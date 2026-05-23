(** Compile-profile decisions shared by CLI entry points. *)

type run_mode = Fast | Release

let opt_level_for_run ~sanitize = function
  | _ when sanitize -> "O0"
  | Fast -> "O0"
  | Release -> "O2"
