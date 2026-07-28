(** Interactive REPL for blorp.

    Provides a read-eval-print loop that accumulates declarations and
    variable bindings across iterations.  Each iteration constructs a
    synthetic source program and runs it through the standard compile
    pipeline. *)

val run : compiler_path:string -> debug:bool -> unit
(** Start the REPL loop.  Reads from stdin, writes to stdout/stderr.
    Returns when the user types [:quit], [:q], or Ctrl-D. *)
