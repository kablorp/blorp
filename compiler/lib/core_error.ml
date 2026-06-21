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

let formatter :
    (phase:string ->
    message:string ->
    line:int ->
    column:int ->
    hint:string option ->
    string)
    option
    ref =
  ref None

let set_formatter render = formatter := Some render

(** Render a [Core_error.t] as a multi-line string for display. *)
let to_string (e : t) : string =
  let fallback_to_string () =
    let base =
      Printf.sprintf "%s: %s at %d:%d"
        (phase_tag_to_string e.phase)
        e.msg e.loc.line e.loc.column
    in
    match e.hint with Some h -> base ^ "\n  hint: " ^ h | None -> base
  in
  match !formatter with
  | Some render -> (
      try
        render
          ~phase:(phase_tag_to_string e.phase)
          ~message:e.msg ~line:e.loc.line ~column:e.loc.column ~hint:e.hint
      with Invalid_argument _ -> fallback_to_string ())
  | None -> fallback_to_string ()
