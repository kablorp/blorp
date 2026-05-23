(** Compile-profile decisions shared by CLI entry points. *)

type run_mode = Fast | Release

val opt_level_for_run : sanitize:bool -> run_mode -> string
(** C optimization level for [blorp run].

    Fast mode prioritizes edit-run latency. Release mode asks the C compiler for
    optimized generated code. Sanitized runs stay at O0 so diagnostics remain
    useful and sanitizer instrumentation stays predictable. *)
