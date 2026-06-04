(** Environment/Symbol Table for blorp Type Checker

    Provides scoped symbol lookup for:
    - Variable types
    - Function signatures
    - Type declarations (unions, records)
    - Type aliases
    - Trait bounds
*)

open Ast
open Types

(** Explicit mutability for variable bindings *)
type var_mutability = Immutable | Mutable

(** Origin of a variable binding — used for context-specific error messages and
    phase-local capability checks. *)
type var_origin =
  | LetBinding
  | FuncParam
  | ForLoopVar
  | MatchBinding
  | ScopedResource
  | ScopedResourceUnavailable of string
  | ScopedResourceDerived
  | Other

(** Re-exports from [Env_types] so consumers that reference [Env.purity],
    [Env.func_origin], [Env.overload_entry], [Env.impl_instance] continue
    to work unchanged. The [= ...] syntax makes these true type aliases
    with full constructor/field visibility. *)
type purity = Env_types.purity = Pure | Impure

type func_origin = Env_types.func_origin = UserDefined | Builtin | Foreign
type def_id = Env_types.def_id

type resource_result_policy = Env_types.resource_result_policy =
  | ResourceResultDependent
  | ResourceResultIndependent
  | ResourceResultOrdinary

type resource_arg_policy = Env_types.resource_arg_policy =
  | RejectResourceArgs
  | AllowResourceArgs of resource_result_policy

type loop_producer = Env_types.loop_producer =
  | LoopProducerIndices
  | LoopProducerEnumerate
  | LoopProducerEnumerate2
  | LoopProducerWindows

type trait_ref = Env_types.trait_ref = { tr_name : string }
(** Reference to a trait in a bound or obligation. *)

type bound_type_param = Env_types.bound_type_param = {
  param_name : string;
  param_bounds : trait_ref list;
}
(** Type parameter with optional trait bounds *)

type type_kind = TypeUnion | TypeEnum | TypeBuiltin | TypeResource

type overload_entry = Env_types.overload_entry = {
  ol_def_id : def_id;
  ol_func_type : type_expr;
  ol_type_params : bound_type_param list;
  ol_param_names : string option list;
  ol_purity : purity;
  ol_origin : func_origin;
  ol_resource_args : resource_arg_policy;
  ol_module_path : string option;
  ol_dim_constraints : (type_expr * type_expr) list;
  ol_loop_producer : loop_producer option;
  ol_debug_only : bool;
}

(** Symbol kinds *)
type symbol_kind =
  | VarSymbol of {
      var_type : type_expr;
      source_type : type_expr option;
      mutability : var_mutability;
      origin : var_origin;
      refinement : Refinement.binding_refinement;
    }
  | FuncSymbol of {
      callable_id : def_id;
      func_type : type_expr; (* Function type including params and return *)
      type_params : bound_type_param list; (* Generic type parameters *)
      param_names : string option list;
          (* Parameter names aligned with typed parameters *)
      purity : purity;
      origin : func_origin;
      resource_args : resource_arg_policy;
      module_path : string option;
      dim_constraints : (type_expr * type_expr) list;
      loop_producer : loop_producer option;
      debug_only : bool;
    }
  | TypeSymbol of {
      type_params : string list;
      variants : variant list; (* For union types *)
      type_kind : type_kind;
      contains_resource : bool;
    }
  | RecordSymbol of {
      type_params : string list;
      fields : field_decl list;
      is_value : bool;
      contains_resource : bool;
    }
  | AliasSymbol of { type_params : string list; target : type_expr }
  | OpaqueAliasSymbol of {
      type_params : string list;
      target : type_expr;
      home_module : string option;
    }
  | ConstructorSymbol of {
      parent_type : string; (* The union type this constructor belongs to *)
      constructor_id : int; (* Callable identity for constructor calls *)
      type_params : string list; (* Inherited from parent *)
      field_types : type_expr list; (* Types of constructor fields *)
      tag : int;
    }

type symbol = { name : string; kind : symbol_kind }
(** Symbol table entry *)

module StringMap = Map.Make (String)

type type_binding =
  | TypeBinding of {
      tb_type_params : string list;
      tb_variants : variant list;
      tb_type_kind : type_kind;
      tb_contains_resource : bool;
    }
  | RecordBinding of {
      rb_type_params : string list;
      rb_fields : field_decl list;
      rb_is_value : bool;
      rb_contains_resource : bool;
    }
  | AliasBinding of { ab_type_params : string list; ab_target : type_expr }
  | OpaqueAliasBinding of {
      oab_type_params : string list;
      oab_target : type_expr;
      oab_home_module : string option;
    }

type scope = { symbols : symbol list; by_name : symbol StringMap.t }
(** A scope preserves binding order for scans and diagnostics while indexing
    names for hot lookup paths. [symbols] is newest binding first. *)

type type_index = type_binding option StringMap.t

let empty_scope = { symbols = []; by_name = StringMap.empty }

let type_binding_of_symbol sym =
  match sym.kind with
  | TypeSymbol { type_params; variants; type_kind; contains_resource } ->
      Some
        (TypeBinding
           {
             tb_type_params = type_params;
             tb_variants = variants;
             tb_type_kind = type_kind;
             tb_contains_resource = contains_resource;
           })
  | RecordSymbol { type_params; fields; is_value; contains_resource } ->
      Some
        (RecordBinding
           {
             rb_type_params = type_params;
             rb_fields = fields;
             rb_is_value = is_value;
             rb_contains_resource = contains_resource;
           })
  | AliasSymbol { type_params; target } ->
      Some (AliasBinding { ab_type_params = type_params; ab_target = target })
  | OpaqueAliasSymbol { type_params; target; home_module } ->
      Some
        (OpaqueAliasBinding
           {
             oab_type_params = type_params;
             oab_target = target;
             oab_home_module = home_module;
           })
  | VarSymbol _ | FuncSymbol _ | ConstructorSymbol _ -> None

let scope_of_symbols symbols =
  let by_name =
    List.fold_right
      (fun sym by_name -> StringMap.add sym.name sym by_name)
      symbols StringMap.empty
  in
  { symbols; by_name }

let add_symbol_to_scope scope sym =
  {
    symbols = sym :: scope.symbols;
    by_name = StringMap.add sym.name sym scope.by_name;
  }

let scope_symbols scope = scope.symbols

let update_type_index type_index sym =
  match type_binding_of_symbol sym with
  | Some binding -> StringMap.add sym.name (Some binding) type_index
  | None ->
      if StringMap.mem sym.name type_index then
        StringMap.add sym.name None type_index
      else type_index

type trait_obligation = {
  obligation_type : type_expr;
  obligation_trait : trait_ref;
}
(** A pending proof that [obligation_type] satisfies [obligation_trait]. *)

(** Result of resolving a trait obligation. *)
type trait_obligation_resolution =
  | TraitObligationSatisfied
  | TraitObligationUnsatisfied
  | TraitObligationDeferred

type trait_method_sig = {
  tm_name : string;
  tm_params : type_expr list; (* Parameter types (may contain TySelf) *)
  tm_return : type_expr; (* Return type (may contain TySelf) *)
  tm_is_pure : bool;
  tm_has_default : bool; (* Has default implementation *)
  tm_default_body : Ast.expr option;
      (* The default body AST, if [tm_has_default]. Used
                                         to synthesize [ci_methods] for impls that omit
                                         the method. *)
  tm_param_names : string option list;
      (* Parameter names from the trait decl, used
                                           when synthesizing the impl's func_decl. *)
}
(** Trait method signature for trait registry *)

type trait_def = {
  td_def_id : def_id;
  td_name : string;
  td_type_params : string list; (* e.g., ["T"] for Iterator[T] *)
  td_supertraits : string list;
  td_methods : trait_method_sig list;
  td_loc : loc option;
  td_module_path : string option;
}
(** Trait definition for registry. See [env.mli] for the full docstring
    on [td_loc] / [td_module_path]; short version: [td_loc] is the source
    location of the declaration ([None] for [env_builtins] stubs),
    [td_module_path] is the logical module name (e.g. ["std/traits"])
    used for duplicate-trait diagnostics. *)

type impl_instance = Env_types.impl_instance = {
  ii_def_id : def_id;
  ii_trait : string;
  ii_for_type : type_expr;
  ii_bounds : bound_type_param list;
  ii_is_builtin : bool;
  ii_loc : loc option;
}
(** [impl_instance] re-exported from [Env_types]. *)

type env = {
  scopes : scope list;
  type_index : type_index;
  current_function : string option; (* For checking purity *)
  current_function_pure : bool;
  type_params_in_scope : string list;
      (* Type parameters in current generic context *)
  type_param_bounds : bound_type_param list; (* Type params with their bounds *)
  trait_functions : (string * string) list; (* (function_name, trait_name) *)
  traits : trait_def list; (* Registered trait definitions *)
  impls : impl_instance list; (* Registered impl instances *)
  impl_index : (string, impl_instance list) Hashtbl.t;
      (* Impls indexed by trait name *)
  overloads : (string, overload_entry list) Hashtbl.t;
      (** Overload sets keyed by function name *)
  ufcs_methods : (string, overload_entry list) Hashtbl.t;
      (** Method-only functions: accessible via UFCS but not as bare names *)
}
(** Environment is a stack of scopes *)

(** Empty environment. Reads the ambient [Session.current ()] for the
    shared [impl_index] / [ufcs_methods] tables — those are session-owned
    (one set per compile) so impl and method registrations made by earlier
    [typecheck_module] calls within the same compile are visible to later
    ones, without leaking across independent [Pipeline.compile] invocations
    in the same OCaml process.

    Ordinary overload sets are lexical/import-scope data, so each env gets a
    fresh table. Sharing them at session scope lets one module's selective
    imports influence another module's unrelated name resolution.

    Each [Pipeline.compile] runs inside [Session.with_current
    (Session.create ())], which makes the fresh session's tables the
    ones [Env.empty ()] picks up. Tests that need isolation should
    wrap in [Session.with_current (Session.create ())]; tests that
    don't need isolation share the process-default session (same
    behavior as before the session refactor — see
    [Session.current_ref]). *)
let empty () : env =
  let sess = Session.current () in
  {
    scopes = [ empty_scope ];
    type_index = StringMap.empty;
    current_function = None;
    current_function_pure = false;
    type_params_in_scope = [];
    type_param_bounds = [];
    trait_functions = [];
    traits = [];
    impls = [];
    impl_index = sess.impl_index;
    overloads = Hashtbl.create 32;
    ufcs_methods = sess.ufcs_methods;
  }

(** Push a new scope *)
let push_scope (env : env) : env =
  { env with scopes = empty_scope :: env.scopes }

(** Add a symbol to the current scope *)
let add_symbol (env : env) (sym : symbol) : env =
  let type_index = update_type_index env.type_index sym in
  match env.scopes with
  | [] ->
      { env with scopes = [ add_symbol_to_scope empty_scope sym ]; type_index }
  | current :: rest ->
      { env with scopes = add_symbol_to_scope current sym :: rest; type_index }

(** Look up a symbol by name in the current (topmost) scope only *)
let lookup_in_current_scope (env : env) (name : string) : symbol option =
  match env.scopes with
  | [] -> None
  | current :: _ -> StringMap.find_opt name current.by_name

(** Look up a symbol by name in all scopes *)
let lookup (env : env) (name : string) : symbol option =
  let rec search scopes =
    match scopes with
    | [] -> None
    | scope :: rest -> (
        match StringMap.find_opt name scope.by_name with
        | Some s -> Some s
        | None -> search rest)
  in
  search env.scopes

let find_type_binding (env : env) (name : string) : type_binding option =
  match StringMap.find_opt name env.type_index with
  | Some binding -> binding
  | None -> None

(** Human-readable label for a symbol kind, used in error messages *)
let symbol_kind_label (sym : symbol) : string =
  match sym.kind with
  | VarSymbol _ -> "variable"
  | FuncSymbol _ -> "function"
  | TypeSymbol _ -> "type"
  | RecordSymbol _ -> "record"
  | AliasSymbol _ -> "type alias"
  | OpaqueAliasSymbol _ -> "opaque type"
  | ConstructorSymbol _ -> "constructor"

(* ============================================================================
   Convenient symbol addition functions
   ============================================================================ *)

(** Add a variable to the environment *)
let add_var (env : env) (name : string) (var_type : type_expr) ?source_type
    ?(mutability = Immutable) ?(origin = LetBinding)
    ?(refinement = Refinement.unrefined_binding) () : env =
  add_symbol env
    {
      name;
      kind = VarSymbol { var_type; source_type; mutability; origin; refinement };
    }

(** Check if a variable is a function parameter *)
let is_func_param (env : env) (name : string) : bool =
  match lookup env name with
  | Some { kind = VarSymbol { origin = FuncParam; _ }; _ } -> true
  | _ -> false

(** Check if a variable is a for-loop variable *)
let is_for_loop_var (env : env) (name : string) : bool =
  match lookup env name with
  | Some { kind = VarSymbol { origin = ForLoopVar; _ }; _ } -> true
  | _ -> false

let is_scoped_resource_var (env : env) (name : string) : bool =
  match lookup env name with
  | Some { kind = VarSymbol { origin = ScopedResource; _ }; _ } -> true
  | _ -> false

let is_scoped_resource_derived_var (env : env) (name : string) : bool =
  match lookup env name with
  | Some
      {
        kind =
          VarSymbol
            { origin = ScopedResourceDerived | ScopedResourceUnavailable _; _ };
        _;
      } ->
      true
  | _ -> false

let scoped_resource_unavailable_owner (env : env) (name : string) :
    string option =
  match lookup env name with
  | Some { kind = VarSymbol { origin = ScopedResourceUnavailable owner; _ }; _ }
    ->
      Some owner
  | _ -> None

let is_scoped_resource_related_var (env : env) (name : string) : bool =
  match lookup env name with
  | Some
      {
        kind =
          VarSymbol
            {
              origin =
                ( ScopedResource | ScopedResourceDerived
                | ScopedResourceUnavailable _ );
              _;
            };
        _;
      } ->
      true
  | _ -> false

(** Add a function to the environment *)
let add_func (env : env) (name : string) (func_type : type_expr) ?callable_id
    ?(type_params = []) ?(param_names = []) ?(purity = Impure)
    ?(origin = UserDefined) ?resource_args ?module_path ?(dim_constraints = [])
    ?loop_producer ?(debug_only = false) () : env =
  let resource_args =
    match resource_args with
    | Some policy -> policy
    | None -> RejectResourceArgs
  in
  let callable_id =
    match callable_id with
    | Some id -> id
    | None -> Session.mint_def_id (Session.current ())
  in
  add_symbol env
    {
      name;
      kind =
        FuncSymbol
          {
            callable_id;
            func_type;
            type_params;
            param_names;
            purity;
            origin;
            resource_args;
            module_path;
            dim_constraints;
            loop_producer;
            debug_only;
          };
    }

let is_debug_only_func (env : env) (name : string) : bool =
  match lookup env name with
  | Some { kind = FuncSymbol { debug_only; _ }; _ } -> debug_only
  | _ -> false

let is_debug_only_overload_set (env : env) (name : string) : bool =
  match Hashtbl.find_opt env.overloads name with
  | Some (_ :: _ as entries) -> List.for_all (fun e -> e.ol_debug_only) entries
  | _ -> false

(** Add a type declaration to the environment *)
let add_type ?(with_ctors = true) ?(kind = TypeUnion)
    ?(contains_resource = false) (env : env) (name : string)
    (type_params : string list) (variants : variant list) : env =
  let env =
    add_symbol env
      {
        name;
        kind =
          TypeSymbol
            { type_params; variants; type_kind = kind; contains_resource };
      }
  in
  if not with_ctors then env
  else
    (* Add each variant as a constructor *)
    List.fold_left
      (fun env v ->
        add_symbol env
          {
            name = v.variant_name;
            kind =
              ConstructorSymbol
                {
                  parent_type = name;
                  constructor_id = Session.mint_def_id (Session.current ());
                  type_params;
                  field_types = v.variant_fields;
                  tag = v.variant_tag;
                };
          })
      env variants

(** Add a record declaration to the environment *)
let add_record (env : env) (name : string) (type_params : string list)
    (fields : field_decl list) ?(is_value = false) ?(contains_resource = false)
    () : env =
  add_symbol env
    {
      name;
      kind = RecordSymbol { type_params; fields; is_value; contains_resource };
    }

(** Check if a record type is a value type (struct) *)
let is_value_record (env : env) (name : string) : bool =
  match find_type_binding env name with
  | Some (RecordBinding { rb_is_value = true; _ }) -> true
  | _ -> false

(** Add a type alias to the environment *)
let add_alias (env : env) (name : string) (type_params : string list)
    (target : type_expr) : env =
  add_symbol env { name; kind = AliasSymbol { type_params; target } }

(** Add an opaque type alias to the environment.
    Unlike [add_alias], this is not expanded by [resolve_alias]; it is a
    nominal type during frontend checking and erased only by backend layout. *)
let add_opaque_alias (env : env) (name : string) (type_params : string list)
    (target : type_expr) ~(home_module : string option) : env =
  add_symbol env
    { name; kind = OpaqueAliasSymbol { type_params; target; home_module } }

(* ============================================================================
   Symbol lookup helpers
   ============================================================================ *)

(** Get the type of a variable *)
let get_var_type (env : env) (name : string) : type_expr option =
  match lookup env name with
  | Some { kind = VarSymbol { var_type; _ }; _ } -> Some var_type
  | Some { kind = FuncSymbol { func_type; _ }; _ } -> Some func_type
  | _ -> None

let get_var_refinement (env : env) (name : string) :
    Refinement.binding_refinement option =
  match lookup env name with
  | Some { kind = VarSymbol { refinement; _ }; _ } -> Some refinement
  | _ -> None

let set_var_refinement (env : env) (name : string)
    (refinement : Refinement.binding_refinement) : env option =
  let update_symbol sym =
    match sym with
    | { name = sym_name; kind = VarSymbol var } when String.equal sym_name name
      ->
        Some { sym with kind = VarSymbol { var with refinement } }
    | _ -> None
  in
  let rec update_scope acc = function
    | [] -> None
    | sym :: rest -> (
        match update_symbol sym with
        | Some updated -> Some (List.rev_append acc (updated :: rest))
        | None -> update_scope (sym :: acc) rest)
  in
  let rec update_scopes acc = function
    | [] -> None
    | scope :: rest -> (
        match update_scope [] (scope_symbols scope) with
        | Some updated_symbols ->
            let updated_scope = scope_of_symbols updated_symbols in
            Some
              { env with scopes = List.rev_append acc (updated_scope :: rest) }
        | None -> update_scopes (scope :: acc) rest)
  in
  update_scopes [] env.scopes

(** Get a function's info *)
let get_func_info (env : env) (name : string) :
    (type_expr * bound_type_param list * purity) option =
  match lookup env name with
  | Some { kind = FuncSymbol { func_type; type_params; purity; _ }; _ } ->
      Some (func_type, type_params, purity)
  | _ -> None

let get_func_callable_id (env : env) (name : string) : def_id option =
  match lookup env name with
  | Some { kind = FuncSymbol { callable_id; _ }; _ } -> Some callable_id
  | _ -> None

let get_func_loop_producer (env : env) (name : string) : loop_producer option =
  match lookup env name with
  | Some { kind = FuncSymbol { loop_producer; _ }; _ } -> loop_producer
  | _ -> None

(** Get a function's dimension constraints from its where clause *)
let get_dim_constraints (env : env) (name : string) :
    (type_expr * type_expr) list =
  match lookup env name with
  | Some { kind = FuncSymbol { dim_constraints; _ }; _ } -> dim_constraints
  | _ -> []

(** Check if a function name resolves to a compiler builtin (not user-defined) *)
let is_builtin_func (env : env) (name : string) : bool =
  match lookup env name with
  | Some { kind = FuncSymbol { origin = Builtin; _ }; _ } -> true
  | _ -> false

(** Check if a function name resolves to a lexical, non-builtin function.
    Imported functions carry [module_path = Some _]; builtins carry
    [origin = Builtin]. A local function must win over session-wide overload
    entries registered while typechecking other modules in the same compile. *)
let is_local_func (env : env) (name : string) : bool =
  match lookup env name with
  | Some { kind = FuncSymbol { origin = Builtin; _ }; _ } -> false
  | Some { kind = FuncSymbol { module_path = None; _ }; _ } -> true
  | _ -> false

(** Get a function's parameter names *)
let get_func_param_names (env : env) (name : string) : string option list option
    =
  match lookup env name with
  | Some { kind = FuncSymbol { param_names; _ }; _ } -> Some param_names
  | _ -> None

(** Get a type declaration *)
let get_type_decl (env : env) (name : string) :
    (string list * variant list) option =
  match find_type_binding env name with
  | Some (TypeBinding { tb_type_params; tb_variants; _ }) ->
      Some (tb_type_params, tb_variants)
  | _ -> None

(** Get a type declaration's kind *)
let get_type_kind (env : env) (name : string) : type_kind option =
  match find_type_binding env name with
  | Some (TypeBinding { tb_type_kind; _ }) -> Some tb_type_kind
  | _ -> None

let get_type_contains_resource (env : env) (name : string) : bool =
  match find_type_binding env name with
  | Some (TypeBinding { tb_contains_resource; _ }) -> tb_contains_resource
  | Some (RecordBinding { rb_contains_resource; _ }) -> rb_contains_resource
  | _ -> false

(** Get a constructor info *)
let get_constructor (env : env) (name : string) :
    (string * string list * type_expr list * int) option =
  match lookup env name with
  | Some
      {
        kind =
          ConstructorSymbol { parent_type; type_params; field_types; tag; _ };
        _;
      } ->
      Some (parent_type, type_params, field_types, tag)
  | _ -> None

let get_constructor_callable_id (env : env) (name : string) : int option =
  match lookup env name with
  | Some { kind = ConstructorSymbol { constructor_id; _ }; _ } ->
      Some constructor_id
  | _ -> None

(** Get a record declaration *)
let get_record (env : env) (name : string) :
    (string list * field_decl list) option =
  match find_type_binding env name with
  | Some (RecordBinding { rb_type_params; rb_fields; _ }) ->
      Some (rb_type_params, rb_fields)
  | _ -> None

(** Find all record/struct type names whose field names exactly match the given set.
    Returns a list of type names. Used to detect ambiguous record literals. *)
let find_records_with_fields (env : env) (field_names : string list) :
    string list =
  let sorted_names = List.sort String.compare field_names in
  let matches = ref [] in
  List.iter
    (fun scope ->
      List.iter
        (fun sym ->
          match sym.kind with
          | RecordSymbol { fields; _ } ->
              let sym_fields =
                List.sort String.compare
                  (List.map (fun f -> f.field_name) fields)
              in
              if sym_fields = sorted_names && not (List.mem sym.name !matches)
              then matches := sym.name :: !matches
          | _ -> ())
        (scope_symbols scope))
    env.scopes;
  List.rev !matches

(** Get a type alias *)
let get_alias (env : env) (name : string) : (string list * type_expr) option =
  match find_type_binding env name with
  | Some (AliasBinding { ab_type_params; ab_target }) ->
      Some (ab_type_params, ab_target)
  | _ -> None

let get_opaque_alias (env : env) (name : string) :
    (string list * type_expr * string option) option =
  match find_type_binding env name with
  | Some (OpaqueAliasBinding { oab_type_params; oab_target; oab_home_module })
    ->
      Some (oab_type_params, oab_target, oab_home_module)
  | _ -> None

let rec disambiguate_nominal_dim_application (env : env) (ty : type_expr) :
    type_expr =
  let nominal_dim_params name =
    let params =
      match get_record env name with
      | Some (ps, _) -> Some ps
      | None -> (
          match get_type_decl env name with
          | Some (ps, _) -> Some ps
          | None -> (
              match get_alias env name with
              | Some (ps, _) -> Some ps
              | None -> (
                  match get_opaque_alias env name with
                  | Some (ps, _, _) -> Some ps
                  | None -> None)))
    in
    match params with
    | Some ps when ps <> [] && List.for_all Types.Dim.is_var_name ps -> Some ps
    | _ -> None
  in
  match ty with
  | TyArray (TyNamed (name, []), dims) -> (
      let dims = List.map (disambiguate_nominal_dim_application env) dims in
      match nominal_dim_params name with
      | Some ps when List.length ps = List.length dims -> TyNamed (name, dims)
      | _ -> TyArray (TyNamed (name, []), dims))
  | TyArray (elem, dims) ->
      TyArray
        ( disambiguate_nominal_dim_application env elem,
          List.map (disambiguate_nominal_dim_application env) dims )
  | TyNamed (name, args) ->
      TyNamed (name, List.map (disambiguate_nominal_dim_application env) args)
  | TyFunc { params; return; is_pure } ->
      TyFunc
        {
          params = List.map (disambiguate_nominal_dim_application env) params;
          return = disambiguate_nominal_dim_application env return;
          is_pure;
        }
  | TyTuple elems ->
      TyTuple (List.map (disambiguate_nominal_dim_application env) elems)
  | TyRange inner -> TyRange (disambiguate_nominal_dim_application env inner)
  | TyDimOp (op, a, b) ->
      TyDimOp
        ( op,
          disambiguate_nominal_dim_application env a,
          disambiguate_nominal_dim_application env b )
  | _ -> ty

(** Direct (non-chaining) substitution for alias resolution.
    Unlike apply_subst, this only substitutes each variable once,
    avoiding infinite loops from swapped variables like #M→#N, #N→#M. *)
let direct_subst (bindings : (string * type_expr) list) (ty : type_expr) :
    type_expr =
  Types.map_type_expr
    (fun t ->
      let name =
        match t with TyVar n | TyNamed (n, []) -> Some n | _ -> None
      in
      Option.bind name (fun n -> List.assoc_opt n bindings))
    ty

(** Resolve a type alias (recursively, with cycle detection) *)
let resolve_alias (env : env) (ty : type_expr) : type_expr =
  let rec resolve ~visited ty =
    match ty with
    | TyNamed (name, args) -> (
        let args = List.map (resolve ~visited) args in
        if List.mem name visited then TyNamed (name, args)
          (* cycle detected — stop recursing *)
        else
          match get_alias env name with
          | Some (type_params, target) ->
              (* Direct substitution (no chaining) to avoid loops from swapped params *)
              let bindings =
                List.map2 (fun param arg -> (param, arg)) type_params args
              in
              resolve ~visited:(name :: visited) (direct_subst bindings target)
          | None -> TyNamed (name, args))
    | TyFunc f ->
        TyFunc
          {
            f with
            params = List.map (resolve ~visited) f.params;
            return = resolve ~visited f.return;
          }
    | TyArray (elem, dims) ->
        TyArray (resolve ~visited elem, List.map (resolve ~visited) dims)
    | TyTuple elems -> TyTuple (List.map (resolve ~visited) elems)
    | TyRange inner -> TyRange (resolve ~visited inner)
    | TyDimOp (op, a, b) ->
        Types.Dim.normalize
          (TyDimOp (op, resolve ~visited a, resolve ~visited b))
    | _ -> ty
  in
  resolve ~visited:[] ty

let function_type_purity (env : env) (ty : type_expr) : purity option =
  match resolve_alias env ty with
  | TyFunc { is_pure; _ } -> Some (if is_pure then Pure else Impure)
  | _ -> None

let is_impure_function_type (env : env) (ty : type_expr) : bool =
  match function_type_purity env ty with
  | Some Impure -> true
  | Some Pure | None -> false

(** Strip parser-level trait-bound encoding from a type parameter name. *)
let type_param_name param = strip_type_param_bounds param

let type_param_names params = List.map type_param_name params
let bound_type_param_names = Generic_params.param_names

let overload_type_param_names (entry : overload_entry) : string list =
  Generic_params.param_names entry.ol_type_params

(* ============================================================================
   Function context management
   ============================================================================ *)

(** Enter a function context *)
let enter_function (env : env) (name : string) (pure : bool)
    (type_params : string list) : env =
  let stripped = type_param_names type_params in
  {
    env with
    current_function = Some name;
    current_function_pure = pure;
    type_params_in_scope = stripped @ env.type_params_in_scope;
  }

(** Get the current type parameters in scope *)
let get_type_params (env : env) : string list = env.type_params_in_scope

(* ============================================================================
   Trait and Type Parameter Bound Management
   ============================================================================ *)

(** Check whether registering [(func_name, trait_name)] would collide
    with an existing binding of the same function name to a DIFFERENT
    trait. Returns the existing trait name when a collision would
    occur, [None] otherwise.

    Idempotent re-registration (same [func_name] bound to the same
    [trait_name]) is NOT a collision — this is the supertrait-sweep
    pattern: registering [Orderable: Equatable] re-binds [equals] under
    its declaring trait [Equatable], which is already what's
    registered. Callers use this to emit a diagnostic at the trait
    declaration / import site when two unrelated traits claim the same
    method name. *)
let trait_function_collision (env : env) (func_name : string)
    (trait_name : string) : string option =
  match List.assoc_opt func_name env.trait_functions with
  | Some existing_trait when existing_trait <> trait_name -> Some existing_trait
  | _ -> None

(** Register a trait function (maps function name to its trait).

    Does not collision-check — callers that want a diagnostic for two
    unrelated traits sharing a method name should consult
    [trait_function_collision] first. Duplicate [(func_name,
    trait_name)] entries are tolerated by [get_function_trait], which
    returns the first; but the list is an append here, so callers that
    emit collisions pre-check avoid accumulating duplicates. *)
let add_trait_function (env : env) (func_name : string) (trait_name : string) :
    env =
  { env with trait_functions = (func_name, trait_name) :: env.trait_functions }

(** Get the trait that a function belongs to (if any) *)
let get_function_trait (env : env) (func_name : string) : string option =
  List.assoc_opt func_name env.trait_functions

(** Build a trait obligation from a type and parser-level trait name. *)
let trait_obligation obligation_type trait_name =
  { obligation_type; obligation_trait = Generic_params.trait_ref trait_name }

(** Generate obligations for applying a bounded type parameter to a concrete type. *)
let trait_obligations_for_bound_type_param param concrete_type =
  List.map
    (fun obligation_trait ->
      { obligation_type = concrete_type; obligation_trait })
    param.param_bounds

(** Set type parameter bounds for the current context *)
let set_type_param_bounds (env : env) (params : bound_type_param list) : env =
  { env with type_param_bounds = params @ env.type_param_bounds }

(** Get the bounds for a type parameter *)
let get_type_param_bounds (env : env) (param_name : string) : string list =
  match
    List.find_opt (fun p -> p.param_name = param_name) env.type_param_bounds
  with
  | Some info -> Generic_params.trait_ref_names info.param_bounds
  | None -> []

(** Check if a type parameter has a specific trait bound *)
let has_trait_bound (env : env) (param_name : string) (trait_name : string) :
    bool =
  List.mem trait_name (get_type_param_bounds env param_name)

(* ============================================================================
   Trait Definition and Impl Management
   ============================================================================ *)

(** Register a trait definition *)
let add_trait (env : env) (trait : trait_def) : env =
  { env with traits = trait :: env.traits }

(** Structural equality for two trait definitions, independent of where
    they came from.

    Compared fields: [td_name], [td_type_params], [td_supertraits],
    [td_methods]. Ignored fields: [td_loc], [td_module_path] — those
    are metadata about WHERE the trait was declared, not what it
    declares.

    Method order IS significant — two trait definitions that permute
    their methods will compare unequal. That matches the language's
    stance elsewhere (method lookup is order-sensitive for overload
    resolution). Supertrait order is also significant, for the same
    reason and to keep this check cheap. *)
let trait_defs_structurally_equal (a : trait_def) (b : trait_def) : bool =
  let methods_equal (ma : trait_method_sig) (mb : trait_method_sig) =
    ma.tm_name = mb.tm_name
    && ma.tm_params = mb.tm_params
    && ma.tm_return = mb.tm_return
    && ma.tm_is_pure = mb.tm_is_pure
    && ma.tm_has_default = mb.tm_has_default
    (* Intentionally skipped fields:
       - [tm_param_names]: purely cosmetic (IDE hover, doc). A trait
         signature `func f(a: T)` and `func f(b: T)` are the same
         contract. [env_builtins] omits them ([]); the AST-parser
         fills them from source. Counting them as significant would
         mean every stdlib trait clashes with its env_builtins stub.
       - [tm_default_body]: expression-level equality is expensive and
         two parses of the same source can diverge in non-semantic AST
         details (locs, meta ids). The [tm_has_default] bit captures
         "has a default" for correctness-relevant decisions (synthesis,
         missing-method checks); body semantics are trusted to match if
         both copies came from the same trait source. *)
  in
  a.td_name = b.td_name
  && a.td_type_params = b.td_type_params
  && a.td_supertraits = b.td_supertraits
  && List.length a.td_methods = List.length b.td_methods
  && List.for_all2 methods_equal a.td_methods b.td_methods

(** Register a trait with duplicate-check.

    - If no trait by that name is present in [env.traits], add it.
    - If the same name is present and structurally equal, no-op: the
      env is returned unchanged. This is the idempotent case — the
      same trait declaration reaching the env via multiple import
      chains is a normal occurrence.
    - If the existing entry is an [env_builtins] stub (identified by
      [td_module_path = None] AND [td_loc = None]), the incoming
      declaration REPLACES it rather than conflicting. Stubs exist
      purely to register names / supertrait chains / impls before
      std/traits.brp has been loaded; the user-facing declaration
      carries the authoritative method list and should win silently.
    - If the same name is present but NOT structurally equal AND the
      existing entry is NOT a stub, return [Error msg] with a
      diagnostic. The caller decides whether to surface the error
      (pipeline path) or ignore it (dev scaffolding).

    Only consults [env.traits], not the session-scoped registry —
    conflict checks at the env boundary are per-file. Cross-module
    conflicts are surfaced separately by [Session.register_module_traits]
    when a second module tries to register the same trait name. *)
let try_add_trait (env : env) (trait : trait_def) : (env, string) result =
  let is_stub td = td.td_module_path = None && td.td_loc = None in
  let replace_stub env name trait =
    (* Swap the stub for the incoming def in-place by filtering it out
       before prepending, so [get_trait] (which returns the first match)
       sees only the authoritative version. *)
    {
      env with
      traits = trait :: List.filter (fun t -> t.td_name <> name) env.traits;
    }
  in
  match List.find_opt (fun t -> t.td_name = trait.td_name) env.traits with
  | None -> Ok (add_trait env trait)
  | Some existing when trait_defs_structurally_equal existing trait -> Ok env
  | Some existing when is_stub existing ->
      Ok (replace_stub env trait.td_name trait)
  | Some existing ->
      let loc_str td =
        match (td.td_module_path, td.td_loc) with
        | Some p, _ -> Printf.sprintf " (from %s)" p
        | None, Some l -> (
            match l.loc_file with
            | Some f -> Printf.sprintf " (from %s)" f
            | None -> "")
        | None, None -> ""
      in
      Error
        (Printf.sprintf
           "conflicting declaration for trait '%s'%s: another declaration%s \
            has different supertraits or methods"
           trait.td_name (loc_str trait) (loc_str existing))

(** Pure conversion from the parsed [Ast.trait_decl] to the typecheck-
    side [trait_def]. No env side effects — callers (both
    [Typecheck.register_trait] for the import path and [get_trait]'s
    session fallback) construct the record from the AST. Missing param
    type annotations are silently dropped here, matching the historical
    [register_trait] behavior; trait-method validation in
    [Typecheck.first_pass] is the authoritative catcher for that. *)
let trait_def_of_decl ?loc ?module_path (trait : trait_decl) : trait_def =
  {
    td_def_id = Session.mint_def_id (Session.current ());
    td_name = trait.trait_name;
    td_type_params = Ast.type_param_names trait.trait_type_params;
    td_supertraits = trait.trait_supertraits;
    td_methods =
      List.map
        (fun (m : trait_method) ->
          let param_types =
            List.filter_map (fun (p : param) -> p.param_type) m.method_params
          in
          let return_type =
            Option.value m.method_return_type ~default:ty_void
          in
          {
            tm_name = m.method_name;
            tm_params = param_types;
            tm_return = return_type;
            tm_is_pure = m.method_is_pure;
            tm_has_default = Option.is_some m.method_default_body;
            tm_default_body = m.method_default_body;
            tm_param_names =
              List.map (fun (p : param) -> p.param_name) m.method_params;
          })
        trait.trait_methods;
    td_loc = loc;
    td_module_path = module_path;
  }

(** Look up a trait by name.

    Lookup order:
    1. Per-file [env.traits] — populated from the current module's own
       [DTrait] decls in [first_pass], plus every imported module's
       [DTrait] decls via [register_module_trait_defs] in [process_import].
    2. Session-scoped [trait_index] — populated from EVERY loaded
       module, import or not. Makes the supertrait graph uniformly
       resolvable: a file that writes [T: Orderable] without importing
       [traits] still sees [Orderable: Equatable] as long as the
       [traits] module has been loaded somewhere in the compilation.

    The session fallback only fires on a per-file miss, so
    import-registered trait defs always win. That preserves the
    existing [register_trait] path (which also registers
    [trait_functions] entries for bare-name method dispatch) and means
    the fallback is strictly additive — it never overrides what the
    importer already chose. *)
let get_trait (env : env) (name : string) : trait_def option =
  match List.find_opt (fun t -> t.td_name = name) env.traits with
  | Some _ as hit -> hit
  | None -> (
      match Session.find_trait_decl (Session.current ()) name with
      | None -> None
      | Some (trait, m) ->
          Some (trait_def_of_decl ~module_path:m.Session.name trait))

(** Render a trait name for a diagnostic, qualifying with the trait's
    home module when known. Builtin traits (registered by
    [env_builtins] with [td_module_path = None]) and source-less
    lookup results render bare. Used by error emitters in [infer.ml]
    so users see e.g. ["Addable (from std/traits)"] rather than just
    ["Addable"] — disambiguates when multiple modules could own a
    trait of the same name. *)
let format_trait_name (env : env) (trait_name : string) : string =
  match get_trait env trait_name with
  | Some td -> (
      match td.td_module_path with
      | Some path -> Printf.sprintf "%s (from %s)" trait_name path
      | None -> trait_name)
  | None -> trait_name

(** Render a type name for a diagnostic, qualifying with its home
    module via [Session.find_type_home] when known. Builtin types
    registered via [env_builtins] (no home module in the session
    index) and types from the current file render bare. Track B. *)
let format_type_name (name : string) : string =
  match Session.find_type_home (Session.current ()) name with
  | Some path -> Printf.sprintf "%s (from %s)" name path
  | None -> name

(** Render a constructor reference for a diagnostic, qualifying with
    the constructor's parent type's home module. Looks up [name] in
    the env's constructor table to find the parent type, then the
    session's [type_index] for that type's home module. When either
    lookup misses (user-defined constructor in the current file,
    builtin constructor from [env_builtins]) the name renders bare.
    Track B. *)
let format_constructor_ref (env : env) (name : string) : string =
  match get_constructor env name with
  | Some (parent_type, _, _, _) -> (
      match Session.find_type_home (Session.current ()) parent_type with
      | Some path -> Printf.sprintf "%s (from %s)" name path
      | None -> name)
  | None -> name

(** Render a single overload reference for a diagnostic, qualifying
    with the overload's home module when known. Pre-imported
    primitives / prelude functions have [ol_module_path = None] and
    render bare. Used by error emitters that reach into an
    [overload_entry] — Track B's "which `map`?" disambiguator. *)
let format_overload_ref (name : string) (entry : overload_entry) : string =
  match entry.ol_module_path with
  | Some path -> Printf.sprintf "%s (from %s)" name path
  | None -> name

(** Render a list of overload candidates for a diagnostic — one per
    line, each qualified via [format_overload_ref]. Used when an
    overload set is ambiguous and the error message should enumerate
    all candidate sources so the user can pick one. Empty list
    returns the empty string; callers should treat that as "no
    candidates to list" and fall back to a bare-name message. *)
let format_overload_candidates (name : string) (entries : overload_entry list) :
    string =
  match entries with
  | [] -> ""
  | _ ->
      String.concat "\n"
        (List.map
           (fun e -> Printf.sprintf "  - %s" (format_overload_ref name e))
           entries)

(** Check if a trait has another trait as a supertrait (transitively).
    Walks the supertrait graph with a visited-set to stop at back-edges.
    Cyclic supertrait declarations (`trait A: B` + `trait B: A`) are ill-
    formed — typecheck should ultimately reject them — but ad-hoc cycles
    can form mid-typecheck during batch-mode module loading before all
    registrations stabilize, and the hang would mask the real error.
    Returning [false] on back-edges is the conservative answer: if a
    cycle exists, neither direction can validly claim supertrait-of the
    other, so the query fails and surfaces a downstream error rather
    than silently looping. *)
let trait_has_supertrait (env : env) (trait_name : string) (target : string) :
    bool =
  let rec walk visited name =
    if List.mem name visited then false
    else
      match get_trait env name with
      | None -> false
      | Some td ->
          List.mem target td.td_supertraits
          || List.exists
               (fun super -> walk (name :: visited) super)
               td.td_supertraits
  in
  walk [] trait_name

(** Collect every method name declared on [trait_name] OR any of its
    transitive supertraits. Used by the default-body synthesizer
    (Option D / step 5) to decide which bare-name identifier calls
    inside a synthesized body are trait-method references and should
    be rewritten into UFCS-dispatch form so they resolve through the
    impl's methods rather than through the global trait-function
    table. Duplicates are possible (same method declared at multiple
    levels of the hierarchy); callers that need a set-view should
    dedup. Cycle-safe via a visited set — ill-formed supertrait
    cycles terminate rather than hang. *)
let trait_method_names_transitive (env : env) (trait_name : string) :
    string list =
  let rec walk visited name =
    if List.mem name visited then []
    else
      match get_trait env name with
      | None -> []
      | Some td ->
          let own =
            List.map (fun (m : trait_method_sig) -> m.tm_name) td.td_methods
          in
          let from_supers =
            List.concat_map (walk (name :: visited)) td.td_supertraits
          in
          own @ from_supers
  in
  walk [] trait_name

(** Like [trait_method_names_transitive] but pairs each method name
    with the trait that actually DECLARES it (not the starting trait).
    A method inherited through the supertrait graph is reported under
    its originating trait, which is what [add_trait_function] needs
    for correct dispatch — [base_op] from [trait Derived: Base]
    dispatches via Base, not Derived. Same cycle-safety contract. *)
let trait_methods_with_declaring_trait (env : env) (trait_name : string) :
    (string * string) list =
  let rec walk visited name =
    if List.mem name visited then []
    else
      match get_trait env name with
      | None -> []
      | Some td ->
          let own =
            List.map
              (fun (m : trait_method_sig) -> (m.tm_name, name))
              td.td_methods
          in
          let from_supers =
            List.concat_map (walk (name :: visited)) td.td_supertraits
          in
          own @ from_supers
  in
  walk [] trait_name

(** Check if a type parameter satisfies a trait bound transitively.
    E.g., T: Integer satisfies "Addable" because Integer's supertraits include Addable. *)
let has_trait_bound_transitive (env : env) (param_name : string)
    (trait_name : string) : bool =
  has_trait_bound env param_name trait_name
  ||
  let direct_bounds = get_type_param_bounds env param_name in
  List.exists
    (fun bound_trait -> trait_has_supertrait env bound_trait trait_name)
    direct_bounds

(** Look up a trait method signature by function name across all traits that
    a type parameter is bounded by (including supertraits). Returns the method
    sig and the concrete type variable to substitute for Self. *)
let find_trait_method_for_param (env : env) (param_name : string)
    (func_name : string) : (trait_method_sig * string) option =
  let bounds = get_type_param_bounds env param_name in
  (* Visited-set to guard against cyclic supertrait declarations (e.g.
     [trait A: B] + [trait B: A]). Returns [None] at back-edges — the
     method either exists on a non-cyclic branch or it doesn't. *)
  let rec search_trait visited tn =
    if List.mem tn visited then None
    else
      match get_trait env tn with
      | None -> None
      | Some td -> (
          match
            List.find_opt (fun m -> m.tm_name = func_name) td.td_methods
          with
          | Some m -> Some (m, tn)
          | None ->
              List.find_map (search_trait (tn :: visited)) td.td_supertraits)
  in
  List.find_map (search_trait []) bounds

(** Register an impl instance *)
let add_impl (env : env) (impl : impl_instance) : env =
  let existing =
    match Hashtbl.find_opt env.impl_index impl.ii_trait with
    | Some lst -> lst
    | None -> []
  in
  Hashtbl.replace env.impl_index impl.ii_trait (impl :: existing);
  { env with impls = impl :: env.impls }

(** Find a previously-registered impl whose (trait, for-type) overlaps with
    [candidate]. Two impls overlap when they target the same trait and their
    for-types bidirectionally unify with the type parameters of either impl
    treated as free variables — i.e., there exists some concrete type that
    both impls would match.

    [env_builtins] registrations (marked [ii_is_builtin = true]) are
    ignored: they never emit C and only serve to make typechecking
    succeed. Only source-level impls can collide at link time.

    Walks [env.impls] (the per-typecheck immutable list) rather than
    the session-scoped [impl_index] hashtable. Within a single
    [typecheck_module] call this is the set of impls visible from
    this file's typecheck; cross-module conflicts between different
    modules in the same compile are caught by the dedicated
    [Pipeline.check_cross_module_coherence] pass.

    Returns the first overlapping non-builtin impl, or [None]. If
    [candidate] is itself a builtin, returns [None] unconditionally
    (builtins don't conflict with anything). *)
let find_conflicting_impl (env : env) (candidate : impl_instance) :
    impl_instance option =
  if candidate.ii_is_builtin then None
  else
    let cand_params = Generic_params.param_names candidate.ii_bounds in
    List.find_opt
      (fun existing_impl ->
        if existing_impl.ii_is_builtin then false
        else if existing_impl.ii_trait <> candidate.ii_trait then false
        else
          let exist_params =
            Generic_params.param_names existing_impl.ii_bounds
          in
          let type_params = cand_params @ exist_params in
          Types.types_bidirectional ~type_params existing_impl.ii_for_type
            candidate.ii_for_type)
      env.impls

(** Alpha-rename type variables in impl's for_type to avoid occurs-check
    collisions when matching against concrete types that use the same var names.
    E.g., impl Equatable for Option[T] matching Option[List[T]] where T in the
    actual type is a different binding than T in the impl. *)
let alpha_rename_impl_vars impl_type_params impl_for_type actual_ty =
  let actual_vars = collect_type_vars actual_ty in
  let needs_rename =
    List.exists (fun p -> List.mem p actual_vars) impl_type_params
  in
  if not needs_rename then (impl_for_type, impl_type_params)
  else
    let rename_map =
      List.filter_map
        (fun v ->
          if List.mem v actual_vars then Some (v, "__impl_" ^ v) else None)
        impl_type_params
    in
    let renamed_type =
      List.fold_left
        (fun t (old_name, new_name) ->
          Types.map_type_expr
            (function
              | TyVar n when n = old_name -> Some (TyVar new_name)
              | TyBoundVar p when p.param_name = old_name ->
                  Some (TyBoundVar { p with param_name = new_name })
              | TyNamed (n, []) when n = old_name ->
                  Some (TyNamed (new_name, []))
              | _ -> None)
            t)
        impl_for_type rename_map
    in
    let renamed_vars =
      List.map
        (fun v ->
          match List.assoc_opt v rename_map with
          | Some new_name -> new_name
          | None -> v)
        impl_type_params
    in
    (renamed_type, renamed_vars)

(** Check if a concrete type implements a trait.
    Uses impl_index for O(1) trait-name lookup instead of scanning all impls.
    NOTE: This checks DIRECT impls only. Implementing a subtrait does NOT
    automatically satisfy supertrait requirements — those must be explicitly
    implemented. For type PARAMETER bounds, use has_trait_bound_transitive. *)

(** Extract substitution from a compatible type match.
    Given impl_type (with type vars) and concrete_type, return [(var_name, concrete_type)] *)
let extract_type_subst (impl_type : type_expr) (concrete_type : type_expr) :
    (string * type_expr) list =
  let subst = ref [] in
  let rec walk impl_t conc_t =
    match (impl_t, conc_t) with
    | TyVar name, _ -> subst := (name, conc_t) :: !subst
    | TyBoundVar param, _ -> subst := (param.param_name, conc_t) :: !subst
    | TyNamed (name, []), _
      when String.length name = 1 && Char.uppercase_ascii name.[0] = name.[0] ->
        subst := (name, conc_t) :: !subst
    | TyNamed (n1, args1), TyNamed (n2, args2) when n1 = n2 ->
        List.iter2 (fun a b -> walk a b) args1 args2
    | ( TyFunc { params = p1; return = r1; _ },
        TyFunc { params = p2; return = r2; _ } ) ->
        List.iter2 (fun a b -> walk a b) p1 p2;
        walk r1 r2
    | TyTuple e1, TyTuple e2 -> List.iter2 (fun a b -> walk a b) e1 e2
    | _ -> ()
  in
  (try walk impl_type concrete_type with Invalid_argument _ -> ());
  !subst

let rec type_implements_trait (env : env) (ty : type_expr) (trait_name : string)
    : bool =
  (* Structured [TyBoundVar] nodes carry inline bounds directly. Legacy
     bounds-encoded [TyVar] names remain only at compatibility boundaries.
     Plain [TyVar]/[TyNamed] type parameters consult [env.type_param_bounds],
     which [set_type_param_bounds] populates at impl/function entry.

     [TyNamed (name, [])] is ambiguous: the parser produces it both for actual
     user-declared types (`record T { ... }`) and for type parameters
     (`func f[T](x: T)`). Before treating such a name as a bounded type
     parameter, confirm it is in the current type-parameter scope and is not a
     declared record/type/alias in the current env. *)
  let trait_refs_satisfy_trait refs =
    let bounds = Generic_params.trait_ref_names refs in
    List.mem trait_name bounds
    || List.exists
         (fun bound_trait -> trait_has_supertrait env bound_trait trait_name)
         bounds
  in
  let is_declared_type name =
    get_record env name <> None
    || get_type_decl env name <> None
    || get_alias env name <> None
  in
  let bound_match =
    match ty with
    | TyBoundVar param -> trait_refs_satisfy_trait param.param_bounds
    | TyVar name -> has_trait_bound_transitive env name trait_name
    | TyNamed (name, [])
      when List.mem name env.type_params_in_scope && not (is_declared_type name)
      ->
        has_trait_bound_transitive env name trait_name
    | _ -> false
  in
  if bound_match then true
  else
    let trait_impls =
      match Hashtbl.find_opt env.impl_index trait_name with
      | Some lst -> lst
      | None -> []
    in
    (* Check if inline bounds constraints are satisfied by the concrete type args *)
    let check_bounds impl =
      if impl.ii_bounds = [] then true
      else
        let subst = extract_type_subst impl.ii_for_type ty in
        List.for_all
          (fun param ->
            let param_name = param.param_name in
            let bounds = Generic_params.trait_ref_names param.param_bounds in
            match List.assoc_opt param_name subst with
            | None -> true (* unresolved — skip *)
            | Some concrete_arg ->
                List.for_all
                  (fun bound_trait ->
                    type_implements_trait env concrete_arg bound_trait)
                  bounds)
          impl.ii_bounds
    in
    let direct =
      List.exists
        (fun impl ->
          types_equal impl.ii_for_type ty
          ||
          let impl_type_params = Generic_params.param_names impl.ii_bounds in
          impl_type_params <> []
          && types_compatible ~type_params:impl_type_params impl.ii_for_type ty
          && check_bounds impl
          ||
          let renamed_for_type, renamed_params =
            alpha_rename_impl_vars
              (Generic_params.param_names impl.ii_bounds)
              impl.ii_for_type ty
          in
          types_compatible ~type_params:renamed_params renamed_for_type ty
          && check_bounds impl)
        trait_impls
    in
    if direct then true
    else
      Hashtbl.fold
        (fun parent_trait impls found ->
          if found then true
          else if trait_has_supertrait env parent_trait trait_name then
            List.exists
              (fun impl ->
                types_equal impl.ii_for_type ty
                ||
                let impl_type_params =
                  Generic_params.param_names impl.ii_bounds
                in
                impl_type_params <> []
                && types_compatible ~type_params:impl_type_params
                     impl.ii_for_type ty
                ||
                let renamed_for_type, renamed_params =
                  alpha_rename_impl_vars
                    (Generic_params.param_names impl.ii_bounds)
                    impl.ii_for_type ty
                in
                types_compatible ~type_params:renamed_params renamed_for_type ty)
              impls
          else false)
        env.impl_index false

(** Check whether a type satisfies a structured trait obligation. *)
let type_satisfies_trait_obligation env obligation =
  let trait_name = Generic_params.trait_ref_name obligation.obligation_trait in
  let builtin_operator_primitive =
    match obligation.obligation_type with
    | TyNamed (("Int" | "Float" | "String" | "Bool" | "Char" | "Fixed"), []) ->
        true
    | TyNamed (("Float32" | "Float16"), []) -> true
    | ty when Types.is_any_integer_type ty -> true
    | _ -> false
  in
  type_implements_trait env obligation.obligation_type trait_name
  || (trait_name = "Equatable" || trait_name = "Orderable")
     && builtin_operator_primitive

(** Resolve a structured trait obligation. *)
let resolve_trait_obligation env obligation =
  if type_satisfies_trait_obligation env obligation then
    TraitObligationSatisfied
  else
    match obligation.obligation_type with
    | TyBoundVar _ -> TraitObligationUnsatisfied
    | TyVar name
      when (not (List.mem name env.type_params_in_scope))
           && get_type_param_bounds env name = [] ->
        TraitObligationDeferred
    | _ -> TraitObligationUnsatisfied

(** Return the first obligation that is definitely unsatisfied. *)
let find_unsatisfied_trait_obligation env obligations =
  List.find_opt
    (fun obligation ->
      match resolve_trait_obligation env obligation with
      | TraitObligationUnsatisfied -> true
      | TraitObligationSatisfied | TraitObligationDeferred -> false)
    obligations

(** Substitute Self type with a concrete type in a type expression *)
let resolve_self (concrete_type : type_expr) (ty : type_expr) : type_expr =
  Types.map_type_expr (function TySelf -> Some concrete_type | _ -> None) ty

(** Get a trait method signature with Self resolved to a concrete type *)
let get_resolved_method_sig (method_sig : trait_method_sig)
    (concrete_type : type_expr) : trait_method_sig =
  {
    method_sig with
    tm_params = List.map (resolve_self concrete_type) method_sig.tm_params;
    tm_return = resolve_self concrete_type method_sig.tm_return;
  }

(* ============================================================================
   Overload Resolution
   ============================================================================ *)

(** Register an overload entry for a function name.
    Appends to the existing list if one exists, skipping duplicates
    (same module_path AND same purity — pure/impure pairs from one
    module both survive; see body comment for the Phase 2.7 reason). *)
let add_overload (env : env) (name : string) (entry : overload_entry) : env =
  let existing =
    match Hashtbl.find_opt env.overloads name with
    | Some entries -> entries
    | None -> []
  in
  (* Skip if same module AND same purity already registered — the
     paired pure/impure overloads of the same source name (e.g.
     list.map / list.flat_map) must both survive so Phase 2.7 tasks
     48/49's callback-purity tiebreak at the call site has both
     candidates to pick from. Re-imports of the same signature (same
     module + same purity) are still dominated as before. *)
  let dominated =
    List.exists
      (fun e ->
        e.ol_module_path = entry.ol_module_path && e.ol_purity = entry.ol_purity)
      existing
  in
  if not dominated then Hashtbl.replace env.overloads name (existing @ [ entry ]);
  env

(** Get all overload entries for a function name. *)
let get_overloads (env : env) (name : string) : overload_entry list =
  match Hashtbl.find_opt env.overloads name with
  | Some entries -> entries
  | None -> []

let find_overload_by_def_id (env : env) (def_id : def_id) :
    overload_entry option =
  Hashtbl.fold
    (fun _ entries found ->
      match found with
      | Some _ -> found
      | None -> List.find_opt (fun entry -> entry.ol_def_id = def_id) entries)
    env.overloads None

let find_ufcs_method_by_def_id (env : env) (def_id : def_id) :
    overload_entry option =
  Hashtbl.fold
    (fun _ entries found ->
      match found with
      | Some _ -> found
      | None -> List.find_opt (fun entry -> entry.ol_def_id = def_id) entries)
    env.ufcs_methods None

(** Extract the head type name from a type expression (e.g., "List" from List[Int]). *)
let head_type_name (ty : type_expr) : string option =
  match ty with
  | TyNamed (name, _) -> Some name
  | TyArray _ -> Some Types.array_head_name
  | _ -> None

(** Resolve an overloaded function name given the first argument's type.
    Returns the matching overload entry, or None if no match or ambiguous. *)
let resolve_overload (env : env) (name : string) (first_arg_type : type_expr) :
    overload_entry option =
  match Hashtbl.find_opt env.overloads name with
  | None | Some [] | Some [ _ ] ->
      None (* 0 or 1 entries: no resolution needed *)
  | Some entries -> (
      let arg_head = head_type_name first_arg_type in
      match arg_head with
      | None -> None (* Can't resolve without a concrete head type *)
      | Some arg_name -> (
          (* Find entries whose first param has matching head type *)
          let matches =
            List.filter
              (fun entry ->
                match entry.ol_func_type with
                | TyFunc { params = first_param :: _; _ } -> (
                    match head_type_name first_param with
                    | Some param_name -> param_name = arg_name
                    | None ->
                        (* Generic first param — try types_compatible *)
                        types_compatible
                          ~type_params:(overload_type_param_names entry)
                          first_param first_arg_type)
                | _ -> false)
              entries
          in
          match matches with
          | [ single ] -> Some single (* Unique match *)
          | _ -> None))
(* Ambiguous or no match *)

(** Phase 2.7 tasks 48/49 — pick the best overload for a given arg
    vector. Used by both the EIdent overload path
    ([resolve_overload_with_args]) and the UFCS dispatch in [infer.ml].

    Rules:
    - First-arg head type must match (same filter as [resolve_overload]).
    - For every function-typed parameter, the arg's purity must satisfy
      the param's: if the param is declared [pure], the arg must be pure;
      an impure param accepts any callback (pure is a subtype of impure).
    - If multiple overloads still match, prefer the one demanding more
      pure callbacks — that's the strictly-more-specific signature.
    - If still tied, return None (ambiguous). *)
let select_overload_for_args (entries : overload_entry list)
    (arg_types : type_expr list) : overload_entry option =
  match entries with
  | [] -> None
  | [ single ] -> Some single
  | _ -> (
      let first_arg = match arg_types with hd :: _ -> Some hd | [] -> None in
      let first_arg_head = Option.bind first_arg head_type_name in
      let head_match entry =
        match (entry.ol_func_type, first_arg) with
        | TyFunc { params = first_param :: _; _ }, Some farg -> (
            match (head_type_name first_param, first_arg_head) with
            | Some pn, Some an -> pn = an
            | None, _ ->
                types_compatible
                  ~type_params:(overload_type_param_names entry)
                  first_param farg
            | _ -> false)
        | _ -> false
      in
      (* A function-typed param requiring purity is satisfied only by a
         pure-tagged arg. Non-function params must still be compatible:
         first-arg head equality alone is too weak ([List[Int]] must not
         select an overload expecting [List[Float]]). *)
      let purity_ok param arg =
        match (param, arg) with
        | TyFunc p, TyFunc a -> (not p.is_pure) || a.is_pure
        | _ -> true
      in
      let param_compatible entry param arg =
        types_compatible
          ~type_params:(overload_type_param_names entry)
          param arg
        && purity_ok param arg
      in
      let arg_compatible entry =
        match entry.ol_func_type with
        | TyFunc { params; _ } -> (
            try List.for_all2 (param_compatible entry) params arg_types
            with Invalid_argument _ -> false)
        | _ -> false
      in
      let matches =
        List.filter (fun e -> head_match e && arg_compatible e) entries
      in
      let pure_param_count entry =
        match entry.ol_func_type with
        | TyFunc { params; _ } ->
            List.fold_left
              (fun acc p ->
                match p with
                | TyFunc { is_pure = true; _ } -> acc + 1
                | _ -> acc)
              0 params
        | _ -> 0
      in
      match matches with
      | [ single ] -> Some single
      | [] -> None
      | many -> (
          let sorted =
            List.sort
              (fun a b -> compare (pure_param_count b) (pure_param_count a))
              many
          in
          match sorted with
          | best :: rest
            when not
                   (List.exists
                      (fun e -> pure_param_count e = pure_param_count best)
                      rest) ->
              Some best
          | _ -> None))

(* ============================================================================
   UFCS Method-Only Functions
   ============================================================================ *)

(** Check whether adding [entry] under method-name [name] would collide
    with an existing UFCS registration from a different module.

    Returns [Some existing_entry] when there is already an entry with:
    - same method name (trivially — both are in the same hashtable bucket)
    - same first-parameter head type (or mutually-compatible when
      one side is generic)
    - same purity
    - a DIFFERENT, non-None [ol_module_path]

    Callers use this to emit a clear diagnostic at the import site when
    two modules silently register competing UFCS methods. Returns [None]
    for:
    - no existing entry (first registration wins)
    - same module re-registration (idempotent; dedup in [add_ufcs_method])
    - different first-arg type (dispatches unambiguously at call time)
    - pure/impure pair from same module (handled by purity tiebreak at
      [select_overload_for_args])
    - either side missing a [module_path] (builtins / locally-defined
      functions don't participate in cross-module UFCS collision) *)
let ufcs_collision (env : env) (name : string) (entry : overload_entry) :
    overload_entry option =
  let existing =
    match Hashtbl.find_opt env.ufcs_methods name with
    | Some entries -> entries
    | None -> []
  in
  let first_param_of e =
    match e.ol_func_type with
    | TyFunc { params = p :: _; _ } -> Some p
    | _ -> None
  in
  let same_first_param a b =
    match (first_param_of a, first_param_of b) with
    | Some pa, Some pb -> (
        match (head_type_name pa, head_type_name pb) with
        | Some ha, Some hb -> ha = hb
        | _ ->
            types_compatible
              ~type_params:(overload_type_param_names entry)
              pa pb)
    | _ -> false
  in
  List.find_opt
    (fun e ->
      e.ol_module_path <> entry.ol_module_path
      && e.ol_module_path <> None
      && entry.ol_module_path <> None
      && e.ol_purity = entry.ol_purity
      && same_first_param e entry)
    existing

(** Register a method-only function (accessible via UFCS but not bare name).
    Used when importing a type auto-imports its module's applicable functions.

    Does not perform collision detection — callers that want a
    cross-module collision diagnostic should consult
    [ufcs_collision] first. Dedup on the exact (module, purity,
    func_type) triple still applies here so same-module
    re-registration is idempotent. *)
let add_ufcs_method (env : env) (name : string) (entry : overload_entry) : env =
  let existing =
    match Hashtbl.find_opt env.ufcs_methods name with
    | Some entries -> entries
    | None -> []
  in
  (* Dedup on the full (module, purity, func type) triple. Previous
     dedup checked only module+purity, which dropped legitimate
     overloads that share a source module but target different first-
     arg types — e.g. [less_than] impl-registered for [(A, B)],
     [(A, B, C)], and [(A, B, C, D)] from std/tuple.brp: without comparing the
     function type, only the first registration landed. *)
  let already =
    List.exists
      (fun e ->
        e.ol_module_path = entry.ol_module_path
        && e.ol_purity = entry.ol_purity
        && e.ol_func_type = entry.ol_func_type)
      existing
  in
  if not already then
    Hashtbl.replace env.ufcs_methods name (existing @ [ entry ]);
  env

(** Look up UFCS-only methods by name and first argument type.
    Returns all matching overload entries (may include both pure and impure). *)
let lookup_ufcs_methods (env : env) (name : string) (first_arg_type : type_expr)
    : overload_entry list =
  match Hashtbl.find_opt env.ufcs_methods name with
  | None | Some [] -> []
  | Some entries ->
      (* Fast path: both sides have a named head constructor — e.g.
         [Dict[String, Int]] and [Dict[K, V]]. Skip full unification
         for common cases.

         Fallback: structural types ([TyTuple], [TyFunc], [TyRange]…)
         have no head constructor name. In that case the only reliable
         match is [types_compatible], which unifies under the impl's
         type-parameter substitution. This is what lets trait-impl
         methods on tuples (e.g. [less_than] on [(A, B)]) be dispatched via
         UFCS when the synthesized default body writes [b.less_than(a)]. *)
      let compatible_first_param entry =
        match entry.ol_func_type with
        | TyFunc { params = first_param :: _; _ } -> (
            match
              (head_type_name first_param, head_type_name first_arg_type)
            with
            | Some p, Some a -> p = a
            | _ ->
                types_compatible
                  ~type_params:(overload_type_param_names entry)
                  first_param first_arg_type)
        | _ -> false
      in
      List.filter compatible_first_param entries

(** Check if a name exists as a UFCS-only method. *)
let has_ufcs_method (env : env) (name : string) : bool =
  match Hashtbl.find_opt env.ufcs_methods name with
  | Some (_ :: _) -> true
  | _ -> false

(* ============================================================================
   Error suggestion helpers
   ============================================================================ *)

(** Levenshtein edit distance between two strings *)
let levenshtein s1 s2 =
  let len1 = String.length s1 and len2 = String.length s2 in
  if len1 = 0 then len2
  else if len2 = 0 then len1
  else
    let prev = Array.init (len2 + 1) (fun j -> j) in
    let curr = Array.make (len2 + 1) 0 in
    for i = 1 to len1 do
      curr.(0) <- i;
      for j = 1 to len2 do
        let cost = if s1.[i - 1] = s2.[j - 1] then 0 else 1 in
        curr.(j) <-
          min (min (prev.(j) + 1) (curr.(j - 1) + 1)) (prev.(j - 1) + cost)
      done;
      Array.blit curr 0 prev 0 (len2 + 1)
    done;
    prev.(len2)

(** Collect all value-position identifier names visible in the environment.
    Excludes TypeSymbol, RecordSymbol, and AliasSymbol since those are not
    valid in value position (where "Undefined identifier" errors occur). *)
let all_value_identifiers (env : env) : string list =
  let names = Hashtbl.create 64 in
  List.iter
    (fun scope ->
      List.iter
        (fun (sym : symbol) ->
          match sym.kind with
          | TypeSymbol _ | RecordSymbol _ | AliasSymbol _ | OpaqueAliasSymbol _
            ->
              ()
          | VarSymbol _ | FuncSymbol _ | ConstructorSymbol _ ->
              if not (Hashtbl.mem names sym.name) then
                Hashtbl.add names sym.name true)
        (scope_symbols scope))
    env.scopes;
  Hashtbl.fold (fun name _ acc -> name :: acc) names []

(** Check if [name] is a prefix of [candidate] (at least 3 chars). *)
let is_prefix_of name candidate =
  let nlen = String.length name in
  nlen >= 3
  && String.length candidate > nlen
  && String.sub candidate 0 nlen = name

(** Suggest a similar identifier. Returns "" or ". Did you mean 'X'?" *)
let find_similar (name : string) (env : env) : string option =
  let candidates = all_value_identifiers env in
  let max_dist = if String.length name <= 3 then 1 else 2 in
  let same_case c =
    (* Filter out candidates with different leading case — avoids matching
       variable 'arr' against constructor 'Err' *)
    String.length c > 0
    && String.length name > 0
    && Char.lowercase_ascii c.[0]
       = c.[0]
       = (Char.lowercase_ascii name.[0] = name.[0])
  in
  let scored =
    List.filter_map
      (fun c ->
        let d = levenshtein name c in
        if d > 0 && d <= max_dist && same_case c then Some (c, d) else None)
      candidates
  in
  match
    List.sort
      (fun (c1, d1) (c2, d2) ->
        let cmp = compare d1 d2 in
        if cmp <> 0 then cmp else String.compare c1 c2)
      scored
  with
  | (best, _) :: _ -> Some best
  | [] -> (
      (* Fallback: check if name is a prefix of any candidate *)
      let prefix_matches =
        List.filter (fun c -> is_prefix_of name c && same_case c) candidates
      in
      match List.sort String.compare prefix_matches with
      | best :: _ -> Some best
      | [] -> None)
