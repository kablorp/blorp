(** Source-level guardrails for typed Core and type-resolution boundaries.

    These tests intentionally inspect compiler source. They are narrow
    architecture checks: if production code starts calling transitional
    compatibility APIs or low-level resolver chains directly, the unit suite
    should fail before the boundary erodes. *)

let contains_substring haystack needle =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  let rec matches_at i j =
    j = nlen || (haystack.[i + j] = needle.[j] && matches_at i (j + 1))
  in
  let rec loop i =
    i + nlen <= hlen && (matches_at i 0 || loop (i + 1))
  in
  nlen = 0 || loop 0

let count_substring haystack needle =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  let rec matches_at i j =
    j = nlen || (haystack.[i + j] = needle.[j] && matches_at i (j + 1))
  in
  let rec loop count i =
    if nlen = 0 || i + nlen > hlen then count
    else if matches_at i 0 then loop (count + 1) (i + nlen)
    else loop count (i + 1)
  in
  loop 0 0

let is_ident_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true
  | _ -> false

let contains_token haystack needle =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  let token_ends_ident = nlen > 0 && is_ident_char needle.[nlen - 1] in
  let token_starts_ident = nlen > 0 && is_ident_char needle.[0] in
  let rec matches_at i j =
    j = nlen || (haystack.[i + j] = needle.[j] && matches_at i (j + 1))
  in
  let left_boundary i =
    i = 0 || (not token_starts_ident) || not (is_ident_char haystack.[i - 1])
  in
  let right_boundary i =
    i + nlen >= hlen
    || (not token_ends_ident)
    || not (is_ident_char haystack.[i + nlen])
  in
  let rec loop i =
    i + nlen <= hlen
    && (matches_at i 0
        && left_boundary i && right_boundary i
       || loop (i + 1))
  in
  nlen = 0 || loop 0

let has_suffix s suffix =
  let slen = String.length s in
  let suffix_len = String.length suffix in
  slen >= suffix_len && String.sub s (slen - suffix_len) suffix_len = suffix

let find_project_file rel =
  let rec search dir depth =
    let candidate = Filename.concat dir rel in
    if Sys.file_exists candidate then candidate
    else if depth = 0 then
      Alcotest.failf "Cannot locate %s from CWD=%s" rel (Sys.getcwd ())
    else
      let parent = Filename.dirname dir in
      if parent = dir then
        Alcotest.failf "Cannot locate %s from CWD=%s" rel (Sys.getcwd ())
      else search parent (depth - 1)
  in
  search (Sys.getcwd ()) 12

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let substring_between source ~start_marker ~end_marker =
  let find_from marker from_idx =
    let marker_len = String.length marker in
    let source_len = String.length source in
    let rec loop i =
      if i + marker_len > source_len then None
      else if String.sub source i marker_len = marker then Some i
      else loop (i + 1)
    in
    loop from_idx
  in
  match find_from start_marker 0 with
  | None -> Alcotest.failf "Cannot find start marker: %s" start_marker
  | Some start_idx -> (
      let body_start = start_idx + String.length start_marker in
      match find_from end_marker body_start with
      | None -> Alcotest.failf "Cannot find end marker: %s" end_marker
      | Some end_idx -> String.sub source start_idx (end_idx - start_idx))

let rec walk_files dir =
  Sys.readdir dir |> Array.to_list
  |> List.concat_map (fun name ->
      let path = Filename.concat dir name in
      if Sys.is_directory path then walk_files path
      else if has_suffix path ".ml" || has_suffix path ".mli" then [ path ]
      else [])

let strip_comments_and_strings source =
  let len = String.length source in
  let buffer = Buffer.create len in
  let rec copy_code i =
    if i >= len then ()
    else if i + 1 < len && source.[i] = '(' && source.[i + 1] = '*' then
      skip_comment (i + 2) 1
    else if source.[i] = '"' then skip_string (i + 1)
    else (
      Buffer.add_char buffer source.[i];
      copy_code (i + 1))
  and skip_comment i depth =
    if i >= len then ()
    else if i + 1 < len && source.[i] = '(' && source.[i + 1] = '*' then
      skip_comment (i + 2) (depth + 1)
    else if i + 1 < len && source.[i] = '*' && source.[i + 1] = ')' then
      let depth = depth - 1 in
      if depth = 0 then copy_code (i + 2) else skip_comment (i + 2) depth
    else skip_comment (i + 1) depth
  and skip_string i =
    if i >= len then ()
    else if source.[i] = '\\' then skip_string (min len (i + 2))
    else if source.[i] = '"' then copy_code (i + 1)
    else skip_string (i + 1)
  in
  copy_code 0;
  Buffer.contents buffer

let repo_rel path =
  let root =
    find_project_file "compiler/lib" |> Filename.dirname |> Filename.dirname
  in
  let root_prefix = root ^ Filename.dir_sep in
  let prefix_len = String.length root_prefix in
  if
    String.length path >= prefix_len
    && String.sub path 0 prefix_len = root_prefix
  then String.sub path prefix_len (String.length path - prefix_len)
  else path

let lib_source_paths = lazy (walk_files (find_project_file "compiler/lib"))

let lib_sources () = Lazy.force lib_source_paths

let stripped_source_cache : (string, string) Hashtbl.t = Hashtbl.create 128

let stripped_file_source path =
  match Hashtbl.find_opt stripped_source_cache path with
  | Some content -> content
  | None ->
      let content = strip_comments_and_strings (read_file path) in
      Hashtbl.replace stripped_source_cache path content;
      content

let assert_token_only_in_files ~paths ~allowed_files token =
  paths
  |> List.iter (fun path ->
      let rel = repo_rel path in
      if not (List.mem rel allowed_files) then
        let content = stripped_file_source path in
        if contains_token content token then
          Alcotest.failf
            "%s uses %s directly; route through the explicit boundary" rel token)

let assert_token_only_in ~allowed_files token =
  assert_token_only_in_files ~paths:(lib_sources ()) ~allowed_files token

let test_type_resolution_has_single_production_boundary () =
  assert_token_only_in
    ~allowed_files:
      [
        "compiler/lib/env.ml";
        "compiler/lib/env.mli";
        "compiler/lib/type_resolution.ml";
        "compiler/lib/infer_type_normalization.ml";
      ]
    "Env.resolve_alias";
  assert_token_only_in
    ~allowed_files:
      [
        "compiler/lib/env.ml";
        "compiler/lib/env.mli";
        "compiler/lib/type_resolution.ml";
      ]
    "Env.disambiguate_nominal_dim_application";
  assert_token_only_in
    ~allowed_files:
      [
        "compiler/lib/types.ml";
        "compiler/lib/types.mli";
        "compiler/lib/type_resolution.ml";
      ]
    "Types.resolve_qualified_types"

let test_typed_ast_does_not_reexport_raw_ast_constructors () =
  let impl =
    find_project_file "compiler/lib/typed_ast.ml"
    |> read_file |> strip_comments_and_strings
  in
  let iface =
    find_project_file "compiler/lib/typed_ast.mli"
    |> read_file |> strip_comments_and_strings
  in
  if contains_substring impl "let with_expr_type = Ast.with_expr_type" then
    Alcotest.fail
      "Typed_ast must not re-export Ast.with_expr_type; raw compatibility \
       payload construction should stay at explicit Ast compatibility \
       boundaries.";
  if contains_substring impl "type type_info = Ast.expr_type_info" then
    Alcotest.fail
      "Typed_ast.type_info must be owned by Typed_ast, not aliased to the raw \
       Ast compatibility payload.";
  if contains_substring iface "type type_info = private Ast.expr_type_info" then
    Alcotest.fail
      "Typed_ast.type_info must expose a typed-boundary record, not a private \
       alias of Ast.expr_type_info."

let test_typed_expr_metadata_has_proof_payload () =
  let ast_impl =
    find_project_file "compiler/lib/ast.ml"
    |> read_file |> strip_comments_and_strings
  in
  let typed_impl =
    find_project_file "compiler/lib/typed_ast.ml"
    |> read_file |> strip_comments_and_strings
  in
  let ast_block =
    substring_between ast_impl ~start_marker:"type expr_type_info = {"
      ~end_marker:"type unop"
  in
  let typed_block =
    substring_between typed_impl ~start_marker:"type type_info = {"
      ~end_marker:"type func_info ="
  in
  if not (contains_substring ast_block "proofs :") then
    Alcotest.fail
      "Ast.expr_type_info should carry an explicit proof payload so inference \
       can preserve proof facts at the typed boundary.";
  if not (contains_substring typed_block "proofs :") then
    Alcotest.fail
      "Typed_ast.type_info should carry an explicit proof payload instead of \
       forcing proof facts to remain in proof_env side tables."

let test_typed_ast_keeps_layout_out_of_boundary () =
  let impl =
    find_project_file "compiler/lib/typed_ast.ml"
    |> read_file |> strip_comments_and_strings
  in
  let iface =
    find_project_file "compiler/lib/typed_ast.mli"
    |> read_file |> strip_comments_and_strings
  in
  [
    "Core_layout";
    "Core_type_layout";
    "Codegen_types";
    "layout";
    "storage";
    "abi";
  ]
  |> List.iter (fun forbidden ->
      if contains_token impl forbidden || contains_token iface forbidden then
        Alcotest.failf
          "Typed_ast must not carry %s facts; layout/codegen facts belong in \
           narrow phase-specific boundaries."
          forbidden)

let test_expr_type_compatibility_surface_is_inventoried () =
  let typed_boundary_files =
    [ "compiler/lib/ast.ml"; "compiler/lib/typed_ast.ml" ]
  in
  assert_token_only_in ~allowed_files:typed_boundary_files ".expr_type";
  assert_token_only_in ~allowed_files:[ "compiler/lib/ast.ml" ]
    "expr_type = Some";
  assert_token_only_in ~allowed_files:[ "compiler/lib/ast.ml" ]
    "expr_type_info = Some";
  assert_token_only_in ~allowed_files:[ "compiler/lib/ast.ml" ]
    "expr_type_info = Option.map";
  assert_token_only_in ~allowed_files:[ "compiler/lib/ast.ml" ]
    "expr_type = None";
  assert_token_only_in ~allowed_files:[ "compiler/lib/ast.ml" ]
    "expr_type_info = None"

let test_expr_type_compatibility_helpers_are_inventoried () =
  assert_token_only_in ~allowed_files:[] "Ast.with_expr_type";
  assert_token_only_in ~allowed_files:[ "compiler/lib/ast.ml" ]
    "expr_type_info_from_type";
  assert_token_only_in
    ~allowed_files:
      [
        "compiler/lib/ast.ml";
        "compiler/lib/infer.ml";
        "compiler/lib/typed_ast.ml";
      ]
    "with_expr_type_info";
  assert_token_only_in ~allowed_files:[] "Ast.require_expr_type";
  assert_token_only_in ~allowed_files:[] "Ast.require_expr_type_info";
  assert_token_only_in ~allowed_files:[] "require_expr_semantic_type";
  assert_token_only_in ~allowed_files:[] "Ast.require_expr_value_type";
  assert_token_only_in
    ~allowed_files:[ "compiler/lib/ast.ml"; "compiler/lib/infer.ml" ]
    "map_expr_type_payload";
  let infer =
    find_project_file "compiler/lib/infer.ml"
    |> read_file |> strip_comments_and_strings
  in
  Alcotest.(check int)
    "Infer has one raw typed-payload annotation boundary" 1
    (count_substring infer "Ast.with_expr_type_info");
  Alcotest.(check int)
    "Infer has one raw typed-payload zonking boundary" 1
    (count_substring infer "Ast.map_expr_type_payload")

let test_dead_raw_expr_accessors_stay_deleted () =
  let ast =
    find_project_file "compiler/lib/ast.ml"
    |> read_file |> strip_comments_and_strings
  in
  [
    "let require_expr_type ";
    "let require_expr_type_info ";
    "let require_expr_semantic_type ";
    "let require_expr_value_type ";
    "let with_expr_type ";
  ]
  |> List.iter (fun token ->
      if contains_substring ast token then
        Alcotest.failf
          "%s should stay deleted; use typed payload accessors instead." token)

let test_lsp_hover_uses_type_metadata_boundary () =
  let hover =
    find_project_file "compiler/lib/lsp/lsp_hover.ml"
    |> read_file |> strip_comments_and_strings
  in
  if contains_token hover ".expr_type_info" then
    Alcotest.fail
      "LSP hover should route expression type metadata through \
       Type_metadata_format.hover_type_view_for_expr instead of reading the \
       transitional AST payload directly."

let test_explicit_dim_lift_stays_in_named_boundaries () =
  assert_token_only_in
    ~allowed_files:
      [ "compiler/lib/core_trait_resolve.ml"; "compiler/lib/type_widening.ml" ]
    "Types.Dim.lift_to_int"

let test_late_layout_fallbacks_stay_in_inventoried_callers () =
  let guard allowed_files token = assert_token_only_in ~allowed_files token in
  guard [] "Core_list_layout.layout_of_elem";
  guard [] "Core_list_layout.layout_of_type";
  guard [ "compiler/lib/core_pipeline.ml" ] "Core_list_layout.annotate_program";
  guard [] "Core_list_layout.canonical_type";
  guard [] "Core_list_layout.width_for_enum_info";
  guard [] "Core_array_layout.tensor_storage_for_elem";
  guard
      [
        "compiler/lib/core_emit_layout.ml";
        "compiler/lib/core_emit_layout.mli";
        "compiler/lib/core_specialize.ml";
      ]
    "Core_layout_type.tensor_element_storage";
  guard
      [ "compiler/lib/core_emit_layout.ml" ]
    "Core_layout_type.tensor_storage_layout_of_type";
  guard [] "Core_layout_type.tensor_storage_layout_of_elem";
  guard [] "let tensor_for_in_raw_storage ";
  guard [] "let tensor_for_in_raw_storage_of_layout";
  guard [] "let tensor_producer_builtin_storage_rule ";
  guard [] "builtin_storage_rule";
  guard [] "Core_array_layout.tensor_layout_of_type";
  guard [] "Core_array_layout.tensor_layout_of_elem";
  guard [] "Core_array_layout.tensor_raw_scalar_abi";
  guard [] "Core_array_layout.tensor_raw_scalar_abi_of_layout";
  guard [] "Core_array_layout.list_storage_for_elem";
  guard [] "Core_array_layout.canonical_type";
  guard [] "Core_array_layout.width_for_enum_info";
  guard
    [ "compiler/lib/core_list_layout.ml" ]
    "Core_layout_type.list_element_storage";
  guard [ "compiler/lib/core_layout_type.ml" ] "Core_option_layout.classify";
  guard
    [ "compiler/lib/core_layout_type.ml" ]
    "Core_option_layout.nullable_managed_payload_type";
  guard
    [ "compiler/lib/core_layout_type.ml" ]
    "Core_option_layout.primitive_stack_abi_of_layout";
  guard
    [ "compiler/lib/core_layout_type.ml" ]
    "Core_option_layout.runtime_suffix_of_primitive_stack_abi";
  guard
    [ "compiler/lib/core_layout_type.ml" ]
    "Core_option_layout.primitive_stack_abi_of_scalar";
  guard
    [ "compiler/lib/core_layout_type.ml" ]
    "Core_option_layout.c_type_of_primitive_stack_abi";
  guard
    [ "compiler/lib/core_layout_type.ml" ]
    "Codegen_types.stack_option_c_type";
  guard [] "Codegen_types.generated_stack_option_c_type_of_payload";
  guard
    [ "compiler/lib/core_layout_type.ml" ]
    "Codegen_types.stack_result_c_type";
  guard [ "compiler/lib/core_layout_type.ml" ] "Codegen_types.is_stack_option";
  guard [ "compiler/lib/core_layout_type.ml" ] "Codegen_types.is_stack_result";
  guard
    [
      "compiler/lib/codegen/codegen_types.ml";
      "compiler/lib/core_type_layout.ml";
    ]
    "Core_result_layout.classify";
  guard
    [
      "compiler/lib/codegen/codegen_types.ml";
      "compiler/lib/core_type_layout.ml";
    ]
    "Core_result_layout.metadata";
  guard [] "same_tensor_shape";
  guard
    [ "compiler/lib/core_tensor_fusion.ml" ]
    "Core_tensor_type.same_static_shape";
  guard [] "Types.array_parts (Codegen_types.normalize_type expr.ty)";
  guard [] "Types.is_array_type (Codegen_types.normalize_type expr.ty)";
  guard [] "Types.is_array_type (Codegen_types.normalize_type binding.bind_ty)";
  guard []
    "Types.is_array_type (Codegen_types.normalize_type binding.borrow_ty)";
  guard [] "Types.array_parts (Codegen_types.normalize_type";
  guard [] "Types.array_parts (canonical_type";
  guard [] "Types.array_parts (normalize_type";
  guard [] "Types.is_array_type (normalize_type";
  guard []
    "ty |> Codegen_types.expand_alias ~reg |> Codegen_types.normalize_type";
  guard
    [ "compiler/lib/core_mono.ml" ]
    "Codegen_types.normalize_type (Codegen_types.expand_alias";
  guard [] "Codegen_types.expand_alias ~reg:ctx.reg parent_ty";
  let emit_layout =
    find_project_file "compiler/lib/core_emit_layout.ml"
    |> read_file |> strip_comments_and_strings
  in
  if contains_substring emit_layout "Codegen_types.normalize_type" then
    Alcotest.fail
      "Core_emit_layout should consume late-layout canonical facts through \
       Core_layout_type/Core_tensor_type rather than raw Codegen_types \
       normalization.";
  let tailrec =
    find_project_file "compiler/lib/core_tailrec.ml"
    |> read_file |> strip_comments_and_strings
  in
  if contains_substring tailrec "Codegen_types.normalize_type" then
    Alcotest.fail
      "Core_tailrec should consume late-layout list/source-value facts through \
       Core_layout_type rather than raw Codegen_types normalization.";
  guard [] "Core_type_layout.requires_release_or_error";
  guard [] "Core_type_layout.requires_retain_or_error";
  guard [] "Core_type_layout.release_capability";
  guard
    [ "compiler/lib/core_layout_type.ml" ]
    "Core_type_layout.is_arc_boxed_storage_value_type";
  guard [] "Core_type_layout.destructor_policy_for_record";
  guard [] "Core_type_layout.destructor_policy_for_union";
  guard
    [ "compiler/lib/core_list_layout.ml" ]
    "Core_layout_type.classify_erased_storage";
  guard
    [
      "compiler/lib/core_emit_layout.ml";
      "compiler/lib/core_specialize.ml";
    ]
    "Core_layout_type.boxed_storage_requires_release_or_error";
  guard [ "compiler/lib/core_layout_type.ml" ] "Codegen_types.type_to_c";
  guard [ "compiler/lib/core_layout_type.ml" ] "Codegen_types.is_pointer_type";
  guard
    [ "compiler/lib/core_layout_type.ml" ]
    "Codegen_types.has_type_vars ty && c_type ~reg ty";
  guard [] "is_user_hashable_key";
  let intrinsics =
    find_project_file "compiler/lib/core_intrinsics.ml"
    |> read_file |> strip_comments_and_strings
  in
  if contains_substring intrinsics "let immediate_table_key_ty" then
    Alcotest.fail
      "Core_intrinsics should consume hash probe facts from Core_layout_type \
       instead of reclassifying table key type families locally.";
  if contains_substring intrinsics "let key_needs_value_box" then
    Alcotest.fail
      "Core_intrinsics should consume pointer-argument layout facts from \
       Core_layout_type instead of reclassifying hash keys locally.";
  if contains_substring intrinsics "let value_needs_storage_box" then
    Alcotest.fail
      "Core_intrinsics should consume boxed-storage pointer-argument facts \
       from Core_layout_type instead of reclassifying values locally.";
  if contains_substring intrinsics "let is_supported_numeric_tensor_elem" then
    Alcotest.fail
      "Core_intrinsics should consume tensor numeric access facts from \
       Core_layout_type instead of reclassifying vector reduction element \
       families locally.";
  if
    contains_substring intrinsics
      "Codegen_types.normalize_type tensor_ty.elem_ty"
  then
    Alcotest.fail
      "Core_intrinsics should not normalize tensor element types locally while \
       synthesizing reductions; use Core_tensor_type plus Core_layout_type \
       access facts.";
  let specialize =
    find_project_file "compiler/lib/core_specialize.ml"
    |> read_file |> strip_comments_and_strings
  in
  if contains_substring specialize "Codegen_types.is_enum_type reg name" then
    Alcotest.fail
      "Core_specialize should consume enum-backed tensor checked-get access \
       facts from Core_layout_type instead of reclassifying enum names \
       locally.";
  if contains_substring specialize "Hashtbl.mem reg.Codegen_types.enum_types"
  then
    Alcotest.fail
      "Core_specialize should consume enum layout facts from Core_layout_type \
       instead of reading reg.enum_types directly.";
  if contains_substring specialize "primitive_stack_option_payload_suffix" then
    Alcotest.fail
      "Core_specialize should consume Option runtime ABI facts from \
       Core_layout_type instead of selecting primitive stack Option suffixes \
       locally.";
  if contains_substring specialize "option_layout_is_boxed_union" then
    Alcotest.fail
      "Core_specialize should consume Option runtime ABI facts from \
       Core_layout_type instead of checking boxed-union Option layout locally.";
  if contains_substring specialize "Hashtbl.mem reg.Codegen_types.value_records"
  then
    Alcotest.fail
      "Core_specialize should consume debug heap classification facts from \
       Core_type_layout/Core_layout_type instead of reading value_records \
       directly.";
  let infer =
    find_project_file "compiler/lib/infer.ml"
    |> read_file |> strip_comments_and_strings
  in
  if contains_substring infer "Env.is_value_record ctx.env n" then
    Alcotest.fail
      "Infer should consume debug heap classification facts from \
       Core_type_layout instead of duplicating is_heap value-record logic.";
  ()

let test_type_param_bound_string_parsing_stays_inventoried () =
  assert_token_only_in ~allowed_files:[] "String.split_on_char ':'";
  assert_token_only_in ~allowed_files:[] "String.split_on_char '+'";
  assert_token_only_in
    ~allowed_files:[ "compiler/lib/types.ml" ]
    "String.index_opt s ':'";
  assert_token_only_in ~allowed_files:[] "String.index_opt param ':'";
  assert_token_only_in ~allowed_files:[] "String.index_opt p ':'";
  assert_token_only_in ~allowed_files:[] "String.index_opt name ':'";
  assert_token_only_in ~allowed_files:[] "String.contains name ':'";
  assert_token_only_in ~allowed_files:[] "Generic_params.of_parser_string";
  assert_token_only_in ~allowed_files:[] "TyVar \"T:";
  assert_token_only_in ~allowed_files:[] "TyVar \"E:";
  assert_token_only_in ~allowed_files:[] "list_of_parser_strings";
  assert_token_only_in ~allowed_files:[] "list_to_parser_strings";
  assert_token_only_in ~allowed_files:[] "type_params_of_parser_strings";
  assert_token_only_in ~allowed_files:[] "type_params_to_parser_strings";
  assert_token_only_in ~allowed_files:[] "parse_type_param_bounds";
  assert_token_only_in ~allowed_files:[] "type_param_bound_names";
  assert_token_only_in ~allowed_files:[] "type_param_bounds_from_strings [";
  assert_token_only_in ~allowed_files:[] "set_type_param_bounds_from_strings";
  assert_token_only_in
    ~allowed_files:[ "compiler/lib/unused_imports.ml" ]
    "Types.strip_type_param_bounds";
  assert_token_only_in
    ~allowed_files:[ "compiler/lib/codegen/codegen_types.ml" ]
    "Codegen_types.is_type_param_name";
  lib_sources ()
  |> List.iter (fun path ->
      let rel = repo_rel path in
      if rel <> "compiler/lib/generic_params.ml" then
        let content = read_file path in
        if contains_substring content "^ \":\" ^ String.concat \"+\"" then
          Alcotest.failf
            "%s re-encodes generic bounds directly; route formatting through \
             Generic_params."
            rel)
  |> ignore

let test_ast_decl_type_params_are_structured () =
  let ast_source = read_file (find_project_file "compiler/lib/ast.ml") in
  List.iter
    (fun field ->
      let raw = field ^ " : string list" in
      if contains_substring ast_source raw then
        Alcotest.failf
          "Ast.%s regressed to string list; declaration type parameters must \
           stay structured at the AST boundary."
          field;
      let structured = field ^ " : type_param_decl list" in
      if not (contains_substring ast_source structured) then
        Alcotest.failf "Ast.%s should be declared as type_param_decl list."
          field)
    [
      "func_type_params";
      "type_params";
      "record_type_params";
      "trait_type_params";
      "alias_type_params";
    ];
  [ "compiler/lib/env_types.ml"; "compiler/lib/env.ml"; "compiler/lib/env.mli" ]
  |> List.iter (fun rel ->
      let content = find_project_file rel |> read_file in
      if contains_substring content "ol_type_params : string list" then
        Alcotest.failf
          "%s stores overload type params as parser strings; use structured \
           bound_type_param data."
          rel;
      if contains_substring content "ii_bounds : (string * string list) list"
      then
        Alcotest.failf
          "%s stores impl bounds as tuple lists; use structured \
           bound_type_param data."
          rel)
  |> ignore;
  let typecheck_source =
    read_file (find_project_file "compiler/lib/typecheck.ml")
  in
  if
    contains_substring typecheck_source
      "cfs_effective_type_params : string list"
  then
    Alcotest.fail
      "Typecheck.checked_func_signature stores effective type params as parser \
       strings; use structured type_param_decl data."
  else ();
  let env_source = read_file (find_project_file "compiler/lib/env.ml") in
  if
    contains_substring env_source
      "type_params : string list; (* Generic type parameters *)"
  then
    Alcotest.fail
      "Env.FuncSymbol stores type params as parser strings; use structured \
       bound_type_param data.";
  let core_source = read_file (find_project_file "compiler/lib/core.ml") in
  if contains_substring core_source "cf_type_params : string list" then
    Alcotest.fail
      "Core.core_func stores type params as parser strings; use structured \
       type_param_decl data."

let test_infer_interface_does_not_reexport_refinement_internals () =
  let iface =
    find_project_file "compiler/lib/infer.mli"
    |> read_file |> strip_comments_and_strings
  in
  [
    "type proven_collection";
    "type range_upper";
    "type range_proof";
    "RangeUpper";
    "CollVar";
  ]
  |> List.iter (fun token ->
      if contains_substring iface token then
        Alcotest.failf
          "Infer.mli must not expose refinement proof internals (%s); keep \
           proof modeling behind Refinement and Infer implementation \
           boundaries."
          token)

let test_infer_implementation_uses_refinement_constructors () =
  let impl =
    find_project_file "compiler/lib/infer.ml"
    |> read_file |> strip_comments_and_strings
  in
  [
    "Some (CollVar";
    "Some (CollDim";
    "(var, CollDim";
    "(idx, CollDim";
    "Some (RangeUpper";
    "~range_upper:(RangeUpper";
    "Some (Refinement.RangeUpper";
    "~range_upper:(Refinement.RangeUpper";
    "Refinement.CollVar";
    "Refinement.CollDim";
    "Refinement.ConstantDim";
    "Refinement.CollectionLength";
    "proven_subscripts";
    "proven_ranges";
    "(string * proven_collection) list";
    "(string * range_proof) list";
  ]
  |> List.iter (fun token ->
      if contains_substring impl token then
        Alcotest.failf
          "Infer.ml constructs refinement proof internals directly (%s); use \
           Refinement smart constructors so invalid proofs stay \
           unrepresentable."
          token)

let test_refinement_interface_hides_raw_collection_names () =
  let iface =
    find_project_file "compiler/lib/refinement.mli"
    |> read_file |> strip_comments_and_strings
  in
  [
    "CollVar of string";
    "CollSubscript of proven_collection * string";
    "RangeUpperLengthMinus of { coll : string";
    "RangeUpperAtMostLength of { coll : string";
    "CollectionLength of string";
    "direct_collection_var : proven_collection -> string option";
    "coll:string";
    "var:collection_identity -> string list";
    "(string * proven_collection) list";
    "(string * range_proof) list";
  ]
  |> List.iter (fun token ->
      if contains_substring iface token then
        Alcotest.failf
          "Refinement interface exposes raw collection/dimension names (%s); \
           use identity types in proof data so invalid names stay \
           unrepresentable."
          token)

let test_refinement_interface_hides_raw_dimension_names () =
  let iface =
    find_project_file "compiler/lib/refinement.mli"
    |> read_file |> strip_comments_and_strings
  in
  [
    "RangeUpperDimension of string";
    "DimensionBound of string";
    "range_upper_dimension : string";
    "dimension_bound : string";
  ]
  |> List.iter (fun token ->
      if contains_substring iface token then
        Alcotest.failf
          "Refinement interface exposes raw dimension names (%s); use \
           dimension_identity in proof data so invalid names stay \
           unrepresentable."
          token)

let test_refinement_interface_hides_binding_proof_storage () =
  let iface =
    find_project_file "compiler/lib/refinement.mli"
    |> read_file |> strip_comments_and_strings
  in
  [
    "type binding_refinement =";
    "binding_range :";
    "binding_subscript :";
    "RangeBinding";
    "UnrefinedBinding";
  ]
  |> List.iter (fun token ->
      if contains_substring iface token then
        Alcotest.failf
          "Refinement interface exposes binding proof storage (%s); keep \
           binding refinements abstract and mutate them through smart \
           operations."
          token)

let test_proof_paths_use_structured_semantic_metadata () =
  let impl =
    find_project_file "compiler/lib/infer.ml"
    |> read_file |> strip_comments_and_strings
  in
  let assert_block ~name ~start_marker ~end_marker ~forbidden ~required =
    let block = substring_between impl ~start_marker ~end_marker in
    List.iter
      (fun token ->
        if contains_substring block token then
          Alcotest.failf
            "%s uses %s in proof/refinement typing; use the structured proof \
             semantic accessor so raw expr_type compatibility does not drive \
             bounds decisions."
            name token)
      forbidden;
    List.iter
      (fun token ->
        if not (contains_substring block token) then
          Alcotest.failf
            "%s does not use %s; proof/refinement typing should make the \
             structured semantic metadata dependency explicit."
            name token)
      required
  in
  assert_block ~name:"resolve_subscript_chain_type"
    ~start_marker:"let rec resolve_subscript_chain_type"
    ~end_marker:"let build_subst"
    ~forbidden:[ "expr_semantic_type_opt"; ".expr_type" ]
    ~required:[ "expr_proof_semantic_type_opt" ];
  assert_block ~name:"infer_vector_ctor" ~start_marker:"and infer_vector_ctor"
    ~end_marker:"and infer_matrix_ctor" ~forbidden:[ ".expr_type" ]
    ~required:[ "expr_proof_semantic_type_opt" ];
  assert_block ~name:"extract_upper_bound"
    ~start_marker:"and extract_upper_bound"
    ~end_marker:"and extract_range_narrowings" ~forbidden:[ ".expr_type" ]
    ~required:[ "expr_proof_semantic_type_opt" ]

let test_branch_narrowing_has_single_construction_boundary () =
  let impl =
    find_project_file "compiler/lib/infer.ml"
    |> read_file |> strip_comments_and_strings
  in
  Alcotest.(check int)
    "conditional narrowing should insert TyRange in one helper" 1
    (count_substring impl "TyRange upper_ty");
  if not (contains_substring impl "Refinement.make_branch_range_proof") then
    Alcotest.fail
      "conditional range narrowing should route through the Refinement branch \
       proof boundary instead of open-coding mutable/immutable checks.";
  if not (contains_substring impl "~refinement") then
    Alcotest.fail
      "conditional range narrowing should attach binding refinement metadata \
       instead of relying only on a TyRange semantic type."

let test_branch_narrowing_preserves_existing_binding_metadata () =
  let impl =
    find_project_file "compiler/lib/infer.ml"
    |> read_file |> strip_comments_and_strings
  in
  let block =
    substring_between impl ~start_marker:"let branch_range_narrowing_refinement"
      ~end_marker:"let apply_branch_range_narrowing"
  in
  if not (contains_substring block "Env.get_var_refinement") then
    Alcotest.fail
      "branch narrowing should read existing binding refinement metadata \
       before adding a range proof.";
  if not (contains_substring block "binding_add_range_proof") then
    Alcotest.fail
      "branch narrowing should add a range proof to existing binding metadata \
       instead of replacing the whole binding refinement."

let test_loop_range_proofs_attach_binding_metadata () =
  let impl =
    find_project_file "compiler/lib/infer.ml"
    |> read_file |> strip_comments_and_strings
  in
  if not (contains_substring impl "Env.set_var_refinement") then
    Alcotest.fail
      "loop range proofs should attach refinement metadata to Env bindings \
       instead of relying only on proof_env side tables.";
  if count_substring impl "env_with_binding_refinement_from_proof" < 4 then
    Alcotest.fail
      "loop proof metadata should be attached through the binding proof bundle \
       at construction sites, not only defined as an unused helper."

let test_identifier_inference_attaches_binding_proofs () =
  let impl =
    find_project_file "compiler/lib/infer.ml"
    |> read_file |> strip_comments_and_strings
  in
  let block =
    substring_between impl ~start_marker:"| EIdent name -> ("
      ~end_marker:"| ELiteral lit -> ("
  in
  if not (contains_substring impl "let expr_proofs_for_identifier") then
    Alcotest.fail
      "Infer should have one helper that converts Env binding refinements and \
       range-typed identifiers into expression proof payloads.";
  if not (contains_substring block "expr_proofs_for_identifier") then
    Alcotest.fail
      "identifier inference should attach Env binding proof metadata to the \
       typed expression payload instead of leaving proofs only in side tables."

let test_chained_subscript_proofs_consume_binding_metadata () =
  let impl =
    find_project_file "compiler/lib/infer.ml"
    |> read_file |> strip_comments_and_strings
  in
  let block =
    substring_between impl ~start_marker:"let rec expr_to_proven_collection"
      ~end_marker:"let rec resolve_subscript_chain_type"
  in
  if not (contains_substring block "env_binding_proves_subscript") then
    Alcotest.fail
      "chained subscript proof construction should consume Env binding proof \
       metadata as the fallback after typed expression proof metadata.";
  if not (contains_substring block "expr_proves_subscript") then
    Alcotest.fail
      "chained subscript proof construction should consume expression proof \
       payloads for typed index expressions.";
  if contains_substring block "proof_env_proves_subscript" then
    Alcotest.fail
      "chained subscript proof construction should no longer consult \
       proof_env; typed expression payloads and Env binding metadata are the \
       durable proof sources."

let test_tuple_destruct_proofs_attach_binding_metadata () =
  let impl =
    find_project_file "compiler/lib/infer.ml"
    |> read_file |> strip_comments_and_strings
  in
  let block =
    substring_between impl ~start_marker:"and ctx_after_inferred_expr"
      ~end_marker:"and infer_all"
  in
  if not (contains_substring block "env_with_binding_refinement_from_proof")
  then
    Alcotest.fail
      "tuple destructuring should attach available proof metadata when it \
       introduces bindings, especially enumerate index variables."

let test_offset_subscript_proofs_prefer_binding_metadata () =
  let impl =
    find_project_file "compiler/lib/infer.ml"
    |> read_file |> strip_comments_and_strings
  in
  let block =
    substring_between impl ~start_marker:"let proven_from_expr ="
      ~end_marker:"let mod_bound ="
  in
  if not (contains_substring block "env_binding_proves_offset_range") then
    Alcotest.fail
      "offset subscript proof validation should still have Env binding \
       metadata as the fallback after typed expression proof metadata.";
  if not (contains_substring block "expr_proves_offset_range") then
    Alcotest.fail
      "offset subscript proof validation should query typed expression proof \
       payloads before compatibility fallbacks.";
  if not (contains_substring block "match proven_from_expr") then
    Alcotest.fail
      "offset subscript proof validation should make the expression proof \
       payload the first decision point.";
  if contains_substring block "proof_env_proves_offset_range" then
    Alcotest.fail
      "offset subscript proof validation should not query proof_env directly; \
       proof_env must stay a loop-proof construction scratchpad, not a \
       validation source.";
  if contains_substring block "Env.get_var_type" then
    Alcotest.fail
      "offset subscript proof validation should not rediscover TyRange proofs \
       from Env variable types; range-typed identifiers should attach proof \
       payloads during identifier inference."

let test_direct_subscript_validation_uses_expr_proofs () =
  let impl =
    find_project_file "compiler/lib/infer.ml"
    |> read_file |> strip_comments_and_strings
  in
  let block =
    substring_between impl
      ~start_marker:"and validate_index ctx loc idx dim coll'"
      ~end_marker:"and infer_unconstrained_value_expr"
  in
  if not (contains_substring block "expr_proves_direct_range") then
    Alcotest.fail
      "direct subscript validation should consume typed expression range \
       proofs before falling back to Env binding metadata.";
  if contains_substring block "proof_env_proves_direct_range" then
    Alcotest.fail
      "direct subscript validation should not query proof_env directly; \
       durable expression and binding metadata should carry range facts."

let test_refinement_interface_hides_proof_env_validation_queries () =
  let iface =
    find_project_file "compiler/lib/refinement.mli"
    |> read_file |> strip_comments_and_strings
  in
  [
    "proof_env_proves_subscript";
    "proof_env_proves_dim_at_most";
    "proof_env_direct_collection_vars";
    "proof_env_proves_direct_range";
    "proof_env_proves_offset_range";
    "proof_env_find_subscript_source";
    "proof_env_without_var";
    "proof_env_add_range";
  ]
  |> List.iter (fun forbidden ->
      if contains_token iface forbidden then
        Alcotest.failf
          "%s should not be public: proof_env is an inference-local assembly \
           scratchpad, while validation queries belong on durable expression \
           or binding proof metadata."
          forbidden)

let suite =
  [
    ( "boundaries",
      [
        Alcotest.test_case "type resolution has central production boundary"
          `Quick test_type_resolution_has_single_production_boundary;
        Alcotest.test_case "Typed_ast does not re-export raw AST constructors"
          `Quick test_typed_ast_does_not_reexport_raw_ast_constructors;
        Alcotest.test_case "typed expression metadata has proof payload" `Quick
          test_typed_expr_metadata_has_proof_payload;
        Alcotest.test_case "Typed_ast keeps layout out of typed boundary" `Quick
          test_typed_ast_keeps_layout_out_of_boundary;
        Alcotest.test_case "expr_type compatibility surface is inventoried"
          `Quick test_expr_type_compatibility_surface_is_inventoried;
        Alcotest.test_case "expr_type compatibility helpers are inventoried"
          `Quick test_expr_type_compatibility_helpers_are_inventoried;
        Alcotest.test_case "dead raw expr accessors stay deleted" `Quick
          test_dead_raw_expr_accessors_stay_deleted;
        Alcotest.test_case "LSP hover uses type metadata boundary" `Quick
          test_lsp_hover_uses_type_metadata_boundary;
        Alcotest.test_case "dim lift stays in named boundaries" `Quick
          test_explicit_dim_lift_stays_in_named_boundaries;
        Alcotest.test_case "late layout fallbacks stay inventoried" `Quick
          test_late_layout_fallbacks_stay_in_inventoried_callers;
        Alcotest.test_case "type-param bound parsing stays inventoried" `Quick
          test_type_param_bound_string_parsing_stays_inventoried;
        Alcotest.test_case "AST declaration type params stay structured" `Quick
          test_ast_decl_type_params_are_structured;
        Alcotest.test_case
          "Infer interface does not expose refinement internals" `Quick
          test_infer_interface_does_not_reexport_refinement_internals;
        Alcotest.test_case "Infer implementation uses refinement constructors"
          `Quick test_infer_implementation_uses_refinement_constructors;
        Alcotest.test_case "Refinement interface hides raw collection names"
          `Quick test_refinement_interface_hides_raw_collection_names;
        Alcotest.test_case "Refinement interface hides raw dimension names"
          `Quick test_refinement_interface_hides_raw_dimension_names;
        Alcotest.test_case "Refinement hides binding proof storage" `Quick
          test_refinement_interface_hides_binding_proof_storage;
        Alcotest.test_case "proof paths use structured semantic metadata" `Quick
          test_proof_paths_use_structured_semantic_metadata;
        Alcotest.test_case "branch narrowing has one construction boundary"
          `Quick test_branch_narrowing_has_single_construction_boundary;
        Alcotest.test_case "branch narrowing preserves binding metadata" `Quick
          test_branch_narrowing_preserves_existing_binding_metadata;
        Alcotest.test_case "loop range proofs attach binding metadata" `Quick
          test_loop_range_proofs_attach_binding_metadata;
        Alcotest.test_case "identifier inference attaches binding proofs" `Quick
          test_identifier_inference_attaches_binding_proofs;
        Alcotest.test_case "chained subscript proofs consume binding metadata"
          `Quick test_chained_subscript_proofs_consume_binding_metadata;
        Alcotest.test_case "tuple destruct proofs attach binding metadata"
          `Quick test_tuple_destruct_proofs_attach_binding_metadata;
        Alcotest.test_case "offset proofs prefer binding metadata" `Quick
          test_offset_subscript_proofs_prefer_binding_metadata;
        Alcotest.test_case "direct subscript validation uses expression proofs"
          `Quick test_direct_subscript_validation_uses_expr_proofs;
        Alcotest.test_case "proof_env validation queries stay private" `Quick
          test_refinement_interface_hides_proof_env_validation_queries;
      ] );
  ]
