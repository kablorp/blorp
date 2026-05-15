(** AST-to-Document IR printer for the Blorp formatter.

    All formatting rules are encoded here. The printer traverses the AST
    and produces Fmt_doc.doc values that are then laid out by Fmt_layout. *)

open Ast
open Fmt_doc

(** Escape a character using blorp-compatible escape sequences.
    OCaml's Char.escaped produces escapes like \195 that blorp can't parse. *)
let blorp_escape_char c =
  match c with
  | '\n' -> "\\n"
  | '\t' -> "\\t"
  | '\r' -> "\\r"
  | '\\' -> "\\\\"
  | '"' -> "\\\""
  | '\'' -> "\\'"
  | '\000' -> "\\0"
  | c when Char.code c >= 32 && Char.code c < 127 -> String.make 1 c
  | c -> Printf.sprintf "\\u{%X}" (Char.code c)

(** Escape a string using blorp-compatible escape sequences.
    UTF-8 bytes (>= 0x80) are passed through as-is to preserve round-trip
    fidelity. The lexer's \u{XX} syntax means Unicode codepoints, not bytes,
    so escaping individual UTF-8 bytes would corrupt multi-byte characters. *)
let blorp_escape_string s =
  let buf = Buffer.create (String.length s + 4) in
  String.iter
    (fun c ->
      Buffer.add_string buf
        (match c with
        | '"' -> "\\\""
        | '\\' -> "\\\\"
        | '\n' -> "\\n"
        | '\t' -> "\\t"
        | '\r' -> "\\r"
        | '\000' -> "\\0"
        | c when Char.code c >= 32 && Char.code c < 127 -> String.make 1 c
        | c when Char.code c >= 128 -> String.make 1 c
        | c -> Printf.sprintf "\\u{%X}" (Char.code c)))
    s;
  Buffer.contents buf

(** Render a list of type parameter names as [A, B, ...] or Nil if empty. *)
let print_type_params = function
  | [] -> Nil
  | tps ->
      text "["
      ^^ comma_sep
           (List.map (fun tp -> text (type_param_to_parser_string tp)) tps)
      ^^ text "]"

(** Comment store for re-inserting comments *)
let comments : Fmt_comment.t ref = ref (Fmt_comment.create [])

type block_item = BlockComment of Lexer.collected_comment | BlockExpr of expr
type ufcs_step = { step_name : string; step_args : expr list; step_line : int }

let loc_end_line loc = max loc.line loc.end_line

let rec expr_source_end_line e =
  let base = loc_end_line e.expr_loc in
  let max_exprs acc exprs =
    List.fold_left (fun acc e -> max acc (expr_source_end_line e)) acc exprs
  in
  let max_fields acc fields =
    List.fold_left
      (fun acc (_, e) -> max acc (expr_source_end_line e))
      acc fields
  in
  let max_optional_expr acc = function
    | None -> acc
    | Some e -> max acc (expr_source_end_line e)
  in
  match e.expr_desc with
  | EIdent _ | ELiteral _ | EVoid | EBreak | EContinue | EBuiltin _ -> base
  | EUnary (_, inner)
  | EAscription (inner, _)
  | EFieldAccess (inner, _)
  | EDetach inner ->
      max base (expr_source_end_line inner)
  | EBinary (_, left, right)
  | ELogical (_, left, right)
  | ERange (left, right)
  | ESubscript (left, right) ->
      max base (max (expr_source_end_line left) (expr_source_end_line right))
  | ECall (callee, args) ->
      max_exprs (max base (expr_source_end_line callee)) args
  | EIf (cond, then_expr, else_expr) ->
      max_optional_expr
        (max base
           (max (expr_source_end_line cond) (expr_source_end_line then_expr)))
        else_expr
  | EMatch (scrutinee, cases) ->
      List.fold_left
        (fun acc case ->
          max acc
            (max
               (loc_end_line case.case_loc)
               (expr_source_end_line case.case_body)))
        (max base (expr_source_end_line scrutinee))
        cases
  | EBlock exprs
  | EList exprs
  | EVector exprs
  | ETuple exprs
  | ETry exprs
  | EDebugBlock exprs ->
      max_exprs base exprs
  | ERecord fields -> max_fields base fields
  | ERecordUpdate (source, fields) ->
      max_fields (max base (expr_source_end_line source)) fields
  | ELambda fd -> max base (func_source_end_line fd)
  | EWhile (cond, body) | EFor (_, cond, body) | EForTuple (_, cond, body) ->
      max base (max (expr_source_end_line cond) (expr_source_end_line body))
  | ELoopView view ->
      max_optional_expr
        (max base (expr_source_end_line view.loop_view_source))
        view.loop_view_size_arg
  | EAssign (_, value)
  | EVarDecl (_, _, value, _)
  | ETupleDestruct (_, value)
  | ETryBind (_, _, value) ->
      max base (expr_source_end_line value)
  | ESubscriptMulti (target, indices) ->
      max_exprs (max base (expr_source_end_line target)) indices
  | ESubscriptAssign (target, indices, value) ->
      max_exprs
        (max base
           (max (expr_source_end_line target) (expr_source_end_line value)))
        indices
  | EStringInterp (parts, _) ->
      List.fold_left
        (fun acc -> function
          | InterpLit _ -> acc
          | InterpExpr e -> max acc (expr_source_end_line e))
        base parts
  | EStringInterpRaw _ -> base
  | EConcurrent (bindings, timeout, _) ->
      max_optional_expr (max_exprs base bindings) timeout
  | EConcurrentBind (_, _, value) -> max base (expr_source_end_line value)
  | EConcurrentFor (_, iterable, body, timeout, _) ->
      max_optional_expr
        (max base
           (max (expr_source_end_line iterable) (expr_source_end_line body)))
        timeout
  | EDict entries ->
      List.fold_left
        (fun acc (key, value) ->
          max acc (max (expr_source_end_line key) (expr_source_end_line value)))
        base entries
  | EFuncDecl fd -> max base (func_source_end_line fd)

and func_source_end_line fd =
  match fd.func_body with
  | FuncBodyExpr body -> expr_source_end_line body
  | FuncBuiltinBody (_, loc) -> loc_end_line loc
  | FuncForeign _ | FuncNoBody -> 0

(** Emit leading comments for a node at the given line *)
let leading_comments line =
  let cs = Fmt_comment.take_leading !comments ~before_line:line in
  if cs = [] then Nil
  else
    let docs =
      List.map
        (fun (c : Lexer.collected_comment) ->
          text (Fmt_comment.normalize_comment c.cc_text) ^^ hardline)
        cs
    in
    concat docs

(** Emit trailing comment for a node on the given line *)
let trailing_comment line =
  match Fmt_comment.take_trailing !comments ~on_line:line with
  | Some c -> line_suffix (Fmt_comment.normalize_comment c.cc_text)
  | None -> Nil

(** Emit remaining comments at end of file *)
let remaining_comments () =
  let cs = Fmt_comment.take_remaining !comments in
  if cs = [] then Nil
  else
    let docs =
      List.map
        (fun (c : Lexer.collected_comment) ->
          text (Fmt_comment.normalize_comment c.cc_text) ^^ hardline)
        cs
    in
    hardline ^^ concat docs

(* ─── Type Expressions ──────────────────────────────────────────────── *)

let rec print_type_expr = function
  | TyNamed (name, []) -> text name
  | TyNamed (name, args) ->
      text name ^^ text "["
      ^^ comma_sep (List.map print_type_expr args)
      ^^ text "]"
  | TyArray (elem, dims) ->
      print_array_elem_type elem ^^ text "["
      ^^ comma_sep (List.map print_type_expr dims)
      ^^ text "]"
  | TyFunc { params; return; is_pure } ->
      let pure = if is_pure then text "pure " else Nil in
      pure ^^ text "("
      ^^ comma_sep (List.map print_type_expr params)
      ^^ text ") -> " ^^ print_type_expr return
  | TyVar name -> text name
  | TyBoundVar param -> text (type_param_to_parser_string param)
  | TyConstInt n -> text (Printf.sprintf "#%d" n)
  | TyTuple elems ->
      text "(" ^^ comma_sep (List.map print_type_expr elems) ^^ text ")"
  | TySelf -> text "Self"
  | TyVarDims name -> text (name ^ "...")
  | TyRange ty -> text ".." ^^ print_type_expr ty
  | TyDimOp (DimAdd, a, b) ->
      print_type_expr a ^^ text " + " ^^ print_type_expr b
  | TyDimOp (DimSub, a, b) ->
      print_type_expr a ^^ text " - " ^^ print_type_expr b
  | TyDimOp (DimMul, a, b) -> print_dim_mul a ^^ text " * " ^^ print_dim_mul b
  | TyDimOp (DimDiv, a, b) -> print_dim_mul a ^^ text " / " ^^ print_dim_mul b
  | TyMeta n -> text (Printf.sprintf "?m%d" n)

and print_array_elem_type = function
  | TyFunc _ as ty -> text "(" ^^ print_type_expr ty ^^ text ")"
  | ty -> print_type_expr ty

(** Print a dim operand for multiplication/division context.
    Wraps additive expressions in parentheses to preserve precedence. *)
and print_dim_mul = function
  | (TyDimOp (DimAdd, _, _) | TyDimOp (DimSub, _, _)) as ty ->
      text "(" ^^ print_type_expr ty ^^ text ")"
  | ty -> print_type_expr ty

(* ─── Literals ──────────────────────────────────────────────────────── *)

let print_literal = function
  | LitInt n -> text (Int64.to_string n)
  | LitInt128 n -> text n
  | LitFloat f ->
      (* Blorp lexer requires decimal notation (no scientific notation) *)
      (* Try shortest fixed-point representation that round-trips *)
      let rec try_precision n =
        if n > 20 then Printf.sprintf "%.20f" f
        else
          let s = Printf.sprintf "%.*f" n f in
          if float_of_string s = f then s else try_precision (n + 1)
      in
      let s = try_precision 1 in
      text s
  | LitString (s, flags) ->
      if flags.sf_raw then text (Printf.sprintf "r\"%s\"" s)
      else if flags.sf_triple then begin
        (* Triple-quoted string: preserve original quoting style *)
        let buf = Buffer.create (String.length s + 8) in
        Buffer.add_string buf "\"\"\"";
        String.iter
          (fun c ->
            match c with
            | '\\' -> Buffer.add_string buf "\\\\"
            | '\t' -> Buffer.add_string buf "\\t"
            | '\r' -> Buffer.add_string buf "\\r"
            | '\000' -> Buffer.add_string buf "\\0"
            | c -> Buffer.add_char buf c)
          s;
        Buffer.add_string buf "\"\"\"";
        text (Buffer.contents buf)
      end
      else text (Printf.sprintf "\"%s\"" (blorp_escape_string s))
  | LitBool true -> text "True"
  | LitBool false -> text "False"
  | LitChar c ->
      if c < 128 then
        text (Printf.sprintf "'%s'" (blorp_escape_char (Char.chr c)))
      else text (Printf.sprintf "'\\u{%X}'" c)

(* ─── Operators ─────────────────────────────────────────────────────── *)

let binop_str = function
  | Add -> "+"
  | Sub -> "-"
  | Mul -> "*"
  | Div -> "/"
  | Mod -> "%"
  | Lt -> "<"
  | Gt -> ">"
  | Le -> "<="
  | Ge -> ">="
  | Eq -> "=="
  | Ne -> "!="

let unop_str = function Neg -> "-" | Not -> "not "
let logop_str = function And -> "and" | Or -> "or"

(* ─── Operator Precedence ──────────────────────────────────────────── *)

let binop_prec = function
  | Mul | Div | Mod -> 7
  | Add | Sub -> 6
  (* The parser's [cmp_expr] gives all comparisons the same left-associative
     precedence. The printer must match that or it can drop grouping that
     changes how mixed equality/ordering chains parse on the next pass. *)
  | Lt | Gt | Le | Ge | Eq | Ne -> 4

let logop_prec = function And -> 2 | Or -> 1

let expr_prec e =
  match e.expr_desc with
  | EAscription _ -> 0
  | EBinary (op, _, _) -> binop_prec op
  | ELogical (op, _, _) -> logop_prec op
  | _ -> 100

(* ─── Patterns ──────────────────────────────────────────────────────── *)

let rec print_pattern = function
  | PatWildcard -> text "_"
  | PatVar s -> text s
  | PatConstructor (name, []) -> text name ^^ text "()"
  | PatConstructor (name, pats) ->
      text name ^^ text "("
      ^^ comma_sep (List.map print_pattern pats)
      ^^ text ")"
  | PatLiteral lit -> print_literal lit
  | PatTuple pats ->
      text "(" ^^ comma_sep (List.map print_pattern pats) ^^ text ")"
  | PatQualified (modul, ctor, []) -> text modul ^^ text "." ^^ text ctor
  | PatQualified (modul, ctor, pats) ->
      text modul ^^ text "." ^^ text ctor ^^ text "("
      ^^ comma_sep (List.map print_pattern pats)
      ^^ text ")"
  | PatList (elems, spread) ->
      let elem_docs = List.map print_pattern elems in
      let spread_doc =
        match spread with
        | Some p -> [ text "..." ^^ print_pattern p ]
        | None -> []
      in
      text "[" ^^ comma_sep (elem_docs @ spread_doc) ^^ text "]"
  | PatOr pats -> intersperse (text " | ") (List.map print_pattern pats)

(* ─── Parameters ────────────────────────────────────────────────────── *)

let print_param p =
  match p.param_pattern with
  | Some pat -> (
      let base = print_pattern pat in
      match p.param_type with
      | Some ty -> base ^^ text ": " ^^ print_type_expr ty
      | None -> base)
  | None -> (
      let name = match p.param_name with Some n -> n | None -> "_" in
      match p.param_type with
      | Some ty -> text name ^^ text ": " ^^ print_type_expr ty
      | None -> text name)

let rec flat_doc_length = function
  | Nil | Softline | Hardline -> 0
  | Text s -> String.length s
  | SoftlineSpace -> 1
  | Indent (_, doc) | Group doc -> flat_doc_length doc
  | Concat (left, right) -> flat_doc_length left + flat_doc_length right
  | IfBreak (_, flat_doc) -> flat_doc_length flat_doc
  | LineSuffix s -> 1 + String.length s

let flat_param_length p = flat_doc_length (print_param p)

let rec type_expr_contains_func = function
  | TyFunc _ -> true
  | TyNamed (_, args) | TyTuple args -> List.exists type_expr_contains_func args
  | TyArray (elem, dims) ->
      type_expr_contains_func elem || List.exists type_expr_contains_func dims
  | TyRange ty -> type_expr_contains_func ty
  | TyDimOp (_, a, b) -> type_expr_contains_func a || type_expr_contains_func b
  | TyVar _ | TyBoundVar _ | TyConstInt _ | TySelf | TyVarDims _ | TyMeta _ ->
      false

let param_contains_function_type p =
  match p.param_type with
  | Some ty -> type_expr_contains_func ty
  | None -> false

let should_force_multiline_params params =
  List.length params > 3
  && List.exists (fun p -> flat_param_length p > 12) params
  || (List.length params > 1 && List.exists param_contains_function_type params)

let print_multiline_params params =
  match params with
  | [] -> text "()"
  | _ ->
      text "("
      ^^ indent
           (hardline
           ^^ hardlines
                (List.map (fun param -> print_param param ^^ text ",") params))
      ^^ hardline ^^ text ")"

let print_grouped_params params =
  group
    (text "("
    ^^ indent (softline ^^ comma_sep_break (List.map print_param params))
    ^^ softline ^^ text ")")

let print_params ?(force_multiline = false) params =
  if force_multiline || should_force_multiline_params params then
    print_multiline_params params
  else print_grouped_params params

let should_force_signature_params ~head ~params ~ret ~where_clause =
  params <> []
  && flat_doc_length (head ^^ print_grouped_params params ^^ ret ^^ where_clause)
     > line_width

(* ─── Expressions ───────────────────────────────────────────────────── *)

(** Check if an expression contains block-producing constructs that force multiline *)
let rec expr_has_block e =
  match e.expr_desc with
  | EBlock _ | EMatch _ | EDebugBlock _ -> true
  | ELambda fd -> (
      match func_body_expr_opt fd.func_body with
      | Some { expr_desc = EBlock _; _ } -> true
      | _ -> false)
  | EIf (_, then_e, Some else_e) ->
      expr_has_block then_e || expr_has_block else_e
  | ECall (_, args) -> List.exists expr_has_block args
  | EAscription (inner, _) -> expr_has_block inner
  | ETuple elems -> List.exists expr_has_block elems
  | EList elems | EVector elems -> List.exists expr_has_block elems
  | ERecord fields -> List.exists (fun (_, e) -> expr_has_block e) fields
  | _ -> false

let rec ufcs_chain_step_count func_e =
  match func_e.expr_desc with
  | EFieldAccess (receiver, _) -> 1 + ufcs_receiver_step_count receiver
  | _ -> 0

and ufcs_receiver_step_count receiver =
  match receiver.expr_desc with
  | ECall ({ expr_desc = EFieldAccess (inner, _); _ }, _) ->
      1 + ufcs_receiver_step_count inner
  | _ -> 0

(** True when the printer will introduce hard line breaks for this expression
    even though it is not necessarily a block expression in the AST. *)
let rec expr_has_multiline_layout e =
  expr_has_block e
  ||
  match e.expr_desc with
  | ECall (func_e, args) ->
      ufcs_chain_step_count func_e >= 2
      || expr_has_multiline_layout func_e
      || List.exists expr_has_multiline_layout args
  | EFieldAccess (inner, _) | EAscription (inner, _) | EDetach inner ->
      expr_has_multiline_layout inner
  | EUnary (_, inner) -> expr_has_multiline_layout inner
  | EBinary (_, left, right)
  | ELogical (_, left, right)
  | ERange (left, right)
  | ESubscript (left, right) ->
      expr_has_multiline_layout left || expr_has_multiline_layout right
  | EIf (cond, then_e, else_opt) -> (
      expr_has_multiline_layout cond
      || expr_has_multiline_layout then_e
      ||
      match else_opt with
      | Some else_e -> expr_has_multiline_layout else_e
      | None -> false)
  | ETuple elems
  | EList elems
  | EVector elems
  | ETry elems
  | EDebugBlock elems
  | EBlock elems ->
      List.exists expr_has_multiline_layout elems
  | EMatch (scrutinee, cases) ->
      expr_has_multiline_layout scrutinee
      || List.exists
           (fun case -> expr_has_multiline_layout case.case_body)
           cases
  | ERecord fields ->
      List.exists (fun (_, e) -> expr_has_multiline_layout e) fields
  | ERecordUpdate (base, fields) ->
      expr_has_multiline_layout base
      || List.exists (fun (_, e) -> expr_has_multiline_layout e) fields
  | ESubscriptMulti (target, indices) ->
      expr_has_multiline_layout target
      || List.exists expr_has_multiline_layout indices
  | ESubscriptAssign (target, indices, value) ->
      expr_has_multiline_layout target
      || expr_has_multiline_layout value
      || List.exists expr_has_multiline_layout indices
  | EStringInterp (parts, _) ->
      List.exists
        (function
          | InterpExpr e -> expr_has_multiline_layout e | InterpLit _ -> false)
        parts
  | EConcurrent (bindings, timeout, _) -> (
      List.exists expr_has_multiline_layout bindings
      ||
      match timeout with
      | Some timeout -> expr_has_multiline_layout timeout
      | None -> false)
  | EConcurrentBind (_, _, value) -> expr_has_multiline_layout value
  | EConcurrentFor (_, iterable, body, timeout, _) -> (
      expr_has_multiline_layout iterable
      || expr_has_multiline_layout body
      ||
      match timeout with
      | Some timeout -> expr_has_multiline_layout timeout
      | None -> false)
  | EDict entries ->
      List.exists
        (fun (key, value) ->
          expr_has_multiline_layout key || expr_has_multiline_layout value)
        entries
  | ELambda fd -> func_body_has_multiline_layout fd.func_body
  | EWhile (cond, body) | EFor (_, cond, body) | EForTuple (_, cond, body) ->
      expr_has_multiline_layout cond || expr_has_multiline_layout body
  | ELoopView view -> (
      expr_has_multiline_layout view.loop_view_source
      ||
      match view.loop_view_size_arg with
      | Some size_arg -> expr_has_multiline_layout size_arg
      | None -> false)
  | EAssign (_, value)
  | EVarDecl (_, _, value, _)
  | ETupleDestruct (_, value)
  | ETryBind (_, _, value) ->
      expr_has_multiline_layout value
  | EFuncDecl fd -> func_body_has_multiline_layout fd.func_body
  | EIdent _ | ELiteral _ | EVoid | EBreak | EContinue | EBuiltin _
  | EStringInterpRaw _ ->
      false

and func_body_has_multiline_layout = function
  | FuncBodyExpr body -> expr_has_multiline_layout body
  | FuncBuiltinBody _ | FuncForeign _ | FuncNoBody -> false

(** Check if an expression is a lambda (any kind). *)
let is_lambda e = match e.expr_desc with ELambda _ -> true | _ -> false

let func_body_has_block = function
  | FuncBodyExpr { expr_desc = EBlock _; _ } -> true
  | FuncBodyExpr _ | FuncBuiltinBody _ | FuncForeign _ | FuncNoBody -> false

let print_builtin_body = function
  | BuiltinIntrinsic -> text "builtin"
  | BuiltinRuntime cname -> text (Printf.sprintf "builtin(\"%s\")" cname)

(** When true, suppress group-based line breaking in calls/lists/vectors.
    Set when printing lambda arguments, because the parser can't handle
    multiline expressions inside lambda bodies that are function arguments. *)
let force_flat = ref false

let with_force_flat value f =
  let prev = !force_flat in
  force_flat := value;
  Fun.protect ~finally:(fun () -> force_flat := prev) f

let multiline_comma_items items =
  let rec go = function
    | [] -> Nil
    | [ (doc, _) ] -> doc
    | (doc, comma_on_own_line) :: rest ->
        let comma =
          if comma_on_own_line then hardline ^^ text "," else text ","
        in
        doc ^^ comma ^^ hardline ^^ go rest
  in
  go items

let rec print_expr e =
  let doc = print_expr_node e in
  let trail = trailing_comment e.expr_loc.line in
  doc ^^ trail

and print_bracketed open_b close_b elems =
  let has_multiline = List.exists expr_has_multiline_layout elems in
  if has_multiline then
    let item_docs =
      List.map (fun e -> (print_expr e, expr_has_block e)) elems
    in
    text open_b
    ^^ indent (hardline ^^ multiline_comma_items item_docs)
    ^^ hardline ^^ text close_b
  else if !force_flat then
    text open_b ^^ comma_sep (List.map print_expr elems) ^^ text close_b
  else
    group
      (text open_b
      ^^ indent (softline ^^ comma_sep_break (List.map print_expr elems))
      ^^ softline ^^ text close_b)

and print_dict_entry (key, value) =
  print_expr key ^^ text " => " ^^ print_expr value

and print_multiline_dict entries =
  let entry_docs =
    List.map (fun entry -> (print_dict_entry entry, false)) entries
  in
  text "{"
  ^^ indent (hardline ^^ multiline_comma_items entry_docs)
  ^^ hardline ^^ text "}"

and print_single_entry_dict_arg entry =
  let flat = text "{" ^^ print_dict_entry entry ^^ text "}" in
  group (IfBreak (print_multiline_dict [ entry ], flat))

and print_adjacent_single_collection_arg args =
  match args with
  | [ ({ expr_desc = EList _; _ } as arg) ] when not !force_flat ->
      Some (text "(" ^^ print_expr arg ^^ text ")")
  | [ { expr_desc = EDict [ entry ]; _ } ] when not !force_flat ->
      Some (text "(" ^^ print_single_entry_dict_arg entry ^^ text ")")
  | [ { expr_desc = EDict entries; _ } ] when (not !force_flat) && entries <> []
    ->
      Some (text "(" ^^ print_multiline_dict entries ^^ text ")")
  | _ -> None

and vector_rank_expr e =
  match e.expr_desc with EVector elems -> vector_rank_elems elems | _ -> 0

and vector_rank_elems elems =
  match elems with
  | [] -> 1
  | first :: rest ->
      let child_rank = vector_rank_expr first in
      if
        child_rank > 0
        && List.for_all (fun e -> vector_rank_expr e = child_rank) rest
      then child_rank + 1
      else 1

and print_vector_row elems =
  if !force_flat then
    text "{" ^^ comma_sep (List.map print_expr elems) ^^ text "}"
  else
    group
      (text "{"
      ^^ indent (softline ^^ comma_sep_break (List.map print_expr elems))
      ^^ softline ^^ text "}")

and print_shaped_vector_item e =
  match e.expr_desc with
  | EVector elems ->
      if vector_rank_elems elems >= 2 then print_shaped_vector elems
      else print_vector_row elems
  | _ -> print_expr e

and print_shaped_vector elems =
  let item_docs =
    elems
    |> List.map print_shaped_vector_item
    |> List.map (fun doc -> doc ^^ text ",")
  in
  text "{" ^^ indent (hardline ^^ hardlines item_docs) ^^ hardline ^^ text "}"

and print_vector_literal elems =
  if
    (not !force_flat)
    && vector_rank_elems elems >= 2
    && not (List.exists expr_has_block elems)
  then print_shaped_vector elems
  else print_bracketed "{" "}" elems

and print_chain_call_args args =
  match args with
  | [] -> text "()"
  | _ -> (
      match print_adjacent_single_collection_arg args with
      | Some doc -> doc
      | None ->
          let has_block_lambda =
            List.exists
              (fun a ->
                match a.expr_desc with
                | ELambda fd -> func_body_has_block fd.func_body
                | _ -> false)
              args
          in
          if List.exists expr_has_multiline_layout args then
            let render () =
              let arg_docs =
                List.map (fun arg -> (print_expr arg, expr_has_block arg)) args
              in
              text "("
              ^^ indent (hardline ^^ multiline_comma_items arg_docs)
              ^^ hardline ^^ text ")"
            in
            if has_block_lambda then with_force_flat true render else render ()
          else
            group
              (text "("
              ^^ indent (softline ^^ comma_sep_break (List.map print_expr args))
              ^^ softline ^^ text ")"))

and expr_is_non_lambda_block e =
  match e.expr_desc with ELambda _ -> false | _ -> expr_has_block e

and print_block_call_args func_e args =
  match print_adjacent_single_collection_arg args with
  | Some args_doc -> print_expr func_e ^^ args_doc
  | None ->
      let arg_docs =
        List.map (fun arg -> (print_expr arg, expr_has_block arg)) args
      in
      print_expr func_e ^^ text "("
      ^^ indent (hardline ^^ multiline_comma_items arg_docs)
      ^^ hardline ^^ text ")"

and print_ufcs_chain call_expr func_e args =
  let rec collect receiver steps =
    match receiver.expr_desc with
    | ECall ({ expr_desc = EFieldAccess (inner, method_name); _ }, method_args)
      ->
        collect inner
          ({
             step_name = method_name;
             step_args = method_args;
             step_line = loc_end_line receiver.expr_loc;
           }
          :: steps)
    | _ -> (receiver, steps)
  in
  match func_e.expr_desc with
  | EFieldAccess (receiver, method_name) ->
      let receiver, steps =
        collect receiver
          [
            {
              step_name = method_name;
              step_args = args;
              step_line = loc_end_line call_expr.expr_loc;
            };
          ]
      in
      if List.length steps >= 2 && not !force_flat then
        let print_step step =
          let leading =
            Fmt_comment.take_leading !comments ~before_line:step.step_line
          in
          let leading_doc =
            concat
              (List.map
                 (fun (c : Lexer.collected_comment) ->
                   hardline ^^ text (Fmt_comment.normalize_comment c.cc_text))
                 leading)
          in
          leading_doc ^^ hardline ^^ text "." ^^ text step.step_name
          ^^ print_chain_call_args step.step_args
          ^^ trailing_comment step.step_line
        in
        let receiver_doc = print_expr receiver in
        let steps_doc = concat (List.map print_step steps) in
        Some (receiver_doc ^^ indent steps_doc)
      else None
  | _ -> None

and print_expr_node expr =
  match expr.expr_desc with
  | EIdent s -> text s
  | ELiteral lit -> print_literal lit
  | ELoopView view ->
      let name, args =
        match view.loop_view_kind with
        | LoopIndices -> ("indices", [ view.loop_view_source ])
        | LoopEnumerate -> ("enumerate", [ view.loop_view_source ])
        | LoopEnumerate2 -> ("enumerate2", [ view.loop_view_source ])
        | LoopWindows _ ->
            ( "windows",
              view.loop_view_source
              ::
              (match view.loop_view_size_arg with
              | Some size_arg -> [ size_arg ]
              | None -> []) )
      in
      text name ^^ print_chain_call_args args
  | EBinary (op, lhs, rhs) ->
      let prec = binop_prec op in
      let lhs_doc =
        if expr_prec lhs < prec then parens (print_expr lhs) else print_expr lhs
      in
      let rhs_doc =
        if expr_prec rhs <= prec then parens (print_expr rhs)
        else print_expr rhs
      in
      lhs_doc ^^ text " " ^^ text (binop_str op) ^^ text " " ^^ rhs_doc
  | EUnary (Neg, ({ expr_desc = EUnary (Neg, _); _ } as e)) ->
      (* -(-x) not --x, because -- starts a comment *)
      text "-" ^^ parens (print_expr e)
  | EUnary (Neg, ({ expr_desc = ELiteral (LitInt n); _ } as e)) when n < 0L ->
      (* -(negative_lit) needs parens to avoid --N being parsed as comment *)
      text "-" ^^ parens (print_expr e)
  | EUnary (Neg, ({ expr_desc = ELiteral (LitFloat f); _ } as e)) when f < 0.0
    ->
      text "-" ^^ parens (print_expr e)
  | EUnary (op, e) ->
      let child_doc =
        match e.expr_desc with
        | EBinary _ | ELogical _ -> parens (print_expr e)
        | _ -> print_expr e
      in
      text (unop_str op) ^^ child_doc
  | ELogical (op, lhs, rhs) ->
      (* In indent-sensitive Blorp, break before operator when the LHS ends
         with a block expression (match/if). This handles chained
         "match ... and match ... and match ..." patterns where the last
         thing printed from the LHS is a multiline match/if body. *)
      let rec ends_with_block e =
        match e.expr_desc with
        | EMatch _ | EIf _ -> true
        | ELogical (_, _, rhs_inner) -> ends_with_block rhs_inner
        | _ -> false
      in
      let prec = logop_prec op in
      let lhs_doc =
        if expr_prec lhs < prec then parens (print_expr lhs) else print_expr lhs
      in
      let rhs_doc =
        if expr_prec rhs <= prec then parens (print_expr rhs)
        else print_expr rhs
      in
      if ends_with_block lhs then
        lhs_doc ^^ hardline ^^ text (logop_str op) ^^ text " " ^^ rhs_doc
      else lhs_doc ^^ text " " ^^ text (logop_str op) ^^ text " " ^^ rhs_doc
  | EAscription (inner, ty) ->
      let inner_doc =
        match inner.expr_desc with
        | EAscription _ | EBlock _ | EMatch _ | EIf _ | ETry _ | EDebugBlock _
        | EConcurrent _ | EConcurrentFor _ | EFor _ | EForTuple _ | EWhile _ ->
            parens (print_expr inner)
        | _ -> print_expr inner
      in
      inner_doc ^^ text " as " ^^ print_type_expr ty
  | ECall (func_e, []) -> (
      match print_ufcs_chain expr func_e [] with
      | Some doc -> doc
      | None -> print_expr func_e ^^ text "()")
  | ECall (func_e, args) -> (
      match print_ufcs_chain expr func_e args with
      | Some doc -> doc
      | None -> (
          match print_adjacent_single_collection_arg args with
          | Some adjacent_args -> print_expr func_e ^^ adjacent_args
          | None ->
              let has_block_lambda =
                List.exists
                  (fun a ->
                    match a.expr_desc with
                    | ELambda fd -> func_body_has_block fd.func_body
                    | _ -> false)
                  args
              in
              if List.exists expr_has_multiline_layout args then
                if has_block_lambda then
                  with_force_flat true (fun () ->
                      print_block_call_args func_e args)
                else print_block_call_args func_e args
              else if List.exists is_lambda args then
                (* Inline lambdas: use normal group-based breaking. Apply print_arg
               for nested-call IfBreak expansion. *)
                let rec print_arg a =
                  match a.expr_desc with
                  | ECall
                      ({ expr_desc = EFieldAccess _ | EIdent _; _ }, inner_args)
                    when List.length inner_args >= 2 && not !force_flat ->
                      let flat_doc = print_expr a in
                      let inner_args_doc = List.map print_arg inner_args in
                      let callee_doc =
                        print_expr
                          (match a.expr_desc with ECall (f, _) -> f | _ -> a)
                      in
                      let broken_doc =
                        callee_doc ^^ text "("
                        ^^ indent (hardline ^^ comma_sep_break inner_args_doc)
                        ^^ hardline ^^ text ")"
                      in
                      IfBreak (broken_doc, flat_doc)
                  | _ -> print_expr a
                in
                group
                  (print_expr func_e ^^ text "("
                  ^^ indent
                       (softline ^^ comma_sep_break (List.map print_arg args))
                  ^^ softline ^^ text ")")
              else if !force_flat then
                print_expr func_e ^^ text "("
                ^^ comma_sep (List.map print_expr args)
                ^^ text ")"
              else if List.exists expr_is_non_lambda_block args then
                print_block_call_args func_e args
              else
                (* For arguments that are multi-arg calls, provide two layouts via
           IfBreak: expanded (when parent breaks) and flat (when parent fits).
           This gives tree-like expansion at every nesting depth. *)
                let rec print_arg a =
                  match a.expr_desc with
                  | ECall
                      ({ expr_desc = EFieldAccess _ | EIdent _; _ }, inner_args)
                    when List.length inner_args >= 2 ->
                      let flat_doc = print_expr a in
                      (* Recursively apply print_arg to inner args for cascading breaks *)
                      let inner_args_doc = List.map print_arg inner_args in
                      let callee_doc =
                        print_expr
                          (match a.expr_desc with ECall (f, _) -> f | _ -> a)
                      in
                      let broken_doc =
                        callee_doc ^^ text "("
                        ^^ indent (hardline ^^ comma_sep_break inner_args_doc)
                        ^^ hardline ^^ text ")"
                      in
                      IfBreak (broken_doc, flat_doc)
                  | _ -> print_expr a
                in
                let args_doc = List.map print_arg args in
                print_expr func_e
                ^^ group
                     (text "("
                     ^^ indent (softline ^^ comma_sep_break args_doc)
                     ^^ softline ^^ text ")")))
  | EIf (cond, then_e, else_opt) -> (
      let if_doc =
        text "if " ^^ print_expr cond ^^ text ":"
        ^^ indent (hardline ^^ print_block_body then_e)
      in
      match else_opt with
      | None -> if_doc
      | Some else_e -> (
          match else_e.expr_desc with
          | EIf _ ->
              if_doc ^^ hardline ^^ text "else " ^^ print_expr_node else_e
          | _ ->
              if_doc ^^ hardline ^^ text "else" ^^ text ":"
              ^^ indent (hardline ^^ print_block_body else_e)))
  | EMatch (scrutinee, cases) ->
      text "match " ^^ print_expr scrutinee ^^ text ":"
      ^^ indent
           (hardline
           ^^ hardlines
                (List.map
                   (fun case ->
                     print_pattern case.case_pattern
                     ^^ text ":"
                     ^^
                     match case.case_body.expr_desc with
                     | EBlock _ ->
                         indent (hardline ^^ print_block_body case.case_body)
                     | _ -> text " " ^^ print_expr case.case_body)
                   cases))
  | EBlock exprs -> print_block_exprs exprs
  | ETuple elems ->
      if List.exists expr_has_multiline_layout elems then
        let item_docs =
          List.map (fun e -> (print_expr e, expr_has_block e)) elems
        in
        text "("
        ^^ indent (hardline ^^ multiline_comma_items item_docs)
        ^^ hardline ^^ text ")"
      else
        group
          (text "("
          ^^ indent (softline ^^ comma_sep_break (List.map print_expr elems))
          ^^ softline ^^ text ")")
  | EVector elems -> print_vector_literal elems
  | EList elems -> print_bracketed "[" "]" elems
  | ERecord fields ->
      let has_multiline =
        List.exists (fun (_, e) -> expr_has_multiline_layout e) fields
      in
      if has_multiline then
        let field_docs =
          List.map
            (fun (name, e) ->
              (text name ^^ text " = " ^^ print_expr e, expr_has_block e))
            fields
        in
        text "{"
        ^^ indent (hardline ^^ multiline_comma_items field_docs)
        ^^ hardline ^^ text "}"
      else
        group
          (text "{"
          ^^ indent
               (softline
               ^^ comma_sep_break
                    (List.map
                       (fun (name, e) ->
                         text name ^^ text " = " ^^ print_expr e)
                       fields))
          ^^ softline ^^ text "}")
  | ERecordUpdate (base, fields) ->
      group
        (text "{ " ^^ print_expr base ^^ text " | "
        ^^ comma_sep_break
             (List.map
                (fun (name, e) -> text name ^^ text " = " ^^ print_expr e)
                fields)
        ^^ text " }")
  | EFieldAccess (e, field) ->
      (* Block-like expressions need parentheses when used as a method receiver,
         otherwise `(try: ...).method()` becomes `try: ...\n.method()`.
         Lower-precedence expressions also need parentheses: dropping them
         changes `(a + b).to_string()` into `a + b.to_string()`. *)
      let e_doc =
        match e.expr_desc with
        | ETry _ | EDebugBlock _ | EIf _ | EMatch _ | EBlock _ | EFor _
        | EForTuple _ | EWhile _ | EConcurrent _ ->
            text "(" ^^ print_expr e ^^ hardline ^^ text ")"
        | EAscription _ | EBinary _ | ELogical _ | ERange _ | EUnary _ ->
            parens (print_expr e)
        | _ -> print_expr e
      in
      e_doc ^^ text "." ^^ text field
  | ELambda fd -> print_lambda fd
  | EVoid -> text "void"
  (* Bare form prints as "builtin" to preserve the source-level marker.
     The C-name-parametrized form binds std/runtime wrappers to a named
     runtime helper. *)
  | EBuiltin None -> text "builtin"
  | EBuiltin (Some cname) -> text (Printf.sprintf "builtin(\"%s\")" cname)
  | EWhile (cond, body) ->
      text "while " ^^ print_expr cond ^^ text ":"
      ^^ indent (hardline ^^ print_block_body body)
  | EForTuple (names, iter, body) ->
      let name_doc = text "(" ^^ comma_sep (List.map text names) ^^ text ")" in
      text "for " ^^ name_doc ^^ text " in " ^^ print_expr iter ^^ text ":"
      ^^ indent (hardline ^^ print_block_body body)
  | EFor (var, iter, body) ->
      text "for " ^^ text var ^^ text " in " ^^ print_expr iter ^^ text ":"
      ^^ indent (hardline ^^ print_block_body body)
  | EAssign (var, value) -> (
      (* Detect desugared compound assignment: x = x OP expr *)
      match value.expr_desc with
      | EBinary (op, { expr_desc = EIdent v; _ }, rhs)
        when v = var
             && match op with Add | Sub | Mul | Div -> true | _ -> false ->
          let op_str =
            match op with
            | Add -> "+="
            | Sub -> "-="
            | Mul -> "*="
            | Div -> "/="
            | _ -> "="
          in
          text var ^^ text " " ^^ text op_str ^^ text " " ^^ print_expr rhs
      | _ -> text var ^^ text " = " ^^ print_expr value)
  | EVarDecl (name, ty_opt, value, is_mut) ->
      let prefix = if is_mut then text "var " else Nil in
      let ty_ann =
        match ty_opt with
        | Some ty -> text ": " ^^ print_type_expr ty
        | None -> Nil
      in
      prefix ^^ text name ^^ ty_ann ^^ text " = " ^^ print_expr value
  | ETupleDestruct (names, value) ->
      text "("
      ^^ comma_sep (List.map text names)
      ^^ text ") = " ^^ print_expr value
  | ERange (lo, hi) -> print_expr lo ^^ text ".." ^^ print_expr hi
  | EBreak -> text "break"
  | EContinue -> text "continue"
  | ESubscript (e, idx) ->
      print_expr e ^^ text "[" ^^ print_expr idx ^^ text "]"
  | ESubscriptMulti (e, idxs) ->
      print_expr e ^^ text "["
      ^^ comma_sep (List.map print_expr idxs)
      ^^ text "]"
  | ESubscriptAssign (e, idxs, value) ->
      print_expr e ^^ text "["
      ^^ comma_sep (List.map print_expr idxs)
      ^^ text "]" ^^ text " = " ^^ print_expr value
  | EStringInterp (parts, is_triple) ->
      let quote = if is_triple then "\"\"\"" else "\"" in
      let escape_lit s =
        if is_triple then (
          (* In triple-quoted strings, newlines and double-quotes are literal *)
          let buf = Buffer.create (String.length s) in
          String.iter
            (fun c ->
              match c with
              | '\\' -> Buffer.add_string buf "\\\\"
              | '\t' -> Buffer.add_string buf "\\t"
              | '\r' -> Buffer.add_string buf "\\r"
              | '\000' -> Buffer.add_string buf "\\0"
              | c -> Buffer.add_char buf c)
            s;
          Buffer.contents buf)
        else blorp_escape_string s
      in
      text quote
      ^^ concat
           (List.map
              (fun part ->
                match part with
                | InterpLit s -> text (escape_lit s)
                | InterpExpr e -> text "${" ^^ print_expr e ^^ text "}")
              parts)
      ^^ text quote
  | EStringInterpRaw (s, is_triple) ->
      let quote = if is_triple then "\"\"\"" else "\"" in
      text (Printf.sprintf "%s%s%s" quote (blorp_escape_string s) quote)
  | ETry stmts -> text "try:" ^^ indent (hardline ^^ print_block_exprs stmts)
  | EDebugBlock stmts ->
      text "debug:" ^^ indent (hardline ^^ print_block_exprs stmts)
  | ETryBind (name, ty_opt, e) ->
      let ty_ann =
        match ty_opt with
        | Some ty -> text ": " ^^ print_type_expr ty
        | None -> Nil
      in
      text name ^^ ty_ann ^^ text " ?= " ^^ print_expr e
  | EConcurrent (bindings, timeout, max_threads) ->
      let params =
        match (timeout, max_threads) with
        | None, None -> Nil
        | Some t, None -> text "(timeout: " ^^ print_expr t ^^ text ")"
        | None, Some n -> text (Printf.sprintf "(max_threads: %d)" n)
        | Some t, Some n ->
            text (Printf.sprintf "(max_threads: %d, timeout: " n)
            ^^ print_expr t ^^ text ")"
      in
      text "concurrent" ^^ params ^^ text ":"
      ^^ indent (hardline ^^ print_block_exprs bindings)
  | EConcurrentBind (name, ty_opt, e) ->
      let ty_ann =
        match ty_opt with
        | Some ty -> text ": " ^^ print_type_expr ty
        | None -> Nil
      in
      text name ^^ ty_ann ^^ text " = " ^^ print_expr e
  | EDetach body -> text "detach " ^^ print_expr body
  | EDict pairs ->
      let pair_docs =
        List.map
          (fun (k, v) -> print_expr k ^^ text " => " ^^ print_expr v)
          pairs
      in
      text "{" ^^ comma_sep pair_docs ^^ text "}"
  | EConcurrentFor (var, iter, body, timeout, max_threads) ->
      let params =
        match (timeout, max_threads) with
        | None, None -> Nil
        | Some t, None -> text "(timeout: " ^^ print_expr t ^^ text ") "
        | None, Some n -> text (Printf.sprintf "(max_threads: %d) " n)
        | Some t, Some n ->
            text (Printf.sprintf "(max_threads: %d, timeout: " n)
            ^^ print_expr t ^^ text ") "
      in
      text "concurrent" ^^ params ^^ text " for " ^^ text var ^^ text " in "
      ^^ print_expr iter ^^ text ":"
      ^^ indent (hardline ^^ print_block_body body)
  | EFuncDecl fd ->
      (* Nested function declaration. Re-builds the signature inline
         because [print_func_decl] is a separate top-level binding; the
         nested form is a subset (no [private] / [@tailrec] / [foreign] /
         [builtin] — those are top-level-only affordances). *)
      let pure = if fd.func_is_pure then text "pure " else Nil in
      let name = match fd.func_name with Some n -> n | None -> "" in
      let type_params = print_type_params fd.func_type_params in
      let ret =
        match fd.func_return_type with
        | Some ty -> text " -> " ^^ print_type_expr ty
        | None -> Nil
      in
      let head = pure ^^ text "func " ^^ text name ^^ type_params in
      let params =
        print_params
          ~force_multiline:
            (should_force_signature_params ~head ~params:fd.func_params ~ret
               ~where_clause:Nil)
          fd.func_params
      in
      let body =
        match fd.func_body with
        | FuncBodyExpr b -> text ":" ^^ indent (hardline ^^ print_block_body b)
        | FuncBuiltinBody (builtin, _) ->
            text ":" ^^ indent (hardline ^^ print_builtin_body builtin)
        | FuncForeign _ -> text ":" ^^ indent (hardline ^^ text "void")
        | FuncNoBody -> text ":" ^^ indent (hardline ^^ text "void")
      in
      pure ^^ text "func " ^^ text name ^^ type_params ^^ params ^^ ret ^^ body

(** Print the body of a block — a sequence of expressions separated by newlines *)
and print_block_body e =
  match e.expr_desc with
  | EBlock exprs -> print_block_exprs exprs
  | _ -> print_expr e

and print_block_exprs exprs =
  let start_line = function
    | BlockComment c -> c.cc_line
    | BlockExpr e -> e.expr_loc.line
  in
  let end_line = function
    | BlockComment c -> c.cc_line
    | BlockExpr e -> expr_source_end_line e
  in
  let doc_of = function
    | BlockComment c -> text (Fmt_comment.normalize_comment c.cc_text)
    | BlockExpr e -> print_expr e
  in
  let needs_blank prev next =
    match next with
    | BlockComment c -> (
        match prev with
        | BlockComment prev_c when c.cc_line = prev_c.cc_line + 1 -> false
        | _ -> true)
    | BlockExpr _ -> start_line next - end_line prev > 1
  in
  let append_item (prev, acc) item =
    let item_doc = doc_of item in
    match (prev, acc) with
    | None, None -> (Some item, Some item_doc)
    | Some prev_item, Some rendered ->
        let sep =
          if needs_blank prev_item item then hardline ^^ hardline else hardline
        in
        (Some item, Some (rendered ^^ sep ^^ item_doc))
    | _ -> failwith "formatter block item accumulator invariant violated"
  in
  let _, rendered =
    List.fold_left
      (fun state e ->
        let lead =
          Fmt_comment.take_leading !comments ~before_line:e.expr_loc.line
        in
        let items = List.map (fun c -> BlockComment c) lead @ [ BlockExpr e ] in
        List.fold_left append_item state items)
      (None, None) exprs
  in
  match rendered with Some doc -> doc | None -> Nil

(** Print a lambda expression *)
and print_lambda fd =
  let pure = if fd.func_is_pure then text "pure " else Nil in
  let ret =
    match fd.func_return_type with
    | Some ty -> text " -> " ^^ print_type_expr ty
    | None -> Nil
  in
  let head = pure ^^ text "func" in
  let params =
    print_params
      ~force_multiline:
        (should_force_signature_params ~head ~params:fd.func_params ~ret
           ~where_clause:Nil)
      fd.func_params
  in
  match fd.func_body with
  | FuncNoBody -> pure ^^ text "func" ^^ params ^^ ret
  | FuncForeign _ -> pure ^^ text "func" ^^ params ^^ ret
  | FuncBuiltinBody (builtin, _) ->
      pure ^^ text "func" ^^ params ^^ ret ^^ text ": "
      ^^ print_builtin_body builtin
  | FuncBodyExpr body -> (
      match body.expr_desc with
      | EBlock _ ->
          pure ^^ text "func" ^^ params ^^ ret ^^ text ":"
          ^^ indent (hardline ^^ print_block_body body)
      | _ ->
          pure ^^ text "func" ^^ params ^^ ret ^^ text ": " ^^ print_expr body)

(* ─── Import Handling + Sorting ─────────────────────────────────────── *)

(** Classify an import as std (true) or project (false) *)
let is_std_import imp =
  String.length imp.import_module >= 4
  && String.sub imp.import_module 0 4 = "std/"

(** Print a single import item (inside an import: block) *)
let print_import_item imp =
  match imp.import_symbols with
  | Some syms ->
      let sorted =
        List.sort (fun a b -> String.compare a.sym_name b.sym_name) syms
      in
      let prefix =
        match imp.import_alias with
        | Some alias ->
            text imp.import_module ^^ text " as " ^^ text alias ^^ text ":"
        | None -> text imp.import_module ^^ text ":"
      in
      let print_symbol s =
        let base =
          match s.sym_alias with
          | Some alias -> text s.sym_name ^^ text " as " ^^ text alias
          | None -> text s.sym_name
        in
        match s.sym_ctors with
        | CtorNone -> base
        | CtorSome ctors ->
            group
              (text s.sym_name ^^ text "("
              ^^ indent (softline ^^ comma_sep_break (List.map text ctors))
              ^^ softline ^^ text ")")
      in
      group
        (prefix
        ^^ indent
             (softline_space ^^ comma_sep_break (List.map print_symbol sorted))
        )
  | None -> (
      match imp.import_alias with
      | Some alias -> text imp.import_module ^^ text " as " ^^ text alias
      | None -> text imp.import_module)

(** Print a single import declaration (standalone, used in DImport rendering) *)
let print_import imp =
  text "import:" ^^ indent (hardline ^^ print_import_item imp)

(** Deduplicate imports by module path *)
let dedup_imports imports =
  let seen = Hashtbl.create 16 in
  List.filter
    (fun imp ->
      let key =
        imp.import_module ^ ":"
        ^
        match imp.import_symbols with
        | Some s ->
            let sym_keys =
              List.map
                (fun sym ->
                  match sym.sym_alias with
                  | Some a -> sym.sym_name ^ " as " ^ a
                  | None -> sym.sym_name)
                s
            in
            String.concat "," (List.sort String.compare sym_keys)
        | None -> (
            match imp.import_alias with Some a -> "as:" ^ a | None -> "*")
      in
      if Hashtbl.mem seen key then false
      else (
        Hashtbl.add seen key ();
        true))
    imports

(* ─── Top-Level Declarations ────────────────────────────────────────── *)

let string_starts_with s prefix =
  let s_len = String.length s in
  let prefix_len = String.length prefix in
  s_len >= prefix_len && String.sub s 0 prefix_len = prefix

let drop_trailing_empty lines =
  let rec drop = function "" :: rest -> drop rest | lines -> lines in
  List.rev (drop (List.rev lines))

let layout_doc_lines doc =
  Fmt_layout.layout doc |> String.split_on_char '\n' |> drop_trailing_empty

let expand_tabs line = String.concat "    " (String.split_on_char '\t' line)

let parse_format_snippet source =
  try
    Lexer.reset_state ();
    let lexbuf = Lexing.from_string source in
    let program = Parser.program Lexer.next_token lexbuf in
    Some (Interp_parser.transform_program program, Lexer.get_comments ())
  with
  | Parser.Error | Lexer.LexError _ | Parse_error_at _ -> None
  | Failure _ | Invalid_argument _ -> None

let with_comment_store collected f =
  let saved = !comments in
  comments := Fmt_comment.create collected;
  match f () with
  | result ->
      comments := saved;
      result
  | exception exn ->
      comments := saved;
      raise exn

let format_doctest_code_lines code_lines =
  let body_line line =
    if String.trim line = "" then "\n" else "\t" ^ line ^ "\n"
  in
  let source =
    "func __doctest__():\n" ^ String.concat "" (List.map body_line code_lines)
  in
  match parse_format_snippet source with
  | Some
      ( [ { decl_desc = DFunc { func_body = FuncBodyExpr body; _ }; _ } ],
        collected ) ->
      Some
        (with_comment_store collected (fun () ->
             List.map expand_tabs (layout_doc_lines (print_block_body body))))
  | _ -> None

let format_doctest_group_code code_lines =
  let rec drop_blank = function
    | line :: rest when String.trim line = "" -> drop_blank rest
    | lines -> lines
  in
  let strip_blank_edges lines =
    List.rev (drop_blank (List.rev (drop_blank lines)))
  in
  let separate_imports lines =
    match lines with
    | first :: rest when String.trim first = "import:" ->
        let rec consume acc = function
          | line :: remaining
            when string_starts_with line "    " && String.trim line <> "" ->
              consume (("    " ^ String.trim line) :: acc) remaining
          | remaining -> (List.rev acc, remaining)
        in
        let imports, remaining = consume [] rest in
        (first :: imports, remaining)
    | _ -> ([], lines)
  in
  let cleaned = strip_blank_edges code_lines in
  let imports, body = separate_imports cleaned in
  let body = strip_blank_edges body in
  match format_doctest_code_lines body with
  | Some formatted_body ->
      if imports = [] then formatted_body
      else if formatted_body = [] then imports
      else imports @ [ "" ] @ formatted_body
  | None -> cleaned

let format_docstring_doctests lines =
  let strip_doctest_indent line =
    let len = String.length line in
    if len >= 4 && String.sub line 0 4 = "    " then String.sub line 4 (len - 4)
    else if len >= 1 && line.[0] = '\t' then String.sub line 1 (len - 1)
    else line
  in
  let is_delimiter line =
    let trimmed = String.trim line in
    string_starts_with trimmed "::"
  in
  let delimiter_desc line =
    let trimmed = String.trim line in
    String.trim (String.sub trimmed 2 (String.length trimmed - 2))
  in
  let rec split_prefix acc = function
    | [] -> None
    | line :: rest when String.trim line = "doctests:" ->
        Some (List.rev acc, rest)
    | line :: rest -> split_prefix (line :: acc) rest
  in
  let rec split_groups current_desc current_code groups = function
    | [] ->
        let groups =
          match current_desc with
          | Some desc -> (desc, List.rev current_code) :: groups
          | None -> groups
        in
        Some (List.rev groups)
    | line :: rest -> (
        if is_delimiter line then
          let groups =
            match current_desc with
            | Some desc -> (desc, List.rev current_code) :: groups
            | None -> groups
          in
          split_groups (Some (delimiter_desc line)) [] groups rest
        else
          match current_desc with
          | Some _ ->
              split_groups current_desc (line :: current_code) groups rest
          | None when String.trim line = "" -> split_groups None [] groups rest
          | None -> None)
  in
  let render_group (desc, code) =
    ("    :: " ^ desc)
    :: List.map
         (fun line -> if line = "" then "" else "    " ^ line)
         (format_doctest_group_code code)
  in
  match split_prefix [] lines with
  | None -> lines
  | Some (prefix, rest) -> (
      let stripped = List.map strip_doctest_indent rest in
      match split_groups None [] [] stripped with
      | None -> lines
      | Some [] -> lines
      | Some groups ->
          let rendered_groups =
            List.concat
              (List.mapi
                 (fun i group ->
                   let rendered = render_group group in
                   if i = 0 then rendered else "" :: rendered)
                 groups)
          in
          prefix @ [ "doctests:" ] @ rendered_groups)

(** Print a docstring *)
let print_docstring doc =
  let lines = String.split_on_char '\n' doc |> format_docstring_doctests in
  text "---" ^^ hardline
  ^^ concat (List.map (fun line -> text line ^^ hardline) lines)
  ^^ text "---" ^^ hardline

(** Print a function declaration (top-level or method).

    When [is_private] is set, annotations stay on the same line as the
    [private] modifier and signature ([private @tailrec pure func ...])
    — the parser rejects splitting [private] off from its signature
    with a newline, so the formatter must not emit that form. *)
let print_func_decl ?(is_private = false) fd =
  let tailrec_sep = if is_private then text " " else hardline in
  let tailrec =
    if fd.func_is_tailrec then text "@tailrec" ^^ tailrec_sep else Nil
  in
  let debug_only =
    if fd.func_debug_only then text "@debug_only" ^^ tailrec_sep else Nil
  in
  let no_copy =
    if fd.func_no_copy && func_is_foreign fd then text "@no_copy" ^^ tailrec_sep
    else Nil
  in
  let export = if is_private then text "private " else Nil in
  let pure = if fd.func_is_pure then text "pure " else Nil in
  let foreign = if func_is_foreign fd then text "foreign " else Nil in
  let name = match fd.func_name with Some n -> n | None -> "" in
  let type_params = print_type_params fd.func_type_params in
  let ret =
    match fd.func_return_type with
    | Some ty -> text " -> " ^^ print_type_expr ty
    | None -> Nil
  in
  let where_clause =
    match fd.func_dim_constraints with
    | [] -> Nil
    | constraints ->
        let print_constraint (lhs, rhs) =
          print_type_expr lhs ^^ text " == " ^^ print_type_expr rhs
        in
        text " where " ^^ comma_sep (List.map print_constraint constraints)
  in
  let head =
    export ^^ debug_only ^^ tailrec ^^ no_copy ^^ foreign ^^ pure
    ^^ text "func " ^^ text name ^^ type_params
  in
  let params =
    print_params
      ~force_multiline:
        (should_force_signature_params ~head ~params:fd.func_params ~ret
           ~where_clause)
      fd.func_params
  in
  let sig_doc = head ^^ params ^^ ret ^^ where_clause in
  match func_foreign_info fd with
  | Some { foreign_name; _ } when foreign_name <> name ->
      sig_doc ^^ text " = \"" ^^ text foreign_name ^^ text "\""
  | Some _ -> sig_doc
  | None -> (
      match fd.func_body with
      | FuncNoBody -> sig_doc ^^ text ":"
      | FuncBuiltinBody (builtin, _) ->
          sig_doc ^^ text ":" ^^ indent (hardline ^^ print_builtin_body builtin)
      | FuncForeign _ -> sig_doc
      | FuncBodyExpr body ->
          sig_doc ^^ text ":" ^^ indent (hardline ^^ print_block_body body))

(** Print a type/union declaration *)
let print_type_decl ?(is_private = false) td =
  let export = if is_private then text "private " else Nil in
  let type_params = print_type_params td.type_params in
  if td.type_is_builtin then
    (* [type Name = builtin] / [type Name[T] = builtin] *)
    export ^^ text "type " ^^ text td.type_name ^^ type_params
    ^^ text " = builtin"
  else
    let variants =
      List.map
        (fun v ->
          let fields =
            if v.variant_fields = [] then Nil
            else
              text "("
              ^^ comma_sep (List.map print_type_expr v.variant_fields)
              ^^ text ")"
          in
          text v.variant_name ^^ fields)
        td.type_variants
    in
    let keyword = if td.type_is_enum then "enum " else "union " in
    export ^^ text keyword ^^ text td.type_name ^^ type_params ^^ text ":"
    ^^ indent (hardline ^^ hardlines variants)

(** Print a record declaration *)
let print_record_decl ?(is_private = false) rd =
  let export = if is_private then text "private " else Nil in
  let type_params = print_type_params rd.record_type_params in
  let keyword = if rd.record_is_value then "struct " else "record " in
  if rd.record_is_builtin then
    export ^^ text keyword ^^ text rd.record_name ^^ type_params
    ^^ text " {builtin}"
  else
    let fields =
      List.map
        (fun f ->
          text f.field_name ^^ text ": " ^^ print_type_expr f.field_type)
        rd.record_fields
    in
    export ^^ text keyword ^^ text rd.record_name ^^ type_params ^^ text " {"
    ^^ group (indent (softline ^^ comma_sep_break fields) ^^ softline)
    ^^ text "}"

(** Print a variable declaration (top-level) *)
let print_var_decl ?(is_private = false) vd =
  let export = if is_private then text "private " else Nil in
  let prefix = if vd.var_is_mutable then text "var " else Nil in
  let name_doc =
    match vd.var_name with
    | Some n -> text n
    | None -> (
        match vd.var_pattern with
        | Some pat -> print_pattern pat
        | None -> text "_")
  in
  let ty_ann =
    match vd.var_type with
    | Some ty -> text ": " ^^ print_type_expr ty
    | None -> Nil
  in
  export ^^ prefix ^^ name_doc ^^ ty_ann ^^ text " = "
  ^^ print_expr vd.var_value

(** Print a trait declaration *)
let print_trait_decl ?(is_private = false) td =
  let export = if is_private then text "private " else Nil in
  let type_params = print_type_params td.trait_type_params in
  let supers =
    if td.trait_supertraits = [] then Nil
    else
      text ": "
      ^^ concat
           (List.mapi
              (fun i s -> (if i > 0 then text " + " else Nil) ^^ text s)
              td.trait_supertraits)
  in
  (* Only emit trailing colon if trait has methods or has no supertraits.
     Supertraits-only traits (e.g., trait Baz: Foo) must NOT have a trailing colon. *)
  let needs_colon = td.trait_methods <> [] || td.trait_supertraits = [] in
  let header =
    export ^^ text "trait " ^^ text td.trait_name ^^ type_params ^^ supers
    ^^ if needs_colon then text ":" else Nil
  in
  let methods =
    List.map
      (fun m ->
        let pure = if m.method_is_pure then text "pure " else Nil in
        let ret =
          match m.method_return_type with
          | Some ty -> text " -> " ^^ print_type_expr ty
          | None -> Nil
        in
        let head = pure ^^ text "func " ^^ text m.method_name in
        let params =
          print_params
            ~force_multiline:
              (should_force_signature_params ~head ~params:m.method_params ~ret
                 ~where_clause:Nil)
            m.method_params
        in
        let sig_doc = head ^^ params ^^ ret in
        match m.method_default_body with
        | None -> sig_doc
        | Some body -> (
            match body.expr_desc with
            | EBlock _ ->
                sig_doc ^^ text ":" ^^ indent (hardline ^^ print_block_body body)
            | _ -> sig_doc ^^ text ": " ^^ print_expr body))
      td.trait_methods
  in
  header ^^ indent (hardline ^^ hardlines methods)

(** Print an impl declaration *)
let print_impl_decl ?(is_private = false) id =
  let export = if is_private then text "private " else Nil in
  let header =
    export ^^ text "implements " ^^ text id.impl_trait ^^ text " for "
    ^^ print_type_expr id.impl_for_type
    ^^ text ":"
  in
  let methods = List.map (fun fd -> print_func_decl fd) id.impl_methods in
  header ^^ indent (hardline ^^ blank_lines 1 methods)

(** Print a type alias declaration *)
let print_type_alias ?(is_private = false) ta =
  let export = if is_private then text "private " else Nil in
  let type_params = print_type_params ta.alias_type_params in
  export ^^ text "type alias " ^^ text ta.alias_name ^^ type_params
  ^^ text " = "
  ^^ print_type_expr ta.alias_target

let print_new_type ?(is_private = false) nt =
  let export = if is_private then text "private " else Nil in
  let type_params = print_type_params nt.new_type_params in
  export ^^ text "new type " ^^ text nt.new_type_name ^^ type_params
  ^^ text " = "
  ^^ print_type_expr nt.new_type_target

(** Print a single declaration (non-import) *)
let rec print_decl_desc ?(is_private = false) = function
  | DFunc fd -> print_func_decl ~is_private fd
  | DType td -> print_type_decl ~is_private td
  | DRecord rd -> print_record_decl ~is_private rd
  | DVar vd -> print_var_decl ~is_private vd
  | DImport imp -> print_import imp
  | DPrivate inner -> print_decl_inner ~is_private:true inner
  | DTrait td -> print_trait_decl ~is_private td
  | DImpl id -> print_impl_decl ~is_private id
  | DTypeAlias ta -> print_type_alias ~is_private ta
  | DNewType nt -> print_new_type ~is_private nt

and print_decl_inner ?(is_private = false) d =
  let doc_doc =
    match d.decl_doc with Some doc -> print_docstring doc | None -> Nil
  in
  let lead = leading_comments d.decl_loc.line in
  lead ^^ doc_doc
  ^^ print_decl_desc ~is_private d.decl_desc
  ^^ trailing_comment d.decl_loc.line

(* ─── Program ───────────────────────────────────────────────────────── *)

(** Print a foreign func without the 'foreign' prefix (used inside foreign blocks) *)
let print_foreign_block_func fd =
  let no_copy = if fd.func_no_copy then text "@no_copy " else Nil in
  let debug_only = if fd.func_debug_only then text "@debug_only " else Nil in
  let pure = if fd.func_is_pure then text "pure " else Nil in
  let name = match fd.func_name with Some n -> n | None -> "" in
  let type_params = print_type_params fd.func_type_params in
  let params = print_params fd.func_params in
  let ret =
    match fd.func_return_type with
    | Some ty -> text " -> " ^^ print_type_expr ty
    | None -> Nil
  in
  let sig_doc =
    debug_only ^^ no_copy ^^ pure ^^ text "func " ^^ text name ^^ type_params
    ^^ params ^^ ret
  in
  match func_foreign_info fd with
  | Some { foreign_name; _ } when foreign_name <> name ->
      sig_doc ^^ text " = \"" ^^ text foreign_name ^^ text "\""
  | _ -> sig_doc

(** Print a group of foreign functions as a foreign(...): block *)
let print_foreign_block (includes, link_flags) decls =
  let flag_key = function
    | None -> "link"
    | Some "linux" -> "link_linux"
    | Some "macos" -> "link_macos"
    | Some tag -> "link_" ^ tag (* forward-compat *)
  in
  let args =
    List.map (fun inc -> "include: \"" ^ inc ^ "\"") includes
    @ List.map (fun (tag, lf) -> flag_key tag ^ ": \"" ^ lf ^ "\"") link_flags
  in
  let header =
    if args = [] then text "foreign:"
    else text "foreign(" ^^ text (String.concat ", " args) ^^ text "):"
  in
  let items =
    List.mapi
      (fun i d ->
        let doc_doc =
          match d.decl_doc with Some doc -> print_docstring doc | None -> Nil
        in
        (* Skip leading_comments for first decl — already extracted by group_foreign *)
        let lead = if i = 0 then Nil else leading_comments d.decl_loc.line in
        let func_doc =
          match d.decl_desc with
          | DFunc fd -> print_foreign_block_func fd
          | _ -> print_decl_desc d.decl_desc
        in
        lead ^^ doc_doc ^^ func_doc ^^ trailing_comment d.decl_loc.line)
      decls
  in
  header ^^ indent (hardline ^^ hardlines items)

(** Print a complete program *)
let print_program (program : program) =
  (* Extract file-level header comments — comments that appear before the
     first declaration of any kind.  These must be emitted before imports
     so they don't get swept up by the first non-import declaration. *)
  let first_line =
    match program with d :: _ -> d.decl_loc.line | [] -> max_int
  in
  let header_comments = leading_comments first_line in

  (* Sort only a leading import section. Imports that appear after real
     declarations must stay in place; otherwise comments and declarations
     before them get swept into the import block. *)
  let rec split_leading_imports acc = function
    | ({ decl_desc = DImport _; _ } as d) :: rest ->
        split_leading_imports (d :: acc) rest
    | rest -> (List.rev acc, rest)
  in
  let import_decls, others = split_leading_imports [] program in

  (* Pair each import with its leading comments so comments travel with
     imports through sorting.  Trailing comments on the import line are
     also captured. *)
  let import_with_comments =
    List.map
      (fun (d : decl) ->
        let imp = match d.decl_desc with DImport i -> i | _ -> assert false in
        let leading =
          Fmt_comment.take_leading !comments ~before_line:d.decl_loc.line
        in
        let trailing =
          Fmt_comment.take_trailing !comments ~on_line:d.decl_loc.line
        in
        (imp, leading, trailing))
      import_decls
  in
  (* Drain any remaining comments in the import section range so they
     don't leak into the body.  These are orphan comments between the
     last import and the first body decl (rare). *)
  let import_trailing_comments =
    match import_decls with
    | [] -> Nil
    | _ ->
        let last_import_line =
          List.fold_left (fun mx d -> max mx d.decl_loc.line) 0 import_decls
        in
        let drained =
          Fmt_comment.drain_through !comments ~through_line:last_import_line
        in
        if drained = [] then Nil
        else
          let docs =
            List.map
              (fun (c : Lexer.collected_comment) ->
                text (Fmt_comment.normalize_comment c.cc_text) ^^ hardline)
              drained
          in
          hardline ^^ concat docs
  in

  (* Sort and group imports, carrying comments along *)
  let sort_with_comments pairs =
    let deduped = dedup_imports (List.map (fun (i, _, _) -> i) pairs) in
    (* After dedup, re-associate: find the pair whose import matches *)
    let find_pair imp =
      List.find_opt (fun (i, _, _) -> i.import_module = imp.import_module) pairs
    in
    let deduped_with_comments =
      List.filter_map
        (fun imp ->
          match find_pair imp with
          | Some (_, lead, trail) -> Some (imp, lead, trail)
          | None -> Some (imp, [], None))
        deduped
    in
    let std =
      List.filter (fun (i, _, _) -> is_std_import i) deduped_with_comments
    in
    let proj =
      List.filter (fun (i, _, _) -> not (is_std_import i)) deduped_with_comments
    in
    let sort_group g =
      List.sort
        (fun (a, _, _) (b, _, _) ->
          String.compare a.import_module b.import_module)
        g
    in
    (sort_group std, sort_group proj)
  in
  let std_imps, proj_imps = sort_with_comments import_with_comments in

  (* Build import section as import: block, emitting comments with their imports *)
  let print_import_with_comments (imp, leading, trailing) =
    let lead_doc =
      match leading with
      | [] -> Nil
      | cs ->
          concat
            (List.map
               (fun (c : Lexer.collected_comment) ->
                 text (Fmt_comment.normalize_comment c.cc_text) ^^ hardline)
               cs)
    in
    let trail_doc =
      match trailing with
      | Some (c : Lexer.collected_comment) ->
          line_suffix (Fmt_comment.normalize_comment c.cc_text)
      | None -> Nil
    in
    lead_doc ^^ print_import_item imp ^^ trail_doc
  in
  let render_import_block ?(suffix = Nil) std_imps proj_imps =
    let std_doc =
      if std_imps = [] then Nil
      else hardlines (List.map print_import_with_comments std_imps)
    in
    let proj_doc =
      if proj_imps = [] then Nil
      else hardlines (List.map print_import_with_comments proj_imps)
    in
    let body =
      match (std_imps, proj_imps) with
      | [], [] -> Nil
      | _, [] -> std_doc
      | [], _ -> proj_doc
      | _, _ -> std_doc ^^ hardline ^^ proj_doc
    in
    if std_imps = [] && proj_imps = [] then Nil
    else text "import:" ^^ indent (hardline ^^ body) ^^ suffix
  in
  let import_doc =
    render_import_block ~suffix:import_trailing_comments std_imps proj_imps
  in
  let print_import_block import_decls =
    let import_with_comments =
      List.map
        (fun (d : decl) ->
          let imp =
            match d.decl_desc with DImport i -> i | _ -> assert false
          in
          let leading =
            Fmt_comment.take_leading !comments ~before_line:d.decl_loc.line
          in
          let trailing =
            Fmt_comment.take_trailing !comments ~on_line:d.decl_loc.line
          in
          (imp, leading, trailing))
        import_decls
    in
    let std_imps, proj_imps = sort_with_comments import_with_comments in
    render_import_block std_imps proj_imps
  in

  (* Group consecutive foreign-block functions back into blocks *)
  let get_foreign_key d =
    match d.decl_desc with
    | DFunc fd -> (
        match func_foreign_info fd with
        | Some { foreign_includes; foreign_link_flags; _ }
          when foreign_includes <> [] || foreign_link_flags <> [] ->
            Some (foreign_includes, foreign_link_flags)
        (* All foreign functions use block syntax *)
        | Some _ -> Some ([], [])
        | None -> None)
    | _ -> None
  in
  (* Classify whether a declaration is "small" (constants, aliases, exports of same) *)
  let is_small_decl d =
    match d.decl_desc with
    | DVar _ | DTypeAlias _ | DNewType _ -> true
    | DPrivate { decl_desc = DVar _ | DTypeAlias _ | DNewType _; _ } -> true
    | _ -> false
  in
  let func_name_of_decl d =
    match d.decl_desc with
    | DFunc { func_name = Some name; _ }
    | DPrivate { decl_desc = DFunc { func_name = Some name; _ }; _ } ->
        Some name
    | _ -> None
  in
  let is_same_function_overload d1 d2 =
    match (func_name_of_decl d1, func_name_of_decl d2) with
    | Some name1, Some name2 -> name1 = name2
    | _ -> false
  in
  let rec group_foreign acc decls =
    match decls with
    | [] -> List.rev acc
    | d :: rest -> (
        match d.decl_desc with
        | DImport _ ->
            let rec collect_imports group remaining =
              match remaining with
              | ({ decl_desc = DImport _; _ } as d2) :: rest2 ->
                  collect_imports (d2 :: group) rest2
              | _ -> (List.rev group, remaining)
            in
            let group_decls, remaining = collect_imports [ d ] rest in
            let block_doc = print_import_block group_decls in
            group_foreign ((block_doc, None) :: acc) remaining
        | _ -> (
            match get_foreign_key d with
            | Some key ->
                (* Collect consecutive decls with the same foreign key *)
                let rec collect_group group remaining =
                  match remaining with
                  | d2 :: rest2 when get_foreign_key d2 = Some key ->
                      collect_group (d2 :: group) rest2
                  | _ -> (List.rev group, remaining)
                in
                let group_decls, remaining = collect_group [ d ] rest in
                (* Extract leading comments for the first decl BEFORE entering
                the indented block — otherwise they get consumed inside it *)
                let first_decl = List.hd group_decls in
                let lead = leading_comments first_decl.decl_loc.line in
                let block_doc = print_foreign_block key group_decls in
                group_foreign ((lead ^^ block_doc, None) :: acc) remaining
            | None ->
                let doc_doc =
                  match d.decl_doc with
                  | Some doc -> print_docstring doc
                  | None -> Nil
                in
                let lead = leading_comments d.decl_loc.line in
                let doc =
                  lead ^^ doc_doc
                  ^^ print_decl_desc d.decl_desc
                  ^^ trailing_comment d.decl_loc.line
                in
                group_foreign ((doc, Some d) :: acc) rest))
  in
  (* Build body declarations with context-aware spacing:
     no blank line between same-name function overloads,
     1 blank line between consecutive small declarations (DVar, DTypeAlias),
     2 blank lines around larger declarations (DFunc, DType, DRecord, etc.) *)
  let body_items = group_foreign [] others in
  let sep1 = hardline ^^ hardline in
  (* 1 blank line *)
  let sep2 = hardline ^^ hardline ^^ hardline in
  (* 2 blank lines *)
  let body_doc =
    match body_items with
    | [] -> Nil
    | [ (doc, _) ] -> doc
    | _ ->
        let rec join = function
          | [] -> Nil
          | [ (doc, _) ] -> doc
          | (doc1, decl1) :: ((_, decl2) :: _ as rest) ->
              let sep =
                match (decl1, decl2) with
                | Some d1, Some d2 when is_same_function_overload d1 d2 ->
                    hardline
                | Some d1, Some d2 when is_small_decl d1 && is_small_decl d2 ->
                    sep1
                | _ -> sep2
              in
              doc1 ^^ sep ^^ join rest
        in
        join body_items
  in

  (* Combine imports and body *)
  let full =
    match (std_imps @ proj_imps, others) with
    | [], [] -> Nil
    | [], _ -> body_doc
    | _, [] -> import_doc
    | _, _ -> import_doc ^^ hardline ^^ hardline ^^ hardline ^^ body_doc
  in

  (* Prepend file-level header comments and append remaining comments *)
  header_comments ^^ full ^^ remaining_comments ()
