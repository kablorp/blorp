val run_process_capture_timeout :
  ?cwd:string ->
  ?env:(string * string) list ->
  timeout:int option ->
  string ->
  string list ->
  int * string

(** Run a subprocess with combined stdout/stderr capture. The subprocess leads
    a new session and process group. A positive timeout terminates that process
    group and returns exit code 124. Descendants that remain in the inherited
    group cannot outlive the command by retaining or closing the capture
    stream; trusted commands must not move descendants into another group.
    Capture is always bounded; overflow terminates the group and returns exit
    code 125 even when the timeout is disabled. *)
