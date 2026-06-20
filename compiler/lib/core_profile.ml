(** Per-stage wall-clock profiler for the compiler pipeline.

    A [t] records start-time / elapsed-time pairs keyed by either a Core stage
    or an explicit frontend label. The [on_stage] callback is designed to plug
    into [Core_pipeline.compile_typed_with_modules ~on_stage]: it measures the time
    between successive stage fires, attributing each delta to the phase that
    just completed.

    Timing source is [Unix.gettimeofday] (wall clock, including I/O wait
    time) rather than [Sys.time] (CPU time), so phases that block on
    module loading or disk reads show their real cost. *)

type entry = Core_stage.t * float
(** Core stage × elapsed milliseconds *)

type phase = Core of Core_stage.t | Label of string
type timed_entry = phase * float

type t = {
  mutable start : float;  (** time of the last [on_stage] fire *)
  entries : timed_entry list ref;  (** reverse chronological *)
}

let now_ms () = Unix.gettimeofday () *. 1000.0
let create () = { start = now_ms (); entries = ref [] }
let record_phase t phase ms = t.entries := (phase, ms) :: !(t.entries)

(** Record a pre-computed duration (ms) for a stage. Primarily for tests. *)
let record t stage ms = record_phase t (Core stage) ms

(** Record a pre-computed duration (ms) for a non-Core phase. *)
let record_label t label ms = record_phase t (Label label) ms

let record_elapsed t phase =
  let now = now_ms () in
  let elapsed = now -. t.start in
  t.start <- now;
  record_phase t phase elapsed

(** Callback for non-Core compiler phases. *)
let on_label (t : t) label = record_elapsed t (Label label)

(** Callback compatible with [Core_pipeline.on_stage_callback]. Measures the
    elapsed time since the previous fire (or [create]) and attributes it
    to the stage that just completed. Ignores the program payload. *)
let on_stage (t : t) : Core_stage.t -> Core.core_program -> unit =
 fun stage _prog -> record_elapsed t (Core stage)

let all_entries t : timed_entry list = List.rev !(t.entries)

let entries t : entry list =
  all_entries t
  |> List.filter_map (function Core stage, ms -> Some (stage, ms) | _ -> None)

let phase_label = function
  | Core stage -> Core_stage.to_string stage
  | Label s -> s

let phase_kind = function Core _ -> "core" | Label _ -> "label"

let serialize_entry (phase, ms) =
  String.concat "\t"
    [ phase_kind phase; phase_label phase; Printf.sprintf "%.17g" ms ]

let serialize_entries entries =
  entries |> List.map serialize_entry |> String.concat "\n"

(** Format the profile as a readable table. Phases appear in the order
    they fired. If only Core stages were recorded, the first stage is annotated
    with [*] because the profiler cannot see work that happened before the
    first stage callback. *)
let format (t : t) : string =
  t |> all_entries |> serialize_entries
  |> Compiler_blorp_bridge.render_core_profile_format
