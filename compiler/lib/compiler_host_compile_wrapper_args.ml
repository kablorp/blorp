type t = {
  profile : bool;
  output : string;
  filename : string;
}

let usage =
  "Usage: blorp __compiler-host-compile-wrapper [--profile] -o <out.c> \
   <file.brp>"

let parse = function
  | [ "-o"; output; filename ] -> Ok { profile = false; output; filename }
  | [ "--profile"; "-o"; output; filename ] ->
      Ok { profile = true; output; filename }
  | _ -> Error usage
