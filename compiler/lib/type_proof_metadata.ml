type collection_identity = CollectionIdentity of string
type dimension_identity = DimensionIdentity of string

type proven_collection =
  | CollVar of collection_identity
  | CollSubscript of proven_collection * collection_identity
  | CollDim of int

type range_upper =
  | RangeUpperLit of int
  | RangeUpperDimension of dimension_identity
  | RangeUpperLengthMinus of { coll : collection_identity; end_offset : int }
  | RangeUpperAtMostLength of { coll : collection_identity }

type proof_source =
  | ProofSourceUnknown
  | ProofSourceLoopRange
  | ProofSourceLoopIndices
  | ProofSourceLoopEnumerate
  | ProofSourceCondition
  | ProofSourceRangeTypeFallback

type range_proof = {
  range_start : int;
  range_upper : range_upper;
  range_source : proof_source;
}

type subscript_proof = {
  subscript_collection : proven_collection;
  subscript_source : proof_source;
}

type value_proofs = {
  range : range_proof option;
  subscript : subscript_proof option;
}

type binding_refinement = value_proofs
type expr_proofs = value_proofs

type subscript_bound =
  | ConstantDim of int
  | DimensionBound of dimension_identity
  | CollectionLength of collection_identity

type subscript_bounds = {
  constant_dims : int list;
  dimension_bounds : dimension_identity list;
  collection_lengths : collection_identity list;
}

type offset_rejection = OffsetNoMatchingBound | OffsetOutOfBounds of string

type offset_subscript_proof =
  | OffsetProven
  | OffsetRejected of offset_rejection

let collection_identity_equal (CollectionIdentity a) (CollectionIdentity b) =
  String.equal a b

let dimension_identity_equal (DimensionIdentity a) (DimensionIdentity b) =
  String.equal a b

let rec proven_collection_equal a b =
  match (a, b) with
  | CollVar x, CollVar y -> collection_identity_equal x y
  | CollSubscript (ca, ia), CollSubscript (cb, ib) ->
      collection_identity_equal ia ib && proven_collection_equal ca cb
  | CollDim a, CollDim b -> a = b
  | _ -> false

let valid_identity s = String.trim s = s && s <> ""
let is_dim_var_name name = String.length name > 0 && name.[0] = '#'

let collection_identity name =
  if valid_identity name then Some (CollectionIdentity name) else None

let dimension_identity name =
  if is_dim_var_name name then Some (DimensionIdentity name) else None

let collection_identity_name (CollectionIdentity name) = name
let dimension_identity_name (DimensionIdentity name) = name
let collection_var identity = CollVar identity
let collection_subscript coll ~index = CollSubscript (coll, index)
let collection_dim dim = if dim < 0 then None else Some (CollDim dim)

let direct_collection_var = function
  | CollVar identity -> Some identity
  | _ -> None

let collection_dim_at_most coll ~size =
  match coll with CollDim dim -> size >= 0 && dim <= size | _ -> false

let range_upper_lit upper =
  if upper < 0 then None else Some (RangeUpperLit upper)

let range_upper_dimension dim = RangeUpperDimension dim

let range_upper_length_minus ~coll ~end_offset =
  if end_offset < 0 then None
  else Some (RangeUpperLengthMinus { coll; end_offset })

let range_upper_at_most_length ~coll = RangeUpperAtMostLength { coll }

let valid_upper ~range_start = function
  | RangeUpperLit upper -> upper >= 0 && upper >= range_start
  | RangeUpperDimension _ -> range_start >= 0
  | RangeUpperLengthMinus { end_offset; _ } -> end_offset >= 0
  | RangeUpperAtMostLength _ -> true

let make_range_proof_with_source ~source ~range_start ~range_upper =
  if range_start < 0 || not (valid_upper ~range_start range_upper) then None
  else Some { range_start; range_upper; range_source = source }

let make_range_proof ~range_start ~range_upper =
  make_range_proof_with_source ~source:ProofSourceUnknown ~range_start
    ~range_upper

let range_proof_source proof = proof.range_source

let make_subscript_proof ~source ~collection =
  { subscript_collection = collection; subscript_source = source }

let subscript_proof_collection proof = proof.subscript_collection
let subscript_proof_source proof = proof.subscript_source
let no_proofs = { range = None; subscript = None }
let unrefined_binding = no_proofs
let unproven_expr = no_proofs
let expr_proofs_of_binding binding = binding
let binding_refinement_of_expr_proofs proofs = proofs
let range_binding proof = { no_proofs with range = Some proof }
let binding_add_range_proof binding proof = { binding with range = Some proof }

let binding_add_subscript_proof ?(source = ProofSourceUnknown) binding
    ~collection =
  {
    binding with
    subscript =
      Some { subscript_collection = collection; subscript_source = source };
  }

let binding_range_proof binding = binding.range

let binding_proves_subscript binding ~collection =
  match binding.subscript with
  | Some proof -> proven_collection_equal proof.subscript_collection collection
  | None -> false

let binding_proves_dim_at_most binding ~size =
  match binding.subscript with
  | Some proof -> collection_dim_at_most proof.subscript_collection ~size
  | None -> false

let binding_direct_collection_vars binding =
  match binding.subscript with
  | Some proof -> (
      match direct_collection_var proof.subscript_collection with
      | Some identity -> [ identity ]
      | None -> [])
  | None -> []

let constant_dim_bound dim = if dim < 0 then None else Some (ConstantDim dim)
let dimension_bound dim = DimensionBound dim
let collection_length_bound coll = CollectionLength coll

let subscript_bounds bounds =
  let rec go constant_dims dimension_bounds collection_lengths = function
    | [] ->
        {
          constant_dims = List.rev constant_dims;
          dimension_bounds = List.rev dimension_bounds;
          collection_lengths = List.rev collection_lengths;
        }
    | ConstantDim dim :: rest ->
        go (dim :: constant_dims) dimension_bounds collection_lengths rest
    | DimensionBound dim :: rest ->
        go constant_dims (dim :: dimension_bounds) collection_lengths rest
    | CollectionLength coll :: rest ->
        go constant_dims dimension_bounds (coll :: collection_lengths) rest
  in
  go [] [] [] bounds

let covers_const_dim proof ~dim =
  match proof.range_upper with
  | RangeUpperLit upper -> proof.range_start >= 0 && upper <= dim
  | RangeUpperDimension _ | RangeUpperLengthMinus _ | RangeUpperAtMostLength _
    ->
      false

let covers_dimension proof ~dim =
  match proof.range_upper with
  | RangeUpperDimension bounded_dim ->
      proof.range_start >= 0 && dimension_identity_equal bounded_dim dim
  | RangeUpperLit _ | RangeUpperLengthMinus _ | RangeUpperAtMostLength _ ->
      false

let covers_same_collection proof ~coll =
  match proof.range_upper with
  | RangeUpperLengthMinus { coll = bounded_coll; _ }
  | RangeUpperAtMostLength { coll = bounded_coll } ->
      proof.range_start >= 0 && collection_identity_equal bounded_coll coll
  | RangeUpperLit _ | RangeUpperDimension _ -> false

let covers_const_dim_with_offset proof ~dim ~offset =
  match proof.range_upper with
  | RangeUpperLit upper ->
      if upper <= proof.range_start then Ok ()
      else
        let min_val = proof.range_start + offset in
        let max_val = upper - 1 + offset in
        if min_val >= 0 && max_val >= 0 && max_val < dim then Ok ()
        else
          Error
            (Printf.sprintf
               "index range [%d, %d] exceeds dimension of size %d. Adjust loop \
                bounds to ensure all accesses are in [0, %d)"
               min_val max_val dim dim)
  | RangeUpperDimension _ | RangeUpperLengthMinus _ | RangeUpperAtMostLength _
    ->
      Error ""

let covers_same_collection_with_offset proof ~coll ~offset =
  match proof.range_upper with
  | RangeUpperLengthMinus { coll = bounded_coll; end_offset } ->
      collection_identity_equal bounded_coll coll
      && proof.range_start + offset >= 0
      && offset <= end_offset
  | RangeUpperAtMostLength _ | RangeUpperLit _ | RangeUpperDimension _ -> false

let proves_direct_subscript_with_bounds proof ~bounds =
  match proof.range_upper with
  | RangeUpperLit _ ->
      List.exists (fun dim -> covers_const_dim proof ~dim) bounds.constant_dims
  | RangeUpperDimension _ ->
      List.exists
        (fun dim -> covers_dimension proof ~dim)
        bounds.dimension_bounds
  | RangeUpperLengthMinus _ | RangeUpperAtMostLength _ ->
      List.exists
        (fun coll -> covers_same_collection proof ~coll)
        bounds.collection_lengths

let proves_direct_subscript proof ~bounds =
  proves_direct_subscript_with_bounds proof ~bounds:(subscript_bounds bounds)

let proves_offset_subscript_with_bounds proof ~bounds ~offset =
  match proof.range_upper with
  | RangeUpperLit _ ->
      let rec check first_error = function
        | [] -> OffsetRejected first_error
        | dim :: rest -> (
            match covers_const_dim_with_offset proof ~dim ~offset with
            | Ok () -> OffsetProven
            | Error "" -> check first_error rest
            | Error msg ->
                check
                  (match first_error with
                  | OffsetOutOfBounds _ -> first_error
                  | OffsetNoMatchingBound -> OffsetOutOfBounds msg)
                  rest)
      in
      check OffsetNoMatchingBound bounds.constant_dims
  | RangeUpperDimension _ -> OffsetRejected OffsetNoMatchingBound
  | RangeUpperLengthMinus _ | RangeUpperAtMostLength _ ->
      if
        List.exists
          (fun coll -> covers_same_collection_with_offset proof ~coll ~offset)
          bounds.collection_lengths
      then OffsetProven
      else OffsetRejected OffsetNoMatchingBound

let proves_offset_subscript proof ~bounds ~offset =
  proves_offset_subscript_with_bounds proof ~bounds:(subscript_bounds bounds)
    ~offset

let binding_proves_direct_range binding ~bounds =
  match binding.range with
  | Some proof -> proves_direct_subscript proof ~bounds
  | None -> false

let binding_proves_offset_range binding ~bounds ~offset =
  match binding.range with
  | Some proof -> proves_offset_subscript proof ~bounds ~offset
  | None -> OffsetRejected OffsetNoMatchingBound

let offset_no_matching_bound = OffsetRejected OffsetNoMatchingBound
