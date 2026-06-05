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
let valid_stage_names = List.map fst stage_names

(* Small local Levenshtein — Core_stage intentionally has no deps beyond
   stdlib. Duplication with [Env.levenshtein] is acceptable; a shared
   helper module would require a new layer to avoid cycles. *)
let edit_distance s1 s2 =
  let len1 = String.length s1 and len2 = String.length s2 in
  if len1 = 0 then len2
  else if len2 = 0 then len1
  else
    let prev = Array.init (len2 + 1) (fun j -> j) in
    let curr = Array.make (len2 + 1) 0 in
    for i = 1 to len1 do
      curr.(0) <- i;
      for j = 1 to len2 do
        let cost = if s1.[i - 1] = s2.[j - 1] then 0 else 1 in
        curr.(j) <-
          min (min (prev.(j) + 1) (curr.(j - 1) + 1)) (prev.(j - 1) + cost)
      done;
      Array.blit curr 0 prev 0 (len2 + 1)
    done;
    prev.(len2)

(** Closest stage name to [s] by edit distance, or [None] if nothing is
    within a useful threshold. Threshold scales with input length so a
    2-char typo in "monot" gets matched to "mono". *)
let closest_stage s =
  let max_dist = max 1 ((String.length s / 3) + 1) in
  let scored =
    List.filter_map
      (fun name ->
        let d = edit_distance s name in
        if d <= max_dist then Some (name, d) else None)
      valid_stage_names
  in
  match List.sort (fun (_, a) (_, b) -> compare a b) scored with
  | (best, _) :: _ -> Some best
  | [] -> None

let unknown_stage_error original normalized =
  let suggestion =
    match closest_stage normalized with
    | Some name -> Printf.sprintf " (did you mean %S?)" name
    | None -> ""
  in
  let valid = String.concat ", " valid_stage_names in
  Error
    (Printf.sprintf "unknown stage %S%s (valid: %s)" original suggestion valid)

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
