(** LSP signature help handler.

    Provides function signature information when the user types '(' or ','.
    Parsed documents use AST call spans first. Incomplete documents fall back
    to a best-effort text scan. *)

open Lsp_json

(* ============================================================================
   Call site detection
   ============================================================================ *)

(** Text fallback for incomplete documents.

    Finds the enclosing function call at the cursor position.
    Returns (func_name, active_param_index) or None.
    Walks backwards tracking paren nesting to find unmatched '('.
    Skips string literal content. Scans up to 5 previous lines if needed. *)
let find_enclosing_call_text_fallback (lines : string list) (line : int)
    (col : int) : (string * int) option =
  (* Collect text from current and up to 5 previous lines *)
  let combined = Buffer.create 256 in
  let start_line = max 0 (line - 5) in
  for i = start_line to line do
    let l = if i < List.length lines then List.nth lines i else "" in
    let text =
      if i = line then
        (* Only up to cursor *)
        let len = min col (String.length l) in
        String.sub l 0 len
      else l
    in
    Buffer.add_string combined text;
    if i < line then Buffer.add_char combined '\n'
  done;
  let text = Buffer.contents combined in
  let len = String.length text in
  (* Walk backwards, tracking paren depth and comma count *)
  let depth = ref 0 in
  let commas = ref 0 in
  let in_string = ref false in
  let found_paren = ref (-1) in
  let i = ref (len - 1) in
  while !i >= 0 && !found_paren = -1 do
    let c = text.[!i] in
    if !in_string then
      (* Walk backwards through string — look for unescaped quote *)
      begin if c = '"' && (!i = 0 || text.[!i - 1] <> '\\') then
        in_string := false
      end
    else
      begin match c with
      | '"' -> in_string := true
      | ')' | ']' | '}' -> incr depth
      | '(' -> if !depth > 0 then decr depth else found_paren := !i
      | '[' | '{' -> if !depth > 0 then decr depth
      | ',' -> if !depth = 0 then incr commas
      | _ -> ()
      end;
    decr i
  done;
  if !found_paren < 0 then None
  else begin
    (* Extract the function name before the '(' *)
    let paren_pos = !found_paren in
    let rec find_name_end i =
      if i < 0 then -1
      else if text.[i] = ' ' || text.[i] = '\t' || text.[i] = '\n' then
        find_name_end (i - 1)
      else i
    in
    let name_end = find_name_end (paren_pos - 1) in
    if name_end < 0 then None
    else begin
      let rec find_name_start i =
        if i < 0 then 0
        else
          let c = text.[i] in
          if
            (c >= 'a' && c <= 'z')
            || (c >= 'A' && c <= 'Z')
            || (c >= '0' && c <= '9')
            || c = '_' || c = '.'
          then find_name_start (i - 1)
          else i + 1
      in
      let name_start = find_name_start name_end in
      let name = String.sub text name_start (name_end - name_start + 1) in
      if name = "" then None else Some (name, !commas)
    end
  end

let position_compare (line_a, col_a) (line_b, col_b) =
  match compare line_a line_b with 0 -> compare col_a col_b | c -> c

let loc_start loc = (loc.Ast.line, loc.column)
let loc_end loc = (loc.Ast.end_line, loc.end_column)

let loc_contains_position loc ~line ~col =
  position_compare (loc_start loc) (line, col) <= 0
  && position_compare (line, col) (loc_end loc) <= 0

let position_before_loc ~line ~col loc =
  position_compare (line, col) (loc_start loc) < 0

let position_after_loc ~line ~col loc =
  position_compare (loc_end loc) (line, col) < 0

let active_param_from_arg_spans args ~line ~col ~implicit_receiver =
  let rec loop index = function
    | [] -> max 0 (index - 1 + implicit_receiver)
    | arg :: rest ->
        if position_before_loc ~line ~col arg.Ast.expr_loc then
          index + implicit_receiver
        else if
          loc_contains_position arg.expr_loc ~line ~col
          || not (position_after_loc ~line ~col arg.expr_loc)
        then index + implicit_receiver
        else loop (index + 1) rest
  in
  loop 0 args

let module_qualified_name module_aliases qualifier member =
  match List.assoc_opt qualifier module_aliases with
  | Some _ -> Some (qualifier ^ "." ^ member, 0)
  | None -> None

let std_prefixed_path path =
  if
    String.starts_with ~prefix:"std/" path
    || String.starts_with ~prefix:"pkg/" path
    || String.starts_with ~prefix:"./" path
    || String.starts_with ~prefix:"../" path
  then path
  else "std/" ^ path

let module_paths_match left right =
  left = right
  || std_prefixed_path left = right
  || left = std_prefixed_path right

let module_alias_for_path module_aliases module_path =
  List.find_map
    (fun (alias, path) ->
      if module_paths_match path module_path then Some alias else None)
    module_aliases

let resolved_call_signature_name module_aliases callee
    (call : Ast.resolved_call) =
  let implicit_receiver =
    match (call.call_syntax, callee.Ast.expr_desc) with
    | (CallMethod | CallMethodOnlyUfcs), EFieldAccess _ -> 1
    | (CallMethod | CallMethodOnlyUfcs), _ -> 0
    | (CallBare | CallQualified _ | CallClosureSyntax | CallTraitDispatch), _ ->
        0
  in
  match (call.call_syntax, callee.Ast.expr_desc, call.call_target) with
  | ( CallQualified _,
      EFieldAccess ({ expr_desc = EIdent qualifier; _ }, member),
      CallDirect _ ) ->
      Some (qualifier ^ "." ^ member, 0)
  | CallQualified module_path, _, CallDirect { source_name; _ } -> (
      match module_alias_for_path module_aliases module_path with
      | Some qualifier -> Some (qualifier ^ "." ^ source_name, 0)
      | None -> Some (source_name, 0))
  | _, _, CallDirect { source_name; _ } -> Some (source_name, implicit_receiver)
  | _, _, CallTraitMethod { method_name; _ } ->
      Some (method_name, implicit_receiver)
  | _, _, CallClosure _ -> None

let callee_signature_name module_aliases callee =
  match callee.Ast.expr_desc with
  | EIdent name -> Some (name, 0)
  | EFieldAccess ({ expr_desc = EIdent qualifier; _ }, member) ->
      module_qualified_name module_aliases qualifier member
  | _ -> None

let call_signature_name module_aliases call_expr callee =
  match Ast.expr_resolved_call call_expr with
  | Some resolved -> resolved_call_signature_name module_aliases callee resolved
  | None -> callee_signature_name module_aliases callee

let rec find_enclosing_call_expr module_aliases (expr : Ast.expr) ~line ~col =
  match expr.Ast.expr_desc with
  | ECall (callee, args) when loc_contains_position expr.expr_loc ~line ~col
    -> (
      match find_enclosing_call_in_children module_aliases expr ~line ~col with
      | Some _ as found -> found
      | None -> (
          match call_signature_name module_aliases expr callee with
          | Some (name, implicit_receiver) ->
              Some
                ( name,
                  active_param_from_arg_spans args ~line ~col ~implicit_receiver
                )
          | None -> None))
  | _ -> find_enclosing_call_in_children module_aliases expr ~line ~col

and find_enclosing_call_in_children module_aliases expr ~line ~col =
  expr |> Ast.expr_children
  |> List.find_map (fun child ->
      find_enclosing_call_expr module_aliases child ~line ~col)

let find_enclosing_call_in_func module_aliases (func : Ast.func_decl) ~line ~col
    =
  match Ast.func_body_expr_opt func.Ast.func_body with
  | Some body -> find_enclosing_call_expr module_aliases body ~line ~col
  | None -> None

let rec find_enclosing_call_in_decl module_aliases (decl : Ast.decl) ~line ~col
    =
  match decl.decl_desc with
  | DFunc func -> find_enclosing_call_in_func module_aliases func ~line ~col
  | DVar var ->
      find_enclosing_call_expr module_aliases var.Ast.var_value ~line ~col
  | DPrivate inner ->
      find_enclosing_call_in_decl module_aliases inner ~line ~col
  | DImpl impl ->
      impl.Ast.impl_methods
      |> List.find_map (fun func ->
          find_enclosing_call_in_func module_aliases func ~line ~col)
  | _ -> None

let find_enclosing_call_parsed (program : Ast.program) module_aliases
    (position : Lsp_protocol.position) =
  let line = position.line + 1 in
  let col = position.character + 1 in
  program
  |> List.find_map (fun decl ->
      find_enclosing_call_in_decl module_aliases decl ~line ~col)

let find_enclosing_call doc position =
  match doc.Lsp_state.program with
  | Some program -> (
      match find_enclosing_call_parsed program doc.module_aliases position with
      | Some _ as found -> found
      | None ->
          let lines = String.split_on_char '\n' doc.text in
          find_enclosing_call_text_fallback lines position.line
            position.character)
  | None ->
      let lines = String.split_on_char '\n' doc.text in
      find_enclosing_call_text_fallback lines position.line position.character

(* ============================================================================
   Signature building
   ============================================================================ *)

(** Build a ParameterInformation JSON object *)
let param_info (label : string) : json = Object [ ("label", String label) ]

(** Build a signature response JSON from label + params *)
let make_sig_response (label : string) (params : string list)
    (active_param : int) : json =
  let param_infos = List.map param_info params in
  let sig_obj =
    Object [ ("label", String label); ("parameters", Array param_infos) ]
  in
  Object
    [
      ("signatures", Array [ sig_obj ]);
      ("activeSignature", Int 0);
      ("activeParameter", Int active_param);
    ]

let loc_matches_file ?file (loc : Ast.loc) =
  match file with None -> true | Some expected -> loc.loc_file = Some expected

let typed_func_name (func : Typed_ast.func_decl) =
  (Typed_ast.func_ast func).Ast.func_name

let typed_func_matches name func = typed_func_name func = Some name

let rec typed_func_from_decl_view name = function
  | Typed_ast.DeclFunction func when typed_func_matches name func -> Some func
  | Typed_ast.DeclPrivate inner ->
      typed_func_from_decl_view name (Typed_ast.decl_view inner)
  | _ -> None

let find_typed_func ?file (program : Typed_ast.program) name =
  program |> Typed_ast.program_decls
  |> List.find_map (fun decl ->
      let ast_decl = Typed_ast.decl_ast decl in
      if not (loc_matches_file ?file ast_decl.decl_loc) then None
      else typed_func_from_decl_view name (Typed_ast.decl_view decl))

let typed_func_param_label index (param : Typed_ast.func_param_info) =
  let pname =
    match param.Typed_ast.param_name with
    | Some name -> name
    | None -> Printf.sprintf "arg%d" index
  in
  Printf.sprintf "%s: %s" pname (Types.type_to_string param.source_param_ty)

let typed_func_param_labels (func : Typed_ast.func_decl) =
  Typed_ast.func_param_infos func |> List.mapi typed_func_param_label

let typed_func_return_type (func : Typed_ast.func_decl) =
  let info = Typed_ast.func_info func in
  match info.source_return_ty with
  | Some ty -> ty
  | None -> Typed_ast.func_semantic_return_type func

let typed_func_signature_label (func : Typed_ast.func_decl) name params =
  let ast = Typed_ast.func_ast func in
  let pure_str = if ast.func_is_pure then "pure " else "" in
  Printf.sprintf "%sfunc %s(%s) -> %s" pure_str name
    (String.concat ", " params)
    (Types.type_to_string (typed_func_return_type func))

let typed_func_signature (func : Typed_ast.func_decl) name active_param =
  let params = typed_func_param_labels func in
  let label = typed_func_signature_label func name params in
  make_sig_response label params active_param

(** Try to build signature from a module-qualified call like "L.map" *)
let try_qualified_signature (module_aliases : (string * string) list)
    (qualifier : string) (member : string) (active_param : int) : json option =
  match List.assoc_opt qualifier module_aliases with
  | None -> None
  | Some path -> (
      match
        match Modules.find_cached path with
        | Some _ as found -> found
        | None -> Modules.find_cached (std_prefixed_path path)
      with
      | None -> None
      | Some m -> (
          match List.assoc_opt member m.exports with
          | None -> None
          | Some d -> (
              match d.Ast.decl_desc with
              | Ast.DFunc fd ->
                  let label, params = Lsp_protocol.format_func_decl fd member in
                  Some (make_sig_response label params active_param)
              | _ -> None)))

let env_func_signature name active_param func_type param_names purity =
  let pure_str = match purity with Env.Pure -> "pure " | Env.Impure -> "" in
  let param_types, ret_type =
    match func_type with
    | Ast.TyFunc { params; return; _ } -> (params, Some return)
    | _ -> ([], None)
  in
  let params =
    List.mapi
      (fun i ty ->
        let pname =
          match List.nth_opt param_names i with
          | Some (Some n) -> n
          | _ -> Printf.sprintf "arg%d" i
        in
        Printf.sprintf "%s: %s" pname (Types.type_to_string ty))
      param_types
  in
  let ret =
    match ret_type with
    | Some ty -> " -> " ^ Types.type_to_string ty
    | None -> ""
  in
  let label =
    Printf.sprintf "%sfunc %s(%s)%s" pure_str name
      (String.concat ", " params)
      ret
  in
  make_sig_response label params active_param

(** Build signature from an env lookup *)
let build_signature ?typed_program ?file (env : Env.env) (name : string)
    (active_param : int) (module_aliases : (string * string) list) : json =
  (* Handle qualified calls like "L.map" *)
  match String.split_on_char '.' name with
  | [ qualifier; member ] -> (
      match
        try_qualified_signature module_aliases qualifier member active_param
      with
      | Some result -> result
      | None -> Null)
  | _ -> (
      match
        Option.bind typed_program (fun program ->
            find_typed_func ?file program name)
      with
      | Some func -> typed_func_signature func name active_param
      | None -> (
          (* Direct lookup in env *)
          match Env.lookup env name with
          | Some
              { kind = Env.FuncSymbol { func_type; param_names; purity; _ }; _ }
            ->
              env_func_signature name active_param func_type param_names purity
          | _ -> Null))

(* ============================================================================
   Main handler
   ============================================================================ *)

let handle_signature_help (state : Lsp_state.state) (params : json) : json =
  let td = get "textDocument" params in
  let pos = get "position" params in
  match (td, pos) with
  | Some td, Some pos_json -> (
      let uri = Lsp_protocol.get_uri td in
      let position = Lsp_protocol.position_of_json pos_json in
      match (Lsp_state.find_document state uri, position) with
      | Some doc, Some pos ->
          Lsp_state.with_document_session doc (fun () ->
              match doc.env with
              | Some env -> (
                  match find_enclosing_call doc pos with
                  | Some (name, active_param) ->
                      build_signature ?typed_program:doc.typed_program
                        ~file:(Lsp_protocol.uri_to_path uri)
                        env name active_param doc.module_aliases
                  | None -> Null)
              | None -> Null)
      | _ -> Null)
  | _ -> Null
