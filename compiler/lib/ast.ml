(** AST Type Definitions for blorp *)

type loc = {
  line : int;
  column : int;
  end_line : int;
  end_column : int;
  loc_file : string option;
}
(** Source location — optionally a span with end position.

    [loc_file] identifies the source file the location came from. It is
    [None] for dummy/synthesized locs (pre-parse bootstrap, codegen stubs,
    tests, etc.). Diagnostics prefer [loc_file] over the current
    compilation unit's filename so cross-file references (e.g. "previously
    implemented at std/int.brp:79:1" in a coherence error) cite the
    correct file. *)

(** Create a point location (no span, no file). For locations that
    should carry a source file, use [point_loc_in]. *)
let point_loc ~line ~column =
  { line; column; end_line = line; end_column = column; loc_file = None }

(** Create a point location with a specific source file. *)
let point_loc_in ~file ~line ~column =
  { line; column; end_line = line; end_column = column; loc_file = Some file }

let dummy_loc =
  { line = 0; column = 0; end_line = 0; end_column = 0; loc_file = None }

exception Parse_error_at of loc * string
(** Raised by parser actions with accurate source location *)

(** Dimension arithmetic operators *)
type dim_op = DimAdd | DimSub | DimMul | DimDiv

type type_param_decl = Generic_params.bound_type_param = {
  param_name : string;
  param_bounds : Generic_params.trait_ref list;
}
(** Generic type parameter declaration at the source/AST boundary. *)

let make_type_param name bounds =
  Generic_params.make_bound_type_param name bounds

let type_param_name param = param.param_name
let type_param_names params = Generic_params.param_names params
let type_param_to_parser_string = Generic_params.to_parser_string

(** Type expressions *)
type type_expr =
  | TyNamed of string * type_expr list
      (** Named type with optional type args *)
  | TyArray of type_expr * type_expr list
      (** Postfix array type: T[#N] / T[#M, #N] *)
  | TyFunc of { params : type_expr list; return : type_expr; is_pure : bool }
      (** Function type *)
  | TyVar of string  (** Type variable/parameter *)
  | TyBoundVar of type_param_decl
      (** Type variable with inline trait bounds in declaration type positions *)
  | TyConstInt of int  (** Const literal in type context (e.g., Int[#5]) *)
  | TyTuple of type_expr list  (** Tuple type (2-4 elements) *)
  | TySelf
      (** Self type - resolved to implementing type in trait/impl context *)
  | TyVarDims of string
      (** Variadic dimension variable — named for identity; ?? gets fresh names, #N... is explicit *)
  | TyRange of type_expr
      (** Range type ..#N — integer in [0, N), erases to long *)
  | TyDimOp of dim_op * type_expr * type_expr
      (** Dimension arithmetic: #M + #N or #M * #N *)
  | TyMeta of int
      (** Unification variable — fresh, distinct from rigid [TyVar] *)

(** Binary operators *)
type binop = Add | Sub | Mul | Div | Mod | Lt | Gt | Le | Ge | Eq | Ne

(** Explicit type-widening metadata carried during the typed-AST transition. *)
type type_widening_collection_kind =
  | ListLiteral
  | VectorLiteral
  | DictLiteral
  | SetLiteral

type type_widening_reason =
  | MutableBinding
  | ArgumentSlot
  | CollectionElement of type_widening_collection_kind
  | BitwiseOperator
  | MethodReceiver
  | NumericOperator of binop

type type_widening_decision =
  | Keep of type_expr
  | Widen of {
      from_ty : type_expr;
      to_ty : type_expr;
      reason : type_widening_reason;
    }

type expr_type_origin =
  | ExplicitAnnotation of type_expr
  | Inferred
  | Synthesized of string

type call_syntax =
  | CallBare
  | CallQualified of string
  | CallMethod
  | CallMethodOnlyUfcs
  | CallClosureSyntax
  | CallTraitDispatch

type callable_origin =
  | CallableLocal
  | CallableImported of string
  | CallableBuiltin
  | CallableForeign
  | CallableConstructor of string
  | CallableImplMethod

type resolved_call_target =
  | CallDirect of {
      callable_id : int;
      source_name : string;
      call_pure : bool;
      origin : callable_origin;
    }
  | CallTraitMethod of {
      trait_name : string;
      method_name : string;
      call_pure : bool;
      callable_id : int option;
    }
  | CallClosure of { call_pure : bool }

type resolved_call = {
  call_syntax : call_syntax;
  call_target : resolved_call_target;
  instantiated_params : type_expr list;
  instantiated_return : type_expr;
}

type expr_type_info = {
  source_ty : type_expr option;
  semantic_ty : type_expr;
  value_ty : type_expr;
  origin : expr_type_origin;
  widening : type_widening_decision;
  proofs : Type_proof_metadata.expr_proofs;
  resolved_call : resolved_call option;
}

(** Unary operators *)
type unop = Neg | Not

(** Logical operators *)
type logop = And | Or

(** Patterns for match expressions *)
type pattern =
  | PatWildcard  (** _ *)
  | PatVar of string  (** x *)
  | PatConstructor of string * pattern list  (** Some(x) *)
  | PatLiteral of literal  (** 42, "hello" *)
  | PatTuple of pattern list  (** (x, y) or (x, y, z) or (x, y, z, w) *)
  | PatQualified of string * string * pattern list
      (** O.Some(x) - module, ctor, args *)
  | PatList of pattern list * pattern option
      (** [a, b, ...rest] — fixed elems + optional spread *)
  | PatOr of pattern list  (** p1 | p2 | p3 — or-pattern *)

and string_flags = {
  sf_triple : bool;  (** Triple-quoted string """...""" *)
  sf_raw : bool;  (** Raw string r"..." — no escape processing *)
}
(** String literal flags *)

(** Literal values.

    Integer literals that fit in [int64] use [LitInt]. Larger decimal
    literals use [LitInt128] and carry their source digits so the compiler can
    infer [Int128] without truncating through a host-sized integer. *)
and literal =
  | LitInt of int64
  | LitInt128 of string
  | LitFloat of float
  | LitString of string * string_flags  (** content * flags *)
  | LitBool of bool
  | LitChar of int  (** Unicode codepoint *)

(** Ownership: who is responsible for releasing this value?
    Computed by the ownership annotation pre-pass. *)
type ownership =
  | Owned  (** Fresh allocation — caller must release *)
  | Borrowed  (** Reference into existing structure — do NOT release *)
  | Mixed  (** if/match with owned + borrowed branches — needs normalization *)

type rc_annotation = {
  rc_managed : bool;
      (** Type is reference-counted: String/List/Dict/Tensor/Record/Closure/Tuple/etc. *)
  rc_cow : bool;
      (** Type uses COW semantics: String/List/Dict/Tensor/non-value records *)
  rc_alias : bool;
      (** Expression is an alias (not fresh): EIdent | EFieldAccess *)
  rc_ownership : ownership;  (** Ownership of this expression's result *)
}
(** RC annotation computed by pre-codegen pass from type information.
    None on expr means "unknown" — codegen falls back to existing heuristics. *)

type expr = {
  expr_desc : expr_desc;
  expr_loc : loc;
  expr_type : type_expr option;  (** Inferred type after type checking *)
  expr_type_info : expr_type_info option;
      (** Transitional typed payload preserving semantic/value-slot split. *)
  expr_rc : rc_annotation option;  (** RC annotation from pre-codegen pass *)
}
(** Expressions *)

and expr_desc =
  | EIdent of string
  | ELiteral of literal
  | EBinary of binop * expr * expr
  | EUnary of unop * expr
  | ELogical of logop * expr * expr
  | EAscription of expr * type_expr
  | ECall of expr * expr list
  | EIf of expr * expr * expr option  (** condition, then, else *)
  | EMatch of expr * match_case list
  | EBlock of expr list
  | ETuple of expr list
  | EVector of expr list
  | EList of expr list
  | ERecord of (string * expr) list
  | ERecordUpdate of
      expr * (string * expr) list (* { base | field = val, ... } *)
  | EFieldAccess of expr * string
  | ELambda of func_decl
  | EVoid
  | EWhile of expr * expr  (** condition, body *)
  | EFor of string * expr * expr  (** var, iterable, body *)
  | EForTuple of string list * expr * expr  (** tuple binders, iterable, body *)
  | ELoopView of loop_view
      (** Internal typed loop-view producer. Parser never emits this; inference
        rewrites recognized loop-only collection combinators into this node so
        lowering consumes explicit producer metadata instead of re-matching
        source call names. *)
  | EAssign of string * expr  (** var = value (reassignment) *)
  | EVarDecl of string * type_expr option * expr * bool
      (** name, type, value, is_mutable *)
  | ETupleDestruct of string list * expr
      (** (a, b) = expr or (a, b, c) = expr *)
  | ERange of expr * expr  (** start..end (exclusive) *)
  | EBreak
  | EContinue
  | ESubscript of expr * expr  (** collection[index] *)
  | ESubscriptMulti of expr * expr list
      (** tensor[i, j, ...] — multi-index access *)
  | ESubscriptAssign of expr * expr list * expr
      (** tensor[i, j, ...] = val — subscript mutation *)
  | EStringInterp of string_interp_part list * bool
      (** parts * is_triple_quoted *)
  | EStringInterpRaw of string * bool  (** raw_content * is_triple_quoted *)
  | EQuestionBind of string * type_expr option * expr
      (** name ?= expr — propagate Option/Result from the enclosing block *)
  | EWith of with_binding * expr
      (** with name = expr: body / with name ?= expr: body — scoped resource
          syntax. The parser represents it explicitly before resource cleanup
          semantics are implemented. *)
  | EDebugBlock of expr list
      (** debug: block — diagnostics-only statements that return Void *)
  | EConcurrent of expr list * expr option * int option
      (** concurrent: block — bindings, optional timeout_ms expr, optional max_threads *)
  | EConcurrentBind of string * type_expr option * expr
      (** name = expr — concurrent task binding *)
  | EConcurrentFor of string * expr * expr * expr option * int option
      (** var, iterable, body, optional timeout, optional max_threads *)
  | EDetach of expr  (** detach expr — detach on thread pool *)
  | EDict of (expr * expr) list  (** {"key" => val, ...} — dict literal *)
  | EBuiltin of string option
      (** Parser-level compiler-provided body marker.
        [EBuiltin None] — sentinel for [builtin]. The function declaration
        parser converts this to [FuncBuiltinBody (BuiltinIntrinsic, _)] when
        it is the whole function body; this node should never reach
        [Core_lower].
        [EBuiltin (Some c_name)] — [builtin("c_name")]. Lowering synthesizes
        a [CCall (CKBuiltin c_name, ...)] body that forwards all parameters
        to the named C runtime helper from [FuncBuiltinBody]. Distinct from
        [foreign func], which is reserved for user-facing FFI. *)
  | EFuncDecl of func_decl
      (** Nested function declaration in a block.
      Transient node produced by the parser for [pure func name[T](...)]
      appearing as a statement. Eliminated by the [nested-hoist] pre-infer
      pass: the nested function becomes a top-level [DFunc] with a
      mangled name, and call sites in the parent body are rewritten to
      reference the hoisted name. No pass after hoisting should see this
      constructor. *)

and with_binding_kind = WithPlain | WithTry

and with_binding = {
  with_name : string;
  with_type : type_expr option;
  with_value : expr;
  with_kind : with_binding_kind;
}

and loop_view_kind =
  | LoopIndices
      (** [indices(tensor)] in for-loop position: first-dimension indices. *)
  | LoopEnumerate
      (** [enumerate(tensor)] in for-loop position: index + value/peeled row. *)
  | LoopEnumerate2
      (** [enumerate2(matrix)] in for-loop position: row, col, scalar. *)
  | LoopWindows of int
      (** [windows(vector, K)] in for-loop position. The int is the proven
        positive window size. *)

and loop_view = {
  loop_view_kind : loop_view_kind;
  loop_view_source : expr;
  loop_view_size_arg : expr option;
      (** Original size expression for [windows]. Kept for locations/traversal;
        the proven positive literal is carried by [LoopWindows]. *)
  loop_view_elem_type : type_expr;
      (** Element type yielded by the loop producer. For tuple loops this is a
        tuple type. *)
}

(** String interpolation part *)
and string_interp_part =
  | InterpLit of string  (** Literal string part *)
  | InterpExpr of expr  (** Interpolated expression *)

and match_case = { case_pattern : pattern; case_body : expr; case_loc : loc }
(** Match case *)

and builtin_body =
  | BuiltinIntrinsic
      (** [builtin] — compiler intrinsic body synthesized by lowering. *)
  | BuiltinRuntime of string
      (** [builtin("c_name")] — direct runtime helper forwarding body. *)

and foreign_func = {
  foreign_name : string;
  foreign_includes : string list;
  foreign_link_flags : (string option * string) list;
}

and func_body =
  | FuncBodyExpr of expr
  | FuncBuiltinBody of builtin_body * loc
  | FuncForeign of foreign_func
  | FuncNoBody

and func_decl = {
  func_name : string option;  (** None for lambdas *)
  func_type_params : type_param_decl list;
  func_params : param list;
  func_return_type : type_expr option;
  func_body : func_body;
  func_is_pure : bool;
  func_is_tailrec : bool;
  func_no_copy : bool;  (** @no_copy annotation — skip FFI arg copying *)
  func_debug_only : bool;
      (** @debug_only annotation — usable only in debug contexts *)
  func_resource_result_ordinary : bool;
      (** @resource_result_ordinary annotation — builtin resource operation
          returns ordinary data, not a resource-dependent borrowed value. *)
  func_dim_constraints : (type_expr * type_expr) list;
      (** Dimension constraints from [where] clause.
      Each pair [(lhs, rhs)] represents the equality [lhs == rhs].
      Checked at call sites with concrete values; registered as Givens
      (substitutions) when type-checking the function body. *)
}
(** Function declaration *)

and param_passing =
  | ParamByValue
  | ParamBorrow
      (** Borrowed resource parameter. The function may use the resource during
          the call but does not own cleanup and must not let resource-dependent
          values escape. *)

and param = {
  param_name : string option;  (** None for pattern params *)
  param_pattern : pattern option;  (** For tuple destructuring *)
  param_type : type_expr option;
  param_passing : param_passing;
  param_loc : loc;
}
(** Function parameter *)

type variant = {
  variant_name : string;
  variant_fields : type_expr list;
  variant_tag : int;
  variant_loc : loc;
  variant_def_id : int option;
      (** Canonical identity minted by [Session.mint_def_id] at type-decl
      registration (typecheck [process_type_decl] and [env_builtins]
      for stdlib unions). Typed as [int] not [Env_types.def_id] to
      avoid a circular dependency — [env_types] already opens [Ast].
      [None] means "not yet decorated by typecheck" (parser-constructed
      variants). Downstream passes (codegen, diagnostics) should always
      see [Some] by the time they read it. *)
}
(** Union/ADT variant *)

type resource_cleanup =
  | ResourceCleanupBuiltin of string
      (** Compiler/runtime cleanup builtin emitted for scoped resource cleanup. *)

type type_decl = {
  type_name : string;
  type_params : type_param_decl list;
  type_variants : variant list;
  type_is_enum : bool;
      (** true for enum declarations — integer-valued, no fields *)
  type_is_builtin : bool;
      (** true for [type Name = builtin] — primitive type whose
                              representation + operations are compiler-provided.
                              Has no variants; serves as a visible declaration so
                              stdlib can document primitives like Int, Float, etc. *)
  type_is_resource : bool;
      (** true for [resource type Name = builtin] — scoped external
          capabilities that must be acquired through [with] before cleanup
          lowering can own their close edge. Resource types are also builtin
          for representation/codegen purposes. *)
  type_resource_cleanup : resource_cleanup option;
      (** Optional compiler-owned cleanup metadata for resource types. [None]
          means cleanup lowers through the normal [close(handle)] resource
          trait path; [Some (ResourceCleanupBuiltin name)] means lowering owns
          a direct runtime builtin cleanup edge. *)
}
(** Type declaration (union/ADT/enum/builtin primitive) *)

type field_decl = {
  field_name : string;
  field_type : type_expr;
  field_loc : loc;
}
(** Record field declaration *)

type record_decl = {
  record_name : string;
  record_type_params : type_param_decl list;
  record_fields : field_decl list;
  record_is_value : bool;
      (** true for struct (stack-allocated value type), false for record *)
  record_is_builtin : bool;
      (** true for builtin types (List, Dict, etc.) defined in std/ *)
}
(** Record declaration *)

type var_decl = {
  var_name : string option;
  var_pattern : pattern option;
  var_type : type_expr option;
  var_value : expr;
  var_is_mutable : bool;
  var_is_const : bool;
}
(** Variable declaration *)

(** Constructor import mode for union types *)
type ctor_import =
  | CtorNone  (** No constructors (qualified access only: Type.Ctor) *)
  | CtorSome of string list  (** Named constructors: Type(Ctor1, Ctor2) *)

type import_symbol = {
  sym_name : string;  (** Original exported name *)
  sym_alias : string option;  (** Local alias (None = use original name) *)
  sym_ctors : ctor_import;  (** Constructor import mode for union types *)
}
(** A single imported symbol, optionally aliased *)

type import_decl = {
  import_module : string;
  import_symbols : import_symbol list option;  (** None for qualified imports *)
  import_alias : string option;
}
(** Import declaration *)

type trait_method = {
  method_name : string;
  method_params : param list;  (** Regular params, may use Self type *)
  method_return_type : type_expr option;
  method_is_pure : bool;
  method_default_body : expr option;  (** For default implementations *)
}
(** Trait method signature - for new trait system *)

type trait_decl = {
  trait_name : string;
  trait_type_params : type_param_decl list;
      (** For traits like Iterator[Item] *)
  trait_supertraits : string list;
  trait_methods : trait_method list;
      (** Method signatures with optional default impls *)
}
(** Trait declaration - Rust-style with method signatures *)

type impl_decl = {
  impl_trait : string;  (** Trait being implemented *)
  impl_for_type : type_expr;  (** Type implementing the trait *)
  impl_methods : func_decl list;  (** Method implementations *)
}
(** Impl declaration - Rust-style impl Trait for Type *)

type type_alias_decl = {
  alias_name : string;
  alias_type_params : type_param_decl list;
  alias_target : type_expr;
}
(** Type alias declaration *)

(** Top-level declarations *)
type decl_desc =
  | DFunc of func_decl
  | DType of type_decl
  | DRecord of record_decl
  | DVar of var_decl
  | DImport of import_decl
  | DPrivate of decl
  | DTrait of trait_decl
  | DImpl of impl_decl
  | DTypeAlias of type_alias_decl

and decl = { decl_desc : decl_desc; decl_loc : loc; decl_doc : string option }

type program = decl list
(** A program is a list of declarations *)

(** Compatibility constructor for transitional typed AST payloads.

    Long term, parsed AST nodes should not carry typed payloads. While the
    compiler migrates phase-by-phase, keep legacy [expr_type] and structured
    [expr_type_info] construction in one place so call sites do not rebuild
    subtly different payloads. *)
let expr_type_info_from_type ty : expr_type_info =
  {
    source_ty = None;
    semantic_ty = ty;
    value_ty = ty;
    origin = Inferred;
    widening = Keep ty;
    proofs = Type_proof_metadata.unproven_expr;
    resolved_call = None;
  }

let untyped_expr ~loc desc =
  {
    expr_desc = desc;
    expr_loc = loc;
    expr_type = None;
    expr_type_info = None;
    expr_rc = None;
  }

let with_untyped_expr_desc expr desc =
  { expr with expr_desc = desc; expr_type = None; expr_type_info = None }

let with_expr_type_info expr info =
  { expr with expr_type = Some info.semantic_ty; expr_type_info = Some info }

let with_expr_resolved_call expr resolved_call =
  match expr.expr_type_info with
  | Some info ->
      with_expr_type_info expr { info with resolved_call = Some resolved_call }
  | None -> expr

let resolved_call_purity call =
  match call.call_target with
  | CallDirect { call_pure; _ }
  | CallTraitMethod { call_pure; _ }
  | CallClosure { call_pure } ->
      call_pure

let resolved_call_direct_callable_id call =
  match call.call_target with
  | CallDirect { callable_id; _ } -> Some callable_id
  | CallTraitMethod _ | CallClosure _ -> None

let resolved_call_concrete_callable_id call =
  match call.call_target with
  | CallDirect { callable_id; _ } -> Some callable_id
  | CallTraitMethod { callable_id; _ } -> callable_id
  | CallClosure _ -> None

let expr_resolved_call expr =
  Option.bind expr.expr_type_info (fun info -> info.resolved_call)

let expr_concrete_callable_id expr =
  Option.bind (expr_resolved_call expr) resolved_call_concrete_callable_id

let map_expr_type_origin f = function
  | ExplicitAnnotation ty -> ExplicitAnnotation (f ty)
  | Inferred -> Inferred
  | Synthesized source -> Synthesized source

let map_type_widening_decision f = function
  | Keep ty -> Keep (f ty)
  | Widen { from_ty; to_ty; reason } ->
      Widen { from_ty = f from_ty; to_ty = f to_ty; reason }

let map_resolved_call f call =
  {
    call with
    instantiated_params = List.map f call.instantiated_params;
    instantiated_return = f call.instantiated_return;
  }

let map_expr_type_info f info =
  {
    source_ty = Option.map f info.source_ty;
    semantic_ty = f info.semantic_ty;
    value_ty = f info.value_ty;
    origin = map_expr_type_origin f info.origin;
    widening = map_type_widening_decision f info.widening;
    proofs = info.proofs;
    resolved_call = Option.map (map_resolved_call f) info.resolved_call;
  }

let map_expr_type_payload f expr =
  {
    expr with
    expr_type = Option.map f expr.expr_type;
    expr_type_info = Option.map (map_expr_type_info f) expr.expr_type_info;
  }

let func_body_expr_opt = function
  | FuncBodyExpr body -> Some body
  | FuncBuiltinBody _ | FuncForeign _ | FuncNoBody -> None

let map_func_body_expr f = function
  | FuncBodyExpr body -> FuncBodyExpr (f body)
  | FuncBuiltinBody _ as body -> body
  | FuncForeign _ as body -> body
  | FuncNoBody -> FuncNoBody

let func_is_foreign f =
  match f.func_body with FuncForeign _ -> true | _ -> false

let func_foreign_info f =
  match f.func_body with FuncForeign info -> Some info | _ -> None

let func_has_builtin_body f =
  match f.func_body with FuncBuiltinBody _ -> true | _ -> false

(** Return the immediate sub-expressions of an expression node.
    Useful for writing generic AST walkers without matching all 30+ variants.
    NOTE: Lambda bodies ARE included. Walkers that need to skip or scope-manage
    lambdas should handle ELambda explicitly before falling through to this. *)
let expr_children (e : expr) : expr list =
  match e.expr_desc with
  | EIdent _ | ELiteral _ | EVoid | EBuiltin _ | EBreak | EContinue
  | EStringInterpRaw _ ->
      []
  | EUnary (_, e)
  | EAscription (e, _)
  | EFieldAccess (e, _)
  | EAssign (_, e)
  | EQuestionBind (_, _, e)
  | EConcurrentBind (_, _, e) ->
      [ e ]
  | EBinary (_, l, r)
  | ELogical (_, l, r)
  | ERange (l, r)
  | EWhile (l, r)
  | EFor (_, l, r)
  | EForTuple (_, l, r)
  | ESubscript (l, r) ->
      [ l; r ]
  | ELoopView view ->
      view.loop_view_source
      :: (match view.loop_view_size_arg with Some e -> [ e ] | None -> [])
  | ECall (callee, args) -> callee :: args
  | EIf (cond, then_, else_) ->
      cond :: then_ :: (match else_ with Some e -> [ e ] | None -> [])
  | EMatch (scrutinee, cases) ->
      scrutinee :: List.map (fun c -> c.case_body) cases
  | EBlock exprs
  | EVector exprs
  | EList exprs
  | ETuple exprs
  | EDebugBlock exprs
  | EConcurrent (exprs, None, _) ->
      exprs
  | EConcurrent (exprs, Some timeout, _) -> exprs @ [ timeout ]
  | EWith (binding, body) -> [ binding.with_value; body ]
  | ERecord fields -> List.map snd fields
  | ERecordUpdate (base, fields) -> base :: List.map snd fields
  | ELambda func -> (
      match func_body_expr_opt func.func_body with
      | Some b -> [ b ]
      | None -> [])
  | EVarDecl (_, _, init, _) | ETupleDestruct (_, init) -> [ init ]
  | ESubscriptMulti (coll, indices) -> coll :: indices
  | ESubscriptAssign (coll, indices, value) -> coll :: (indices @ [ value ])
  | EStringInterp (parts, _) ->
      List.filter_map
        (function InterpLit _ -> None | InterpExpr e -> Some e)
        parts
  | EConcurrentFor (_, iter, body, None, _) -> [ iter; body ]
  | EConcurrentFor (_, iter, body, Some timeout, _) -> [ iter; body; timeout ]
  | EDetach body -> [ body ]
  | EDict pairs -> List.concat_map (fun (k, v) -> [ k; v ]) pairs
  | EFuncDecl func -> (
      match func_body_expr_opt func.func_body with
      | Some b -> [ b ]
      | None -> [])

(** Map a function over the immediate sub-expressions of an expression node,
    returning a new expression with the same structure but transformed children.
    Useful for writing generic AST transforms without matching all 30+ variants.
    NOTE: Lambda bodies ARE included. Transforms that need to skip or scope-manage
    lambdas should handle ELambda explicitly before falling through to this. *)
let expr_map_children (f : expr -> expr) (e : expr) : expr =
  let desc' =
    match e.expr_desc with
    | EIdent _ | ELiteral _ | EVoid | EBuiltin _ | EBreak | EContinue
    | EStringInterpRaw _ ->
        e.expr_desc
    | EUnary (op, e1) -> EUnary (op, f e1)
    | EAscription (e1, ty) -> EAscription (f e1, ty)
    | EFieldAccess (e1, field) -> EFieldAccess (f e1, field)
    | EAssign (name, e1) -> EAssign (name, f e1)
    | EQuestionBind (name, ty, e1) -> EQuestionBind (name, ty, f e1)
    | EConcurrentBind (name, ty, e1) -> EConcurrentBind (name, ty, f e1)
    | EBinary (op, l, r) -> EBinary (op, f l, f r)
    | ELogical (op, l, r) -> ELogical (op, f l, f r)
    | ERange (l, r) -> ERange (f l, f r)
    | EWhile (cond, body) -> EWhile (f cond, f body)
    | EFor (var, iter, body) -> EFor (var, f iter, f body)
    | EForTuple (vars, iter, body) -> EForTuple (vars, f iter, f body)
    | ELoopView view ->
        ELoopView
          {
            view with
            loop_view_source = f view.loop_view_source;
            loop_view_size_arg = Option.map f view.loop_view_size_arg;
          }
    | ESubscript (coll, idx) -> ESubscript (f coll, f idx)
    | ECall (callee, args) -> ECall (f callee, List.map f args)
    | EIf (cond, then_, else_) -> EIf (f cond, f then_, Option.map f else_)
    | EMatch (scrutinee, cases) ->
        EMatch
          ( f scrutinee,
            List.map (fun c -> { c with case_body = f c.case_body }) cases )
    | EBlock exprs -> EBlock (List.map f exprs)
    | EVector exprs -> EVector (List.map f exprs)
    | EList exprs -> EList (List.map f exprs)
    | ETuple exprs -> ETuple (List.map f exprs)
    | EDebugBlock exprs -> EDebugBlock (List.map f exprs)
    | EConcurrent (exprs, timeout, mt) ->
        EConcurrent (List.map f exprs, Option.map f timeout, mt)
    | EWith (binding, body) ->
        EWith ({ binding with with_value = f binding.with_value }, f body)
    | ERecord fields ->
        ERecord (List.map (fun (name, e1) -> (name, f e1)) fields)
    | ERecordUpdate (base, fields) ->
        ERecordUpdate (f base, List.map (fun (name, e1) -> (name, f e1)) fields)
    | ELambda func ->
        ELambda { func with func_body = map_func_body_expr f func.func_body }
    | EVarDecl (name, ty, init, is_mut) -> EVarDecl (name, ty, f init, is_mut)
    | ETupleDestruct (names, init) -> ETupleDestruct (names, f init)
    | ESubscriptMulti (coll, indices) ->
        ESubscriptMulti (f coll, List.map f indices)
    | ESubscriptAssign (coll, indices, value) ->
        ESubscriptAssign (f coll, List.map f indices, f value)
    | EStringInterp (parts, is_triple) ->
        EStringInterp
          ( List.map
              (function
                | InterpLit _ as lit -> lit | InterpExpr e1 -> InterpExpr (f e1))
              parts,
            is_triple )
    | EConcurrentFor (var, iter, body, timeout, mt) ->
        EConcurrentFor (var, f iter, f body, Option.map f timeout, mt)
    | EDetach body -> EDetach (f body)
    | EDict pairs -> EDict (List.map (fun (k, v) -> (f k, f v)) pairs)
    | EFuncDecl func ->
        EFuncDecl { func with func_body = map_func_body_expr f func.func_body }
  in
  { e with expr_desc = desc' }

(** Collect all variable names bound by a pattern (recursive) *)
let rec collect_pattern_vars = function
  | PatWildcard -> []
  | PatLiteral _ -> []
  | PatVar name -> [ name ]
  | PatConstructor (_, pats) -> List.concat_map collect_pattern_vars pats
  | PatQualified (_, _, pats) -> List.concat_map collect_pattern_vars pats
  | PatTuple pats -> List.concat_map collect_pattern_vars pats
  | PatList (pats, spread) ->
      let pat_vars = List.concat_map collect_pattern_vars pats in
      let spread_vars =
        match spread with Some pat -> collect_pattern_vars pat | None -> []
      in
      pat_vars @ spread_vars
  | PatOr (p :: _) ->
      collect_pattern_vars p (* All alternatives bind same vars *)
  | PatOr [] -> []

(** Phase in which a compiler error was produced *)
type error_phase = Parse | ModuleLoad | TypeCheck | Codegen

(** Structured error kind — used for reliable filtering in module type-checking.
    Only the categories that need programmatic matching are tagged explicitly;
    all other errors use OtherError. *)
type error_kind =
  | UndefinedIdent of string  (** name *)
  | NotExported of string * string  (** symbol, module *)
  | PrivateTypeLeak
  | OtherError

type compiler_error = {
  message : string;
  loc : loc;
  phase : error_phase;
  kind : error_kind;
  notes : string list;
  help : string option;
}
(** Compiler error — shared across all compilation phases *)
