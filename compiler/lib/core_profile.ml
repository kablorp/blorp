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

let total_duration entries =
  List.fold_left (fun acc (_, ms) -> acc +. ms) 0.0 entries

let has_label_entries entries =
  List.exists (function Label _, _ -> true | Core _, _ -> false) entries

let row_label ~has_labels index phase =
  if index = 0 && not has_labels then phase_label phase ^ "*"
  else phase_label phase

let profile_rows entries =
  let has_labels = has_label_entries entries in
  List.mapi
    (fun index (phase, ms) -> (row_label ~has_labels index phase, ms))
    entries

let label_width rows =
  List.fold_left
    (fun acc (label, _) -> max acc (String.length label))
    (String.length "phase") (("total", 0.0) :: rows)

let row_percent ~total_ms ms =
  if total_ms > 0.0 then ms /. total_ms *. 100.0 else 0.0

let add_row buf ~label_width ~total_ms (label, ms) =
  Buffer.add_string buf
    (Printf.sprintf "%-*s %6.1f  %5.1f\n" label_width label ms
       (row_percent ~total_ms ms))

(** Format the profile as a readable table. Phases appear in the order
    they fired. If only Core stages were recorded, the first stage is annotated
    with [*] because the profiler cannot see work that happened before the
    first stage callback. *)
let format (t : t) : string =
  let entries = all_entries t in
  let total_ms = total_duration entries in
  let has_labels = has_label_entries entries in
  let rows = profile_rows entries in
  let label_width = label_width rows in
  let separator = String.make (label_width + 14) '-' in
  let buf = Buffer.create 256 in
  Buffer.add_string buf
    (Printf.sprintf "%-*s %6s  %5s\n" label_width "phase" "ms" "%");
  Buffer.add_string buf separator;
  Buffer.add_char buf '\n';
  List.iter (add_row buf ~label_width ~total_ms) rows;
  Buffer.add_string buf separator;
  Buffer.add_char buf '\n';
  Buffer.add_string buf
    (Printf.sprintf "%-*s %6.1f  100.0\n" label_width "total" total_ms);
  if entries <> [] && not has_labels then
    Buffer.add_string buf
      "* first entry includes work before the first stage callback\n";
  Buffer.contents buf
