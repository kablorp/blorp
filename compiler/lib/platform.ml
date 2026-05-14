(** Host platform detection.

    Centralizes the [uname] probe so the parser doesn't need it and tests
    can mock the result. Evaluated once per process. *)

let host : string Lazy.t =
  lazy
    (* [Sys.os_type] returns ["Unix" | "Win32" | "Cygwin"] — not enough to
     tell macOS from Linux. Fall back to [uname -s]. *)
    (try
       let ic = Unix.open_process_in "uname -s" in
       let s = input_line ic in
       ignore (Unix.close_process_in ic);
       if s = "Darwin" then "macos"
       else if s = "Linux" then "linux"
       else String.lowercase_ascii s
     with _ -> "linux")

(** Current host platform tag ([ "linux" | "macos" | ...]). *)
let current () : string = Lazy.force host
