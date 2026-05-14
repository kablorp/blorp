(** Pure OCaml raw terminal line editor for the REPL.

    Provides readline-like editing (cursor movement, history navigation,
    kill/yank) using raw terminal mode via [Unix.tcsetattr].  Falls back
    to basic [input_line] when stdin is not a TTY. *)

type t

type read_result =
  | Input of string  (** Complete input ready to evaluate *)
  | Eof  (** End of input (Ctrl-D on empty line) *)
  | Interrupted  (** Input cancelled (Ctrl-C) *)

val create : ?max_history:int -> unit -> t

val enter_raw_mode : t -> unit
(** Enter raw terminal mode.  No-op if stdin is not a TTY. *)

val restore_mode : t -> unit
(** Restore original terminal settings.  No-op if not in raw mode. *)

val install_cleanup_handlers : t -> unit
(** Install [at_exit] and signal handlers that restore the terminal. *)

val read_input : t -> read_result
(** Read one complete input (single or multi-line) from the user.
    In TTY mode, single-line expressions execute on Enter; multi-line
    blocks (lines ending with [:]) continue until a blank line.
    In non-TTY mode, reads until a blank line or EOF. *)

val add_history : t -> string -> unit
(** Add a completed input string to history. *)

val set_hint_fn : t -> (string -> string option) -> unit
(** Set a ghost hint callback.
    Given the current text, return [Some suffix] to show dimmed after cursor,
    or [None] for no hint. *)

val set_completions_fn : t -> (string -> (string * string) list) -> unit
(** Set a tab-completion callback.
    Given the current text, return [(command, description)] pairs for matching
    commands. *)
