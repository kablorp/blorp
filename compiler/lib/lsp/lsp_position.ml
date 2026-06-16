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

let dim_span_starting_at (line_text : string) (start_col : int) :
    (int * int) option =
  let len = String.length line_text in
  if
    start_col >= 0
    && start_col + 1 < len
    && line_text.[start_col] = '#'
    && is_ident_char line_text.[start_col + 1]
  then Some (start_col, scan_ident_end line_text (start_col + 1))
  else None

let ident_span_at (line_text : string) ~(col : int) : (int * int) option =
  let len = String.length line_text in
  if col < 0 || col > len then None
  else
    let cursor = min col len in
    let direct_dim =
      if cursor < len then dim_span_starting_at line_text cursor else None
    in
    match direct_dim with
    | Some _ as span -> span
    | None ->
        let start_col = scan_ident_start line_text cursor in
        let end_col = scan_ident_end line_text cursor in
        if start_col = end_col then None
        else
          let ident_span = (start_col, end_col) in
          if start_col > 0 then
            match dim_span_starting_at line_text (start_col - 1) with
            | Some (dim_start, dim_end) when dim_end = end_col ->
                Some (dim_start, dim_end)
            | _ -> Some ident_span
          else Some ident_span

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
   Source context lookup — conservative line-local cursor classification
   ============================================================================ *)

let clamp_col text col =
  let len = String.length text in
  max 0 (min col len)

let identifier_start_at_cursor text col =
  scan_ident_start text (clamp_col text col)

let rec last_index_satisfying text start predicate =
  if start < 0 then None
  else if predicate start then Some start
  else last_index_satisfying text (start - 1) predicate

let last_char_before text ch before =
  let start = min (before - 1) (String.length text - 1) in
  last_index_satisfying text start (fun i -> text.[i] = ch)

let last_arrow_before text before =
  let start = min (before - 2) (String.length text - 2) in
  last_index_satisfying text start (fun i ->
      text.[i] = '-' && text.[i + 1] = '>')

let char_between text ch start stop =
  let rec loop i = if i >= stop then false else text.[i] = ch || loop (i + 1) in
  loop (max 0 start)

let split_words text =
  text |> String.trim |> String.split_on_char ' '
  |> List.filter (fun word -> word <> "")

let is_identifier_text text =
  let len = String.length text in
  len > 0
  && ((text.[0] >= 'a' && text.[0] <= 'z')
     || (text.[0] >= 'A' && text.[0] <= 'Z')
     || text.[0] = '_')
  &&
  let rec loop i =
    if i >= len then true else is_ident_char text.[i] && loop (i + 1)
  in
  loop 1

let binding_segment_before_colon text colon_index =
  let last_delim =
    List.filter_map
      (fun ch -> last_char_before text ch colon_index)
      [ '('; '['; '{'; ',' ]
    |> List.fold_left max (-1)
  in
  String.sub text (last_delim + 1) (colon_index - last_delim - 1)

let segment_can_introduce_type_annotation segment =
  match split_words segment with
  | [ name ] -> is_identifier_text name
  | [ "var"; name ] | [ "private"; name ] | [ "const"; name ] ->
      is_identifier_text name
  | [ "private"; "var"; name ] | [ "private"; "const"; name ] ->
      is_identifier_text name
  | _ -> false

(** Completion and hover often run while the source is temporarily incomplete,
    so the parser cannot provide a cursor context. Keep this line-local detector
    conservative: it recognizes return-type arrows and annotation colons whose
    left side looks like a binding/field/type parameter, and it rejects contexts
    already past an initializer or single-line function body. *)
let is_type_name_context (text : string) (col : int) =
  let ident_start = identifier_start_at_cursor text col in
  let has_invalidator_after start =
    char_between text '=' start ident_start
    || char_between text ':' start ident_start
  in
  match last_arrow_before text ident_start with
  | Some arrow_index when not (has_invalidator_after (arrow_index + 2)) -> true
  | _ -> (
      match last_char_before text ':' ident_start with
      | Some colon_index
        when (not (char_between text '=' (colon_index + 1) ident_start))
             && segment_can_introduce_type_annotation
                  (binding_segment_before_colon text colon_index) ->
          true
      | _ -> false)

let is_type_name_context_at (text : string) ~(line : int) ~(col : int) =
  match line_at text ~line with
  | None -> false
  | Some line_text -> is_type_name_context line_text col

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
    | DCompileTimeBlock bindings ->
        List.iter (fun binding -> walk_expr binding.ctb_var.var_value) bindings
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

let loc_same_position a b =
  a.line = b.line && a.column = b.column
  && Option.equal String.equal a.loc_file b.loc_file

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

let position_compare (line_a, col_a) (line_b, col_b) =
  match compare line_a line_b with 0 -> compare col_a col_b | c -> c

let loc_contains_position (loc : loc) ~(line : int) ~(col : int) =
  let target = (line + 1, col + 1) in
  position_compare (loc.line, loc.column) target <= 0
  && position_compare target (loc.end_line, loc.end_column) <= 0

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
        | DeclVar _ | DeclRecord _ | DeclTypeAlias _ | DeclCompileTimeBlock _
        | DeclOther ->
            None)

(* ============================================================================
   Record field lookup
   ============================================================================ *)

let expr_type_opt expr =
  match expr.expr_type_info with
  | Some { semantic_ty; _ } -> Some semantic_ty
  | None -> None

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

type record_field_hit = {
  field_name : string;
  field_type : type_expr;
  field_loc : loc;
  occurrence_loc : loc;
}

let record_field_info ?(module_aliases = []) (env : Env.env) receiver_ty
    field_name : (loc * type_expr) option =
  let resolution_ctx = Type_resolution.make_context ~env ~module_aliases () in
  match Type_resolution.annotation_canonical resolution_ctx receiver_ty with
  | TyNamed (record_name, type_args) -> (
      match Env.get_record env record_name with
      | Some (type_params, fields) ->
          fields
          |> List.find_opt (fun (field : Ast.field_decl) ->
              field.field_name = field_name)
          |> Option.map (fun (field : Ast.field_decl) ->
              ( field.field_loc,
                instantiate_type_params type_params type_args field.field_type
              ))
      | None -> None)
  | _ -> None

let field_span_after_receiver text receiver_loc field_name :
    (int * int * int) option =
  match line_at text ~line:(receiver_loc.end_line - 1) with
  | None -> None
  | Some line_text ->
      let field_start = receiver_loc.end_column in
      let field_end = field_start + String.length field_name in
      if
        receiver_loc.end_line > 0 && field_start > 0
        && field_end <= String.length line_text
        && line_text.[field_start - 1] = '.'
        && String.sub line_text field_start (String.length field_name)
           = field_name
      then Some (receiver_loc.end_line - 1, field_start, field_end)
      else None

let position_inside_span ~line ~col (span_line, start_col, end_col) =
  line = span_line && start_col <= col && col <= end_col

let record_field_loc ?module_aliases (env : Env.env) receiver_ty field_name :
    loc option =
  record_field_info ?module_aliases env receiver_ty field_name |> Option.map fst

let next_non_space line_text start stop =
  let rec loop i =
    if i >= stop then None
    else if line_text.[i] = ' ' || line_text.[i] = '\t' then loop (i + 1)
    else Some i
  in
  loop start

let only_spaces_between line_text start stop =
  let rec loop i =
    if i >= stop then true
    else (line_text.[i] = ' ' || line_text.[i] = '\t') && loop (i + 1)
  in
  loop start

let occurrence_loc_of_span ?file line start_col end_col =
  {
    line = line + 1;
    column = start_col + 1;
    end_line = line + 1;
    end_column = end_col + 1;
    loc_file = file;
  }

let field_assignment_loc_before_value ?file text field_name value_expr :
    loc option =
  let value_line = value_expr.expr_loc.line - 1 in
  let value_col = max 0 (value_expr.expr_loc.column - 1) in
  match line_at text ~line:value_line with
  | None -> None
  | Some line_text ->
      let stop = min value_col (String.length line_text) in
      let rec scan i best =
        if i >= stop then best
        else if is_ident_char line_text.[i] then
          let start_col = scan_ident_start line_text i in
          let end_col = scan_ident_end line_text i in
          let word = String.sub line_text start_col (end_col - start_col) in
          let best =
            if word = field_name then
              match next_non_space line_text end_col stop with
              | Some eq_col
                when line_text.[eq_col] = '='
                     && only_spaces_between line_text (eq_col + 1) stop ->
                  Some
                    (occurrence_loc_of_span ?file value_line start_col end_col)
              | _ -> best
            else best
          in
          scan end_col best
        else scan (i + 1) best
      in
      scan 0 None

let record_assignment_fields = function
  | ERecord fields | ERecordUpdate (_, fields) -> Some fields
  | _ -> None

let record_assignment_receiver_type expr =
  match expr.expr_desc with
  | ERecord _ -> expr_type_opt expr
  | ERecordUpdate (base, _) -> (
      match expr_type_opt expr with
      | Some _ as ty -> ty
      | None -> expr_type_opt base)
  | _ -> None

let record_field_assignment_hits_for_expr ?(module_aliases = []) ?file
    (env : Env.env) text expr : record_field_hit list =
  match
    ( record_assignment_fields expr.expr_desc,
      record_assignment_receiver_type expr )
  with
  | Some fields, Some receiver_ty ->
      fields
      |> List.filter_map (fun (field_name, value_expr) ->
          match
            ( field_assignment_loc_before_value ?file text field_name value_expr,
              record_field_info ~module_aliases env receiver_ty field_name )
          with
          | Some occurrence_loc, Some (field_loc, field_type) ->
              Some { field_name; field_type; field_loc; occurrence_loc }
          | _ -> None)
  | _ -> []

let find_record_field_assignment_hit ?(module_aliases = []) ?file
    (env : Env.env) (program : program) ~(text : string) ~(line : int)
    ~(col : int) : record_field_hit option =
  let best = ref None in
  let best_start = ref (-1, -1) in
  let loc_starts_after a (line_b, col_b) =
    a.line > line_b || (a.line = line_b && a.column > col_b)
  in
  let consider expr =
    let expr_start = (expr.expr_loc.line, expr.expr_loc.column) in
    if loc_starts_after expr.expr_loc !best_start then
      record_field_assignment_hits_for_expr ~module_aliases ?file env text expr
      |> List.iter (fun hit ->
          if col_inside_name hit.occurrence_loc hit.field_name ~line ~col then begin
            best := Some hit;
            best_start := expr_start
          end)
  in
  let rec walk_expr expr =
    (match expr.expr_desc with
    | ERecord _ | ERecordUpdate _ -> consider expr
    | _ -> ());
    List.iter walk_expr (expr_children expr)
  in
  let rec walk_decl decl =
    match decl.decl_desc with
    | DFunc fd -> fd.func_body |> func_body_expr_opt |> Option.iter walk_expr
    | DVar vd -> walk_expr vd.var_value
    | DCompileTimeBlock bindings ->
        List.iter (fun binding -> walk_expr binding.ctb_var.var_value) bindings
    | DImpl impl ->
        List.iter
          (fun fd ->
            fd.func_body |> func_body_expr_opt |> Option.iter walk_expr)
          impl.impl_methods
    | DPrivate inner -> walk_decl inner
    | DType _ | DRecord _ | DImport _ | DTrait _ | DTypeAlias _ -> ()
  in
  List.iter walk_decl program;
  !best

let find_record_field_definition (env : Env.env) (program : program)
    ~(text : string) ~(line : int) ~(col : int) : loc option =
  let field_name_opt = word_at text ~line ~col in
  let best = ref None in
  let best_col = ref (-1) in
  let consider receiver field_name =
    match field_name_opt with
    | Some wanted when wanted = field_name -> (
        match field_span_after_receiver text receiver.expr_loc field_name with
        | Some ((_, start_col, _end_col) as span)
          when position_inside_span ~line ~col span && start_col >= !best_col
          -> (
            match expr_type_opt receiver with
            | Some receiver_ty -> (
                match record_field_loc env receiver_ty field_name with
                | Some loc ->
                    best := Some loc;
                    best_col := start_col
                | None -> ())
            | None -> ())
        | _ -> ())
    | _ -> ()
  in
  let rec walk_expr expr =
    match expr.expr_desc with
    | EFieldAccess (receiver, field_name) ->
        consider receiver field_name;
        walk_expr receiver
    | _ -> List.iter walk_expr (expr_children expr)
  in
  let rec walk_decl decl =
    match decl.decl_desc with
    | DFunc fd -> fd.func_body |> func_body_expr_opt |> Option.iter walk_expr
    | DVar vd -> walk_expr vd.var_value
    | DCompileTimeBlock bindings ->
        List.iter (fun binding -> walk_expr binding.ctb_var.var_value) bindings
    | DImpl impl ->
        List.iter
          (fun fd ->
            fd.func_body |> func_body_expr_opt |> Option.iter walk_expr)
          impl.impl_methods
    | DPrivate inner -> walk_decl inner
    | DType _ | DRecord _ | DImport _ | DTrait _ | DTypeAlias _ -> ()
  in
  List.iter walk_decl program;
  !best

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

type type_param_hit = {
  type_param_name : string;
  type_param_label : string;
  type_param_loc : loc;
}

let skip_spaces text stop i =
  let rec loop i =
    if i >= stop || i >= String.length text || text.[i] <> ' ' then i
    else loop (i + 1)
  in
  loop i

let type_param_name_span_in_segment text segment_start segment_stop :
    (string * int * int) option =
  let start = skip_spaces text segment_stop segment_start in
  if start >= segment_stop then None
  else if text.[start] = '#' then
    let name_start = start in
    let ident_start = start + 1 in
    if ident_start < segment_stop && is_ident_char text.[ident_start] then
      let name_end = scan_ident_end text ident_start in
      Some
        ( String.sub text name_start (name_end - name_start),
          name_start,
          name_end )
    else None
  else if
    (text.[start] >= 'a' && text.[start] <= 'z')
    || (text.[start] >= 'A' && text.[start] <= 'Z')
    || text.[start] = '_'
  then
    let name_end = scan_ident_end text start in
    Some (String.sub text start (name_end - start), start, name_end)
  else None

let rec matching_bracket text open_index depth i =
  if i >= String.length text then None
  else
    match text.[i] with
    | '[' -> matching_bracket text open_index (depth + 1) (i + 1)
    | ']' when depth = 1 -> Some i
    | ']' -> matching_bracket text open_index (depth - 1) (i + 1)
    | _ -> matching_bracket text open_index depth (i + 1)

let first_type_param_list_after_name line_text name =
  let name_len = String.length name in
  let rec find_name start =
    if start + name_len > String.length line_text then None
    else if String.sub line_text start name_len = name then
      Some (start + name_len)
    else find_name (start + 1)
  in
  match find_name 0 with
  | None -> None
  | Some after_name -> (
      let rec find_open i =
        if i >= String.length line_text then None
        else
          match line_text.[i] with
          | '[' -> Some i
          | '(' | ':' | '=' -> None
          | _ -> find_open (i + 1)
      in
      match find_open after_name with
      | None -> None
      | Some open_index -> (
          match matching_bracket line_text open_index 1 (open_index + 1) with
          | Some close_index -> Some (open_index, close_index)
          | None -> None))

let type_param_decl_span line_text ~decl_name ~param_name =
  match first_type_param_list_after_name line_text decl_name with
  | None -> None
  | Some (open_index, close_index) ->
      let rec loop segment_start i =
        if i > close_index then None
        else if i = close_index || line_text.[i] = ',' then
          let match_segment =
            match type_param_name_span_in_segment line_text segment_start i with
            | Some (name, start_col, end_col) when name = param_name ->
                Some (start_col, end_col)
            | _ -> None
          in
          match match_segment with
          | Some _ as span -> span
          | None -> loop (i + 1) (i + 1)
        else loop segment_start (i + 1)
      in
      loop (open_index + 1) (open_index + 1)

let type_param_loc_for_decl_name ?file text decl_loc decl_name param_name =
  if not (loc_matches_file ?file decl_loc) then None
  else
    let line_index = decl_loc.line - 1 in
    match line_at text ~line:line_index with
    | None -> None
    | Some line_text ->
        type_param_decl_span line_text ~decl_name ~param_name
        |> Option.map (fun (start_col, end_col) ->
            {
              line = decl_loc.line;
              column = start_col + 1;
              end_line = decl_loc.line;
              end_column = end_col + 1;
              loc_file = decl_loc.loc_file;
            })

let type_param_hit_for_decl ?file text decl_loc decl_name type_params name =
  match
    List.find_opt (fun param -> Ast.type_param_name param = name) type_params
  with
  | None -> None
  | Some param ->
      type_param_loc_for_decl_name ?file text decl_loc decl_name name
      |> Option.map (fun type_param_loc ->
          {
            type_param_name = name;
            type_param_label =
              Printf.sprintf "type parameter %s"
                (Ast.type_param_to_parser_string param);
            type_param_loc;
          })

let cursor_is_type_param_decl_site hit ~line ~col =
  col_inside_name hit.type_param_loc hit.type_param_name ~line ~col

let function_body_or_header_reaches_target_line decl_loc fd ~target_line =
  decl_loc.line <= target_line
  && (target_line = decl_loc.line
     || function_body_reaches_target_line fd ~target_line)

let find_function_type_param_at ?file (program : program) ~(text : string)
    ~(line : int) ~(col : int) : type_param_hit option =
  let target_line = line + 1 in
  match word_at text ~line ~col with
  | None -> None
  | Some name ->
      let in_type_context = is_type_name_context_at text ~line ~col in
      let check_func decl_loc fd =
        match fd.func_name with
        | None -> None
        | Some decl_name ->
            if
              function_body_or_header_reaches_target_line decl_loc fd
                ~target_line
            then
              match
                type_param_hit_for_decl ?file text decl_loc decl_name
                  fd.func_type_params name
              with
              | Some hit
                when in_type_context
                     || cursor_is_type_param_decl_site hit ~line ~col ->
                  Some hit
              | _ -> None
            else None
      in
      let rec check_decl decl =
        match decl.decl_desc with
        | DFunc fd -> check_func decl.decl_loc fd
        | DImpl impl ->
            List.find_map (check_func decl.decl_loc) impl.impl_methods
        | DPrivate inner -> check_decl inner
        | DType _ | DRecord _ | DImport _ | DTrait _ | DTypeAlias _ | DVar _
        | DCompileTimeBlock _ ->
            None
      in
      List.find_map check_decl program

let identifier_spans_for_line (line_text : string) : (string * int * int) list =
  let len = String.length line_text in
  let rec loop i acc =
    if i >= len then List.rev acc
    else
      match dim_span_starting_at line_text i with
      | Some (start_col, end_col) ->
          let name = String.sub line_text start_col (end_col - start_col) in
          loop end_col ((name, start_col, end_col) :: acc)
      | None ->
          if
            (line_text.[i] >= 'a' && line_text.[i] <= 'z')
            || (line_text.[i] >= 'A' && line_text.[i] <= 'Z')
            || line_text.[i] = '_'
          then
            let end_col = scan_ident_end line_text i in
            let name = String.sub line_text i (end_col - i) in
            loop end_col ((name, i, end_col) :: acc)
          else loop (i + 1) acc
  in
  loop 0 []

let type_param_occurrence_loc ?file ~line start_col end_col =
  {
    line = line + 1;
    column = start_col + 1;
    end_line = line + 1;
    end_column = end_col + 1;
    loc_file = file;
  }

let collect_function_type_param_occurrences ?file (program : program)
    ~(text : string) (target : type_param_hit) : loc list =
  let function_matches decl_loc fd =
    match fd.func_name with
    | None -> false
    | Some decl_name -> (
        match
          type_param_hit_for_decl ?file text decl_loc decl_name
            fd.func_type_params target.type_param_name
        with
        | Some hit -> loc_same_position hit.type_param_loc target.type_param_loc
        | None -> false)
  in
  let collect_from_func decl_loc fd =
    let start_line = decl_loc.line - 1 in
    let end_line =
      match func_body_end_line fd with
      | Some line -> max decl_loc.line line - 1
      | None -> start_line
    in
    let rec collect_line line acc =
      if line > end_line then List.rev acc
      else
        match line_at text ~line with
        | None -> collect_line (line + 1) acc
        | Some line_text ->
            let line_occurrences =
              identifier_spans_for_line line_text
              |> List.filter_map (fun (name, start_col, end_col) ->
                  if name <> target.type_param_name then None
                  else
                    let loc =
                      type_param_occurrence_loc ?file ~line start_col end_col
                    in
                    if loc_same_position loc target.type_param_loc then Some loc
                    else if is_type_name_context line_text start_col then
                      Some loc
                    else None)
            in
            collect_line (line + 1) (List.rev_append line_occurrences acc)
    in
    collect_line start_line []
  in
  let rec collect_decl decl =
    match decl.decl_desc with
    | DFunc fd when function_matches decl.decl_loc fd ->
        collect_from_func decl.decl_loc fd
    | DImpl impl -> (
        match
          List.find_opt (function_matches decl.decl_loc) impl.impl_methods
        with
        | Some fd -> collect_from_func decl.decl_loc fd
        | None -> [])
    | DPrivate inner -> collect_decl inner
    | DFunc _ | DVar _ | DType _ | DRecord _ | DImport _ | DTrait _
    | DTypeAlias _ | DCompileTimeBlock _ ->
        []
  in
  List.find_map
    (fun decl ->
      match collect_decl decl with
      | [] -> None
      | occurrences -> Some occurrences)
    program
  |> Option.value ~default:[]

(* ============================================================================
   Definition lookup — for go-to-definition
   ============================================================================ *)

let loc_at_declared_name loc ~name ~keyword_prefix =
  let column = loc.column + String.length keyword_prefix in
  {
    loc with
    column;
    end_line = loc.line;
    end_column = column + String.length name;
  }

let type_decl_name_loc loc (td : type_decl) =
  let keyword_prefix =
    if td.type_is_resource then "resource type "
    else if td.type_is_enum then "enum "
    else if td.type_variants = [] then "type "
    else "union "
  in
  loc_at_declared_name loc ~name:td.type_name ~keyword_prefix

let record_decl_name_loc loc (rd : record_decl) =
  let keyword_prefix = if rd.record_is_value then "struct " else "record " in
  loc_at_declared_name loc ~name:rd.record_name ~keyword_prefix

let trait_decl_name_loc loc (td : trait_decl) =
  loc_at_declared_name loc ~name:td.trait_name ~keyword_prefix:"trait "

let type_alias_name_loc loc (ad : type_alias_decl) =
  let keyword_prefix =
    if ad.alias_is_opaque then "opaque type " else "type alias "
  in
  loc_at_declared_name loc ~name:ad.alias_name ~keyword_prefix

let func_decl_name_loc loc (fd : func_decl) =
  match fd.func_name with
  | None -> loc
  | Some name -> (
      let from_first_param =
        match fd.func_params with
        | first_param :: _ ->
            let type_param_suffix_len =
              match fd.func_type_params with
              | [] -> 0
              | params ->
                  2
                  + String.length
                      (String.concat ", "
                         (List.map type_param_to_parser_string params))
            in
            let column =
              first_param.param_loc.column - String.length name
              - type_param_suffix_len - 1
            in
            if column > 0 then
              Some
                {
                  line = first_param.param_loc.line;
                  column;
                  end_line = first_param.param_loc.line;
                  end_column = column + String.length name;
                  loc_file = loc.loc_file;
                }
            else None
        | [] -> None
      in
      match from_first_param with
      | Some loc -> loc
      | None ->
          let keyword_prefix =
            if fd.func_is_pure then "pure func " else "func "
          in
          loc_at_declared_name loc ~name ~keyword_prefix)

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
          | DFunc fd when fd.func_name = Some name ->
              Some (func_decl_name_loc d.decl_loc fd)
          | DVar vd when vd.var_name = Some name -> Some d.decl_loc
          | DType td when td.type_name = name ->
              Some (type_decl_name_loc d.decl_loc td)
          | DType td -> (
              match
                List.find_opt
                  (fun (v : variant) -> v.variant_name = name)
                  td.type_variants
              with
              | Some variant ->
                  Some
                    (loc_at_declared_name variant.variant_loc
                       ~name:variant.variant_name ~keyword_prefix:"")
              | None -> None)
          | DRecord rd when rd.record_name = name ->
              Some (record_decl_name_loc d.decl_loc rd)
          | DTrait td when td.trait_name = name ->
              Some (trait_decl_name_loc d.decl_loc td)
          | DTypeAlias ad when ad.alias_name = name ->
              Some (type_alias_name_loc d.decl_loc ad)
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
        else
          let mapper_match =
            match binding.with_error_map with
            | Some mapper
              when mapper.with_error_name = name
                   && loc_starts_before_cursor e.expr_loc ->
                Some e.expr_loc
            | _ -> None
          in
          Option.fold ~none:(find_local_in_expr body)
            ~some:(fun loc -> Some loc)
            mapper_match
    | EConcurrent (bindings, _, _) -> find_local_in_exprs bindings
    | EConcurrentBind (n, _, _)
      when n = name && loc_starts_before_cursor e.expr_loc ->
        Some e.expr_loc
    | EConcurrentlyLoop (n, _, body, _, _) ->
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
    without an explicit import. *)
let prelude_ufcs_modules = Language_surface.prelude_ufcs_modules

(* Core trait names are accepted in bounds without an explicit source import.
   Navigation should expose only trait declarations from these modules, not every
   helper function or method declaration they contain. *)
let prelude_trait_modules = [ "traits" ]

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

let resolve_imported_name_on_import_line (imp : Ast.import_decl)
    (clicked_name : string) : string option =
  match imp.import_symbols with
  | Some syms -> (
      match
        List.find_opt
          (fun s ->
            s.sym_name = clicked_name
            || import_symbol_local_name s = clicked_name)
          syms
      with
      | Some s -> Some s.sym_name
      | None ->
          if List.exists (import_symbol_imports_ctor clicked_name) syms then
            Some clicked_name
          else None)
  | None -> Some clicked_name

(** Search a loaded module's AST for [name]; returns its location if found. *)
let find_in_module (m : Modules.loaded_module) ~(name : string) : Ast.loc option
    =
  find_definition m.decls ~name ~line:0 ~col:0

let find_trait_in_module (m : Modules.loaded_module) ~(name : string) :
    Ast.loc option =
  let rec find_in_decls decls =
    match decls with
    | [] -> None
    | (d : Ast.decl) :: rest -> (
        match d.decl_desc with
        | DTrait trait when trait.trait_name = name ->
            Some (trait_decl_name_loc d.decl_loc trait)
        | DPrivate inner -> (
            match find_in_decls [ inner ] with
            | Some _ as hit -> hit
            | None -> find_in_decls rest)
        | _ -> find_in_decls rest)
  in
  find_in_decls m.decls

type resolved_call_definition = {
  resolved_definition_path : string option;
  resolved_definition_loc : Ast.loc;
}

let visible_call_source_name name =
  let clean = Call_resolution.strip_callable_id_suffix name in
  match Codegen_names.parse_ufcs_name clean with
  | Some (_, original_name) -> original_name
  | None -> clean

let resolved_call_source_name (call : Ast.resolved_call) =
  match call.call_target with
  | CallDirect { source_name; _ } -> Some (visible_call_source_name source_name)
  | CallTraitMethod { method_name; _ } -> Some method_name
  | CallClosure _ -> None

let typed_expr_loc expr = (Typed_ast.ast expr).expr_loc
let optional_expr = function Some expr -> [ expr ] | None -> []

let typed_func_body_expr_opt func =
  match Typed_ast.func_body_expr func with Ok body -> body | Error _ -> None

let typed_expr_children expr =
  match Typed_ast.expr_desc expr with
  | Error _ -> []
  | Ok desc -> (
      match desc with
      | Typed_ast.EIdent _ | ELiteral _ | EVoid | EBreak | EContinue
      | EStringInterpRaw _ | EBuiltin _ ->
          []
      | EUnary (_, inner)
      | EAscription (inner, _)
      | EOpaqueInto (_, inner)
      | EOpaqueFrom (_, inner)
      | EDetach inner ->
          [ inner ]
      | EBinary (_, left, right)
      | ELogical (_, left, right)
      | EWhile (left, right)
      | ERange (left, right)
      | ESubscript (left, right) ->
          [ left; right ]
      | ECall (callee, args) -> callee :: args
      | EIf (cond, then_, else_) -> cond :: then_ :: optional_expr else_
      | EMatch (scrutinee, cases) ->
          scrutinee :: List.map (fun case -> case.Typed_ast.case_body) cases
      | EBlock exprs
      | ETuple exprs
      | EVector exprs
      | EList exprs
      | EDebugBlock exprs
      | EConcurrent (exprs, _, _) ->
          exprs
      | ERecord fields -> List.map snd fields
      | ERecordUpdate (base, fields) -> base :: List.map snd fields
      | EFieldAccess (receiver, _) -> [ receiver ]
      | ELambda func | EFuncDecl func -> (
          match typed_func_body_expr_opt func with
          | Some body -> [ body ]
          | None -> [])
      | EFor (_, iter, body) | EForTuple (_, iter, body) -> [ iter; body ]
      | ELoopView view ->
          view.Typed_ast.loop_view_source
          :: optional_expr view.loop_view_size_arg
      | EAssign (_, rhs)
      | ECompoundAssign (_, _, rhs)
      | EVarDecl (_, _, rhs, _)
      | ETupleDestruct (_, rhs)
      | EQuestionBind (_, _, rhs)
      | EConcurrentBind (_, _, rhs) ->
          [ rhs ]
      | ESubscriptMulti (coll, indices) -> coll :: indices
      | ESubscriptAssign (coll, indices, value) -> coll :: (indices @ [ value ])
      | EStringInterp (parts, _) ->
          List.filter_map
            (function
              | Typed_ast.InterpExpr expr -> Some expr | InterpLit _ -> None)
            parts
      | EWith (binding, body) ->
          binding.with_value :: body
          ::
          (match binding.with_error_map with
          | Some mapper -> [ mapper.with_error_value ]
          | None -> [])
      | ESelect arms ->
          List.concat_map
            (fun arm ->
              let kind_exprs =
                match arm.Typed_ast.select_arm_kind with
                | SelectRecv { select_channel; _ }
                | SelectSealed { select_channel; _ } ->
                    [ select_channel ]
                | SelectAfter timeout -> [ timeout ]
              in
              kind_exprs @ [ arm.select_arm_body ])
            arms
      | EConcurrentlyLoop (_, iter, body, timeout, _) ->
          iter :: body :: optional_expr timeout
      | EDict pairs -> List.concat_map (fun (k, v) -> [ k; v ]) pairs)

let find_resolved_call_at (program : Typed_ast.program) ~(name : string)
    ~(line : int) ~(col : int) : Ast.resolved_call option =
  let best = ref None in
  let best_start = ref (-1, -1) in
  let target_line = line + 1 in
  let target_col = col + 1 in
  let loc_starts_after loc (line_b, col_b) =
    loc.line > line_b || (loc.line = line_b && loc.column > col_b)
  in
  let call_loc_can_refer_to_cursor loc =
    loc_contains_position loc ~line ~col
    || (loc.line = target_line && loc.column <= target_col)
  in
  let consider expr =
    let loc = typed_expr_loc expr in
    if call_loc_can_refer_to_cursor loc && loc_starts_after loc !best_start then
      match Typed_ast.expr_resolved_call expr with
      | Some call when resolved_call_source_name call = Some name ->
          best := Some call;
          best_start := (loc.line, loc.column)
      | _ -> ()
  in
  let rec walk_expr expr =
    consider expr;
    List.iter walk_expr (typed_expr_children expr)
  in
  let walk_func func = typed_func_body_expr_opt func |> Option.iter walk_expr in
  let rec walk_decl decl =
    match Typed_ast.decl_view decl with
    | DeclFunction func -> walk_func func
    | DeclVar var -> (
        match Typed_ast.var_value_expr var with
        | Ok expr -> walk_expr expr
        | Error _ -> ())
    | DeclImpl impl -> List.iter walk_func (Typed_ast.impl_methods impl)
    | DeclPrivate inner -> walk_decl inner
    | DeclCompileTimeBlock bindings ->
        List.iter
          (fun binding ->
            let var = Typed_ast.compile_time_binding_var binding in
            match Typed_ast.var_value_expr var with
            | Ok expr -> walk_expr expr
            | Error _ -> ())
          bindings
    | DeclRecord _ | DeclTypeAlias _ | DeclOther -> ()
  in
  program |> Typed_ast.program_decls |> List.iter walk_decl;
  !best

let find_callable_definition_in_program (program : Typed_ast.program)
    ~(callable_id : int) : Ast.loc option =
  let rec find_decl decl =
    let ast_decl = Typed_ast.decl_ast decl in
    match Typed_ast.decl_view decl with
    | DeclFunction func when Typed_ast.func_callable_id func = Some callable_id
      ->
        Some (func_decl_name_loc ast_decl.decl_loc (Typed_ast.func_ast func))
    | DeclPrivate inner -> find_decl inner
    | DeclFunction _ | DeclVar _ | DeclRecord _ | DeclTypeAlias _ | DeclImpl _
    | DeclCompileTimeBlock _ | DeclOther ->
        None
  in
  program |> Typed_ast.program_decls |> List.find_map find_decl

let find_loaded_module_by_path ?base_dir module_path =
  let cached_by_name_or_path () =
    match Modules.find_cached module_path with
    | Some _ as hit -> hit
    | None ->
        Modules.get_all_modules ()
        |> List.find_opt (fun (m : Modules.loaded_module) ->
            m.name = module_path || m.path = module_path)
  in
  match base_dir with
  | Some base_dir -> (
      match Modules.load_module module_path base_dir with
      | Some _ as hit -> hit
      | None -> cached_by_name_or_path ())
  | None -> cached_by_name_or_path ()

let find_loaded_import_module ?base_dir (imp : Ast.import_decl) =
  find_loaded_module_by_path ?base_dir imp.import_module

let find_callable_definition_in_module (m : Modules.loaded_module)
    ~(callable_id : int) ~(source_name : string) :
    resolved_call_definition option =
  match
    Option.bind m.typed_decls (fun typed_program ->
        find_callable_definition_in_program typed_program ~callable_id)
  with
  | Some loc ->
      Some
        {
          resolved_definition_path = Some m.path;
          resolved_definition_loc = loc;
        }
  | None ->
      find_in_module m ~name:source_name
      |> Option.map (fun loc ->
          {
            resolved_definition_path = Some m.path;
            resolved_definition_loc = loc;
          })

let find_callable_definition_anywhere (current_program : Typed_ast.program)
    ~(callable_id : int) ~(source_name : string) :
    resolved_call_definition option =
  match find_callable_definition_in_program current_program ~callable_id with
  | Some loc ->
      Some { resolved_definition_path = None; resolved_definition_loc = loc }
  | None ->
      Modules.get_all_modules ()
      |> List.find_map (fun m ->
          find_callable_definition_in_module m ~callable_id ~source_name)

let find_resolved_call_definition ?base_dir (program : Typed_ast.program)
    ~(name : string) ~(line : int) ~(col : int) :
    resolved_call_definition option =
  match find_resolved_call_at program ~name ~line ~col with
  | None -> None
  | Some call -> (
      match call.call_target with
      | CallDirect { callable_id; source_name; origin; _ } -> (
          let source_name = visible_call_source_name source_name in
          let by_id () =
            find_callable_definition_anywhere program ~callable_id ~source_name
          in
          let by_imported_module module_path =
            match find_loaded_module_by_path ?base_dir module_path with
            | Some m ->
                find_callable_definition_in_module m ~callable_id ~source_name
            | None -> by_id ()
          in
          match origin with
          | CallableLocal -> by_id ()
          | CallableImported module_path -> by_imported_module module_path
          | CallableBuiltin | CallableForeign | CallableConstructor _
          | CallableImplMethod ->
              by_id ())
      | CallTraitMethod { callable_id = Some callable_id; method_name; _ } ->
          find_callable_definition_anywhere program ~callable_id
            ~source_name:method_name
      | CallTraitMethod { callable_id = None; _ } | CallClosure _ -> None)

(** Top-of-file location used when navigating to a whole module. *)
let module_top_loc : Ast.loc =
  { line = 1; column = 1; end_line = 1; end_column = 1; loc_file = None }

let is_inline_whitespace = function ' ' | '\t' -> true | _ -> false

let leading_whitespace_len text =
  let len = String.length text in
  let rec loop i =
    if i >= len || not (is_inline_whitespace text.[i]) then i else loop (i + 1)
  in
  loop 0

let skip_inline_whitespace text i =
  let len = String.length text in
  let rec loop i =
    if i >= len || not (is_inline_whitespace text.[i]) then i else loop (i + 1)
  in
  loop i

let starts_with_at text ~pos prefix =
  let prefix_len = String.length prefix in
  pos >= 0
  && pos + prefix_len <= String.length text
  && String.sub text pos prefix_len = prefix

let import_alias_end text start =
  let start = skip_inline_whitespace text start in
  let stop = scan_ident_end text start in
  if stop > start then Some stop else None

let import_header_colon_index (line_text : string) module_end =
  let len = String.length line_text in
  let after_module = skip_inline_whitespace line_text module_end in
  if after_module >= len then None
  else if line_text.[after_module] = ':' then Some after_module
  else if
    starts_with_at line_text ~pos:after_module "as"
    && (after_module + 2 >= len
       || not (is_ident_char line_text.[after_module + 2]))
  then
    match import_alias_end line_text (after_module + 2) with
    | Some alias_end ->
        let after_alias = skip_inline_whitespace line_text alias_end in
        if after_alias < len && line_text.[after_alias] = ':' then
          Some after_alias
        else None
    | None -> None
  else None

let import_header_span_on_line (line_text : string) (imp : Ast.import_decl) :
    (int * int) option =
  let start = leading_whitespace_len line_text in
  let module_len = String.length imp.import_module in
  let module_end = start + module_len in
  if starts_with_at line_text ~pos:start imp.import_module then
    let after_module = skip_inline_whitespace line_text module_end in
    if
      after_module = String.length line_text
      || Option.is_some (import_header_colon_index line_text module_end)
      || starts_with_at line_text ~pos:after_module "as"
    then Some (start, module_end)
    else None
  else None

let import_header_has_symbol_block line_text imp =
  match import_header_span_on_line line_text imp with
  | None -> false
  | Some (_, module_end) -> (
      match import_header_colon_index line_text module_end with
      | None -> false
      | Some colon ->
          let after_colon = colon + 1 in
          let suffix =
            String.sub line_text after_colon
              (String.length line_text - after_colon)
          in
          String.trim suffix = "")

let cursor_inside_span ~(col : int) (start_col, end_col) =
  col >= start_col && col <= end_col

let rec collect_imports acc = function
  | [] -> List.rev acc
  | (d : Ast.decl) :: rest -> (
      match d.decl_desc with
      | DImport imp -> collect_imports (imp :: acc) rest
      | DPrivate inner -> collect_imports acc (inner :: rest)
      | _ -> collect_imports acc rest)

let find_import_module_at_cursor (program : Ast.program) ~(text : string)
    ~(line : int) ~(col : int) : Ast.import_decl option =
  match line_at text ~line with
  | None -> None
  | Some line_text ->
      collect_imports [] program
      |> List.find_opt (fun imp ->
          match import_header_span_on_line line_text imp with
          | Some span -> cursor_inside_span ~col span
          | None -> false)

let find_import_module_span_at_cursor (program : Ast.program) ~(text : string)
    ~(line : int) ~(col : int) : (int * int) option =
  match line_at text ~line with
  | None -> None
  | Some line_text ->
      collect_imports [] program
      |> List.find_map (fun imp ->
          match import_header_span_on_line line_text imp with
          | Some span when cursor_inside_span ~col span -> Some span
          | _ -> None)

let find_import_header_on_line imports line_text =
  List.find_map
    (fun imp ->
      match import_header_span_on_line line_text imp with
      | Some span -> Some (imp, span)
      | None -> None)
    imports

let line_is_inside_import_symbol_block lines ~header_line ~target_line
    ~header_indent =
  let rec loop line_index =
    if line_index > target_line then true
    else
      let line_text = lines.(line_index) in
      if String.trim line_text = "" then loop (line_index + 1)
      else if leading_whitespace_len line_text > header_indent then
        loop (line_index + 1)
      else false
  in
  loop (header_line + 1)

let find_import_declaration_line_at_cursor (program : Ast.program)
    ~(text : string) ~(line : int) ~(col : int) : Ast.import_decl option =
  let lines = String.split_on_char '\n' text |> Array.of_list in
  if line < 0 || line >= Array.length lines then None
  else
    let imports = collect_imports [] program in
    let line_text = lines.(line) in
    match find_import_header_on_line imports line_text with
    | Some (imp, (start_col, _)) when col >= start_col -> Some imp
    | _ ->
        let target_indent = leading_whitespace_len line_text in
        let rec scan header_line =
          if header_line < 0 then None
          else
            let header_text = lines.(header_line) in
            match find_import_header_on_line imports header_text with
            | Some (imp, _) ->
                let header_indent = leading_whitespace_len header_text in
                if
                  target_indent > header_indent
                  && import_header_has_symbol_block header_text imp
                  && line_is_inside_import_symbol_block lines ~header_line
                       ~target_line:line ~header_indent
                then Some imp
                else None
            | None -> scan (header_line - 1)
        in
        scan (line - 1)

let find_import_module_definition_at_cursor ?base_dir (program : Ast.program)
    ~(text : string) ~(line : int) ~(col : int) : (string * Ast.loc) option =
  match find_import_module_at_cursor program ~text ~line ~col with
  | None -> None
  | Some imp -> (
      match find_loaded_import_module ?base_dir imp with
      | Some m -> Some (m.path, module_top_loc)
      | None -> None)

(** Does [name] refer to the module imported by [imp]? Matches either the
    explicit `as` alias or the last segment of the module path. *)
let import_names_module (imp : Ast.import_decl) (name : string) : bool =
  match imp.import_alias with
  | Some a -> a = name
  | None -> Filename.basename imp.import_module = name

let find_imported_name_definition_at_cursor ?base_dir (program : Ast.program)
    ~(text : string) ~(line : int) ~(col : int) ~(name : string) :
    (string * Ast.loc) option =
  match find_import_declaration_line_at_cursor program ~text ~line ~col with
  | None -> None
  | Some imp -> (
      match find_loaded_import_module ?base_dir imp with
      | None -> None
      | Some m -> (
          if import_names_module imp name then Some (m.path, module_top_loc)
          else
            match resolve_imported_name_on_import_line imp name with
            | Some original -> (
                match find_in_module m ~name:original with
                | Some loc -> Some (m.path, loc)
                | None -> None)
            | None -> None))

(** Find [name] across modules imported by [program] and across the prelude
    UFCS modules (list/option/string/...). Returns the module's file path and
    the definition's location in that file.

    Resolution order:
      1. Symbol exported by an explicit import ({name}, {name as alias}).
      2. Module itself — click on `option` or an alias `L` jumps to top-of-file.
      3. Symbol reachable through a prelude UFCS module.
      4. Trait declaration reachable through implicit core trait bounds. *)
let find_cross_module_definition ?base_dir (program : Ast.program)
    ~(name : string) : (string * Ast.loc) option =
  let try_module mod_name lookup_name =
    match find_loaded_module_by_path ?base_dir mod_name with
    | Some m -> (
        match find_in_module m ~name:lookup_name with
        | Some loc -> Some (m.path, loc)
        | None -> None)
    | None -> None
  in
  let try_trait_module mod_name lookup_name =
    match find_loaded_module_by_path ?base_dir mod_name with
    | Some m -> (
        match find_trait_in_module m ~name:lookup_name with
        | Some loc -> Some (m.path, loc)
        | None -> None)
    | None -> None
  in
  let try_module_itself (imp : Ast.import_decl) : (string * Ast.loc) option =
    match find_loaded_import_module ?base_dir imp with
    | Some m -> Some (m.path, module_top_loc)
    | None -> None
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
      | None -> (
          (* 3. Fall back to prelude UFCS modules — no import required. *)
          match
            List.find_map
              (fun mod_name -> try_module mod_name name)
              prelude_ufcs_modules
          with
          | Some _ as r -> r
          | None ->
              (* 4. Trait bounds use core std traits without an explicit import,
                 but only trait names are globally reachable this way. *)
              List.find_map
                (fun mod_name -> try_trait_module mod_name name)
                prelude_trait_modules))
