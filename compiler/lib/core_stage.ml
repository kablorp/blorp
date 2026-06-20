(** Core pipeline stage enum, shared by [--dump-core-after] and
    [--stop-after] CLI flags.

    The variants match [Core_pipeline.observed_stage_order].
    Adding a stage means: add a variant, update [all] and [to_string],
    insert the matching hook in [Core_pipeline]. The unit tests in
    [test_core_stage.ml] round-trip every variant, so forgetting a
    [to_string] update fails fast. *)

type t =
  | Lower
  | Debug
  | Desugar
  | Mono
  | Synth
  | Match
  | TraitResolve
      (** Rewrites trait-method calls ([CCall] to a bare method name) to direct
        calls to the matching impl's mangled name. Runs post-Match so types
        are concrete and pattern compilation is settled; pre-Resolve so the
        rewritten name flows through regular name-lookup. See
        [Core_trait_resolve]. *)
  | Resolve
  | StdInline
  | Tailrec
  | Fusion
  | Specialize
  | Dce
  | ConsumeSpecialize
  | Perceus
  | Reuse
  | Closure
  | Final
      (** [Final] is a synonym for "after every Core pass" and is the
        default when [--dump-core] is given without an argument. *)

(* Stage enum is pure data (parsed, rendered, enumerated by tests and
   tools). The control-flow exception that callbacks raise to stop the
   pipeline lives next to [on_stage_callback] in [Core_pipeline]. *)

let all =
  [
    Lower;
    Debug;
    Desugar;
    Mono;
    Synth;
    Match;
    TraitResolve;
    Resolve;
    StdInline;
    Tailrec;
    Fusion;
    Specialize;
    Dce;
    ConsumeSpecialize;
    Perceus;
    Reuse;
    Closure;
    Final;
  ]

let to_string = function
  | Lower -> "lower"
  | Debug -> "debug"
  | Desugar -> "desugar"
  | Mono -> "mono"
  | Synth -> "synth"
  | Match -> "match"
  | TraitResolve -> "trait_resolve"
  | Resolve -> "resolve"
  | StdInline -> "std_inline"
  | Tailrec -> "tailrec"
  | Fusion -> "fusion"
  | Specialize -> "specialize"
  | Dce -> "dce"
  | ConsumeSpecialize -> "consume_specialize"
  | Perceus -> "perceus"
  | Reuse -> "reuse"
  | Closure -> "closure"
  | Final -> "final"

let stage_names = List.map (fun stage -> (to_string stage, stage)) all

let fallback_valid_stage_names () =
  List.map fst stage_names |> String.concat ", "

let unknown_stage_error_renderer : (string -> string -> string) option ref =
  ref None

let set_unknown_stage_error_renderer renderer =
  unknown_stage_error_renderer := Some renderer

let unknown_stage_error original normalized =
  let fallback_message =
    Printf.sprintf "unknown stage %S (valid: %s)" original
      (fallback_valid_stage_names ())
  in
  let message =
    match !unknown_stage_error_renderer with
    | Some render -> (
        try render original normalized
        with Invalid_argument _ -> fallback_message)
    | None -> fallback_message
  in
  Error message

let of_string s =
  let normalized = String.lowercase_ascii (String.trim s) in
  match List.assoc_opt normalized stage_names with
  | Some stage -> Ok stage
  | None -> unknown_stage_error s normalized

(** Parse a comma-separated list of stage names. Used by the CLI so
    [--dump-core-after=desugar,mono] produces multiple dumps from a
    single invocation. Whitespace around commas is tolerated.

    Returns all stages in input order on success, or the first error
    encountered (the error message names the offending element so the
    user can tell which item was bad in a longer list). *)
let of_string_list s =
  let parts = String.split_on_char ',' s in
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | part :: rest -> (
        match of_string part with
        | Ok stage -> go (stage :: acc) rest
        | Error err -> Error err)
  in
  go [] parts
