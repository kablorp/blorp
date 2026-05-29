(** Compile-profile decisions shared by CLI entry points. *)

type run_mode = Fast | Release
type opt_level = Unoptimized | Optimized

let opt_level_flag = function Unoptimized -> "O0" | Optimized -> "O2"
let opt_level_for_mode = function Fast -> Unoptimized | Release -> Optimized

let opt_level_for_run ~sanitize mode =
  let level = if sanitize then Unoptimized else opt_level_for_mode mode in
  opt_level_flag level
