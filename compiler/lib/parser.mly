%{
(** Blorp Parser

    Grammar for Blorp language:
    - Indentation-sensitive (uses INDENT/DEDENT tokens)
    - Functional with algebraic data types
    - Pattern matching
    - Pure/impure function tracking
    - Rust-style trait system
*)

open Ast

let make_bound_type_param name bounds = make_type_param name bounds

(* Extract the source file from a Lexing.position (None if empty — e.g.
   inline tests that build lexbufs without setting a filename). *)
let pos_file (pos : Lexing.position) =
  if pos.pos_fname = "" then None else Some pos.pos_fname

(* Get current position from Menhir's $symbolstartpos *)
let loc_of_pos (pos : Lexing.position) =
  { line = pos.pos_lnum;
    column = pos.pos_cnum - pos.pos_bol + 1;
    end_line = pos.pos_lnum;
    end_column = pos.pos_cnum - pos.pos_bol + 1;
    loc_file = pos_file pos }

(* Create a span loc from start and end positions *)
let span_loc (spos : Lexing.position) (epos : Lexing.position) =
  { line = spos.pos_lnum; column = spos.pos_cnum - spos.pos_bol + 1;
    end_line = epos.pos_lnum; end_column = epos.pos_cnum - epos.pos_bol + 1;
    loc_file = pos_file spos }

(* These are fallbacks - most rules should use $symbolstartpos directly *)
let make_loc () = point_loc ~line:1 ~column:1

let make_expr desc = { expr_desc = desc; expr_loc = make_loc (); expr_type = None; expr_type_info = None; expr_rc = None }
let make_expr_at pos desc = { expr_desc = desc; expr_loc = loc_of_pos pos; expr_type = None; expr_type_info = None; expr_rc = None }
let make_expr_span spos epos desc = { expr_desc = desc; expr_loc = span_loc spos epos; expr_type = None; expr_type_info = None; expr_rc = None }
let make_decl_at pos desc = { decl_desc = desc; decl_loc = loc_of_pos pos; decl_doc = None }
let make_decl_doc_at pos doc desc = { decl_desc = desc; decl_loc = loc_of_pos pos; decl_doc = doc }

let parse_fail_at pos msg =
  raise (Parse_error_at (loc_of_pos pos, msg))

let foreign_block_only_error pos =
  parse_fail_at pos
    "foreign declarations must use a foreign: block; write `foreign:` and \
     indent `func ...` inside it"

let export_not_supported_error pos =
  parse_fail_at pos
    "export is not supported; declarations are public by default, so remove \
     `export`"

let exported_foreign_block_only_error pos =
  parse_fail_at pos
    "foreign declarations must use a foreign: block; declarations are public \
     by default, so omit `export` and write `foreign:`"

let is_dim_type_arg = function
  | TyConstInt _ | TyVarDims _ | TyDimOp _ -> true
  | TyVar name -> String.length name > 0 && name.[0] = '#'
  | TyNamed (name, []) -> String.length name > 0 && name.[0] = '#'
  | _ -> false

let named_type_or_array name args =
  if args <> [] && List.for_all is_dim_type_arg args then
    TyArray (TyNamed (name, []), args)
  else
    TyNamed (name, args)

let apply_array_suffixes base suffixes =
  List.fold_left (fun ty dims -> TyArray (ty, dims)) base suffixes

let stmts_to_expr = function [e] -> e | es -> make_expr (EBlock es)
let stmts_to_expr_at pos = function [e] -> e | es -> make_expr_at pos (EBlock es)

let func_body_of_expr e =
  let builtin_body_of_opt = function
    | None -> BuiltinIntrinsic
    | Some c_name -> BuiltinRuntime c_name
  in
  match e.expr_desc with
  | EBuiltin opt -> FuncBuiltinBody (builtin_body_of_opt opt, e.expr_loc)
  | EBlock [ ({ expr_desc = EBuiltin opt; _ } as builtin_expr) ] ->
      FuncBuiltinBody (builtin_body_of_opt opt, builtin_expr.expr_loc)
  | _ -> FuncBodyExpr e

(** Create binary expression with span *)
let make_binop_span spos epos op left right =
  make_expr_span spos epos (EBinary (op, left, right))

(** Create a func_decl record — reduces duplication across parser rules *)
let mk_func ~dim_constraints ~is_pure ~name ~tparams ~params ~ret ~body
    ~annots =
  { func_name = name; func_type_params = tparams; func_params = params;
    func_return_type = ret; func_body = body; func_is_pure = is_pure;
    func_is_tailrec = List.mem "tailrec" annots;
    func_no_copy = List.mem "no_copy" annots;
    func_debug_only = List.mem "debug_only" annots;
    func_resource_result_ordinary =
      List.mem "resource_result_ordinary" annots;
    func_dim_constraints = dim_constraints }

let mk_foreign_func ~is_pure ~fn_name ~params ~ret ~c_name ~annots =
  let c_name = match c_name with Some c -> c | None -> fn_name in
  let fd =
    mk_func ~dim_constraints:[] ~is_pure ~name:(Some fn_name) ~tparams:[]
      ~params ~ret:(Some ret) ~body:FuncNoBody ~annots
  in
  {
    fd with
    func_body =
      FuncForeign
        { foreign_name = c_name; foreign_includes = []; foreign_link_flags = [] };
  }

let make_foreign_decl_at pos doc ~is_pure ~fn_name ~params ~ret ~c_name ~annots =
  make_decl_doc_at pos doc
    (DFunc (mk_foreign_func ~is_pure ~fn_name ~params ~ret ~c_name ~annots))

let apply_foreign_block_metadata ~includes ~link_flags decl =
  let apply_to_func fd foreign =
    { fd with
      func_body =
        FuncForeign
          { foreign with
            foreign_includes = includes @ foreign.foreign_includes;
            foreign_link_flags = link_flags @ foreign.foreign_link_flags } }
  in
  match decl.decl_desc with
  | DFunc ({ func_body = FuncForeign foreign; _ } as fd) ->
      { decl with decl_desc = DFunc (apply_to_func fd foreign) }
  | DPrivate ({ decl_desc = DFunc ({ func_body = FuncForeign foreign; _ } as fd); _ } as inner) ->
      { decl with
        decl_desc = DPrivate { inner with decl_desc = DFunc (apply_to_func fd foreign) } }
  | _ -> decl

(** Parse named parameters for concurrent blocks: max_threads: N, timeout: expr *)
type concurrent_params = {
  conc_timeout: expr option;
  conc_max_threads: int option;
}

type concurrently_loop_params = {
  loop_timeout: expr option;
  loop_limit: int option;
}

let concurrent_max_threads_or_error loc n =
  if Int64.compare n 0L <= 0 then
    raise (Parse_error_at (loc, "max_threads must be positive"))
  else if Int64.compare n (Int64.of_int max_int) > 0 then
    raise (Parse_error_at (loc, "max_threads is too large"))
  else Int64.to_int n

let concurrent_loop_limit_or_error loc n =
  if Int64.compare n 0L <= 0 then
    raise (Parse_error_at (loc, "concurrently limit must be positive"))
  else if Int64.compare n (Int64.of_int max_int) > 0 then
    raise (Parse_error_at (loc, "concurrently limit is too large"))
  else Int64.to_int n

let concurrent_for_width_of_legacy = function
  | None -> ConcurrentForDefault
  | Some n -> ConcurrentForMaxThreads n

let concurrent_for_width_of_limit loc params =
  match params.loop_limit with
  | Some n -> ConcurrentForLimit n
  | None ->
      raise
        (Parse_error_at
           (loc, "`for ... concurrently(...)` requires `limit: N`"))

let apply_concurrently_loop_param params (name, value) =
  match name with
  | "limit" ->
      if params.loop_limit <> None then
        raise (Parse_error_at (value.expr_loc, "duplicate concurrently limit"))
      else (
        match value.expr_desc with
        | ELiteral (LitInt n) ->
            {
              params with
              loop_limit =
                Some (concurrent_loop_limit_or_error value.expr_loc n);
            }
        | _ ->
            raise
              (Parse_error_at
                 (value.expr_loc, "concurrently limit must be an integer literal"))
        )
  | "timeout" ->
      if params.loop_timeout <> None then
        raise (Parse_error_at (value.expr_loc, "duplicate timeout parameter"))
      else { params with loop_timeout = Some value }
  | "max_threads" ->
      raise
        (Parse_error_at
           (value.expr_loc,
            "use `limit: N` in `concurrently(...)`; `max_threads` is for legacy `concurrent(...)`"))
  | "item_timeout" ->
      raise
        (Parse_error_at
           (value.expr_loc,
            "`item_timeout` is reserved for the concurrency migration but is not implemented yet"))
  | _ ->
      raise
        (Parse_error_at
           (value.expr_loc,
            Printf.sprintf
              "unknown concurrently parameter '%s' (expected 'limit' or 'timeout')"
              name))

%}

(* Tokens *)
%token FUNC PURE VAR UNION ENUM RECORD STRUCT VOID_KW FOREIGN DETACH WHERE
%token WHILE FOR IN IF ELSE AND OR NOT BREAK CONTINUE
%token IMPLEMENTS TRAIT SELF_TYPE TYPE ALIAS BUILTIN
%token IMPORT AS PRIVATE EXPORT MATCH
%token TRUE FALSE
%token <string> IDENT
%token <int64> INT
%token <string> BIGINT
%token <float> FLOAT
%token <string> STRING
%token <string> STRING_RAW
%token <string> STRING_INTERP
%token <string> TRIPLE_STRING
%token <string> TRIPLE_STRING_INTERP
%token <int> CHAR
%token <string> DOCSTRING
%token LPAREN RPAREN LBRACKET RBRACKET LBRACE RBRACE
%token COLON COMMA DOT DOTDOT DOTDOTDOT PLUS MINUS STAR SLASH UNDERSCORE
%token LT GT PERCENT HASH AT ARROW LE GE EQ NE EQUALS
%token PLUS_EQ MINUS_EQ STAR_EQ SLASH_EQ
%token QUESTION_EQUALS FATARROW
%token TRY WITH DEBUG RESOURCE BORROW
%token CONCURRENT CONCURRENTLY
%token PIPE
%token INDENT DEDENT NEWLINE
%token EOF

(* Precedence - lowest to highest *)
%nonassoc EXPR_DONE
%left OR
%left AND
%left EQ NE
%left LT GT LE GE
%nonassoc DOTDOT
%left PLUS MINUS
%left STAR SLASH PERCENT
%nonassoc BUILTIN_BARE POSTFIX_REDUCE
%nonassoc LPAREN LBRACKET DOT

%start <Ast.program> program

%%

(* Parameterized rules for comma-separated lists with optional trailing comma *)
trailing_list(SEP, ITEM):
  | (* empty *) { [] }
  | items = trailing_nonempty_list(SEP, ITEM) { items }

trailing_nonempty_list(SEP, ITEM):
  | x = ITEM { [x] }
  | x = ITEM SEP { [x] }
  | x = ITEM SEP xs = trailing_nonempty_list(SEP, ITEM) { x :: xs }

(* Program: list of declarations *)
program:
  | newlines decls = decl_list EOF { decls }

decl_list:
  | (* empty *) { [] }
  | d = decl newlines ds = decl_list { d :: ds }
  | ds = import_block newlines rest = decl_list { ds @ rest }
  | FOREIGN ds = foreign_dispatch newlines rest = decl_list { ds @ rest }

newlines:
  | (* empty *) { () }
  | NEWLINE newlines { () }

(* Name that allows keywords to be used as identifiers *)
name:
  | n = IDENT { n }
  | DEBUG { "debug" }
  | AND { "and" }
  | OR { "or" }
  | NOT { "not" }
  | TYPE { "type" }
  | MATCH { "match" }
  | IF { "if" }
  | ELSE { "else" }
  | TRUE { "True" }
  | FALSE { "False" }
  | IN { "in" }
  | FOR { "for" }
  | WHILE { "while" }
  | WITH { "with" }
  | FOREIGN { "foreign" }
  | RESOURCE { "resource" }

identifier:
  | n = IDENT { n }
  | DEBUG { "debug" }
  | WITH { "with" }

(* Optional docstring preceding a declaration *)
docstring:
  | (* empty *) { None }
  | doc = DOCSTRING { Some doc }

(* Declarations *)
decl:
  | doc = docstring d = func_decl
    { make_decl_doc_at $symbolstartpos doc (DFunc d) }
  | doc = docstring d = type_decl
    { make_decl_doc_at $symbolstartpos doc (DType d) }
  | doc = docstring d = enum_decl
    { make_decl_doc_at $symbolstartpos doc (DType d) }
  | doc = docstring d = record_decl
    { make_decl_doc_at $symbolstartpos doc (DRecord d) }
  | doc = docstring d = struct_decl
    { make_decl_doc_at $symbolstartpos doc (DRecord d) }
  | d = var_decl { make_decl_at $symbolstartpos (DVar { d with var_is_const = not d.var_is_mutable }) }
  | doc = docstring PRIVATE d = private_inner_decl
    { let inner = if doc <> None && d.decl_doc = None
                  then { d with decl_doc = doc } else d in
      make_decl_at $symbolstartpos (DPrivate inner) }
  | doc = docstring d = trait_decl
    { make_decl_doc_at $symbolstartpos doc (DTrait d) }
  | doc = docstring d = impl_decl
    { make_decl_doc_at $symbolstartpos doc (DImpl d) }
  | doc = docstring d = type_alias_decl
    { make_decl_doc_at $symbolstartpos doc (DTypeAlias d) }
  | docstring e = EXPORT FOREIGN FUNC
    { let _ = e in exported_foreign_block_only_error $startpos(e) }
  | docstring e = EXPORT FOREIGN PURE FUNC
    { let _ = e in exported_foreign_block_only_error $startpos(e) }
  | docstring e = EXPORT PURE FUNC
    { let _ = e in export_not_supported_error $startpos(e) }
  | docstring e = EXPORT FUNC
    { let _ = e in export_not_supported_error $startpos(e) }
  | docstring e = EXPORT start = unsupported_export_decl_start
    { let _ = (e, start) in export_not_supported_error $startpos(e) }
  | DOCSTRING FOREIGN FUNC
    { foreign_block_only_error $symbolstartpos }
  | DOCSTRING FOREIGN PURE FUNC
    { foreign_block_only_error $symbolstartpos }

unsupported_export_decl_start:
  | TYPE { () }
  | UNION { () }
  | ENUM { () }
  | RECORD { () }
  | STRUCT { () }
  | VAR { () }
  | TRAIT { () }
  | IMPLEMENTS { () }
  | IDENT { () }

(* Inline helpers for purity/return-type cross-product *)
%inline purity_prefix:
  | PURE { true }
  | { false }

%inline return_type_opt:
  | ARROW t = type_expr { Some t }
  | { None }

%inline type_annotation_opt:
  | COLON t = type_expr { Some t }
  | { None }

%inline lambda_purity:
  | PURE { true }
  | FUNC { false }
  | PURE FUNC { true }

%inline foreign_c_name_opt:
  | EQUALS c = STRING { Some c }
  | { None }

(* Function declaration *)
func_decl:
  | annots = annotations p = purity_prefix FUNC fn_name = name type_params = type_params_opt
    params = params ret = return_type_opt wc = where_clause_opt COLON body = func_body
    { mk_func ~dim_constraints:wc ~is_pure:p ~name:(Some fn_name) ~tparams:type_params
        ~params ~ret ~body ~annots }
  (* The [builtin func Name(...)] / [builtin pure func Name(...)] top-level
     declaration form was removed 2026-04-24. It previously declared a
     function signature with no body for env registration (used only by
     the reverted prelude-as-builtin-decls design). Use [builtin("cname")]
     as the function body inside a domain module instead — that both
     declares the signature and specifies the runtime helper binding. *)
annotations:
  | (* empty *) { [] }
  | AT name = IDENT NEWLINE rest = annotations { name :: rest }
  | AT name = IDENT rest = annotations { name :: rest }
  | AT name = IDENT LPAREN n = INT RPAREN NEWLINE rest = annotations
    { (name ^ "(" ^ Int64.to_string n ^ ")") :: rest }
  | AT name = IDENT LPAREN n = INT RPAREN rest = annotations
    { (name ^ "(" ^ Int64.to_string n ^ ")") :: rest }

(* Inline annotations: identical to [annotations] but without the
   NEWLINE branches, so the surrounding context can require everything
   to live on the same logical line. Used after [PRIVATE] so that
   `private @tailrec\npure func ...` is rejected — the visibility
   modifier must sit with its signature. *)
annotations_inline:
  | (* empty *) { [] }
  | AT name = IDENT rest = annotations_inline { name :: rest }
  | AT name = IDENT LPAREN n = INT RPAREN rest = annotations_inline
    { (name ^ "(" ^ Int64.to_string n ^ ")") :: rest }

func_decl_inline:
  | annots = annotations_inline p = purity_prefix FUNC fn_name = name type_params = type_params_opt
    params = params ret = return_type_opt wc = where_clause_opt COLON body = func_body
    { mk_func ~dim_constraints:wc ~is_pure:p ~name:(Some fn_name) ~tparams:type_params
        ~params ~ret ~body ~annots }
  (* [builtin func] top-level decl form removed 2026-04-24 — see [func_decl]. *)

(* Decls allowed directly under [PRIVATE] — same set as the top-level
   [decl] rule but with [func_decl_inline] swapped in for [func_decl]
   so that annotations + func keyword cannot be split across lines from
   the [PRIVATE] modifier. *)
private_inner_decl:
  | doc = docstring d = func_decl_inline
    { make_decl_doc_at $symbolstartpos doc (DFunc d) }
  | doc = docstring d = type_decl
    { make_decl_doc_at $symbolstartpos doc (DType d) }
  | doc = docstring d = enum_decl
    { make_decl_doc_at $symbolstartpos doc (DType d) }
  | doc = docstring d = record_decl
    { make_decl_doc_at $symbolstartpos doc (DRecord d) }
  | doc = docstring d = struct_decl
    { make_decl_doc_at $symbolstartpos doc (DRecord d) }
  | d = var_decl
    { make_decl_at $symbolstartpos (DVar { d with var_is_const = not d.var_is_mutable }) }
  | doc = docstring d = trait_decl
    { make_decl_doc_at $symbolstartpos doc (DTrait d) }
  | doc = docstring d = impl_decl
    { make_decl_doc_at $symbolstartpos doc (DImpl d) }
  | doc = docstring d = type_alias_decl
    { make_decl_doc_at $symbolstartpos doc (DTypeAlias d) }
  | docstring e = EXPORT FOREIGN FUNC
    { let _ = e in exported_foreign_block_only_error $startpos(e) }
  | docstring e = EXPORT FOREIGN PURE FUNC
    { let _ = e in exported_foreign_block_only_error $startpos(e) }
  | docstring e = EXPORT PURE FUNC
    { let _ = e in export_not_supported_error $startpos(e) }
  | docstring e = EXPORT FUNC
    { let _ = e in export_not_supported_error $startpos(e) }
  | docstring e = EXPORT start = unsupported_export_decl_start
    { let _ = (e, start) in export_not_supported_error $startpos(e) }
  | docstring FOREIGN FUNC
    { foreign_block_only_error $symbolstartpos }
  | docstring FOREIGN PURE FUNC
    { foreign_block_only_error $symbolstartpos }

type_params_opt:
  | (* empty *) { [] }
  | LBRACKET params = type_param_list RBRACKET { params }

type_param_list:
  | (* empty *) { [] }
  | params = type_param_nonempty_list { params }

type_param_nonempty_list:
  | p = type_param { [p] }
  | p = type_param COMMA { [p] }
  | p = type_param COMMA ps = type_param_nonempty_list { p :: ps }

type_param:
  | name = IDENT { make_type_param name [] }
  | HASH name = IDENT { make_type_param ("#" ^ name) [] }  (* Numeric type parameter *)
  | HASH UNDERSCORE { make_type_param "#_" [] }  (* Wildcard numeric type parameter *)
  | name = IDENT COLON bounds = separated_nonempty_list(PLUS, IDENT)
    { make_bound_type_param name bounds }  (* With trait bounds *)

params:
  | LPAREN ps = trailing_list(COMMA, param) RPAREN { ps }

param:
  | name = IDENT COLON ty = type_expr
    { { param_name = Some name; param_pattern = None; param_type = Some ty; param_passing = ParamByValue; param_loc = loc_of_pos $symbolstartpos } }
  | name = IDENT COLON BORROW ty = type_expr
    { { param_name = Some name; param_pattern = None; param_type = Some ty; param_passing = ParamBorrow; param_loc = loc_of_pos $symbolstartpos } }
  | name = IDENT
    { { param_name = Some name; param_pattern = None; param_type = None; param_passing = ParamByValue; param_loc = loc_of_pos $symbolstartpos } }
  | UNDERSCORE
    { { param_name = None; param_pattern = Some PatWildcard; param_type = None; param_passing = ParamByValue; param_loc = loc_of_pos $symbolstartpos } }
  | UNDERSCORE COLON ty = type_expr
    { { param_name = Some "_"; param_pattern = None; param_type = Some ty; param_passing = ParamByValue; param_loc = loc_of_pos $symbolstartpos } }
  | UNDERSCORE COLON BORROW ty = type_expr
    { { param_name = Some "_"; param_pattern = None; param_type = Some ty; param_passing = ParamBorrow; param_loc = loc_of_pos $symbolstartpos } }
  | LPAREN p1 = IDENT COMMA ps = trailing_nonempty_list(COMMA, IDENT) RPAREN COLON ty = type_expr
    { let all = p1 :: ps in
      if List.length all > 4 then parse_fail_at $symbolstartpos "Tuples support 2-4 elements";
      { param_name = None;
        param_pattern = Some (PatTuple (List.map (fun n -> PatVar n) all));
        param_type = Some ty; param_passing = ParamByValue; param_loc = loc_of_pos $symbolstartpos } }
  | LPAREN p1 = IDENT COMMA ps = trailing_nonempty_list(COMMA, IDENT) RPAREN
    { let all = p1 :: ps in
      if List.length all > 4 then parse_fail_at $symbolstartpos "Tuples support 2-4 elements";
      { param_name = None;
        param_pattern = Some (PatTuple (List.map (fun n -> PatVar n) all));
        param_type = None; param_passing = ParamByValue; param_loc = loc_of_pos $symbolstartpos } }

func_body:
  | e = expr { func_body_of_expr e }
  | NEWLINE INDENT stmts = stmt_list DEDENT
    { func_body_of_expr (make_expr (EBlock stmts)) }
  | NEWLINE { FuncNoBody }  (* Forward declaration - no body *)

stmt_list:
  | newlines ss = stmt_list_nonempty { ss }

stmt_list_nonempty:
  | s = stmt rest = stmt_list_tail { s :: rest }

stmt_list_tail:
  | NEWLINE newlines rest = stmt_list_after_newline { rest }
  | s = stmt rest = stmt_list_tail { s :: rest }  (* After DEDENT, no NEWLINE before next stmt *)
  | { [] }

stmt_list_after_newline:
  | rest = stmt_list_nonempty { rest }
  | { [] }

destruct_ident:
  | n = IDENT { n }
  | UNDERSCORE { "_" }

with_binding:
  | name = destruct_ident EQUALS value = expr
    { { with_name = name; with_type = None;
        with_value = value; with_kind = WithPlain } }
  | name = destruct_ident COLON ty = type_expr EQUALS value = expr
    { { with_name = name; with_type = Some ty;
        with_value = value; with_kind = WithPlain } }
  | name = destruct_ident QUESTION_EQUALS value = expr
    { { with_name = name; with_type = None;
        with_value = value; with_kind = WithTry } }
  | name = destruct_ident COLON ty = type_expr QUESTION_EQUALS value = expr
    { { with_name = name; with_type = Some ty;
        with_value = value; with_kind = WithTry } }

stmt:
  | d = stmt_var_decl
    { match (d.var_name, d.var_pattern) with
      | (Some name, _) -> make_expr_at $symbolstartpos (EVarDecl (name, d.var_type, d.var_value, d.var_is_mutable))
      | (None, Some _pat) -> make_expr_at $symbolstartpos EVoid
      | (None, None) -> make_expr_at $symbolstartpos EVoid }
  | WHILE cond = expr COLON NEWLINE INDENT body = stmt_list DEDENT
    { make_expr_at $symbolstartpos (EWhile (cond, make_expr (EBlock body))) }
  (* Error: while without colon *)
  | WHILE expr NEWLINE
    { parse_fail_at $startpos($3) "Expected ':' after while condition" }
  | FOR name = IDENT IN iter = expr COLON NEWLINE INDENT body = stmt_list DEDENT
    { make_expr_at $symbolstartpos (EFor (name, iter, make_expr (EBlock body))) }
  (* Error: for without 'in' keyword *)
  | FOR IDENT IDENT
    { parse_fail_at $startpos($3) "Expected 'in' after for variable. Write 'for x in collection:'" }
  | FOR UNDERSCORE IN iter = expr COLON NEWLINE INDENT body = stmt_list DEDENT
    { make_expr_at $symbolstartpos (EFor ("_", iter, make_expr (EBlock body))) }
  (* For-in with N-ary tuple destructuring: for (a, b) in pairs: or for (a, b, c) in triples: *)
  | FOR LPAREN d1 = destruct_ident COMMA ds = trailing_nonempty_list(COMMA, destruct_ident) RPAREN IN iter = expr COLON NEWLINE INDENT body = stmt_list DEDENT
    { let all = d1 :: ds in
      if List.length all > 4 then parse_fail_at $symbolstartpos "Tuples support 2-4 elements";
      make_expr_at $symbolstartpos (EForTuple (all, iter, make_expr (EBlock body))) }
  (* ?= bindings propagate Option/Result from the enclosing carrier-returning block. *)
  | name = IDENT QUESTION_EQUALS e = expr
    { make_expr_at $symbolstartpos (EQuestionBind (name, None, e)) }
  | name = IDENT COLON ty = type_expr QUESTION_EQUALS e = expr
    { make_expr_at $symbolstartpos (EQuestionBind (name, Some ty, e)) }
  (* Nested function declaration: [pure func name[T](params) -> ret: body]
     appearing inside a block. Produces [EFuncDecl] which the nested-hoist
     pre-infer pass lifts to top level. Same syntax as a top-level func_decl
     minus the top-level-only affordances (private, @tailrec, foreign,
     builtin) — those would mean something different or nothing at all
     inside a body. *)
  | p = purity_prefix FUNC fn_name = name type_params = type_params_opt
    params = params ret = return_type_opt wc = where_clause_opt COLON body = func_body
    { let fd = mk_func ~dim_constraints:wc ~is_pure:p ~name:(Some fn_name)
        ~tparams:type_params ~params ~ret ~body ~annots:[] in
      make_expr_at $symbolstartpos (EFuncDecl fd) }
  | DEBUG COLON NEWLINE INDENT stmts = stmt_list DEDENT
    { make_expr_at $symbolstartpos (EDebugBlock stmts) }
  | e = expr { e }

stmt_var_decl:
  | VAR name = IDENT ty = type_annotation_opt EQUALS e = expr
    { { var_name = Some name; var_pattern = None;
        var_type = ty; var_value = e; var_is_mutable = true; var_is_const = false } }
  | name = IDENT COLON ty = type_expr EQUALS e = expr
    { { var_name = Some name; var_pattern = None;
        var_type = Some ty; var_value = e; var_is_mutable = false; var_is_const = false } }

(* Type declaration (union/ADT) *)
type_decl:
  | UNION name = IDENT type_params = type_params_opt COLON NEWLINE
    INDENT variants = variant_list DEDENT
    { { type_name = name;
        type_params = type_params;
        type_variants = variants;
        type_is_enum = false;
        type_is_builtin = false;
        type_is_resource = false;
        type_resource_cleanup = None } }
  (* Primitive type declaration: [type Name = builtin] or [type Name[T] = builtin].
     Declares a type whose representation and operations are provided by the
     compiler. Used in std/ to make primitives like Int, Float, Tensor visible
     to humans grepping the stdlib. *)
  | TYPE name = IDENT type_params = type_params_opt EQUALS BUILTIN
    { { type_name = name;
        type_params = type_params;
        type_variants = [];
        type_is_enum = false;
        type_is_builtin = true;
        type_is_resource = false;
        type_resource_cleanup = None } }
  | RESOURCE TYPE name = IDENT type_params = type_params_opt EQUALS BUILTIN
    { { type_name = name;
        type_params = type_params;
        type_variants = [];
        type_is_enum = false;
        type_is_builtin = true;
        type_is_resource = true;
        type_resource_cleanup = None } }
  | RESOURCE TYPE name = IDENT type_params = type_params_opt EQUALS BUILTIN LPAREN cleanup = STRING RPAREN
    { { type_name = name;
        type_params = type_params;
        type_variants = [];
        type_is_enum = false;
        type_is_builtin = true;
        type_is_resource = true;
        type_resource_cleanup = Some (ResourceCleanupBuiltin cleanup) } }

(* Enum declaration (integer-valued union, no fields, no type params) *)
enum_decl:
  | ENUM name = IDENT COLON NEWLINE
    INDENT variants = variant_list DEDENT
    { { type_name = name;
        type_params = [];
        type_variants = variants;
        type_is_enum = true;
        type_is_builtin = false;
        type_is_resource = false;
        type_resource_cleanup = None } }

variant_list:
  | v = variant { [v] }
  | v = variant NEWLINE vs = variant_list { v :: vs }

variant:
  | name = IDENT
    { { variant_name = name; variant_fields = []; variant_tag = 0; variant_loc = loc_of_pos $symbolstartpos; variant_def_id = None } }
  (* Allow True/False as enum variant names — needed so [enum Bool: True; False] parses. *)
  | TRUE
    { { variant_name = "True"; variant_fields = []; variant_tag = 0; variant_loc = loc_of_pos $symbolstartpos; variant_def_id = None } }
  | FALSE
    { { variant_name = "False"; variant_fields = []; variant_tag = 0; variant_loc = loc_of_pos $symbolstartpos; variant_def_id = None } }
  | name = IDENT LPAREN fields = trailing_list(COMMA, type_expr) RPAREN
    { { variant_name = name; variant_fields = fields; variant_tag = 0; variant_loc = loc_of_pos $symbolstartpos; variant_def_id = None } }

(* Record declaration - brace syntax only, can span multiple lines *)
record_decl:
  | RECORD name = IDENT type_params = type_params_opt LBRACE
    fields = trailing_list(COMMA, field_decl) RBRACE
    { { record_name = name;
        record_type_params = type_params;
        record_fields = fields;
        record_is_value = false;
        record_is_builtin = false } }
  | RECORD name = IDENT type_params = type_params_opt LBRACE BUILTIN RBRACE
    { { record_name = name;
        record_type_params = type_params;
        record_fields = [];
        record_is_value = false;
        record_is_builtin = true } }

(* Struct declaration - stack-allocated value type *)
struct_decl:
  | STRUCT name = IDENT LBRACE
    fields = trailing_list(COMMA, field_decl) RBRACE
    { { record_name = name;
        record_type_params = [];
        record_fields = fields;
        record_is_value = true;
        record_is_builtin = false } }

field_decl:
  | name = identifier COLON ty = type_expr
    { { field_name = name; field_type = ty; field_loc = loc_of_pos $symbolstartpos } }

(* Variable declaration *)
var_decl:
  | VAR name = IDENT ty = type_annotation_opt EQUALS e = expr
    { { var_name = Some name; var_pattern = None;
        var_type = ty; var_value = e; var_is_mutable = true; var_is_const = false } }
  | name = IDENT ty = type_annotation_opt EQUALS e = expr
    { { var_name = Some name; var_pattern = None;
        var_type = ty; var_value = e; var_is_mutable = false; var_is_const = false } }

(* Import block: import: NEWLINE INDENT items... DEDENT *)
import_block:
  | IMPORT COLON NEWLINE INDENT newlines items = import_block_body DEDENT
    { items }

import_block_body:
  | (* empty *) { [] }
  | item = import_block_item newlines rest = import_block_body
    { make_decl_at $symbolstartpos (DImport item) :: rest }

import_block_item:
  | path = module_path AS alias = identifier COLON syms = separated_nonempty_list(COMMA, import_sym)
    { { import_module = path; import_symbols = Some syms; import_alias = Some alias } }
  | path = module_path COLON syms = separated_nonempty_list(COMMA, import_sym)
    { { import_module = path; import_symbols = Some syms; import_alias = None } }
  | path = module_path AS alias = identifier COLON NEWLINE INDENT newlines syms = import_sym_block
    { { import_module = path; import_symbols = Some syms; import_alias = Some alias } }
  | path = module_path COLON NEWLINE INDENT newlines syms = import_sym_block
    { { import_module = path; import_symbols = Some syms; import_alias = None } }
  | path = module_path AS alias = identifier LBRACE syms = trailing_nonempty_list(COMMA, import_sym) RBRACE
    { let _ = (path, alias, syms) in
      parse_fail_at $symbolstartpos
        "use ':' for selective imports; write `module as Alias: name1, name2` instead of `module as Alias { name1, name2 }`." }
  | path = module_path LBRACE syms = trailing_nonempty_list(COMMA, import_sym) RBRACE
    { let _ = (path, syms) in
      parse_fail_at $symbolstartpos
        "use ':' for selective imports; write `module: name1, name2` instead of `module { name1, name2 }`." }
  | path = module_path AS alias = identifier
    { { import_module = path; import_symbols = None; import_alias = Some alias } }
  | path = module_path
    { { import_module = path; import_symbols = None; import_alias = None } }

import_sym_block:
  | syms = trailing_nonempty_list(COMMA, import_sym) tail = import_sym_block_tail
    { syms @ tail }

import_sym_block_tail:
  | DEDENT { [] }
  | NEWLINE newlines DEDENT { [] }
  | NEWLINE newlines rest = import_sym_block { rest }

import_sym:
  | n = name AS alias = identifier
    { { sym_name = n; sym_alias = Some alias; sym_ctors = CtorNone } }
  | n = name LPAREN ctors = trailing_nonempty_list(COMMA, name) RPAREN
    { { sym_name = n; sym_alias = None; sym_ctors = CtorSome ctors } }
  | n = name
    { { sym_name = n; sym_alias = None; sym_ctors = CtorNone } }

module_path:
  | parts = separated_nonempty_list(SLASH, identifier) { String.concat "/" parts }
  | DOT SLASH parts = separated_nonempty_list(SLASH, identifier) { "./" ^ String.concat "/" parts }
  | ups = nonempty_list(dotdot_slash) parts = separated_nonempty_list(SLASH, identifier) { String.concat "" ups ^ String.concat "/" parts }

dotdot_slash:
  | DOTDOT SLASH { "../" }

(* Dispatch after consuming FOREIGN token in decl_list. *)
foreign_dispatch:
  (* foreign(include: "...", link: "..."): block *)
  | LPAREN args = separated_nonempty_list(COMMA, foreign_arg) RPAREN
    COLON NEWLINE INDENT items = foreign_block_items DEDENT
    { let includes = List.filter_map (fun (k, v) ->
        if k = "include" then Some v else None) args in
      (* Platform filtering happens later in the pipeline. The parser
         just tags each flag with the platform (or [None] for all). *)
      let link_flags = List.filter_map (fun (k, v) ->
        if k = "link" then Some (None, v)
        else if k = "link_linux" then Some (Some "linux", v)
        else if k = "link_macos" then Some (Some "macos", v)
        else None) args in
      List.map (apply_foreign_block_metadata ~includes ~link_flags) items }
  (* foreign: block (no args) *)
  | COLON NEWLINE INDENT items = foreign_block_items DEDENT
    { items }
  | PURE FUNC
    { foreign_block_only_error $symbolstartpos }
  | FUNC
    { foreign_block_only_error $symbolstartpos }

(* Named argument in foreign(...) block header *)
foreign_arg:
  | k = IDENT COLON v = STRING { (k, v) }

(* Items inside foreign: block *)
foreign_block_items:
  | (* empty *) { [] }
  | item = foreign_block_item newlines rest = foreign_block_items
    { item :: rest }

foreign_block_item:
  | is_private = foreign_private_opt annots = annotations_inline
    p = purity_prefix FUNC fn_name = name
    params = params ARROW ret = type_expr c = foreign_c_name_opt
    { let decl =
        make_foreign_decl_at $symbolstartpos None ~is_pure:p ~fn_name
          ~params ~ret ~c_name:c ~annots
      in
      if is_private then make_decl_at $symbolstartpos (DPrivate decl) else decl }

foreign_private_opt:
  | PRIVATE { true }
  | { false }

(* ============================================================================
   NEW Trait System - Rust-style
   ============================================================================ *)

(* Trait declaration with method signatures
   trait Show:
       pure func show(value: Self) -> String

   trait Eq:
       pure func eq(a: Self, b: Self) -> Bool
       -- Default implementation
       pure func neq(a: Self, b: Self) -> Bool:
           not eq(a, b)
*)
trait_decl:
  (* trait Name: *)
  | TRAIT name = IDENT COLON NEWLINE INDENT methods = trait_method_list DEDENT
    { { trait_name = name;
        trait_type_params = [];
        trait_supertraits = [];
        trait_methods = methods } }
  (* trait Name[T]: *)
  | TRAIT name = IDENT LBRACKET tparams = type_param_list RBRACKET COLON
    NEWLINE INDENT methods = trait_method_list DEDENT
    { { trait_name = name;
        trait_type_params = tparams;
        trait_supertraits = [];
        trait_methods = methods } }
  (* trait Name: Super1 + Super2 — supertraits only, no own methods *)
  | TRAIT name = IDENT COLON supers = separated_nonempty_list(PLUS, IDENT) NEWLINE
    { { trait_name = name;
        trait_type_params = [];
        trait_supertraits = supers;
        trait_methods = [] } }
  (* trait Name: Super1 + Super2: — supertraits with own methods *)
  | TRAIT name = IDENT COLON supers = separated_nonempty_list(PLUS, IDENT) COLON
    NEWLINE INDENT methods = trait_method_list DEDENT
    { { trait_name = name;
        trait_type_params = [];
        trait_supertraits = supers;
        trait_methods = methods } }
  (* trait Name[T]: Super1 + Super2: *)
  | TRAIT name = IDENT LBRACKET tparams = type_param_list RBRACKET
    COLON supers = separated_nonempty_list(PLUS, IDENT) COLON
    NEWLINE INDENT methods = trait_method_list DEDENT
    { { trait_name = name;
        trait_type_params = tparams;
        trait_supertraits = supers;
        trait_methods = methods } }

trait_method_list:
  | m = trait_method { [m] }
  | m = trait_method NEWLINE ms = trait_method_list { m :: ms }
  | NEWLINE ms = trait_method_list { ms }  (* Skip blank lines *)

(* Trait method signature - may have default body *)
trait_method:
  (* abstract method with return type *)
  | p = purity_prefix FUNC fn_name = name params = params ARROW ret = type_expr
    { { method_name = fn_name; method_params = params;
        method_return_type = Some ret; method_is_pure = p;
        method_default_body = None } }
  (* default method with return type and body *)
  | p = purity_prefix FUNC fn_name = name params = params ARROW ret = type_expr COLON body = trait_method_body
    { { method_name = fn_name; method_params = params;
        method_return_type = Some ret; method_is_pure = p;
        method_default_body = Some body } }
  (* abstract method without return type *)
  | p = purity_prefix FUNC fn_name = name params = params
    { { method_name = fn_name; method_params = params;
        method_return_type = None; method_is_pure = p;
        method_default_body = None } }

trait_method_body:
  | e = expr { e }
  | NEWLINE INDENT stmts = stmt_list DEDENT { make_expr (EBlock stmts) }

(* Impl declaration
   implements Show for Int:
       pure func show(value: Int) -> String:
           to_string(value)

   implements Show for Option[T: Show]:
       pure func show(value: Option[T]) -> String:
           match value
               Some(x): "Some(" + show(x) + ")"
               None: "None"
*)
impl_decl:
  (* implements Trait for Type[T: Bound]: *)
  | IMPLEMENTS trait_name = IDENT FOR for_type = type_expr COLON
    NEWLINE INDENT methods = impl_method_list DEDENT
    { { impl_trait = trait_name;
        impl_for_type = for_type;
        impl_methods = methods } }

impl_method_list:
  | newlines ms = impl_method_list_nonempty { ms }

impl_method_list_nonempty:
  | m = impl_method rest = impl_method_list_tail { m :: rest }

impl_method_list_tail:
  | NEWLINE newlines rest = impl_method_list_after_newline { rest }
  | m = impl_method rest = impl_method_list_tail { m :: rest }  (* After func body DEDENT, no NEWLINE *)
  | { [] }

impl_method_list_after_newline:
  | rest = impl_method_list_nonempty { rest }
  | { [] }

(* Impl method - just a regular function *)
impl_method:
  | p = purity_prefix FUNC fn_name = name type_params = type_params_opt
    params = params ret = return_type_opt wc = where_clause_opt COLON body = func_body
    { mk_func ~dim_constraints:wc ~is_pure:p ~name:(Some fn_name) ~tparams:type_params
        ~params ~ret ~body ~annots:[] }

(* Type alias declaration *)
type_alias_decl:
  | TYPE ALIAS name = IDENT type_params = type_params_opt EQUALS ty = type_expr
    { { alias_name = name; alias_type_params = type_params; alias_target = ty } }

(* Type expressions *)
type_expr:
  | d = type_dim_atom { d }
  | ty = non_dim_type_expr { ty }

non_dim_type_expr:
  | name = IDENT { TyNamed (name, []) } %prec POSTFIX_REDUCE
  | name = IDENT LBRACKET args = trailing_nonempty_list(COMMA, type_arg) RBRACKET
    suffixes = array_suffixes
    { apply_array_suffixes (named_type_or_array name args) suffixes }
  (* Qualified type: Module.Type or Module.Type[Args] *)
  | mod_name = IDENT DOT type_name = IDENT
    { TyNamed (mod_name ^ "." ^ type_name, []) } %prec POSTFIX_REDUCE
  | mod_name = IDENT DOT type_name = IDENT LBRACKET args = trailing_nonempty_list(COMMA, type_arg) RBRACKET
    suffixes = array_suffixes
    { apply_array_suffixes (named_type_or_array (mod_name ^ "." ^ type_name) args) suffixes }
  (* Range type: ..#N — integer in [0, N) *)
  | DOTDOT HASH n = INT { TyRange (TyConstInt (Int64.to_int n)) }
  | DOTDOT HASH name = IDENT { TyRange (TyVar ("#" ^ name)) }
  (* Self type - special type that refers to implementing type *)
  | SELF_TYPE { TySelf }
  (* Void type *)
  | LPAREN RPAREN { TyNamed ("Void", []) }
  (* Zero-param function type *)
  | LPAREN RPAREN ARROW ret = type_expr
    { TyFunc { params = []; return = ret; is_pure = false } }
  (* Pure function type *)
  | PURE LPAREN params = trailing_list(COMMA, type_expr) RPAREN ARROW ret = type_expr
    { TyFunc { params; return = ret; is_pure = true } }
  (* Parenthesized types: (T), (T, T), (T, T) -> R, etc.
     Inside tuple parens, elements may carry bounds on type variables for
     impl [for] clauses: [implements Equatable for (A: Equatable, B: Equatable):].
     Bounded elements are represented as [TyBoundVar], same as in square-
     bracket type args. A bounded tyvar is only meaningful at a declaration
     site (an impl [for] clause or a generic function's type-param list);
     typecheck rejects it in value-position type annotations. *)
  | LPAREN types = trailing_nonempty_list(COMMA, tuple_elem) RPAREN ARROW ret = type_expr
    { TyFunc { params = types; return = ret; is_pure = false } }
  | LPAREN types = trailing_nonempty_list(COMMA, tuple_elem) RPAREN suffixes = array_suffixes
    { let base =
        match types with
        | [t] -> t  (* Just grouping parentheses *)
        | ts when List.length ts >= 2 && List.length ts <= 4 -> TyTuple ts
        | _ -> parse_fail_at $symbolstartpos "Tuples support 2-4 elements"
      in
      apply_array_suffixes base suffixes }

type_dim_atom:
  (* Dimension variable as type: #N — allows dim params to be used as parameter types *)
  | HASH name = IDENT { TyVar ("#" ^ name) }
  (* Dimension literal as type: #300 — singleton dim type, value must equal 300 *)
  | HASH n = INT { TyConstInt (Int64.to_int n) }

array_suffix:
  | LBRACKET dims = trailing_nonempty_list(COMMA, array_dim_arg) RBRACKET { dims }

array_suffixes:
  | { [] } %prec POSTFIX_REDUCE
  | suffix = array_suffix rest = array_suffixes { suffix :: rest }

array_dim_arg:
  | d = dim_expr { d }
  | HASH UNDERSCORE { TyVar "#_" }
  | HASH UNDERSCORE DOTDOTDOT { TyVarDims "#_" }
  | HASH name = IDENT DOTDOTDOT { TyVarDims ("#" ^ name) }

(* An element of a tuple type. Same shape as [type_arg] but restricted to
   forms that make sense inside [(...)] — type exprs and bounded type vars.
   Dim forms ([#N], [#_], [#_...]) are omitted since tuples can't contain
   dim types. *)
tuple_elem:
  (* Bounded type variable: A: Trait or A: T1+T2 *)
  | name = IDENT COLON bounds = separated_nonempty_list(PLUS, IDENT)
    { TyBoundVar (make_bound_type_param name bounds) }
  | ty = non_dim_type_expr { ty }

type_arg:
  (* Type variable with trait bounds - must be before type_expr to match T:Stringable *)
  | name = IDENT COLON bounds = separated_nonempty_list(PLUS, IDENT)
    { TyBoundVar (make_bound_type_param name bounds) }
  | HASH UNDERSCORE { TyVar "#_" }  (* Wildcard dim (one dim, discarded) *)
  | HASH UNDERSCORE DOTDOTDOT { TyVarDims "#_" }  (* Variadic wildcard: #_... (any number of dims, all discarded) *)
  | HASH name = IDENT DOTDOTDOT { TyVarDims ("#" ^ name) }  (* Named variadic dim: #Ds... *)
  | d = dim_expr { d }  (* Dimension expressions: #N, 3, #M + #N, #M * #N *)
  | ty = non_dim_type_expr { ty }

(* Dimension where clauses: where #M + #N == #R, #A == #B *)
where_clause_opt:
  | { [] }
  | WHERE cs = separated_nonempty_list(COMMA, dim_constraint) { cs }

dim_constraint:
  | lhs = dim_expr EQ rhs = dim_expr { (lhs, rhs) }

(* Dimension atoms — building blocks for dimension arithmetic *)
dim_atom:
  | HASH name = IDENT { TyVar ("#" ^ name) }  (* Named: #N, #M *)
  | HASH n = INT { TyConstInt (Int64.to_int n) }  (* Literal: #3, #16 *)
  | n = INT { TyConstInt (Int64.to_int n) }       (* Bare literal: 3, 16 *)
  | LPAREN d = dim_expr RPAREN { d }              (* Parenthesized: (#N + 1) *)

(* Multiplicative dim: left-associative chaining.
   #N * 2 * 3 parses as (#N * 2) * 3. *)
dim_mul:
  | d = dim_atom { d }
  | a = dim_mul STAR b = dim_atom { TyDimOp (DimMul, a, b) }
  | a = dim_mul SLASH b = dim_atom { TyDimOp (DimDiv, a, b) }

(* Dimension expressions — additive with left-associative chaining.
   #S + #K - 1 parses as (#S + #K) - 1.
   Multiplication/division bind tighter: #N * 4 + 1 = (#N * 4) + 1. *)
dim_expr:
  | d = dim_mul { d }
  | a = dim_expr PLUS b = dim_mul { TyDimOp (DimAdd, a, b) }
  | a = dim_expr MINUS b = dim_mul { TyDimOp (DimSub, a, b) }

(* Expressions - using precedence declarations *)
expr:
  | e = assign_expr { e }

assign_expr:
  | lhs = postfix_expr EQUALS rhs = assign_expr
    { match lhs.expr_desc with
      | EIdent name -> make_expr_at $symbolstartpos (EAssign (name, rhs))
      | ESubscript (coll, idx) -> make_expr_at $symbolstartpos (ESubscriptAssign (coll, [idx], rhs))
      | ESubscriptMulti (coll, indices) -> make_expr_at $symbolstartpos (ESubscriptAssign (coll, indices, rhs))
      | ETuple exprs ->
        let names = List.map (fun e ->
          match e.expr_desc with
          | EIdent n -> n
          | EVoid -> "_"
          | _ -> parse_fail_at $symbolstartpos "Invalid tuple destructuring: elements must be identifiers or _"
        ) exprs in
        if List.length names > 4 then parse_fail_at $symbolstartpos "Tuples support 2-4 elements";
        make_expr_at $symbolstartpos (ETupleDestruct (names, rhs))
      | EFieldAccess _ -> parse_fail_at $symbolstartpos "Field assignment is not supported. Use record update syntax: { record | field = value }"
      | _ -> make_expr_at $symbolstartpos (EAssign ("_", rhs)) (* invalid LHS, caught by typechecker *)
    }
  | name = IDENT op = compound_op e = assign_expr
    { make_expr_at $symbolstartpos (ECompoundAssign (name, op, e)) }
  | e = ascription_expr { e }

%inline compound_op:
  | PLUS_EQ { AssignAdd }
  | MINUS_EQ { AssignSub }
  | STAR_EQ { AssignMul }
  | SLASH_EQ { AssignDiv }

ascription_expr:
  | e = or_expr AS ty = type_expr
    { make_expr_span $symbolstartpos $endpos (EAscription (e, ty)) }
  | e = or_expr { e }

or_expr:
  | left = or_expr OR newlines right = and_expr
    { make_expr_span $symbolstartpos $endpos (ELogical (Or, left, right)) }
  | e = and_expr { e } %prec EXPR_DONE

and_expr:
  | left = and_expr AND newlines right = cmp_expr
    { make_expr_span $symbolstartpos $endpos (ELogical (And, left, right)) }
  | e = cmp_expr { e } %prec EXPR_DONE

cmp_expr:
  | left = cmp_expr EQ newlines right = range_expr { make_binop_span $symbolstartpos $endpos Eq left right }
  | left = cmp_expr NE newlines right = range_expr { make_binop_span $symbolstartpos $endpos Ne left right }
  | left = cmp_expr LT newlines right = range_expr { make_binop_span $symbolstartpos $endpos Lt left right }
  | left = cmp_expr GT newlines right = range_expr { make_binop_span $symbolstartpos $endpos Gt left right }
  | left = cmp_expr LE newlines right = range_expr { make_binop_span $symbolstartpos $endpos Le left right }
  | left = cmp_expr GE newlines right = range_expr { make_binop_span $symbolstartpos $endpos Ge left right }
  | e = range_expr { e }

range_expr:
  | start_e = add_expr DOTDOT end_e = add_expr
    { make_expr_span $symbolstartpos $endpos (ERange (start_e, end_e)) }
  | e = add_expr { e } %prec EXPR_DONE

add_expr:
  (* Allow NEWLINE after operator for multi-line expressions *)
  | left = add_expr PLUS newlines right = mul_expr { make_binop_span $symbolstartpos $endpos Add left right }
  | left = add_expr MINUS newlines right = mul_expr { make_binop_span $symbolstartpos $endpos Sub left right }
  | e = mul_expr { e } %prec EXPR_DONE

mul_expr:
  | left = mul_expr STAR newlines right = unary_expr { make_binop_span $symbolstartpos $endpos Mul left right }
  | left = mul_expr SLASH newlines right = unary_expr { make_binop_span $symbolstartpos $endpos Div left right }
  | left = mul_expr PERCENT newlines right = unary_expr { make_binop_span $symbolstartpos $endpos Mod left right }
  | e = unary_expr { e }

unary_expr:
  | MINUS e = unary_expr { make_expr_span $symbolstartpos $endpos (EUnary (Neg, e)) }
  | NOT e = unary_expr { make_expr_span $symbolstartpos $endpos (EUnary (Not, e)) }
  | e = postfix_expr { e } %prec POSTFIX_REDUCE

postfix_expr:
  | e = postfix_expr DOT name = identifier { make_expr_at $symbolstartpos (EFieldAccess (e, name)) }
  | e = postfix_expr DOT n = INT { make_expr_at $symbolstartpos (EFieldAccess (e, Int64.to_string n)) }
  | callee = postfix_expr LPAREN args = trailing_list(COMMA, expr) RPAREN
    { make_expr_span $symbolstartpos $endpos (ECall (callee, args)) }
  | coll = postfix_expr LBRACKET idx_list = trailing_nonempty_list(COMMA, expr) RBRACKET
    { match idx_list with
      | [idx] -> make_expr_span $symbolstartpos $endpos (ESubscript (coll, idx))
      | _ -> make_expr_span $symbolstartpos $endpos (ESubscriptMulti (coll, idx_list)) }
  | e = primary_expr { e }

primary_expr:
  | n = INT { make_expr_span $symbolstartpos $endpos (ELiteral (LitInt n)) }
  | n = BIGINT { make_expr_span $symbolstartpos $endpos (ELiteral (LitInt128 n)) }
  | f = FLOAT { make_expr_span $symbolstartpos $endpos (ELiteral (LitFloat f)) }
  | s = STRING { make_expr_span $symbolstartpos $endpos (ELiteral (LitString (s, { sf_triple = false; sf_raw = false }))) }
  | s = STRING_RAW { make_expr_span $symbolstartpos $endpos (ELiteral (LitString (s, { sf_triple = false; sf_raw = true }))) }
  | s = TRIPLE_STRING { make_expr_span $symbolstartpos $endpos (ELiteral (LitString (s, { sf_triple = true; sf_raw = false }))) }
  | s = STRING_INTERP { make_expr_span $symbolstartpos $endpos (EStringInterpRaw (s, false)) }
  | s = TRIPLE_STRING_INTERP { make_expr_span $symbolstartpos $endpos (EStringInterpRaw (s, true)) }
  | c = CHAR { make_expr_span $symbolstartpos $endpos (ELiteral (LitChar c)) }
  | TRUE { make_expr_span $symbolstartpos $endpos (ELiteral (LitBool true)) }
  | FALSE { make_expr_span $symbolstartpos $endpos (ELiteral (LitBool false)) }
  | name = IDENT { make_expr_span $symbolstartpos $endpos (EIdent name) }
  | DEBUG { make_expr_span $symbolstartpos $endpos (EIdent "debug") }
  | UNDERSCORE { make_expr_at $symbolstartpos EVoid }
  | VOID_KW { make_expr_at $symbolstartpos EVoid }
  | BREAK { make_expr_at $symbolstartpos EBreak }
  | CONTINUE { make_expr_at $symbolstartpos EContinue }
  | BUILTIN LPAREN cname = STRING RPAREN
    { make_expr_at $symbolstartpos (EBuiltin (Some cname)) }  (* builtin("cname"): synthesized body that forwards params to the named C runtime helper *)
  | BUILTIN { make_expr_at $symbolstartpos (EBuiltin None) } %prec BUILTIN_BARE  (* builtin is a placeholder for compiler-provided implementation *)
  | LPAREN RPAREN { make_expr_span $symbolstartpos $endpos (ELiteral (LitInt 0L)) }  (* Void - placeholder *)
  | LPAREN e = expr RPAREN { e }
  | LPAREN e1 = expr COMMA es = trailing_nonempty_list(COMMA, expr) RPAREN
    { let all = e1 :: es in
      if List.length all > 4 then parse_fail_at $symbolstartpos "Tuples support 2-4 elements";
      make_expr_span $symbolstartpos $endpos (ETuple all) }
  | lambda = lambda_expr { lambda }
  | LBRACKET elems = trailing_list(COMMA, expr) RBRACKET { make_expr_span $symbolstartpos $endpos (EList elems) }
  | LBRACE pairs = trailing_nonempty_list(COMMA, dict_pair) RBRACE
    { make_expr_span $symbolstartpos $endpos (EDict pairs) }
  | LBRACE fields = trailing_list(COMMA, record_field) RBRACE
    { make_expr_span $symbolstartpos $endpos (ERecord fields) }
  | LBRACE base = or_expr PIPE updates = trailing_nonempty_list(COMMA, record_field) RBRACE
    { make_expr_span $symbolstartpos $endpos (ERecordUpdate (base, updates)) }
  | LBRACE elems = trailing_nonempty_list(COMMA, vector_elem_expr) RBRACE
    { make_expr_span $symbolstartpos $endpos (EVector elems) }
  (* If with optional else clause — supports arbitrary else-if chains *)
  | IF cond = expr COLON NEWLINE INDENT then_stmts = stmt_list DEDENT ec = else_clause
    { make_expr_at $symbolstartpos (EIf (cond, stmts_to_expr then_stmts, ec)) }
  (* Error: if without colon *)
  | IF expr NEWLINE
    { parse_fail_at $startpos($3) "Expected ':' after if condition" }
  | MATCH scrutinee = expr COLON NEWLINE INDENT cases = match_case_list DEDENT
    { make_expr_at $symbolstartpos (EMatch (scrutinee, cases)) }
  (* Error: match without colon *)
  | MATCH expr NEWLINE
    { parse_fail_at $startpos($3) "Expected ':' after match expression" }
  | TRY COLON NEWLINE INDENT stmts = stmt_list DEDENT
    { let _ = stmts in
      parse_fail_at $symbolstartpos
        "try: blocks have been removed; use `name ?= expr` directly in a function returning Option or Result." }
  (* Legacy error: try blocks were removed. Keep this narrow production so
     existing code gets the same migration guidance even when the colon is
     missing. *)
  | TRY NEWLINE
    { parse_fail_at $symbolstartpos
        "try: blocks have been removed; use `name ?= expr` directly in a function returning Option or Result." }
  | WITH with_binding COMMA
    { parse_fail_at $startpos($3)
        "Multiple resource bindings in one `with` header are not supported yet. Nested `with` blocks make resource close order explicit." }
  | WITH binding = with_binding COLON NEWLINE INDENT body = stmt_list DEDENT
    { make_expr_at $symbolstartpos (EWith (binding, stmts_to_expr_at $startpos(body) body)) }
  | WITH with_binding NEWLINE
    { parse_fail_at $startpos($3) "Expected ':' after with binding" }
  | FOR name = IDENT IN iter = expr CONCURRENTLY LPAREN params = concurrently_loop_params RPAREN COLON NEWLINE INDENT body = stmt_list DEDENT
    { make_expr_at $symbolstartpos
        (EConcurrentFor
           ( name,
             iter,
             stmts_to_expr body,
             params.loop_timeout,
             concurrent_for_width_of_limit
               (loc_of_pos $startpos(params))
               params )) }
  | FOR UNDERSCORE IN iter = expr CONCURRENTLY LPAREN params = concurrently_loop_params RPAREN COLON NEWLINE INDENT body = stmt_list DEDENT
    { make_expr_at $symbolstartpos
        (EConcurrentFor
           ( "_",
             iter,
             stmts_to_expr body,
             params.loop_timeout,
             concurrent_for_width_of_limit
               (loc_of_pos $startpos(params))
               params )) }
  | FOR name = IDENT IN iter = expr CONCURRENTLY COLON NEWLINE INDENT body = stmt_list DEDENT
    { let _ = (name, iter, body) in
      parse_fail_at $startpos($6)
        "`for ... concurrently` requires options; write `for x in xs concurrently(limit: N):`" }
  (* concurrent: block — no timeout *)
  (* concurrent: block — no params *)
  | CONCURRENT COLON NEWLINE INDENT stmts = stmt_list DEDENT
    { make_expr_at $symbolstartpos (EConcurrent (stmts, None, None)) }
  (* concurrent(params): block — with named params *)
  | CONCURRENT LPAREN params = concurrent_params RPAREN COLON NEWLINE INDENT stmts = stmt_list DEDENT
    { make_expr_at $symbolstartpos (EConcurrent (stmts, params.conc_timeout, params.conc_max_threads)) }
  (* concurrent for — no params *)
  | CONCURRENT FOR name = IDENT IN iter = expr COLON NEWLINE INDENT body = stmt_list DEDENT
    { make_expr_at $symbolstartpos (EConcurrentFor (name, iter, stmts_to_expr body, None, ConcurrentForDefault)) }
  (* concurrent(params) for — with named params *)
  | CONCURRENT LPAREN params = concurrent_params RPAREN FOR name = IDENT IN iter = expr COLON NEWLINE INDENT body = stmt_list DEDENT
    { make_expr_at $symbolstartpos
        (EConcurrentFor
           ( name,
             iter,
             stmts_to_expr body,
             params.conc_timeout,
             concurrent_for_width_of_legacy params.conc_max_threads )) }
  | CONCURRENTLY COLON NEWLINE INDENT stmts = stmt_list DEDENT
    { let _ = stmts in
      parse_fail_at $symbolstartpos
        "Use `concurrent:` for fixed concurrent blocks; `concurrently(...)` is only a for-loop modifier." }
  (* detach expr — detach on thread pool *)
  | DETACH body = unary_expr
    { make_expr_at $symbolstartpos (EDetach body) }
(* Named parameters for concurrent blocks: max_threads: N, timeout: expr *)
concurrent_param:
  | name = IDENT COLON value = expr
    { (name, value) }

concurrent_params:
  | p = concurrent_param
    { let (name, value) = p in
      match name with
      | "max_threads" ->
          (match value.expr_desc with
           | ELiteral (LitInt n) ->
               {
                 conc_timeout = None;
                 conc_max_threads =
                   Some (concurrent_max_threads_or_error value.expr_loc n);
               }
           | _ -> raise (Parse_error_at (value.expr_loc, "max_threads must be an integer literal")))
      | "timeout" -> { conc_timeout = Some value; conc_max_threads = None }
      | _ -> raise (Parse_error_at (value.expr_loc, Printf.sprintf "unknown concurrent parameter '%s' (expected 'max_threads' or 'timeout')" name)) }
  | p1 = concurrent_param COMMA p2 = concurrent_param
    { let apply params (name, value) =
        match name with
        | "max_threads" ->
            if params.conc_max_threads <> None then
              raise (Parse_error_at (value.expr_loc, "duplicate max_threads parameter"))
            else (match value.expr_desc with
              | ELiteral (LitInt n) ->
                  {
                    params with
                    conc_max_threads =
                      Some (concurrent_max_threads_or_error value.expr_loc n);
                  }
              | _ -> raise (Parse_error_at (value.expr_loc, "max_threads must be an integer literal")))
        | "timeout" ->
            if params.conc_timeout <> None then
              raise (Parse_error_at (value.expr_loc, "duplicate timeout parameter"))
            else { params with conc_timeout = Some value }
        | _ -> raise (Parse_error_at (value.expr_loc, Printf.sprintf "unknown concurrent parameter '%s'" name))
      in
      let init = { conc_timeout = None; conc_max_threads = None } in
      apply (apply init p1) p2 }

concurrently_loop_param:
  | name = IDENT COLON value = expr
    { (name, value) }

concurrently_loop_params:
  | params = separated_nonempty_list(COMMA, concurrently_loop_param)
    { let init = { loop_timeout = None; loop_limit = None } in
      let parsed = List.fold_left apply_concurrently_loop_param init params in
      match parsed.loop_limit with
      | Some _ -> parsed
      | None ->
          raise
            (Parse_error_at
               (loc_of_pos $symbolstartpos,
                "`for ... concurrently(...)` requires `limit: N`")) }

record_field:
  | name = identifier EQUALS e = expr { (name, e) }

dict_pair:
  | k = or_expr FATARROW v = expr { (k, v) }

vector_elem_expr:
  | e = or_expr { e }

else_clause:
  | (* empty *) { None }
  | ELSE COLON NEWLINE INDENT else_stmts = stmt_list DEDENT
    { Some (stmts_to_expr else_stmts) }
  | ELSE IF cond = expr COLON NEWLINE INDENT then_stmts = stmt_list DEDENT ec = else_clause
    { Some (make_expr_at $symbolstartpos (EIf (cond, stmts_to_expr then_stmts, ec))) }
  (* Error: else without colon *)
  | ELSE NEWLINE
    { parse_fail_at $startpos($2) "Expected ':' after else" }

match_case_list:
  | newlines cs = match_case_list_nonempty { cs }

match_case_list_nonempty:
  | c = match_case rest = match_case_list_tail { c :: rest }

match_case_list_tail:
  | NEWLINE newlines rest = match_case_list_after_newline { rest }
  | c = match_case rest = match_case_list_tail { c :: rest }  (* After DEDENT, no NEWLINE *)
  | { [] }

match_case_list_after_newline:
  | rest = match_case_list_nonempty { rest }
  | { [] }

match_case:
  | p = pattern COLON e = expr { { case_pattern = p; case_body = e; case_loc = loc_of_pos $symbolstartpos } }
  (* Multi-line match case body *)
  | p = pattern COLON NEWLINE INDENT stmts = stmt_list DEDENT
    { { case_pattern = p; case_body = make_expr (EBlock stmts); case_loc = loc_of_pos $symbolstartpos } }
  (* Error: -> instead of : in match arm *)
  | pattern ARROW
    { parse_fail_at $startpos($2) "Use ':' not '->' in match arms. Write 'pattern: body'" }

pattern:
  | p = simple_pattern { p }
  | p1 = simple_pattern PIPE ps = separated_nonempty_list(PIPE, simple_pattern)
    { PatOr (p1 :: ps) }

simple_pattern:
  | UNDERSCORE { PatWildcard }
  | name = IDENT { PatVar name }
  | n = INT { PatLiteral (LitInt n) }
  | n = BIGINT { PatLiteral (LitInt128 n) }
  | MINUS n = INT { PatLiteral (LitInt (Int64.neg n)) }
  | f = FLOAT { PatLiteral (LitFloat f) }
  | MINUS f = FLOAT { PatLiteral (LitFloat (-. f)) }
  | s = STRING { PatLiteral (LitString (s, { sf_triple = false; sf_raw = false })) }
  | s = TRIPLE_STRING { PatLiteral (LitString (s, { sf_triple = true; sf_raw = false })) }
  | c = CHAR { PatLiteral (LitChar c) }
  | TRUE { PatLiteral (LitBool true) }
  | FALSE { PatLiteral (LitBool false) }
  | name = IDENT LPAREN ps = trailing_list(COMMA, pattern) RPAREN
    { PatConstructor (name, ps) }
  | LPAREN p1 = pattern COMMA ps = trailing_nonempty_list(COMMA, pattern) RPAREN
    { let all = p1 :: ps in
      if List.length all > 4 then parse_fail_at $symbolstartpos "Tuples support 2-4 elements";
      PatTuple all }
  (* Qualified patterns: O.Some(x), O.None *)
  | mod_name = IDENT DOT ctor_name = IDENT LPAREN ps = trailing_list(COMMA, pattern) RPAREN
    { PatQualified (mod_name, ctor_name, ps) }
  | mod_name = IDENT DOT ctor_name = IDENT
    { PatQualified (mod_name, ctor_name, []) }
  (* List patterns: [], [x], [x, y], [x, ...rest], [...rest], [..._] *)
  | LBRACKET RBRACKET
    { PatList ([], None) }
  | LBRACKET DOTDOTDOT sp = spread_target RBRACKET
    { PatList ([], Some sp) }
  | LBRACKET p = pattern rest = list_pattern_rest RBRACKET
    { let (elems, spread) = rest in PatList (p :: elems, spread) }

spread_target:
  | name = IDENT { PatVar name }
  | UNDERSCORE { PatWildcard }

list_pattern_rest:
  | (* empty *) { ([], None) }
  | COMMA DOTDOTDOT sp = spread_target { ([], Some sp) }
  | COMMA p = pattern rest = list_pattern_rest
    { let (elems, spread) = rest in (p :: elems, spread) }

lambda_body:
  | e = or_expr { e } %prec EXPR_DONE
  | NEWLINE INDENT stmts = stmt_list DEDENT { make_expr (EBlock stmts) }

lambda_expr:
  | p = lambda_purity LPAREN ps = trailing_list(COMMA, lambda_param) RPAREN
	    ret = return_type_opt COLON body = lambda_body
	    { make_expr_at $symbolstartpos (ELambda (
	        mk_func ~dim_constraints:[] ~is_pure:p ~name:None ~tparams:[] ~params:ps
	          ~ret ~body:(FuncBodyExpr body) ~annots:[])) }

lambda_param:
  | name = IDENT COLON ty = type_expr
    { { param_name = Some name; param_pattern = None; param_type = Some ty; param_passing = ParamByValue; param_loc = loc_of_pos $symbolstartpos } }
  | name = IDENT
    { { param_name = Some name; param_pattern = None; param_type = None; param_passing = ParamByValue; param_loc = loc_of_pos $symbolstartpos } }
  (* Underscore as discard parameter *)
  | UNDERSCORE COLON ty = type_expr
    { { param_name = Some "_"; param_pattern = None; param_type = Some ty; param_passing = ParamByValue; param_loc = loc_of_pos $symbolstartpos } }
  | UNDERSCORE
    { { param_name = Some "_"; param_pattern = None; param_type = None; param_passing = ParamByValue; param_loc = loc_of_pos $symbolstartpos } }
