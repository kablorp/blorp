(** Structured errors raised by Core passes.

    Phase 0.5.1 consolidation: [phase] is now a typed [phase_tag] variant
    rather than a free-form string, eliminating drift between the phase
    tag on an error and the [Core_stage] enum. Stage renames become
    compile errors, not silent text drift.

    {1 Usage}

    {[
      open Core_error

      errorf
        (Stage Core_stage.Lower)
        expr.expr_loc
        ~hint:"every expression must be typed before lowering — \
               run Infer.infer before Core_lower.lower_typed_expr"
        "expression missing type"
    ]}

    At the boundary (e.g. [Pipeline]), catch [Core_error] and render
    it via [to_string] or a fancier [Diagnostics]-based renderer:

    {[
      try Core_lower.lower_typed_program typed_prog
      with Core_error err ->
        prerr_endline (Core_error.to_string err);
        exit 1
    ]} *)

(** Where in the compiler an error was produced. Stage-level errors
    carry a [Core_stage.t] so they round-trip with the observability
    infrastructure. [Frontend] and [Emit] cover the pre- and post-
    stage positions that are not modeled as [Core_stage] variants
    (parse / typecheck / module load before any Core pass; C
    emission after every stage has run). [Other] is an escape hatch
    for infrastructure code that doesn't cleanly map to a single
    phase (e.g. traversal helpers, registry builders). *)
type phase_tag =
  | Stage of Core_stage.t
  | Frontend  (** pre-Core work: parse, typecheck, module load *)
  | Emit  (** post-stage work: C emission *)
  | Other of string  (** free-form tag for non-pipeline infrastructure *)

(** Render a [phase_tag] as a stable short string suitable for error
    messages and diagnostic prefixes. *)
let phase_tag_to_string = function
  | Stage s -> Core_stage.to_string s
  | Frontend -> "frontend"
  | Emit -> "emit"
  | Other s -> s

type t = {
  phase : phase_tag;  (** which pass / module raised *)
  msg : string;  (** the primary error message *)
  loc : Ast.loc;  (** source location of the offending node *)
  hint : string option;  (** optional actionable suggestion *)
}
(** A structured Core-pass error. *)

exception Core_error of t
(** The exception carrying a [t]. Catch this at pipeline boundaries. *)

(** [errorf ?hint phase loc fmt ...] — raise [Core_error] with a
    [Printf]-style formatted message. Use [?hint] to attach an
    actionable suggestion. *)
let errorf ?hint phase loc fmt =
  Printf.ksprintf (fun msg -> raise (Core_error { phase; msg; loc; hint })) fmt

(** Render a [Core_error.t] as a multi-line string for display. *)
let to_string (e : t) : string =
  let base =
    Printf.sprintf "%s: %s at %d:%d"
      (phase_tag_to_string e.phase)
      e.msg e.loc.line e.loc.column
  in
  match e.hint with Some h -> base ^ "\n  hint: " ^ h | None -> base

(** Test helper: run [f] and assert it raised [Core_error] whose
    [phase] equals [~phase] and whose [msg] contains [~msg_contains]
    as a substring. Raises [Alcotest.Test_error] on mismatch. *)
let check_raises ~(phase : phase_tag) ~msg_contains f =
  let found = ref None in
  (try f () with Core_error e -> found := Some e);
  match !found with
  | None ->
      failwith
        (Printf.sprintf
           "expected Core_error %s containing %S — no exception raised"
           (phase_tag_to_string phase)
           msg_contains)
  | Some e ->
      if e.phase <> phase then
        failwith
          (Printf.sprintf
             "Core_error phase mismatch: expected %S, got %S (msg=%S)"
             (phase_tag_to_string phase)
             (phase_tag_to_string e.phase)
             e.msg);
      let contains haystack needle =
        let hn = String.length needle in
        let hl = String.length haystack in
        let rec go i =
          if i + hn > hl then false
          else if String.sub haystack i hn = needle then true
          else go (i + 1)
        in
        go 0
      in
      if not (contains e.msg msg_contains) then
        failwith
          (Printf.sprintf "Core_error msg %S does not contain %S" e.msg
             msg_contains)
