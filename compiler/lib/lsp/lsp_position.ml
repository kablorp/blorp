(** LSP position lookup — cursor-to-AST mapping.

    Finds expressions and declarations at a given cursor position,
    and locates definitions of identifiers. Used by hover and
    go-to-definition. *)

open Ast

(* ============================================================================
   Word lookup — extract the identifier spanning a cursor position
   ============================================================================ *)

let is_ident_char c =
  (c >= 'a' && c <= 'z')
  || (c >= 'A' && c <= 'Z')
  || (c >= '0' && c <= '9')
  || c = '_'

let line_at (text : string) ~(line : int) : string option =
  if line < 0 then None
  else String.split_on_char '\n' text |> fun lines -> List.nth_opt lines line

let scan_ident_start (line_text : string) (col : int) : int =
  let rec scan i =
    if i <= 0 || not (is_ident_char line_text.[i - 1]) then i else scan (i - 1)
  in
  scan col

let scan_ident_end (line_text : string) (col : int) : int =
  let len = String.length line_text in
  let rec scan i =
    if i >= len || not (is_ident_char line_text.[i]) then i else scan (i + 1)
  in
  scan col

let ident_span_at (line_text : string) ~(col : int) : (int * int) option =
  let len = String.length line_text in
  if col < 0 || col > len then None
  else
    let cursor = min col len in
    let start_col = scan_ident_start line_text cursor in
    let end_col = scan_ident_end line_text cursor in
    if start_col = end_col then None else Some (start_col, end_col)

(** Return the identifier adjacent to [col] on [line] (0-based), or [None] if
    the cursor position is not next to an identifier. Works on the raw document
    text so it covers positions the AST walk misses: type annotations, pattern
    constructors, method names after `.`, etc. *)
let word_at (text : string) ~(line : int) ~(col : int) : string option =
  match line_at text ~line with
  | None -> None
  | Some line_text ->
      ident_span_at line_text ~col
      |> Option.map (fun (start_col, end_col) ->
          String.sub line_text start_col (end_col - start_col))

(* ============================================================================
   Expression lookup — find the deepest expression at a cursor position
   ============================================================================ *)

(** Find the expression at a given position (0-based line and column).
    Uses closest-start-position heuristic: walk AST depth-first,
    find the expr with matching line and largest column <= target. *)
let find_expr_at (program : program) ~(line : int) ~(col : int) : expr option =
  let target_line = line + 1 in
  let target_col = col + 1 in
  let best = ref None in
  let best_col = ref (-1) in

  let check_expr (e : expr) =
    if
      e.expr_loc.line = target_line
      && e.expr_loc.column <= target_col
      && e.expr_loc.column >= !best_col
    then begin
      best := Some e;
      best_col := e.expr_loc.column
    end
  in

  let rec walk_expr (e : expr) =
    check_expr e;
    List.iter walk_expr (expr_children e)
  in

  let rec walk_decl (d : decl) =
    match d.decl_desc with
    | DFunc fd -> (
        match func_body_expr_opt fd.func_body with
        | Some b -> walk_expr b
        | None -> ())
    | DVar vd -> walk_expr vd.var_value
    | DImpl impl ->
        List.iter
          (fun fd ->
            match func_body_expr_opt fd.func_body with
            | Some b -> walk_expr b
            | None -> ())
          impl.impl_methods
    | DPrivate d2 -> walk_decl d2
    | DType _ | DRecord _ | DImport _ | DTrait _ | DTypeAlias _ -> ()
  in

  List.iter walk_decl program;
  !best

(** Find a declaration at a given line (0-based).

    When [file] is provided, declarations from injected or imported programs
    are intentionally ignored. LSP hover operates on a single open document;
    same-line declarations from prelude/module loading must not shadow source
    declarations in that document. *)
let loc_matches_file ?file (loc : loc) =
  match file with None -> true | Some expected -> loc.loc_file = Some expected

let func_header_line decl_loc (fd : func_decl) =
  match fd.func_params with
  | first_param :: _ -> first_param.param_loc.line
  | [] -> (
      match func_body_expr_opt fd.func_body with
      | Some body when body.expr_loc.line > decl_loc.line ->
          body.expr_loc.line - 1
      | _ -> decl_loc.line)

let rec decl_starts_on_line (decl : decl) ~target_line =
  decl.decl_loc.line = target_line
  ||
  match decl.decl_desc with
  | DFunc fd -> func_header_line decl.decl_loc fd = target_line
  | DPrivate inner -> decl_starts_on_line inner ~target_line
  | _ -> false

let find_decl_at ?file (program : program) ~(line : int) : decl option =
  let target_line = line + 1 in
  List.find_opt
    (fun (d : decl) ->
      decl_starts_on_line d ~target_line && loc_matches_file ?file d.decl_loc)
    program

(** Find a typed declaration at a given line (0-based). *)
let find_typed_decl_at ?file (program : Typed_ast.program) ~(line : int) :
    Typed_ast.decl option =
  let target_line = line + 1 in
  program |> Typed_ast.program_decls
  |> List.find_opt (fun decl ->
      let ast_decl = Typed_ast.decl_ast decl in
      decl_starts_on_line ast_decl ~target_line
      && loc_matches_file ?file ast_decl.decl_loc)

type typed_param_hit = {
  param_name : string;
  source_param_ty : type_expr;
  semantic_param_ty : type_expr;
  param_loc : loc;
}

let col_inside_name (loc : loc) name ~(line : int) ~(col : int) =
  let target_line = line + 1 in
  let target_col = col + 1 in
  loc.line = target_line && loc.column <= target_col
  && target_col < loc.column + String.length name

let find_typed_param_in_func ?file (func : Typed_ast.func_decl) ~(line : int)
    ~(col : int) : typed_param_hit option =
  let ast = Typed_ast.func_ast func in
  let rec loop (params : param list) (infos : Typed_ast.func_param_info list) =
    match (params, infos) with
    | param :: rest_params, info :: rest_infos -> (
        let source_name = (param : Ast.param).param_name in
        match source_name with
        | Some name
          when loc_matches_file ?file param.param_loc
               && col_inside_name param.param_loc name ~line ~col ->
            Some
              {
                param_name = name;
                source_param_ty = info.Typed_ast.source_param_ty;
                semantic_param_ty = info.semantic_param_ty;
                param_loc = param.param_loc;
              }
        | _ -> loop rest_params rest_infos)
    | _ -> None
  in
  loop ast.func_params (Typed_ast.func_param_infos func)

(** Find a typed function parameter declaration at a given position. *)
let find_typed_param_at ?file (program : Typed_ast.program) ~(line : int)
    ~(col : int) : typed_param_hit option =
  program |> Typed_ast.program_decls
  |> List.find_map (fun decl ->
      let ast_decl = Typed_ast.decl_ast decl in
      if not (loc_matches_file ?file ast_decl.decl_loc) then None
      else
        match Typed_ast.decl_view decl with
        | DeclFunction func -> find_typed_param_in_func ?file func ~line ~col
        | DeclImpl impl ->
            impl |> Typed_ast.impl_methods
            |> List.find_map (fun func ->
                find_typed_param_in_func ?file func ~line ~col)
        | DeclPrivate inner -> (
            match Typed_ast.decl_view inner with
            | DeclFunction func ->
                find_typed_param_in_func ?file func ~line ~col
            | _ -> None)
        | DeclVar _ | DeclRecord _ | DeclTypeAlias _ | DeclOther -> None)

(* ============================================================================
   Definition lookup — for go-to-definition
   ============================================================================ *)

let loc_end_line loc = max loc.line loc.end_line

let rec expr_end_line expr =
  expr |> expr_children
  |> List.fold_left
       (fun max_line child -> max max_line (expr_end_line child))
       (loc_end_line expr.expr_loc)

let func_body_end_line fd =
  fd.func_body |> func_body_expr_opt |> Option.map expr_end_line

let function_body_reaches_target_line fd ~target_line =
  match func_body_end_line fd with
  | Some body_end_line -> target_line <= body_end_line
  | None -> false

(** Find the definition location of a name in the program.
    Searches top-level declarations first, then local definitions
    within the enclosing function body at the given cursor position. *)
let find_definition (program : program) ~(name : string) ~(line : int)
    ~(col : int) : loc option =
  let target_line = line + 1 in
  let target_col = col + 1 in

  let loc_starts_before_cursor loc =
    loc.line < target_line
    || (loc.line = target_line && loc.column <= target_col)
  in

  (* Search top-level declarations *)
  let rec find_in_decls decls =
    match decls with
    | [] -> None
    | d :: rest -> (
        let found =
          match d.decl_desc with
          | DFunc fd when fd.func_name = Some name -> Some d.decl_loc
          | DVar vd when vd.var_name = Some name -> Some d.decl_loc
          | DType td when td.type_name = name -> Some d.decl_loc
          | DType td -> (
              match
                List.find_opt
                  (fun (v : variant) -> v.variant_name = name)
                  td.type_variants
              with
              | Some _ -> Some d.decl_loc
              | None -> None)
          | DRecord rd when rd.record_name = name -> Some d.decl_loc
          | DTrait td when td.trait_name = name -> Some d.decl_loc
          | DTypeAlias ad when ad.alias_name = name -> Some d.decl_loc
          | DPrivate inner -> find_in_decls [ inner ]
          | _ -> None
        in
        match found with Some _ -> found | None -> find_in_decls rest)
  in

  (* Search for local definitions inside expressions *)
  let rec find_local_in_expr (e : expr) : loc option =
    match e.expr_desc with
    | EVarDecl (n, _, _, _) when n = name && loc_starts_before_cursor e.expr_loc
      ->
        Some e.expr_loc
    | ETupleDestruct (names, _) ->
        if List.mem name names && loc_starts_before_cursor e.expr_loc then
          Some e.expr_loc
        else None
    | EFor (n, _, body) ->
        if n = name && loc_starts_before_cursor e.expr_loc then Some e.expr_loc
        else find_local_in_expr body
    | EForTuple (names, _, body) ->
        if List.mem name names && loc_starts_before_cursor e.expr_loc then
          Some e.expr_loc
        else find_local_in_expr body
    | EBlock exprs -> find_local_in_exprs exprs
    | EIf (_, t, e_opt) -> (
        match find_local_in_expr t with
        | Some _ as r -> r
        | None -> (
            match e_opt with Some e -> find_local_in_expr e | None -> None))
    | EMatch (_, cases) ->
        List.fold_left
          (fun acc c ->
            match acc with
            | Some _ -> acc
            | None -> find_local_in_expr c.case_body)
          None cases
    | ESelect arms ->
        List.fold_left
          (fun acc arm ->
            match acc with
            | Some _ -> acc
            | None -> (
                match arm.select_arm_kind with
                | SelectRecv { select_bind; _ }
                  when select_bind = name
                       && loc_starts_before_cursor arm.select_arm_loc ->
                    Some arm.select_arm_loc
                | _ -> find_local_in_expr arm.select_arm_body))
          None arms
    | EWhile (_, body) -> find_local_in_expr body
    | EDebugBlock stmts -> find_local_in_exprs stmts
    | EQuestionBind (n, _, _)
      when n = name && loc_starts_before_cursor e.expr_loc ->
        Some e.expr_loc
    | EWith (binding, body) ->
        if binding.with_name = name && loc_starts_before_cursor e.expr_loc then
          Some e.expr_loc
        else find_local_in_expr body
    | EConcurrent (bindings, _, _) -> find_local_in_exprs bindings
    | EConcurrentBind (n, _, _)
      when n = name && loc_starts_before_cursor e.expr_loc ->
        Some e.expr_loc
    | EConcurrentFor (n, _, body, _, _) ->
        if n = name && loc_starts_before_cursor e.expr_loc then Some e.expr_loc
        else find_local_in_expr body
    | EDetach body -> find_local_in_expr body
    | _ -> None
  and find_local_in_exprs exprs =
    List.fold_left
      (fun acc e ->
        match acc with Some _ -> acc | None -> find_local_in_expr e)
      None exprs
  in

  (* Find the enclosing function at the cursor line and search its params + body *)
  let find_in_enclosing_func () =
    let check_func_decl (fd : func_decl) (decl_loc : loc) =
      if
        decl_loc.line <= target_line
        && function_body_reaches_target_line fd ~target_line
      then
        let in_params =
          List.find_opt
            (fun (p : Ast.param) -> p.param_name = Some name)
            fd.func_params
        in
        match in_params with
        | Some param -> Some param.param_loc
        | None -> (
            match func_body_expr_opt fd.func_body with
            | Some body -> find_local_in_expr body
            | None -> None)
      else None
    in
    let result = ref None in
    List.iter
      (fun (d : decl) ->
        if !result = None then
          match d.decl_desc with
          | DFunc fd -> (
              match check_func_decl fd d.decl_loc with
              | Some _ as r -> result := r
              | None -> ())
          | DImpl impl ->
              List.iter
                (fun fd ->
                  if !result = None then
                    match check_func_decl fd d.decl_loc with
                    | Some _ as r -> result := r
                    | None -> ())
                impl.impl_methods
          | DPrivate { decl_desc = DFunc fd; decl_loc; _ } -> (
              match check_func_decl fd decl_loc with
              | Some _ as r -> result := r
              | None -> ())
          | _ -> ())
      program;
    !result
  in

  match find_in_enclosing_func () with
  | Some _ as r -> r
  | None -> find_in_decls program

(* ============================================================================
   Cross-module definition lookup — resolve imported / prelude-UFCS symbols
   ============================================================================ *)

(** Modules whose exports are available as UFCS methods on prelude types
    without an explicit import. Kept in sync with
    typecheck.ml:load_prelude_ref and Modules.prelude_module_names. *)
let prelude_ufcs_modules =
  [ "option"; "result"; "string"; "list"; "dict"; "set"; "bool" ]

(** Map an embedded module path like [<embedded:std/option>] to the configured
    filesystem std path. Non-embedded paths and sessions without an explicit
    filesystem std override are returned unchanged. *)
let resolve_module_source_path ~(base_dir : string) (path : string) : string =
  let _ = base_dir in
  let prefix = "<embedded:" in
  let prefix_len = String.length prefix in
  let path_len = String.length path in
  if
    path_len > prefix_len
    && String.sub path 0 prefix_len = prefix
    && path.[path_len - 1] = '>'
  then
    let module_name = String.sub path prefix_len (path_len - prefix_len - 1) in
    match Modules.std_source_dir () with
    | None -> path
    | Some std_dir ->
        let std_prefix = "std/" in
        let relative =
          if
            String.length module_name > String.length std_prefix
            && String.sub module_name 0 (String.length std_prefix) = std_prefix
          then
            String.sub module_name (String.length std_prefix)
              (String.length module_name - String.length std_prefix)
          else module_name
        in
        let candidate = Filename.concat std_dir (relative ^ ".brp") in
        if Sys.file_exists candidate then candidate else path
  else path

let import_symbol_local_name (s : Ast.import_symbol) : string =
  Option.value s.sym_alias ~default:s.sym_name

let import_symbol_imports_ctor (local_name : string) (s : Ast.import_symbol) :
    bool =
  match s.sym_ctors with
  | CtorSome ctors -> List.mem local_name ctors
  | CtorNone -> false

(** Resolve [local_name] against a single import declaration.
    Returns the exported name to look up in the source module, or [None]
    if the import doesn't bring [local_name] into scope.

    Handles three selective forms:
      - `{ foo }` and `{ foo as bar }` — direct symbol imports
      - `{ Type(CtorA, CtorB) }` — constructor imports; a click on
        `CtorA` in the import block resolves to `CtorA` in the module *)
let resolve_imported_name (imp : Ast.import_decl) (local_name : string) :
    string option =
  match imp.import_symbols with
  | Some syms -> (
      match
        List.find_opt (fun s -> import_symbol_local_name s = local_name) syms
      with
      | Some s -> Some s.sym_name
      | None ->
          if List.exists (import_symbol_imports_ctor local_name) syms then
            Some local_name
          else None)
  | None ->
      (* Qualified or bare: the name itself doesn't enter scope as a bare
         identifier (only the module alias does). Cmd+Click on a name after
         `alias.` still reads the bare word from text — so speculate that
         [local_name] might exist in this module and let the cross-module
         search confirm. *)
      Some local_name

(** Search a loaded module's AST for [name]; returns its location if found. *)
let find_in_module (m : Modules.loaded_module) ~(name : string) : Ast.loc option
    =
  find_definition m.decls ~name ~line:0 ~col:0

(** Top-of-file location used when navigating to a whole module. *)
let module_top_loc : Ast.loc =
  { line = 1; column = 1; end_line = 1; end_column = 1; loc_file = None }

(** Does [name] refer to the module imported by [imp]? Matches either the
    explicit `as` alias or the last segment of the module path. *)
let import_names_module (imp : Ast.import_decl) (name : string) : bool =
  match imp.import_alias with
  | Some a -> a = name
  | None -> Filename.basename imp.import_module = name

(** Find [name] across modules imported by [program] and across the prelude
    UFCS modules (list/option/string/...). Returns the module's file path and
    the definition's location in that file.

    Resolution order:
      1. Symbol exported by an explicit import ({name}, {name as alias}).
      2. Module itself — click on `option` or an alias `L` jumps to top-of-file.
      3. Symbol reachable through a prelude UFCS module. *)
let find_cross_module_definition (program : Ast.program) ~(name : string) :
    (string * Ast.loc) option =
  let try_module mod_name lookup_name =
    match Modules.find_cached mod_name with
    | Some m -> (
        match find_in_module m ~name:lookup_name with
        | Some loc -> Some (m.path, loc)
        | None -> None)
    | None -> None
  in
  let try_module_itself (imp : Ast.import_decl) : (string * Ast.loc) option =
    match Modules.find_cached imp.import_module with
    | Some m -> Some (m.path, module_top_loc)
    | None -> None
  in
  let rec collect_imports acc = function
    | [] -> List.rev acc
    | (d : Ast.decl) :: rest -> (
        match d.decl_desc with
        | DImport imp -> collect_imports (imp :: acc) rest
        | DPrivate inner -> collect_imports acc (inner :: rest)
        | _ -> collect_imports acc rest)
  in
  let imports = collect_imports [] program in
  (* 1. Exported symbol via a selective import. *)
  let symbol_match =
    List.find_map
      (fun imp ->
        match resolve_imported_name imp name with
        | Some original -> try_module imp.import_module original
        | None -> None)
      imports
  in
  match symbol_match with
  | Some _ as r -> r
  | None -> (
      (* 2. The module itself (path segment or `as` alias). *)
      let module_match =
        List.find_map
          (fun imp ->
            if import_names_module imp name then try_module_itself imp else None)
          imports
      in
      match module_match with
      | Some _ as r -> r
      | None ->
          (* 3. Fall back to prelude UFCS modules — no import required. *)
          List.find_map
            (fun mod_name -> try_module mod_name name)
            prelude_ufcs_modules)
