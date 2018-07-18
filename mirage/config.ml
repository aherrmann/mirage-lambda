(* from mirage-skeleton/device-usage/block *)
open Mirage

(* configuration step to create disk.img *)
type img = Img
let img = Type Img

let img = impl @@ object
    inherit base_configurable
    method clean _i = Bos.OS.File.delete (Fpath.v "disk.img")
    method module_name = "Functoria_runtime"
    method name = "img"
    method ty = img

    method packages = Key.pure [
      package ~build:true "bos";
      package ~build:true "fpath";
    ]

    method build _i =
      let open Bos in
      OS.Cmd.run Cmd.(v "dd" % "if=/dev/zero" % "of=disk.img" % "count=100000")
end

let port =
  let doc =
    Key.Arg.info
      ~doc:"The TCP port on which to listen for incoming connections."
      ["p"; "port"]
  in
  Key.(create "port" Arg.(opt int 1234 doc))

let disk =
  let doc =
    Key.Arg.info
      ~doc:"The path to the block device to use."
      ["d"; "disk"]
  in
  Key.(create "disk" Arg.(opt string "./disk.img" doc))

let () =
  register "lambda" [
    foreign "Unikernel.Main"
      ~packages:[ package "lambda"
                ; package "lambda-protobuf"
                ; package "rresult" ]
      ~deps:[abstract img]
      ~keys:[Key.abstract port; Key.abstract disk]
      (block @-> stackv4 @-> job)
    $ block_of_file "XXX"
    $ generic_stackv4 default_network
  ]
