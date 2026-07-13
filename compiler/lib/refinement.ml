include Type_proof_metadata

type proof_env = {
  subscript_proofs : (collection_identity * subscript_proof) list;
  range_proofs : (collection_identity * range_proof) list;
}

type branch_subject = ImmutableSubject | MutableSubject
type branch_range_proof = range_proof
type branch_proof_rejection = MutableSubjectCannotNarrow | InvalidRangeBounds

let empty_proof_env = { subscript_proofs = []; range_proofs = [] }

let remove_proofs_for_var var proofs =
  List.filter
    (fun (entry_var, _) -> not (collection_identity_equal entry_var var))
    proofs

let replace_proof_for_var var proof proofs =
  (var, proof) :: remove_proofs_for_var var proofs

let find_proof_for_var var proofs =
  List.find_map
    (fun (entry_var, proof) ->
      if collection_identity_equal entry_var var then Some proof else None)
    proofs

let without_subscript_name env ~var =
  { env with subscript_proofs = remove_proofs_for_var var env.subscript_proofs }

let without_range_name env ~var =
  { env with range_proofs = remove_proofs_for_var var env.range_proofs }

let proof_env_without_subscript env ~var = without_subscript_name env ~var
let proof_env_without_range env ~var = without_range_name env ~var

let proof_env_add_subscript ?(source = ProofSourceUnknown) env ~var ~collection
    =
  {
    env with
    subscript_proofs =
      replace_proof_for_var var
        (make_subscript_proof ~source ~collection)
        env.subscript_proofs;
  }

let proof_env_apply_subscript_to_binding env ~var binding =
  match find_proof_for_var var env.subscript_proofs with
  | Some proof ->
      binding_add_subscript_proof
        ~source:(subscript_proof_source proof)
        binding
        ~collection:(subscript_proof_collection proof)
  | None -> binding

let add_range_proof env ~var ~proof =
  { env with range_proofs = replace_proof_for_var var proof env.range_proofs }

let proof_env_add_range_bounds ?source env ~var ~range_start ~range_upper =
  let source = Option.value source ~default:ProofSourceUnknown in
  match make_range_proof_with_source ~source ~range_start ~range_upper with
  | Some proof -> add_range_proof env ~var ~proof
  | None -> proof_env_without_range env ~var

let proof_env_find_range env ~var = find_proof_for_var var env.range_proofs

let immutable_subject name =
  match collection_identity name with
  | Some _ -> Some ImmutableSubject
  | None -> None

let mutable_subject name =
  match collection_identity name with
  | Some _ -> Some MutableSubject
  | None -> None

let make_branch_range_proof subject ~range_start ~range_upper =
  match subject with
  | MutableSubject -> Error MutableSubjectCannotNarrow
  | ImmutableSubject -> (
      match
        make_range_proof_with_source ~source:ProofSourceCondition ~range_start
          ~range_upper
      with
      | Some proof -> Ok proof
      | None -> Error InvalidRangeBounds)

let branch_range_proof proof = proof
