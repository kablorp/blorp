(** Host platform detection.

    Centralizes the [uname] probe so the parser doesn't need it and tests
    can mock the result. Evaluated once per process. *)

let canonical_host_tag = function
  | "Darwin" -> "macos"
  | "Linux" -> "linux"
  | tag -> String.lowercase_ascii tag

let read_uname_s () =
  let ic = Unix.open_process_in "uname -s" in
  Fun.protect
    ~finally:(fun () -> try ignore (Unix.close_process_in ic) with _ -> ())
    (fun () -> input_line ic)

let host : string Lazy.t =
  lazy
    (* [Sys.os_type] returns ["Unix" | "Win32" | "Cygwin"] — not enough to
     tell macOS from Linux. Fall back to [uname -s]. *)
    (try read_uname_s () |> canonical_host_tag with _ -> "linux")

(** Current host platform tag ([ "linux" | "macos" | ...]). *)
let current () : string = Lazy.force host
