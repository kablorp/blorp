(** LSP completion handler.

    Provides identifier, keyword, type, and module member completions.
    Triggered on typing and after '.' for qualified access. *)

open Ast
open Lsp_json

(* ============================================================================
   Completion context detection
   ============================================================================ *)

let clamp_cursor text col =
  let len = String.length text in
  max 0 (min col len)

let rec identifier_start_before text index =
  if index < 0 then 0
  else if Lsp_position.is_ident_char text.[index] then
    identifier_start_before text (index - 1)
  else index + 1

let identifier_at_cursor text ~col =
  let col = clamp_cursor text col in
  let start = identifier_start_before text (col - 1) in
  let text = if start < col then String.sub text start (col - start) else "" in
  (start, text)

(** Extract the prefix being typed and optional dot qualifier.
    Returns (prefix, Some module_alias) for "M.foo" or (prefix, None) for "foo". *)
let get_completion_context (text : string) (col : int) : string * string option
    =
  let ident_start, prefix = identifier_at_cursor text ~col in
  (* Check for dot before the identifier *)
  if ident_start > 0 && text.[ident_start - 1] = '.' then begin
    let dot_pos = ident_start - 1 in
    let qualifier_end = dot_pos in
    let qual_start = identifier_start_before text (qualifier_end - 1) in
    if qual_start < qualifier_end then
      let qualifier = String.sub text qual_start (qualifier_end - qual_start) in
      (prefix, Some qualifier)
    else (prefix, None)
  end
  else (prefix, None)

let last_char_between text ch start stop =
  let stop = min stop (String.length text) in
  let rec loop i found =
    if i >= stop then found
    else loop (i + 1) (if text.[i] = ch then Some i else found)
  in
  loop (max 0 start) None

let last_char_before = Lsp_position.last_char_before
let char_between = Lsp_position.char_between
let is_identifier_text = Lsp_position.is_identifier_text

let is_type_completion_context (text : string) (col : int) =
  Lsp_position.is_type_name_context text col

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
let kind_method = 2
let kind_function = 3
let kind_constructor = 4
let kind_field = 5
let kind_variable = 6
let kind_class = 7
let kind_interface = 8
let kind_keyword = 14
let kind_struct = 22
let kind_type_parameter = 25

(* ============================================================================
   Keyword list
   ============================================================================ *)

let keywords = Language_surface.lsp_completion_keywords

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

let is_qualified_type_name text =
  text |> String.split_on_char '.'
  |> List.for_all (fun part -> part <> "" && is_identifier_text part)

let split_type_args text =
  let len = String.length text in
  let add_segment start stop acc =
    let segment = String.sub text start (stop - start) |> String.trim in
    if segment = "" then None else Some (segment :: acc)
  in
  let rec loop depth segment_start i acc =
    if i >= len then
      if depth <> 0 then None
      else add_segment segment_start len acc |> Option.map List.rev
    else
      match text.[i] with
      | '[' -> loop (depth + 1) segment_start (i + 1) acc
      | ']' when depth = 0 -> None
      | ']' -> loop (depth - 1) segment_start (i + 1) acc
      | ',' when depth = 0 -> (
          match add_segment segment_start i acc with
          | Some acc -> loop depth (i + 1) (i + 1) acc
          | None -> None)
      | _ -> loop depth segment_start (i + 1) acc
  in
  loop 0 0 0 []

let rec collect_options = function
  | [] -> Some []
  | None :: _ -> None
  | Some value :: rest ->
      collect_options rest |> Option.map (fun values -> value :: values)

let rec parse_simple_type_expr text =
  let text = String.trim text in
  let len = String.length text in
  if text = "" then None
  else
    match String.index_opt text '[' with
    | None ->
        if is_qualified_type_name text then Some (TyNamed (text, [])) else None
    | Some open_index -> (
        if len < 3 || text.[len - 1] <> ']' then None
        else
          let name = String.sub text 0 open_index |> String.trim in
          let args_text =
            String.sub text (open_index + 1) (len - open_index - 2)
          in
          if not (is_qualified_type_name name) then None
          else
            match split_type_args args_text with
            | None -> None
            | Some args ->
                args
                |> List.map parse_simple_type_expr
                |> collect_options
                |> Option.map (fun args -> TyNamed (name, args)))

let loc_matches_optional_file ?file loc =
  match file with None -> true | Some expected -> loc.loc_file = Some expected

let type_decl_keyword (decl : Ast.type_decl) =
  if decl.type_is_resource then "resource type"
  else if decl.type_is_builtin then "type"
  else if decl.type_is_enum then "enum"
  else "union"

let env_type_kind_keyword = function
  | Env.TypeResource -> "resource type"
  | Env.TypeBuiltin -> "type"
  | Env.TypeEnum -> "enum"
  | Env.TypeUnion -> "union"

let type_decl_detail label (decl : Ast.type_decl) =
  let params =
    decl.type_params |> Ast.type_param_names |> Lsp_protocol.format_type_params
  in
  Printf.sprintf "%s %s%s" (type_decl_keyword decl) label params

let record_decl_detail label (decl : Ast.record_decl) =
  let params =
    decl.record_type_params |> Ast.type_param_names
    |> Lsp_protocol.format_type_params
  in
  let kw = if decl.record_is_value then "struct" else "record" in
  Printf.sprintf "%s %s%s" kw label params

let trait_decl_detail label (decl : Ast.trait_decl) =
  let params =
    decl.trait_type_params |> Ast.type_param_names
    |> Lsp_protocol.format_type_params
  in
  Printf.sprintf "trait %s%s" label params

let type_alias_detail label (decl : Ast.type_alias_decl) =
  let kw = if decl.alias_is_opaque then "opaque type" else "alias" in
  Printf.sprintf "%s %s = %s" kw label (Types.type_to_string decl.alias_target)

let env_type_symbol_detail label type_params type_kind =
  let params = Lsp_protocol.format_type_params type_params in
  Printf.sprintf "%s %s%s" (env_type_kind_keyword type_kind) label params

let env_record_symbol_detail label type_params is_value =
  let params = Lsp_protocol.format_type_params type_params in
  let kw = if is_value then "struct" else "record" in
  Printf.sprintf "%s %s%s" kw label params

let env_trait_detail (trait : Env.trait_def) =
  let params = Lsp_protocol.format_type_params trait.td_type_params in
  Printf.sprintf "trait %s%s" trait.td_name params

let add_visible_completion seen items prefix label kind detail sort_group =
  if starts_with_ci prefix label && not (Hashtbl.mem seen label) then begin
    Hashtbl.add seen label ();
    items :=
      completion_item ~label ~kind ~detail
        ~sort_text:(Printf.sprintf "%s_%s" sort_group label)
      :: !items
  end

let rec add_source_type_decl_completion add label decl =
  match decl.decl_desc with
  | DType type_decl ->
      add label kind_class (type_decl_detail label type_decl) "0"
  | DRecord record_decl ->
      let kind =
        if record_decl.record_is_value then kind_struct else kind_class
      in
      add label kind (record_decl_detail label record_decl) "0"
  | DTrait trait_decl ->
      add label kind_interface (trait_decl_detail label trait_decl) "0"
  | DTypeAlias alias_decl ->
      add label kind_class (type_alias_detail label alias_decl) "0"
  | DPrivate inner -> add_source_type_decl_completion add label inner
  | DFunc _ | DVar _ | DImport _ | DImpl _ -> ()

let rec source_type_label decl =
  match decl.decl_desc with
  | DType type_decl -> Some type_decl.type_name
  | DRecord record_decl -> Some record_decl.record_name
  | DTrait trait_decl -> Some trait_decl.trait_name
  | DTypeAlias alias_decl -> Some alias_decl.alias_name
  | DPrivate inner -> source_type_label inner
  | DFunc _ | DVar _ | DImport _ | DImpl _ -> None

let completions_from_source_types ?file ?(skip = fun _ -> false)
    (program : program) (prefix : string) : json list * (string, unit) Hashtbl.t
    =
  let items = ref [] in
  let names = Hashtbl.create 32 in
  let add label kind detail sort_group =
    if not (skip label) then
      add_visible_completion names items prefix label kind detail sort_group
  in
  program
  |> List.iter (fun decl ->
      if loc_matches_optional_file ?file decl.decl_loc then
        match source_type_label decl with
        | Some label -> add_source_type_decl_completion add label decl
        | None -> ());
  (List.rev !items, names)

let completions_from_env_types ?(skip = fun _ -> false) (env : Env.env)
    (prefix : string) : json list =
  let items = ref [] in
  let seen = Hashtbl.create 64 in
  let add label kind detail sort_group =
    if not (skip label) then
      add_visible_completion seen items prefix label kind detail sort_group
  in
  List.iter
    (fun scope ->
      List.iter
        (fun (sym : Env.symbol) ->
          match sym.kind with
          | Env.TypeSymbol { type_params; type_kind; _ } ->
              add sym.name kind_class
                (env_type_symbol_detail sym.name type_params type_kind)
                "1"
          | Env.RecordSymbol { type_params; is_value; _ } ->
              let kind = if is_value then kind_struct else kind_class in
              add sym.name kind
                (env_record_symbol_detail sym.name type_params is_value)
                "1"
          | Env.AliasSymbol { target; _ } ->
              add sym.name kind_class
                (Printf.sprintf "alias %s = %s" sym.name
                   (Types.type_to_string target))
                "1"
          | Env.OpaqueAliasSymbol { target; _ } ->
              add sym.name kind_class
                (Printf.sprintf "opaque type %s = %s" sym.name
                   (Types.type_to_string target))
                "1"
          | Env.VarSymbol _ | Env.FuncSymbol _ | Env.ConstructorSymbol _ -> ())
        (Env.scope_symbols scope))
    env.scopes;
  List.iter
    (fun trait ->
      add trait.Env.td_name kind_interface (env_trait_detail trait) "1")
    env.traits;
  List.rev !items

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
              | Env.OpaqueAliasSymbol { target; _ } ->
                  Some
                    (completion_item ~label:sym.name ~kind:kind_class
                       ~detail:
                         (Printf.sprintf "opaque type %s = %s" sym.name
                            (Types.type_to_string target))
                       ~sort_text:("2_" ^ sym.name))
            in
            match item with Some i -> items := i :: !items | None -> ()
          end)
        (Env.scope_symbols scope))
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

let add_typed_function_completion add (func : Typed_ast.func_decl) =
  match (Typed_ast.func_ast func).func_name with
  | Some name ->
      add name kind_function (typed_func_completion_detail func name) "0"
  | None -> ()

let add_typed_var_completion add (var : Typed_ast.var_decl) =
  let ast = Typed_ast.var_ast var in
  match ast.var_name with
  | Some name ->
      let info = Typed_ast.var_info var in
      let display_ty =
        Option.value info.source_binding_ty ~default:info.binding_ty
      in
      add name kind_variable (Types.type_to_string display_ty) "0"
  | None -> ()

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
        | DeclFunction func -> add_typed_function_completion add func
        | DeclVar var -> add_typed_var_completion add var
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
            | DeclFunction func -> add_typed_function_completion add func
            | DeclVar var -> add_typed_var_completion add var
            | _ -> ())
        | DeclCompileTimeBlock bindings ->
            List.iter
              (fun binding ->
                add_typed_var_completion add
                  (Typed_ast.compile_time_binding_var binding))
              bindings
        | DeclImpl _ | DeclOther -> ());
  (List.rev !items, names)

let loc_starts_before_cursor loc ~line ~character =
  let loc_line = loc.line - 1 in
  let loc_col = loc.column - 1 in
  loc_line < line || (loc_line = line && loc_col <= character)

let loc_end_line loc = max loc.line loc.end_line - 1

let rec expr_end_line expr =
  expr |> expr_children
  |> List.fold_left
       (fun max_line child -> max max_line (expr_end_line child))
       (loc_end_line expr.expr_loc)

let func_body_end_line fd =
  fd.func_body |> func_body_expr_opt |> Option.map expr_end_line

let function_body_reaches_cursor_line fd ~line =
  match func_body_end_line fd with
  | Some body_end_line -> line <= body_end_line
  | None -> false

let type_detail_opt = function
  | Some ty -> Types.type_to_string ty
  | None -> "local"

let expr_source_type_opt expr =
  match expr.expr_type_info with
  | Some { source_ty = Some ty; _ } -> Some ty
  | Some { semantic_ty; _ } -> Some semantic_ty
  | None -> None

let find_enclosing_function (program : program) ~(line : int) ~(character : int)
    =
  let selected_func = ref None in
  let consider_func decl_loc fd =
    if
      loc_starts_before_cursor decl_loc ~line ~character
      && function_body_reaches_cursor_line fd ~line
    then
      match !selected_func with
      | Some (best_loc, _) when best_loc.line > decl_loc.line -> ()
      | Some (best_loc, _)
        when best_loc.line = decl_loc.line && best_loc.column >= decl_loc.column
        ->
          ()
      | _ -> selected_func := Some (decl_loc, fd)
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
  Option.map snd !selected_func

let completions_from_enclosing_type_params (program : program) ~(line : int)
    ~(character : int) (prefix : string) : json list * (string, unit) Hashtbl.t
    =
  let items = ref [] in
  let names = Hashtbl.create 8 in
  let add param =
    let label = Ast.type_param_name param in
    let detail =
      Printf.sprintf "type parameter %s" (Ast.type_param_to_parser_string param)
    in
    add_visible_completion names items prefix label kind_type_parameter detail
      "0"
  in
  (match find_enclosing_function program ~line ~character with
  | Some func -> List.iter add func.func_type_params
  | None -> ());
  (List.rev !items, names)

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
      | EQuestionBind (name, source_ty, init) ->
          add name (type_detail_opt source_ty);
          collect_expr init
      | EWith (binding, body) ->
          collect_expr binding.with_value;
          Option.iter
            (fun mapper ->
              add mapper.with_error_name "with error";
              collect_expr mapper.with_error_value)
            binding.with_error_map;
          add binding.with_name (type_detail_opt binding.with_type);
          collect_expr body
      | EConcurrentBind (name, source_ty, init) ->
          add name (type_detail_opt source_ty);
          collect_expr init
      | EConcurrentlyLoop (name, iter, body, timeout, _) ->
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
      | ESelect arms ->
          List.iter
            (fun arm ->
              match arm.select_arm_kind with
              | SelectRecv { select_bind; select_channel } ->
                  collect_expr select_channel;
                  if
                    loc_starts_before_cursor arm.select_arm_loc ~line ~character
                  then add select_bind "select binding";
                  collect_expr arm.select_arm_body
              | SelectAfter timeout ->
                  collect_expr timeout;
                  collect_expr arm.select_arm_body
              | SelectSealed channel ->
                  collect_expr channel;
                  collect_expr arm.select_arm_body)
            arms
      | ELambda _ | EFuncDecl _ -> ()
      | _ -> List.iter collect_expr (expr_children expr)
  in
  (match find_enclosing_function program ~line ~character with
  | Some fd ->
      List.iter add_param fd.func_params;
      fd.func_body |> func_body_expr_opt |> Option.iter collect_expr
  | None -> ());
  (List.rev !items, names)

let receiver_type_from_local_scope (program : program) ~(line : int)
    ~(character : int) (receiver_name : string) : type_expr option =
  let found = ref None in
  let loc_is_after a b =
    a.line > b.line || (a.line = b.line && a.column > b.column)
  in
  let record_type loc ty =
    if loc_starts_before_cursor loc ~line ~character then
      match !found with
      | Some (best_loc, _) when not (loc_is_after loc best_loc) -> ()
      | _ -> found := Some (loc, ty)
  in
  let type_of_binding source_ty init =
    match source_ty with
    | Some ty -> Some ty
    | None -> expr_source_type_opt init
  in
  let add_param (param : Ast.param) =
    match (param.param_name, param.param_type) with
    | Some name, Some ty when name = receiver_name ->
        record_type param.param_loc ty
    | _ -> ()
  in
  let rec collect_expr (expr : expr) =
    if loc_starts_before_cursor expr.expr_loc ~line ~character then
      match expr.expr_desc with
      | EVarDecl (name, source_ty, init, _) ->
          if name = receiver_name then
            type_of_binding source_ty init
            |> Option.iter (record_type expr.expr_loc);
          collect_expr init
      | EQuestionBind (name, source_ty, init) ->
          if name = receiver_name then
            Option.iter (record_type expr.expr_loc) source_ty;
          collect_expr init
      | EConcurrentBind (name, source_ty, init) ->
          if name = receiver_name then
            Option.iter (record_type expr.expr_loc) source_ty;
          collect_expr init
      | EWith (binding, body) ->
          collect_expr binding.with_value;
          Option.iter
            (fun mapper -> collect_expr mapper.with_error_value)
            binding.with_error_map;
          if binding.with_name = receiver_name then
            Option.iter (record_type expr.expr_loc) binding.with_type;
          collect_expr body
      | EMatch (scrutinee, cases) ->
          collect_expr scrutinee;
          List.iter
            (fun case ->
              if loc_starts_before_cursor case.case_loc ~line ~character then
                collect_expr case.case_body)
            cases
      | ESelect arms ->
          List.iter
            (fun arm ->
              match arm.select_arm_kind with
              | SelectRecv { select_channel; _ } ->
                  collect_expr select_channel;
                  collect_expr arm.select_arm_body
              | SelectAfter timeout ->
                  collect_expr timeout;
                  collect_expr arm.select_arm_body
              | SelectSealed channel ->
                  collect_expr channel;
                  collect_expr arm.select_arm_body)
            arms
      | ELambda _ | EFuncDecl _ -> ()
      | _ -> List.iter collect_expr (expr_children expr)
  in
  (match find_enclosing_function program ~line ~character with
  | Some fd ->
      List.iter add_param fd.func_params;
      fd.func_body |> func_body_expr_opt |> Option.iter collect_expr
  | None -> ());
  Option.map snd !found

type record_field_completion_context = {
  record_ty : type_expr;
  assigned_fields : (string, unit) Hashtbl.t;
}

let substring_trim text start stop =
  if stop <= start then ""
  else String.sub text start (stop - start) |> String.trim

let nearest_open_record_brace text ident_start =
  match last_char_before text '{' ident_start with
  | Some open_index
    when not (char_between text '}' (open_index + 1) ident_start) ->
      Some open_index
  | _ -> None

let current_record_field_segment_start text content_start ident_start =
  match last_char_between text ',' content_start ident_start with
  | Some comma_index -> comma_index + 1
  | None -> content_start

let collect_assigned_field_names text start stop =
  let fields = Hashtbl.create 8 in
  let add_segment segment_start segment_stop =
    let segment = substring_trim text segment_start segment_stop in
    match String.index_opt segment '=' with
    | None -> ()
    | Some equals_index ->
        let field_name = String.sub segment 0 equals_index |> String.trim in
        if is_identifier_text field_name then
          Hashtbl.replace fields field_name ()
  in
  let rec loop segment_start i =
    if i >= stop then add_segment segment_start stop
    else if text.[i] = ',' then begin
      add_segment segment_start i;
      loop (i + 1) (i + 1)
    end
    else loop segment_start (i + 1)
  in
  loop start start;
  fields

let record_literal_type_before_open_brace text open_index =
  match last_char_before text '=' open_index with
  | None -> None
  | Some equals_index -> (
      match last_char_before text ':' equals_index with
      | None -> None
      | Some colon_index ->
          substring_trim text (colon_index + 1) equals_index
          |> parse_simple_type_expr)

let record_update_base_type program text ~line ~character open_index pipe_index
    =
  let base_text = substring_trim text (open_index + 1) pipe_index in
  if is_identifier_text base_text then
    receiver_type_from_local_scope program ~line ~character base_text
  else None

let record_field_completion_context program text ~line ~character =
  let ident_start, _ = identifier_at_cursor text ~col:character in
  match nearest_open_record_brace text ident_start with
  | None -> None
  | Some open_index ->
      let pipe_index =
        last_char_between text '|' (open_index + 1) ident_start
      in
      let content_start =
        match pipe_index with
        | Some pipe_index -> pipe_index + 1
        | None -> open_index + 1
      in
      let segment_start =
        current_record_field_segment_start text content_start ident_start
      in
      if char_between text '=' segment_start ident_start then None
      else
        let record_ty =
          match pipe_index with
          | Some pipe_index ->
              record_update_base_type program text ~line ~character open_index
                pipe_index
          | None -> record_literal_type_before_open_brace text open_index
        in
        record_ty
        |> Option.map (fun record_ty ->
            {
              record_ty;
              assigned_fields =
                collect_assigned_field_names text content_start segment_start;
            })

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
          | DCompileTimeBlock _ | DImport _ | DPrivate _ ->
              item name kind_variable name)
        m.exports

let completions_from_module_types (module_path : string) (prefix : string) :
    json list =
  match find_cached_module module_path with
  | None -> []
  | Some m ->
      let items = ref [] in
      let seen = Hashtbl.create 32 in
      let add label kind detail sort_group =
        add_visible_completion seen items prefix label kind detail sort_group
      in
      List.iter
        (fun (name, decl) -> add_source_type_decl_completion add name decl)
        m.exports;
      List.rev !items

let method_completion_detail name (entry : Env.overload_entry) =
  let pure_str =
    match entry.ol_purity with Env.Pure -> "pure " | Env.Impure -> ""
  in
  match entry.ol_func_type with
  | TyFunc { params; return; _ } ->
      let params =
        params
        |> List.mapi (fun index ty ->
            let param_name =
              match List.nth_opt entry.ol_param_names index with
              | Some (Some name) -> name
              | _ -> Printf.sprintf "arg%d" index
            in
            Printf.sprintf "%s: %s" param_name (Types.type_to_string ty))
        |> String.concat ", "
      in
      Printf.sprintf "%smethod %s(%s) -> %s" pure_str name params
        (Types.type_to_string return)
  | ty ->
      Printf.sprintf "%smethod %s: %s" pure_str name (Types.type_to_string ty)

let instantiate_type_params type_params args ty =
  if List.length type_params <> List.length args then ty
  else
    let subst = List.combine type_params args in
    Types.map_type_expr
      (function
        | TyVar name | TyNamed (name, []) -> List.assoc_opt name subst
        | TyBoundVar param -> List.assoc_opt param.param_name subst
        | _ -> None)
      ty

let completions_from_receiver_fields ?(module_aliases = [])
    ?(skip = fun _ -> false) (env : Env.env) (receiver_ty : type_expr)
    (prefix : string) : json list * (string, unit) Hashtbl.t =
  let seen = Hashtbl.create 8 in
  let add_field type_params type_args field =
    if starts_with_ci prefix field.field_name && not (skip field.field_name)
    then begin
      Hashtbl.replace seen field.field_name ();
      let field_ty =
        instantiate_type_params type_params type_args field.field_type
      in
      Some
        (completion_item ~label:field.field_name ~kind:kind_field
           ~detail:(Types.type_to_string field_ty)
           ~sort_text:("0_" ^ field.field_name))
    end
    else None
  in
  let resolution_ctx = Type_resolution.make_context ~env ~module_aliases () in
  let items =
    match Type_resolution.annotation_canonical resolution_ctx receiver_ty with
    | TyNamed (record_name, type_args) -> (
        match Env.get_record env record_name with
        | Some (type_params, fields) ->
            List.filter_map (add_field type_params type_args) fields
        | None -> [])
    | _ -> []
  in
  (items, seen)

let completions_from_receiver_methods ?(skip = fun _ -> false) (env : Env.env)
    (receiver_ty : type_expr) (prefix : string) : json list =
  let names =
    Hashtbl.fold
      (fun name _ acc ->
        if starts_with_ci prefix name && not (skip name) then name :: acc
        else acc)
      env.ufcs_methods []
    |> List.sort_uniq String.compare
  in
  List.filter_map
    (fun name ->
      match Env.lookup_ufcs_methods env name receiver_ty with
      | [] -> None
      | entry :: _ ->
          Some
            (completion_item ~label:name ~kind:kind_method
               ~detail:(method_completion_detail name entry)
               ~sort_text:("0_" ^ name)))
    names

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
          Lsp_state.with_document_session doc (fun () ->
              (* Get the current line text *)
              let lines = String.split_on_char '\n' doc.text in
              let line_text =
                if pos.line < List.length lines then List.nth lines pos.line
                else ""
              in
              let prefix, qualifier =
                get_completion_context line_text pos.character
              in
              let type_context =
                is_type_completion_context line_text pos.character
              in
              let record_field_context =
                match (qualifier, doc.program) with
                | None, Some program ->
                    record_field_completion_context program line_text
                      ~line:pos.line ~character:pos.character
                | _ -> None
              in
              let items =
                match qualifier with
                | Some alias -> (
                    (* Module-qualified completion first; otherwise treat the
                   qualifier as a simple receiver expression for UFCS methods. *)
                    match List.assoc_opt alias doc.module_aliases with
                    | Some path ->
                        if type_context then
                          completions_from_module_types path prefix
                        else completions_from_module path prefix
                    | None when type_context -> []
                    | None -> (
                        match (doc.program, doc.env) with
                        | Some program, Some env -> (
                            match
                              receiver_type_from_local_scope program
                                ~line:pos.line ~character:pos.character alias
                            with
                            | Some receiver_ty ->
                                let field_items, field_names =
                                  completions_from_receiver_fields env
                                    receiver_ty prefix
                                    ~module_aliases:doc.module_aliases
                                in
                                let method_items =
                                  completions_from_receiver_methods env
                                    receiver_ty prefix ~skip:(fun name ->
                                      Hashtbl.mem field_names name)
                                in
                                field_items @ method_items
                            | None -> [])
                        | _ -> []))
                | None -> (
                    (* General completion: record fields in field-name slots,
                   type-only in annotation contexts, otherwise identifiers +
                   keywords. *)
                    let file = Lsp_protocol.uri_to_path uri in
                    match (record_field_context, doc.env) with
                    | Some context, Some env ->
                        let field_items, _ =
                          completions_from_receiver_fields env context.record_ty
                            prefix ~module_aliases:doc.module_aliases
                            ~skip:(fun name ->
                              Hashtbl.mem context.assigned_fields name)
                        in
                        field_items
                    | Some _, None -> []
                    | None, _ ->
                        if type_context then (
                          let type_param_items, type_param_names =
                            match doc.source_program with
                            | Some program ->
                                completions_from_enclosing_type_params program
                                  ~line:pos.line ~character:pos.character prefix
                            | None -> ([], Hashtbl.create 0)
                          in
                          let source_items, source_names =
                            match doc.source_program with
                            | Some program ->
                                completions_from_source_types program ~file
                                  prefix ~skip:(fun name ->
                                    Hashtbl.mem type_param_names name)
                            | None -> ([], Hashtbl.create 0)
                          in
                          Hashtbl.iter
                            (fun name () ->
                              Hashtbl.replace type_param_names name ())
                            source_names;
                          let env_items =
                            match doc.env with
                            | Some env ->
                                completions_from_env_types
                                  ~skip:(fun name ->
                                    Hashtbl.mem type_param_names name)
                                  env prefix
                            | None -> []
                          in
                          type_param_items @ source_items @ env_items)
                        else
                          let typed_items, typed_names =
                            match doc.typed_program with
                            | Some typed_program ->
                                completions_from_typed_program typed_program
                                  ~file prefix
                            | None -> ([], Hashtbl.create 0)
                          in
                          let local_items, local_names =
                            match doc.program with
                            | Some program ->
                                completions_from_local_scope program
                                  ~line:pos.line ~character:pos.character prefix
                                  ~skip:(fun name ->
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
                                  ~skip:(fun name ->
                                    Hashtbl.mem typed_names name)
                                  env prefix
                            | None -> []
                          in
                          let kw_items = completions_from_keywords prefix in
                          typed_items @ local_items @ env_items @ kw_items)
              in
              Object [ ("isIncomplete", Bool false); ("items", Array items) ])
      | _ -> Object [ ("isIncomplete", Bool false); ("items", Array []) ])
  | _ -> Object [ ("isIncomplete", Bool false); ("items", Array []) ]
