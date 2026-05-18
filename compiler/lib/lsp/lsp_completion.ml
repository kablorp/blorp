(** LSP completion handler.

    Provides identifier, keyword, type, and module member completions.
    Triggered on typing and after '.' for qualified access. *)

open Ast
open Lsp_json

(* ============================================================================
   Completion context detection
   ============================================================================ *)

(** Extract the prefix being typed and optional dot qualifier.
    Returns (prefix, Some module_alias) for "M.foo" or (prefix, None) for "foo". *)
let get_completion_context (text : string) (col : int) : string * string option
    =
  (* Walk backwards from cursor to find the word being typed *)
  let len = String.length text in
  let col = min col len in
  (* Find start of current identifier *)
  let rec find_start i =
    if i < 0 then 0
    else
      let c = text.[i] in
      if
        (c >= 'a' && c <= 'z')
        || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9')
        || c = '_'
      then find_start (i - 1)
      else i + 1
  in
  let ident_start = find_start (col - 1) in
  let prefix =
    if ident_start < col then String.sub text ident_start (col - ident_start)
    else ""
  in
  (* Check for dot before the identifier *)
  if ident_start > 0 && text.[ident_start - 1] = '.' then begin
    let dot_pos = ident_start - 1 in
    let qualifier_end = dot_pos in
    let rec find_qual_start i =
      if i < 0 then 0
      else
        let c = text.[i] in
        if
          (c >= 'a' && c <= 'z')
          || (c >= 'A' && c <= 'Z')
          || (c >= '0' && c <= '9')
          || c = '_'
        then find_qual_start (i - 1)
        else i + 1
    in
    let qual_start = find_qual_start (qualifier_end - 1) in
    if qual_start < qualifier_end then
      let qualifier = String.sub text qual_start (qualifier_end - qual_start) in
      (prefix, Some qualifier)
    else (prefix, None)
  end
  else (prefix, None)

(* ============================================================================
   Completion item builders
   ============================================================================ *)

let completion_item ~label ~kind ~detail ~sort_text : json =
  Object
    [
      ("label", String label);
      ("kind", Int kind);
      ("detail", String detail);
      ("sortText", String sort_text);
    ]

(* LSP CompletionItemKind constants *)
let _kind_text = 1
let kind_method = 2
let kind_function = 3
let kind_constructor = 4
let _kind_field = 5
let kind_variable = 6
let kind_class = 7
let _kind_interface = 8
let kind_keyword = 14
let kind_struct = 22

(* ============================================================================
   Keyword list
   ============================================================================ *)

let keywords =
  [
    "func";
    "pure";
    "var";
    "union";
    "record";
    "void";
    "while";
    "for";
    "in";
    "if";
    "else";
    "and";
    "or";
    "not";
    "match";
    "True";
    "False";
    "break";
    "continue";
    "try";
    "debug";
    "struct";
    "enum";
    "foreign";
    "private";
    "builtin";
    "concurrent";
    "detach";
    "import";
    "as";
    "trait";
    "implements";
    "type";
    "alias";
    "where";
    "return";
  ]

(* ============================================================================
   Completion sources
   ============================================================================ *)

(** Case-insensitive prefix match *)
let starts_with_ci prefix s =
  let plen = String.length prefix in
  let slen = String.length s in
  if plen > slen then false
  else
    let rec check i =
      if i >= plen then true
      else
        let a = Char.lowercase_ascii prefix.[i] in
        let b = Char.lowercase_ascii s.[i] in
        if a = b then check (i + 1) else false
    in
    check 0

(** Build completion items from environment identifiers *)
let completions_from_env ?(skip = fun _ -> false) (env : Env.env)
    (prefix : string) : json list =
  let items = ref [] in
  let seen = Hashtbl.create 64 in
  List.iter
    (fun scope ->
      List.iter
        (fun (sym : Env.symbol) ->
          if
            (not (Hashtbl.mem seen sym.name))
            && starts_with_ci prefix sym.name
            && not (skip sym.name)
          then begin
            Hashtbl.add seen sym.name true;
            let item =
              match sym.kind with
              | Env.FuncSymbol { func_type; purity; _ } ->
                  let pure_str =
                    match purity with Env.Pure -> "pure " | Env.Impure -> ""
                  in
                  Some
                    (completion_item ~label:sym.name ~kind:kind_function
                       ~detail:
                         (Printf.sprintf "%sfunc: %s" pure_str
                            (Types.type_to_string func_type))
                       ~sort_text:("0_" ^ sym.name))
              | Env.VarSymbol { var_type; source_type; _ } ->
                  let display_ty = Option.value source_type ~default:var_type in
                  Some
                    (completion_item ~label:sym.name ~kind:kind_variable
                       ~detail:(Types.type_to_string display_ty)
                       ~sort_text:("0_" ^ sym.name))
              | Env.ConstructorSymbol { parent_type; field_types; _ } ->
                  let fields = Lsp_protocol.format_field_types field_types in
                  Some
                    (completion_item ~label:sym.name ~kind:kind_constructor
                       ~detail:
                         (Printf.sprintf "%s%s  (from %s)" sym.name fields
                            parent_type)
                       ~sort_text:("1_" ^ sym.name))
              | Env.TypeSymbol { type_params; _ } ->
                  let params = Lsp_protocol.format_type_params type_params in
                  Some
                    (completion_item ~label:sym.name ~kind:kind_class
                       ~detail:(Printf.sprintf "union %s%s" sym.name params)
                       ~sort_text:("2_" ^ sym.name))
              | Env.RecordSymbol { type_params; is_value; _ } ->
                  let params = Lsp_protocol.format_type_params type_params in
                  let kw = if is_value then "struct" else "record" in
                  let k = if is_value then kind_struct else kind_class in
                  Some
                    (completion_item ~label:sym.name ~kind:k
                       ~detail:(Printf.sprintf "%s %s%s" kw sym.name params)
                       ~sort_text:("2_" ^ sym.name))
              | Env.AliasSymbol { target; _ } ->
                  Some
                    (completion_item ~label:sym.name ~kind:kind_class
                       ~detail:
                         (Printf.sprintf "alias %s = %s" sym.name
                            (Types.type_to_string target))
                       ~sort_text:("2_" ^ sym.name))
            in
            match item with Some i -> items := i :: !items | None -> ()
          end)
        scope)
    env.scopes;
  List.rev !items

let typed_func_completion_detail (func : Typed_ast.func_decl) name =
  let ast = Typed_ast.func_ast func in
  let pure_str = if ast.func_is_pure then "pure " else "" in
  let params =
    Typed_ast.func_param_infos func
    |> List.mapi (fun index param ->
        let pname =
          match param.Typed_ast.param_name with
          | Some name -> name
          | None -> Printf.sprintf "arg%d" index
        in
        Printf.sprintf "%s: %s" pname
          (Types.type_to_string param.source_param_ty))
  in
  let info = Typed_ast.func_info func in
  let ret_ty =
    match info.source_return_ty with
    | Some ty -> ty
    | None -> Typed_ast.func_semantic_return_type func
  in
  Printf.sprintf "%sfunc %s(%s) -> %s" pure_str name
    (String.concat ", " params)
    (Types.type_to_string ret_ty)

let completions_from_typed_program ?file (program : Typed_ast.program)
    (prefix : string) : json list * (string, unit) Hashtbl.t =
  let items = ref [] in
  let names = Hashtbl.create 32 in
  let add name kind detail sort_group =
    if starts_with_ci prefix name && not (Hashtbl.mem names name) then begin
      Hashtbl.add names name ();
      items :=
        completion_item ~label:name ~kind ~detail
          ~sort_text:(Printf.sprintf "%s_%s" sort_group name)
        :: !items
    end
  in
  let loc_matches_file loc =
    match file with
    | None -> true
    | Some expected -> loc.loc_file = Some expected
  in
  program |> Typed_ast.program_decls
  |> List.iter (fun decl ->
      let ast_decl = Typed_ast.decl_ast decl in
      if loc_matches_file ast_decl.decl_loc then
        match Typed_ast.decl_view decl with
        | DeclFunction func -> (
            match (Typed_ast.func_ast func).func_name with
            | Some name ->
                add name kind_function
                  (typed_func_completion_detail func name)
                  "0"
            | None -> ())
        | DeclVar var -> (
            let ast = Typed_ast.var_ast var in
            match ast.var_name with
            | Some name ->
                let info = Typed_ast.var_info var in
                let display_ty =
                  Option.value info.source_binding_ty ~default:info.binding_ty
                in
                add name kind_variable (Types.type_to_string display_ty) "0"
            | None -> ())
        | DeclRecord record ->
            let ast = Typed_ast.record_ast record in
            let params =
              ast.record_type_params |> Ast.type_param_names
              |> Lsp_protocol.format_type_params
            in
            let kw = if ast.record_is_value then "struct" else "record" in
            let kind =
              if ast.record_is_value then kind_struct else kind_class
            in
            add ast.record_name kind
              (Printf.sprintf "%s %s%s" kw ast.record_name params)
              "2"
        | DeclTypeAlias alias ->
            let ast = Typed_ast.type_alias_ast alias in
            let info = Typed_ast.type_alias_info alias in
            add ast.alias_name kind_class
              (Printf.sprintf "alias %s = %s" ast.alias_name
                 (Types.type_to_string info.source_target_ty))
              "2"
        | DeclPrivate inner -> (
            match Typed_ast.decl_view inner with
            | DeclFunction func -> (
                match (Typed_ast.func_ast func).func_name with
                | Some name ->
                    add name kind_function
                      (typed_func_completion_detail func name)
                      "0"
                | None -> ())
            | DeclVar var -> (
                let ast = Typed_ast.var_ast var in
                match ast.var_name with
                | Some name ->
                    let info = Typed_ast.var_info var in
                    let display_ty =
                      Option.value info.source_binding_ty
                        ~default:info.binding_ty
                    in
                    add name kind_variable (Types.type_to_string display_ty) "0"
                | None -> ())
            | _ -> ())
        | DeclImpl _ | DeclOther -> ());
  (List.rev !items, names)

let loc_starts_before_cursor loc ~line ~character =
  let loc_line = loc.line - 1 in
  let loc_col = loc.column - 1 in
  loc_line < line || (loc_line = line && loc_col <= character)

let type_detail_opt = function
  | Some ty -> Types.type_to_string ty
  | None -> "local"

let expr_source_type_opt expr =
  match expr.expr_type_info with
  | Some { source_ty = Some ty; _ } -> Some ty
  | Some { semantic_ty; _ } -> Some semantic_ty
  | None -> None

let completions_from_local_scope ?(skip = fun _ -> false) (program : program)
    ~(line : int) ~(character : int) (prefix : string) :
    json list * (string, unit) Hashtbl.t =
  let items = ref [] in
  let names = Hashtbl.create 16 in
  let add name detail =
    if
      starts_with_ci prefix name
      && (not (Hashtbl.mem names name))
      && not (skip name)
    then begin
      Hashtbl.add names name ();
      items :=
        completion_item ~label:name ~kind:kind_variable ~detail
          ~sort_text:("0_" ^ name)
        :: !items
    end
  in
  let add_param (param : Ast.param) =
    match param.param_name with
    | Some name -> add name (type_detail_opt param.param_type)
    | None ->
        param.param_pattern
        |> Option.iter (fun pat ->
            pat |> Ast.collect_pattern_vars
            |> List.iter (fun name ->
                add name (type_detail_opt param.param_type)))
  in
  let rec collect_expr (expr : expr) =
    if loc_starts_before_cursor expr.expr_loc ~line ~character then
      match expr.expr_desc with
      | EVarDecl (name, source_ty, init, _) ->
          let detail =
            match source_ty with
            | Some ty -> Types.type_to_string ty
            | None -> type_detail_opt (expr_source_type_opt init)
          in
          add name detail;
          collect_expr init
      | ETupleDestruct (names, init) ->
          List.iter (fun name -> add name "local") names;
          collect_expr init
      | EFor (name, iter, body) ->
          collect_expr iter;
          add name "loop variable";
          collect_expr body
      | EForTuple (names, iter, body) ->
          collect_expr iter;
          List.iter (fun name -> add name "loop variable") names;
          collect_expr body
      | ETryBind (name, source_ty, init) ->
          add name (type_detail_opt source_ty);
          collect_expr init
      | EConcurrentBind (name, source_ty, init) ->
          add name (type_detail_opt source_ty);
          collect_expr init
      | EConcurrentFor (name, iter, body, timeout, _) ->
          collect_expr iter;
          add name "loop variable";
          collect_expr body;
          Option.iter collect_expr timeout
      | EMatch (scrutinee, cases) ->
          collect_expr scrutinee;
          List.iter
            (fun case ->
              if loc_starts_before_cursor case.case_loc ~line ~character then
                case.case_pattern |> Ast.collect_pattern_vars
                |> List.iter (fun name -> add name "pattern binding");
              collect_expr case.case_body)
            cases
      | ELambda _ | EFuncDecl _ -> ()
      | _ -> List.iter collect_expr (expr_children expr)
  in
  let best_func = ref None in
  let consider_func decl_loc fd =
    if loc_starts_before_cursor decl_loc ~line ~character then
      match !best_func with
      | Some (best_loc, _) when best_loc.line > decl_loc.line -> ()
      | Some (best_loc, _)
        when best_loc.line = decl_loc.line && best_loc.column >= decl_loc.column
        ->
          ()
      | _ -> best_func := Some (decl_loc, fd)
  in
  List.iter
    (fun decl ->
      match decl.decl_desc with
      | DFunc fd -> consider_func decl.decl_loc fd
      | DImpl impl ->
          List.iter (fun fd -> consider_func decl.decl_loc fd) impl.impl_methods
      | DPrivate { decl_desc = DFunc fd; decl_loc; _ } ->
          consider_func decl_loc fd
      | _ -> ())
    program;
  (match !best_func with
  | Some (_, fd) ->
      List.iter add_param fd.func_params;
      fd.func_body |> func_body_expr_opt |> Option.iter collect_expr
  | None -> ());
  (List.rev !items, names)

(** Build keyword completion items *)
let completions_from_keywords (prefix : string) : json list =
  List.filter_map
    (fun kw ->
      if starts_with_ci prefix kw then
        Some
          (completion_item ~label:kw ~kind:kind_keyword ~detail:"keyword"
             ~sort_text:("3_" ^ kw))
      else None)
    keywords

(** Build completion items from module exports *)
let find_cached_module module_path =
  match Modules.find_cached module_path with
  | Some _ as m -> m
  | None ->
      if
        (not (String.starts_with ~prefix:"std/" module_path))
        && (not (String.starts_with ~prefix:"pkg/" module_path))
        && (not (String.starts_with ~prefix:"./" module_path))
        && not (String.starts_with ~prefix:"../" module_path)
      then Modules.find_cached ("std/" ^ module_path)
      else None

let completions_from_module (module_path : string) (prefix : string) : json list
    =
  match find_cached_module module_path with
  | None -> []
  | Some m ->
      List.concat_map
        (fun (name, (d : decl)) ->
          let item label kind detail =
            if starts_with_ci prefix label then
              [ completion_item ~label ~kind ~detail ~sort_text:("0_" ^ label) ]
            else []
          in
          match d.decl_desc with
          | DFunc fd ->
              let label, _ = Lsp_protocol.format_func_decl fd name in
              item name kind_function label
          | DType td ->
              let params =
                Lsp_protocol.format_type_params
                  (Ast.type_param_names td.type_params)
              in
              let kw = if td.type_is_enum then "enum" else "union" in
              let type_item =
                item name kind_class (Printf.sprintf "%s %s%s" kw name params)
              in
              let variant_items =
                List.concat_map
                  (fun (variant : Ast.variant) ->
                    let fields =
                      Lsp_protocol.format_field_types variant.variant_fields
                    in
                    item variant.variant_name kind_constructor
                      (Printf.sprintf "%s%s  (from %s)" variant.variant_name
                         fields td.type_name))
                  td.type_variants
              in
              type_item @ variant_items
          | DRecord rd ->
              let k = if rd.record_is_value then kind_struct else kind_class in
              let kw = if rd.record_is_value then "struct" else "record" in
              let params =
                Lsp_protocol.format_type_params
                  (Ast.type_param_names rd.record_type_params)
              in
              item name k (Printf.sprintf "%s %s%s" kw name params)
          | DVar _ -> item name kind_variable name
          | DTrait td ->
              item name kind_class (Printf.sprintf "trait %s" td.trait_name)
          | DTypeAlias ad ->
              item name kind_class
                (Printf.sprintf "alias %s = %s" name
                   (Types.type_to_string ad.alias_target))
          | DImpl _ -> item name kind_method (Printf.sprintf "impl %s" name)
          | DImport _ | DPrivate _ -> item name kind_variable name)
        m.exports

(* ============================================================================
   Main handler
   ============================================================================ *)

let handle_completion (state : Lsp_state.state) (params : json) : json =
  let td = get "textDocument" params in
  let pos = get "position" params in
  match (td, pos) with
  | Some td, Some pos_json -> (
      let uri = Lsp_protocol.get_uri td in
      let position = Lsp_protocol.position_of_json pos_json in
      match (Lsp_state.find_document state uri, position) with
      | Some doc, Some pos ->
          (* Get the current line text *)
          let lines = String.split_on_char '\n' doc.text in
          let line_text =
            if pos.line < List.length lines then List.nth lines pos.line else ""
          in
          let prefix, qualifier =
            get_completion_context line_text pos.character
          in
          let items =
            match qualifier with
            | Some alias -> (
                (* Module-qualified completion: look up alias *)
                match List.assoc_opt alias doc.module_aliases with
                | Some path -> completions_from_module path prefix
                | None -> [])
            | None ->
                (* General completion: identifiers + keywords *)
                let file = Lsp_protocol.uri_to_path uri in
                let typed_items, typed_names =
                  match doc.typed_program with
                  | Some typed_program ->
                      completions_from_typed_program typed_program ~file prefix
                  | None -> ([], Hashtbl.create 0)
                in
                let local_items, local_names =
                  match doc.program with
                  | Some program ->
                      completions_from_local_scope program ~line:pos.line
                        ~character:pos.character prefix ~skip:(fun name ->
                          Hashtbl.mem typed_names name)
                  | None -> ([], Hashtbl.create 0)
                in
                Hashtbl.iter
                  (fun name () -> Hashtbl.replace typed_names name ())
                  local_names;
                let env_items =
                  match doc.env with
                  | Some env ->
                      completions_from_env
                        ~skip:(fun name -> Hashtbl.mem typed_names name)
                        env prefix
                  | None -> []
                in
                let kw_items = completions_from_keywords prefix in
                typed_items @ local_items @ env_items @ kw_items
          in
          Object [ ("isIncomplete", Bool false); ("items", Array items) ]
      | _ -> Object [ ("isIncomplete", Bool false); ("items", Array []) ])
  | _ -> Object [ ("isIncomplete", Bool false); ("items", Array []) ]
