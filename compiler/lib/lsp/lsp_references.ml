(** Same-file references and document highlights.

    This is intentionally LSP-owned analysis. It reuses the compiler's current
    definition resolver for each candidate occurrence so local shadowing follows
    the same rules as go-to-definition. A later symbol-index layer can replace
    the candidate/filter implementation without changing the protocol handlers.
*)

open Ast
open Lsp_json

type occurrence = { name : string; loc : loc }

let loc_same_position a b =
  a.line = b.line && a.column = b.column
  && Option.equal String.equal a.loc_file b.loc_file

let loc_matches_file ?file loc =
  match file with None -> true | Some expected -> loc.loc_file = Some expected

let add_occurrence occurrences ?file name loc =
  if name <> "_" && loc_matches_file ?file loc then
    occurrences := { name; loc } :: !occurrences

let collect_param occurrences ?file (param : param) =
  match param.param_name with
  | Some name -> add_occurrence occurrences ?file name param.param_loc
  | None ->
      (* Pattern parameter locations are currently only attached to the whole
         parameter. Keep the occurrence useful for references, even though the
         range may cover the start of the pattern instead of the exact binder. *)
      param.param_pattern
      |> Option.iter (fun pat ->
          pat |> Ast.collect_pattern_vars
          |> List.iter (fun name ->
              add_occurrence occurrences ?file name param.param_loc))

let collect_pattern_bindings occurrences ?file pattern loc =
  pattern |> Ast.collect_pattern_vars
  |> List.iter (fun name -> add_occurrence occurrences ?file name loc)

let rec collect_expr occurrences ?file (expr : expr) =
  let collect = collect_expr occurrences ?file in
  let add name = add_occurrence occurrences ?file name expr.expr_loc in
  match expr.expr_desc with
  | EIdent name -> add name
  | EAssign (name, value) | ECompoundAssign (name, _, value) ->
      add name;
      collect value
  | EVarDecl (name, _, init, _) ->
      add name;
      collect init
  | ETupleDestruct (names, init) ->
      List.iter add names;
      collect init
  | EFor (name, iter, body) ->
      collect iter;
      add name;
      collect body
  | EForTuple (names, iter, body) ->
      collect iter;
      List.iter add names;
      collect body
  | EQuestionBind (name, _, init) ->
      add name;
      collect init
  | EWith (binding, body) ->
      collect binding.with_value;
      add_occurrence occurrences ?file binding.with_name expr.expr_loc;
      Option.iter
        (fun mapper ->
          add_occurrence occurrences ?file mapper.with_error_name expr.expr_loc;
          collect mapper.with_error_value)
        binding.with_error_map;
      collect body
  | EConcurrentBind (name, _, init) ->
      add name;
      collect init
  | EConcurrentlyLoop (name, iter, body, timeout, _) ->
      collect iter;
      add name;
      collect body;
      Option.iter collect timeout
  | EMatch (scrutinee, cases) ->
      collect scrutinee;
      List.iter
        (fun case ->
          collect_pattern_bindings occurrences ?file case.case_pattern
            case.case_loc;
          collect case.case_body)
        cases
  | ESelect arms ->
      List.iter
        (fun arm ->
          match arm.select_arm_kind with
          | SelectRecv { select_bind; select_channel } ->
              collect select_channel;
              add_occurrence occurrences ?file select_bind arm.select_arm_loc;
              collect arm.select_arm_body
          | SelectAfter timeout ->
              collect timeout;
              collect arm.select_arm_body
          | SelectSealed channel ->
              collect channel;
              collect arm.select_arm_body)
        arms
  | ELambda func | EFuncDecl func -> collect_func occurrences ?file func
  | _ -> List.iter collect (Ast.expr_children expr)

and collect_func occurrences ?file (func : func_decl) =
  List.iter (collect_param occurrences ?file) func.func_params;
  func.func_body |> Ast.func_body_expr_opt
  |> Option.iter (collect_expr occurrences ?file)

let rec collect_decl occurrences ?file (decl : decl) =
  let add name loc = add_occurrence occurrences ?file name loc in
  match decl.decl_desc with
  | DFunc func ->
      Option.iter
        (fun name ->
          add name (Lsp_position.func_decl_name_loc decl.decl_loc func))
        func.func_name;
      collect_func occurrences ?file func
  | DVar var ->
      Option.iter (fun name -> add name decl.decl_loc) var.var_name;
      Option.iter
        (fun pat ->
          collect_pattern_bindings occurrences ?file pat decl.decl_loc)
        var.var_pattern;
      collect_expr occurrences ?file var.var_value
  | DCompileTimeBlock bindings ->
      List.iter
        (fun binding ->
          let var = binding.ctb_var in
          Option.iter (fun name -> add name binding.ctb_loc) var.var_name;
          Option.iter
            (fun pat ->
              collect_pattern_bindings occurrences ?file pat binding.ctb_loc)
            var.var_pattern;
          collect_expr occurrences ?file var.var_value)
        bindings
  | DType type_decl ->
      add type_decl.type_name decl.decl_loc;
      List.iter
        (fun variant -> add variant.variant_name variant.variant_loc)
        type_decl.type_variants
  | DRecord record ->
      add record.record_name decl.decl_loc;
      List.iter
        (fun field -> add field.field_name field.field_loc)
        record.record_fields
  | DTrait trait ->
      add trait.trait_name decl.decl_loc;
      List.iter
        (fun method_ -> add method_.method_name decl.decl_loc)
        trait.trait_methods
  | DImpl impl -> List.iter (collect_func occurrences ?file) impl.impl_methods
  | DTypeAlias alias -> add alias.alias_name decl.decl_loc
  | DPrivate inner -> collect_decl occurrences ?file inner
  | DImport _ -> ()

let collect_program ?file (program : program) =
  let occurrences = ref [] in
  List.iter (collect_decl occurrences ?file) program;
  List.rev !occurrences

let loc_inside_name loc name ~(line : int) ~(character : int) =
  let target_line = line + 1 in
  let target_col = character + 1 in
  loc.line = target_line && loc.column <= target_col
  && target_col <= loc.column + String.length name

let record_field_declaration_at_cursor ?file program pos =
  let rec find_in_decl decl =
    match decl.decl_desc with
    | DRecord record ->
        record.record_fields
        |> List.find_opt (fun field ->
            loc_matches_file ?file field.field_loc
            && loc_inside_name field.field_loc field.field_name
                 ~line:pos.Lsp_protocol.line ~character:pos.character)
        |> Option.map (fun field -> field.field_loc)
    | DPrivate inner -> find_in_decl inner
    | _ -> None
  in
  List.find_map find_in_decl program

let field_definition_at_cursor doc program env pos =
  let file = Lsp_protocol.uri_to_path doc.Lsp_state.uri in
  match
    Lsp_position.find_record_field_assignment_hit
      ~module_aliases:doc.module_aliases ~file env program ~text:doc.text
      ~line:pos.Lsp_protocol.line ~col:pos.character
  with
  | Some hit -> Some hit.field_loc
  | None -> (
      match
        Lsp_position.find_record_field_definition env program ~text:doc.text
          ~line:pos.Lsp_protocol.line ~col:pos.character
      with
      | Some _ as result -> result
      | None -> record_field_declaration_at_cursor ~file program pos)

let occurrence_loc_of_span ?file (line, start_col, end_col) =
  {
    line = line + 1;
    column = start_col + 1;
    end_line = line + 1;
    end_column = end_col + 1;
    loc_file = file;
  }

let collect_field_occurrences doc env program target =
  let file = Lsp_protocol.uri_to_path doc.Lsp_state.uri in
  let occurrences = ref [] in
  let add name loc =
    if loc_matches_file ~file loc && loc_same_position loc target then
      add_occurrence occurrences ~file name loc
  in
  let add_field_access receiver field_name =
    match Lsp_position.expr_type_opt receiver with
    | Some receiver_ty -> (
        match
          Lsp_position.record_field_loc ~module_aliases:doc.module_aliases env
            receiver_ty field_name
        with
        | Some field_loc when loc_same_position field_loc target -> (
            match
              Lsp_position.field_span_after_receiver doc.text receiver.expr_loc
                field_name
            with
            | Some span ->
                let loc = occurrence_loc_of_span ~file span in
                add_occurrence occurrences ~file field_name loc
            | None -> ())
        | _ -> ())
    | None -> ()
  in
  let add_record_assignment_fields expr =
    Lsp_position.record_field_assignment_hits_for_expr
      ~module_aliases:doc.module_aliases ~file env doc.text expr
    |> List.iter (fun (hit : Lsp_position.record_field_hit) ->
        if loc_same_position hit.field_loc target then
          add_occurrence occurrences ~file hit.field_name hit.occurrence_loc)
  in
  let rec collect_expr expr =
    match expr.expr_desc with
    | ERecord _ | ERecordUpdate _ ->
        add_record_assignment_fields expr;
        List.iter collect_expr (expr_children expr)
    | EFieldAccess (receiver, field_name) ->
        add_field_access receiver field_name;
        collect_expr receiver
    | _ -> List.iter collect_expr (expr_children expr)
  in
  let rec collect_decl decl =
    match decl.decl_desc with
    | DRecord record ->
        List.iter
          (fun field -> add field.field_name field.field_loc)
          record.record_fields
    | DFunc func -> collect_func func
    | DVar var -> collect_expr var.var_value
    | DCompileTimeBlock bindings ->
        List.iter
          (fun binding -> collect_expr binding.ctb_var.var_value)
          bindings
    | DImpl impl -> List.iter collect_func impl.impl_methods
    | DPrivate inner -> collect_decl inner
    | DType _ | DImport _ | DTrait _ | DTypeAlias _ -> ()
  and collect_func func =
    func.func_body |> Ast.func_body_expr_opt |> Option.iter collect_expr
  in
  List.iter collect_decl program;
  List.rev !occurrences

let collect_type_param_occurrences doc program
    (target : Lsp_position.type_param_hit) =
  let file = Lsp_protocol.uri_to_path doc.Lsp_state.uri in
  Lsp_position.collect_function_type_param_occurrences ~file program
    ~text:doc.text target
  |> List.map (fun loc -> { name = target.type_param_name; loc })

let definition_for_occurrence program occurrence =
  Lsp_position.find_definition program ~name:occurrence.name
    ~line:(max 0 (occurrence.loc.line - 1))
    ~col:(max 0 (occurrence.loc.column - 1))

let definition_at_cursor doc program pos =
  match
    Lsp_position.word_at doc.Lsp_state.text ~line:pos.Lsp_protocol.line
      ~col:pos.character
  with
  | None -> None
  | Some name ->
      Lsp_position.find_definition program ~name ~line:pos.line
        ~col:pos.character

let occurrence_matches_definition program target occurrence =
  match definition_for_occurrence program occurrence with
  | Some loc -> loc_same_position loc target
  | None -> false

let occurrence_range occurrence =
  let start_pos = Lsp_protocol.loc_to_position occurrence.loc in
  {
    Lsp_protocol.start = start_pos;
    end_ =
      {
        start_pos with
        character = start_pos.character + String.length occurrence.name;
      };
  }

let location_json uri occurrence =
  Lsp_protocol.location_json ~uri ~range:(occurrence_range occurrence)

let document_highlight_json occurrence =
  Object
    [
      ("range", Lsp_protocol.range_to_json (occurrence_range occurrence));
      ("kind", Int 1);
    ]

let matching_occurrences doc program pos =
  let file = Lsp_protocol.uri_to_path doc.Lsp_state.uri in
  match
    Lsp_position.find_function_type_param_at program ~file ~text:doc.text
      ~line:pos.Lsp_protocol.line ~col:pos.character
  with
  | Some target -> collect_type_param_occurrences doc program target
  | None -> (
      match doc.Lsp_state.env with
      | Some env -> (
          match field_definition_at_cursor doc program env pos with
          | Some target -> collect_field_occurrences doc env program target
          | None -> (
              match definition_at_cursor doc program pos with
              | None -> []
              | Some target ->
                  collect_program ~file program
                  |> List.filter (occurrence_matches_definition program target))
          )
      | None -> (
          match definition_at_cursor doc program pos with
          | None -> []
          | Some target ->
              collect_program ~file program
              |> List.filter (occurrence_matches_definition program target)))

let handle_references (state : Lsp_state.state) (params : json) : json =
  match (get "textDocument" params, get "position" params) with
  | Some td, Some pos_json -> (
      let uri = Lsp_protocol.get_uri td in
      match
        ( Lsp_state.find_document state uri,
          Lsp_protocol.position_of_json pos_json )
      with
      | Some doc, Some pos -> (
          match doc.program with
          | Some program ->
              matching_occurrences doc program pos
              |> List.map (location_json uri)
              |> fun locations -> Array locations
          | None -> Array [])
      | _ -> Array [])
  | _ -> Array []

let handle_document_highlight (state : Lsp_state.state) (params : json) : json =
  match (get "textDocument" params, get "position" params) with
  | Some td, Some pos_json -> (
      let uri = Lsp_protocol.get_uri td in
      match
        ( Lsp_state.find_document state uri,
          Lsp_protocol.position_of_json pos_json )
      with
      | Some doc, Some pos -> (
          match doc.program with
          | Some program ->
              matching_occurrences doc program pos
              |> List.map document_highlight_json
              |> fun highlights -> Array highlights
          | None -> Array [])
      | _ -> Array [])
  | _ -> Array []
