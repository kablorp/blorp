include Type_proof_metadata

type proof_env = {
  subscript_proofs : (collection_identity * subscript_proof) list;
  range_proofs : (collection_identity * range_proof) list;
}

type narrowed_subject =
  | NarrowedBinding of collection_identity
  | NarrowedAlias of {
      alias : collection_identity;
      target : collection_identity;
    }

type branch_subject =
  | ImmutableSubject of narrowed_subject
  | MutableSubject of collection_identity

type branch_range_proof = { subject : narrowed_subject; proof : range_proof }
type branch_proof_rejection = MutableSubjectCannotNarrow | InvalidRangeBounds

let empty_proof_env = { subscript_proofs = []; range_proofs = [] }

let without_subscript_name env ~var =
  {
    env with
    subscript_proofs =
      List.filter
        (fun (entry_var, _) -> not (collection_identity_equal entry_var var))
        env.subscript_proofs;
  }

let without_range_name env ~var =
  {
    env with
    range_proofs =
      List.filter
        (fun (entry_var, _) -> not (collection_identity_equal entry_var var))
        env.range_proofs;
  }

let proof_env_without_subscript env ~var = without_subscript_name env ~var
let proof_env_without_range env ~var = without_range_name env ~var

let proof_env_add_subscript ?(source = ProofSourceUnknown) env ~var ~collection
    =
  let env = without_subscript_name env ~var in
  {
    env with
    subscript_proofs =
      (var, make_subscript_proof ~source ~collection) :: env.subscript_proofs;
  }

let proof_env_apply_subscript_to_binding env ~var binding =
  match
    List.find_map
      (fun (entry_var, proof) ->
        if collection_identity_equal entry_var var then Some proof else None)
      env.subscript_proofs
  with
  | Some proof ->
      binding_add_subscript_proof
        ~source:(subscript_proof_source proof)
        binding
        ~collection:(subscript_proof_collection proof)
  | None -> binding

let add_range_proof env ~var ~proof =
  let env = without_range_name env ~var in
  { env with range_proofs = (var, proof) :: env.range_proofs }

let proof_env_add_range_bounds ?source env ~var ~range_start ~range_upper =
  let source = Option.value source ~default:ProofSourceUnknown in
  match make_range_proof_with_source ~source ~range_start ~range_upper with
  | Some proof -> add_range_proof env ~var ~proof
  | None -> proof_env_without_range env ~var

let proof_env_find_range env ~var =
  List.find_map
    (fun (entry_var, proof) ->
      if collection_identity_equal entry_var var then Some proof else None)
    env.range_proofs

let immutable_subject name =
  match collection_identity name with
  | Some identity -> Some (ImmutableSubject (NarrowedBinding identity))
  | None -> None

let immutable_alias_subject ~alias ~target =
  match (collection_identity alias, collection_identity target) with
  | Some alias, Some target when not (collection_identity_equal alias target) ->
      Some (ImmutableSubject (NarrowedAlias { alias; target }))
  | _ -> None

let mutable_subject name =
  match collection_identity name with
  | Some identity -> Some (MutableSubject identity)
  | None -> None

let make_branch_range_proof subject ~range_start ~range_upper =
  match subject with
  | MutableSubject _ -> Error MutableSubjectCannotNarrow
  | ImmutableSubject subject -> (
      match
        make_range_proof_with_source ~source:ProofSourceCondition ~range_start
          ~range_upper
      with
      | Some proof -> Ok { subject; proof }
      | None -> Error InvalidRangeBounds)

let branch_range_subject proof = proof.subject
let branch_range_proof proof = proof.proof
