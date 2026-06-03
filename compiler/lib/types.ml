(** Type Utilities for blorp Type Checker

    Provides type manipulation functions including:
    - Type variable generation
    - Substitution maps
    - Type comparison and compatibility
    - Type-to-string conversion
*)

open Ast

(** Check if a type variable name is a dimension parameter (#N, #M, etc.) *)
let is_dim_var name = String.length name > 0 && name.[0] = '#'

type subst_entry = { var_name : string; concrete_type : type_expr }
(** Type substitution map entry *)

type subst_map = subst_entry list
(** Type substitution map *)

(* ============================================================================
   Metavariable environment (HM unification variables)
   ============================================================================

   [TyMeta n] is a unification variable with unique integer identity. Unlike
   rigid [TyVar] (user-declared type parameters, opaque within a function
   body), metas are bound during unification to concrete types or to other
   metas (forming chains that [zonk_type] follows).

   {1 Session-threaded state (Phase 2.1)}

   Meta state lives on [Session.t] — [fresh_meta_counter], [meta_origin],
   and [meta_env] are all fields of the session. Every function here takes
   a [~sess] parameter. Reset between function bodies via [Session.reset_meta].

   All unification sites commit their meta bindings to the session eagerly —
   no per-call substitution map to propagate. [zonk_type] and [zonk_expr]
   walk the typed AST at end-of-body and resolve every meta to its final
   binding. An unbound meta is a "cannot infer" error — downstream passes
   never see [TyMeta]. *)

(** Resolve [?sess] to the concrete session to use — explicit when
    passed, else the ambient current session. All meta-touching
    functions in this module follow this pattern so callers that
    don't carry a session in scope can rely on the ambient one set
    by the frontend entry points. *)
let sess_of ?sess () =
  match sess with Some s -> s | None -> Session.current ()

(** Generate a fresh meta. [origin] is the rigid type-param name being
    instantiated ("T", "K", etc.) — recorded for error messages. *)
let fresh_meta ?sess ?(origin = "?") () : type_expr =
  let s = sess_of ?sess () in
  let n = s.Session.fresh_meta_counter in
  s.fresh_meta_counter <- n + 1;
  s.meta_origin <- (n, origin) :: s.meta_origin;
  TyMeta n

(** Look up a meta's binding, or [None] if unbound. Does NOT chase chains. *)
let lookup_meta ?sess (n : int) : type_expr option =
  Hashtbl.find_opt (sess_of ?sess ()).Session.meta_env n

(** Bind a meta to a type. Caller must have verified no cycle (occurs_meta)
    and that [n] isn't already bound to an incompatible type. *)
let bind_meta ?sess (n : int) (ty : type_expr) : unit =
  Hashtbl.replace (sess_of ?sess ()).Session.meta_env n ty

(** Occurs-check for metas: does [ty] contain [TyMeta n] (following chains)? *)
let rec occurs_meta ?sess (n : int) (ty : type_expr) : bool =
  let sess = sess_of ?sess () in
  match ty with
  | TyMeta m when m = n -> true
  | TyMeta m -> (
      match lookup_meta ~sess m with
      | Some t -> occurs_meta ~sess n t
      | None -> false)
  | TyNamed (_, args) -> List.exists (occurs_meta ~sess n) args
  | TyArray (elem, dims) ->
      occurs_meta ~sess n elem || List.exists (occurs_meta ~sess n) dims
  | TyFunc { params; return; _ } ->
      List.exists (occurs_meta ~sess n) params || occurs_meta ~sess n return
  | TyTuple elems -> List.exists (occurs_meta ~sess n) elems
  | TyRange inner -> occurs_meta ~sess n inner
  | TyDimOp (_, a, b) -> occurs_meta ~sess n a || occurs_meta ~sess n b
  | _ -> false

(** Look up the origin name recorded when [TyMeta n] was created. *)
let meta_origin_name ?sess (n : int) : string =
  match List.assoc_opt n (sess_of ?sess ()).Session.meta_origin with
  | Some name -> name
  | None -> Printf.sprintf "?m%d" n

(** Follow [TyMeta] bindings to the head of the chain without recursing
    into type structure or defaulting unbound metas. For predicates that
    match on the outermost constructor (e.g. [is_named_type_in],
    [occurs_in]) — cheaper than [zonk_type] and preserves unbound metas
    as [TyMeta] rather than rewriting them to [TyVar]. *)
let rec head_resolve ?sess (ty : type_expr) : type_expr =
  let sess = sess_of ?sess () in
  match ty with
  | TyMeta n -> (
      match lookup_meta ~sess n with
      | Some inner -> head_resolve ~sess inner
      | None -> ty)
  | _ -> ty

(** Recursively resolve a type: follow every [TyMeta] through the env to
    its final binding, then recurse structurally. Idempotent.

    Unbound metas resolve to [TyVar <origin>] — the rigid name we recorded
    at instantiation. This matches standard HM: a call site whose type
    parameters are genuinely unconstrained stays polymorphic at that name,
    the same as it was before instantiation. Downstream monomorphization
    handles this as it already did for the pre-refactor baseline. *)
let rec zonk_type ?sess (ty : type_expr) : type_expr =
  let sess = sess_of ?sess () in
  match ty with
  | TyMeta n -> (
      match lookup_meta ~sess n with
      | Some t -> zonk_type ~sess t
      | None -> TyVar (meta_origin_name ~sess n))
  | TyNamed (name, args) -> TyNamed (name, List.map (zonk_type ~sess) args)
  | TyArray (elem, dims) ->
      TyArray (zonk_type ~sess elem, List.map (zonk_type ~sess) dims)
  | TyFunc { params; return; is_pure } ->
      TyFunc
        {
          params = List.map (zonk_type ~sess) params;
          return = zonk_type ~sess return;
          is_pure;
        }
  | TyTuple elems -> TyTuple (List.map (zonk_type ~sess) elems)
  | TyRange inner -> TyRange (zonk_type ~sess inner)
  | TyDimOp (op, a, b) -> TyDimOp (op, zonk_type ~sess a, zonk_type ~sess b)
  | _ -> ty

(** Does [ty] still contain any inference-only metavariable? This is a
    phase-boundary predicate: typed frontend output must be zonked before Core
    lowering, and later phases should never see [TyMeta]. *)
let rec contains_meta (ty : type_expr) : bool =
  match ty with
  | TyMeta _ -> true
  | TyNamed (_, args) -> List.exists contains_meta args
  | TyArray (elem, dims) -> contains_meta elem || List.exists contains_meta dims
  | TyFunc { params; return; _ } ->
      List.exists contains_meta params || contains_meta return
  | TyTuple elems -> List.exists contains_meta elems
  | TyRange inner -> contains_meta inner
  | TyDimOp (_, a, b) -> contains_meta a || contains_meta b
  | TyVar _ | TyBoundVar _ | TyConstInt _ | TySelf | TyVarDims _ -> false

(** Stdlib modules provide a small set of runtime/language ABI type names
    that must remain globally stable. Other std-local records/unions/aliases
    use the same owner-qualified identity as user modules so same-named std
    types in different modules (for example codec.Decoder and csv.Decoder) do not
    collapse to one [TyNamed "Thing"]. *)
let is_std_module_name name =
  let std_prefix = "std/" in
  String.length name >= String.length std_prefix
  && String.sub name 0 (String.length std_prefix) = std_prefix

let global_abi_type_names =
  [
    "Int";
    "Bool";
    "Char";
    "Float";
    "Float32";
    "Float16";
    "Int8";
    "Int16";
    "Int32";
    "Int64";
    "Int128";
    "UInt8";
    "UInt16";
    "UInt32";
    "UInt64";
    "UInt128";
    "Void";
    "Ptr";
    "Module";
    "String";
    "Bytes";
    "Fixed";
    "LiteralString";
    "StringSlice";
    "List";
    "ParallelList";
    "ParallelVector";
    "ParallelMatrix";
    "Dict";
    "Set";
    "Option";
    "Result";
    "Range";
    "Tensor";
    "Vector";
    "Matrix";
    "Builder";
    "Slice";
    "MemStats";
    "SchedulerStats";
    "Task";
    "Channel";
    "Stream";
    "FallibleStream";
    "FileReader";
    "FileWriter";
    "FileAppender";
    "FileReadWriter";
    "FileReadAppender";
    "TcpListener";
    "TcpStream";
    "IpAddress";
    "DnsName";
    "InterfaceScope";
    "Port";
    "UdpSocket";
    "ConcurrencyError";
  ]

let is_global_abi_type_name name = List.mem name global_abi_type_names
let canonical_module_type_separator = "::"

let canonical_module_type_name ~(module_path : string) (type_name : string) :
    string =
  if is_std_module_name module_path && is_global_abi_type_name type_name then
    type_name
  else module_path ^ canonical_module_type_separator ^ type_name

let split_canonical_module_type_name (name : string) : (string * string) option
    =
  let sep_len = String.length canonical_module_type_separator in
  let len = String.length name in
  let rec scan i =
    if i + sep_len > len then None
    else if String.sub name i sep_len = canonical_module_type_separator then
      let module_path = String.sub name 0 i in
      let type_name = String.sub name (i + sep_len) (len - i - sep_len) in
      Some (module_path, type_name)
    else scan (i + 1)
  in
  scan 0

let display_type_name name =
  match split_canonical_module_type_name name with
  | Some (module_path, type_name) -> module_path ^ "." ^ type_name
  | None -> name

(* ============================================================================
   Type to String
   ============================================================================ *)

(** Convert a type expression to a human-readable string *)
let rec type_to_string (ty : type_expr) : string =
  match ty with
  | TyNamed (name, []) -> display_type_name name
  | TyNamed ("Tuple", args) when List.length args >= 2 ->
      Printf.sprintf "(%s)" (String.concat ", " (List.map type_to_string args))
  | TyNamed (name, args) ->
      Printf.sprintf "%s[%s]" (display_type_name name)
        (String.concat ", " (List.map type_to_string args))
  | TyArray (elem, dims) ->
      let elem_str =
        match elem with
        | TyFunc _ -> Printf.sprintf "(%s)" (type_to_string elem)
        | _ -> type_to_string elem
      in
      Printf.sprintf "%s[%s]" elem_str
        (String.concat ", " (List.map type_to_string dims))
  | TyFunc { params; return; is_pure } ->
      let pure_str = if is_pure then "pure " else "" in
      Printf.sprintf "%s(%s) -> %s" pure_str
        (String.concat ", " (List.map type_to_string params))
        (type_to_string return)
  | TyVar name -> name
  | TyBoundVar param -> type_param_to_parser_string param
  | TyConstInt n -> Printf.sprintf "#%d" n
  | TyTuple elems ->
      Printf.sprintf "(%s)" (String.concat ", " (List.map type_to_string elems))
  | TySelf -> "Self"
  | TyVarDims name -> name ^ "..."
  | TyRange ty -> Printf.sprintf "..%s" (type_to_string ty)
  | TyDimOp (DimAdd, a, b) ->
      Printf.sprintf "%s + %s" (type_to_string a) (type_to_string b)
  | TyDimOp (DimSub, a, b) ->
      Printf.sprintf "%s - %s" (type_to_string a) (type_to_string b)
  | TyDimOp (DimMul, a, b) ->
      Printf.sprintf "%s * %s" (type_to_string a) (type_to_string b)
  | TyDimOp (DimDiv, a, b) ->
      Printf.sprintf "%s / %s" (type_to_string a) (type_to_string b)
  | TyMeta n -> Printf.sprintf "?m%d" n

(* ============================================================================
   Type Equality and Compatibility
   ============================================================================ *)

(** Normalize tensor type names: Vector and Matrix are aliases for Tensor *)
let normalize_type_name = function "Vector" | "Matrix" -> "Tensor" | n -> n

let array_head_name = "__Array"
let ty_array elem dims = match dims with [] -> elem | _ -> TyArray (elem, dims)

let array_parts = function
  | TyArray (elem, dims) -> Some (elem, dims)
  | TyNamed (("Tensor" | "Vector" | "Matrix"), elem :: (_ :: _ as dims)) ->
      Some (elem, dims)
  | _ -> None

let is_array_type ty =
  match array_parts ty with Some _ -> true | None -> false

(** Check if two types are structurally equal *)
let rec types_equal (t1 : type_expr) (t2 : type_expr) : bool =
  match (t1, t2) with
  | TyNamed (n1, args1), TyNamed (n2, args2) ->
      normalize_type_name n1 = normalize_type_name n2
      && List.length args1 = List.length args2
      && List.for_all2 types_equal args1 args2
  | TyArray (elem1, dims1), TyArray (elem2, dims2) ->
      types_equal elem1 elem2
      && List.length dims1 = List.length dims2
      && List.for_all2 types_equal dims1 dims2
  | TyArray _, TyNamed (("Tensor" | "Vector" | "Matrix"), _)
  | TyNamed (("Tensor" | "Vector" | "Matrix"), _), TyArray _ -> (
      match (array_parts t1, array_parts t2) with
      | Some (elem1, dims1), Some (elem2, dims2) ->
          types_equal elem1 elem2
          && List.length dims1 = List.length dims2
          && List.for_all2 types_equal dims1 dims2
      | _ -> false)
  | TyVar n1, TyVar n2 -> n1 = n2
  | TyBoundVar p1, TyBoundVar p2 -> p1 = p2
  | TyBoundVar p, TyVar n | TyVar n, TyBoundVar p -> p.param_name = n
  | TyConstInt a, TyConstInt b -> a = b
  | TyTuple elems1, TyTuple elems2 ->
      List.length elems1 = List.length elems2
      && List.for_all2 types_equal elems1 elems2
  | TyTuple elems1, TyNamed ("Tuple", elems2)
  | TyNamed ("Tuple", elems1), TyTuple elems2 ->
      List.length elems1 = List.length elems2
      && List.for_all2 types_equal elems1 elems2
  | TyFunc f1, TyFunc f2 ->
      f1.is_pure = f2.is_pure
      && types_equal f1.return f2.return
      && List.length f1.params = List.length f2.params
      && List.for_all2 types_equal f1.params f2.params
  | TySelf, TySelf -> true
  | TyVarDims a, TyVarDims b -> a = b
  | TyRange a, TyRange b -> types_equal a b
  | TyDimOp (op1, a1, b1), TyDimOp (op2, a2, b2) ->
      op1 = op2 && types_equal a1 a2 && types_equal b1 b2
  | TyMeta a, TyMeta b -> a = b
  (* 0D tensor: T[] = T *)
  | TyNamed (("Tensor" | "Vector" | "Matrix"), [ elem ]), other
  | other, TyNamed (("Tensor" | "Vector" | "Matrix"), [ elem ]) ->
      types_equal elem other
  | _ -> false

(** Strip trait bounds from type parameter name: "T:Stringable" -> "T" *)
let strip_type_param_bounds (s : string) : string =
  match String.index_opt s ':' with Some i -> String.sub s 0 i | None -> s

let is_legacy_single_letter_type_param name =
  String.length name = 1 && name.[0] >= 'A' && name.[0] <= 'Z'

let is_type_param_name s =
  String.index_opt s ':' <> None
  || is_legacy_single_letter_type_param (strip_type_param_bounds s)

let is_ascii_upper c = c >= 'A' && c <= 'Z'

let is_ascii_alnum c =
  (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')

let string_for_all_from s start pred =
  let rec loop i =
    if i >= String.length s then true
    else if pred s.[i] then loop (i + 1)
    else false
  in
  loop start

let is_capitalized_alnum s =
  String.length s > 0
  && is_ascii_upper s.[0]
  && string_for_all_from s 1 is_ascii_alnum

let is_valid_named_type_param name =
  let name = strip_type_param_bounds name in
  (not (is_dim_var name)) && is_capitalized_alnum name

let is_valid_dim_type_param name =
  let name = strip_type_param_bounds name in
  if name = "#_" then true
  else if is_dim_var name && String.length name > 1 then
    let base = String.sub name 1 (String.length name - 1) in
    is_capitalized_alnum base
  else false

(* ============================================================================
   Type Parameter Utilities
   ============================================================================ *)

(** Generic recursive mapper for type expressions.
    Applies [f] to each node after recursing into children (bottom-up).
    If [f] returns [Some ty'], that replaces the node; [None] keeps it as-is.
    Does NOT recurse into the result of [f] — for single-pass transforms only.
    For transforms needing cycle detection (like apply_subst), use custom recursion. *)
let rec map_type_expr (f : type_expr -> type_expr option) (ty : type_expr) :
    type_expr =
  let ty' =
    match ty with
    | TyNamed (name, args) -> TyNamed (name, List.map (map_type_expr f) args)
    | TyArray (elem, dims) ->
        TyArray (map_type_expr f elem, List.map (map_type_expr f) dims)
    | TyFunc { params; return; is_pure } ->
        TyFunc
          {
            params = List.map (map_type_expr f) params;
            return = map_type_expr f return;
            is_pure;
          }
    | TyTuple elems -> TyTuple (List.map (map_type_expr f) elems)
    | TyRange inner -> TyRange (map_type_expr f inner)
    | TyDimOp (op, a, b) -> TyDimOp (op, map_type_expr f a, map_type_expr f b)
    | other -> other
  in
  match f ty' with Some r -> r | None -> ty'

(** Collect free type variable names from a type expression.
    Handles both TyVar("T") from OCaml-constructed types and
    TyNamed("T", []) from parser-constructed types (single uppercase letter = type param).
    NOTE: The heuristic for TyNamed uses single uppercase letter to detect type
    params. Multi-char type params (Acc, Elem, Key) use TyVar, not TyNamed. *)
let rec collect_type_vars (ty : type_expr) : string list =
  match ty with
  | TyVar v -> [ v ]
  | TyBoundVar p -> [ p.param_name ]
  | TyVarDims v -> [ v ]
  | TyNamed (name, [])
    when String.length name = 1 && name.[0] >= 'A' && name.[0] <= 'Z' ->
      [ name ]
  | TyNamed (_, args) -> List.concat_map collect_type_vars args
  | TyArray (elem, dims) ->
      collect_type_vars elem @ List.concat_map collect_type_vars dims
  | TyTuple elems -> List.concat_map collect_type_vars elems
  | TyFunc { params; return; _ } ->
      List.concat_map collect_type_vars params @ collect_type_vars return
  | TyRange inner -> collect_type_vars inner
  | TyDimOp (_, a, b) -> collect_type_vars a @ collect_type_vars b
  | _ -> []

(** Collect candidate generic parameter names from a source-level type
    annotation before declared/known concrete types have been resolved.

    This is intentionally broader than [collect_type_vars]: parser-produced
    [TyNamed("Elem", [])] may be an implicit generic parameter, but only the
    typechecker has the environment needed to reject names that are concrete
    records/unions/aliases. *)
let rec collect_type_param_candidates (ty : type_expr) : string list =
  match ty with
  | TyVar v -> [ v ]
  | TyBoundVar p -> [ p.param_name ]
  | TyVarDims v -> [ v ]
  | TyNamed (name, [])
    when is_valid_named_type_param name || is_valid_dim_type_param name ->
      [ strip_type_param_bounds name ]
  | TyNamed (_, args) -> List.concat_map collect_type_param_candidates args
  | TyArray (elem, dims) ->
      collect_type_param_candidates elem
      @ List.concat_map collect_type_param_candidates dims
  | TyTuple elems -> List.concat_map collect_type_param_candidates elems
  | TyFunc { params; return; _ } ->
      List.concat_map collect_type_param_candidates params
      @ collect_type_param_candidates return
  | TyRange inner -> collect_type_param_candidates inner
  | TyDimOp (_, a, b) ->
      collect_type_param_candidates a @ collect_type_param_candidates b
  | _ -> []

(** Replace each occurrence of the wildcard dim [TyVar "#_"] with a fresh
    [TyMeta]. [#_] means "this dim is discarded" — the caller signals they
    don't care about it and the callee doesn't use it in the return type.
    Each occurrence is an independent wildcard, so each gets its own meta
    (one call to [fresh_meta] per occurrence).

    Called at signature-instantiation time. Without this, [TyVar "#_"]
    from a signature like [get(arr: T[#_], ...)] never unifies
    with a concrete dim at the call site. *)
let freshen_dim_wildcards ?sess (ty : type_expr) : type_expr =
  let sess = sess_of ?sess () in
  map_type_expr
    (function
      | TyVar "#_" -> Some (fresh_meta ~sess ~origin:"_" ())
      | TyNamed ("#_", []) -> Some (fresh_meta ~sess ~origin:"_" ())
      | _ -> None)
    ty

(** Instantiate type parameter names as TyVar in a type expression.
    The parser creates TyNamed("T", []) for type params, but inference
    needs TyVar "T" for proper polymorphic type checking. *)
let instantiate_type_params (type_params : string list) (ty : type_expr) :
    type_expr =
  let stripped = List.map strip_type_param_bounds type_params in
  map_type_expr
    (function
      | TyNamed (name, []) when List.mem name stripped -> Some (TyVar name)
      | _ -> None)
    ty

(* ============================================================================
   Substitution Map Operations
   ============================================================================ *)

(** Look up a type variable in the substitution map *)
let lookup_subst (name : string) (subst : subst_map) : type_expr option =
  List.find_map
    (fun entry ->
      if entry.var_name = name then Some entry.concrete_type else None)
    subst

(** Check if a type variable occurs in a type (for occurs check) *)
let rec occurs_in ?sess (var_name : string) (ty : type_expr) : bool =
  let sess = sess_of ?sess () in
  match head_resolve ~sess ty with
  | TyVar name -> name = var_name
  | TyBoundVar p -> p.param_name = var_name
  | TyNamed (name, []) -> name = var_name (* Could be a type param *)
  | TyNamed (_, args) -> List.exists (occurs_in ~sess var_name) args
  | TyArray (elem, dims) ->
      occurs_in ~sess var_name elem
      || List.exists (occurs_in ~sess var_name) dims
  | TyFunc { params; return; _ } ->
      List.exists (occurs_in ~sess var_name) params
      || occurs_in ~sess var_name return
  | TyTuple elems -> List.exists (occurs_in ~sess var_name) elems
  | TyConstInt _ -> false
  | TySelf -> false
  | TyVarDims _ -> false
  | TyRange inner -> occurs_in ~sess var_name inner
  | TyDimOp (_, a, b) ->
      occurs_in ~sess var_name a || occurs_in ~sess var_name b
  | TyMeta _ ->
      false (* Unbound meta after [head_resolve]; no name-based occurs. *)

(** Normalize dimension arithmetic: recursively evaluate to TyConstInt when possible.
    Note: DimSub CAN produce negative TyConstInt values. Callers must validate
    non-negativity separately using [find_negative_dim]. *)
let rec normalize_dim (ty : type_expr) : type_expr =
  match ty with
  | TyDimOp (op, a, b) -> (
      let a' = normalize_dim a in
      let b' = normalize_dim b in
      match (op, a', b') with
      (* Fully concrete: evaluate *)
      | DimAdd, TyConstInt a, TyConstInt b -> TyConstInt (a + b)
      | DimSub, TyConstInt a, TyConstInt b -> TyConstInt (a - b)
      | DimSub, x, y when types_equal x y -> TyConstInt 0
      | DimMul, TyConstInt a, TyConstInt b -> TyConstInt (a * b)
      | DimMul, TyConstInt 0, _ | DimMul, _, TyConstInt 0 -> TyConstInt 0
      | DimDiv, TyConstInt a, TyConstInt b when b > 0 && a mod b = 0 ->
          TyConstInt (a / b)
      | DimDiv, TyConstInt 0, _ -> TyConstInt 0
      (* Constant folding through nested add/sub: (X + c1) + c2 → X + (c1 + c2) *)
      | DimAdd, TyDimOp (DimAdd, x, TyConstInt c1), TyConstInt c2 ->
          normalize_dim (TyDimOp (DimAdd, x, TyConstInt (c1 + c2)))
      | DimAdd, TyConstInt c2, TyDimOp (DimAdd, x, TyConstInt c1) ->
          normalize_dim (TyDimOp (DimAdd, x, TyConstInt (c1 + c2)))
      (* (X + c1) - c2 → X + (c1 - c2) *)
      | DimSub, TyDimOp (DimAdd, x, TyConstInt c1), TyConstInt c2 ->
          normalize_dim (TyDimOp (DimAdd, x, TyConstInt (c1 - c2)))
      (* (X - c1) + c2 → X + (c2 - c1) *)
      | DimAdd, TyDimOp (DimSub, x, TyConstInt c1), TyConstInt c2 ->
          normalize_dim (TyDimOp (DimAdd, x, TyConstInt (c2 - c1)))
      (* (X - c1) - c2 → X - (c1 + c2) *)
      | DimSub, TyDimOp (DimSub, x, TyConstInt c1), TyConstInt c2 ->
          normalize_dim (TyDimOp (DimSub, x, TyConstInt (c1 + c2)))
      (* X + 0 → X, X - 0 → X *)
      | DimAdd, x, TyConstInt 0 -> x
      | DimAdd, TyConstInt 0, x -> x
      | DimSub, x, TyConstInt 0 -> x
      (* X * 1 → X, X / 1 → X *)
      | DimMul, x, TyConstInt 1 -> x
      | DimMul, TyConstInt 1, x -> x
      | DimDiv, x, TyConstInt 1 -> x
      | _ -> TyDimOp (op, a', b'))
  | _ -> ty

(** Check if a type contains any non-positive dimension constants.
    Dimensions must be >= 1 (zero-length tensors are not allowed — use List for
    potentially-empty collections). Returns Some (bad_value) if found. *)
let rec find_negative_dim (ty : type_expr) : int option =
  match normalize_dim ty with
  | TyConstInt n when n <= 0 -> Some n
  | TyNamed (_, args) ->
      List.fold_left
        (fun acc arg ->
          match acc with Some _ -> acc | None -> find_negative_dim arg)
        None args
  | TyArray (elem, dims) ->
      List.fold_left
        (fun acc arg ->
          match acc with Some _ -> acc | None -> find_negative_dim arg)
        None (elem :: dims)
  | TyTuple elems ->
      List.fold_left
        (fun acc elem ->
          match acc with Some _ -> acc | None -> find_negative_dim elem)
        None elems
  | TyRange inner -> find_negative_dim inner
  | TyDimOp (_, a, b) -> (
      match find_negative_dim a with
      | Some _ as r -> r
      | None -> find_negative_dim b)
  | TyFunc { params; return; _ } -> (
      let r =
        List.fold_left
          (fun acc p ->
            match acc with Some _ -> acc | None -> find_negative_dim p)
          None params
      in
      match r with Some _ -> r | None -> find_negative_dim return)
  | _ -> None

(** Apply substitutions to a type.
    Uses a visited set to prevent infinite loops from cyclic substitutions
    like A→B, B→A (the occurs_in check only catches direct self-references). *)
let apply_subst ?sess (subst : subst_map) (ty : type_expr) : type_expr =
  let sess = sess_of ?sess () in
  let rec apply ~visited ty =
    let try_subst_name name =
      if List.mem name visited then ty
      else
        match lookup_subst name subst with
        | Some t when not (occurs_in ~sess name t) ->
            apply ~visited:(name :: visited) t
        | Some t -> t
        | None -> ty
    in
    match ty with
    | TyVar name -> try_subst_name name
    | TyBoundVar p -> try_subst_name p.param_name
    | TyNamed (name, []) -> try_subst_name name
    | TyNamed (name, args) -> TyNamed (name, List.map (apply ~visited) args)
    | TyArray (elem, dims) ->
        TyArray (apply ~visited elem, List.map (apply ~visited) dims)
    | TyFunc { params; return; is_pure } ->
        TyFunc
          {
            params = List.map (apply ~visited) params;
            return = apply ~visited return;
            is_pure;
          }
    | TyTuple elems -> TyTuple (List.map (apply ~visited) elems)
    | TyConstInt _ -> ty
    | TyRange inner -> TyRange (apply ~visited inner)
    | TyDimOp (op, a, b) ->
        let a' = apply ~visited a in
        let b' = apply ~visited b in
        normalize_dim (TyDimOp (op, a', b'))
    | TySelf -> (
        if List.mem "Self" visited then ty
        else
          match lookup_subst "Self" subst with
          | Some t -> apply ~visited:("Self" :: visited) t
          | None -> ty)
    | TyVarDims _ as vd -> vd
    | TyMeta _ as m ->
        (* Follow the meta env through its chain, but DO NOT default unbound
           metas to [TyVar <origin>] — that's [zonk_type]'s job at end of
           inference. Defaulting here (during inference) causes unbound
           metas to escape as rigid [TyVar]s that later unifications try to
           bind, producing wrong bindings. Also: don't recurse via
           [apply_subst] into the bound type, since name-keyed [subst]
           entries would wrongly expand rigid names inside it (cache's
           [V ↦ (V, Int)] would infinitely expand V). *)
        let rec follow t =
          match t with
          | TyMeta m' -> (
              match lookup_meta ~sess m' with
              | Some inner when inner <> t -> follow inner
              | _ -> t)
          | _ -> t
        in
        follow m
  in
  apply ~visited:[] ty

let apply_type_param_subst subst ty =
  let rec go = function
    | TyVar name as ty -> (
        match List.assoc_opt name subst with
        | Some replacement -> replacement
        | None -> (
            match List.assoc_opt (strip_type_param_bounds name) subst with
            | Some replacement -> replacement
            | None -> ty))
    | TyBoundVar p as ty -> (
        match List.assoc_opt p.param_name subst with
        | Some replacement -> replacement
        | None -> (
            match List.assoc_opt (type_param_to_parser_string p) subst with
            | Some replacement -> replacement
            | None -> ty))
    | TyNamed (name, []) as ty when is_type_param_name name -> (
        match List.assoc_opt name subst with
        | Some replacement -> replacement
        | None -> (
            match List.assoc_opt (strip_type_param_bounds name) subst with
            | Some replacement -> replacement
            | None -> ty))
    | TyNamed (name, args) -> TyNamed (name, List.map go args)
    | TyArray (elem, dims) -> TyArray (go elem, List.map go dims)
    | TyTuple elems -> TyTuple (List.map go elems)
    | TyFunc f ->
        TyFunc { f with params = List.map go f.params; return = go f.return }
    | TyRange inner -> TyRange (go inner)
    | TyDimOp (op, a, b) -> normalize_dim (TyDimOp (op, go a, go b))
    | ty -> ty
  in
  go ty

(** Unify two types, returning accumulated substitutions on success.
    ~symmetric: if true, TyVar/type-param binds on EITHER side (true unification).
      If false (default), only binds on the LEFT (expected) side — one-way matching.
    ~type_params: type parameter names treated as bindable wildcards.
    Handles: TyVar binding, pure function covariance, range subtyping,
    variadic dimension wildcards, consistent binding checks. *)
let unify ?sess ?(symmetric = false) ?(type_params : string list = [])
    ?(rigid_vars : string list = []) (t1 : type_expr) (t2 : type_expr) :
    subst_map option =
  let sess = sess_of ?sess () in
  let stripped_params = List.map strip_type_param_bounds type_params in
  let is_var name = List.mem name stripped_params in
  let is_rigid name = List.mem name rigid_vars in
  (* Try to bind a variable, checking consistency with existing bindings *)
  let try_bind subst name ty =
    match List.find_opt (fun e -> e.var_name = name) subst with
    | Some existing ->
        (* Already bound — check consistent with existing binding *)
        if types_equal existing.concrete_type ty then Some subst else None
    | None ->
        (* Fresh binding — occurs check *)
        if occurs_in ~sess name ty then None
        else Some ({ var_name = name; concrete_type = ty } :: subst)
  in
  let rec go subst t1 t2 =
    (* Resolve metas through the env before anything else — a bound meta
       stands for its binding. Identical unbound metas match each other. *)
    let t1 =
      match t1 with
      | TyMeta n -> ( match lookup_meta ~sess n with Some t -> t | None -> t1)
      | _ -> t1
    in
    let t2 =
      match t2 with
      | TyMeta n -> ( match lookup_meta ~sess n with Some t -> t | None -> t2)
      | _ -> t2
    in
    if types_equal t1 t2 then Some subst
    else
      match (t1, t2) with
      (* Meta on either side: bind eagerly to the other side.
       Occurs-check prevents cyclic bindings ($m ↦ List[$m]). *)
      | TyMeta n, other ->
          if occurs_meta ~sess n other then None
          else (
            bind_meta ~sess n other;
            Some subst)
      | other, TyMeta n ->
          if occurs_meta ~sess n other then None
          else (
            bind_meta ~sess n other;
            Some subst)
      (* Same type variable in different AST forms: TyVar "T" = TyNamed("T",[]) *)
      | TyVar name, TyNamed (n, []) when name = n -> Some subst
      | TyNamed (n, []), TyVar name when name = n -> Some subst
      | (TyBoundVar p, TyVar name | TyVar name, TyBoundVar p)
        when p.param_name = name ->
          Some subst
      | (TyBoundVar p, TyNamed (n, []) | TyNamed (n, []), TyBoundVar p)
        when p.param_name = n ->
          Some subst
      (* Rigid type variables: cannot bind — used for generic function body checking.
       Exception: dim vars (#N, #M) ARE rigid but always compatible with Int,
       since they represent compile-time integer constants. *)
      | TyNamed ("Int", []), TyVar name when is_rigid name && is_dim_var name ->
          Some subst
      | TyVar name, TyNamed ("Int", []) when is_rigid name && is_dim_var name ->
          Some subst
      | TyNamed ("Int", []), TyBoundVar p
        when is_rigid p.param_name && is_dim_var p.param_name ->
          Some subst
      | TyBoundVar p, TyNamed ("Int", [])
        when is_rigid p.param_name && is_dim_var p.param_name ->
          Some subst
      | TyNamed ("Int", []), TyNamed (n, []) when is_rigid n && is_dim_var n ->
          Some subst
      | TyNamed (n, []), TyNamed ("Int", []) when is_rigid n && is_dim_var n ->
          Some subst
      | TyVar name, _ when is_rigid name -> None
      | _, TyVar name when is_rigid name -> None
      | TyBoundVar p, _ when is_rigid p.param_name -> None
      | _, TyBoundVar p when is_rigid p.param_name -> None
      | TyNamed (n, []), _ when is_rigid n -> None
      | _, TyNamed (n, []) when is_rigid n -> None
      (* TyVar on left — always bind *)
      | TyVar name, _ -> try_bind subst name t2
      (* TyVar on right — only in symmetric mode *)
      | _, TyVar name when symmetric -> try_bind subst name t1
      (* Bounded type variables behave as their declared parameter name for
         unification; trait obligations are checked separately. *)
      | TyBoundVar p, _ -> try_bind subst p.param_name t2
      | _, TyBoundVar p when symmetric -> try_bind subst p.param_name t1
      (* Type parameter on left — always bind *)
      | TyNamed (n, []), _ when is_var n -> try_bind subst n t2
      (* Type parameter on right — only in symmetric mode *)
      | _, TyNamed (n, []) when symmetric && is_var n -> try_bind subst n t1
      (* Functions: pure ⊆ impure *)
      | TyFunc f1, TyFunc f2 -> (
          if f1.is_pure && not f2.is_pure then
            None (* expected pure, got impure *)
          else if List.length f1.params <> List.length f2.params then None
          else
            List.fold_left2
              (fun acc p1 p2 ->
                match acc with None -> None | Some s -> go s p1 p2)
              (Some subst) f1.params f2.params
            |> fun acc ->
            match acc with None -> None | Some s -> go s f1.return f2.return)
      (* Tuples *)
      | TyTuple e1, TyTuple e2 ->
          if List.length e1 <> List.length e2 then None
          else
            List.fold_left2
              (fun acc a b ->
                match acc with None -> None | Some s -> go s a b)
              (Some subst) e1 e2
      | TyTuple e1, TyNamed ("Tuple", e2) | TyNamed ("Tuple", e1), TyTuple e2 ->
          if List.length e1 <> List.length e2 then None
          else
            List.fold_left2
              (fun acc a b ->
                match acc with None -> None | Some s -> go s a b)
              (Some subst) e1 e2
      (* 0D tensor: T[] = T — but NOT when the single arg is TyVarDims (variadic dims) *)
      | TyNamed (("Tensor" | "Vector" | "Matrix"), [ elem ]), other
        when match elem with TyVarDims _ -> false | _ -> true ->
          go subst elem other
      | other, TyNamed (("Tensor" | "Vector" | "Matrix"), [ elem ])
        when match elem with TyVarDims _ -> false | _ -> true ->
          go subst elem other
      | TyArray (elem1, dims1), TyArray (elem2, dims2) -> (
          match go subst elem1 elem2 with
          | Some s -> go_args s dims1 dims2
          | None -> None)
      | TyArray _, TyNamed (("Tensor" | "Vector" | "Matrix"), _)
      | TyNamed (("Tensor" | "Vector" | "Matrix"), _), TyArray _ -> (
          match (array_parts t1, array_parts t2) with
          | Some (elem1, dims1), Some (elem2, dims2) -> (
              match go subst elem1 elem2 with
              | Some s -> go_args s dims1 dims2
              | None -> None)
          | _ -> None)
      (* LiteralString subtyping: LiteralString flows TO String context.
       Must come before the general TyNamed case which would reject the name mismatch. *)
      | TyNamed ("String", []), TyNamed ("LiteralString", []) -> Some subst
      | TyNamed ("LiteralString", []), TyNamed ("String", []) when symmetric ->
          Some subst
      (* Named types *)
      | TyNamed (n1, args1), TyNamed (n2, args2) ->
          if normalize_type_name n1 <> normalize_type_name n2 then None
          else go_args subst args1 args2
      (* Range subtyping: range flows TO Int context only (not symmetric) *)
      | TyNamed ("Int", []), TyRange _ -> Some subst
      | TyRange _, TyNamed ("Int", []) when symmetric -> Some subst
      (* Dimension types flow TO Int context (a compile-time constant IS a valid Int)
       but Int does NOT flow to TyConstInt (a runtime Int cannot prove a compile-time dimension).
       This prevents forging dimension guarantees from runtime values. *)
      | TyNamed ("Int", []), TyConstInt _ -> Some subst
      | TyConstInt _, TyNamed ("Int", []) when symmetric -> Some subst
      (* Dim vars (#N, #M) also flow to Int context — they are integers at runtime *)
      | TyNamed ("Int", []), TyVar name when is_dim_var name -> Some subst
      (* Range to range *)
      | TyRange (TyConstInt m), TyRange (TyConstInt n) ->
          if n <= m then Some subst
          else None (* smaller actual fits larger expected *)
      | TyRange a, TyRange b -> go subst a b
      (* Dimension arithmetic: canonical-form algebraic solver.
       Replaces ~170 lines of ad-hoc pattern matching with a principled
       sum-of-products solver (Baaij 2015, ghc-typelits-natnormalise). *)
      | t1, t2
        when (match t1 with TyDimOp _ -> true | _ -> false)
             || match t2 with TyDimOp _ -> true | _ -> false -> (
          match Dim_solver.solve ~lookup_meta:(lookup_meta ~sess) t1 t2 with
          | Dim_solver.Solved -> Some subst
          | Dim_solver.BindMeta (m, value) ->
              (* Occurs check unnecessary: canonical subtraction cancels shared metas *)
              bind_meta ~sess m value;
              Some subst
          | Dim_solver.BindVar (name, value) -> go subst (TyVar name) value
          | Dim_solver.Contradiction -> None
          | Dim_solver.Stuck ->
              (* Fallback: zonk metas, apply substitutions, normalize, and retry.
                Handles cases where a meta was bound by an earlier unification step. *)
              let d1 =
                normalize_dim (zonk_type ~sess (apply_subst ~sess subst t1))
              in
              let d2 =
                normalize_dim (zonk_type ~sess (apply_subst ~sess subst t2))
              in
              if d1 <> t1 || d2 <> t2 then go subst d1 d2 else None)
      | _ -> None
  and go_args subst args1 args2 =
    match (args1, args2) with
    | [], [] -> Some subst
    | [ TyVarDims _ ], _ -> Some subst
    (* Right-side #N... only in symmetric mode — prevents unsound narrowing
       where T[#N...] satisfies T[#3] *)
    | _, [ TyVarDims _ ] when symmetric -> Some subst
    | a :: rest1, b :: rest2 -> (
        match go subst a b with Some s -> go_args s rest1 rest2 | None -> None)
    | _, _ -> None
  in
  go [] t1 t2

(** Check if two types are compatible (for assignment/passing).
    One-way matching: expected (left) can have type vars/params as wildcards,
    actual (right) must satisfy expected. Thin wrapper around [unify ~symmetric:false]. *)
let types_compatible ?sess ?(type_params : string list = [])
    (expected : type_expr) (actual : type_expr) : bool =
  unify ?sess ~symmetric:false ~type_params expected actual <> None

(** Check if two types are bidirectionally compatible (true unification).
    Unlike [types_compatible] which only matches left→right, this checks
    both directions in a single consistent substitution context.
    Use when you only need a boolean and don't care which direction matched. *)
let types_bidirectional ?sess ?(type_params : string list = []) (a : type_expr)
    (b : type_expr) : bool =
  unify ?sess ~symmetric:true ~type_params a b <> None

(** Check type compatibility with rigid type variables.
    Rigid vars cannot bind — they represent opaque types in generic function bodies.
    Used to verify a generic function body's return type matches the declaration. *)
let types_compatible_rigid ?sess ~(rigid_vars : string list)
    (expected : type_expr) (actual : type_expr) : bool =
  unify ?sess ~symmetric:false ~rigid_vars expected actual <> None

(** Check if a type expression is a valid dimension type.
    Valid: TyConstInt, TyVar (dim params like #N), TyVarDims (#N...),
    TyDimOp (arithmetic), TyNamed of a dim param. *)
let rec is_dim_type ?sess (type_params : string list) (ty : type_expr) : bool =
  let sess = sess_of ?sess () in
  match head_resolve ~sess ty with
  | TyConstInt _ -> true
  | TyVarDims _ -> true
  | TyDimOp (_, a, b) ->
      is_dim_type ~sess type_params a && is_dim_type ~sess type_params b
  | TyVar name -> is_dim_var name
  | TyNamed (name, []) ->
      (* Parser sometimes emits TyNamed ("#N", []) for dim params. *)
      is_dim_var name
      || List.exists
           (fun p ->
             let stripped = strip_type_param_bounds p in
             stripped = name && is_dim_var stripped)
           type_params
  | _ -> false

(** Validate that an array type has valid dimension arguments.
    Returns None if valid, Some error_message if invalid. *)
let validate_array_dims ?sess (type_params : string list) (ty : type_expr) :
    string option =
  let sess = sess_of ?sess () in
  let scalar_array_element_name = function
    | "Int" | "Int8" | "Int16" | "Int32" | "Int64" | "Int128" | "UInt8"
    | "UInt16" | "UInt32" | "UInt64" | "UInt128" | "Float" | "Float32"
    | "Float16" | "Bool" | "Char" | "String" | "Fixed" ->
        true
    | _ -> false
  in
  match find_negative_dim ty with
  | Some n ->
      Some
        (Printf.sprintf
           "Dimension arithmetic produces non-positive result: %d (dimensions \
            must be >= 1)"
           n)
  | None -> (
      match ty with
      | TyNamed (name, bad :: _) when scalar_array_element_name name ->
          Some
            (Printf.sprintf
               "Array dimension argument must be a dimension type (#N, #3, \
                #Ds...), got %s"
               (type_to_string bad))
      | TyArray (_, dims) -> (
          let invalid =
            List.filter (fun d -> not (is_dim_type ~sess type_params d)) dims
          in
          match invalid with
          | bad :: _ ->
              Some
                (Printf.sprintf
                   "Array dimension argument must be a dimension type (#N, #3, \
                    #Ds...), got %s"
                   (type_to_string bad))
          | [] ->
              let is_vardims = function TyVarDims _ -> true | _ -> false in
              if List.length (List.filter is_vardims dims) > 1 then
                Some
                  "Array type cannot have multiple variadic dims — use a \
                   single #N... as the last dimension"
              else if
                List.exists is_vardims dims
                && not (is_vardims (List.nth dims (List.length dims - 1)))
              then
                Some
                  "Array type: variadic dimension (#N...) must be the last \
                   dimension argument"
              else None)
      | TyNamed ((("Tensor" | "Vector" | "Matrix") as name), _ :: dims) -> (
          let invalid =
            List.filter (fun d -> not (is_dim_type ~sess type_params d)) dims
          in
          match invalid with
          | bad :: _ ->
              Some
                (Printf.sprintf
                   "%s dimension argument must be a dimension type (#N, #3, \
                    #Ds...), got %s"
                   name (type_to_string bad))
          | [] ->
              let is_vardims = function TyVarDims _ -> true | _ -> false in
              if
                (name = "Vector" || name = "Matrix")
                && List.exists is_vardims dims
              then
                Some
                  (Printf.sprintf
                     "%s does not support variadic dimensions (#N...). Use \
                      T[#Ds...] instead"
                     name)
                (* Variadic dim can only appear once and must be the last dim arg *)
              else if List.length (List.filter is_vardims dims) > 1 then
                Some
                  (Printf.sprintf
                     "%s cannot have multiple variadic dims — use a single \
                      #N... as the last dimension"
                     name)
              else if
                List.exists is_vardims dims
                && not (is_vardims (List.nth dims (List.length dims - 1)))
              then
                Some
                  (Printf.sprintf
                     "%s: variadic dimension (#N...) must be the last \
                      dimension argument"
                     name)
              else None)
      | _ -> None)

let validate_tensor_dims = validate_array_dims

(** Check if a type contains TyVarDims (variadic dims like #N...) anywhere.
    Used to reject variadic dims in positions where concrete dimensions are required
    (variable declarations, record fields). Variadic dims are only valid in function
    parameter and return type annotations where they mean "generic over any dims". *)
let rec contains_vardims (ty : type_expr) : bool =
  match ty with
  | TyVarDims _ -> true
  | TyNamed (_, args) -> List.exists contains_vardims args
  | TyArray (elem, dims) ->
      contains_vardims elem || List.exists contains_vardims dims
  | TyTuple elems -> List.exists contains_vardims elems
  | TyFunc { params; return; _ } ->
      List.exists contains_vardims params || contains_vardims return
  | TyRange inner -> contains_vardims inner
  | TyDimOp (_, a, b) -> contains_vardims a || contains_vardims b
  | _ -> false

(** Collect the names of all [TyVarDims] occurring in a type. *)
let rec collect_vardim_names (ty : type_expr) : string list =
  match ty with
  | TyVarDims name -> [ name ]
  | TyNamed (_, args) -> List.concat_map collect_vardim_names args
  | TyArray (elem, dims) ->
      collect_vardim_names elem @ List.concat_map collect_vardim_names dims
  | TyTuple elems -> List.concat_map collect_vardim_names elems
  | TyFunc { params; return; _ } ->
      List.concat_map collect_vardim_names params @ collect_vardim_names return
  | TyRange inner -> collect_vardim_names inner
  | TyDimOp (_, a, b) -> collect_vardim_names a @ collect_vardim_names b
  | _ -> []

(* ============================================================================
   Common Type Constructors
   ============================================================================ *)

(** Built-in type constructors *)
let ty_int = TyNamed ("Int", [])

let ty_float = TyNamed ("Float", [])
let ty_string = TyNamed ("String", [])
let ty_bool = TyNamed ("Bool", [])
let ty_char = TyNamed ("Char", [])
let ty_void = TyNamed ("Void", [])
let ty_int8 = TyNamed ("Int8", [])
let ty_int16 = TyNamed ("Int16", [])
let ty_int32 = TyNamed ("Int32", [])
let ty_int128 = TyNamed ("Int128", [])
let ty_uint8 = TyNamed ("UInt8", [])
let ty_uint16 = TyNamed ("UInt16", [])
let ty_uint32 = TyNamed ("UInt32", [])
let ty_uint64 = TyNamed ("UInt64", [])
let ty_uint128 = TyNamed ("UInt128", [])
let ty_float32 = TyNamed ("Float32", [])
let ty_float16 = TyNamed ("Float16", [])

(** All sized integer type names (including Int) *)
let all_int_type_names =
  [
    "Int";
    "Int8";
    "Int16";
    "Int32";
    "Int64";
    "Int128";
    "UInt8";
    "UInt16";
    "UInt32";
    "UInt64";
    "UInt128";
  ]

let signed_int_type_names =
  [ "Int"; "Int8"; "Int16"; "Int32"; "Int64"; "Int128" ]

let unsigned_int_type_names =
  [ "UInt8"; "UInt16"; "UInt32"; "UInt64"; "UInt128" ]

(* Predicate follows [TyMeta] one hop before matching. Pre-zonk
   callers (infer / typecheck, on a type that may still be a bound
   meta) get the right answer via ambient [Session.current ()]. Post-
   zonk callers (codegen, the core_ passes) pay a no-op head_resolve
   and pattern match as expected. A caller that truly needs
   structural-only matching can match [TyNamed _] directly. *)
let is_named_type_in names ty =
  match head_resolve ty with
  | TyNamed (name, []) -> List.mem name names
  | _ -> false

let is_std_duration_type_name name =
  match split_canonical_module_type_name name with
  | Some (module_path, "Duration") -> module_path = "std/units"
  | _ -> name = "Duration" || name = "std_units__Duration"

let is_std_duration_type ty =
  match head_resolve ty with
  | TyNamed (name, []) -> is_std_duration_type_name name
  | _ -> false

(** Check if a type is any integer type (signed or unsigned, any width). *)
let is_any_integer_type ty = is_named_type_in all_int_type_names ty

(** Check if a type is a signed integer type. *)
let is_signed_integer_type ty = is_named_type_in signed_int_type_names ty

(** Check if a type is an unsigned integer type. *)
let is_unsigned_integer_type ty = is_named_type_in unsigned_int_type_names ty

(** Map integer type name to C type string *)
let int_type_to_c = function
  | "Int" -> "long"
  | "Int8" -> "int8_t"
  | "Int16" -> "int16_t"
  | "Int32" -> "int32_t"
  | "Int64" -> "long"
  | "Int128" -> "__int128"
  | "UInt8" -> "uint8_t"
  | "UInt16" -> "uint16_t"
  | "UInt32" -> "uint32_t"
  | "UInt64" -> "uint64_t"
  | "UInt128" -> "unsigned __int128"
  | n -> failwith (Printf.sprintf "int_type_to_c: not an integer type: %s" n)

(** Range for compile-time literal checking. Int128/UInt128 use Int64 bounds as approximation. *)
let int_type_range = function
  | "Int8" -> (Int64.of_int (-128), Int64.of_int 127)
  | "Int16" -> (Int64.of_int (-32768), Int64.of_int 32767)
  | "Int32" -> (Int64.of_string "-2147483648", Int64.of_string "2147483647")
  | "Int" | "Int64" -> (Int64.min_int, Int64.max_int)
  | "Int128" -> (Int64.min_int, Int64.max_int) (* approximate *)
  | "UInt8" -> (Int64.zero, Int64.of_int 255)
  | "UInt16" -> (Int64.zero, Int64.of_int 65535)
  | "UInt32" -> (Int64.zero, Int64.of_string "4294967295")
  | "UInt64" -> (Int64.zero, Int64.max_int) (* approximate *)
  | "UInt128" -> (Int64.zero, Int64.max_int) (* approximate *)
  | n -> failwith (Printf.sprintf "int_type_range: not an integer type: %s" n)

(** All float type names *)
let all_float_type_names = [ "Float"; "Float32"; "Float16" ]

(** Check if a type is any float type (Float or Float32) *)
let is_any_float_type = is_named_type_in all_float_type_names

(** Check if a type is Float32 *)
let is_float32_type = is_named_type_in [ "Float32" ]

(** Check if a type is Float16 *)
let is_float16_type = is_named_type_in [ "Float16" ]

(** Map float type name to C type string *)
let float_type_to_c = function
  | "Float" -> "double"
  | "Float32" -> "float"
  | "Float16" -> "_Float16"
  | n -> failwith (Printf.sprintf "float_type_to_c: not a float type: %s" n)

(** Create a List type *)
let ty_list elem = TyNamed ("List", [ elem ])

(** Create a function type *)
let ty_func ?(pure = false) params return =
  TyFunc { params; return; is_pure = pure }

(** Rewrite bare module-local type names to their canonical owner-qualified
    frontend identity when a type crosses a module boundary. *)
let qualify_module_local_types ~(module_path : string)
    (local_type_names : string list) (ty : type_expr) : type_expr =
  map_type_expr
    (function
      | TyNamed (name, args)
        when List.mem name local_type_names
             && not
                  (is_std_module_name module_path
                  && is_global_abi_type_name name) ->
          Some (TyNamed (canonical_module_type_name ~module_path name, args))
      | _ -> None)
    ty

(** Resolve qualified type names (e.g., "A.Thing" → "path/to/a::Thing";
    stdlib aliases like "D.Dict" still resolve to "Dict") using module aliases.
    Recursively walks the type tree. *)
let resolve_qualified_types (module_aliases : (string * string) list)
    (ty : type_expr) : type_expr =
  let resolve_name name args =
    match String.index_opt name '.' with
    | None -> TyNamed (name, args)
    | Some dot_pos -> (
        let mod_alias = String.sub name 0 dot_pos in
        let type_name =
          String.sub name (dot_pos + 1) (String.length name - dot_pos - 1)
        in
        match List.assoc_opt mod_alias module_aliases with
        | Some module_path ->
            TyNamed (canonical_module_type_name ~module_path type_name, args)
        | None -> TyNamed (name, args))
  in
  let rec walk = function
    | TyNamed (name, args) -> resolve_name name (List.map walk args)
    | TyArray (elem, dims) -> TyArray (walk elem, List.map walk dims)
    | TyFunc f ->
        TyFunc
          { f with params = List.map walk f.params; return = walk f.return }
    | TyTuple elems -> TyTuple (List.map walk elems)
    | TyRange inner -> TyRange (walk inner)
    | TyDimOp (op, a, b) -> TyDimOp (op, walk a, walk b)
    | ty -> ty
  in
  walk ty

(* ============================================================================
   Dim — consolidated API for dimension-type operations
   ============================================================================

   Dimension types (TyConstInt, TyVar "#N", TyVarDims, TyRange, TyDimOp) are
   a refinement of Int: every dim value, at runtime, is a non-negative Int.
   This module is the single source of truth for the predicates, lifts, and
   normalizations that flow from that fact.

   See memory/dim_types_formalization.md for the 8 laws and full site
   inventory. When adding a new dim-aware operation, extend this module
   rather than sprinkling new special cases in infer/typecheck/codegen. *)
module Dim = struct
  (** Law 1 discriminator: names starting with '#' are dim vars.
      Used everywhere a [TyVar] needs to distinguish dim from normal type
      parameters. Replaces the inline [name.[0] = '#'] checks. *)
  let is_var_name = is_dim_var

  (** True if [ty] is any dimension form: [TyConstInt], [TyVar "#N"],
      [TyVarDims], [TyDimOp], or [TyNamed ("#N", [])] (parser quirk).
      The [type_params] list is needed to recognize parser-produced
      [TyNamed (name, [])] where [name] is a dim param in scope. *)
  let is_dim = is_dim_type

  (** Runtime-value dim refinements. These are scalar Int values after
      codegen erasure. Excludes [TyVarDims], which is a type-level pack of
      zero or more dimensions, not a single runtime value. *)
  let is_value_dim = function
    | TyRange _ | TyConstInt _ | TyDimOp _ -> true
    | TyVar name when is_dim_var name -> true
    | TyNamed (name, []) when is_dim_var name -> true
    | _ -> false

  (** Law 2: find the first non-positive concrete dim value in [ty], or [None]
      if all are positive. [TyDimOp (DimSub, _, _)] can produce a non-positive
      [TyConstInt] after [normalize]; callers validate. *)
  let find_negative = find_negative_dim

  (** Law 3: lift a dim or refinement to [Int] for value-context operations
      (binary ops, etc.). [TyRange], [TyConstInt], and dim-var [TyVar]
      all collapse to [Int]; other types pass through. *)
  let lift_to_int = function
    | ty when is_value_dim ty -> TyNamed ("Int", [])
    | ty -> ty

  (** Law 7 detector: does [ty] contain any [TyVarDims] anywhere? *)
  let contains_vardims = contains_vardims

  (** Law 7 name-collector: extract the names of all [TyVarDims]
      occurrences in [ty]. *)
  let collect_vardim_names = collect_vardim_names

  (** Law 8: normalize dim arithmetic. [#2 + #3 → TyConstInt 5], etc.
      Partial evaluation when operands aren't both concrete. *)
  let normalize = normalize_dim
end
