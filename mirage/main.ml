(* Generated by mirage configure --net=socket (Wed, 20 Jun 2018 17:28:40 GMT). *)

open Lwt.Infix
let return = Lwt.return
let run =
OS.Main.run

let _ = Printexc.record_backtrace true

module Unikernel1 = Unikernel.Main(Block)(Tcpip_stack_socket)

module Mirage_logs1 = Mirage_logs.Make(Pclock)

let tcpv4_socket11 = lazy (
  Tcpv4_socket.connect (Key_gen.socket ())
  )

let udpv4_socket11 = lazy (
  Udpv4_socket.connect (Key_gen.socket ())
  )

let argv_unix1 = lazy (
  OS.Env.argv ()
  )

let img1 = lazy (
  return ()
  )

let block11 = lazy (
  Block.connect "/disk.img"
  )

let stackv4_socket1 = lazy (
  let __udpv4_socket11 = Lazy.force udpv4_socket11 in
  let __tcpv4_socket11 = Lazy.force tcpv4_socket11 in
  __udpv4_socket11 >>= fun _udpv4_socket11 ->
  __tcpv4_socket11 >>= fun _tcpv4_socket11 ->
  let config = { Mirage_stack_lwt.name = "stackv4_socket";
            interface = (Key_gen.interfaces ()) ;} in
Tcpip_stack_socket.connect config _udpv4_socket11 _tcpv4_socket11
  )

let pclock1 = lazy (
  Pclock.connect ()
  )

let key1 = lazy (
  let __argv_unix1 = Lazy.force argv_unix1 in
  __argv_unix1 >>= fun _argv_unix1 ->
  return (Functoria_runtime.with_argv (List.map fst Key_gen.runtime_keys) "lambda" _argv_unix1)
  )

let noop1 = lazy (
  return ()
  )

let f11 = lazy (
  let __block11 = Lazy.force block11 in
  let __stackv4_socket1 = Lazy.force stackv4_socket1 in
  let __img1 = Lazy.force img1 in
  __block11 >>= fun _block11 ->
  __stackv4_socket1 >>= fun _stackv4_socket1 ->
  __img1 >>= fun _img1 ->
  Unikernel1.start _block11 _stackv4_socket1 _img1
  )

let mirage_logs1 = lazy (
  let __pclock1 = Lazy.force pclock1 in
  __pclock1 >>= fun _pclock1 ->
  let ring_size = None in
  let reporter = Mirage_logs1.create ?ring_size _pclock1 in
  Mirage_runtime.set_level ~default:Logs.Info (Key_gen.logs ());
  Mirage_logs1.set_reporter reporter;
  Lwt.return reporter
  )

let mirage1 = lazy (
  let __noop1 = Lazy.force noop1 in
  let __noop1 = Lazy.force noop1 in
  let __key1 = Lazy.force key1 in
  let __mirage_logs1 = Lazy.force mirage_logs1 in
  let __f11 = Lazy.force f11 in
  __noop1 >>= fun _noop1 ->
  __noop1 >>= fun _noop1 ->
  __key1 >>= fun _key1 ->
  __mirage_logs1 >>= fun _mirage_logs1 ->
  __f11 >>= fun _f11 ->
  Lwt.return_unit
  )

let () =
  let t =
  Lazy.force noop1 >>= fun _ ->
    Lazy.force noop1 >>= fun _ ->
    Lazy.force key1 >>= fun _ ->
    Lazy.force mirage_logs1 >>= fun _ ->
    Lazy.force mirage1
  in run t