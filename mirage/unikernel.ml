open Lwt.Infix

module type BLOCK = Mirage_block_lwt.S
module type TCP = Mirage_stack_lwt.V4

[@@@warning "-40"]

let pp_chr =
  Fmt.using
    (function '\032' .. '\126' as x -> x
            | _ -> '.')
    Fmt.char

let pp_scalar : type buffer. get:(buffer -> int -> char) -> length:(buffer -> int) -> buffer Fmt.t
  = fun ~get ~length ppf b ->
  let l = length b in

  for i = 0 to l / 16
  do Fmt.pf ppf "%08x: " (i * 16);
    let j = ref 0 in

    while !j < 16
    do if (i * 16) + !j < l
      then Fmt.pf ppf "%02x" (Char.code @@ get b ((i * 16) + !j))
      else Fmt.pf ppf "  ";

      if !j mod 2 <> 0 then Fmt.pf ppf " ";

      incr j;
    done;

    Fmt.pf ppf "  ";
    j := 0;

    while !j < 16
    do if (i * 16) + !j < l
      then Fmt.pf ppf "%a" pp_chr (get b ((i * 16) + !j))
      else Fmt.pf ppf " ";

      incr j;
    done;

    Fmt.pf ppf "@\n"
  done

let pp_string    = pp_scalar ~get:String.get ~length:String.length
let pp_bytes     = pp_scalar ~get:Bytes.get ~length:Bytes.length
let pp_cstruct   = pp_scalar ~get:Cstruct.get_char ~length:Cstruct.len

let log_src = Logs.Src.create "lambda" ~doc:"lambda"
module Log = (val Logs.src_log log_src : Logs.LOG)

module Main (B: BLOCK) (S: TCP) = struct

  module AbstractTypes = struct
    (* XXX(dinosaure): we need to define types at top-level. *)

    let cstruct     = Lambda.Type.abstract "Cstruct.t"
    let formatter   = Lambda.Type.abstract "Format.formatter"
    let error       = Lambda.Type.abstract "Block.error"
    let write_error = Lambda.Type.abstract "Block.write_error"
    let info        = Lambda.Type.abstract "Mirage_block.info"
  end

  let make_environment b =
    let open AbstractTypes in
    let open Lambda_protobuf in
    List.fold_left
      (fun primitives (k, v) -> match v with
         | Lambda.Parsetree.Prm primitive -> Primitives.add k primitive primitives
         | _ -> Fmt.invalid_arg "Invalid expression as primitive")
      Primitives.empty
      Lambda.[ primitive   "Block.pp_error"           [ formatter; error; ]                     Type.unit                            B.pp_error
             ; primitive   "Block.pp_write_error"     [ formatter; write_error; ]               Type.unit                            B.pp_write_error
             ; L.primitive "Block.disconnect"         []                                        Type.(lwt unit)                      B.(disconnect b)
             ; L.primitive "Block.get_info"           []                                        Type.(lwt info)                      B.(get_info b)
             ; primitive   "read_write"               [ info ]                                  Type.bool                            (fun b -> b.Mirage_block.read_write)
             ; primitive   "sector_size"              [ info ]                                  Type.int                             (fun b -> b.Mirage_block.sector_size)
             ; primitive   "size_sectors"             [ info ]                                  Type.int64                           (fun b -> b.Mirage_block.size_sectors)
             ; L.primitive "Block.read"               Type.[ int64; list cstruct; ]             Type.(lwt (result unit error))       B.(read b)
             ; L.primitive "Block.write"              Type.[ int64; list cstruct; ]             Type.(lwt (result unit write_error)) B.(write b)
             ; primitive   "Cstruct.to_string"        [ cstruct ]                               Type.string                          Cstruct.to_string
             ; primitive   "Cstruct.of_string"        [ Type.string ]                           cstruct                              (fun s -> Cstruct.of_string s)
             ; primitive   "Cstruct.blit"             Type.[ cstruct; int; cstruct; int; int; ] Type.unit                            Cstruct.blit
             ; primitive   "Cstruct.blit_to_string"   Type.[ cstruct; int; bytes; int; int; ]   Type.unit                            Cstruct.blit_to_bytes
             ; primitive   "Cstruct.blit_from_string" Type.[ string; int; cstruct; int; int; ]  Type.unit                            Cstruct.blit_from_string ],
    List.fold_left
      (fun gamma (k, v) -> Gamma.add k v gamma)
      Gamma.empty
      [ "Format.formatter",  Lambda.Type.abstract_injection formatter
      ; "Block.error",       Lambda.Type.abstract_injection error
      ; "Cstruct.t",         Lambda.Type.abstract_injection cstruct
      ; "Mirage_block.info", Lambda.Type.abstract_injection info
      ; "Block.write_error", Lambda.Type.abstract_injection write_error ]

  let bind_err flow x f =
    x >>= function
    | Ok ()   -> f ()
    | Error e ->
      Log.err (fun l -> l "Got %a, closing" S.TCPV4.pp_write_error e);
      S.TCPV4.close flow

  let eval ~blocks ~gamma ~primitives request =
    try
      Log.info (fun l -> l "Parse protobuf request:\n\n%a%!" pp_string request);

      let request = Pbrt.Decoder.of_bytes (Bytes.unsafe_of_string request) in
      let request = Lambda_protobuf.Pb.decode_request request in
      let ast, ret, _ = Lambda_protobuf.request ~gamma ~primitives request in
      let Lambda.Type.V ret = Lambda.Type.typ ret in

      let expected = Lambda.Type.(list AbstractTypes.cstruct @-> list AbstractTypes.cstruct @-> ret) in

      let res = match Lambda.type_and_eval ast expected with
        | Ok f -> let x = f blocks [] in Ok x
        | Error e -> Fmt.kstrf (fun e -> Error (`Msg e)) "%a" Lambda.pp_error e in

      let pp_value = Lambda.Type.pp_val ret in

      Logs.info (fun l -> l "Process and eval: %a => %a.\n%!"
                    Lambda.Parsetree.pp ast
                    (Fmt.result ~ok:pp_value ~error:Rresult.R.pp_msg) res);
      Ok ()
    with exn ->
      Logs.err (fun l -> l "Retrieve an error: %s" (Printexc.to_string exn));
      Error (`Msg (Printexc.to_string exn))

  let process ~gamma ~primitives flow =
    let dst, dst_port = S.TCPV4.dst flow in

    Logs.info (fun f ->
        f "new tcp connection from IP %a on port %d"
          Ipaddr.V4.pp_hum dst dst_port);

    let (>>?) = bind_err flow in
    let buffer = Buffer.create 512 in
    let block_buffer = Cstruct_buffer.create 512 in
    let decoder = Lambda_protobuf.Rpc.Decoder.default () in

    let rec loop blocks decoder =
      S.TCPV4.read flow >>= function
      | Ok `Eof ->
        Logs.info (fun f -> f "Closing connection!");
        Lwt.return_unit
      | Error e ->
        Logs.warn (fun f ->
            f "Error reading data from established connection: %a"
              S.TCPV4.pp_error e);
        Lwt.return_unit
      | Ok (`Data src) ->

        let rec go blocks decoder =
          Log.info (fun f -> f "State of the decoder: %a." Lambda_protobuf.Rpc.Decoder.pp decoder);

          match Lambda_protobuf.Rpc.Decoder.eval src decoder with
          | `Await decoder -> decoder, blocks
          | `Flush (decoder, `Protobuf, raw) ->
            Buffer.add_string buffer (Cstruct.to_string raw);
            go blocks (Lambda_protobuf.Rpc.Decoder.flush decoder)
          | `Flush (decoder, `Block n, raw) ->
            let blocks =
              if Int64.to_int n = List.length blocks then blocks
              else
                (Log.info (fun f ->
                     f "Retrieve block %d:\n\n%a\n%!"
                       (List.length blocks)
                       pp_string (Cstruct_buffer.contents block_buffer))
                ; let block = Cstruct_buffer.contents block_buffer in
                  Cstruct_buffer.clear block_buffer
                ; block :: blocks) in

            Cstruct_buffer.add block_buffer raw;

            go blocks (Lambda_protobuf.Rpc.Decoder.flush decoder)
          | `Error (decoder, err) ->
            Logs.warn (fun f ->
                f "Retrieve an error: %a."
                  Lambda_protobuf.Rpc.Decoder.pp_error err);
            (Lambda_protobuf.Rpc.Decoder.reset decoder, [])
          | `End decoder ->

            let blocks =
              if Cstruct_buffer.has block_buffer > 0
              then (Log.info (fun f ->
                  f "Retrieve block %d:\n%a\n%!"
                    (List.length blocks)
                    pp_string (Cstruct_buffer.contents block_buffer))
                   ; let block = Cstruct_buffer.contents block_buffer in
                     Cstruct_buffer.clear block_buffer
                   ; block :: blocks)
              else blocks in

            eval ~blocks:(List.map Cstruct.of_string (List.rev blocks)) ~gamma ~primitives (Buffer.contents buffer) |> fun res ->
            Buffer.clear buffer;
            (Lambda_protobuf.Rpc.Decoder.reset decoder, []) in

        let decoder, blocks = go blocks (Lambda_protobuf.Rpc.Decoder.refill 0 (Cstruct.len src) decoder) in
        loop blocks decoder
    in loop [] decoder

  let start b s () =
    let primitives, gamma = make_environment b in

    let port = Key_gen.port () in
    S.listen_tcpv4 s ~port (process ~gamma ~primitives);
    S.listen s

end
