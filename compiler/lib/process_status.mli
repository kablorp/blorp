(** Portable conversion of OCaml process statuses to shell-style exit codes. *)

val exit_code_of_signal : int -> int
(** Return [128 + signal_number]. OCaml represents standard signal constants
    as negative integers, unlike the positive numbers used by shells. *)

val exit_code : Unix.process_status -> int
(** Convert a completed process status to the exit-code convention used by the
    compiler CLI and test harnesses. *)
