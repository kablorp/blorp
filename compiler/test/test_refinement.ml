open Blorp.Refinement

let expect_some name = function
  | Some value -> value
  | None -> Alcotest.failf "%s: expected proof" name

let expect_none name = function
  | None -> ()
  | Some _ -> Alcotest.failf "%s: expected no proof" name

let coll_id name = expect_some name (collection_identity name)
let coll_var name = collection_var (coll_id name)
let coll_subscript coll index = collection_subscript coll ~index:(coll_id index)
let dim_id name = expect_some name (dimension_identity name)
let upper_lit n = expect_some "literal upper" (range_upper_lit n)
let upper_dim name = range_upper_dimension (dim_id name)
let bound_const n = expect_some "constant bound" (constant_dim_bound n)
let bound_coll name = collection_length_bound (coll_id name)
let bound_dim name = dimension_bound (dim_id name)

let check_source name expected actual =
  Alcotest.(check bool) name true (expected = actual)

let upper_length_minus coll end_offset =
  expect_some "length-minus upper"
    (range_upper_length_minus ~coll:(coll_id coll) ~end_offset)

let upper_at_most coll = range_upper_at_most_length ~coll:(coll_id coll)

let test_collection_proofs_compare_structurally () =
  let a = coll_subscript (coll_var "matrix") "row" in
  let b = coll_subscript (coll_var "matrix") "row" in
  let c = coll_subscript (coll_var "matrix") "col" in
  Alcotest.(check bool) "same chain" true (proven_collection_equal a b);
  Alcotest.(check bool) "different index" false (proven_collection_equal a c)

let test_collection_identity_smart_constructors () =
  let matrix = expect_some "matrix identity" (collection_identity "matrix") in
  let row = expect_some "row identity" (collection_identity "row") in
  Alcotest.(check string)
    "identity preserves name" "matrix"
    (collection_identity_name matrix);
  Alcotest.(check bool)
    "blank identities are rejected" true
    (Option.is_none (collection_identity " "));
  Alcotest.(check bool)
    "negative dimensions are rejected" true
    (Option.is_none (collection_dim (-1)));
  let a = collection_subscript (collection_var matrix) ~index:row in
  let b = coll_subscript (coll_var "matrix") "row" in
  Alcotest.(check bool)
    "smart collection path matches legacy shape" true
    (proven_collection_equal a b)

let test_collection_proof_queries_hide_shape () =
  let xs = coll_var "xs" in
  let row = coll_subscript xs "row" in
  Alcotest.(check (option string))
    "direct collection var" (Some "xs")
    (Option.map collection_identity_name (direct_collection_var xs));
  Alcotest.(check (option string))
    "subscripted collection is not a direct var" None
    (Option.map collection_identity_name (direct_collection_var row));
  Alcotest.(check bool)
    "constant dimension fits larger size" true
    (collection_dim_at_most (expect_some "dim" (collection_dim 4)) ~size:8);
  Alcotest.(check bool)
    "constant dimension rejects smaller size" false
    (collection_dim_at_most (expect_some "dim" (collection_dim 8)) ~size:4);
  Alcotest.(check bool)
    "collection vars are not constant dimensions" false
    (collection_dim_at_most xs ~size:8)

let test_range_upper_smart_constructors () =
  let xs = expect_some "xs identity" (collection_identity "xs") in
  Alcotest.(check bool)
    "negative literal upper is rejected" true
    (Option.is_none (range_upper_lit (-1)));
  Alcotest.(check bool)
    "negative end offset is rejected" true
    (Option.is_none (range_upper_length_minus ~coll:xs ~end_offset:(-1)));
  Alcotest.(check bool)
    "blank symbolic collection identities are rejected" true
    (Option.is_none (collection_identity " "));
  let upper =
    expect_some "length(xs)-1" (range_upper_length_minus ~coll:xs ~end_offset:1)
  in
  let proof =
    expect_some "0..length(xs)-1"
      (make_range_proof ~range_start:0 ~range_upper:upper)
  in
  Alcotest.(check bool)
    "validated symbolic upper proves same collection" true
    (covers_same_collection proof ~coll:(coll_id "xs"));
  let at_most = range_upper_at_most_length ~coll:xs in
  let proof =
    expect_some "0..length(xs)/k"
      (make_range_proof ~range_start:0 ~range_upper:at_most)
  in
  Alcotest.(check bool)
    "validated at-most upper proves direct collection" true
    (covers_same_collection proof ~coll:(coll_id "xs"))

let test_range_proof_rejects_invalid_bounds () =
  expect_none "negative lower"
    (make_range_proof ~range_start:(-1) ~range_upper:(upper_lit 5));
  expect_none "negative literal upper"
    (Option.bind (range_upper_lit (-1)) (fun upper ->
         make_range_proof ~range_start:0 ~range_upper:upper));
  expect_none "negative symbolic end offset"
    (range_upper_length_minus ~coll:(coll_id "xs") ~end_offset:(-1))

let test_literal_range_proves_constant_dimensions () =
  let proof =
    expect_some "0..5"
      (make_range_proof ~range_start:0 ~range_upper:(upper_lit 5))
  in
  Alcotest.(check bool)
    "fits exact dimension" true
    (covers_const_dim proof ~dim:5);
  Alcotest.(check bool)
    "does not fit smaller dimension" false
    (covers_const_dim proof ~dim:4)

let test_symbolic_range_proves_same_collection () =
  let proof =
    expect_some "length(xs)"
      (make_range_proof ~range_start:0 ~range_upper:(upper_length_minus "xs" 0))
  in
  Alcotest.(check bool)
    "same collection" true
    (covers_same_collection proof ~coll:(coll_id "xs"));
  Alcotest.(check bool)
    "different collection" false
    (covers_same_collection proof ~coll:(coll_id "ys"))

let test_dimension_range_proves_same_dimension () =
  let proof =
    expect_some "0..#N"
      (make_range_proof ~range_start:0 ~range_upper:(upper_dim "#N"))
  in
  Alcotest.(check bool)
    "same dimension" true
    (proves_direct_subscript proof ~bounds:[ bound_dim "#N" ]);
  Alcotest.(check bool)
    "different dimension" false
    (proves_direct_subscript proof ~bounds:[ bound_dim "#M" ]);
  Alcotest.(check bool)
    "dimension proof does not prove offsets" true
    (match
       proves_offset_subscript proof ~bounds:[ bound_dim "#N" ] ~offset:1
     with
    | OffsetRejected OffsetNoMatchingBound -> true
    | OffsetProven | OffsetRejected (OffsetOutOfBounds _) -> false);
  Alcotest.(check bool)
    "non-dimension names are rejected" true
    (Option.is_none (dimension_identity "N"))

let test_offset_checks_are_explicit () =
  let literal =
    expect_some "0..5"
      (make_range_proof ~range_start:0 ~range_upper:(upper_lit 5))
  in
  Alcotest.(check bool)
    "literal offset fits" true
    (Result.is_ok (covers_const_dim_with_offset literal ~dim:6 ~offset:1));
  Alcotest.(check bool)
    "literal offset overflows" true
    (Result.is_error (covers_const_dim_with_offset literal ~dim:5 ~offset:1));
  let symbolic =
    expect_some "0..length(xs)-1"
      (make_range_proof ~range_start:0 ~range_upper:(upper_length_minus "xs" 1))
  in
  Alcotest.(check bool)
    "symbolic offset fits end gap" true
    (covers_same_collection_with_offset symbolic ~coll:(coll_id "xs") ~offset:1);
  Alcotest.(check bool)
    "symbolic offset exceeds end gap" false
    (covers_same_collection_with_offset symbolic ~coll:(coll_id "xs") ~offset:2)

let test_direct_subscript_dispatches_by_proof_shape () =
  let literal =
    expect_some "0..4"
      (make_range_proof ~range_start:0 ~range_upper:(upper_lit 4))
  in
  Alcotest.(check bool)
    "literal proof uses constant dimension" true
    (proves_direct_subscript literal
       ~bounds:[ bound_coll "other"; bound_const 4 ]);
  let symbolic_subrange =
    expect_some "0..length(xs)/2"
      (make_range_proof ~range_start:0 ~range_upper:(upper_at_most "xs"))
  in
  Alcotest.(check bool)
    "symbolic subrange proof uses collection identity" true
    (proves_direct_subscript symbolic_subrange
       ~bounds:[ bound_const 0; bound_coll "xs" ])

let test_offset_subscript_dispatches_by_proof_shape () =
  let literal =
    expect_some "0..4"
      (make_range_proof ~range_start:0 ~range_upper:(upper_lit 4))
  in
  Alcotest.(check bool)
    "literal offset reports concrete overflow" true
    (match
       proves_offset_subscript literal ~bounds:[ bound_const 4 ] ~offset:1
     with
    | OffsetRejected (OffsetOutOfBounds msg) -> String.length msg > 0
    | _ -> false);
  let symbolic =
    expect_some "0..length(xs)-1"
      (make_range_proof ~range_start:0 ~range_upper:(upper_length_minus "xs" 1))
  in
  Alcotest.(check bool)
    "symbolic offset uses collection end gap" true
    (match
       proves_offset_subscript symbolic
         ~bounds:[ bound_const 0; bound_coll "xs" ]
         ~offset:1
     with
    | OffsetProven -> true
    | OffsetRejected _ -> false);
  let at_most_length =
    expect_some "0..length(xs)/2"
      (make_range_proof ~range_start:0 ~range_upper:(upper_at_most "xs"))
  in
  Alcotest.(check bool)
    "at-most-length proof does not prove offsets" true
    (match
       proves_offset_subscript at_most_length
         ~bounds:[ bound_coll "xs" ]
         ~offset:1
     with
    | OffsetProven -> false
    | OffsetRejected OffsetNoMatchingBound -> true
    | OffsetRejected (OffsetOutOfBounds _) -> false)

let test_subscript_bounds_have_smart_constructors () =
  let bounds = subscript_bounds [ bound_const 4; bound_coll "xs" ] in
  let literal =
    expect_some "0..4"
      (make_range_proof ~range_start:0 ~range_upper:(upper_lit 4))
  in
  Alcotest.(check bool)
    "private bounds prove direct subscript" true
    (proves_direct_subscript_with_bounds literal ~bounds);
  Alcotest.(check bool)
    "negative dimensions are rejected" true
    (Option.is_none (constant_dim_bound (-1)));
  Alcotest.(check bool)
    "blank collection identities are rejected" true
    (Option.is_none (collection_identity ""))

let test_proof_env_replaces_shadowed_proofs () =
  let i = coll_id "i" in
  let xs = coll_var "xs" in
  let ys = coll_var "ys" in
  let env =
    empty_proof_env
    |> proof_env_add_subscript ~var:i ~collection:xs
    |> proof_env_add_subscript ~var:i ~collection:ys
    |> proof_env_add_range_bounds ~var:i ~range_start:0
         ~range_upper:(upper_lit 4)
    |> proof_env_add_range_bounds ~var:i ~range_start:0
         ~range_upper:(upper_lit 8)
  in
  let binding =
    proof_env_apply_subscript_to_binding env ~var:i unrefined_binding
  in
  Alcotest.(check bool)
    "latest subscript proof replaces older same-variable proof" true
    (binding_proves_subscript binding ~collection:ys);
  Alcotest.(check bool)
    "older subscript proof is shadowed" false
    (binding_proves_subscript binding ~collection:xs);
  let latest_range =
    expect_some "latest range proof" (proof_env_find_range env ~var:i)
  in
  Alcotest.(check bool)
    "latest range proof replaces older same-variable proof" true
    (proves_direct_subscript latest_range ~bounds:[ bound_const 8 ]);
  Alcotest.(check bool)
    "older range proof is shadowed" false
    (proves_direct_subscript latest_range ~bounds:[ bound_const 4 ]);
  let env =
    env |> proof_env_without_subscript ~var:i |> proof_env_without_range ~var:i
  in
  let binding =
    proof_env_apply_subscript_to_binding env ~var:i unrefined_binding
  in
  Alcotest.(check bool)
    "forgetting a variable removes subscript proof" false
    (binding_proves_subscript binding ~collection:ys);
  Alcotest.(check bool)
    "forgetting a variable removes range proof" false
    (Option.is_some (proof_env_find_range env ~var:i))

let test_range_proofs_carry_sources () =
  let i = coll_id "i" in
  let j = coll_id "j" in
  let explicit =
    expect_some "sourced range"
      (make_range_proof_with_source ~source:ProofSourceLoopRange ~range_start:0
         ~range_upper:(upper_lit 4))
  in
  check_source "range proof source" ProofSourceLoopRange
    (range_proof_source explicit);
  let env =
    empty_proof_env
    |> proof_env_add_range_bounds ~source:ProofSourceLoopRange ~var:i
         ~range_start:0 ~range_upper:(upper_lit 4)
  in
  let found =
    expect_some "stored sourced range" (proof_env_find_range env ~var:i)
  in
  check_source "stored range source" ProofSourceLoopRange
    (range_proof_source found);
  let env =
    proof_env_add_range_bounds ~source:ProofSourceLoopIndices env ~var:j
      ~range_start:0 ~range_upper:(upper_lit 8)
  in
  let found =
    expect_some "range bounds source" (proof_env_find_range env ~var:j)
  in
  check_source "range bounds source" ProofSourceLoopIndices
    (range_proof_source found)

let test_subscript_proofs_carry_sources () =
  let i = coll_id "i" in
  let xs = coll_var "xs" in
  let ys = coll_var "ys" in
  let proof =
    make_subscript_proof ~source:ProofSourceLoopEnumerate ~collection:xs
  in
  check_source "subscript proof source" ProofSourceLoopEnumerate
    (subscript_proof_source proof);
  let env =
    empty_proof_env
    |> proof_env_add_subscript ~source:ProofSourceLoopEnumerate ~var:i
         ~collection:xs
  in
  let binding =
    proof_env_apply_subscript_to_binding env ~var:i unrefined_binding
  in
  Alcotest.(check bool)
    "sourced subscript proof still proves collection" true
    (binding_proves_subscript binding ~collection:xs);
  let env =
    proof_env_add_subscript ~source:ProofSourceLoopIndices env ~var:i
      ~collection:ys
  in
  let binding =
    proof_env_apply_subscript_to_binding env ~var:i unrefined_binding
  in
  Alcotest.(check bool)
    "replacement subscript proof is mirrored to binding" true
    (binding_proves_subscript binding ~collection:ys);
  Alcotest.(check bool)
    "shadowed subscript proof is removed before mirroring" false
    (binding_proves_subscript binding ~collection:xs)

let test_binding_refinement_carries_range_and_subscript_proofs () =
  let range =
    expect_some "0..4"
      (make_range_proof_with_source ~source:ProofSourceLoopRange ~range_start:0
         ~range_upper:(upper_lit 4))
  in
  let binding =
    binding_add_range_proof unrefined_binding range
    |> binding_add_subscript_proof ~source:ProofSourceLoopIndices
         ~collection:(coll_var "xs")
  in
  Alcotest.(check bool)
    "binding stores range proof" true
    (match binding_range_proof binding with
    | Some actual -> actual = range
    | None -> false);
  Alcotest.(check bool)
    "binding proves direct collection" true
    (binding_proves_subscript binding ~collection:(coll_var "xs"));
  Alcotest.(check bool)
    "binding rejects different collection" false
    (binding_proves_subscript binding ~collection:(coll_var "ys"));
  Alcotest.(check bool)
    "binding exposes direct collection vars" true
    (List.exists
       (fun identity -> String.equal (collection_identity_name identity) "xs")
       (binding_direct_collection_vars binding));
  Alcotest.(check bool)
    "binding proves direct range" true
    (binding_proves_direct_range binding
       ~bounds:
         [
           expect_some "constant dim" (constant_dim_bound 4);
           collection_length_bound (coll_id "xs");
         ]);
  let offset_range =
    expect_some "1..4"
      (make_range_proof_with_source ~source:ProofSourceLoopRange ~range_start:1
         ~range_upper:(upper_lit 4))
  in
  let offset_binding = range_binding offset_range in
  Alcotest.(check bool)
    "binding proves negative offset within range" true
    (match
       binding_proves_offset_range offset_binding
         ~bounds:[ expect_some "constant dim" (constant_dim_bound 4) ]
         ~offset:(-1)
     with
    | OffsetProven -> true
    | OffsetRejected _ -> false);
  Alcotest.(check bool)
    "binding reports offset out of bounds" true
    (match
       binding_proves_offset_range offset_binding
         ~bounds:[ expect_some "constant dim" (constant_dim_bound 4) ]
         ~offset:1
     with
    | OffsetRejected (OffsetOutOfBounds _) -> true
    | OffsetProven | OffsetRejected OffsetNoMatchingBound -> false)

let test_proof_env_can_mirror_subscript_facts_to_binding () =
  let i = coll_id "i" in
  let env =
    empty_proof_env
    |> proof_env_add_subscript ~source:ProofSourceLoopEnumerate ~var:i
         ~collection:(coll_var "xs")
  in
  let binding =
    proof_env_apply_subscript_to_binding env ~var:i unrefined_binding
  in
  Alcotest.(check bool)
    "mirrored binding proves collection" true
    (binding_proves_subscript binding ~collection:(coll_var "xs"))

let test_branch_narrowing_rejects_mutable_subjects () =
  let immutable = expect_some "immutable subject" (immutable_subject "i") in
  let proof =
    match
      make_branch_range_proof immutable ~range_start:0
        ~range_upper:(upper_lit 10)
    with
    | Ok proof -> proof
    | Error _ -> Alcotest.fail "immutable subject should produce a proof"
  in
  Alcotest.(check bool)
    "immutable proof keeps direct subject" true
    (match branch_range_subject proof with
    | NarrowedBinding identity ->
        String.equal (collection_identity_name identity) "i"
    | _ -> false);
  Alcotest.(check bool)
    "branch proof reuses range proof decisions" true
    (proves_direct_subscript (branch_range_proof proof)
       ~bounds:[ bound_const 10 ]);
  let alias =
    expect_some "immutable alias"
      (immutable_alias_subject ~alias:"j" ~target:"i")
  in
  let alias_proof =
    match
      make_branch_range_proof alias ~range_start:0 ~range_upper:(upper_lit 10)
    with
    | Ok proof -> proof
    | Error _ -> Alcotest.fail "immutable alias should produce a proof"
  in
  Alcotest.(check bool)
    "immutable alias proof records alias target" true
    (match branch_range_subject alias_proof with
    | NarrowedAlias { alias; target } ->
        String.equal (collection_identity_name alias) "j"
        && String.equal (collection_identity_name target) "i"
    | _ -> false);
  let mutable_subject = expect_some "mutable subject" (mutable_subject "i") in
  Alcotest.(check bool)
    "mutable subject cannot produce branch proof" true
    (match
       make_branch_range_proof mutable_subject ~range_start:0
         ~range_upper:(upper_lit 10)
     with
    | Error MutableSubjectCannotNarrow -> true
    | _ -> false);
  Alcotest.(check bool)
    "blank subject names are rejected" true
    (Option.is_none (immutable_subject ""))

let suite =
  [
    ( "proofs",
      [
        Alcotest.test_case "collection proofs compare structurally" `Quick
          test_collection_proofs_compare_structurally;
        Alcotest.test_case "collection identity smart constructors" `Quick
          test_collection_identity_smart_constructors;
        Alcotest.test_case "collection proof queries hide shape" `Quick
          test_collection_proof_queries_hide_shape;
        Alcotest.test_case "range upper smart constructors" `Quick
          test_range_upper_smart_constructors;
        Alcotest.test_case "range proof rejects invalid bounds" `Quick
          test_range_proof_rejects_invalid_bounds;
        Alcotest.test_case "literal range proves constant dimensions" `Quick
          test_literal_range_proves_constant_dimensions;
        Alcotest.test_case "symbolic range proves same collection" `Quick
          test_symbolic_range_proves_same_collection;
        Alcotest.test_case "dimension range proves same dimension" `Quick
          test_dimension_range_proves_same_dimension;
        Alcotest.test_case "offset checks are explicit" `Quick
          test_offset_checks_are_explicit;
        Alcotest.test_case "direct subscript dispatches by proof shape" `Quick
          test_direct_subscript_dispatches_by_proof_shape;
        Alcotest.test_case "offset subscript dispatches by proof shape" `Quick
          test_offset_subscript_dispatches_by_proof_shape;
        Alcotest.test_case "subscript bounds have smart constructors" `Quick
          test_subscript_bounds_have_smart_constructors;
        Alcotest.test_case "proof env replaces shadowed proofs" `Quick
          test_proof_env_replaces_shadowed_proofs;
        Alcotest.test_case "range proofs carry sources" `Quick
          test_range_proofs_carry_sources;
        Alcotest.test_case "subscript proofs carry sources" `Quick
          test_subscript_proofs_carry_sources;
        Alcotest.test_case "binding refinement carries proof bundle" `Quick
          test_binding_refinement_carries_range_and_subscript_proofs;
        Alcotest.test_case "proof env mirrors subscript facts to binding" `Quick
          test_proof_env_can_mirror_subscript_facts_to_binding;
        Alcotest.test_case "branch narrowing rejects mutable subjects" `Quick
          test_branch_narrowing_rejects_mutable_subjects;
      ] );
  ]
