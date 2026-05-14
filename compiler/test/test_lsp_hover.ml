(** Unit tests for LSP hover formatting. *)

open Blorp

let contains_substring haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    if i + needle_len > haystack_len then false
    else if String.sub haystack i needle_len = needle then true
    else loop (i + 1)
  in
  needle_len = 0 || loop 0

let typed_ident_with_source name ~source_ty ~semantic_ty =
  let info : Ast.expr_type_info =
    {
      source_ty = Some source_ty;
      semantic_ty;
      value_ty = semantic_ty;
      origin = ExplicitAnnotation source_ty;
      widening = Keep semantic_ty;
      proofs = Type_proof_metadata.unproven_expr;
    }
  in
  {
    Ast.expr_desc = EIdent name;
    expr_loc = Ast.dummy_loc;
    expr_type = Some semantic_ty;
    expr_type_info = Some info;
    expr_rc = None;
  }

let test_hover_prefers_source_type_and_shows_canonical_identity () =
  let env = Env.add_var (Env.empty ()) "user_id" Types.ty_int () in
  let expr =
    typed_ident_with_source "user_id"
      ~source_ty:(Ast.TyNamed ("UserId", []))
      ~semantic_ty:Types.ty_int
  in
  match Lsp_hover.hover_info_for_expr env expr with
  | Some hover ->
      Alcotest.(check bool)
        "source spelling is primary" true
        (contains_substring hover "user_id: UserId");
      Alcotest.(check bool)
        "canonical identity is included when different" true
        (contains_substring hover "canonical type: Int")
  | None -> Alcotest.fail "expected hover text"

let test_hover_ignores_legacy_expr_type_without_structured_metadata () =
  let expr : Ast.expr =
    {
      expr_desc = ELiteral (LitInt 1L);
      expr_loc = Ast.dummy_loc;
      expr_type = Some Types.ty_int;
      expr_type_info = None;
      expr_rc = None;
    }
  in
  match Lsp_hover.hover_info_for_expr (Env.empty ()) expr with
  | Some hover ->
      Alcotest.failf
        "legacy expr_type mirror should not produce hover without structured \
         metadata, got: %s"
        hover
  | None -> ()

let test_hover_uses_env_source_type_as_identifier_fallback () =
  let source_ty = Ast.TyNamed ("UserId", []) in
  let env =
    Env.add_var (Env.empty ()) "user_id" Types.ty_int ~source_type:source_ty ()
  in
  let expr : Ast.expr =
    {
      expr_desc = EIdent "user_id";
      expr_loc = Ast.dummy_loc;
      expr_type = None;
      expr_type_info = None;
      expr_rc = None;
    }
  in
  match Lsp_hover.hover_info_for_expr env expr with
  | Some hover ->
      Alcotest.(check bool)
        "env source spelling is primary fallback" true
        (contains_substring hover "user_id: UserId")
  | None -> Alcotest.fail "expected hover text"

let analyzed_state source =
  Test_helpers.with_isolated_env (fun () ->
      let uri = "file:///tmp/lsp_hover_integration.brp" in
      let state = Lsp_state.create () in
      let doc : Lsp_state.document =
        {
          uri;
          version = 1;
          text = source;
          diagnostics = [];
          parse_errors = [];
          program = None;
          typed_program = None;
          env = None;
          module_aliases = [];
        }
      in
      Hashtbl.add state.documents uri doc;
      Lsp_state.analyze state doc;
      if doc.diagnostics <> [] then
        Alcotest.fail
          ("expected analyzed document without diagnostics, got:\n"
          ^ Test_helpers.format_errors doc.diagnostics);
      (state, uri))

let hover_value_at state uri ~line ~character =
  let params =
    Lsp_json.Object
      [
        ("textDocument", Object [ ("uri", String uri) ]);
        ("position", Object [ ("line", Int line); ("character", Int character) ]);
      ]
  in
  match Lsp_server.handle_hover state params with
  | Object fields -> (
      match List.assoc_opt "contents" fields with
      | Some (Object contents) -> (
          match List.assoc_opt "value" contents with
          | Some (String value) -> value
          | _ -> Alcotest.fail "hover contents missing markdown value")
      | _ -> Alcotest.fail "hover response missing contents")
  | Null -> Alcotest.fail "expected hover response, got null"
  | _ -> Alcotest.fail "unexpected hover response shape"

let test_hover_integration_uses_analyzed_typed_metadata () =
  let state, uri =
    analyzed_state
      {|
func main(args: List[String]) -> Int:
    var total = 1
    sized = 1 as Int32
    total
|}
  in
  let total_literal = hover_value_at state uri ~line:2 ~character:16 in
  Alcotest.(check bool)
    "literal semantic type comes from typed metadata" true
    (contains_substring total_literal "```blorp\n#1\n```");
  Alcotest.(check bool)
    "literal hover includes value-slot" true
    (contains_substring total_literal "value-slot type: Int");
  Alcotest.(check bool)
    "literal hover includes widening" true
    (contains_substring total_literal "widening: mutable binding (#1 -> Int)");
  let ascription = hover_value_at state uri ~line:3 ~character:12 in
  Alcotest.(check bool)
    "ascription hover includes source spelling" true
    (contains_substring ascription "```blorp\nInt32\n```")

let test_hover_integration_uses_typed_declaration_metadata () =
  let state, uri =
    analyzed_state
      {|
type alias UserId = Int
type alias MaybeUserId = Option[UserId]

global_id: UserId = 1

record User {id: UserId}

func main(args: List[String]) -> Int:
    user: User = {id = 1}
    user.id
|}
  in
  let alias_hover = hover_value_at state uri ~line:2 ~character:18 in
  Alcotest.(check bool)
    "alias declaration hover keeps source target" true
    (contains_substring alias_hover "alias MaybeUserId = Option[UserId]");
  Alcotest.(check bool)
    "alias declaration hover includes canonical target" true
    (contains_substring alias_hover "canonical target: Option[Int]");
  let var_hover = hover_value_at state uri ~line:4 ~character:2 in
  Alcotest.(check bool)
    "variable declaration hover keeps source type" true
    (contains_substring var_hover "global_id: UserId");
  Alcotest.(check bool)
    "variable declaration hover includes canonical type" true
    (contains_substring var_hover "canonical binding type: Int");
  let record_hover = hover_value_at state uri ~line:6 ~character:10 in
  Alcotest.(check bool)
    "record declaration hover keeps field source type" true
    (contains_substring record_hover "record User {id: UserId}");
  Alcotest.(check bool)
    "record declaration hover includes field canonical type" true
    (contains_substring record_hover "id canonical type: Int")

let test_hover_integration_uses_typed_parameter_metadata () =
  let state, uri =
    analyzed_state
      {|
type alias UserId = Int

func consume(user_id: UserId) -> UserId:
    user_id
|}
  in
  let param_hover = hover_value_at state uri ~line:3 ~character:14 in
  Alcotest.(check bool)
    "parameter hover keeps source type" true
    (contains_substring param_hover "user_id: UserId");
  Alcotest.(check bool)
    "parameter hover includes canonical type" true
    (contains_substring param_hover "canonical parameter type: Int");
  Alcotest.(check bool)
    "parameter hover is parameter-specific" false
    (contains_substring param_hover "func consume")

let suite =
  [
    ( "format",
      [
        Alcotest.test_case
          "prefers expression source spelling and shows canonical identity"
          `Quick test_hover_prefers_source_type_and_shows_canonical_identity;
        Alcotest.test_case
          "ignores legacy expr_type without structured metadata" `Quick
          test_hover_ignores_legacy_expr_type_without_structured_metadata;
        Alcotest.test_case "uses env source type as identifier fallback" `Quick
          test_hover_uses_env_source_type_as_identifier_fallback;
        Alcotest.test_case "integration uses analyzed typed metadata" `Quick
          test_hover_integration_uses_analyzed_typed_metadata;
        Alcotest.test_case "integration uses typed declaration metadata" `Quick
          test_hover_integration_uses_typed_declaration_metadata;
        Alcotest.test_case "integration uses typed parameter metadata" `Quick
          test_hover_integration_uses_typed_parameter_metadata;
      ] );
  ]
