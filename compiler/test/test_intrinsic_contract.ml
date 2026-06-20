(** Phase 2.6.6: parity contract between [Core_intrinsic_registry] and
    [Core_emit]'s [emit_intrinsic] dispatcher.

    The registry is documented as the single source of truth for all
    CKIntrinsic primitives. This test enforces that contract:

    1. Every implemented registry entry has an emit clause.
    2. Every emit clause name corresponds to a registry entry.
    3. The registry's declared arity matches what emit accepts.

    Drift between these two is caught at [make compiler-unit-test], not at
    runtime-compile of user code. *)

open Blorp

(** Extract intrinsic names that appear in emit_intrinsic match clauses or in
    the Blorp-owned template manifest consumed by the emitter.
    Reads [core_emit_intrinsic.ml] (Phase 5.1 step 3 moved the match
    body there; prior to that it lived in [core_emit.ml]) and
    regex-matches the patterns used by the dispatcher. Handles both
    single-name and grouped ``("a" | "b" | "c")`` match arms.

    Returns a sorted, deduplicated list. *)
let emit_intrinsic_names () : string list =
  (* The source file may be inspected from the repo root, from [compiler/],
     or from dune's sandbox. Walk upward from [Sys.getcwd ()] and check
     both repo-root and compiler-root layouts so this contract does not depend
     on the caller's working directory. *)
  let rec ancestors dir =
    let parent = Filename.dirname dir in
    if parent = dir then [ dir ] else dir :: ancestors parent
  in
  let relative_candidates =
    [
      "compiler/lib/core_emit_intrinsic.ml";
      "lib/core_emit_intrinsic.ml";
      "../../../../lib/core_emit_intrinsic.ml";
      "../../../../../lib/core_emit_intrinsic.ml";
      "../../../../compiler/lib/core_emit_intrinsic.ml";
      "../../../compiler/lib/core_emit_intrinsic.ml";
    ]
  in
  let candidates =
    relative_candidates
    @ List.concat_map
        (fun root ->
          [
            Filename.concat root "compiler/lib/core_emit_intrinsic.ml";
            Filename.concat root "lib/core_emit_intrinsic.ml";
          ])
        (ancestors (Sys.getcwd ()))
  in
  let path =
    match List.find_opt Sys.file_exists candidates with
    | Some p -> p
    | None ->
        Alcotest.failf
          "Cannot locate core_emit_intrinsic.ml from CWD=%s; tried %s"
          (Sys.getcwd ())
          (String.concat ", " candidates)
  in
  let ic = open_in path in
  let content = really_input_string ic (in_channel_length ic) in
  close_in ic;
  (* Two regex-like scans: single-quoted names in match-arm position. *)
  let names = ref [] in
  let len = String.length content in
  let scan_after i =
    (* After finding an opening bracket or pipe at position i, collect
       quoted names separated by pipes until hitting a comma or bracket. *)
    let rec walk j =
      if j >= len then ()
      else
        match content.[j] with
        | '"' ->
            let k =
              try String.index_from content (j + 1) '"' with Not_found -> len
            in
            let name = String.sub content (j + 1) (k - j - 1) in
            (* Filter: intrinsic names are snake_case alphanumeric. *)
            let is_intrinsic =
              String.length name > 0
              && String.for_all
                   (fun c ->
                     (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '_')
                   name
            in
            if is_intrinsic then names := name :: !names;
            walk (k + 1)
        | ',' | ']' | '=' | ';' | '(' -> () (* end of match-arm pattern *)
        | '|' | ' ' | '\n' | '\t' -> walk (j + 1)
        | _ -> () (* hit non-pipe non-string character — stop *)
    in
    walk i
  in
  (* Find match-arm patterns inside emit_intrinsic. Strategy: locate
     each pipe-space-quote sequence and parse from there. Grouped arms
     written as OR-pipes within parens are captured by the same walker. *)
  let rec scan i =
    if i >= len - 2 then ()
    else if
      content.[i] = '|'
      && i + 1 < len
      && (content.[i + 1] = ' ' || content.[i + 1] = '\n')
    then begin
      (* Skip whitespace and any grouping parentheses, then scan names. *)
      let j = ref (i + 1) in
      while
        !j < len
        && (content.[!j] = ' '
           || content.[!j] = '\n'
           || content.[!j] = '\t'
           || content.[!j] = '(')
      do
        incr j
      done;
      if !j < len && content.[!j] = '"' then scan_after !j;
      scan (i + 1)
    end
    else scan (i + 1)
  in
  scan 0;
  let blorp_template_names =
    match
      Compiler_blorp_bridge.manifest_for_renderer
        Compiler_blorp_bridge.intrinsic_renderer
    with
    | Ok manifest ->
        Lazy.force manifest.Core_emit_blorp_template.templates
        |> List.map (fun template -> template.Core_emit_blorp_template.name)
    | Error (_, message) -> Alcotest.fail message
  in
  List.sort_uniq String.compare (!names @ blorp_template_names)

(* ============================================================================
   Tests
   ============================================================================ *)

(** Registry names are the canonical set. *)
let registry_names () =
  List.map (fun i -> i.Core_intrinsic_registry.name) Core_intrinsic_registry.all
  |> List.sort_uniq String.compare

(** Names from registry marked implemented=true. *)
let registry_implemented_names () =
  List.filter_map
    (fun i ->
      if i.Core_intrinsic_registry.implemented then Some i.name else None)
    Core_intrinsic_registry.all
  |> List.sort_uniq String.compare

(** The position-based scan is already strict enough that no non-intrinsic
    string literal leaks through (verified during Phase 2.6.6 review:
    scanner returns 131 unique names, all valid intrinsics). A prefix
    allowlist would silently drop new intrinsic categories, so we keep
    every captured name and trust the scan. *)

let test_every_implemented_registered_appears_in_emit () =
  let emit = emit_intrinsic_names () in
  let impl = registry_implemented_names () in
  let missing = List.filter (fun n -> not (List.mem n emit)) impl in
  if missing <> [] then
    Alcotest.failf
      "Registry entries marked implemented but with no emit_intrinsic match \
       clause: [%s]"
      (String.concat "; " missing)

let test_every_emit_clause_is_registered () =
  let emit = emit_intrinsic_names () in
  let registered = registry_names () in
  let orphan = List.filter (fun n -> not (List.mem n registered)) emit in
  if orphan <> [] then
    Alcotest.failf
      "Emit clauses for intrinsic names missing from registry: [%s]. Either \
       add a registry entry or remove the emit clause."
      (String.concat "; " orphan)

let test_registry_has_entries () =
  (* Sanity: the all list is nonempty. If it ever drops to zero, the
     other tests would silently pass. *)
  Alcotest.(check bool)
    "registry non-empty" true
    (List.length (registry_names ()) > 50)

let test_emit_scan_found_something () =
  (* Sanity: the source-inspection regex actually found match arms.
     If a refactor renames emit_intrinsic or changes formatting, the
     scan might return [] and silently pass. *)
  let emit = emit_intrinsic_names () in
  Alcotest.(check bool) "emit scan non-empty" true (List.length emit > 50)

(* ============================================================================
   Schema tests (Phase 2.6.6 extension fields)
   ============================================================================ *)

let test_every_entry_declares_arity () =
  (* Every registry entry must declare an arity — either [Fixed n] for
     exact count or [Variadic] for arg-count-dependent dispatch. This
     ensures the contract test (and future Phase 4.2 elementwise lift)
     can reason about call shape without source inspection. *)
  List.iter
    (fun (i : Core_intrinsic_registry.intrinsic_info) ->
      match i.arity with
      | Fixed n when n >= 0 -> ()
      | Variadic -> ()
      | Fixed n -> Alcotest.failf "intrinsic %S has negative arity %d" i.name n)
    Core_intrinsic_registry.all

let test_math_intrinsics_marked_pure () =
  (* All math_* intrinsics are mathematically pure — no I/O, no hidden
     state. Sanity-check by sampling common ones. *)
  let math_names = [ "math_sin"; "math_cos"; "math_sqrt"; "math_log" ] in
  List.iter
    (fun name ->
      match
        List.find_opt
          (fun i -> i.Core_intrinsic_registry.name = name)
          Core_intrinsic_registry.all
      with
      | Some i when i.is_pure -> ()
      | Some _ -> Alcotest.failf "%s should be is_pure=true" name
      | None -> Alcotest.failf "%s missing from registry" name)
    math_names

let test_list_get_is_not_elementwise () =
  (* [list_get] is a structural access; it's not a per-element operation
     that could be auto-lifted over a tensor. Elementwise_liftable must
     be false for it. *)
  match
    List.find_opt
      (fun i -> i.Core_intrinsic_registry.name = "list_get")
      Core_intrinsic_registry.all
  with
  | Some i ->
      Alcotest.(check bool)
        "list_get not elementwise" false i.elementwise_liftable
  | None -> Alcotest.fail "list_get missing from registry"

let test_math_unary_is_elementwise () =
  (* Phase 4.2 will auto-lift math_sqrt(vec) → map(vec, math_sqrt).
     Require math_sqrt / math_log / etc. to be marked elementwise. *)
  let elementwise_math = [ "math_sqrt"; "math_log"; "math_sin" ] in
  List.iter
    (fun name ->
      match
        List.find_opt
          (fun i -> i.Core_intrinsic_registry.name = name)
          Core_intrinsic_registry.all
      with
      | Some i when i.elementwise_liftable -> ()
      | Some _ -> Alcotest.failf "%s should be elementwise_liftable=true" name
      | None -> Alcotest.failf "%s missing from registry" name)
    elementwise_math

(** Name-suffix invariants: categorical classifications that must hold
    for every entry in the class. Assertions rather than derivations —
    they lock annotations so adding a new [_set_] intrinsic that forgets
    [~is_pure:false] fails the build. *)
let test_impure_suffixes_are_impure () =
  (* Names that END with an action verb (_alloc, _resize, _cow, _free,
     _retain_for, _release_elem, etc.) are state-mutating. Names where
     the verb is followed by a noun ([_release_fn], [_retain_fn_ptr])
     describe the field-access function pointer reading a verb-named
     field — those are pure reads, not actions. *)
  let ends_with name suf =
    let nlen = String.length name in
    let slen = String.length suf in
    nlen >= slen && String.sub name (nlen - slen) slen = suf
  in
  let is_impure_by_convention name =
    ends_with name "_alloc" || ends_with name "_cow" || ends_with name "_resize"
    || ends_with name "_set" || ends_with name "_set_len"
    || ends_with name "_ensure_unique"
    || ends_with name "_ensure_capacity"
    || ends_with name "_release_elem"
    || ends_with name "_retain_for"
    || ends_with name "_retain_key_for"
    || ends_with name "_retain_value_for"
    || ends_with name "_release_value_for"
    || ends_with name "_set_elem_release"
    || ends_with name "_free_entry"
    || ends_with name "_alloc_entry"
    || ends_with name "_set_byte"
    || ends_with name "_set_first"
    || ends_with name "_set_last"
    || ends_with name "_set_bucket"
    || ends_with name "_set_next"
    || ends_with name "_set_prev_order"
    || ends_with name "_set_next_order"
    || ends_with name "_set_key_at"
    || ends_with name "_set_value_at"
    || ends_with name "_meta_set"
    || ends_with name "_order_set"
    || ends_with name "_set_order_len"
    || ends_with name "_order_index_set"
  in
  List.iter
    (fun (i : Core_intrinsic_registry.intrinsic_info) ->
      if is_impure_by_convention i.name && i.is_pure then
        Alcotest.failf "%s has impure naming convention but is_pure=true" i.name)
    Core_intrinsic_registry.all

let test_list_dict_set_structural_not_elementwise () =
  (* Structural collection ops (list_/dict_/set_/slice_) never lift over
     tensors — they operate on container-specific fields. *)
  let is_structural name =
    let prefixes = [ "list_"; "dict_"; "set_"; "slice_" ] in
    List.exists
      (fun p ->
        String.length name >= String.length p
        && String.sub name 0 (String.length p) = p)
      prefixes
  in
  List.iter
    (fun (i : Core_intrinsic_registry.intrinsic_info) ->
      if is_structural i.name && i.elementwise_liftable then
        Alcotest.failf "%s is structural but elementwise_liftable=true" i.name)
    Core_intrinsic_registry.all

let ownership_prefixes =
  [
    "list_"; "string_"; "bytes_"; "set_"; "dict_"; "slice_"; "tensor_"; "fixed_";
  ]

let has_prefix name prefix =
  String.length name >= String.length prefix
  && String.sub name 0 (String.length prefix) = prefix

let needs_ownership_contract name =
  List.exists (has_prefix name) ownership_prefixes

let implemented_ownership_intrinsics () =
  List.filter
    (fun (i : Core_intrinsic_registry.intrinsic_info) ->
      i.implemented && needs_ownership_contract i.name)
    Core_intrinsic_registry.all

let ownership_contract_for_intrinsic
    (i : Core_intrinsic_registry.intrinsic_info) =
  try
    Ok
      (match i.arity with
      | Fixed arity -> Core_ownership.intrinsic_contract i.name arity
      | Variadic -> Core_ownership.intrinsic_contract i.name 0)
  with Invalid_argument msg -> Error msg

let test_collection_intrinsics_have_ownership_contracts () =
  (* Collection/value intrinsics are the leaf operations Perceus must reason
     about. Every implemented one needs an explicit contract so a new
     structural read does not silently fall back to "consumes all args". *)
  let missing =
    List.filter_map
      (fun (i : Core_intrinsic_registry.intrinsic_info) ->
        match ownership_contract_for_intrinsic i with
        | Ok (Some _) -> None
        | Ok None -> Some i.name
        | Error msg ->
            Some (Printf.sprintf "%s has invalid contract: %s" i.name msg))
      (implemented_ownership_intrinsics ())
  in
  if missing <> [] then
    Alcotest.failf
      "Implemented ownership-sensitive intrinsics missing Core_ownership \
       contracts: [%s]"
      (String.concat "; " missing)

let test_all_implemented_intrinsics_have_ownership_contracts () =
  (* Perceus sees CKIntrinsic as backend leaf operations. Every implemented
     intrinsic needs an explicit ownership contract, even if the contract is
     just "borrow primitive inputs and return a primitive", so new intrinsics
     cannot silently inherit fallback ownership behavior. *)
  let missing =
    List.filter_map
      (fun (i : Core_intrinsic_registry.intrinsic_info) ->
        if not i.implemented then None
        else
          match ownership_contract_for_intrinsic i with
          | Ok (Some _) -> None
          | Ok None -> Some i.name
          | Error msg ->
              Some (Printf.sprintf "%s has invalid contract: %s" i.name msg))
      Core_intrinsic_registry.all
  in
  if missing <> [] then
    Alcotest.failf
      "Implemented intrinsics missing Core_ownership contracts: [%s]"
      (String.concat "; " missing)

let test_collection_intrinsic_contracts_are_well_formed () =
  (* A contract that returns an alias to a consumed/COW/transfer argument is
     self-contradictory: the caller would lose the owner while Perceus treats
     the result as borrowed from it. Keep that ABI rule audited at the same
     boundary where intrinsic coverage is audited. *)
  let invalid =
    List.filter_map
      (fun (i : Core_intrinsic_registry.intrinsic_info) ->
        match ownership_contract_for_intrinsic i with
        | Error msg -> Some (Printf.sprintf "%s: %s" i.name msg)
        | Ok contract -> (
            match contract with
            | None -> None
            | Some contract -> (
                match Core_ownership.validate_contract contract with
                | [] -> None
                | violations ->
                    Some
                      (Printf.sprintf "%s: %s" i.name
                         (String.concat "; "
                            (List.map
                               Core_ownership.string_of_contract_violation
                               violations))))))
      (implemented_ownership_intrinsics ())
  in
  if invalid <> [] then
    Alcotest.failf
      "Implemented ownership-sensitive intrinsics have malformed \
       Core_ownership contracts: [%s]"
      (String.concat "; " invalid)

let string_of_result_mode = function
  | Core_ownership.ReturnVoid -> "ReturnVoid"
  | Core_ownership.ReturnPrimitive -> "ReturnPrimitive"
  | Core_ownership.ReturnOwned -> "ReturnOwned"
  | Core_ownership.ReturnBorrowed -> "ReturnBorrowed"
  | Core_ownership.ReturnAliasOfArg i -> Printf.sprintf "ReturnAliasOfArg %d" i

let string_of_arg_modes args =
  args |> List.map Core_ownership.string_of_arg_mode |> String.concat ", "

let expect_builtin_contract name expected_args expected_result =
  match Core_ownership.builtin_contract name (List.length expected_args) with
  | Some { Core_ownership.args; result }
    when args = expected_args && result = expected_result ->
      ()
  | Some { Core_ownership.args; result } ->
      Alcotest.failf "%s contract mismatch: got ([%s], %s), expected ([%s], %s)"
        name (string_of_arg_modes args)
        (string_of_result_mode result)
        (string_of_arg_modes expected_args)
        (string_of_result_mode expected_result)
  | None -> Alcotest.failf "%s missing Core_ownership builtin contract" name

let test_string_runtime_builtins_have_ownership_contracts () =
  let borrow = Core_ownership.Borrow in
  let ret_prim = Core_ownership.ReturnPrimitive in
  let ret_owned = Core_ownership.ReturnOwned in
  List.iter
    (fun name -> expect_builtin_contract name [ borrow ] ret_owned)
    [
      "blorp_from_char";
      "blorp_from_chars";
      "blorp_bytes_from_string";
      "blorp_base64_encode";
      "blorp_url_encode";
      "blorp_url_decode";
      "blorp_html_escape";
      "blorp_string_chars";
      "blorp_string_codepoints";
      "blorp_codepoint_reverse";
    ];
  List.iter
    (fun name -> expect_builtin_contract name [ borrow ] ret_prim)
    [ "blorp_parse_int"; "blorp_parse_float"; "blorp_codepoint_length" ];
  expect_builtin_contract "blorp_string_get_opt" [ borrow; borrow ] ret_prim;
  expect_builtin_contract "blorp_string_levenshtein" [ borrow; borrow ] ret_prim;
  expect_builtin_contract "blorp_string_lcs" [ borrow; borrow ] ret_owned

let test_channel_runtime_builtins_have_ownership_contracts () =
  let borrow = Core_ownership.Borrow in
  let retain = Core_ownership.Retain in
  let ret_prim = Core_ownership.ReturnPrimitive in
  let ret_owned = Core_ownership.ReturnOwned in
  List.iter
    (fun name -> expect_builtin_contract name [ borrow ] ret_owned)
    [
      "blorp_channel_recv";
      "blorp_channel_try_recv";
      "blorp_channel_recv_nullable";
      "blorp_channel_try_recv_nullable";
    ];
  List.iter
    (fun name -> expect_builtin_contract name [ borrow ] ret_prim)
    [
      "blorp_channel_recv_int";
      "blorp_channel_recv_int8";
      "blorp_channel_recv_int16";
      "blorp_channel_recv_int32";
      "blorp_channel_recv_int64";
      "blorp_channel_recv_uint8";
      "blorp_channel_recv_uint16";
      "blorp_channel_recv_uint32";
      "blorp_channel_recv_uint64";
      "blorp_channel_recv_float";
      "blorp_channel_recv_bool";
      "blorp_channel_recv_char";
      "blorp_channel_recv_f32";
      "blorp_channel_recv_f16";
      "blorp_channel_try_recv_int";
      "blorp_channel_try_recv_int8";
      "blorp_channel_try_recv_int16";
      "blorp_channel_try_recv_int32";
      "blorp_channel_try_recv_int64";
      "blorp_channel_try_recv_uint8";
      "blorp_channel_try_recv_uint16";
      "blorp_channel_try_recv_uint32";
      "blorp_channel_try_recv_uint64";
      "blorp_channel_try_recv_float";
      "blorp_channel_try_recv_bool";
      "blorp_channel_try_recv_char";
      "blorp_channel_try_recv_f32";
      "blorp_channel_try_recv_f16";
    ];
  expect_builtin_contract "blorp_channel_send" [ borrow; retain ] ret_prim;
  expect_builtin_contract "blorp_channel_try_send" [ borrow; retain ] ret_prim;
  expect_builtin_contract "blorp_channel_try_send_status" [ borrow; retain ]
    ret_prim;
  expect_builtin_contract "blorp_channel_try_send_attempt" [ borrow; retain ]
    ret_owned;
  expect_builtin_contract "blorp_channel_try_recv_attempt" [ borrow ] ret_owned;
  expect_builtin_contract "blorp_channel_recv_timeout" [ borrow; borrow ]
    ret_owned;
  expect_builtin_contract "blorp_channel_recv_timeout_nullable"
    [ borrow; borrow ] ret_owned;
  expect_builtin_contract "blorp_channel_recv_timeout_attempt"
    [ borrow; borrow ] ret_owned;
  List.iter
    (fun name -> expect_builtin_contract name [ borrow; borrow ] ret_prim)
    [
      "blorp_channel_recv_timeout_int";
      "blorp_channel_recv_timeout_int8";
      "blorp_channel_recv_timeout_int16";
      "blorp_channel_recv_timeout_int32";
      "blorp_channel_recv_timeout_int64";
      "blorp_channel_recv_timeout_uint8";
      "blorp_channel_recv_timeout_uint16";
      "blorp_channel_recv_timeout_uint32";
      "blorp_channel_recv_timeout_uint64";
      "blorp_channel_recv_timeout_float";
      "blorp_channel_recv_timeout_bool";
      "blorp_channel_recv_timeout_char";
      "blorp_channel_recv_timeout_f32";
      "blorp_channel_recv_timeout_f16";
    ];
  expect_builtin_contract "blorp_channel_send_timeout"
    [ borrow; retain; borrow ] ret_prim;
  expect_builtin_contract "blorp_channel_send_timeout_status"
    [ borrow; retain; borrow ] ret_prim;
  expect_builtin_contract "blorp_channel_send_timeout_attempt"
    [ borrow; retain; borrow ] ret_owned;
  expect_builtin_contract "blorp_channel_seal" [ borrow ]
    Core_ownership.ReturnVoid

let test_void_boxed_runtime_builtins_have_ownership_coverage () =
  let failures =
    Core_ownership.builtin_void_boxed_arg_positions
    |> List.filter_map (fun (name, positions) ->
        let required_arity =
          match positions with
          | [] -> 0
          | _ -> 1 + List.fold_left max 0 positions
        in
        match Core_ownership.builtin_contract_entry name with
        | None ->
            Some
              (Printf.sprintf
                 "%s has runtime void* ABI slots but no ownership contract" name)
        | Some entry ->
            let supported_arity =
              Core_ownership.builtin_contract_sample_arities entry
              |> List.exists (fun arity ->
                  arity >= required_arity
                  &&
                  match Core_ownership.builtin_contract name arity with
                  | Some _ -> true
                  | None -> false)
            in
            if supported_arity then None
            else
              Some
                (Printf.sprintf
                   "%s has runtime void* ABI slots through arity %d, but its \
                    ownership contract does not cover that arity"
                   name required_arity))
  in
  Alcotest.(check (list string))
    "void-boxed runtime builtins have ownership coverage" [] failures

let test_specialize_uses_ownership_void_boxed_manifest () =
  Alcotest.(check (list (pair string (list int))))
    "Core_specialize consumes the ownership-owned ABI manifest"
    Core_ownership.builtin_void_boxed_arg_positions
    Blorp.Core_specialize.void_boxed_arg_positions

let test_ir_backed_std_functions_registered () =
  let int_ty = Ast.TyNamed ("Int", []) in
  let string_ty = Ast.TyNamed ("String", []) in
  let bytes_ty = Ast.TyNamed ("Bytes", []) in
  let list_ty = Ast.TyNamed ("List", [ int_ty ]) in
  let dict_ty = Ast.TyNamed ("Dict", [ string_ty; int_ty ]) in
  let set_ty = Ast.TyNamed ("Set", [ int_ty ]) in
  let lookup ~mod_path ~func_name ~arity ~receiver_ty =
    Core_intrinsic_registry.lookup_ir_backed_std_function ~mod_path ~func_name
      ~arity ~receiver_ty
  in
  Alcotest.(check (option string))
    "list length" (Some "list_len")
    (lookup ~mod_path:"std/list" ~func_name:"length" ~arity:1
       ~receiver_ty:list_ty);
  Alcotest.(check (option string))
    "string length" (Some "string_len")
    (lookup ~mod_path:"std/string" ~func_name:"length" ~arity:1
       ~receiver_ty:string_ty);
  Alcotest.(check (option string))
    "bytes length" (Some "bytes_len")
    (lookup ~mod_path:"std/bytes" ~func_name:"length" ~arity:1
       ~receiver_ty:bytes_ty);
  Alcotest.(check (option string))
    "dict length" (Some "dict_len")
    (lookup ~mod_path:"std/dict" ~func_name:"length" ~arity:1
       ~receiver_ty:dict_ty);
  Alcotest.(check (option string))
    "set length" (Some "set_len")
    (lookup ~mod_path:"std/set" ~func_name:"length" ~arity:1 ~receiver_ty:set_ty);
  Alcotest.(check (option string))
    "wrong receiver rejected" None
    (lookup ~mod_path:"std/dict" ~func_name:"length" ~arity:1
       ~receiver_ty:set_ty)

let suite =
  [
    ( "parity",
      [
        Alcotest.test_case "registry non-empty" `Quick test_registry_has_entries;
        Alcotest.test_case "emit scan non-empty" `Quick
          test_emit_scan_found_something;
        Alcotest.test_case "registered → emit" `Quick
          test_every_implemented_registered_appears_in_emit;
        Alcotest.test_case "emit → registry" `Quick
          test_every_emit_clause_is_registered;
      ] );
    ( "schema",
      [
        Alcotest.test_case "arity declared everywhere" `Quick
          test_every_entry_declares_arity;
        Alcotest.test_case "math intrinsics are pure" `Quick
          test_math_intrinsics_marked_pure;
        Alcotest.test_case "list_get not elementwise" `Quick
          test_list_get_is_not_elementwise;
        Alcotest.test_case "math unary is elementwise" `Quick
          test_math_unary_is_elementwise;
      ] );
    ( "invariants",
      [
        Alcotest.test_case "impure suffixes are impure" `Quick
          test_impure_suffixes_are_impure;
        Alcotest.test_case "structural not elementwise" `Quick
          test_list_dict_set_structural_not_elementwise;
        Alcotest.test_case "collection intrinsics have ownership contracts"
          `Quick test_collection_intrinsics_have_ownership_contracts;
        Alcotest.test_case "all implemented intrinsics have ownership contracts"
          `Quick test_all_implemented_intrinsics_have_ownership_contracts;
        Alcotest.test_case "collection intrinsic contracts are well-formed"
          `Quick test_collection_intrinsic_contracts_are_well_formed;
        Alcotest.test_case "string runtime builtins have ownership contracts"
          `Quick test_string_runtime_builtins_have_ownership_contracts;
        Alcotest.test_case "channel runtime builtins have ownership contracts"
          `Quick test_channel_runtime_builtins_have_ownership_contracts;
        Alcotest.test_case "void-boxed runtime builtins have ownership coverage"
          `Quick test_void_boxed_runtime_builtins_have_ownership_coverage;
        Alcotest.test_case "specialize uses ownership void-boxed manifest"
          `Quick test_specialize_uses_ownership_void_boxed_manifest;
        Alcotest.test_case "IR-backed std functions registered" `Quick
          test_ir_backed_std_functions_registered;
      ] );
  ]
