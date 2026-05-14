(** LSP signature help handler.

    Provides function signature information when the user types '(' or ','.
    Uses a text-level heuristic to find the enclosing function call and
    active parameter index. *)

open Lsp_json

(* ============================================================================
   Call site detection — text-level heuristic
   ============================================================================ *)

(** Find the enclosing function call at the cursor position.
    Returns (func_name, active_param_index) or None.
    Walks backwards tracking paren nesting to find unmatched '('.
    Skips string literal content. Scans up to 5 previous lines if needed. *)
let find_enclosing_call (lines : string list) (line : int) (col : int) :
    (string * int) option =
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

let find_typed_func ?file (program : Typed_ast.program) name =
  program |> Typed_ast.program_decls
  |> List.find_map (fun decl ->
      let ast_decl = Typed_ast.decl_ast decl in
      if not (loc_matches_file ?file ast_decl.decl_loc) then None
      else
        match Typed_ast.decl_view decl with
        | Typed_ast.DeclFunction func when typed_func_name func = Some name ->
            Some func
        | _ -> None)

let typed_func_signature (func : Typed_ast.func_decl) name active_param =
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
  let label =
    Printf.sprintf "%sfunc %s(%s) -> %s" pure_str name
      (String.concat ", " params)
      (Types.type_to_string ret_ty)
  in
  make_sig_response label params active_param

(** Try to build signature from a module-qualified call like "L.map" *)
let try_qualified_signature (module_aliases : (string * string) list)
    (qualifier : string) (member : string) (active_param : int) : json option =
  match List.assoc_opt qualifier module_aliases with
  | None -> None
  | Some path -> (
      match Modules.find_cached path with
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
              let pure_str =
                match purity with Env.Pure -> "pure " | Env.Impure -> ""
              in
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
      | Some doc, Some pos -> (
          match doc.env with
          | Some env -> (
              let lines = String.split_on_char '\n' doc.text in
              match find_enclosing_call lines pos.line pos.character with
              | Some (name, active_param) ->
                  build_signature ?typed_program:doc.typed_program
                    ~file:(Lsp_protocol.uri_to_path uri)
                    env name active_param doc.module_aliases
              | None -> Null)
          | None -> Null)
      | _ -> Null)
  | _ -> Null
