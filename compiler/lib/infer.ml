(** Expression Type Inference for blorp Type Checker

    Implements type inference for all expression forms in the blorp language.
    Uses bidirectional type inference where possible.
*)

open Ast
open Types
open Env

type 'a infer_result = ('a, compiler_error) Result.t
(** Inference result *)

(** Create an inference error *)
let error ?(kind = Ast.OtherError) loc message =
  Error { message; loc; phase = TypeCheck; kind; notes = []; help = None }

let error_with ?(kind = Ast.OtherError) ~notes ~help loc message =
  Error { message; loc; phase = TypeCheck; kind; notes; help }

(** Reject a Void-typed expression appearing in a position that consumes a
    value. Centralizes the diagnostic for tuple/list/record/match/call/assign
    contexts that silently accept a Void and then crash C compilation with
    [void __x = ...;] or similar.

    [context] is a short phrase naming the surrounding construct
    (e.g. "tuple element", "list element", "record field", "match scrutinee") —
    appears verbatim in the error message, so phrase it as a noun. *)
let reject_void_value ~(context : string) (loc : Ast.loc) (ty : Ast.type_expr) :
    unit infer_result =
  match ty with
  | TyNamed ("Void", []) ->
      error_with
        ~notes:
          [
            "Void expressions produce no value and cannot be stored or consumed";
          ]
        ~help:
          (Some
             "Call the function as a statement instead, or change its return \
              type") loc
        (Printf.sprintf "%s has type Void" (String.capitalize_ascii context))
  | _ -> Ok ()

(** Common std library functions and their module — for import suggestions *)
let common_std_functions =
  [
    (* list *)
    ("sort", "list");
    ("map", "list");
    ("filter", "list");
    ("fold", "list");
    ("fold_left", "list");
    ("fold_right", "list");
    ("flat_map", "list");
    ("for_each", "list");
    ("append", "list");
    ("reverse", "list");
    ("zip", "list");
    ("take", "list");
    ("drop", "list");
    ("any", "list");
    ("all", "list");
    ("find", "list");
    ("contains", "list");
    ("unique", "list");
    ("get", "list");
    ("insert", "list");
    ("concat", "list");
    ("sum", "list");
    ("product", "list");
    (* string *)
    ("split", "string");
    ("join", "string");
    ("trim", "string");
    ("starts_with", "string");
    ("ends_with", "string");
    ("replace", "string");
    ("upper", "string");
    ("lower", "string");
    ("pad_left", "string");
    ("pad_right", "string");
    ("substring", "string");
    ("contains_str", "string");
    ("char_at", "string");
    ("index_of", "string");
    (* dict *)
    ("dict_set", "dict");
    ("dict_get", "dict");
    ("dict_remove", "dict");
    ("dict_contains", "dict");
    ("keys", "dict");
    ("values", "dict");
    (* math/float *)
    ("sin", "float");
    ("cos", "float");
    ("sqrt", "float");
    ("pi", "float");
    ("pow", "float");
    ("log", "float");
    ("exp", "float");
    ("floor", "float");
    ("ceil", "float");
    (* option/result *)
    ("and_then", "option");
    ("or_else", "option");
    ("flatten", "option");
    ("map_err", "result");
    ("swap", "result");
    (* io/system *)
    ("now", "time");
    ("exec", "system");
    ("file_exists", "system");
  ]

let renamed_string_method_hint receiver_type method_name =
  match (receiver_type, method_name) with
  | "String", "to_upper" ->
      Some "'to_upper' was renamed to 'upper'; write `value.upper()`"
  | "String", "to_lower" ->
      Some "'to_lower' was renamed to 'lower'; write `value.lower()`"
  | _ -> None

(** Suggest capitalized type name for common lowercase types *)
let suggest_capitalized_type ty =
  let known =
    [
      ("int", "Int");
      ("float", "Float");
      ("string", "String");
      ("bool", "Bool");
      ("char", "Char");
      ("void", "Void");
      ("list", "List");
      ("dict", "Dict");
      ("set", "Set");
      ("option", "Option");
      ("result", "Result");
    ]
  in
  match ty with
  | TyNamed (name, _)
    when String.length name > 0 && name.[0] >= 'a' && name.[0] <= 'z' -> (
      match List.assoc_opt name known with
      | Some cap ->
          Some
            (Printf.sprintf
               "Did you mean '%s'? Type names are capitalized in blorp" cap)
      | None -> None)
  | _ -> None

(** Let binding operator for result monad *)
let ( let* ) = Result.bind

(** Strict trait-obligation check for inference-time consumers.
    Deferred obligations are treated as unsatisfied here to preserve existing
    pre-monomorphization diagnostics; callee generic bounds use a separate
    deferred-friendly path. *)
let trait_obligation_satisfied env ty trait_name =
  match
    Env.resolve_trait_obligation env (Env.trait_obligation ty trait_name)
  with
  | TraitObligationSatisfied -> true
  | TraitObligationUnsatisfied | TraitObligationDeferred -> false

let is_parallel_list_type = function
  | TyNamed (("ParallelList" | "std/list::ParallelList"), _) -> true
  | _ -> false

type proven_collection = Refinement.proven_collection

let collection_identity_opt = Refinement.collection_identity
let dimension_identity_opt = Refinement.dimension_identity

let collection_var_opt name =
  match collection_identity_opt name with
  | Some identity -> Some (Refinement.collection_var identity)
  | None -> None

let collection_subscript_opt coll index =
  match collection_identity_opt index with
  | Some identity -> Some (Refinement.collection_subscript coll ~index:identity)
  | None -> None

let range_upper_length_minus_opt coll ~end_offset =
  match collection_identity_opt coll with
  | Some identity ->
      Refinement.range_upper_length_minus ~coll:identity ~end_offset
  | None -> None

let range_upper_at_most_length_opt coll =
  match collection_identity_opt coll with
  | Some identity -> Some (Refinement.range_upper_at_most_length ~coll:identity)
  | None -> None

let range_upper_dimension_opt dim =
  match dimension_identity_opt dim with
  | Some identity -> Some (Refinement.range_upper_dimension identity)
  | None -> None

let collection_length_bound_opt coll =
  match collection_identity_opt coll with
  | Some identity -> Some (Refinement.collection_length_bound identity)
  | None -> None

let dimension_bound_opt dim =
  match dimension_identity_opt dim with
  | Some identity -> Some (Refinement.dimension_bound identity)
  | None -> None

let proof_env_without_subscript env var =
  match collection_identity_opt var with
  | Some identity -> Refinement.proof_env_without_subscript env ~var:identity
  | None -> env

let proof_env_without_range env var =
  match collection_identity_opt var with
  | Some identity -> Refinement.proof_env_without_range env ~var:identity
  | None -> env

let proof_env_add_subscript ?source env var collection =
  match collection_identity_opt var with
  | Some identity ->
      Refinement.proof_env_add_subscript ?source env ~var:identity ~collection
  | None -> env

let proof_env_add_range_bounds ?source env var ~range_start ~range_upper =
  match collection_identity_opt var with
  | Some identity ->
      Refinement.proof_env_add_range_bounds ?source env ~var:identity
        ~range_start ~range_upper
  | None -> env

let proof_env_find_range env var =
  match collection_identity_opt var with
  | Some identity -> Refinement.proof_env_find_range env ~var:identity
  | None -> None

let env_with_range_refinement_from_proof env proof_env var =
  match proof_env_find_range proof_env var with
  | Some proof -> (
      let refinement =
        match Env.get_var_refinement env var with
        | Some existing -> Refinement.binding_add_range_proof existing proof
        | None -> Refinement.range_binding proof
      in
      match Env.set_var_refinement env var refinement with
      | Some env -> env
      | None -> env)
  | None -> env

let env_with_subscript_refinement_from_proof env proof_env var =
  match collection_identity_opt var with
  | Some identity -> (
      let refinement =
        let existing =
          Option.value
            (Env.get_var_refinement env var)
            ~default:Refinement.unrefined_binding
        in
        Refinement.proof_env_apply_subscript_to_binding proof_env ~var:identity
          existing
      in
      match Env.set_var_refinement env var refinement with
      | Some env -> env
      | None -> env)
  | None -> env

let env_with_binding_refinement_from_proof env proof_env var =
  env |> fun env ->
  env_with_range_refinement_from_proof env proof_env var |> fun env ->
  env_with_subscript_refinement_from_proof env proof_env var

let env_binding_proves_subscript env var collection =
  match Env.get_var_refinement env var with
  | Some refinement ->
      Refinement.binding_proves_subscript refinement ~collection
  | None -> false

let env_binding_proves_dim_at_most env var ~size =
  match Env.get_var_refinement env var with
  | Some refinement -> Refinement.binding_proves_dim_at_most refinement ~size
  | None -> false

let env_binding_direct_collection_vars env var =
  match Env.get_var_refinement env var with
  | Some refinement ->
      Refinement.binding_direct_collection_vars refinement
      |> List.map Refinement.collection_identity_name
  | None -> []

let env_binding_proves_direct_range env var ~bounds =
  match Env.get_var_refinement env var with
  | Some refinement -> Refinement.binding_proves_direct_range refinement ~bounds
  | None -> false

let env_binding_proves_offset_range env var ~bounds ~offset =
  match Env.get_var_refinement env var with
  | Some refinement ->
      Refinement.binding_proves_offset_range refinement ~bounds ~offset
  | None -> Refinement.offset_no_matching_bound

let range_type_proof_opt upper_ty =
  let range_upper_opt =
    match upper_ty with
    | TyConstInt n -> Refinement.range_upper_lit n
    | TyVar name when Types.Dim.is_var_name name -> (
        match dimension_identity_opt name with
        | Some dim -> Some (Refinement.range_upper_dimension dim)
        | None -> None)
    | _ -> None
  in
  match range_upper_opt with
  | Some range_upper ->
      Refinement.make_range_proof_with_source
        ~source:Refinement.ProofSourceRangeTypeFallback ~range_start:0
        ~range_upper
  | None -> None

let binding_refinement_with_range_type refinement ty =
  match ty with
  | TyRange range_upper_ty -> (
      match Refinement.binding_range_proof refinement with
      | Some _ -> refinement
      | None -> (
          match range_type_proof_opt range_upper_ty with
          | Some proof -> Refinement.binding_add_range_proof refinement proof
          | None -> refinement))
  | _ -> refinement

let expr_proofs_for_identifier env name ty =
  let refinement =
    Option.value
      (Env.get_var_refinement env name)
      ~default:Refinement.unrefined_binding
  in
  binding_refinement_with_range_type refinement ty
  |> Type_proof_metadata.expr_proofs_of_binding

let expr_binding_refinement_opt expr =
  match expr.expr_type_info with
  | Some info ->
      Some (Type_proof_metadata.binding_refinement_of_expr_proofs info.proofs)
  | None -> None

let expr_semantic_type_opt expr =
  match expr.expr_type_info with
  | Some info -> Some info.semantic_ty
  | None -> None

let inferred_expr_semantic_type expr =
  match expr_semantic_type_opt expr with
  | Some ty -> ty
  | None ->
      failwith
        "internal: inferred expression is missing structured type metadata"

let expr_value_type_opt expr =
  match expr.expr_type_info with
  | Some info -> Some info.value_ty
  | None -> None

let expr_proves_subscript expr collection =
  match expr_binding_refinement_opt expr with
  | Some refinement ->
      Refinement.binding_proves_subscript refinement ~collection
  | None -> false

let expr_proves_dim_at_most expr ~size =
  match expr_binding_refinement_opt expr with
  | Some refinement -> Refinement.binding_proves_dim_at_most refinement ~size
  | None -> false

let expr_direct_collection_vars expr =
  match expr_binding_refinement_opt expr with
  | Some refinement ->
      Refinement.binding_direct_collection_vars refinement
      |> List.map Refinement.collection_identity_name
  | None -> []

let expr_proves_direct_range expr ~bounds =
  match expr_binding_refinement_opt expr with
  | Some refinement -> Refinement.binding_proves_direct_range refinement ~bounds
  | None -> false

let expr_proves_offset_range expr ~bounds ~offset =
  match expr_binding_refinement_opt expr with
  | Some refinement ->
      Refinement.binding_proves_offset_range refinement ~bounds ~offset
  | None -> Refinement.offset_no_matching_bound

let binding_range_start_opt env name =
  match Env.get_var_refinement env name with
  | Some refinement -> (
      match Refinement.binding_range_proof refinement with
      | Some { range_start; _ } when range_start >= 0 -> Some range_start
      | _ -> None)
  | None -> None

type branch_narrowing_subject =
  | BranchNarrowImmutableInt
  | BranchNarrowMutableInt
  | BranchNarrowUnavailable

let branch_narrowing_subject env var =
  match Env.lookup env var with
  | Some
      {
        kind =
          VarSymbol
            { var_type = TyNamed ("Int", []); mutability = Immutable; _ };
        _;
      } ->
      BranchNarrowImmutableInt
  | Some
      {
        kind =
          VarSymbol { var_type = TyNamed ("Int", []); mutability = Mutable; _ };
        _;
      } ->
      BranchNarrowMutableInt
  | _ -> BranchNarrowUnavailable

let refinement_branch_subject subject var =
  match subject with
  | BranchNarrowImmutableInt -> Refinement.immutable_subject var
  | BranchNarrowMutableInt -> Refinement.mutable_subject var
  | BranchNarrowUnavailable -> None

let range_upper_for_branch_narrowing = function
  | TyConstInt n -> Refinement.range_upper_lit n
  | TyVar name when Types.Dim.is_var_name name -> range_upper_dimension_opt name
  | _ -> None

let branch_range_narrowing_refinement env var upper_ty =
  let subject = branch_narrowing_subject env var in
  match range_upper_for_branch_narrowing upper_ty with
  | Some range_upper -> (
      match refinement_branch_subject subject var with
      | Some subject -> (
          match
            Refinement.make_branch_range_proof subject ~range_start:0
              ~range_upper
          with
          | Ok proof ->
              let existing =
                Option.value
                  (Env.get_var_refinement env var)
                  ~default:Refinement.unrefined_binding
              in
              Some
                (Refinement.binding_add_range_proof existing
                   (Refinement.branch_range_proof proof))
          | Error _ -> None)
      | None -> None)
  | None -> None

let apply_branch_range_narrowing env (var, upper_ty) =
  match branch_range_narrowing_refinement env var upper_ty with
  | Some refinement ->
      Env.add_var env var (TyRange upper_ty) ~origin:Other ~refinement ()
  | None -> env

let apply_branch_range_narrowings env narrowings =
  List.fold_left apply_branch_range_narrowing env narrowings

type expected_value_slot_context =
  | ExpectedArgumentSlot
  | ExpectedCollectionElement of Type_widening.collection_kind
  | ExpectedBitwiseOperand

type expected_context =
  | NoExpectedType
  | ExpectedType of type_expr
  | AnnotatedExpectedType of type_expr
  | ExpectedValueSlot of {
      expected_ty : type_expr;
      slot_context : expected_value_slot_context;
    }

type return_annotation_inference =
  | ReturnAnnotationDoesNotGuideInference
  | ReturnAnnotationGuidesInference of type_expr

type record_literal_target =
  | RecordLiteralTarget of {
      target_ty : type_expr;
      field_types : (string * type_expr) list;
    }
  | EmptyCollectionLiteralTarget of type_expr
  | InferRecordLiteralFromFields
  | InvalidRecordLiteralTarget of type_expr

type infer_ctx = {
  env : env;
  expected : expected_context;
      (* Bidirectional expected type for value-yielding positions. *)
  rigid_type_params : string list;
      (* Generic parameters that are opaque inside the current function body. *)
  in_loop : bool; (* Whether we're inside a loop body *)
  proof_env : Refinement.proof_env;
      (** Refinement facts proven in the current inference scope. *)
  module_aliases : (string * string) list;
      (* Maps alias → module path for qualified imports *)
  allow_debug_only_calls : bool;
      (* Debug/test builds may call @debug_only helpers directly. *)
  in_debug_context : bool; (* True while inferring a debug: block. *)
}
(** Inference context *)

(** Create a context *)
let make_ctx ?(module_aliases = []) ?(allow_debug_only_calls = false)
    ?(rigid_type_params = []) env =
  {
    env;
    expected = NoExpectedType;
    rigid_type_params;
    in_loop = false;
    proof_env = Refinement.empty_proof_env;
    module_aliases;
    allow_debug_only_calls;
    in_debug_context = false;
  }

let type_resolution_context ctx =
  Type_resolution.make_context ~env:ctx.env ~module_aliases:ctx.module_aliases
    ()

(** Resolve explicit source type annotations before inference consumes them.
    Keep these helpers named by use case so future source/semantic/provenance
    differences have one obvious construction boundary. *)
let resolve_value_ascription ctx ty =
  let resolution_ctx = type_resolution_context ctx in
  Type_resolution.value_ascription resolution_ctx ty

let resolve_local_binding_annotation ctx ty =
  let resolution_ctx = type_resolution_context ctx in
  Type_resolution.local_binding_annotation resolution_ctx ty

let resolve_function_parameter_annotation ctx ty =
  let resolution_ctx = type_resolution_context ctx in
  Type_resolution.function_parameter_annotation resolution_ctx ty

let resolve_function_return_annotation ctx ty =
  let resolution_ctx = type_resolution_context ctx in
  Type_resolution.function_return_annotation resolution_ctx ty

let resolve_function_return_annotation_type ctx ty =
  resolve_function_return_annotation ctx ty |> Type_resolution.canonical

let canonicalize_inferred_type_for_ast ctx ty =
  let resolution_ctx = type_resolution_context ctx in
  Type_resolution.annotation_canonical resolution_ctx ty

let normalize_type_with_env env purpose ty =
  let normalization_ctx = Infer_type_normalization.make_context ~env () in
  Infer_type_normalization.canonical normalization_ctx purpose ty

let normalize_type ctx purpose ty = normalize_type_with_env ctx.env purpose ty

(** Set expected type for bidirectional inference *)
let with_expected ctx ty = { ctx with expected = ExpectedType ty }

(** Set expected type for a value slot that intentionally preserves a more
    precise semantic type than the slot's runtime value type. *)
let with_expected_value_slot ctx ty slot_context =
  { ctx with expected = ExpectedValueSlot { expected_ty = ty; slot_context } }

(** Set expected type from an explicit annotation (stronger context for record disambiguation) *)
let with_annotated_expected ctx ty =
  { ctx with expected = AnnotatedExpectedType ty }

(** Clear expected type *)
let without_expected ctx = { ctx with expected = NoExpectedType }

let fold_expected_context ctx ~none ~expected ~annotated =
  match ctx.expected with
  | NoExpectedType -> none
  | ExpectedType ty -> expected ty
  | AnnotatedExpectedType ty -> annotated ty
  | ExpectedValueSlot { expected_ty; _ } -> expected expected_ty

let expected_value_slot_opt ctx semantic_ty =
  match ctx.expected with
  | ExpectedValueSlot { expected_ty; slot_context } -> (
      match slot_context with
      | ExpectedArgumentSlot ->
          Some
            (Type_widening.argument_target_slot ~param_ty:expected_ty
               semantic_ty)
      | ExpectedCollectionElement kind ->
          Some
            (Type_widening.collection_element_target_slot kind
               ~target_ty:expected_ty semantic_ty)
      | ExpectedBitwiseOperand ->
          Some
            (Type_widening.bitwise_operand_target_slot ~target_ty:expected_ty
               semantic_ty))
  | NoExpectedType | ExpectedType _ | AnnotatedExpectedType _ -> None

let has_expected_argument_slot ctx =
  match ctx.expected with
  | ExpectedValueSlot { slot_context = ExpectedArgumentSlot; _ } -> true
  | NoExpectedType | ExpectedType _ | AnnotatedExpectedType _
  | ExpectedValueSlot _ ->
      false

let expected_type_opt ctx =
  fold_expected_context ctx ~none:None ~expected:Option.some
    ~annotated:Option.some

let expected_sized_integer_type_opt ctx =
  match expected_type_opt ctx with
  | Some (TyNamed (type_name, []) as ty)
    when Types.is_any_integer_type ty && type_name <> "Int" ->
      Some (type_name, ty)
  | _ -> None

let expected_sized_float_type_opt ctx =
  match expected_type_opt ctx with
  | Some (TyNamed (("Float32" | "Float16"), []) as ty) -> Some ty
  | _ -> None

let return_annotation_inference ty =
  match Types.collect_type_vars ty with
  | [] -> ReturnAnnotationGuidesInference ty
  | _ -> (
      match ty with
      | TyNamed (_, _) | TyTuple _ | TyArray _ ->
          ReturnAnnotationGuidesInference ty
      | _ -> ReturnAnnotationDoesNotGuideInference)

let rec all_some = function
  | [] -> Some []
  | Some x :: rest -> (
      match all_some rest with Some xs -> Some (x :: xs) | None -> None)
  | None :: _ -> None

(** Well-known or retired names with targeted suggestions. *)
let foreign_name_hints =
  [
    ( "return",
      "blorp doesn't use 'return'. The last expression in a function body is \
       its return value" );
    ( "let",
      "blorp doesn't use 'let'. Write 'name: Type = value' or 'var name = \
       value'" );
    ("val", "blorp doesn't use 'val'. Write 'name: Type = value' for bindings");
    ("lambda", "blorp uses 'func' for lambdas: func(x): x + 1");
    ("null", "blorp doesn't have null. Use Option[T] with Some(value) or None");
    ("nil", "blorp doesn't have nil. Use Option[T] with Some(value) or None");
    ("range", "blorp uses '..' for ranges: for i in 0..5:");
    ("len", "Use 'length(collection)' in blorp");
    ("println", "Use 'print(value)' in blorp");
    ("eprintln", "Use 'err_print(value)' in blorp");
    ( "to_upper",
      "'to_upper' was renamed to 'upper'; import it with `import: string: \
       upper` and call `upper(value)` or `value.upper()`" );
    ( "to_lower",
      "'to_lower' was renamed to 'lower'; import it with `import: string: \
       lower` and call `lower(value)` or `value.lower()`" );
    ("int", "Capitalize type names in blorp: 'Int', not 'int'");
    ("float", "Capitalize type names in blorp: 'Float', not 'float'");
    ("str", "Use 'String' in blorp, not 'str'");
    ("bool", "Capitalize type names in blorp: 'Bool', not 'bool'");
    ("sub", "Operator trait method 'sub' was renamed to 'subtract'");
    ("mul", "Operator trait method 'mul' was renamed to 'multiply'");
    ("div", "Operator trait method 'div' was renamed to 'divide'");
    ("mod", "Operator trait method 'mod' was renamed to 'remainder'");
    ("neg", "Operator trait method 'neg' was renamed to 'negate'");
    ("eq", "Operator trait method 'eq' was renamed to 'equals'");
    ("ne", "Operator trait method 'ne' was renamed to 'not_equals'");
    ("lt", "Operator trait method 'lt' was renamed to 'less_than'");
    ("gt", "Operator trait method 'gt' was renamed to 'greater_than'");
    ("le", "Operator trait method 'le' was renamed to 'less_than_or_equal'");
    ("ge", "Operator trait method 'ge' was renamed to 'greater_than_or_equal'");
  ]

(** Error for an undefined identifier with Levenshtein did-you-mean suggestion. *)
let undefined_ident_error ctx name loc =
  let help =
    match List.assoc_opt name foreign_name_hints with
    | Some hint -> Some hint
    | None -> (
        (* Check if name exists in a qualified-only module (exact or prefix match) *)
        let module_hint =
          List.find_map
            (fun (alias, mod_path) ->
              match Modules.find_cached mod_path with
              | Some m ->
                  let exports = List.map fst m.Modules.exports in
                  let mod_base = Filename.basename mod_path in
                  if List.mem name exports then
                    Some
                      (Printf.sprintf
                         "'%s' is available as '%s.%s', or use a selective \
                          import: %s: %s"
                         name alias name mod_base name)
                  else
                    (* Prefix match: 'fold' → 'fold_left' *)
                    let nlen = String.length name in
                    if nlen >= 3 then
                      let prefix_matches =
                        List.filter
                          (fun e ->
                            String.length e > nlen && String.sub e 0 nlen = name)
                          exports
                      in
                      match List.sort String.compare prefix_matches with
                      | best :: _ ->
                          Some
                            (Printf.sprintf
                               "Did you mean '%s'? Use '%s.%s' or a selective \
                                import: %s: %s"
                               best alias best mod_base best)
                      | [] -> None
                    else None
              | None -> None)
            ctx.module_aliases
        in
        match module_hint with
        | Some h -> Some h
        | None -> (
            (* Search ALL loaded modules for this name.
               Prefer non-prelude modules over prelude (option/result) since
               the user likely wants the more specific module. *)
            let all_modules = Modules.get_all_modules () in
            let prelude_mods = Modules.prelude_module_names in
            let matching_modules =
              List.filter_map
                (fun (m : Modules.loaded_module) ->
                  let exports = List.map fst m.Modules.exports in
                  if List.mem name exports then Some m.Modules.name else None)
                all_modules
            in
            (* Prefer non-prelude modules *)
            let best_module =
              match
                List.find_opt
                  (fun m -> not (List.mem m prelude_mods))
                  matching_modules
              with
              | Some m -> Some (Filename.basename m)
              | None ->
                  Option.map Filename.basename (List.nth_opt matching_modules 0)
            in
            let all_module_hint =
              match best_module with
              | Some mod_name ->
                  Some
                    (Printf.sprintf "'%s' requires an import: import: %s: %s"
                       name mod_name name)
              | None -> None
            in
            match all_module_hint with
            | Some h -> Some h
            | None -> (
                (* Check static table of common std library functions *)
                match List.assoc_opt name common_std_functions with
                | Some mod_name ->
                    Some
                      (Printf.sprintf "'%s' requires an import: import: %s: %s"
                         name mod_name name)
                | None -> (
                    (* Check if it looks like a module alias (e.g., L, D, S) *)
                    let alias_hint =
                      let lower = String.lowercase_ascii name in
                      let known_aliases =
                        [
                          ("l", "list");
                          ("d", "dict");
                          ("s", "string");
                          ("m", "math");
                          ("t", "time");
                          ("io", "io");
                        ]
                      in
                      match List.assoc_opt lower known_aliases with
                      | Some mod_name ->
                          Some
                            (Printf.sprintf
                               "'%s' is not defined. To use qualified calls, \
                                add: import: %s as %s"
                               name mod_name name)
                      | None -> None
                    in
                    match alias_hint with
                    | Some h -> Some h
                    | None -> (
                        match Env.find_similar name ctx.env with
                        | Some s -> Some (Printf.sprintf "Did you mean '%s'?" s)
                        | None -> None)))))
  in
  error_with ~kind:(UndefinedIdent name) ~notes:[] ~help loc
    (Printf.sprintf "Undefined identifier: %s" name)

let annotate_expr_type_info expr info = Ast.with_expr_type_info expr info

let annotate_inferred_expr expr ty =
  annotate_expr_type_info expr (Ast.expr_type_info_from_type ty)

(** Validate a ?= type annotation against the unwrapped inner type,
    bind the variable, and return the updated context and typed stmt. *)
let validate_try_bind ctx stmt name ty_ann inner_ty rhs' =
  let* () =
    match ty_ann with
    | Some ann_ty ->
        let type_params = Env.get_type_params ctx.env in
        if types_compatible ~type_params ann_ty inner_ty then Ok ()
        else
          error stmt.expr_loc
            (Printf.sprintf
               "Type annotation `%s` does not match unwrapped type `%s`"
               (type_to_string ann_ty) (type_to_string inner_ty))
    | None -> Ok ()
  in
  let bind_ty = match ty_ann with Some t -> t | None -> inner_ty in
  let env' = Env.add_var ctx.env name bind_ty () in
  let ctx' = { ctx with env = env' } in
  let stmt' =
    annotate_inferred_expr
      { stmt with expr_desc = ETryBind (name, ty_ann, rhs') }
      inner_ty
  in
  Ok (ctx', stmt')

(** Check that a variable name is not already declared in the current scope.
    Returns Ok () if the name is fresh, or an error if it's a re-declaration. *)
let check_no_redeclaration (env : env) (name : string) (loc : loc) :
    unit infer_result =
  (* Skip compiler-internal names — these can shadow in nested contexts. *)
  if String.length name > 2 && name.[0] = '_' && name.[1] = '_' then Ok ()
  else
    (* Check current scope for same-scope redeclaration *)
    match lookup_in_current_scope env name with
    | Some { kind = VarSymbol _; _ } ->
        error loc
          (Printf.sprintf
             "Variable '%s' is already declared in this scope. Use 'var' and \
              reassignment instead of re-declaring"
             name)
    | Some existing ->
        error loc
          (Printf.sprintf
             "Variable '%s' conflicts with existing %s of the same name" name
             (Env.symbol_kind_label existing))
    | None -> (
        (* Check outer scopes for shadowing user-defined names.
         Builtins are exempt — names like length, add, sub, input are too
         common as variable names to prohibit. Only shadow-check against
         user declarations and imports. *)
        let is_builtin_symbol sym =
          match sym.kind with
          | FuncSymbol { origin = Builtin; _ } -> true
          | _ -> false
        in
        match lookup env name with
        | Some sym when not (is_builtin_symbol sym) -> (
            match sym.kind with
            | VarSymbol _ ->
                error loc
                  (Printf.sprintf
                     "Variable '%s' shadows a variable in an outer scope. Use \
                      a different name"
                     name)
            | _ ->
                error loc
                  (Printf.sprintf
                     "Variable '%s' shadows %s '%s'. Use a different name" name
                     (Env.symbol_kind_label sym)
                     name))
        | _ -> Ok ())

(** Look up a function's type from a specific module.
    Prefers [typed_decls] (post-typecheck) over [exports] (parsed decls)
    so that implicit type parameters (those discovered by
    [compute_effective_type_params] in [typecheck.ml]) are available for
    [instantiate_type_params]. Without this, multi-char implicit
    generics like [Acc] or [Elem] are treated as concrete types in
    qualified calls ([M.func(...)]), causing "expected Elem, got Int"
    errors. *)
let lookup_module_func_type module_path func_name =
  match Modules.find_cached module_path with
  | None -> None
  | Some m -> (
      let decls_for_types =
        match Modules.get_typed_decls m.name with
        | Some td -> Typed_ast.program_ast td
        | None -> m.decls
      in
      let local_type_names =
        module_local_type_names_from_decls decls_for_types
      in
      let qualify ty =
        Types.qualify_module_local_types ~module_path:m.name local_type_names ty
      in
      let rec extract_func_type decl =
        match decl.decl_desc with
        | DPrivate inner -> extract_func_type inner
        | DFunc f ->
            let param_types =
              List.filter_map (fun p -> p.param_type) f.func_params
            in
            let return =
              match f.func_return_type with
              | Some t -> t
              | None -> TyNamed ("Void", [])
            in
            let ty =
              TyFunc { params = param_types; return; is_pure = f.func_is_pure }
            in
            Some
              (instantiate_type_params
                 (Ast.type_param_names f.func_type_params)
                 ty
              |> qualify)
        | _ -> None
      in
      let typed_func_type typed_func =
        let f = Typed_ast.func_ast typed_func in
        let param_types =
          List.filter_map (fun p -> p.param_type) f.func_params
        in
        let ty =
          TyFunc
            {
              params = param_types;
              return = Typed_ast.func_semantic_return_type typed_func;
              is_pure = f.func_is_pure;
            }
        in
        instantiate_type_params (Ast.type_param_names f.func_type_params) ty
        |> qualify
      in
      (* Try typed_decls first: after typecheck, func_type_params carries
         the effective params (declared + implicit). Falls back to exports
         if typecheck hasn't run for this module yet. *)
      let from_typed =
        match Modules.get_typed_decls m.name with
        | Some typed_program ->
            let rec find = function
              | [] -> None
              | typed_decl :: rest -> (
                  match Typed_ast.decl_view typed_decl with
                  | Typed_ast.DeclPrivate _ ->
                      find rest (* respect visibility *)
                  | Typed_ast.DeclFunction typed_func
                    when (Typed_ast.func_ast typed_func).func_name
                         = Some func_name ->
                      Some (typed_func_type typed_func)
                  | _ -> find rest)
            in
            find (Typed_ast.program_decls typed_program)
        | None -> None
      in
      match from_typed with
      | Some _ -> from_typed
      | None ->
          List.find_map
            (fun (name, decl) ->
              if name = func_name then extract_func_type decl else None)
            m.exports)

(** Look up a variable exported by a specific module.
    Qualified value access ([M.value]) must use the exporting module's typed
    declaration instead of falling back to an unqualified value named [value]
    in the caller's environment. Prefer the checked variable annotation: record
    literal initializers can retain a local/bare constructor result type, while
    the variable annotation has already been resolved to the module-owned type
    that callers must see. *)
let lookup_module_var_type module_path var_name =
  match Modules.find_cached module_path with
  | None -> None
  | Some m -> (
      let decls_for_types =
        match Modules.get_typed_decls m.name with
        | Some td -> Typed_ast.program_ast td
        | None -> m.decls
      in
      let local_type_names =
        module_local_type_names_from_decls decls_for_types
      in
      let qualify ty =
        Types.qualify_module_local_types ~module_path:m.name local_type_names ty
      in
      let extract_var_type decl =
        match decl.decl_desc with
        | DPrivate _ -> None
        | DVar v when v.var_name = Some var_name -> (
            match v.var_type with
            | Some ty -> Some (qualify ty)
            | None -> Option.map qualify (expr_semantic_type_opt v.var_value))
        | _ -> None
      in
      let extract_typed_var_type typed_decl =
        match Typed_ast.decl_view typed_decl with
        | Typed_ast.DeclPrivate _ -> None
        | Typed_ast.DeclVar typed_var
          when (Typed_ast.var_ast typed_var).var_name = Some var_name ->
            Some (Typed_ast.var_binding_type typed_var |> qualify)
        | _ -> None
      in
      let from_typed =
        match Modules.get_typed_decls m.name with
        | Some typed_program ->
            List.find_map extract_typed_var_type
              (Typed_ast.program_decls typed_program)
        | None -> None
      in
      match from_typed with
      | Some _ -> from_typed
      | None ->
          List.find_map
            (fun (name, decl) ->
              if name = var_name then extract_var_type decl else None)
            m.exports)

(** Look up a trait-impl method on a module-qualified call.

    [M.to_string(value)] where [to_string] is not a top-level function in
    [M] but [M] declares [implements Trait for Foo:] whose [Foo] matches
    [value]'s type and whose [to_string] method is present. Returns
    [(mangled_name, method_signature)] so the call site can rewrite the
    callee to the impl-mangled name (which [core_resolve] registers as a
    user function) and preserve the type signature for inference.

    This closes the gap that used to require every trait-method-like
    stdlib function to also live at the top level of its module: wrapping
    a top-level [func to_string(value: T)] in [implements Stringable for
    T:] would break [V.to_string(value)] callers without this lookup,
    because the top-level name disappears into the impl's mangled form.

    Matches on the outermost type constructor (via [type_name_for_impl]),
    so [Option[Int]] matches [impl for Option[T]] regardless of element
    type — consistent with how [Core_trait_resolve] keys its registry. *)
let lookup_module_impl_method module_path method_name (arg_ty : type_expr) :
    (string * type_expr) option =
  match Modules.find_cached module_path with
  | None -> None
  | Some m -> (
      let arg_head = Codegen_types.type_name_for_impl arg_ty in
      match arg_head with
      | None -> None
      | Some arg_type_name ->
          let decls =
            match Modules.get_typed_decls m.name with
            | Some td -> Typed_ast.program_ast td
            | None -> m.decls
          in
          let try_impl d =
            match d.decl_desc with
            | DPrivate _ -> None (* private impls don't export *)
            | DImpl impl
              when not (Codegen_types.has_type_vars impl.impl_for_type) -> (
                (* Only non-generic impls. Generic impls (e.g.
                    [implements HasLength for Dict[K, V]:]) route through
                    the existing monomorphization path — their method
                    signatures carry type vars that need fresh metas per
                    call site, which this simple lookup can't provide
                    correctly. *)
                match Codegen_types.type_name_for_impl impl.impl_for_type with
                | Some impl_type_name when impl_type_name = arg_type_name ->
                    (* Find the named method on this impl. *)
                    List.find_map
                      (fun (f : func_decl) ->
                        if f.func_name = Some method_name then
                          let param_types =
                            List.filter_map
                              (fun p -> p.param_type)
                              f.func_params
                          in
                          let return =
                            match f.func_return_type with
                            | Some t -> t
                            | None -> TyNamed ("Void", [])
                          in
                          let ty =
                            TyFunc
                              {
                                params = param_types;
                                return;
                                is_pure = f.func_is_pure;
                              }
                          in
                          let mangled =
                            Printf.sprintf "%s_%s_%s" impl.impl_trait
                              method_name impl_type_name
                          in
                          Some
                            ( mangled,
                              instantiate_type_params
                                (Ast.type_param_names f.func_type_params)
                                ty )
                        else None)
                      impl.impl_methods
                | _ -> None)
            | _ -> None
          in
          List.find_map try_impl decls)

(** Resolve a record's field types with type parameter substitution.
    Given a record type name and its concrete type args, returns a list of
    (field_name, resolved_field_type) pairs, or None if type is not a record.

    Tries the local env first, then searches loaded modules' declarations
    so that record types encountered via union-variant pattern matching
    (e.g., [GeoLineString(ls)] → [ls: LineString]) can have their fields
    accessed without an explicit import of the record type. *)
let resolve_record_field_types env type_name type_args =
  let resolve_with ?(qualify = fun ty -> ty) (type_params, field_list) =
    let subst =
      if List.length type_params = List.length type_args then
        List.map2
          (fun p a -> { var_name = p; concrete_type = a })
          type_params type_args
      else []
    in
    Some
      (List.map
         (fun field ->
           (field.field_name, qualify field.field_type |> apply_subst subst))
         field_list)
  in
  let from_canonical =
    match Types.split_canonical_module_type_name type_name with
    | None -> None
    | Some (module_path, local_type_name) -> (
        match Modules.find_cached module_path with
        | None -> None
        | Some m ->
            let decls =
              match Modules.get_typed_decls m.name with
              | Some td -> Typed_ast.program_ast td
              | None -> m.decls
            in
            let local_type_names = module_local_type_names_from_decls decls in
            let qualify ty =
              Types.qualify_module_local_types ~module_path:m.name
                local_type_names ty
            in
            let record_decl =
              List.find_map
                (fun d ->
                  let rec extract d =
                    match d.Ast.decl_desc with
                    | Ast.DPrivate inner -> extract inner
                    | Ast.DRecord r when r.Ast.record_name = local_type_name ->
                        Some
                          ( Ast.type_param_names r.record_type_params,
                            r.record_fields )
                    | _ -> None
                  in
                  extract d)
                decls
            in
            Option.bind record_decl (fun r -> resolve_with ~qualify r))
  in
  match from_canonical with
  | Some _ as hit -> hit
  | None -> (
      match get_record env type_name with
      | Some r -> resolve_with r
      | None -> (
          (* Cross-module fallback: search loaded modules for the record.
         This handles the case where a record type is referenced
         indirectly (e.g., as a union variant's payload type) without
         being explicitly imported. *)
          let from_module =
            List.find_map
              (fun (m : Modules.loaded_module) ->
                (* Prefer typed_decls for post-typecheck accuracy *)
                let decls =
                  match Modules.get_typed_decls m.name with
                  | Some td -> Typed_ast.program_ast td
                  | None -> m.decls
                in
                List.find_map
                  (fun d ->
                    let rec extract d =
                      match d.Ast.decl_desc with
                      | Ast.DPrivate inner -> extract inner
                      | Ast.DRecord r when r.Ast.record_name = type_name ->
                          Some
                            ( Ast.type_param_names r.record_type_params,
                              r.record_fields )
                      | _ -> None
                    in
                    extract d)
                  decls)
              (Modules.get_all_modules ())
          in
          match from_module with Some r -> resolve_with r | None -> None))

let is_empty_record_collection_type = function
  | TyNamed (("Tensor" | "Vector" | "Matrix" | "Dict" | "Set"), _) -> true
  | _ -> false

let record_literal_target_from_expected ctx literal_fields =
  let from_type ~annotated ty =
    match ty with
    | TyNamed (name, type_args) -> (
        match resolve_record_field_types ctx.env name type_args with
        | Some field_types ->
            RecordLiteralTarget { target_ty = ty; field_types }
        | None when literal_fields = [] && is_empty_record_collection_type ty ->
            EmptyCollectionLiteralTarget ty
        | None ->
            if annotated then InvalidRecordLiteralTarget ty
            else InferRecordLiteralFromFields)
    | _ ->
        if annotated then InvalidRecordLiteralTarget ty
        else InferRecordLiteralFromFields
  in
  fold_expected_context ctx ~none:InferRecordLiteralFromFields
    ~expected:(from_type ~annotated:false)
    ~annotated:(from_type ~annotated:true)

(* ============================================================================
   Literal Type Inference
   ============================================================================ *)

(** Extract the element type from an iterable type for for-in loops *)
let elem_type_of_iterable (ty : type_expr) : type_expr option =
  match Types.array_parts ty with
  | Some (elem, dims) -> (
      (* Dimension peeling: 2D+ yields sub-tensor, 1D yields scalar element.
         T[#M, #N] -> T[#N], T[#N] -> T *)
      match dims with
      | [ _single_dim ] -> Some elem (* 1D → scalar T *)
      | _ :: rest_dims ->
          Some (Types.ty_array elem rest_dims) (* 2D+ → sub-array *)
      | [] -> Some elem (* 0D → scalar T *))
  | None -> (
      match ty with
      | TyNamed ("List", [ elem ]) -> Some elem
      | TyNamed ("Dict", [ key; _ ]) -> Some key (* Dict iterates over keys *)
      | TyNamed ("Set", [ elem ]) -> Some elem (* Set iterates over elements *)
      | TyNamed ("String", []) -> Some ty_char (* String iterates over Char *)
      | TyNamed ("Range", []) -> Some ty_int (* Range -> Int *)
      | TyNamed ("Range", [ elem ]) -> Some elem (* legacy Range[Int] shape *)
      | TyNamed ("Channel", [ elem ]) ->
          Some elem (* Channel iterates via blocking recv *)
      | TyNamed ("Stream", [ elem ]) -> Some elem (* Stream iterates via pull *)
      | _ -> None)

let infer_literal (lit : literal) : type_expr =
  match lit with
  | LitInt n when n > 0L && n <= Int64.of_int max_int ->
      TyConstInt (Int64.to_int n)
  | LitInt _ -> ty_int
  | LitInt128 _ -> TyNamed ("Int128", [])
  | LitFloat _ -> ty_float
  | LitString _ -> ty_string
  | LitBool _ -> ty_bool
  | LitChar _ -> ty_char

(** Singleton integer literals keep their exact type as standalone values, but
    collection elements and branch result joins need an ordinary value type. *)
let inferred_binding_slot ~is_mutable ty =
  if is_mutable then Type_widening.mutable_binding_slot ty
  else Type_widening.keep_slot ty

let inferred_binding_type ~is_mutable ty =
  Type_widening.value_type (inferred_binding_slot ~is_mutable ty)

let expr_type_info_of_slot ?source_ty ?(origin = Inferred)
    ?(proofs = Type_proof_metadata.unproven_expr) slot =
  {
    source_ty;
    semantic_ty = Type_widening.semantic_type slot;
    value_ty = Type_widening.value_type slot;
    origin;
    widening = Type_widening.decision slot;
    proofs;
  }

let with_value_slot ?source_ty ?origin ?proofs expr slot =
  let info = expr_type_info_of_slot ?source_ty ?origin ?proofs slot in
  annotate_expr_type_info expr info

let with_inferred_type ?source_ty ?proofs expr ty =
  with_value_slot ?source_ty ?proofs expr (Type_widening.keep_slot ty)

let expr_proofs_or_unproven expr =
  match expr.expr_type_info with
  | Some info -> info.proofs
  | None -> Type_proof_metadata.unproven_expr

let with_explicit_source_type ~source_ty expr semantic_ty =
  with_value_slot ~source_ty ~origin:(ExplicitAnnotation source_ty)
    ~proofs:(expr_proofs_or_unproven expr)
    expr
    (Type_widening.keep_slot semantic_ty)

let with_inferred_desc expr expr_desc ty =
  with_inferred_type { expr with expr_desc } ty

let inferred_ident_expr expr name ty = with_inferred_desc expr (EIdent name) ty

let inferred_call_expr expr callee args ty =
  with_inferred_desc expr (ECall (callee, args)) ty

let with_value_slot_if_widening expr slot =
  match Type_widening.decision slot with
  | Keep _ -> expr
  | Widen _ -> with_value_slot expr slot

let annotate_method_receiver_expr expr =
  let ty = inferred_expr_semantic_type expr in
  with_value_slot_if_widening expr (Type_widening.method_receiver_slot ty)

let annotate_expected_value_slot ctx expr semantic_ty =
  match expected_value_slot_opt ctx semantic_ty with
  | Some slot -> with_value_slot expr slot
  | None -> expr

let expr_value_type_or expr fallback_ty =
  match expr_value_type_opt expr with Some ty -> ty | None -> fallback_ty

let expr_proof_semantic_type_opt = expr_semantic_type_opt

let annotate_inferred_binding_value ~is_mutable expr ty =
  with_value_slot expr (inferred_binding_slot ~is_mutable ty)

let default_arg_slot_for_param param_ty arg_ty =
  Type_widening.argument_slot ~param_ty ~arg_ty

let default_arg_type_for_param param_ty arg_ty =
  Type_widening.value_type (default_arg_slot_for_param param_ty arg_ty)

let new_type_conversion_hint env ~expected ~actual =
  let type_params = Env.get_type_params env in
  match
    (Env.new_type_underlying env expected, Env.new_type_underlying env actual)
  with
  | Some underlying, _ when types_compatible ~type_params underlying actual ->
      Some
        (Printf.sprintf "wrap the value with %s(...)"
           (Types.type_to_string expected))
  | _, Some underlying when types_compatible ~type_params expected underlying ->
      Some
        (Printf.sprintf "use value() to unwrap %s"
           (Types.type_to_string actual))
  | _ -> None

let append_new_type_conversion_hint env message ~expected ~actual =
  match new_type_conversion_hint env ~expected ~actual with
  | None -> message
  | Some hint -> message ^ "\n    help: " ^ hint

let common_inferred_type ~type_params left right =
  if types_compatible ~type_params left right then Some left
  else if types_compatible ~type_params right left then Some right
  else
    match (left, right) with
    | TyConstInt _, TyConstInt _ -> Some ty_int
    | TyConstInt _, TyNamed ("Int", []) | TyNamed ("Int", []), TyConstInt _ ->
        Some ty_int
    | _ -> None

(* ============================================================================
   Binary Operation Type Checking
   ============================================================================ *)

(** Check if a type name is an enum in the environment (all nullary variants, no type params) *)
let is_enum_type_in_env (env : Env.env) (name : string) : bool =
  match Env.get_type_decl env name with
  | Some (type_params, variants) ->
      type_params = [] && List.for_all (fun v -> v.variant_fields = []) variants
  | None -> false

let type_layout_metadata_for_env (env : Env.env) =
  let is_managed_name name =
    match Env.get_record env name with
    | Some _ -> not (Env.is_value_record env name)
    | None -> (
        match Env.get_type_kind env name with
        | Some TypeUnion -> true
        | Some TypeEnum | Some TypeBuiltin | None -> false)
  in
  Core_type_layout.metadata ~is_managed_name
    ~is_value_record_name:(Env.is_value_record env)
    ~is_enum_name:(is_enum_type_in_env env) ~lookup_alias:(Env.get_alias env) ()

(** Check if a type is a primitive that has built-in operator support *)
let is_primitive_type ?(env : Env.env option) (ty : type_expr) : bool =
  match ty with
  | TyNamed ("Int", [])
  | TyNamed ("Float", [])
  | TyNamed ("String", [])
  | TyNamed ("Bool", [])
  | TyNamed ("Char", [])
  | TyNamed ("Fixed", []) ->
      true
  | _ when Types.is_float32_type ty -> true
  | _ when Types.is_float16_type ty -> true
  | TyNamed (n, [])
    when match env with Some e -> is_enum_type_in_env e n | None -> false ->
      true
  | _ -> Types.is_any_integer_type ty

(** Get the result type of a binary operation *)
let check_binop (ctx : infer_ctx) (op : binop) (left_ty : type_expr)
    (right_ty : type_expr) loc : type_expr infer_result =
  (* Law 3: lift dims and ranges to Int for value-context arithmetic. *)
  let left_ty = Type_widening.numeric_operand_type op left_ty in
  let right_ty = Type_widening.numeric_operand_type op right_ty in
  let numeric_array_elem = function
    | TyNamed (("Int" | "Float" | "Float32" | "Float16"), []) -> true
    | ty -> Types.is_any_integer_type ty
  in
  let array_arithmetic_result =
    match op with
    | Add | Sub | Mul | Div -> (
        let has_vardims dims =
          List.exists (function TyVarDims _ -> true | _ -> false) dims
        in
        match (Types.array_parts left_ty, Types.array_parts right_ty) with
        | Some (elem, dims), None when types_equal elem right_ty ->
            Some (Types.ty_array elem dims)
        | None, Some (elem, dims) when types_equal left_ty elem ->
            Some (Types.ty_array elem dims)
        | Some (elem1, dims1), Some (elem2, dims2)
          when types_equal elem1 elem2
               && (not (has_vardims dims1))
               && (not (has_vardims dims2))
               && List.length dims1 = List.length dims2
               && List.for_all2 types_equal dims1 dims2 ->
            Some (Types.ty_array elem1 dims1)
        | _ -> None)
    | _ -> None
  in
  match op with
  (* Arithmetic operations *)
  | Add | Sub | Mul | Div | Mod -> (
      match array_arithmetic_result with
      | Some ty -> Ok ty
      | None -> (
          match (left_ty, right_ty) with
          (* Primitives: hardcoded for performance *)
          | TyNamed ("Int", []), TyNamed ("Int", []) -> Ok ty_int
          | TyNamed ("Float", []), TyNamed ("Float", []) -> Ok ty_float
          | TyNamed ("Fixed", []), TyNamed ("Fixed", []) when op <> Mod ->
              Ok (TyNamed ("Fixed", []))
          (* String concatenation *)
          | TyNamed ("String", []), TyNamed ("String", []) when op = Add ->
              Ok ty_string
          (* Float32/Float16 arithmetic: same-type only *)
          | TyNamed ("Float32", []), TyNamed ("Float32", []) ->
              Ok (TyNamed ("Float32", []))
          | TyNamed ("Float16", []), TyNamed ("Float16", []) ->
              Ok (TyNamed ("Float16", []))
          (* Sized integer arithmetic: same-type only, returns 0 on div-by-zero *)
          | left, right
            when Types.is_any_integer_type left && types_equal left right ->
              Ok left
          (* Type parameters: require appropriate arithmetic trait bound *)
          | _
            when types_equal left_ty right_ty
                 &&
                 let tp = Env.get_type_params ctx.env in
                 match left_ty with
                 | TyVar name | TyNamed (name, []) -> List.mem name tp
                 | _ -> false ->
              let param_name =
                match left_ty with TyVar n | TyNamed (n, []) -> n | _ -> ""
              in
              let trait_name =
                match op with
                | Add -> "Addable"
                | Sub -> "Subtractable"
                | Mul -> "Multipliable"
                | Div -> "Divisible"
                | Mod -> "Modulable"
                | _ -> "Addable"
              in
              if trait_obligation_satisfied ctx.env left_ty trait_name then
                Ok left_ty
              else
                error loc
                  (Printf.sprintf
                     "Type parameter '%s' requires %s bound for %s operator"
                     param_name trait_name
                     (match op with
                     | Add -> "+"
                     | Sub -> "-"
                     | Mul -> "*"
                     | Div -> "/"
                     | Mod -> "%"
                     | _ -> "?"))
          (* Non-primitives: check trait implementation *)
          | _
            when types_equal left_ty right_ty && not (is_primitive_type left_ty)
            ->
              let trait_name =
                match op with
                | Add -> "Addable"
                | Sub -> "Subtractable"
                | Mul -> "Multipliable"
                | Div -> "Divisible"
                | Mod -> "Modulable"
                | _ -> "Addable"
              in
              if trait_obligation_satisfied ctx.env left_ty trait_name then
                Ok left_ty (* Result type is Self *)
              else
                let help = suggest_capitalized_type left_ty in
                error_with ~notes:[] ~help loc
                  (Printf.sprintf
                     "Type %s does not implement %s (required for %s operator)"
                     (type_to_string left_ty)
                     (Env.format_trait_name ctx.env trait_name)
                     (match op with
                     | Add -> "+"
                     | Sub -> "-"
                     | Mul -> "*"
                     | Div -> "/"
                     | Mod -> "%"
                     | _ -> "?"))
          | _ ->
              let op_str =
                match op with
                | Add -> "+"
                | Sub -> "-"
                | Mul -> "*"
                | Div -> "/"
                | Mod -> "%"
                | _ -> "?"
              in
              let notes =
                if not (types_equal left_ty right_ty) then
                  [
                    Printf.sprintf
                      "'%s' requires both operands to be the same type" op_str;
                  ]
                else []
              in
              let help =
                match suggest_capitalized_type left_ty with
                | Some _ as h -> h
                | None -> suggest_capitalized_type right_ty
              in
              let help =
                match help with
                | Some _ -> help
                | None when not (types_equal left_ty right_ty) -> (
                    (* Suggest type conversion for common mismatches *)
                    match (left_ty, right_ty) with
                    | TyNamed ("Int", []), TyNamed ("Float", []) ->
                        Some "Convert with to_float(x) or to_int(y)"
                    | TyNamed ("Float", []), TyNamed ("Int", []) ->
                        Some "Convert with to_int(x) or to_float(y)"
                    | _, TyNamed ("String", []) | TyNamed ("String", []), _ ->
                        Some "Convert with to_string(x)"
                    | TyNamed ("Option", _), _ | _, TyNamed ("Option", _) ->
                        Some
                          "Option values must be unwrapped first — use match, \
                           .get_or(default), or try: with ?="
                    | TyNamed ("Result", _), _ | _, TyNamed ("Result", _) ->
                        Some
                          "Result values must be unwrapped first — use match, \
                           .get_or(default), or try: with ?="
                    | _ -> None)
                | _ -> help
              in
              error_with ~notes ~help loc
                (Printf.sprintf "Cannot apply %s to %s and %s" op_str
                   (type_to_string left_ty) (type_to_string right_ty))))
  (* Comparison operations *)
  | Lt | Gt | Le | Ge -> (
      match (left_ty, right_ty) with
      (* Primitives: hardcoded *)
      | TyNamed ("Int", []), TyNamed ("Int", []) -> Ok ty_bool
      (* Int vs dim types: dim types are Int values at runtime *)
      | TyNamed ("Int", []), TyConstInt _ | TyConstInt _, TyNamed ("Int", []) ->
          Ok ty_bool
      | TyNamed ("Int", []), TyVar name when Types.Dim.is_var_name name ->
          Ok ty_bool
      | TyVar name, TyNamed ("Int", []) when Types.Dim.is_var_name name ->
          Ok ty_bool
      | TyNamed ("Float", []), TyNamed ("Float", []) -> Ok ty_bool
      | TyNamed ("String", []), TyNamed ("String", []) -> Ok ty_bool
      | TyNamed ("Char", []), TyNamed ("Char", []) -> Ok ty_bool
      | TyNamed ("Fixed", []), TyNamed ("Fixed", []) -> Ok ty_bool
      (* Float32/Float16 comparison: same-type only *)
      | TyNamed ("Float32", []), TyNamed ("Float32", []) -> Ok ty_bool
      | TyNamed ("Float16", []), TyNamed ("Float16", []) -> Ok ty_bool
      (* Sized integer comparison: same-type only *)
      | left, right
        when Types.is_any_integer_type left && types_equal left right ->
          Ok ty_bool
      (* Type parameters: require Orderable bound for comparison *)
      | _
        when types_equal left_ty right_ty
             &&
             let tp = Env.get_type_params ctx.env in
             match left_ty with
             | TyVar name | TyNamed (name, []) -> List.mem name tp
             | _ -> false ->
          let param_name =
            match left_ty with TyVar n | TyNamed (n, []) -> n | _ -> ""
          in
          if trait_obligation_satisfied ctx.env left_ty "Orderable" then
            Ok ty_bool
          else
            error loc
              (Printf.sprintf
                 "Type parameter '%s' requires Orderable bound for comparison \
                  operators. Add '%s: Orderable' to the function signature"
                 param_name param_name)
      (* Non-primitives: check Orderable trait *)
      | _ when types_equal left_ty right_ty && not (is_primitive_type left_ty)
        ->
          if trait_obligation_satisfied ctx.env left_ty "Orderable" then
            Ok ty_bool
          else
            error loc
              (Printf.sprintf
                 "Type %s does not implement %s (required for comparison \
                  operators)"
                 (type_to_string left_ty)
                 (Env.format_trait_name ctx.env "Orderable"))
      | _ ->
          error loc
            (Printf.sprintf
               "Comparison requires matching types that implement Orderable, \
                got %s and %s"
               (type_to_string left_ty) (type_to_string right_ty)))
  (* Equality operations *)
  | Eq | Ne -> (
      let tp = Env.get_type_params ctx.env in
      let compat a b = types_bidirectional ~type_params:tp a b in
      match (left_ty, right_ty) with
      (* Primitives and compatible types *)
      | _ when is_primitive_type ~env:ctx.env left_ty && compat left_ty right_ty
        ->
          Ok ty_bool
      (* Tensor equality: element-wise comparison returning Bool *)
      | _
        when match (Types.array_parts left_ty, Types.array_parts right_ty) with
             | Some (elem, _), Some _
               when numeric_array_elem elem && compat left_ty right_ty ->
                 true
             | _ -> false ->
          Ok ty_bool
      (* Collection equality: structural comparison *)
      | ( TyNamed (("List" | "Dict" | "Set"), _),
          TyNamed (("List" | "Dict" | "Set"), _) )
        when compat left_ty right_ty ->
          Ok ty_bool
      (* Type parameters: require Equatable bound *)
      | _
        when types_equal left_ty right_ty
             &&
             let tp = Env.get_type_params ctx.env in
             match left_ty with
             | TyVar name | TyNamed (name, []) -> List.mem name tp
             | _ -> false ->
          let param_name =
            match left_ty with TyVar n | TyNamed (n, []) -> n | _ -> ""
          in
          if trait_obligation_satisfied ctx.env left_ty "Equatable" then
            Ok ty_bool
          else
            error loc
              (Printf.sprintf
                 "Type parameter '%s' requires Equatable bound for == and != \
                  operators. Add '%s: Equatable' to the function signature"
                 param_name param_name)
      (* Non-primitives: check Equatable trait *)
      | _
        when types_equal left_ty right_ty
             && not (is_primitive_type ~env:ctx.env left_ty) ->
          if trait_obligation_satisfied ctx.env left_ty "Equatable" then
            Ok ty_bool
          else
            error loc
              (Printf.sprintf
                 "Type %s does not implement %s (required for == and != \
                  operators)"
                 (type_to_string left_ty)
                 (Env.format_trait_name ctx.env "Equatable"))
      (* Reject comparing different type parameters even if both are compatible.
          T == U is unsound — Equatable means a type can be compared with ITSELF. *)
      | _
        when let is_tp n = List.mem n tp in
             match (left_ty, right_ty) with
             | (TyVar l | TyNamed (l, [])), (TyVar r | TyNamed (r, []))
               when is_tp l && is_tp r && l <> r ->
                 true
             | _ -> false ->
          error loc
            (Printf.sprintf
               "Cannot compare type parameters %s and %s — equality requires \
                the same type"
               (type_to_string left_ty) (type_to_string right_ty))
      | _ when compat left_ty right_ty -> Ok ty_bool
      | _ ->
          error loc
            (Printf.sprintf
               "Equality comparison requires compatible types, got %s and %s"
               (type_to_string left_ty) (type_to_string right_ty)))

(** Get the result type of a unary operation *)
let check_unop (env : Env.env) (op : unop) (operand_ty : type_expr) loc :
    type_expr infer_result =
  match op with
  | Neg -> (
      match operand_ty with
      | TyNamed ("Int", []) -> Ok ty_int
      | TyNamed ("Float", []) -> Ok ty_float
      | TyNamed ("Float32", []) -> Ok (TyNamed ("Float32", []))
      | TyNamed ("Float16", []) -> Ok (TyNamed ("Float16", []))
      | _
        when match Types.array_parts operand_ty with
             | Some (TyNamed (("Int" | "Float" | "Float32" | "Float16"), []), _)
               ->
                 true
             | Some (elem, _) when Types.is_signed_integer_type elem -> true
             | _ -> false ->
          Ok operand_ty
      | _ when Types.is_signed_integer_type operand_ty -> Ok operand_ty
      | _ when Types.is_unsigned_integer_type operand_ty ->
          error loc
            (Printf.sprintf "Cannot negate unsigned type %s"
               (type_to_string operand_ty))
      | _ when trait_obligation_satisfied env operand_ty "Negatable" ->
          Ok operand_ty
      | _ ->
          error loc
            (Printf.sprintf "Negation requires numeric type, got %s"
               (type_to_string operand_ty)))
  | Not -> (
      match operand_ty with
      | TyNamed ("Bool", []) -> Ok ty_bool
      | _ ->
          error loc
            (Printf.sprintf "Logical not requires Bool, got %s"
               (type_to_string operand_ty)))

(** Get the result type of a logical operation *)
let check_logop (_op : logop) (left_ty : type_expr) (right_ty : type_expr) loc :
    type_expr infer_result =
  match (left_ty, right_ty) with
  | TyNamed ("Bool", []), TyNamed ("Bool", []) -> Ok ty_bool
  | _ ->
      error loc
        (Printf.sprintf
           "Logical operation requires Bool operands, got %s and %s"
           (type_to_string left_ty) (type_to_string right_ty))

(* ============================================================================
   Mutable Capture Detection
   ============================================================================ *)

(** Collect all variable references in an expression.
    Used for mutable capture detection in closures. *)
let rec collect_var_refs (expr : expr) : string list =
  match expr.expr_desc with
  | EIdent name -> [ name ]
  | EAssign (name, init) -> name :: collect_var_refs init
  | _ -> List.concat_map collect_var_refs (expr_children expr)

(** Check if a lambda captures any mutable variables *)
let check_no_mutable_captures (env : env) (func : func_decl) (loc : loc) :
    compiler_error option =
  match func_body_expr_opt func.func_body with
  | None -> None
  | Some body -> (
      (* Get all variable references in the body *)
      let all_refs = collect_var_refs body in
      (* Get parameter names (these are locally bound, not captures) *)
      let param_names =
        List.filter_map (fun (p : Ast.param) -> p.param_name) func.func_params
      in
      (* Free variables are references that aren't parameters *)
      let free_vars =
        List.filter (fun name -> not (List.mem name param_names)) all_refs
      in
      (* Remove duplicates *)
      let free_vars = List.sort_uniq String.compare free_vars in
      (* Check if any free variable is mutable *)
      let mutable_captures =
        List.filter
          (fun name ->
            match lookup env name with
            | Some { kind = VarSymbol { mutability = Mutable; _ }; _ } -> true
            | _ -> false)
          free_vars
      in
      match mutable_captures with
      | [] -> None
      | vars ->
          Some
            {
              message =
                Printf.sprintf
                  "Closure cannot capture mutable variable%s: %s. Use explicit \
                   state threading instead."
                  (if List.length vars > 1 then "s" else "")
                  (String.concat ", " vars);
              loc;
              phase = TypeCheck;
              kind = OtherError;
              notes = [];
              help = None;
            })

(** Convert an expression to a proven_collection if all subscripts in the chain are proven safe.
    Base case: any EIdent is always matchable (returns CollVar).
    Recursive case: ESubscript(coll, idx_var) only matches if idx_var is proven for coll. *)
let rec expr_to_proven_collection env (e : expr) : proven_collection option =
  match e.expr_desc with
  | EIdent v -> collection_var_opt v
  | ESubscript (coll_expr, ({ expr_desc = EIdent idx_var; _ } as idx_expr))
  | ECall
      ( { expr_desc = EIdent ("checked_get" | "tensor_peel"); _ },
        [ coll_expr; ({ expr_desc = EIdent idx_var; _ } as idx_expr) ] ) -> (
      match expr_to_proven_collection env coll_expr with
      | Some coll_pc ->
          if
            expr_proves_subscript idx_expr coll_pc
            || env_binding_proves_subscript env idx_var coll_pc
          then collection_subscript_opt coll_pc idx_var
          else None
      | None -> None)
  | _ -> None

(** Resolve the type of a subscript chain expression using dimensional peeling.
    E.g., m[i] where m: Int[#2, #3] -> Int[#3] *)
let rec resolve_subscript_chain_type (env : env) (e : expr) : type_expr option =
  match e.expr_desc with
  | EIdent v -> get_var_type env v
  | ESubscript (coll, _idx)
  | ECall
      ({ expr_desc = EIdent ("checked_get" | "tensor_peel"); _ }, [ coll; _idx ])
    -> (
      match resolve_subscript_chain_type env coll with
      | Some coll_ty -> (
          match Types.array_parts coll_ty with
          | Some (elem_ty, _ :: rest_dims) -> (
              match rest_dims with
              | [] -> Some elem_ty
              | _ -> Some (Types.ty_array elem_ty rest_dims))
          | _ -> expr_proof_semantic_type_opt e)
      | _ -> expr_proof_semantic_type_opt e)
  | _ -> None

(* ============================================================================
   Call Inference Helpers
   (defined before infer_expr since they don't need mutual recursion)
   ============================================================================ *)

(** Build a substitution from type variable to concrete type.
    ~type_params: explicit list of type parameter names (e.g., ["T"; "Acc"; "T:Stringable"]).
    Only names in this list (after stripping bounds) are treated as substitutable type params. *)
let build_subst ~(type_params : string list) (param_ty : type_expr)
    (arg_ty : type_expr) : subst_map =
  let stripped = Env.type_param_names type_params in
  let rec go param_ty arg_ty =
    let collect_args param_args arg_args =
      if List.length param_args = List.length arg_args then
        List.concat (List.map2 go param_args arg_args)
      else if
        List.length param_args > List.length arg_args
        &&
        match List.nth param_args (List.length param_args - 1) with
        | TyVarDims _ -> true
        | _ -> false
      then
        let prefix =
          List.filteri (fun i _ -> i < List.length arg_args) param_args
        in
        List.concat (List.map2 go prefix arg_args)
      else if
        param_args <> []
        && (match List.nth param_args (List.length param_args - 1) with
          | TyVarDims _ -> true
          | _ -> false)
        && List.length arg_args > List.length param_args
      then
        let non_vardims =
          List.filter (function TyVarDims _ -> false | _ -> true) param_args
        in
        let arg_prefix =
          List.filteri (fun i _ -> i < List.length non_vardims) arg_args
        in
        List.concat (List.map2 go non_vardims arg_prefix)
      else []
    in
    match param_ty with
    | TyVar name -> [ { var_name = name; concrete_type = arg_ty } ]
    | TyBoundVar param ->
        [ { var_name = param.param_name; concrete_type = arg_ty } ]
    | TyNamed (n, []) when List.mem n stripped ->
        [ { var_name = n; concrete_type = arg_ty } ]
    | TyNamed (_, param_args) -> (
        match arg_ty with
        | TyNamed (_, arg_args)
          when List.length param_args = List.length arg_args ->
            collect_args param_args arg_args
        (* Handle variadic dims: param has trailing #N..., arg has fewer args.
            Match the prefix and ignore the trailing #N.... *)
        | TyNamed (_, arg_args)
          when List.length param_args > List.length arg_args
               &&
               match List.nth param_args (List.length param_args - 1) with
               | TyVarDims _ -> true
               | _ -> false ->
            collect_args param_args arg_args
        (* Handle variadic dims: param has trailing #N..., arg has MORE args.
            e.g., T[#N...] param vs Float[#2, #3] arg.
            Match the non-#N... prefix of param against the corresponding prefix of arg. *)
        | TyNamed (_, arg_args)
          when param_args <> []
               && (match List.nth param_args (List.length param_args - 1) with
                 | TyVarDims _ -> true
                 | _ -> false)
               && List.length arg_args > List.length param_args ->
            collect_args param_args arg_args
        | _ -> [])
    | TyArray (param_elem, param_dims) -> (
        match arg_ty with
        | TyArray (arg_elem, arg_dims) ->
            collect_args (param_elem :: param_dims) (arg_elem :: arg_dims)
        | _ -> [])
    | TyTuple pelems -> (
        match arg_ty with
        | TyTuple aelems when List.length pelems = List.length aelems ->
            List.concat (List.map2 go pelems aelems)
        | _ -> [])
    | TyFunc { params = pp; return = pr; _ } -> (
        match arg_ty with
        | TyFunc { params = ap; return = ar; _ }
          when List.length pp = List.length ap ->
            List.concat (List.map2 go pp ap) @ go pr ar
        | _ -> [])
    | TyConstInt _ -> []
    | TyRange inner -> (
        (* Unwrap both sides: param ..#N with arg ..#4 should bind #N to #4, not ..#4 *)
        match arg_ty with
        | TyRange arg_inner -> go inner arg_inner
        | _ -> go inner arg_ty)
    | TySelf -> [ { var_name = "Self"; concrete_type = arg_ty } ]
    | TyVarDims _ -> []
    | TyDimOp (op, a, b) -> (
        match arg_ty with
        | TyDimOp (op2, a2, b2) when op = op2 -> go a a2 @ go b b2
        (* Single-variable solving: #X + c matched against concrete n *)
        | TyConstInt n -> (
            match (op, a, b) with
            | DimAdd, TyVar name, TyConstInt c when n - c >= 0 ->
                [ { var_name = name; concrete_type = TyConstInt (n - c) } ]
            | DimAdd, TyConstInt c, TyVar name when n - c >= 0 ->
                [ { var_name = name; concrete_type = TyConstInt (n - c) } ]
            | DimSub, TyVar name, TyConstInt c ->
                [ { var_name = name; concrete_type = TyConstInt (n + c) } ]
            | DimMul, TyVar name, TyConstInt c when c > 0 && n mod c = 0 ->
                [ { var_name = name; concrete_type = TyConstInt (n / c) } ]
            | DimMul, TyConstInt c, TyVar name when c > 0 && n mod c = 0 ->
                [ { var_name = name; concrete_type = TyConstInt (n / c) } ]
            | DimDiv, TyVar name, TyConstInt c when c > 0 ->
                [ { var_name = name; concrete_type = TyConstInt (n * c) } ]
            | _ -> [])
        | _ -> [])
    | TyMeta _ -> [] (* Unification variable — no substitution to build *)
  in
  go param_ty arg_ty

(** Check if an argument type is a type parameter that needs a trait bound *)
let check_trait_bound_on_arg (ctx : infer_ctx) ?(is_builtin = false) callee_name
    arg_ty loc : unit infer_result =
  match get_function_trait ctx.env callee_name with
  | None -> Ok () (* not a trait function — no bounds to check *)
  | Some required_trait -> (
      let type_param_name =
        match arg_ty with
        | TyVar name -> Some name
        | TyNamed (name, [])
          when List.exists
                 (fun p -> Env.type_param_name p = name)
                 (get_type_params ctx.env) ->
            Some name
        | _ -> None
      in
      match type_param_name with
      | Some param_name when Types.Dim.is_var_name param_name ->
          (* Dimension variables (#N, #M, ...) always monomorphize to [Int]
              at runtime — they're compile-time dimension markers. Trait
              bounds on dim args are checked at monomorphization against
              the concrete [Int] type, not in this pre-mono pass where
              per-module typecheck doesn't see downstream trait impls.
              Without this, calls like [to_float(length(v))] where
              [v: T[#N]] would wrongly require [#N: ToFloat],
              but dim params can't carry trait bounds syntactically. *)
          Ok ()
      | Some param_name ->
          (* Type variable: check if it has the required trait bound *)
          if trait_obligation_satisfied ctx.env arg_ty required_trait then Ok ()
          else
            error loc
              (Printf.sprintf
                 "Type parameter %s requires trait bound %s to call %s"
                 param_name required_trait callee_name)
      | None -> (
          if
            (* Concrete type: only enforce trait bounds for builtin calls.
              Module-qualified calls (like debug.log) skip this — they're specific functions,
              not trait dispatch. *)
            not is_builtin
          then Ok ()
          else if trait_obligation_satisfied ctx.env arg_ty required_trait then
            Ok ()
          (* Element-wise tensor dispatch: if the tensor's element type implements
              the trait, accept the tensor. sqrt(Float[#M, #N]) works because
              Float implements FloatingPoint. *)
            else
            match Types.array_parts arg_ty with
            | Some (elem_ty, _)
              when trait_obligation_satisfied ctx.env elem_ty required_trait ->
                Ok ()
            | _ ->
                error loc
                  (Printf.sprintf
                     "Type '%s' does not implement trait '%s' required by '%s'"
                     (type_to_string arg_ty)
                     (Env.format_trait_name ctx.env required_trait)
                     callee_name)))

(** Extract function name from a callee expression *)
let get_callee_name (callee : expr) : string option =
  match callee.expr_desc with
  | EIdent name -> Some name
  | EFieldAccess (_, name) -> Some name
  | _ -> None

(** Check if a type contains TySelf *)
let rec contains_ty_self (ty : type_expr) : bool =
  match ty with
  | TySelf -> true
  | TyNamed (_, args) -> List.exists contains_ty_self args
  | TyArray (elem, dims) ->
      contains_ty_self elem || List.exists contains_ty_self dims
  | TyFunc { params; return; _ } ->
      List.exists contains_ty_self params || contains_ty_self return
  | TyTuple elems -> List.exists contains_ty_self elems
  | TyRange inner -> contains_ty_self inner
  | TyDimOp (_, a, b) -> contains_ty_self a || contains_ty_self b
  | TyVar _ | TyBoundVar _ | TyConstInt _ | TyVarDims _ -> false
  | TyMeta _ -> false (* Unification variable — not TySelf *)

(** Shorthand for types_compatible using ctx's type params *)
let ctx_types_compatible ctx expected actual =
  match ctx.rigid_type_params with
  | [] ->
      types_compatible
        ~type_params:(Env.get_type_params ctx.env)
        expected actual
  | rigid_vars -> types_compatible_rigid ~rigid_vars expected actual

(** Tensor loop-view classification must be tied to a resolved tensor producer,
    not just the source spelling. Local or third-party functions named
    [enumerate]/[enumerate2]/[windows] must keep normal function-call semantics.

    The declaration/typecheck boundary assigns [loop_producer] metadata to
    std/tensor producers and to the compatibility builtin [enumerate2], so this
    phase no longer reconstructs producer identity from module paths. *)
let loop_producer_for_resolved_name ctx name =
  let name_without_def_id =
    match String.index_opt name '#' with
    | Some hash_idx -> String.sub name 0 hash_idx
    | None -> name
  in
  match Env.get_func_loop_producer ctx.env name with
  | Some producer -> Some producer
  | None -> (
      match Env.get_func_loop_producer ctx.env name_without_def_id with
      | Some producer -> Some producer
      | None -> (
          match Codegen_names.parse_ufcs_name name_without_def_id with
          | Some ("std/tensor", "indices") -> Some LoopProducerIndices
          | Some ("std/tensor", "enumerate") -> Some LoopProducerEnumerate
          | Some ("std/tensor", "enumerate2") -> Some LoopProducerEnumerate2
          | Some ("std/tensor", "windows") -> Some LoopProducerWindows
          | _ -> None))

let is_tensor_loop_call ctx expected name args =
  loop_producer_for_resolved_name ctx name = Some expected
  && List.for_all (fun arg -> Option.is_some (expr_semantic_type_opt arg)) args

let tensor_first_index_type (coll_ty : type_expr) : type_expr option =
  match Types.array_parts coll_ty with
  | Some (_, dim :: _) ->
      Some
        (match dim with
        | TyConstInt n when n > 0 -> TyRange (TyConstInt n)
        | TyVar name when Types.Dim.is_var_name name -> TyRange (TyVar name)
        | _ -> ty_int)
  | Some (_, []) -> Some ty_int
  | None -> None

(** Check for conflicting type variable substitutions in a call. *)
let check_subst_conflicts subst_with_sources callee_type_params callee_name env
    loc =
  let check_conflicts acc (entry, source) =
    match acc with
    | Error e -> Error e
    | Ok seen -> (
        match List.assoc_opt entry.var_name seen with
        | None -> Ok ((entry.var_name, (entry.concrete_type, source)) :: seen)
        | Some (prev_ty, prev_source) ->
            let prev_resolved =
              normalize_type_with_env env SubstitutionConflictComparison prev_ty
            in
            let curr_resolved =
              normalize_type_with_env env SubstitutionConflictComparison
                entry.concrete_type
            in
            if
              types_bidirectional ~type_params:callee_type_params prev_resolved
                curr_resolved
            then Ok seen
            else
              let func_hint =
                match callee_name with
                | Some n -> Printf.sprintf " in call to '%s'" n
                | None -> ""
              in
              error loc
                (Printf.sprintf
                   "Type parameter %s resolved to incompatible types: %s (%s) \
                    and %s (%s)%s"
                   entry.var_name
                   (type_to_string prev_resolved)
                   prev_source
                   (type_to_string curr_resolved)
                   source func_hint))
  in
  match List.fold_left check_conflicts (Ok []) subst_with_sources with
  | Ok _ -> Ok ()
  | Error e -> Error e

(** Check trait bounds on concrete type substitutions for a function call. *)
let check_callee_trait_bounds ?callee_bound_params callee_name subst env loc =
  match callee_name with
  | None -> Ok ()
  | Some name -> (
      let bounded_params =
        match callee_bound_params with
        | Some params -> Some params
        | None -> (
            match Env.get_func_info env name with
            | Some (_, tps, _) -> Some tps
            | None -> None)
      in
      match bounded_params with
      | None -> Ok ()
      | Some bounded_params ->
          List.fold_left
            (fun acc bp ->
              match acc with
              | Error e -> Error e
              | Ok () -> (
                  if bp.Env.param_bounds = [] then Ok ()
                  else
                    let concrete =
                      List.find_opt
                        (fun s -> s.var_name = bp.Env.param_name)
                        subst
                    in
                    match concrete with
                    | None -> Ok ()
                    | Some { concrete_type; _ } -> (
                        let type_var_name =
                          match concrete_type with
                          | TyVar n when List.mem n (Env.get_type_params env) ->
                              Some n
                          | TyNamed (n, [])
                            when List.exists
                                   (fun p -> Env.type_param_name p = n)
                                   (Env.get_type_params env) ->
                              Some n
                          | TyVar _ ->
                              None
                              (* Unresolved callee type param — check as concrete *)
                          | _ -> None
                        in
                        let obligations =
                          Env.trait_obligations_for_bound_type_param bp
                            concrete_type
                        in
                        match
                          Env.find_unsatisfied_trait_obligation env obligations
                        with
                        | None -> Ok ()
                        | Some obligation -> (
                            let trait_name =
                              Generic_params.trait_ref_name
                                obligation.Env.obligation_trait
                            in
                            match type_var_name with
                            | Some var_name ->
                                error loc
                                  (Printf.sprintf
                                     "Type parameter %s does not have bound %s \
                                      (required by %s)"
                                     var_name trait_name name)
                            | None ->
                                error loc
                                  (Printf.sprintf
                                     "Type %s does not implement trait %s \
                                      (required by %s)"
                                     (type_to_string concrete_type)
                                     (Env.format_trait_name env trait_name)
                                     name)))))
            (Ok ()) bounded_params)

(* ============================================================================
   Meta zonking — AST walk that resolves every [TyMeta] to its binding
   ============================================================================

   Called at the end of each function-body inference. After this walk every
   [expr_type] and [expr_type_info] annotation (plus type annotations embedded
   in [EVarDecl], [ETryBind], [EConcurrentBind], [ELambda] params/return)
   contains no leftover [TyMeta]. Any meta that's still unbound gets reported
   via [collect_unbound_metas] as a location'd "cannot infer" error. *)

let rec zonk_expr (e : expr) : expr =
  let e = Ast.map_expr_type_payload Types.zonk_type e in
  { e with expr_desc = zonk_expr_desc e.expr_desc }

and zonk_expr_desc = function
  | ( EIdent _ | ELiteral _ | EVoid | EBuiltin _ | EBreak | EContinue
    | EStringInterpRaw _ ) as d ->
      d
  | EBinary (op, a, b) -> EBinary (op, zonk_expr a, zonk_expr b)
  | EUnary (op, x) -> EUnary (op, zonk_expr x)
  | ELogical (op, a, b) -> ELogical (op, zonk_expr a, zonk_expr b)
  | EAscription (x, ty) -> EAscription (zonk_expr x, Types.zonk_type ty)
  | ECall (fn, args) -> ECall (zonk_expr fn, List.map zonk_expr args)
  | EIf (c, t, e) -> EIf (zonk_expr c, zonk_expr t, Option.map zonk_expr e)
  | EMatch (scrut, arms) ->
      EMatch
        ( zonk_expr scrut,
          List.map
            (fun (c : match_case) ->
              { c with case_body = zonk_expr c.case_body })
            arms )
  | EBlock xs -> EBlock (List.map zonk_expr xs)
  | ETuple xs -> ETuple (List.map zonk_expr xs)
  | EVector xs -> EVector (List.map zonk_expr xs)
  | EList xs -> EList (List.map zonk_expr xs)
  | ERecord fs -> ERecord (List.map (fun (n, x) -> (n, zonk_expr x)) fs)
  | ERecordUpdate (b, fs) ->
      ERecordUpdate (zonk_expr b, List.map (fun (n, x) -> (n, zonk_expr x)) fs)
  | EFieldAccess (o, f) -> EFieldAccess (zonk_expr o, f)
  | ELambda f -> ELambda (zonk_func_decl f)
  | EWhile (c, b) -> EWhile (zonk_expr c, zonk_expr b)
  | EFor (v, it, b) -> EFor (v, zonk_expr it, zonk_expr b)
  | EForTuple (vs, it, b) -> EForTuple (vs, zonk_expr it, zonk_expr b)
  | ELoopView view ->
      ELoopView
        {
          loop_view_kind = view.loop_view_kind;
          loop_view_source = zonk_expr view.loop_view_source;
          loop_view_size_arg = Option.map zonk_expr view.loop_view_size_arg;
          loop_view_elem_type = Types.zonk_type view.loop_view_elem_type;
        }
  | EAssign (v, x) -> EAssign (v, zonk_expr x)
  | EVarDecl (n, ty, v, m) ->
      EVarDecl (n, Option.map Types.zonk_type ty, zonk_expr v, m)
  | ETupleDestruct (ns, v) -> ETupleDestruct (ns, zonk_expr v)
  | ERange (a, b) -> ERange (zonk_expr a, zonk_expr b)
  (* [ESubscript]/[ESubscriptMulti] are rewritten to call syntax by
     [Subscript_desugar] before typecheck and rejected by
     [infer_expr_desc] if they somehow survive. Reaching them here
     would be a symmetric invariant violation — kept in lockstep with
     infer so a bug in either phase surfaces with a clear message
     rather than silently traversing. [ESubscriptAssign] stays
     through zonking by design (Phase 2.3 keeps it in infer for the
     mutability check). *)
  | ESubscript (_, _) | ESubscriptMulti (_, _) ->
      failwith
        "internal: subscript-read node reached zonk; Subscript_desugar should \
         have rewritten it, or infer should have rejected it before zonking"
  | ESubscriptAssign (c, is, v) ->
      ESubscriptAssign (zonk_expr c, List.map zonk_expr is, zonk_expr v)
  | EStringInterp (parts, triple) ->
      EStringInterp
        ( List.map
            (function
              | InterpLit s -> InterpLit s
              | InterpExpr x -> InterpExpr (zonk_expr x))
            parts,
          triple )
  | ETry xs -> ETry (List.map zonk_expr xs)
  | ETryBind (n, ty, v) ->
      ETryBind (n, Option.map Types.zonk_type ty, zonk_expr v)
  | EDebugBlock xs -> EDebugBlock (List.map zonk_expr xs)
  | EConcurrent (xs, t, m) ->
      EConcurrent (List.map zonk_expr xs, Option.map zonk_expr t, m)
  | EConcurrentBind (n, ty, v) ->
      EConcurrentBind (n, Option.map Types.zonk_type ty, zonk_expr v)
  | EConcurrentFor (v, it, b, t, m) ->
      EConcurrentFor (v, zonk_expr it, zonk_expr b, Option.map zonk_expr t, m)
  | EDetach x -> EDetach (zonk_expr x)
  | EDict pairs ->
      EDict (List.map (fun (k, v) -> (zonk_expr k, zonk_expr v)) pairs)
  | EFuncDecl func -> EFuncDecl (zonk_func_decl func)

and zonk_func_decl (f : func_decl) : func_decl =
  {
    f with
    func_return_type = Option.map Types.zonk_type f.func_return_type;
    func_params =
      List.map
        (fun (p : param) ->
          { p with param_type = Option.map Types.zonk_type p.param_type })
        f.func_params;
    func_body = map_func_body_expr zonk_expr f.func_body;
  }

(** Collect every [TyVarDims] name bound by a [FuncParam] in any enclosing
    scope. Used to tell "this variadic dim is a pass-through from our
    generic signature" from "this variadic dim escaped from somewhere it
    shouldn't have". *)
let vardims_bound_in_scope (env : Env.env) : string list =
  List.concat_map
    (fun scope ->
      List.concat_map
        (fun (sym : Env.symbol) ->
          match sym.kind with
          | Env.VarSymbol { var_type; origin = Env.FuncParam; _ } ->
              Types.Dim.collect_vardim_names var_type
          | _ -> [])
        scope)
    env.scopes

let validate_value_ascription_type loc ty =
  match ty with
  | TyNamed ("Void", []) ->
      error loc "Cannot ascribe an expression with type Void"
  | _ -> (
      match Types.Dim.find_negative ty with
      | Some n ->
          error loc
            (Printf.sprintf
               "Dimension arithmetic produces non-positive result: %d \
                (dimensions must be >= 1)"
               n)
      | None ->
          if Types.Dim.contains_vardims ty then
            error_with ~notes:[]
              ~help:
                (Some
                   "Use concrete dimensions, or remove the inline type \
                    ascription and let the compiler infer the value type")
              loc
              (Printf.sprintf
                 "Variadic dimensions (#N...) cannot appear in expression type \
                  ascriptions: %s"
                 (type_to_string ty))
          else Ok ())

(* ============================================================================
   Main Expression Inference
   ============================================================================ *)

(** Infer the type of an expression *)
let rec infer_expr (ctx : infer_ctx) (expr : expr) :
    (type_expr * expr) infer_result =
  let loc = expr.expr_loc in
  match expr.expr_desc with
  (* Identifier lookup *)
  | EIdent name -> (
      match Env.lookup ctx.env name with
      | Some { kind = Env.VarSymbol { var_type = ty; source_type; _ }; _ } ->
          let proofs = expr_proofs_for_identifier ctx.env name ty in
          Ok (ty, with_inferred_type ?source_ty:source_type ~proofs expr ty)
      | Some { kind = Env.FuncSymbol { func_type; _ }; _ } ->
          Ok (func_type, with_inferred_type expr func_type)
      | _ -> (
          (* Could be a constructor *)
          match get_constructor ctx.env name with
          | Some (parent, type_params, [], _tag) ->
              (* Nullary constructor - returns the parent type *)
              (* Use expected type for instantiation if available (bidirectional) *)
              let ty =
                if type_params = [] then TyNamed (parent, [])
                else
                  match expected_type_opt ctx with
                  | Some (TyNamed (exp_name, args))
                    when exp_name = parent
                         && List.length args = List.length type_params ->
                      (* Use expected type's args to instantiate *)
                      TyNamed (parent, args)
                  | _ ->
                      (* No expected type — instantiate to fresh metas
                                  so cross-arm match unification (e.g. [Empty]
                                  vs [Value(x)] in [match c: ...]) propagates
                                  bindings through the global meta env. *)
                      TyNamed
                        ( parent,
                          List.map
                            (fun p -> Types.fresh_meta ~origin:p ())
                            type_params )
              in
              Ok (ty, with_inferred_type expr ty)
          | Some (parent, type_params, field_types, _tag) ->
              (* Constructor with fields - it's a function *)
              let params, return_ty =
                if type_params = [] then (field_types, TyNamed (parent, []))
                else
                  match expected_type_opt ctx with
                  | Some (TyNamed (exp_name, args))
                    when exp_name = parent
                         && List.length args = List.length type_params ->
                      (* Use expected type's args to instantiate — avoids type variable
                           name collision when the constructor's type params shadow
                           the enclosing function's type params (e.g. Some in pop[T]) *)
                      let subst = List.combine type_params args in
                      let apply ty =
                        Types.map_type_expr
                          (function
                            | TyVar name when List.mem_assoc name subst ->
                                Some (List.assoc name subst)
                            | TyNamed (name, []) when List.mem_assoc name subst
                              ->
                                Some (List.assoc name subst)
                            | _ -> None)
                          ty
                      in
                      (List.map apply field_types, TyNamed (parent, args))
                  | _ ->
                      (* No expected type - use TyVars for inference *)
                      let params =
                        List.map
                          (instantiate_type_params type_params)
                          field_types
                      in
                      let return_ty =
                        TyNamed (parent, List.map (fun p -> TyVar p) type_params)
                      in
                      (params, return_ty)
              in
              let ty = TyFunc { params; return = return_ty; is_pure = true } in
              Ok (ty, with_inferred_type expr ty)
          | None -> (
              (* Could be a trait method *)
              match get_function_trait ctx.env name with
              | Some trait_name -> (
                  (* Look up the trait definition *)
                  match get_trait ctx.env trait_name with
                  | Some trait_def -> (
                      (* Find the method signature *)
                      match
                        List.find_opt
                          (fun m -> m.tm_name = name)
                          trait_def.td_methods
                      with
                      | Some method_sig ->
                          (* Return the method type with TySelf still in it
                                  - it will be resolved at call site *)
                          let ty =
                            TyFunc
                              {
                                params = method_sig.tm_params;
                                return = method_sig.tm_return;
                                is_pure = method_sig.tm_is_pure;
                              }
                          in
                          Ok (ty, with_inferred_type expr ty)
                      | None -> undefined_ident_error ctx name loc)
                  | None -> undefined_ident_error ctx name loc)
              | None -> undefined_ident_error ctx name loc)))
  (* Literals *)
  | ELiteral lit -> (
      let ty = infer_literal lit in
      let expected_slot_result semantic_ty =
        Ok
          ( semantic_ty,
            annotate_expected_value_slot ctx
              (with_inferred_type expr semantic_ty)
              semantic_ty )
      in
      (* Contextual narrowing: if expected type is a sized int and literal is LitInt, narrow *)
      match (lit, expected_type_opt ctx) with
      | LitInt _, Some (TyNamed ("Int", []) as expected_ty) ->
          if Option.is_some (expected_value_slot_opt ctx ty) then
            expected_slot_result ty
          else Ok (expected_ty, with_inferred_type expr expected_ty)
      | LitInt n, Some (TyNamed (type_name, []) as expected_ty)
        when Types.is_any_integer_type expected_ty && type_name <> "Int" ->
          let lo, hi = Types.int_type_range type_name in
          if n >= lo && n <= hi then
            if Option.is_some (expected_value_slot_opt ctx ty) then
              expected_slot_result ty
            else Ok (expected_ty, with_inferred_type expr expected_ty)
          else
            error loc
              (Printf.sprintf "Literal %Ld exceeds %s range [%Ld, %Ld]" n
                 type_name lo hi)
      | LitInt n, Some (TyRange (TyConstInt bound))
        when n >= 0L && n < Int64.of_int bound ->
          let range_ty = TyRange (TyConstInt bound) in
          Ok (range_ty, with_inferred_type expr range_ty)
      | LitInt n, Some (TyConstInt expected_n) when n = Int64.of_int expected_n
        ->
          let n_int = Int64.to_int n in
          let literal_ty = TyConstInt n_int in
          Ok (literal_ty, with_inferred_type expr literal_ty)
      | LitInt n, Some (TyConstInt expected_n) ->
          error loc
            (Printf.sprintf "Literal %Ld does not match expected dimension #%d"
               n expected_n)
      | LitInt n, Some (TyVar name) when Types.Dim.is_var_name name ->
          if n > 0L then
            let n_int = Int64.to_int n in
            let literal_ty = TyConstInt n_int in
            Ok (literal_ty, with_inferred_type expr literal_ty)
          else
            error loc
              (Printf.sprintf
                 "Literal %Ld is not a valid dimension (dimensions must be >= \
                  1)"
                 n)
      | LitInt n, Some (TyMeta id)
        when Types.Dim.is_var_name (Types.meta_origin_name id) ->
          if n > 0L then
            let n_int = Int64.to_int n in
            let literal_ty = TyConstInt n_int in
            Ok (literal_ty, with_inferred_type expr literal_ty)
          else
            error loc
              (Printf.sprintf
                 "Literal %Ld is not a valid dimension (dimensions must be >= \
                  1)"
                 n)
      | LitInt _, Some (TyMeta id)
        when not (Types.Dim.is_var_name (Types.meta_origin_name id)) ->
          if has_expected_argument_slot ctx then expected_slot_result ty
          else Ok (ty_int, with_inferred_type expr ty_int)
      | LitFloat _, Some (TyNamed ("Float32", []) as expected_ty) ->
          if Option.is_some (expected_value_slot_opt ctx ty) then
            expected_slot_result ty
          else Ok (expected_ty, with_inferred_type expr expected_ty)
      | LitFloat _, Some (TyNamed ("Float16", []) as expected_ty) ->
          if Option.is_some (expected_value_slot_opt ctx ty) then
            expected_slot_result ty
          else Ok (expected_ty, with_inferred_type expr expected_ty)
      | _ ->
          Ok
            ( ty,
              annotate_expected_value_slot ctx (with_inferred_type expr ty) ty
            ))
  (* Binary operations *)
  | EBinary (op, left, right) -> (
      let* left_ty, left' = infer_unconstrained_value_expr ctx left in
      let* right_ty, right' = infer_unconstrained_value_expr ctx right in
      match check_binop ctx op left_ty right_ty loc with
      | Ok result_ty ->
          let left'' =
            with_value_slot_if_widening left'
              (Type_widening.numeric_operand_slot op left_ty)
          in
          let right'' =
            with_value_slot_if_widening right'
              (Type_widening.numeric_operand_slot op right_ty)
          in
          let result_ty =
            match op with
            | Mod ->
                let lhs_non_negative =
                  match left_ty with
                  | TyRange _ -> true
                  | TyConstInt n -> n >= 0
                  | _ -> (
                      match left'.expr_desc with
                      | ELiteral (LitInt n) -> n >= 0L
                      | _ -> false)
                in
                if lhs_non_negative then
                  let mod_bound =
                    match right_ty with
                    | TyConstInt n when n > 0 -> Some n
                    | _ -> (
                        match right'.expr_desc with
                        | ELiteral (LitInt n) when n > 0L ->
                            Some (Int64.to_int n)
                        | _ -> None)
                  in
                  match mod_bound with
                  | Some n -> TyRange (TyConstInt n)
                  | None -> result_ty
                else result_ty
            | _ -> result_ty
          in
          Ok
            ( result_ty,
              with_inferred_type
                { expr with expr_desc = EBinary (op, left'', right'') }
                result_ty )
      | Error e -> Error e)
  (* Unary operations *)
  | EUnary (Neg, { expr_desc = ELiteral (LitInt n); _ }) -> (
      let neg_n = Int64.neg n in
      let infer_default () =
        Ok
          ( ty_int,
            with_inferred_type
              { expr with expr_desc = ELiteral (LitInt neg_n) }
              ty_int )
      in
      match expected_sized_integer_type_opt ctx with
      | None -> infer_default ()
      | Some (type_name, expected_ty) ->
          (* Contextual narrowing: -N with sized int expected → fold to negative literal *)
          let lo, hi = Types.int_type_range type_name in
          if neg_n >= lo && neg_n <= hi then
            Ok
              ( expected_ty,
                with_inferred_type
                  { expr with expr_desc = ELiteral (LitInt neg_n) }
                  expected_ty )
          else
            error loc
              (Printf.sprintf "Literal %Ld exceeds %s range [%Ld, %Ld]" neg_n
                 type_name lo hi))
  | EUnary (Neg, ({ expr_desc = ELiteral (LitFloat _); _ } as operand)) -> (
      match expected_sized_float_type_opt ctx with
      | Some expected_ty ->
          (* Contextual narrowing: -F with Float32/Float16 expected *)
          let* _operand_ty, operand' =
            infer_unconstrained_value_expr ctx expr
          in
          ignore _operand_ty;
          Ok (expected_ty, with_inferred_type operand' expected_ty)
      | None -> (
          let* operand_ty, operand' =
            infer_unconstrained_value_expr ctx operand
          in
          match check_unop ctx.env Neg operand_ty loc with
          | Ok result_ty ->
              Ok
                ( result_ty,
                  with_inferred_type
                    { expr with expr_desc = EUnary (Neg, operand') }
                    result_ty )
          | Error e -> Error e))
  | EUnary (op, operand) -> (
      let* operand_ty, operand' = infer_unconstrained_value_expr ctx operand in
      match check_unop ctx.env op operand_ty loc with
      | Ok result_ty ->
          Ok
            ( result_ty,
              with_inferred_type
                { expr with expr_desc = EUnary (op, operand') }
                result_ty )
      | Error e -> Error e)
  (* Logical operations *)
  | ELogical (op, left, right) -> (
      let* left_ty, left' = infer_unconstrained_value_expr ctx left in
      (* Progressive narrowing for 'and': constraints from left apply when inferring right.
         This allows patterns like: if i >= 0 and i < N and v[i] > 0.5
         where v[i] is safe because the bounds check on the left has already proven i in range.
         Short-circuit 'and' guarantees right is only evaluated when left is true. *)
      let right_ctx =
        match op with
        | And -> (
            let narrowings = extract_range_narrowings left' in
            match narrowings with
            | [] -> without_expected ctx
            | _ ->
                let env' = apply_branch_range_narrowings ctx.env narrowings in
                { (without_expected ctx) with env = env' })
        | Or -> without_expected ctx
      in
      let* right_ty, right' = infer_expr right_ctx right in
      match check_logop op left_ty right_ty loc with
      | Ok result_ty ->
          Ok
            ( result_ty,
              with_inferred_type
                { expr with expr_desc = ELogical (op, left', right') }
                result_ty )
      | Error e -> Error e)
  (* Type ascription *)
  | EAscription (inner, parsed_source_ty) ->
      let resolved_ascription = resolve_value_ascription ctx parsed_source_ty in
      let source_ty = Type_resolution.source resolved_ascription in
      let ascribed_ty = Type_resolution.canonical resolved_ascription in
      let* () = validate_value_ascription_type loc ascribed_ty in
      let* inferred_ty, inner' =
        infer_annotated_value_expr ctx ascribed_ty inner
      in
      let value_ty =
        match inner'.expr_type_info with
        | Some info -> info.value_ty
        | None -> inferred_ty
      in
      if ctx_types_compatible ctx ascribed_ty value_ty then
        let ascribed_expr =
          with_inferred_type
            { expr with expr_desc = EAscription (inner', source_ty) }
            ascribed_ty
        in
        Ok
          ( ascribed_ty,
            with_value_slot ~source_ty ~origin:(ExplicitAnnotation source_ty)
              ascribed_expr
              (Type_widening.keep_slot ascribed_ty) )
      else
        error loc
          (Printf.sprintf
             "Type mismatch in expression ascription\n\
             \    expected: %s\n\
             \       found: %s"
             (type_to_string ascribed_ty)
             (type_to_string value_ty))
  (* Function calls *)
  | ECall (callee, args) -> infer_call ctx expr callee args loc
  (* If expressions *)
  | EIf (cond, then_branch, else_branch) ->
      infer_if ctx expr cond then_branch else_branch loc
  (* Match expressions *)
  | EMatch (scrutinee, cases) -> infer_match ctx expr scrutinee cases loc
  (* Block expressions *)
  | EBlock exprs -> infer_block ctx expr exprs loc
  (* Tuple expressions *)
  | ETuple elems ->
      (* Extract expected element types from tuple type if available *)
      let expected_elems =
        match expected_type_opt ctx with
        | Some (TyTuple expected) when List.length expected = List.length elems
          ->
            List.map (fun t -> Some t) expected
        | Some (TyNamed ("Tuple", expected))
          when List.length expected = List.length elems ->
            List.map (fun t -> Some t) expected
        | _ -> List.map (fun _ -> None) elems
      in
      (* Infer each element with its expected type *)
      let type_params = Env.get_type_params ctx.env in
      let rec infer_elems es exps acc_tys acc_es =
        match (es, exps) with
        | [], [] -> Ok (List.rev acc_tys, List.rev acc_es)
        | e :: rest_e, exp :: rest_exp ->
            let* e_ty, e' =
              match exp with
              | Some ty -> infer_expected_value_expr ctx ty e
              | None -> infer_unconstrained_value_expr ctx e
            in
            let* () =
              reject_void_value ~context:"tuple element" e.expr_loc e_ty
            in
            let* () =
              match exp with
              | Some expected_ty
                when not (types_compatible ~type_params expected_ty e_ty) ->
                  error e.expr_loc
                    (Printf.sprintf
                       "Tuple element type mismatch: expected %s, got %s"
                       (type_to_string expected_ty)
                       (type_to_string e_ty))
              | _ -> Ok ()
            in
            infer_elems rest_e rest_exp (e_ty :: acc_tys) (e' :: acc_es)
        | _ -> error loc "Internal error: tuple element count mismatch"
      in
      let* elem_tys, elem_exprs = infer_elems elems expected_elems [] [] in
      let ty = TyTuple elem_tys in
      Ok (ty, with_inferred_type { expr with expr_desc = ETuple elem_exprs } ty)
  (* Vector literals *)
  | EVector elements -> infer_array ctx expr elements loc
  (* List literals *)
  | EList elements -> infer_list ctx expr elements loc
  (* Record literals *)
  | ERecord fields -> infer_record ctx expr fields loc
  (* Record update *)
  | ERecordUpdate (base, fields) -> infer_record_update ctx expr base fields loc
  (* Field access *)
  | EFieldAccess (obj, field) -> infer_field_access ctx expr obj field loc
  (* Lambda expressions *)
  | ELambda func -> infer_lambda ctx expr func loc
  (* Pass (unit) or parser-level Builtin placeholder. Whole-function builtin
     bodies are represented as [FuncBuiltinBody] before type checking; this
     branch only handles any defensive expression-level placeholder that remains. *)
  | EVoid | EBuiltin _ -> Ok (ty_void, with_inferred_type expr ty_void)
  | ELoopView _ ->
      error loc
        "Internal error: loop-view node reached type inference before for-loop \
         classification"
  (* While loop - returns Void *)
  | EWhile (cond, body) ->
      let* cond_ty, cond' =
        infer_expected_value_expr ctx (TyNamed ("Bool", [])) cond
      in
      if not (ctx_types_compatible ctx (TyNamed ("Bool", [])) cond_ty) then
        error cond'.expr_loc
          (Printf.sprintf "While condition must be Bool, got %s"
             (type_to_string cond_ty))
      else
        let loop_ctx = { (without_expected ctx) with in_loop = true } in
        let* _body_ty, body' = infer_statement_expr loop_ctx body in
        let new_expr =
          with_inferred_type
            { expr with expr_desc = EWhile (cond', body') }
            ty_void
        in
        Ok (ty_void, new_expr)
  (* For loop - returns Void *)
  | EFor (var, iter, body) ->
      let* iter_ty, iter' = infer_unconstrained_value_expr ctx iter in
      (* Detect indices(coll) — first-dimension index loop. *)
      let is_indices, indices_coll_arg, indices_coll_ty =
        match iter'.expr_desc with
        | ECall ({ expr_desc = EIdent name; _ }, [ coll_arg ])
          when is_tensor_loop_call ctx LoopProducerIndices name [ coll_arg ] ->
            (true, Some coll_arg, expr_proof_semantic_type_opt coll_arg)
        | _ -> (false, None, None)
      in
      (* Detect enumerate(coll) — special loop combinator for indexed iteration.
         for (i, val) in enumerate(v): yields (..#N, T) pairs where i is proven
         in-bounds for v. We intercept before the general iterable check because
         enumerate's return type (List[(Int,T)]) is nominal — the real semantics
         are: iterate over the collection with (index, element) pairs. *)
      let is_enumerate, enum_coll_arg, enum_coll_ty =
        match iter'.expr_desc with
        | ECall ({ expr_desc = EIdent name; _ }, [ coll_arg ])
          when is_tensor_loop_call ctx LoopProducerEnumerate name [ coll_arg ]
          ->
            (true, Some coll_arg, expr_proof_semantic_type_opt coll_arg)
        | _ -> (false, None, None)
      in
      (* Detect enumerate2(m) — 2D iteration yielding (i, j, val) triples *)
      let is_enumerate2, enum2_coll_arg, enum2_coll_ty =
        match iter'.expr_desc with
        | ECall ({ expr_desc = EIdent name; _ }, [ coll_arg ])
          when is_tensor_loop_call ctx LoopProducerEnumerate2 name [ coll_arg ]
          ->
            (true, Some coll_arg, expr_proof_semantic_type_opt coll_arg)
        | _ -> (false, None, None)
      in
      (* Detect zip(v1, v2) — parallel iteration yielding (elem1, elem2) pairs *)
      let is_zip, zip_colls =
        match iter'.expr_desc with
        | ECall ({ expr_desc = EIdent "zip"; _ }, [ a; b ]) ->
            (true, Some (a, b))
        | _ -> (false, None)
      in
      (* Detect windows(coll, K) — special loop combinator for sliding window iteration.
         for w in windows(v, 3): yields T[#3] windows of size 3.
         Each w has type T[#K], and w[j] is proven safe for 0 <= j < K.
         Codegen emits zero-cost pointer arithmetic into the original tensor. *)
      let is_windows, win_coll_arg, win_coll_ty, win_size =
        match iter'.expr_desc with
        | ECall ({ expr_desc = EIdent name; _ }, [ coll_arg; size_arg ])
          when is_tensor_loop_call ctx LoopProducerWindows name
                 [ coll_arg; size_arg ] ->
            let size =
              match size_arg.expr_desc with
              | ELiteral (LitInt n) when n > 0L -> Some (Int64.to_int n)
              | _ -> None
            in
            (true, Some coll_arg, expr_proof_semantic_type_opt coll_arg, size)
        | _ -> (false, None, None, None)
      in
      let* () =
        if is_windows && win_size = None then
          error iter'.expr_loc
            "windows requires a positive integer literal as the window size. \
             Use: for w in windows(v, 3): w[0] + w[1] + w[2]"
        else Ok ()
      in
      (* Block windows on 2D+ tensors — semantics unclear *)
      let* () =
        if is_windows then
          match win_coll_ty with
          | Some ty -> (
              match Types.array_parts ty with
              | Some (_, _ :: _ :: _) ->
                  error iter'.expr_loc
                    "Cannot use windows on a multi-dimensional array. Use for \
                     i in 0..length(array): to create windows manually"
              | _ -> Ok ())
          | _ -> Ok ()
        else Ok ()
      in
      let* elem_ty =
        if is_indices then
          let* coll_ty =
            match indices_coll_ty with
            | Some ty -> Ok ty
            | None ->
                error iter'.expr_loc
                  "Cannot determine type of collection passed to indices"
          in
          match tensor_first_index_type coll_ty with
          | Some idx_ty -> Ok idx_ty
          | None ->
              error iter'.expr_loc
                (Printf.sprintf "indices requires an array, got %s"
                   (type_to_string coll_ty))
        else if is_enumerate then
          (* enumerate(coll) — element type is (index_type, elem_type) *)
          let* coll_ty =
            match enum_coll_ty with
            | Some ty -> Ok ty
            | None ->
                error iter'.expr_loc
                  "Cannot determine type of collection passed to enumerate"
          in
          let* idx_ty, inner_elem_ty =
            match Types.array_parts coll_ty with
            | Some (elem_ty, dims) ->
                (* Extract first dimension for range type *)
                let idx_ty =
                  match tensor_first_index_type coll_ty with
                  | Some idx_ty -> idx_ty
                  | None -> ty_int
                in
                (* Dimension peeling: 2D+ yields sub-tensor, 1D yields scalar *)
                let peeled_ty =
                  match dims with
                  | [ _single ] -> elem_ty
                  | _ :: rest -> Types.ty_array elem_ty rest
                  | [] -> elem_ty
                in
                Ok (idx_ty, peeled_ty)
            | None ->
                error iter'.expr_loc
                  (Printf.sprintf
                     "enumerate requires an array, got %s. For List \
                      enumeration, use: import: list: enumerate"
                     (type_to_string coll_ty))
          in
          Ok (TyTuple [ idx_ty; inner_elem_ty ])
        else if is_enumerate2 then
          (* enumerate2(m) — element type is (row_idx, col_idx, scalar_element) *)
          let* coll_ty =
            match enum2_coll_ty with
            | Some ty -> Ok ty
            | None ->
                error iter'.expr_loc
                  "Cannot determine type of matrix passed to enumerate2"
          in
          match Types.array_parts coll_ty with
          | Some (elem_ty, dim1 :: dim2 :: _) ->
              let row_idx_ty =
                match dim1 with
                | TyConstInt n when n > 0 -> TyRange (TyConstInt n)
                | TyVar name when Types.Dim.is_var_name name ->
                    TyRange (TyVar name)
                | _ -> ty_int
              in
              let col_idx_ty =
                match dim2 with
                | TyConstInt n when n > 0 -> TyRange (TyConstInt n)
                | TyVar name when Types.Dim.is_var_name name ->
                    TyRange (TyVar name)
                | _ -> ty_int
              in
              Ok (TyTuple [ row_idx_ty; col_idx_ty; elem_ty ])
          | Some _ ->
              error iter'.expr_loc
                "enumerate2 requires a 2D+ array. Use enumerate for 1D arrays"
          | None ->
              error iter'.expr_loc
                (Printf.sprintf "enumerate2 requires a 2D array, got %s"
                   (type_to_string coll_ty))
        else if is_zip then
          (* zip(v1, v2) — element type is (elem_type_1, elem_type_2) *)
          let* a, b =
            match zip_colls with
            | Some colls -> Ok colls
            | None -> error iter'.expr_loc "zip requires two arrays"
          in
          let get_elem_ty e =
            match expr_proof_semantic_type_opt e with
            | Some ty -> Option.map fst (Types.array_parts ty)
            | _ -> None
          in
          match (get_elem_ty a, get_elem_ty b) with
          | Some t1, Some t2 -> Ok (TyTuple [ t1; t2 ])
          | _ -> error iter'.expr_loc "zip requires two arrays"
        else if is_windows then
          (* windows(coll, K) — element type is T[#K] *)
          let* coll_ty =
            match win_coll_ty with
            | Some ty -> Ok ty
            | None ->
                error iter'.expr_loc
                  "Cannot determine type of collection passed to windows"
          in
          let* k =
            match win_size with
            | Some k -> Ok k
            | None ->
                error iter'.expr_loc
                  "windows requires a positive integer literal as the window \
                   size. Use: for w in windows(v, 3): w[0] + w[1] + w[2]"
          in
          let* inner_elem_ty =
            match Types.array_parts coll_ty with
            | Some (elem_ty, _) -> Ok elem_ty
            | None ->
                error iter'.expr_loc
                  (Printf.sprintf "windows requires a 1D array, got %s"
                     (type_to_string coll_ty))
          in
          Ok (Types.ty_array inner_elem_ty [ TyConstInt k ])
        else
          match elem_type_of_iterable iter_ty with
          | Some ty -> Ok ty
          | None ->
              error iter'.expr_loc
                (Printf.sprintf
                   "Cannot iterate over type %s. For-in loops work with List, \
                    Vector, Set, String, and Range types"
                   (type_to_string iter_ty))
      in
      (* Refine elem_ty to range type when iterating 0..N with known bound *)
      let elem_ty =
        match iter'.expr_desc with
        | ERange (start_e, end_e) ->
            let is_zero_start =
              match start_e.expr_desc with
              | ELiteral (LitInt 0L) -> true
              | _ -> false
            in
            if is_zero_start then
              let bound =
                match end_e.expr_desc with
                | ELiteral (LitInt n) when n > 0L -> Some (Int64.to_int n)
                | ECall
                    ( { expr_desc = EIdent ("length" | "vector_length"); _ },
                      [ arg ] ) -> (
                    let arg_ty =
                      match arg.expr_desc with
                      | EIdent v -> get_var_type ctx.env v
                      | ESubscript _ -> resolve_subscript_chain_type ctx.env arg
                      | ECall
                          ( {
                              expr_desc = EIdent ("checked_get" | "tensor_peel");
                              _;
                            },
                            _ ) -> (
                          match expr_proof_semantic_type_opt arg with
                          | Some ty -> Some ty
                          | None -> resolve_subscript_chain_type ctx.env arg)
                      | _ -> None
                    in
                    match arg_ty with
                    | Some ty -> (
                        match Types.array_parts ty with
                        | Some (_, TyConstInt n :: _) when n > 0 -> Some n
                        | _ -> None)
                    | _ -> None)
                | _ -> None
              in
              (* Also check if end_e inferred to a dim type (from length() returning #N) *)
              let dim_bound =
                match bound with
                | Some n -> Some (TyConstInt n)
                | None -> (
                    match expr_proof_semantic_type_opt end_e with
                    | Some (TyConstInt n) when n > 0 -> Some (TyConstInt n)
                    | Some (TyVar name) when Types.Dim.is_var_name name ->
                        Some (TyVar name)
                    | _ -> None)
              in
              match dim_bound with Some dim -> TyRange dim | None -> elem_ty
            else elem_ty
        | _ -> elem_ty
      in
      (* Reject same-scope re-declaration of loop variable *)
      let* () = check_no_redeclaration ctx.env var iter'.expr_loc in
      (* Add loop variable to scope for body *)
      let body_env = add_var ctx.env var elem_ty ~origin:ForLoopVar () in
      (* Detect pattern: for i in 0..length(v) -> prove i is in bounds for v *)
      let proof_env =
        match iter'.expr_desc with
        | ERange (start_e, end_e) -> (
            let is_zero_start =
              match start_e.expr_desc with
              | ELiteral (LitInt 0L) -> true
              | _ -> false
            in
            let range_coll =
              match end_e.expr_desc with
              | ECall
                  ( { expr_desc = EIdent ("length" | "vector_length"); _ },
                    [ arg ] ) -> (
                  match arg.expr_desc with
                  | EIdent coll_var -> (
                      (* length(v) — proves loop var in-bounds for collection *)
                      match get_var_type ctx.env coll_var with
                      | Some ty when Types.is_array_type ty ->
                          collection_var_opt coll_var
                      | _ -> None)
                  | ESubscript _
                  | ECall
                      ( { expr_desc = EIdent ("checked_get" | "tensor_peel"); _ },
                        _ ) -> (
                      (* Extended: length(subscript_chain) where chain is proven *)
                      match expr_to_proven_collection ctx.env arg with
                      | Some pc -> (
                          let chain_ty =
                            match expr_proof_semantic_type_opt arg with
                            | Some ty -> Some ty
                            | None -> resolve_subscript_chain_type ctx.env arg
                          in
                          match chain_ty with
                          | Some ty when Types.is_array_type ty -> Some pc
                          | _ -> None)
                      | None -> None)
                  | _ -> None)
              | ELiteral (LitInt n) when n > 0L ->
                  Refinement.collection_dim (Int64.to_int n)
              | _ -> None
            in
            (* Remove any existing proof for this var name (handles shadowing) *)
            let base_proofs = proof_env_without_subscript ctx.proof_env var in
            match (is_zero_start, range_coll) with
            | true, Some coll ->
                proof_env_add_subscript ~source:Refinement.ProofSourceLoopRange
                  base_proofs var coll
            | _ -> base_proofs)
        | _ -> ctx.proof_env
      in
      (* indices: prove the loop variable is in bounds for the collection. *)
      let proof_env =
        if is_indices then
          match indices_coll_arg with
          | Some coll_arg -> (
              let index_coll =
                match coll_arg.expr_desc with
                | EIdent coll_var -> collection_var_opt coll_var
                | _ -> None
              in
              let base_proofs = proof_env_without_subscript proof_env var in
              match index_coll with
              | Some coll ->
                  proof_env_add_subscript
                    ~source:Refinement.ProofSourceLoopIndices base_proofs var
                    coll
              | None -> (
                  match indices_coll_ty with
                  | Some ty -> (
                      match Types.array_parts ty with
                      | Some (_, TyConstInt n :: _) when n > 0 -> (
                          match Refinement.collection_dim n with
                          | Some coll ->
                              proof_env_add_subscript
                                ~source:Refinement.ProofSourceLoopIndices
                                base_proofs var coll
                          | None -> base_proofs)
                      | _ -> base_proofs)
                  | _ -> base_proofs))
          | None -> proof_env
        else proof_env
      in
      (* Extract destructured index variable name from for-tuple body. *)
      let enum_idx_name =
        if is_enumerate then
          match body.expr_desc with
          | EBlock ({ expr_desc = ETupleDestruct (first :: _, _); _ } :: _) ->
              Some first
          | _ -> None
        else None
      in
      (* enumerate: prove the index variable is in bounds for the collection *)
      let proof_env =
        if is_enumerate then
          match enum_coll_arg with
          | Some coll_arg -> (
              match enum_idx_name with
              | Some idx -> (
                  let enum_coll =
                    match coll_arg.expr_desc with
                    | EIdent coll_var -> collection_var_opt coll_var
                    | _ -> None
                  in
                  let base_proofs = proof_env_without_subscript proof_env idx in
                  match enum_coll with
                  | Some coll ->
                      proof_env_add_subscript
                        ~source:Refinement.ProofSourceLoopEnumerate base_proofs
                        idx coll
                  | None -> (
                      (* Try to extract a constant dim bound from the collection type *)
                      match enum_coll_ty with
                      | Some ty -> (
                          match Types.array_parts ty with
                          | Some (_, TyConstInt n :: _) when n > 0 -> (
                              match Refinement.collection_dim n with
                              | Some coll ->
                                  proof_env_add_subscript
                                    ~source:Refinement.ProofSourceLoopEnumerate
                                    base_proofs idx coll
                              | None -> base_proofs)
                          | _ -> base_proofs)
                      | _ -> base_proofs))
              | None -> proof_env)
          | None -> proof_env
        else proof_env
      in
      (* Track range for offset/bound proving. Unified (Phase 5.3):
         one proof environment handles BOTH literal-upper ranges
         ([for i in 0..10]) and length-bounded ranges
         ([for i in 0..length(v)]). The [range_upper] sum tags which. *)
      let proof_env =
        match iter'.expr_desc with
        | ERange (start_e, end_e) -> (
            let rec lower_bound_opt e =
              match e.expr_desc with
              | ELiteral (LitInt n) -> Some (Int64.to_int n)
              | EIdent name -> binding_range_start_opt ctx.env name
              | EBinary (Add, left, right) -> (
                  match (lower_bound_opt left, lower_bound_opt right) with
                  | Some l, Some r -> Some (l + r)
                  | _ -> None)
              | EBinary (Sub, left, { expr_desc = ELiteral (LitInt k); _ }) -> (
                  match lower_bound_opt left with
                  | Some l when l - Int64.to_int k >= 0 ->
                      Some (l - Int64.to_int k)
                  | _ -> None)
              | _ -> None
            in
            let start_val = lower_bound_opt start_e in
            (* Derive the upper bound's shape. Literal-upper forms
               include [N], [N - k], [length(v)] + compile-time dim,
               and [length(v) - k] + compile-time dim. Symbolic forms
               (length(coll), length(coll) - k, length(coll) / k) keep
               the collection reference for cross-proof. *)
            let length_dim_opt arg =
              match expr_proof_semantic_type_opt arg with
              | Some ty -> (
                  match Types.array_parts ty with
                  | Some (_, TyConstInt n :: _) -> Some n
                  | _ -> None)
              | _ -> None
            in
            let length_coll_opt arg =
              match arg.expr_desc with
              | EIdent coll_var -> Some coll_var
              | _ -> None
            in
            let upper =
              match end_e.expr_desc with
              | ELiteral (LitInt n) ->
                  Refinement.range_upper_lit (Int64.to_int n)
              | ECall
                  ( { expr_desc = EIdent ("length" | "vector_length"); _ },
                    [ arg ] ) -> (
                  match length_dim_opt arg with
                  | Some n ->
                      Refinement.range_upper_lit n
                      (* compile-time dim: treat as literal *)
                  | None -> (
                      match length_coll_opt arg with
                      | Some cn -> range_upper_length_minus_opt cn ~end_offset:0
                      | None -> None))
              | EBinary (Sub, lhs, { expr_desc = ELiteral (LitInt k); _ }) -> (
                  let k_int = Int64.to_int k in
                  match lhs.expr_desc with
                  | ELiteral (LitInt n) ->
                      Refinement.range_upper_lit (Int64.to_int n - k_int)
                  | ECall
                      ( { expr_desc = EIdent ("length" | "vector_length"); _ },
                        [ arg ] ) -> (
                      match length_dim_opt arg with
                      | Some n -> Refinement.range_upper_lit (n - k_int)
                      | None -> (
                          match length_coll_opt arg with
                          | Some cn when k > 0L ->
                              range_upper_length_minus_opt cn ~end_offset:k_int
                          | _ -> None))
                  | _ -> None)
              | EBinary
                  ( Div,
                    {
                      expr_desc =
                        ECall
                          ( {
                              expr_desc = EIdent ("length" | "vector_length");
                              _;
                            },
                            [ arg ] );
                      _;
                    },
                    { expr_desc = ELiteral (LitInt k); _ } )
                when k > 0L -> (
                  match length_coll_opt arg with
                  | Some cn -> range_upper_at_most_length_opt cn
                  | None -> None)
              | _ -> None
            in
            let base_proofs = proof_env_without_range proof_env var in
            match (start_val, upper) with
            | Some s, Some up ->
                proof_env_add_range_bounds
                  ~source:Refinement.ProofSourceLoopRange base_proofs var
                  ~range_start:s ~range_upper:up
            | _ -> base_proofs)
        | _ -> proof_env
      in
      (* indices: add numeric range for the loop variable when the first
         dimension is concrete. *)
      let proof_env =
        if is_indices then
          let dim_val =
            match indices_coll_ty with
            | Some ty -> (
                match Types.array_parts ty with
                | Some (_, TyConstInt n :: _) when n > 0 -> Some n
                | _ -> None)
            | None -> None
          in
          let base_proofs = proof_env_without_range proof_env var in
          match dim_val with
          | Some n -> (
              match Refinement.range_upper_lit n with
              | Some range_upper ->
                  proof_env_add_range_bounds
                    ~source:Refinement.ProofSourceLoopIndices base_proofs var
                    ~range_start:0 ~range_upper
              | None -> base_proofs)
          | None -> base_proofs
        else proof_env
      in
      (* enumerate: add numeric range for the index variable *)
      let proof_env =
        if is_enumerate then
          match enum_idx_name with
          | Some idx -> (
              let dim_val =
                match enum_coll_ty with
                | Some ty -> (
                    match Types.array_parts ty with
                    | Some (_, TyConstInt n :: _) when n > 0 -> Some n
                    | _ -> None)
                | None -> None
              in
              let base_proofs = proof_env_without_range proof_env idx in
              match dim_val with
              | Some n -> (
                  match Refinement.range_upper_lit n with
                  | Some range_upper ->
                      proof_env_add_range_bounds
                        ~source:Refinement.ProofSourceLoopEnumerate base_proofs
                        idx ~range_start:0 ~range_upper
                  | None -> base_proofs)
              | None -> base_proofs)
          | None -> proof_env
        else proof_env
      in
      let body_env =
        env_with_binding_refinement_from_proof body_env proof_env var
      in
      let body_env =
        match enum_idx_name with
        | Some idx ->
            env_with_binding_refinement_from_proof body_env proof_env idx
        | None -> body_env
      in
      let body_ctx =
        {
          (without_expected ctx) with
          env = body_env;
          in_loop = true;
          proof_env;
        }
      in
      let* _body_ty, body' = infer_statement_expr body_ctx body in
      let iter_for_lower =
        let mk_loop_view kind source ?size_arg elem_type =
          with_inferred_type
            {
              iter' with
              expr_desc =
                ELoopView
                  {
                    loop_view_kind = kind;
                    loop_view_source = source;
                    loop_view_size_arg = size_arg;
                    loop_view_elem_type = elem_type;
                  };
            }
            (TyNamed ("Loop", [ elem_type ]))
        in
        if is_indices then
          match indices_coll_arg with
          | Some source -> mk_loop_view LoopIndices source elem_ty
          | None -> iter'
        else if is_enumerate then
          match enum_coll_arg with
          | Some source -> mk_loop_view LoopEnumerate source elem_ty
          | None -> iter'
        else if is_enumerate2 then
          match enum2_coll_arg with
          | Some source -> mk_loop_view LoopEnumerate2 source elem_ty
          | None -> iter'
        else if is_windows then
          match (win_coll_arg, win_size) with
          | Some source, Some size ->
              let size_arg =
                match iter'.expr_desc with
                | ECall (_, [ _; size_arg ]) -> Some size_arg
                | _ -> None
              in
              mk_loop_view (LoopWindows size) source ?size_arg elem_ty
          | _ -> iter'
        else iter'
      in
      let new_expr =
        with_inferred_type
          { expr with expr_desc = EFor (var, iter_for_lower, body') }
          ty_void
      in
      Ok (ty_void, new_expr)
  | EForTuple (names, iter, body) ->
      let* iter_ty, iter' = infer_unconstrained_value_expr ctx iter in
      let is_enumerate, enum_coll_arg, enum_coll_ty =
        match iter'.expr_desc with
        | ECall ({ expr_desc = EIdent "enumerate"; _ }, [ coll_arg ])
          when is_tensor_loop_call ctx LoopProducerEnumerate "enumerate"
                 [ coll_arg ] ->
            (true, Some coll_arg, expr_proof_semantic_type_opt coll_arg)
        | _ -> (false, None, None)
      in
      let is_enumerate2, enum2_coll_arg, enum2_coll_ty =
        match iter'.expr_desc with
        | ECall ({ expr_desc = EIdent "enumerate2"; _ }, [ coll_arg ])
          when is_tensor_loop_call ctx LoopProducerEnumerate2 "enumerate2"
                 [ coll_arg ] ->
            (true, Some coll_arg, expr_proof_semantic_type_opt coll_arg)
        | _ -> (false, None, None)
      in
      let is_zip, zip_colls =
        match iter'.expr_desc with
        | ECall ({ expr_desc = EIdent "zip"; _ }, [ a; b ]) ->
            (true, Some (a, b))
        | _ -> (false, None)
      in
      let* tuple_ty =
        if is_enumerate then
          let* coll_ty =
            match enum_coll_ty with
            | Some ty -> Ok ty
            | None ->
                error iter'.expr_loc
                  "Cannot determine type of collection passed to enumerate"
          in
          let* idx_ty, inner_elem_ty =
            match Types.array_parts coll_ty with
            | Some (elem_ty, dims) ->
                let dim =
                  match dims with
                  | TyConstInt n :: _ when n > 0 -> Some (TyConstInt n)
                  | TyVar name :: _ when Types.Dim.is_var_name name ->
                      Some (TyVar name)
                  | _ -> None
                in
                let idx_ty =
                  match dim with Some d -> TyRange d | None -> ty_int
                in
                let peeled_ty =
                  match dims with
                  | [ _single ] -> elem_ty
                  | _ :: rest -> Types.ty_array elem_ty rest
                  | [] -> elem_ty
                in
                Ok (idx_ty, peeled_ty)
            | None ->
                error iter'.expr_loc
                  (Printf.sprintf
                     "enumerate requires an array, got %s. For List \
                      enumeration, use: import: list: enumerate"
                     (type_to_string coll_ty))
          in
          Ok (TyTuple [ idx_ty; inner_elem_ty ])
        else if is_enumerate2 then
          let* coll_ty =
            match enum2_coll_ty with
            | Some ty -> Ok ty
            | None ->
                error iter'.expr_loc
                  "Cannot determine type of matrix passed to enumerate2"
          in
          match Types.array_parts coll_ty with
          | Some (elem_ty, dim1 :: dim2 :: _) ->
              let row_idx_ty =
                match dim1 with
                | TyConstInt n when n > 0 -> TyRange (TyConstInt n)
                | TyVar name when Types.Dim.is_var_name name ->
                    TyRange (TyVar name)
                | _ -> ty_int
              in
              let col_idx_ty =
                match dim2 with
                | TyConstInt n when n > 0 -> TyRange (TyConstInt n)
                | TyVar name when Types.Dim.is_var_name name ->
                    TyRange (TyVar name)
                | _ -> ty_int
              in
              Ok (TyTuple [ row_idx_ty; col_idx_ty; elem_ty ])
          | Some _ ->
              error iter'.expr_loc
                "enumerate2 requires a 2D+ array. Use enumerate for 1D arrays"
          | None ->
              error iter'.expr_loc
                (Printf.sprintf "enumerate2 requires a 2D array, got %s"
                   (type_to_string coll_ty))
        else if is_zip then
          let* a, b =
            match zip_colls with
            | Some colls -> Ok colls
            | None -> error iter'.expr_loc "zip requires two arrays"
          in
          let get_elem_ty e =
            match expr_proof_semantic_type_opt e with
            | Some ty -> Option.map fst (Types.array_parts ty)
            | _ -> None
          in
          match (get_elem_ty a, get_elem_ty b) with
          | Some t1, Some t2 -> Ok (TyTuple [ t1; t2 ])
          | _ -> error iter'.expr_loc "zip requires two arrays"
        else
          match iter_ty with
          | TyNamed ("Dict", [ key_ty; val_ty ]) ->
              Ok (TyTuple [ key_ty; val_ty ])
          | _ -> (
              match elem_type_of_iterable iter_ty with
              | Some (TyTuple _ as tuple_ty) -> Ok tuple_ty
              | Some elem_ty ->
                  error iter'.expr_loc
                    (Printf.sprintf
                       "Tuple for-loop requires iterable elements to be \
                        tuples, got %s"
                       (type_to_string elem_ty))
              | None ->
                  error iter'.expr_loc
                    (Printf.sprintf
                       "Cannot iterate over type %s. Tuple for-in loops work \
                        with Dict and iterables of tuples"
                       (type_to_string iter_ty)))
      in
      let* elem_tys =
        match tuple_ty with
        | TyTuple elem_tys when List.length elem_tys = List.length names ->
            Ok elem_tys
        | TyTuple elem_tys ->
            error iter'.expr_loc
              (Printf.sprintf
                 "Tuple for-loop arity mismatch: expected %d binders, got %d \
                  tuple fields"
                 (List.length names) (List.length elem_tys))
        | _ ->
            error iter'.expr_loc
              (Printf.sprintf "Tuple for-loop requires tuple elements, got %s"
                 (type_to_string tuple_ty))
      in
      let* () =
        List.fold_left
          (fun acc name ->
            let* () = acc in
            if name <> "_" then
              check_no_redeclaration ctx.env name iter'.expr_loc
            else Ok ())
          (Ok ()) names
      in
      let body_env =
        List.fold_left2
          (fun env name ty ->
            if name = "_" then env
            else add_var env name ty ~origin:ForLoopVar ())
          ctx.env names elem_tys
      in
      let enum_idx_name =
        if is_enumerate then
          match names with idx :: _ when idx <> "_" -> Some idx | _ -> None
        else None
      in
      let proof_env =
        if is_enumerate then
          match (enum_coll_arg, enum_idx_name) with
          | Some coll_arg, Some idx -> (
              let enum_coll =
                match coll_arg.expr_desc with
                | EIdent coll_var -> collection_var_opt coll_var
                | _ -> None
              in
              let base_proofs = proof_env_without_subscript ctx.proof_env idx in
              match enum_coll with
              | Some coll ->
                  proof_env_add_subscript
                    ~source:Refinement.ProofSourceLoopEnumerate base_proofs idx
                    coll
              | None -> (
                  match enum_coll_ty with
                  | Some ty -> (
                      match Types.array_parts ty with
                      | Some (_, TyConstInt n :: _) when n > 0 -> (
                          match Refinement.collection_dim n with
                          | Some coll ->
                              proof_env_add_subscript
                                ~source:Refinement.ProofSourceLoopEnumerate
                                base_proofs idx coll
                          | None -> base_proofs)
                      | _ -> base_proofs)
                  | _ -> base_proofs))
          | _ -> ctx.proof_env
        else ctx.proof_env
      in
      let proof_env =
        if is_enumerate then
          match enum_idx_name with
          | Some idx -> (
              let dim_val =
                match enum_coll_ty with
                | Some ty -> (
                    match Types.array_parts ty with
                    | Some (_, TyConstInt n :: _) when n > 0 -> Some n
                    | _ -> None)
                | _ -> None
              in
              let base_proofs = proof_env_without_range proof_env idx in
              match dim_val with
              | Some n -> (
                  match Refinement.range_upper_lit n with
                  | Some range_upper ->
                      proof_env_add_range_bounds
                        ~source:Refinement.ProofSourceLoopEnumerate base_proofs
                        idx ~range_start:0 ~range_upper
                  | None -> base_proofs)
              | None -> base_proofs)
          | None -> proof_env
        else proof_env
      in
      let body_env =
        match enum_idx_name with
        | Some idx ->
            env_with_binding_refinement_from_proof body_env proof_env idx
        | None -> body_env
      in
      let body_ctx =
        {
          (without_expected ctx) with
          env = body_env;
          in_loop = true;
          proof_env;
        }
      in
      let* _body_ty, body' = infer_statement_expr body_ctx body in
      let iter_for_lower =
        let mk_loop_view kind source elem_type =
          with_inferred_type
            {
              iter' with
              expr_desc =
                ELoopView
                  {
                    loop_view_kind = kind;
                    loop_view_source = source;
                    loop_view_size_arg = None;
                    loop_view_elem_type = elem_type;
                  };
            }
            (TyNamed ("Loop", [ elem_type ]))
        in
        if is_enumerate then
          match enum_coll_arg with
          | Some source -> mk_loop_view LoopEnumerate source tuple_ty
          | None -> iter'
        else if is_enumerate2 then
          match enum2_coll_arg with
          | Some source -> mk_loop_view LoopEnumerate2 source tuple_ty
          | None -> iter'
        else iter'
      in
      let new_expr =
        with_inferred_type
          { expr with expr_desc = EForTuple (names, iter_for_lower, body') }
          ty_void
      in
      Ok (ty_void, new_expr)
  (* Range expression - both operands must be Int (or dim type), returns a
     first-class half-open Range value. Loop variables may still be refined to
     TyRange below when the literal range proves a static upper bound. *)
  | ERange (start_e, end_e) ->
      let is_int_like ty =
        types_equal ty ty_int
        ||
        match ty with
        | TyConstInt _ -> true
        | TyVar name -> Types.Dim.is_var_name name
        | _ -> false
      in
      let* start_ty, start' = infer_unconstrained_value_expr ctx start_e in
      if not (is_int_like start_ty) then
        error expr.expr_loc
          (Printf.sprintf "Range start must be Int, got %s"
             (type_to_string start_ty))
      else
        let* end_ty, end' = infer_unconstrained_value_expr ctx end_e in
        if not (is_int_like end_ty) then
          error expr.expr_loc
            (Printf.sprintf "Range end must be Int, got %s"
               (type_to_string end_ty))
        else
          let new_expr =
            with_inferred_type
              { expr with expr_desc = ERange (start', end') }
              (TyNamed ("Range", []))
          in
          Ok (TyNamed ("Range", []), new_expr)
  (* Break and continue - return Void, must be inside a loop *)
  | EBreak ->
      if not ctx.in_loop then
        error expr.expr_loc "'break' can only be used inside a loop"
      else
        let new_expr = with_inferred_type expr ty_void in
        Ok (ty_void, new_expr)
  | EContinue ->
      if not ctx.in_loop then
        error expr.expr_loc "'continue' can only be used inside a loop"
      else
        let new_expr = with_inferred_type expr ty_void in
        Ok (ty_void, new_expr)
  (* Assignment - returns Void *)
  | EAssign (var, value) -> (
      let loc = expr.expr_loc in
      (* Look up the variable to check existence and mutability *)
      match Env.lookup ctx.env var with
      | None when var = "_" ->
          (* Discard pattern — evaluate but don't bind.
              Clear expected context so it doesn't leak into the value expression
              (e.g., Void from lambda return context polluting generic type params). *)
          let* _val_ty, value' = infer_statement_expr ctx value in
          let new_expr =
            with_inferred_type
              { expr with expr_desc = EAssign (var, value') }
              ty_void
          in
          Ok (ty_void, new_expr)
      | None ->
          (* Unknown assignment targets are implicit immutable declarations.
             Do not typo-check the new name here: near matches are legal local
             names, and reads/calls still report suggestions at use sites. *)
          let* val_ty, value' = infer_unconstrained_value_expr ctx value in
          let* () =
            reject_void_value
              ~context:(Printf.sprintf "Declaration of '%s'" var)
              loc val_ty
          in
          let new_expr =
            with_inferred_type
              {
                expr with
                expr_desc = EVarDecl (var, Some val_ty, value', false);
              }
              ty_void
          in
          Ok (ty_void, new_expr)
      | Some { kind = VarSymbol { mutability = Immutable; _ }; _ } ->
          (* Context-appropriate help: check if this is a function parameter
              (lookup in current scope to see if it was declared here or inherited). *)
          let help =
            if Env.is_func_param ctx.env var then
              Printf.sprintf
                "Function parameters are immutable. Copy to a local var: var \
                 %s = %s"
                var var
            else if Env.is_for_loop_var ctx.env var then
              "For loop variables are immutable"
            else
              Printf.sprintf
                "Declare with 'var' to make it mutable: var %s = ..." var
          in
          error_with ~notes:[] ~help:(Some help) loc
            (Printf.sprintf "Cannot assign to immutable variable '%s'" var)
      | Some { kind = VarSymbol { var_type; mutability = Mutable; _ }; _ } ->
          let* val_ty, value' = infer_expected_value_expr ctx var_type value in
          if ctx_types_compatible ctx var_type val_ty then
            let new_expr =
              with_inferred_type
                { expr with expr_desc = EAssign (var, value') }
                ty_void
            in
            Ok (ty_void, new_expr)
          else
            error loc
              (Printf.sprintf
                 "Cannot assign to variable '%s'\n\
                 \    expected: %s\n\
                 \       found: %s"
                 var (type_to_string var_type) (type_to_string val_ty))
      | Some { kind = FuncSymbol _; _ } ->
          error loc (Printf.sprintf "Cannot assign to function '%s'" var)
      | Some { kind = TypeSymbol _; _ } ->
          error loc (Printf.sprintf "Cannot assign to type name '%s'" var)
      | Some { kind = RecordSymbol _; _ } ->
          error loc (Printf.sprintf "Cannot assign to record type '%s'" var)
      | Some { kind = ConstructorSymbol _; _ } ->
          error loc (Printf.sprintf "Cannot assign to constructor '%s'" var)
      | Some { kind = AliasSymbol _; _ } ->
          error loc (Printf.sprintf "Cannot assign to type alias '%s'" var)
      | Some { kind = NewTypeSymbol _; _ } ->
          error loc (Printf.sprintf "Cannot assign to new type '%s'" var))
  (* Variable declaration *)
  | EVarDecl (name, ty_opt, value, is_mutable) -> (
      (* Reject same-scope re-declaration *)
      let* () = check_no_redeclaration ctx.env name loc in
      (* Resolve aliases (e.g., Vector -> Tensor) on declared type while
         retaining source spelling for typed metadata and tooling. *)
      let resolved_ty_opt =
        Option.map (resolve_local_binding_annotation ctx) ty_opt
      in
      let ty_opt = Option.map Type_resolution.canonical resolved_ty_opt in
      let source_ty_opt = Option.map Type_resolution.source resolved_ty_opt in
      (* Reject Void variable declarations *)
      let* () =
        match ty_opt with
        | Some (TyNamed ("Void", [])) ->
            error loc
              (Printf.sprintf "Cannot declare variable '%s' with type Void" name)
        | _ -> Ok ()
      in
      (* Reject negative dimensions in type annotations *)
      let* () =
        match ty_opt with
        | Some ty -> (
            match Types.Dim.find_negative ty with
            | Some n ->
                error loc
                  (Printf.sprintf
                     "Dimension arithmetic produces non-positive result: %d \
                      (dimensions must be >= 1)"
                     n)
            | None -> Ok ())
        | None -> Ok ()
      in
      (* Reject variadic dims in variable type annotations — only valid in function params/returns *)
      let* () =
        match ty_opt with
        | Some ty when Types.Dim.contains_vardims ty ->
            error_with ~notes:[]
              ~help:
                (Some
                   "Use a concrete dimension like #N, or remove the annotation \
                    to let the compiler infer the type")
              loc
              (Printf.sprintf
                 "Variadic dimensions (#N...) cannot appear in variable type \
                  annotations for '%s'"
                 name)
        | _ -> Ok ()
      in
      (* Use declared type as expected type for inference if available *)
      let* val_ty, value' =
        match ty_opt with
        | Some ty -> infer_annotated_value_expr ctx ty value
        | None -> infer_unconstrained_value_expr ctx value
      in
      match ty_opt with
      | Some declared_ty ->
          (* Check that inferred type matches declared type *)
          if ctx_types_compatible ctx declared_ty val_ty then begin
            let source_ty = Option.value source_ty_opt ~default:declared_ty in
            let value' =
              with_explicit_source_type ~source_ty value' declared_ty
            in
            let _env' =
              add_var ctx.env name declared_ty ~source_type:source_ty
                ~mutability:(if is_mutable then Mutable else Immutable)
                ()
            in
            let new_expr =
              with_inferred_type
                {
                  expr with
                  expr_desc =
                    EVarDecl (name, Some declared_ty, value', is_mutable);
                }
                ty_void
            in
            Ok (ty_void, new_expr)
          end
          else
            error loc
              (Printf.sprintf
                 "Type mismatch in variable '%s'\n\
                 \    expected: %s\n\
                 \       found: %s"
                 name
                 (type_to_string declared_ty)
                 (type_to_string val_ty))
      | None ->
          let* () =
            reject_void_value
              ~context:(Printf.sprintf "Declaration of '%s'" name)
              loc val_ty
          in
          (* Reject inferred types containing unresolved variadic dims —
              EXCEPT those bound by the enclosing function's params/return.
              A generic function like [set_all[T](arr: T[#Ds...])]
              legitimately propagates #Ds... through local vars (var result = arr). *)
          let* () =
            if Types.Dim.contains_vardims val_ty then
              let bound = vardims_bound_in_scope ctx.env in
              let unbound =
                List.filter
                  (fun v -> not (List.mem v bound))
                  (Types.Dim.collect_vardim_names val_ty)
              in
              if unbound = [] then Ok ()
              else
                error_with
                  ~notes:
                    [
                      "Variadic dimensions (#N...) must be resolved to \
                       concrete dimensions at every use site";
                    ]
                  ~help:
                    (Some
                       "Add a type annotation with concrete dimensions, use \
                        assert_shape to refine, or use List[T] for \
                        runtime-sized data")
                  loc
                  (Printf.sprintf
                     "Cannot infer concrete dimensions for variable '%s': type \
                      is %s"
                     name (type_to_string val_ty))
            else Ok ()
          in
          let bind_ty = inferred_binding_type ~is_mutable val_ty in
          let value' =
            annotate_inferred_binding_value ~is_mutable value' val_ty
          in
          let _env' =
            add_var ctx.env name bind_ty
              ~mutability:(if is_mutable then Mutable else Immutable)
              ()
          in
          let new_expr =
            with_inferred_type
              {
                expr with
                expr_desc = EVarDecl (name, Some bind_ty, value', is_mutable);
              }
              ty_void
          in
          Ok (ty_void, new_expr))
  (* Tuple destructuring: (a, b) = expr or (a, b, c) = expr *)
  | ETupleDestruct (names, value) -> (
      (* Reject same-scope re-declaration *)
      let* () =
        List.fold_left
          (fun acc name ->
            let* () = acc in
            if name <> "_" then check_no_redeclaration ctx.env name loc
            else Ok ())
          (Ok ()) names
      in
      let* val_ty, value' = infer_unconstrained_value_expr ctx value in
      (* Value must be a tuple type *)
      match val_ty with
      | TyTuple elem_tys when List.length elem_tys = List.length names ->
          (* Add all variables to environment *)
          let _env' =
            List.fold_left2
              (fun env name ty -> add_var env name ty ())
              ctx.env names elem_tys
          in
          let new_expr =
            with_inferred_type
              { expr with expr_desc = ETupleDestruct (names, value') }
              ty_void
          in
          Ok (ty_void, new_expr)
      | TyTuple elem_tys ->
          error loc
            (Printf.sprintf
               "Tuple destructuring arity mismatch: expected %d elements, got \
                %d"
               (List.length names) (List.length elem_tys))
      | _ ->
          error loc
            (Printf.sprintf "Tuple destructuring requires a tuple type, got %s"
               (type_to_string val_ty)))
  (* String interpolation *)
  | EStringInterp (parts, is_triple) -> (
      (* Check each expression part and ensure it's stringable *)
      let rec check_parts acc = function
        | [] -> Ok (List.rev acc)
        | InterpLit s :: rest -> check_parts (InterpLit s :: acc) rest
        | InterpExpr e :: rest -> (
            match infer_unconstrained_value_expr ctx e with
            | Error err -> Error err
            | Ok (ty, e') ->
                (* All primitive types, String, and Stringable types can be interpolated *)
                let is_stringable =
                  match ty with
                  | TyNamed ("Int", [])
                  | TyNamed ("Float", [])
                  | TyNamed ("Bool", [])
                  | TyNamed ("Char", [])
                  | TyNamed ("String", []) ->
                      true
                  | TyRange _ -> true
                  | _ when Types.is_float32_type ty -> true
                  | _ when Types.is_float16_type ty -> true
                  | _ when Types.is_any_integer_type ty -> true
                  | _ when Types.is_array_type ty -> true
                  | TyNamed ("List", _) -> true
                  | TyNamed ("Result", _) -> true
                  | _ -> trait_obligation_satisfied ctx.env ty "Stringable"
                in
                if is_stringable then check_parts (InterpExpr e' :: acc) rest
                else
                  error e.expr_loc
                    (Printf.sprintf
                       "Interpolated expression has type %s which cannot be \
                        converted to String. Implement Stringable for this \
                        type or convert it explicitly"
                       (type_to_string ty)))
      in
      match check_parts [] parts with
      | Error err -> Error err
      | Ok parts' ->
          Ok
            ( ty_string,
              with_inferred_type
                { expr with expr_desc = EStringInterp (parts', is_triple) }
                ty_string ))
  (* Subscript reads (ESubscript, ESubscriptMulti) are rewritten to
     call syntax by [Subscript_desugar] before typecheck. Reaching
     them here means the pass didn't run. *)
  | ESubscript (_, _) | ESubscriptMulti (_, _) ->
      error loc
        "internal: subscript-read node reached typecheck; Subscript_desugar \
         should have rewritten it to a \
         checked_get/checked_slice/matrix_checked_get call"
  (* Subscript assignment: tensor[i, ...] = val — desugars to checked_set etc.
     Deliberately kept here (not moved into [Subscript_desugar]) so
     the mutability check below can run with env access. See
     [Subscript_desugar]'s header docstring. *)
  | ESubscriptAssign (coll, indices, value) ->
      (* Check mutability: subscript assignment requires a mutable variable.
         Recurse through field accesses to find the root variable. *)
      let* () =
        let rec find_root_var e =
          match e.expr_desc with
          | EIdent name -> Some name
          | EFieldAccess (inner, _) -> find_root_var inner
          | _ -> None
        in
        match find_root_var coll with
        | Some name -> (
            match Env.lookup ctx.env name with
            | Some { kind = VarSymbol { mutability = Immutable; _ }; _ } ->
                error_with ~notes:[]
                  ~help:
                    (Some
                       (Printf.sprintf
                          "Declare with 'var' to make it mutable: var %s = ..."
                          name))
                  expr.expr_loc
                  (Printf.sprintf
                     "Cannot assign to subscript of immutable variable '%s'"
                     name)
            | _ -> Ok ())
        | None -> Ok ()
      in
      infer_nd_checked_set ctx expr coll indices value loc
  (* try: block — short-circuit for Option/Result *)
  | ETry stmts ->
      if stmts = [] then error loc "try: block cannot be empty"
      else begin
        let expected_try_yield ctx try_context =
          match (expected_type_opt ctx, try_context) with
          | Some (TyNamed ("Option", [ payload_ty ])), (None | Some `Option) ->
              Some payload_ty
          | ( Some (TyNamed ("Result", [ payload_ty; expected_err_ty ])),
              Some (`Result actual_err_ty) )
            when ctx_types_compatible ctx expected_err_ty actual_err_ty ->
              Some payload_ty
          | _ -> None
        in
        (* Push a new scope for the try block *)
        let inner_ctx = { ctx with env = Env.push_scope ctx.env } in
        (* Infer each statement, threading environment through *)
        let rec infer_try_stmts ctx acc try_context stmts =
          match stmts with
          | [] -> error loc "try: block cannot be empty"
          | [ last ] -> (
              (* Last expression is the yield — infer it normally *)
              match last.expr_desc with
              | ETryBind _ ->
                  error last.expr_loc
                    "Last expression in try: block cannot be a ?= binding — it \
                     must be a value to yield"
              | _ ->
                  let* yield_ty, last' =
                    match expected_try_yield ctx try_context with
                    | Some payload_ty ->
                        infer_expected_value_expr ctx payload_ty last
                    | None -> infer_unconstrained_value_expr ctx last
                  in
                  (* Check for accidental double-wrapping — only reject explicit Some()/Ok() calls *)
                  let is_explicit_wrap =
                    match last.expr_desc with
                    | ECall ({ expr_desc = EIdent "Some"; _ }, _) -> Some "Some"
                    | ECall ({ expr_desc = EIdent "Ok"; _ }, _) -> Some "Ok"
                    | _ -> None
                  in
                  let* () =
                    match (is_explicit_wrap, try_context) with
                    | Some "Some", (Some `Option | None) ->
                        error last.expr_loc
                          "try: block automatically wraps the result in \
                           Some(...) — return the bare value instead"
                    | Some "Ok", Some (`Result _) ->
                        error last.expr_loc
                          "try: block automatically wraps the result in \
                           Ok(...) — return the bare value instead"
                    | _ -> Ok ()
                  in
                  let result_ty =
                    match try_context with
                    | Some `Option -> TyNamed ("Option", [ yield_ty ])
                    | Some (`Result err_ty) ->
                        TyNamed ("Result", [ yield_ty; err_ty ])
                    | None ->
                        (* No ?= bindings — default to Option *)
                        TyNamed ("Option", [ yield_ty ])
                  in
                  Ok
                    ( result_ty,
                      with_inferred_type
                        { expr with expr_desc = ETry (List.rev (last' :: acc)) }
                        result_ty ))
          | stmt :: rest -> (
              match stmt.expr_desc with
              | ETryBind (name, ty_ann, rhs) -> (
                  let* rhs_ty, rhs' = infer_unconstrained_value_expr ctx rhs in
                  (* ?= works on Option and Result only *)
                  match rhs_ty with
                  | TyNamed ("Option", [ inner_ty ]) -> (
                      match try_context with
                      | Some (`Result _) ->
                          error stmt.expr_loc
                            "Cannot mix Option and Result ?= bindings in the \
                             same try: block"
                      | _ ->
                          let* ctx', stmt' =
                            validate_try_bind ctx stmt name ty_ann inner_ty rhs'
                          in
                          infer_try_stmts ctx' (stmt' :: acc) (Some `Option)
                            rest)
                  | TyNamed ("Result", [ inner_ty; err_ty ]) -> (
                      match try_context with
                      | Some `Option ->
                          error stmt.expr_loc
                            "Cannot mix Option and Result ?= bindings in the \
                             same try: block"
                      | Some (`Result prev_err_ty) ->
                          let type_params = Env.get_type_params ctx.env in
                          if
                            not
                              (types_bidirectional ~type_params prev_err_ty
                                 err_ty)
                          then
                            error stmt.expr_loc
                              (Printf.sprintf
                                 "Incompatible error types in try: block: `%s` \
                                  vs `%s`"
                                 (type_to_string prev_err_ty)
                                 (type_to_string err_ty))
                          else begin
                            let* ctx', stmt' =
                              validate_try_bind ctx stmt name ty_ann inner_ty
                                rhs'
                            in
                            infer_try_stmts ctx' (stmt' :: acc)
                              (Some (`Result err_ty))
                              rest
                          end
                      | None ->
                          let* ctx', stmt' =
                            validate_try_bind ctx stmt name ty_ann inner_ty rhs'
                          in
                          infer_try_stmts ctx' (stmt' :: acc)
                            (Some (`Result err_ty))
                            rest)
                  | _ ->
                      error stmt.expr_loc
                        (Printf.sprintf
                           "Cannot use `?=` on type `%s` — only Option and \
                            Result support ?= bindings"
                           (type_to_string rhs_ty)))
              | _ ->
                  (* Regular statement — infer normally and thread context *)
                  let* _, stmt' = infer_statement_expr ctx stmt in
                  let ctx' =
                    match stmt'.expr_desc with
                    | EVarDecl (name, Some var_ty, value, is_mutable) ->
                        {
                          ctx with
                          env =
                            Env.add_var ctx.env name var_ty
                              ?source_type:(inferred_binding_source_type value)
                              ~mutability:
                                (if is_mutable then Mutable else Immutable)
                              ();
                        }
                    | _ -> ctx
                  in
                  infer_try_stmts ctx' (stmt' :: acc) try_context rest)
        in
        infer_try_stmts inner_ctx [] None stmts
      end
  (* ?= binding outside try: block *)
  | ETryBind _ -> error loc "?= binding can only be used inside a try: block"
  | EDebugBlock stmts ->
      let inner_ctx =
        {
          (without_expected ctx) with
          env = Env.push_scope ctx.env;
          in_debug_context = true;
        }
      in
      let* results = infer_all inner_ctx stmts in
      let stmts' = List.map snd results in
      Ok
        ( ty_void,
          with_inferred_type
            { expr with expr_desc = EDebugBlock stmts' }
            ty_void )
  (* Concurrent binding outside concurrent: block *)
  | EConcurrentBind _ ->
      error loc "concurrent binding can only be used inside a concurrent: block"
  (* concurrent: block — structured concurrency *)
  | EConcurrent (stmts, timeout_opt, max_threads) ->
      if stmts = [] then error loc "concurrent: block cannot be empty"
      else begin
        (* Validate timeout is Int if present *)
        let* timeout_opt' =
          match timeout_opt with
          | Some t ->
              let* t_ty, t' = infer_expected_value_expr ctx ty_int t in
              if ctx_types_compatible ctx ty_int t_ty then Ok (Some t')
              else
                error t.expr_loc "concurrent timeout must be Int (milliseconds)"
          | None -> Ok None
        in
        (* Infer each binding — must be EVarDecl (immutable) *)
        let infer_one_binding ctx stmt name ty_ann body =
          let* body_ty, body' = infer_unconstrained_value_expr ctx body in
          let result_ty =
            TyNamed ("Result", [ body_ty; TyNamed ("ConcurrencyError", []) ])
          in
          (* Validate type annotation if present — must match Result[T, ConcurrencyError] *)
          let* () =
            match ty_ann with
            | Some ann_ty ->
                let type_params = Env.get_type_params ctx.env in
                if types_compatible ~type_params ann_ty result_ty then Ok ()
                else
                  error stmt.expr_loc
                    (Printf.sprintf
                       "Type annotation `%s` does not match concurrent result \
                        type `%s`"
                       (type_to_string ann_ty) (type_to_string result_ty))
            | None -> Ok ()
          in
          let env' = Env.add_var ctx.env name result_ty () in
          let ctx' = { ctx with env = env' } in
          let bind' =
            with_inferred_type
              { stmt with expr_desc = EConcurrentBind (name, ty_ann, body') }
              result_ty
          in
          Ok (bind', ctx')
        in
        let rec infer_concurrent_bindings ctx acc = function
          | [] ->
              if acc = [] then error loc "concurrent: block cannot be empty"
              else Ok (List.rev acc, ctx)
          | stmt :: rest -> (
              match stmt.expr_desc with
              | EVarDecl (name, ty_ann, body, false) ->
                  let* bind', ctx' =
                    infer_one_binding ctx stmt name ty_ann body
                  in
                  infer_concurrent_bindings ctx' (bind' :: acc) rest
              | EAssign (name, body) ->
                  (* name = expr without type annotation also valid *)
                  let* bind', ctx' =
                    infer_one_binding ctx stmt name None body
                  in
                  infer_concurrent_bindings ctx' (bind' :: acc) rest
              | EVarDecl (_, _, _, true) ->
                  error stmt.expr_loc
                    "concurrent bindings cannot be mutable (var)"
              | _ ->
                  error stmt.expr_loc
                    "concurrent: block must contain only bindings (name = expr)"
              )
        in
        let* bindings', _ctx' = infer_concurrent_bindings ctx [] stmts in
        (* EConcurrent evaluates to Void; bindings leak to enclosing scope via infer_all *)
        Ok
          ( ty_void,
            with_inferred_type
              {
                expr with
                expr_desc = EConcurrent (bindings', timeout_opt', max_threads);
              }
              ty_void )
      end
  (* concurrent for — dynamic fan-out *)
  | EConcurrentFor (var, iter, body, timeout_opt, max_threads) ->
      (* Validate timeout is Int if present *)
      let* timeout_opt' =
        match timeout_opt with
        | Some t ->
            let* t_ty, t' = infer_expected_value_expr ctx ty_int t in
            if ctx_types_compatible ctx ty_int t_ty then Ok (Some t')
            else
              error t.expr_loc
                "concurrent for timeout must be Int (milliseconds)"
        | None -> Ok None
      in
      let* iter_ty, iter' = infer_unconstrained_value_expr ctx iter in
      let elem_ty =
        match iter_ty with
        | TyNamed ("List", [ t ]) -> Ok t
        | _ ->
            error iter.expr_loc
              (Printf.sprintf "concurrent for requires a List, got %s"
                 (type_to_string iter_ty))
      in
      let* elem_ty = elem_ty in
      let inner_ctx =
        { ctx with env = Env.add_var ctx.env var elem_ty ~origin:ForLoopVar () }
      in
      let* body_ty, body' = infer_unconstrained_value_expr inner_ctx body in
      (* Check for assignments to outer mutable variables (data race) *)
      let rec check_outer_assigns (e : expr) =
        match e.expr_desc with
        | EAssign (name, _) when name <> var -> (
            match Env.lookup ctx.env name with
            | Some { kind = VarSymbol { mutability = Mutable; _ }; _ } ->
                error e.expr_loc
                  (Printf.sprintf
                     "Cannot assign to outer variable '%s' inside concurrent \
                      for (data race)"
                     name)
            | _ -> Ok ())
        | _ ->
            List.fold_left
              (fun acc child ->
                match acc with
                | Error e -> Error e
                | Ok () -> check_outer_assigns child)
              (Ok ()) (Ast.expr_children e)
      in
      let* () = check_outer_assigns body' in
      let result_elem_ty =
        TyNamed ("Result", [ body_ty; TyNamed ("ConcurrencyError", []) ])
      in
      let result_ty = TyNamed ("List", [ result_elem_ty ]) in
      Ok
        ( result_ty,
          with_inferred_type
            {
              expr with
              expr_desc =
                EConcurrentFor (var, iter', body', timeout_opt', max_threads);
            }
            result_ty )
  (* detach expr — detach, returns Void *)
  | EDetach body ->
      let* _body_ty, body' = infer_statement_expr ctx body in
      Ok
        ( ty_void,
          with_inferred_type { expr with expr_desc = EDetach body' } ty_void )
  (* Dict literal *)
  | EDict pairs -> (
      match pairs with
      | [] -> error loc "Dict literal must have at least one entry"
      | (first_key, first_val) :: rest ->
          let expected_key_ty, expected_val_ty =
            match expected_type_opt ctx with
            | Some (TyNamed ("Dict", [ key_ty; val_ty ])) ->
                (Some key_ty, Some val_ty)
            | _ -> (None, None)
          in
          let* key_ty, first_key' =
            infer_collection_literal_target ctx Type_widening.DictLiteral
              ?expected_ty:expected_key_ty ~mismatch_label:"Dict literal key"
              first_key
          in
          let* val_ty, first_val' =
            infer_collection_literal_target ctx Type_widening.DictLiteral
              ?expected_ty:expected_val_ty ~mismatch_label:"Dict literal value"
              first_val
          in
          let* typed_rest =
            List.fold_left
              (fun acc (k, v) ->
                let* pairs = acc in
                let* _kt, k' =
                  infer_checked_collection_element ctx Type_widening.DictLiteral
                    ~target_ty:key_ty ~mismatch_label:"Dict literal key" k
                in
                let* _vt, v' =
                  infer_checked_collection_element ctx Type_widening.DictLiteral
                    ~target_ty:val_ty ~mismatch_label:"Dict literal value" v
                in
                Ok ((k', v') :: pairs))
              (Ok []) rest
          in
          let typed_rest = List.rev typed_rest in
          let dict_ty = TyNamed ("Dict", [ key_ty; val_ty ]) in
          Ok
            ( dict_ty,
              with_inferred_type
                {
                  expr with
                  expr_desc = EDict ((first_key', first_val') :: typed_rest);
                }
                dict_ty ))
  (* Raw interpolation should have been transformed *)
  | EStringInterpRaw _ ->
      error loc
        "Internal error: EStringInterpRaw should have been transformed before \
         type checking"
  (* Nested function declarations should be eliminated by the nested-hoist
     pass (runs before typecheck). Surviving to here is a pipeline bug. *)
  | EFuncDecl _ ->
      error loc
        "Internal error: EFuncDecl survived to type checking; the nested-hoist \
         pass should have eliminated it"

(** Validate a single index against a tensor dimension.
    Returns the inferred index expression on success.
    Identifiers must be proven in-bounds for the collection
    via bounded loops, enumerate, or control-flow narrowing. *)
and validate_index ctx loc idx dim coll' =
  let* idx_ty, idx' = infer_expected_value_expr ctx ty_int idx in
  let subscript_bounds coll_name =
    let dim_bounds =
      match dim with
      | TyConstInt size -> (
          match Refinement.constant_dim_bound size with
          | Some bound -> [ bound ]
          | None -> [])
      | TyVar name when Types.Dim.is_var_name name -> (
          match dimension_bound_opt name with
          | Some bound -> [ bound ]
          | None -> [])
      | _ -> []
    in
    match coll_name with
    | Some cn -> (
        match collection_length_bound_opt cn with
        | Some bound -> bound :: dim_bounds
        | None -> dim_bounds)
    | None -> dim_bounds
  in
  (* Range-typed values are proven in-bounds: ..#N is safe for dimension >= N *)
  match idx_ty with
  | TyRange (TyConstInt range_bound) -> (
      match dim with
      | TyConstInt size when range_bound <= size -> Ok idx'
      | TyConstInt size ->
          error loc
            (Printf.sprintf "Range type ..#%d does not fit dimension of size %d"
               range_bound size)
      | dim_expr -> (
          let min_dim =
            let c =
              Dim_solver.to_canonical ~lookup_meta:Types.lookup_meta dim_expr
            in
            if
              List.for_all
                (fun (m : Dim_solver.monomial) -> m.coeff > 0)
                c.terms
            then
              let var_min =
                List.fold_left
                  (fun acc (m : Dim_solver.monomial) -> acc + m.coeff)
                  0 c.terms
              in
              Some (c.const + var_min)
            else None
          in
          match min_dim with
          | Some min_size when range_bound <= min_size -> Ok idx'
          | _ ->
              error loc
                "Cannot verify bounds: dimension is not known at compile time"))
  | TyRange (TyVar range_var) -> (
      (* Generic range: ..#N matches dimension #N (same var = same bound) *)
      match dim with
      | TyVar dim_var when range_var = dim_var -> Ok idx'
      | _ ->
          error loc
            "Cannot verify bounds: dimension type variable does not match \
             range type")
  | _ -> (
      match idx'.expr_desc with
      | ELiteral (LitInt n) -> (
          let n_int = Int64.to_int n in
          match dim with
          | TyConstInt size ->
              if n_int < 0 then
                (* Negative indexing: v[-k] desugars to v[dim - k] *)
                let pos = size + n_int in
                (* e.g., size=5, n=-1 → pos=4 *)
                if pos < 0 then
                  error loc
                    (Printf.sprintf
                       "Negative index %d out of bounds for dimension of size \
                        %d (resolves to %d)"
                       n_int size pos)
                else
                  Ok
                    (with_inferred_desc idx'
                       (ELiteral (LitInt (Int64.of_int pos)))
                       ty_int)
              else if n_int >= size then
                error loc
                  (Printf.sprintf
                     "Index %d out of bounds for dimension of size %d" n_int
                     size)
              else Ok idx'
          | dim_expr -> (
              (* Symbolic bounds: extract minimum guaranteed dimension from the
              canonical form. Dim vars are >= 1, so each positive-coefficient
              monomial contributes at least its coefficient to the minimum.
              min = constant + sum(coeff for each positive-coeff monomial) *)
              let min_dim =
                let c =
                  Dim_solver.to_canonical ~lookup_meta:Types.lookup_meta
                    dim_expr
                in
                if
                  List.for_all
                    (fun (m : Dim_solver.monomial) -> m.coeff > 0)
                    c.terms
                then
                  let var_min =
                    List.fold_left
                      (fun acc (m : Dim_solver.monomial) ->
                        acc
                        + m.coeff (* each var >= 1, so coeff * var >= coeff *))
                      0 c.terms
                  in
                  Some (c.const + var_min)
                else None
              in
              match min_dim with
              | Some min_size when n_int >= 0 && n_int < min_size -> Ok idx'
              | Some min_size when n_int < 0 && min_size + n_int >= 0 ->
                  (* Negative indexing with symbolic dim: rewrite v[-k] to
                   length(v) + (-k) so the runtime gets a positive index. *)
                  let mk e = with_inferred_desc idx' e ty_int in
                  let len_call = mk (ECall (mk (EIdent "length"), [ coll' ])) in
                  let offset = mk (ELiteral (LitInt (Int64.of_int n_int))) in
                  Ok (mk (EBinary (Add, len_call, offset)))
              | _ ->
                  if n_int < 0 then
                    error loc
                      (Printf.sprintf
                         "Negative index %d requires a compile-time known \
                          dimension to verify bounds. Use v[length(v) %s %d] \
                          with an explicit bounds check, or call with a \
                          concrete dimension"
                         n_int
                         (if n_int = -1 then "-" else "+ (")
                         (if n_int = -1 then 1 else n_int))
                  else
                    error loc
                      "Cannot verify bounds: dimension is not known at compile \
                       time"))
      | EUnary (Neg, { expr_desc = ELiteral (LitInt n); _ }) when n > 0L -> (
          (* Parser sometimes produces EUnary(Neg, LitInt n) instead of LitInt (Int64.neg n) *)
          let n_int = Int64.to_int n in
          match dim with
          | TyConstInt size ->
              let pos = size - n_int in
              if pos < 0 then
                error loc
                  (Printf.sprintf
                     "Negative index -%d out of bounds for dimension of size \
                      %d (resolves to %d)"
                     n_int size pos)
              else
                Ok
                  (with_inferred_desc idx'
                     (ELiteral (LitInt (Int64.of_int pos)))
                     ty_int)
          | dim_expr -> (
              let min_dim =
                let c =
                  Dim_solver.to_canonical ~lookup_meta:Types.lookup_meta
                    dim_expr
                in
                if
                  List.for_all
                    (fun (m : Dim_solver.monomial) -> m.coeff > 0)
                    c.terms
                then
                  let var_min =
                    List.fold_left
                      (fun acc (m : Dim_solver.monomial) -> acc + m.coeff)
                      0 c.terms
                  in
                  Some (c.const + var_min)
                else None
              in
              match min_dim with
              | Some min_size when min_size - n_int >= 0 ->
                  (* Rewrite v[-k] to length(v) - k for runtime *)
                  let mk e = with_inferred_desc idx' e ty_int in
                  let len_call = mk (ECall (mk (EIdent "length"), [ coll' ])) in
                  let offset = mk (ELiteral (LitInt (Int64.of_int n_int))) in
                  Ok (mk (EBinary (Sub, len_call, offset)))
              | _ ->
                  error loc
                    (Printf.sprintf
                       "Negative index -%d requires a compile-time known \
                        dimension to verify bounds. Use v[length(v) - %d] with \
                        an explicit bounds check, or call with a concrete \
                        dimension"
                       n_int n_int)))
      | EUnary (Neg, { expr_desc = ELiteral (LitInt _); _ }) ->
          error loc "Index 0 is not negative — use v[0] instead of v[-0]"
      | EIdent idx_var ->
          let coll_pc = expr_to_proven_collection ctx.env coll' in
          (* Check direct collection match (for i in 0..length(v): v[i]) *)
          let is_proven_direct =
            match coll_pc with
            | Some pc ->
                expr_proves_subscript idx' pc
                || env_binding_proves_subscript ctx.env idx_var pc
            | None -> false
          in
          (* Check dimension match (for i in 0..N: v[i] where v has dim #M, N <= M) *)
          let is_proven_dim =
            if is_proven_direct then true
            else
              match dim with
              | TyConstInt size ->
                  expr_proves_dim_at_most idx' ~size
                  || env_binding_proves_dim_at_most ctx.env idx_var ~size
              | _ -> false
          in
          (* Check same-dimension match: for i in 0..length(a): b[i]
         where a and b have the same tensor dimension type.
         If i is proven for CollVar x and the target collection has
         the same first dim as x, accept it. *)
          let is_proven_same_dim =
            if is_proven_dim then true
            else
              let get_first_dim var_name =
                match Env.get_var_type ctx.env var_name with
                | Some ty -> (
                    match Types.array_parts ty with
                    | Some (_, d :: _) -> Some d
                    | _ -> None)
                | _ -> None
              in
              expr_direct_collection_vars idx'
              @ env_binding_direct_collection_vars ctx.env idx_var
              |> List.exists (fun proven_var ->
                  match (get_first_dim proven_var, Some dim) with
                  | Some d1, Some d2 -> types_equal d1 d2
                  | _ -> false)
          in
          (* Check durable expression/binding proof metadata for a range proof
         that covers this subscript. Two shapes prove it:
         - Literal upper [RangeUpperLit] where range ⊆ [0, dim).
         - Symbolic upper [RangeUpperLengthMinus] or [RangeUpperAtMostLength]
           where upper is bounded by the same collection we're subscripting. *)
          let coll_name =
            match coll'.expr_desc with EIdent n -> Some n | _ -> None
          in
          let is_proven_range =
            if is_proven_same_dim then true
            else
              let bounds = subscript_bounds coll_name in
              expr_proves_direct_range idx' ~bounds
              || env_binding_proves_direct_range ctx.env idx_var ~bounds
          in
          if is_proven_range then Ok idx'
          else
            error loc
              "Subscript index must be a compile-time constant or a loop \
               variable proven in-bounds (e.g., for i in 0..length(v): v[i]). \
               Use get() for runtime-checked access"
      (* Offset from proven loop variable or range-typed variable: v[i + k] or
         v[i - k]. Expression proof payloads are authoritative; Env binding
         metadata is the fallback for transitional expression construction
         gaps. *)
      | EBinary
          ( ((Add | Sub) as op),
            ({ expr_desc = EIdent idx_var; _ } as idx_base),
            { expr_desc = ELiteral (LitInt k); _ } ) -> (
          let k_int = Int64.to_int k in
          let offset = if op = Add then k_int else -k_int in
          let coll_name =
            match coll'.expr_desc with EIdent n -> Some n | _ -> None
          in
          let bounds = subscript_bounds coll_name in
          let proven_from_expr =
            expr_proves_offset_range idx_base ~bounds ~offset
          in
          let proven_from_binding =
            env_binding_proves_offset_range ctx.env idx_var ~bounds ~offset
          in
          let proof_result =
            match proven_from_expr with
            | OffsetRejected OffsetNoMatchingBound -> proven_from_binding
            | OffsetProven | OffsetRejected (OffsetOutOfBounds _) ->
                proven_from_expr
          in
          let proven =
            match proof_result with
            | Refinement.OffsetProven -> Ok ()
            | OffsetRejected (OffsetOutOfBounds msg) ->
                Error
                  (Printf.sprintf "Loop offset %s %s %d: %s" idx_var
                     (if offset >= 0 then "+" else "-")
                     (abs offset) msg)
            | OffsetRejected OffsetNoMatchingBound -> Error ""
          in
          match proven with
          | Ok () -> Ok idx'
          | Error msg when msg <> "" -> error loc msg
          | Error _ ->
              error loc
                "Subscript index must be a compile-time constant or a loop \
                 variable proven in-bounds (e.g., for i in 0..length(v): \
                 v[i]). Use get() for runtime-checked access")
      (* Modulo indexing: v[expr % N] where N is a positive constant that fits the dimension.
     Always safe because result is in [-(N-1), N-1]. We rewrite to ((expr % N) + N) % N
     to guarantee non-negative result in C (where % can return negative for negative dividend). *)
      | EBinary (Mod, mod_lhs, rhs) -> (
          let mod_bound =
            match expr_proof_semantic_type_opt rhs with
            | Some (TyConstInt n) when n > 0 -> Some n
            | _ -> (
                match rhs.expr_desc with
                | ELiteral (LitInt n) when n > 0L -> Some (Int64.to_int n)
                | _ -> None)
          in
          match (mod_bound, dim) with
          | Some n, TyConstInt size when n <= size ->
              (* Rewrite: (lhs % N + N) % N — always non-negative in C *)
              let n_lit =
                with_inferred_desc idx'
                  (ELiteral (LitInt (Int64.of_int n)))
                  ty_int
              in
              let inner_mod =
                with_inferred_desc idx' (EBinary (Mod, mod_lhs, n_lit)) ty_int
              in
              let add_n =
                with_inferred_desc idx' (EBinary (Add, inner_mod, n_lit)) ty_int
              in
              let safe_mod =
                with_inferred_desc idx' (EBinary (Mod, add_n, n_lit)) ty_int
              in
              Ok safe_mod
          | Some n, TyConstInt size ->
              error loc
                (Printf.sprintf "Modulo bound %d exceeds dimension of size %d" n
                   size)
          | _ ->
              (* Check if modulo RHS is length(same_collection) — always safe *)
              let rhs_is_length_of_coll =
                match rhs.expr_desc with
                | ECall
                    ( { expr_desc = EIdent ("length" | "vector_length"); _ },
                      [ { expr_desc = EIdent rhs_coll; _ } ] ) -> (
                    let coll_name =
                      match coll'.expr_desc with
                      | EIdent n -> Some n
                      | _ -> None
                    in
                    match coll_name with
                    | Some cn when String.equal cn rhs_coll -> true
                    | _ -> false)
                | _ -> false
              in
              if rhs_is_length_of_coll then
                (* Safe: (expr % length(v)) is always in [0, length(v)).
                Rewrite to ((expr % length(v)) + length(v)) % length(v) for non-negative result. *)
                let len_call = rhs in
                let inner_mod =
                  with_inferred_desc idx'
                    (EBinary (Mod, mod_lhs, len_call))
                    ty_int
                in
                let add_len =
                  with_inferred_desc idx'
                    (EBinary (Add, inner_mod, len_call))
                    ty_int
                in
                let safe_mod =
                  with_inferred_desc idx'
                    (EBinary (Mod, add_len, len_call))
                    ty_int
                in
                Ok safe_mod
              else
                error loc
                  "Subscript modulo requires a positive compile-time integer \
                   literal or length(v). Use get() for runtime-checked access")
      (* Commutative form: v[1 + i] — suggest rewriting to v[i + 1] *)
      | EBinary
          ( Add,
            { expr_desc = ELiteral (LitInt _); _ },
            { expr_desc = EIdent _; _ } ) ->
          error loc
            "Loop offset access requires the variable on the left: write v[i + \
             k] instead of v[k + i]"
      | _ ->
          error loc
            "Subscript index must be a compile-time constant or a loop \
             variable proven in-bounds (e.g., for i in 0..length(v): v[i]). \
             Use get() for runtime-checked access")

(** Infer a value expression that must choose its own type. Surrounding return
    or container expectations must not shape operands, scrutinees, indices,
    iterators, or other self-contained inputs. *)
and infer_unconstrained_value_expr ctx expr =
  infer_expr (without_expected ctx) expr

(** Infer a value expression with a bidirectional expected type. Use only for
    positions that actually produce that value: annotated initializers,
    assignment RHS values, collection elements, call arguments, and branch
    yields. *)
and infer_expected_value_expr ctx expected_ty expr =
  infer_expr (with_expected ctx expected_ty) expr

and infer_expected_argument_expr ctx param_ty expr =
  infer_expr (with_expected_value_slot ctx param_ty ExpectedArgumentSlot) expr

and infer_expected_collection_element_expr ctx kind expected_ty expr =
  infer_expr
    (with_expected_value_slot ctx expected_ty (ExpectedCollectionElement kind))
    expr

and infer_checked_collection_element ctx kind ~target_ty ~mismatch_label
    ?void_context expr =
  let* elem_ty, elem' =
    infer_expected_collection_element_expr ctx kind target_ty expr
  in
  let* () =
    match void_context with
    | Some context -> reject_void_value ~context expr.expr_loc elem_ty
    | None -> Ok ()
  in
  if ctx_types_compatible ctx target_ty elem_ty then Ok (elem_ty, elem')
  else
    error expr.expr_loc
      (Printf.sprintf "%s type mismatch: expected %s, got %s" mismatch_label
         (type_to_string target_ty) (type_to_string elem_ty))

and infer_collection_literal_target ctx kind ?expected_ty ~mismatch_label
    ?void_context expr =
  let* target_ty =
    match expected_ty with
    | Some target_ty -> Ok target_ty
    | None ->
        let* raw_ty, _ = infer_unconstrained_value_expr ctx expr in
        Ok
          (Type_widening.collection_element_slot kind raw_ty
          |> Type_widening.value_type)
  in
  let* _actual_ty, expr' =
    infer_checked_collection_element ctx kind ~target_ty ~mismatch_label
      ?void_context expr
  in
  Ok (target_ty, expr')

and infer_expected_bitwise_operand_expr ctx expected_ty expr =
  infer_expr
    (with_expected_value_slot ctx expected_ty ExpectedBitwiseOperand)
    expr

and infer_annotated_value_expr ctx expected_ty expr =
  infer_expr (with_annotated_expected ctx expected_ty) expr

(** Infer a statement-position expression. Its result is discarded, so expected
    type context from the enclosing expression must not leak inward. *)
and infer_statement_expr ctx expr = infer_unconstrained_value_expr ctx expr

and inferred_binding_source_type value =
  match value.expr_type_info with Some info -> info.source_ty | None -> None

(** Infer types for a list of expressions, threading environment through.
    This allows var declarations to be visible to subsequent expressions. *)
and ctx_after_inferred_expr ctx expr' =
  match expr'.expr_desc with
  | EVarDecl (name, Some var_ty, value, is_mutable) ->
      {
        ctx with
        env =
          add_var ctx.env name var_ty
            ?source_type:(inferred_binding_source_type value)
            ~mutability:(if is_mutable then Mutable else Immutable)
            ();
      }
  | ETupleDestruct (names, value) -> (
      (* Get the tuple type from the value's type *)
      match expr_semantic_type_opt value with
      | Some (TyTuple elem_tys) when List.length elem_tys = List.length names ->
          let env' =
            List.fold_left2
              (fun env name ty ->
                if name <> "_" then
                  add_var env name ty () |> fun env ->
                  env_with_binding_refinement_from_proof env ctx.proof_env name
                else env)
              ctx.env names elem_tys
          in
          { ctx with env = env' }
      | _ -> ctx)
  | EConcurrent (bindings, _, _) ->
      (* Concurrent bindings leak to enclosing scope *)
      List.fold_left
        (fun ctx bind ->
          match bind.expr_desc with
          | EConcurrentBind (name, _, _) -> (
              match expr_semantic_type_opt bind with
              | Some result_ty ->
                  { ctx with env = add_var ctx.env name result_ty () }
              | None -> ctx)
          | _ -> ctx)
        ctx bindings
  | _ -> ctx

and infer_all ctx exprs =
  let rec go ctx acc exprs =
    match exprs with
    | [] -> Ok (List.rev acc)
    | expr :: rest -> (
        match infer_expr ctx expr with
        | Error e -> Error e
        | Ok (ty, expr') ->
            (* If this was a var declaration or tuple destruct, add it to the environment for subsequent exprs *)
            let ctx' = ctx_after_inferred_expr ctx expr' in
            go ctx' ((ty, expr') :: acc) rest)
  in
  go ctx [] exprs

(** Infer the type of a function call *)
and infer_bitwise_call ctx expr callee_name args loc =
  (* Check if a type is integer: either a concrete integer type or a type variable
     with Integer/SignedInteger/UnsignedInteger trait bound *)
  let is_integer_or_bound ty =
    Types.is_any_integer_type ty
    ||
    match ty with
    | TyConstInt _ -> true
    | TyVar _ | TyNamed (_, []) ->
        trait_obligation_satisfied ctx.env ty "Integer"
    | _ -> false
  in
  (* Special inference for bitwise builtins: enforce same integer type constraints *)
  match callee_name with
  | ("bit_and" | "bit_or" | "bit_xor") when List.length args = 2 ->
      let a = List.nth args 0 in
      let b = List.nth args 1 in
      let* raw_a_ty, _ = infer_unconstrained_value_expr ctx a in
      let a_slot = Type_widening.bitwise_operand_slot raw_a_ty in
      let a_ty = Type_widening.value_type a_slot in
      if not (is_integer_or_bound raw_a_ty) then
        error loc
          (Printf.sprintf "%s requires integer arguments, got %s" callee_name
             (type_to_string raw_a_ty))
      else
        let* _actual_a_ty, a' =
          infer_expected_bitwise_operand_expr ctx a_ty a
        in
        let* b_ty, b' = infer_expected_bitwise_operand_expr ctx a_ty b in
        if not (ctx_types_compatible ctx a_ty b_ty) then
          error loc
            (Printf.sprintf
               "%s requires both arguments to be the same integer type, got %s \
                and %s"
               callee_name (type_to_string a_ty) (type_to_string b_ty))
        else
          let callee_ty =
            TyFunc { params = [ a_ty; a_ty ]; return = a_ty; is_pure = true }
          in
          let callee_expr = inferred_ident_expr expr callee_name callee_ty in
          Ok (a_ty, inferred_call_expr expr callee_expr [ a'; b' ] a_ty)
  | "bit_not" when List.length args = 1 ->
      let a = List.nth args 0 in
      let* raw_a_ty, _ = infer_unconstrained_value_expr ctx a in
      let a_slot = Type_widening.bitwise_operand_slot raw_a_ty in
      let a_ty = Type_widening.value_type a_slot in
      if not (is_integer_or_bound raw_a_ty) then
        error loc
          (Printf.sprintf "bit_not requires an integer argument, got %s"
             (type_to_string raw_a_ty))
      else
        let* _actual_a_ty, a' =
          infer_expected_bitwise_operand_expr ctx a_ty a
        in
        let callee_ty =
          TyFunc { params = [ a_ty ]; return = a_ty; is_pure = true }
        in
        let callee_expr = inferred_ident_expr expr callee_name callee_ty in
        Ok (a_ty, inferred_call_expr expr callee_expr [ a' ] a_ty)
  | ("shift_left" | "shift_right") when List.length args = 2 ->
      let a = List.nth args 0 in
      let n = List.nth args 1 in
      let* raw_a_ty, _ = infer_unconstrained_value_expr ctx a in
      let a_slot = Type_widening.bitwise_operand_slot raw_a_ty in
      let a_ty = Type_widening.value_type a_slot in
      if not (is_integer_or_bound raw_a_ty) then
        error loc
          (Printf.sprintf "%s requires an integer first argument, got %s"
             callee_name (type_to_string raw_a_ty))
      else
        let* _actual_a_ty, a' =
          infer_expected_bitwise_operand_expr ctx a_ty a
        in
        let* n_ty, n' =
          infer_expected_bitwise_operand_expr ctx (TyNamed ("Int", [])) n
        in
        if not (ctx_types_compatible ctx (TyNamed ("Int", [])) n_ty) then
          error loc
            (Printf.sprintf "%s requires Int shift amount, got %s" callee_name
               (type_to_string n_ty))
        else
          let callee_ty =
            TyFunc
              {
                params = [ a_ty; TyNamed ("Int", []) ];
                return = a_ty;
                is_pure = true;
              }
          in
          let callee_expr = inferred_ident_expr expr callee_name callee_ty in
          Ok (a_ty, inferred_call_expr expr callee_expr [ a'; n' ] a_ty)
  | _ ->
      error loc (Printf.sprintf "Wrong number of arguments for %s" callee_name)

and infer_type_name ctx expr args loc =
  match args with
  | [ arg ] ->
      let* arg_ty, arg' = infer_unconstrained_value_expr ctx arg in
      if Codegen_types.has_type_vars arg_ty then
        (* Defer: leave as a real call. [Core_specialize] folds it post-mono
           when [arg_ty] is concrete for each monomorphized copy. *)
        let callee_ty = ty_func [ arg_ty ] ty_string ~pure:true in
        let callee' =
          match expr.expr_desc with
          | ECall (c, _) -> with_inferred_type c callee_ty
          | _ -> inferred_ident_expr expr "type_name" callee_ty
        in
        Ok (ty_string, inferred_call_expr expr callee' [ arg' ] ty_string)
      else
        (* Constant-fold: replace type_name(x) with the type string literal *)
        let type_str = type_to_string arg_ty in
        let lit_expr =
          with_inferred_desc expr
            (ELiteral
               (LitString (type_str, { sf_triple = false; sf_raw = false })))
            ty_string
        in
        Ok (ty_string, lit_expr)
  | _ -> error loc "type_name takes exactly 1 argument"

and infer_is_heap ctx expr args loc =
  match args with
  | [ arg ] -> (
      let* arg_ty, arg' = infer_unconstrained_value_expr ctx arg in
      if Codegen_types.has_type_vars arg_ty then
        let callee_ty = ty_func [ arg_ty ] ty_bool ~pure:true in
        let callee' =
          match expr.expr_desc with
          | ECall (c, _) -> with_inferred_type c callee_ty
          | _ -> inferred_ident_expr expr "is_heap" callee_ty
        in
        Ok (ty_bool, inferred_call_expr expr callee' [ arg' ] ty_bool)
      else
        match
          Core_type_layout.classify_debug_heap_value
            (type_layout_metadata_for_env ctx.env)
            arg_ty
        with
        | Core_type_layout.DebugHeapValue ->
            let lit_expr =
              with_inferred_desc expr (ELiteral (LitBool true)) ty_bool
            in
            Ok (ty_bool, lit_expr)
        | Core_type_layout.DebugStackValue ->
            let lit_expr =
              with_inferred_desc expr (ELiteral (LitBool false)) ty_bool
            in
            Ok (ty_bool, lit_expr)
        | Core_type_layout.DebugHeapUnknownNamed name ->
            error loc
              (Printf.sprintf
                 "is_heap cannot classify unknown runtime type '%s'" name)
        | Core_type_layout.DebugHeapInvalidValueType msg -> error loc msg)
  | _ -> error loc "is_heap takes exactly 1 argument"

and infer_assert_shape ctx expr args loc =
  match args with
  | [ tensor_arg; len_arg ] -> (
      let* tensor_ty, tensor' = infer_unconstrained_value_expr ctx tensor_arg in
      let* _len_ty, len' = infer_expected_value_expr ctx ty_int len_arg in
      (* Verify the tensor has variadic dims — assert_shape only refines #N... to #N *)
      match Types.array_parts tensor_ty with
      | Some (elem, [ TyVarDims _ ]) | Some (elem, [ TyVar _ ]) -> (
          (* Extract the expected length from the literal *)
          match len'.expr_desc with
          | ELiteral (LitInt n) when n > 0L ->
              let result_inner =
                Types.ty_array elem [ TyConstInt (Int64.to_int n) ]
              in
              let result_ty = TyNamed ("Option", [ result_inner ]) in
              let callee_expr =
                inferred_ident_expr expr "assert_shape"
                  (ty_func [ tensor_ty; ty_int ] result_ty ~pure:true)
              in
              Ok
                ( result_ty,
                  inferred_call_expr expr callee_expr [ tensor'; len' ]
                    result_ty )
          | _ ->
              error loc
                "assert_shape requires a positive compile-time integer literal \
                 as the expected length")
      | Some _ ->
          error loc
            "assert_shape requires a variadic-dimension tensor (T[#Ds...]) as \
             first argument"
      | _ -> error loc "assert_shape requires an array type as first argument")
  | _ ->
      error loc
        "assert_shape takes exactly 2 arguments: (tensor, expected_length: Int)"

(* checked_get: generic single-index peeling — works on any dimensionality.
   1D -> T, N-D -> T[remaining_dims...].
   Shift-left: dispatch at type-check time. 1D scalar access emits [checked_get]
   (direct data[i] load). N-D peel emits [tensor_peel] — a distinct name core
   codegen rewrites into [blorp_tensor_slice_row] with row_size / result_first_dim
   extracted from the collection's concrete type. Keeps the two semantics
   separable in the IR rather than hidden behind a cast-after-scalar-load. *)
and infer_checked_get ctx expr args loc =
  match args with
  | [ coll_arg; idx_arg ] -> (
      let* coll_ty, coll' = infer_unconstrained_value_expr ctx coll_arg in
      match Types.array_parts coll_ty with
      | Some (elem_ty, dims) when dims <> [] ->
          let first_dim = List.hd dims in
          let remaining = List.tl dims in
          let result_ty =
            match remaining with
            | [] -> elem_ty
            | rest -> Types.ty_array elem_ty rest
          in
          let* validated_idx = validate_index ctx loc idx_arg first_dim coll' in
          (* Distinct callee name when the result is a peeled sub-tensor
              (remaining dims are non-empty). 1D case (remaining = [])
              still uses [checked_get] for direct scalar loads. *)
          let callee_name =
            if remaining = [] then "checked_get" else "tensor_peel"
          in
          let callee_expr =
            inferred_ident_expr expr callee_name
              (ty_func [ coll_ty; ty_int ] result_ty ~pure:true)
          in
          Ok
            ( result_ty,
              inferred_call_expr expr callee_expr [ coll'; validated_idx ]
                result_ty )
      | _ -> (
          match coll_ty with
          | TyNamed ("List", _) ->
              error loc
                "checked_get is not supported on List. Use get(list, index) \
                 for bounds-checked access"
          | TyNamed ("String", _) ->
              error loc
                "checked_get is not supported on String. Use get(str, index) \
                 for bounds-checked access"
          | _ ->
              error loc
                (Printf.sprintf "checked_get requires an array type, got %s"
                   (type_to_string coll_ty))))
  | _ -> error loc "checked_get takes exactly 2 arguments: (tensor, index: Int)"

(* checked_set: 1D element write with COW *)
and infer_checked_set ctx expr args loc =
  match args with
  | [ coll_arg; idx_arg; val_arg ] -> (
      let* coll_ty, coll' = infer_unconstrained_value_expr ctx coll_arg in
      match Types.array_parts coll_ty with
      | Some (elem_ty, dims) when dims <> [] ->
          let first_dim = List.hd dims in
          let* validated_idx = validate_index ctx loc idx_arg first_dim coll' in
          let* val_ty, val' = infer_expected_value_expr ctx elem_ty val_arg in
          if types_compatible ~type_params:[] val_ty elem_ty then begin
            let callee_expr =
              inferred_ident_expr expr "checked_set"
                (ty_func [ coll_ty; ty_int; elem_ty ] coll_ty ~pure:true)
            in
            Ok
              ( coll_ty,
                inferred_call_expr expr callee_expr
                  [ coll'; validated_idx; val' ]
                  coll_ty )
          end
          else
            error loc
              (Printf.sprintf "Cannot assign %s to tensor element of type %s"
                 (type_to_string val_ty) (type_to_string elem_ty))
      | _ ->
          error loc
            (Printf.sprintf "checked_set requires an array type, got %s"
               (type_to_string coll_ty)))
  | _ ->
      error loc
        "checked_set takes exactly 3 arguments: (tensor, index: Int, value)"

(* checked_slice: 1D range slice *)
and infer_checked_slice ctx expr args loc =
  match args with
  | [ coll_arg; start_arg; end_arg ] -> (
      let* coll_ty, coll' = infer_unconstrained_value_expr ctx coll_arg in
      let* _start_ty, start' = infer_expected_value_expr ctx ty_int start_arg in
      let* _end_ty, end' = infer_expected_value_expr ctx ty_int end_arg in
      match Types.array_parts coll_ty with
      | Some (elem_ty, dims) when List.length dims = 1 -> (
          let first_dim = List.hd dims in
          match (start'.expr_desc, end'.expr_desc) with
          | ELiteral (LitInt s), ELiteral (LitInt e) -> (
              let s_int = Int64.to_int s in
              let e_int = Int64.to_int e in
              match first_dim with
              | TyConstInt size ->
                  if s_int < 0 then
                    error loc
                      (Printf.sprintf "Slice start %d is negative" s_int)
                  else if e_int > size then
                    error loc
                      (Printf.sprintf
                         "Slice end %d out of bounds for Tensor of size %d"
                         e_int size)
                  else if s_int >= e_int then
                    error loc
                      (Printf.sprintf "Slice start %d must be less than end %d"
                         s_int e_int)
                  else
                    let slice_size = e_int - s_int in
                    let slice_ty =
                      Types.ty_array elem_ty [ TyConstInt slice_size ]
                    in
                    let callee_expr =
                      inferred_ident_expr expr "checked_slice"
                        (ty_func
                           [ coll_ty; ty_int; ty_int ]
                           slice_ty ~pure:true)
                    in
                    Ok
                      ( slice_ty,
                        inferred_call_expr expr callee_expr
                          [ coll'; start'; end' ] slice_ty )
              | _ ->
                  error loc
                    "Cannot verify slice bounds: dimension is not known at \
                     compile time")
          | _ ->
              error loc
                "checked_slice requires compile-time integer literal start and \
                 end")
      | Some (_, dims) when List.length dims > 1 ->
          error loc "checked_slice is only supported on 1D arrays"
      | _ ->
          error loc
            (Printf.sprintf "checked_slice requires a 1D array, got %s"
               (type_to_string coll_ty)))
  | _ ->
      error loc
        "checked_slice takes exactly 3 arguments: (tensor, start: Int, end: \
         Int)"

(* N-D checked_get: validates all indices and desugars to the right builtin name *)
and infer_nd_checked_get ctx expr coll indices loc =
  let* coll_ty, coll' = infer_unconstrained_value_expr ctx coll in
  let n_indices = List.length indices in
  match Types.array_parts coll_ty with
  | Some (elem_ty, dims) when List.length dims = n_indices ->
      (* Validate each index against its corresponding dimension *)
      let rec check_indices dims_left idxs_left acc_idxs =
        match (dims_left, idxs_left) with
        | [], [] -> Ok (List.rev acc_idxs)
        | dim :: rest_dims, idx :: rest_idxs ->
            let* idx' = validate_index ctx loc idx dim coll' in
            check_indices rest_dims rest_idxs (idx' :: acc_idxs)
        | _ -> error loc "Internal error: index/dimension count mismatch"
      in
      let* validated_indices = check_indices dims indices [] in
      (* Pick the right builtin name based on dimensionality *)
      let func_name =
        match n_indices with
        | 2 -> "matrix_checked_get"
        | 3 -> "tensor3_checked_get"
        | 4 -> "tensor4_checked_get"
        | 5 -> "tensor5_checked_get"
        | _ -> "checked_get" (* 1D fallback *)
      in
      let param_types = coll_ty :: List.init n_indices (fun _ -> ty_int) in
      let callee_expr =
        inferred_ident_expr expr func_name
          (ty_func param_types elem_ty ~pure:true)
      in
      Ok
        ( elem_ty,
          inferred_call_expr expr callee_expr
            (coll' :: validated_indices)
            elem_ty )
  | Some (_, dims) ->
      error loc
        (Printf.sprintf
           "Multi-index subscript has %d indices but array has %d dimensions"
           n_indices (List.length dims))
  | _ ->
      error loc
        (Printf.sprintf
           "Type %s does not support multi-index subscript. Multi-index \
            subscript is supported on array types"
           (type_to_string coll_ty))

(* N-D checked_set: validates indices+value and desugars to assignment *)
and infer_nd_checked_set ctx expr coll indices value loc =
  let* coll_ty, coll' = infer_unconstrained_value_expr ctx coll in
  let n_indices = List.length indices in
  match Types.array_parts coll_ty with
  | Some (elem_ty, dims) ->
      let n_dims = List.length dims in
      if n_indices <> n_dims then
        error loc
          (Printf.sprintf
             "Subscript assignment has %d indices but tensor has %d dimensions"
             n_indices n_dims)
      else begin
        (* Validate each index *)
        let rec check_indices dims_left idxs_left acc_idxs =
          match (dims_left, idxs_left) with
          | [], [] -> Ok (List.rev acc_idxs)
          | dim :: rest_dims, idx :: rest_idxs ->
              let* idx' = validate_index ctx loc idx dim coll' in
              check_indices rest_dims rest_idxs (idx' :: acc_idxs)
          | _ -> error loc "Internal error: index/dimension count mismatch"
        in
        let* validated_indices = check_indices dims indices [] in
        (* Validate value type *)
        let* val_ty, val' = infer_expected_value_expr ctx elem_ty value in
        if not (types_compatible ~type_params:[] val_ty elem_ty) then
          error loc
            (Printf.sprintf "Cannot assign %s to tensor element of type %s"
               (type_to_string val_ty) (type_to_string elem_ty))
        else
          (* Pick the right builtin name *)
          let func_name =
            match n_indices with
            | 1 -> "checked_set"
            | 2 -> "matrix_checked_set"
            | 3 -> "tensor3_checked_set"
            | 4 -> "tensor4_checked_set"
            | 5 -> "tensor5_checked_set"
            | _ -> "checked_set"
          in
          let param_types =
            (coll_ty :: List.init n_indices (fun _ -> ty_int)) @ [ elem_ty ]
          in
          let callee_expr =
            inferred_ident_expr expr func_name
              (ty_func param_types coll_ty ~pure:true)
          in
          let set_call =
            inferred_call_expr expr callee_expr
              ((coll' :: validated_indices) @ [ val' ])
              coll_ty
          in
          (* Desugar to assignment: x = checked_set(x, ...) *)
          match coll.expr_desc with
          | EIdent var_name ->
              Ok
                ( ty_void,
                  with_inferred_desc expr (EAssign (var_name, set_call)) ty_void
                )
          | _ ->
              (* Non-variable target: keep as ESubscriptAssign *)
              Ok
                ( ty_void,
                  with_inferred_desc expr
                    (ESubscriptAssign (coll', validated_indices, val'))
                    ty_void )
      end
  | _ ->
      error loc
        (Printf.sprintf
           "Type %s does not support subscript assignment. Subscript \
            assignment is supported on array types"
           (type_to_string coll_ty))

(* Core N-D checked_set: validates and returns the ECall node (no EAssign wrapping).
   Used by direct calls like matrix_checked_set(...) *)
and infer_nd_checked_set_call ctx expr coll indices val_arg loc =
  let* coll_ty, coll' = infer_unconstrained_value_expr ctx coll in
  let n_indices = List.length indices in
  match Types.array_parts coll_ty with
  | Some (elem_ty, dims) ->
      if List.length dims <> n_indices then
        error loc
          (Printf.sprintf
             "Subscript assignment has %d indices but tensor has %d dimensions"
             n_indices (List.length dims))
      else begin
        let rec check_indices dims_left idxs_left acc_idxs =
          match (dims_left, idxs_left) with
          | [], [] -> Ok (List.rev acc_idxs)
          | dim :: rest_dims, idx :: rest_idxs ->
              let* idx' = validate_index ctx loc idx dim coll' in
              check_indices rest_dims rest_idxs (idx' :: acc_idxs)
          | _ -> error loc "Internal error: index/dimension count mismatch"
        in
        let* validated_indices = check_indices dims indices [] in
        let* val_ty, val' = infer_expected_value_expr ctx elem_ty val_arg in
        if not (types_compatible ~type_params:[] val_ty elem_ty) then
          error loc
            (Printf.sprintf "Cannot assign %s to tensor element of type %s"
               (type_to_string val_ty) (type_to_string elem_ty))
        else
          let func_name =
            match n_indices with
            | 1 -> "checked_set"
            | 2 -> "matrix_checked_set"
            | 3 -> "tensor3_checked_set"
            | 4 -> "tensor4_checked_set"
            | _ -> "tensor5_checked_set"
          in
          let param_types =
            (coll_ty :: List.init n_indices (fun _ -> ty_int)) @ [ elem_ty ]
          in
          let callee_expr =
            inferred_ident_expr expr func_name
              (ty_func param_types coll_ty ~pure:true)
          in
          Ok
            ( coll_ty,
              inferred_call_expr expr callee_expr
                ((coll' :: validated_indices) @ [ val' ])
                coll_ty )
      end
  | _ ->
      error loc
        (Printf.sprintf "Type %s does not support subscript assignment"
           (type_to_string coll_ty))

(* Intercept handlers for direct calls to N-D checked_get/set builtins *)
and infer_matrix_checked_get ctx expr args loc =
  match args with
  | [ coll; idx1; idx2 ] ->
      infer_nd_checked_get ctx expr coll [ idx1; idx2 ] loc
  | _ ->
      error loc
        "matrix_checked_get takes exactly 3 arguments: (matrix, row: Int, col: \
         Int)"

and infer_matrix_checked_set ctx expr args loc =
  match args with
  | coll :: idx1 :: idx2 :: [ val_arg ] ->
      infer_nd_checked_set_call ctx expr coll [ idx1; idx2 ] val_arg loc
  | _ ->
      error loc
        "matrix_checked_set takes exactly 4 arguments: (matrix, row: Int, col: \
         Int, value)"

(* ============================================================================
   Tensor Constructor Inference
   ============================================================================
   Extracted from infer_call to reduce its size. Each handles compile-time
   dimension validation for typed tensor construction. *)

and infer_vector_ctor ctx expr callee args loc =
  let elem_ctx =
    match expected_type_opt ctx with
    | Some expected_ty -> (
        match Types.array_parts expected_ty with
        | Some (elem, _) -> with_expected ctx elem
        | None -> without_expected ctx)
    | _ -> without_expected ctx
  in
  let* val_ty, val' = infer_expr elem_ctx (List.nth args 0) in
  let* _, size' = infer_unconstrained_value_expr ctx (List.nth args 1) in
  match size'.expr_desc with
  | ELiteral (LitInt n) ->
      let result_ty = Types.ty_array val_ty [ TyConstInt (Int64.to_int n) ] in
      let callee' =
        with_inferred_type callee
          (ty_func [ val_ty; ty_int ] result_ty ~pure:true)
      in
      Ok (result_ty, inferred_call_expr expr callee' [ val'; size' ] result_ty)
  | _ -> (
      let dim_from_size =
        match expr_proof_semantic_type_opt size' with
        | Some (TyConstInt n) -> Some (TyConstInt n)
        | Some (TyVar name) when Types.Dim.is_var_name name -> Some (TyVar name)
        | _ ->
            let extract_dim_from_length_call e =
              match e.expr_desc with
              | ECall
                  ( { expr_desc = EIdent ("length" | "vector_length"); _ },
                    [ arg ] ) -> (
                  match expr_proof_semantic_type_opt arg with
                  | Some ty -> (
                      match Types.array_parts ty with
                      | Some (_, dim :: _) -> (
                          match dim with
                          | TyConstInt _ | TyVar _ -> Some dim
                          | _ -> None)
                      | _ -> None)
                  | _ -> None)
              | _ -> None
            in
            extract_dim_from_length_call size'
      in
      match dim_from_size with
      | Some dim ->
          let result_ty = Types.ty_array val_ty [ dim ] in
          let callee' =
            with_inferred_type callee
              (ty_func [ val_ty; ty_int ] result_ty ~pure:true)
          in
          Ok
            ( result_ty,
              inferred_call_expr expr callee' [ val'; size' ] result_ty )
      | None -> (
          (* Fallback: allowed if expected type provides concrete dims.
              Supports patterns like:  N: Int = 200
                                       var v: Float[#200] = vector(0.0, N)
              The type annotation provides the dimension guarantee. *)
          match expected_type_opt ctx with
          | Some expected_ty
            when match Types.array_parts expected_ty with
                 | Some (_, dims) ->
                     dims <> []
                     && List.for_all
                          (function TyVarDims _ -> false | _ -> true)
                          dims
                 | None -> false ->
              let callee' =
                with_inferred_type callee
                  (ty_func [ val_ty; ty_int ] expected_ty ~pure:true)
              in
              Ok
                ( expected_ty,
                  inferred_call_expr expr callee' [ val'; size' ] expected_ty )
          | _ ->
              error loc
                "vector() requires a compile-time constant size (use a literal \
                 or a #N dim parameter)"))

(** matrix(value, rows, cols): 2D constructor. Dims must be compile-time constants. *)
and infer_matrix_ctor ctx expr callee args loc =
  let elem_ctx =
    match expected_type_opt ctx with
    | Some expected_ty -> (
        match Types.array_parts expected_ty with
        | Some (elem, _) -> with_expected ctx elem
        | None -> without_expected ctx)
    | _ -> without_expected ctx
  in
  let* val_ty, val' = infer_expr elem_ctx (List.nth args 0) in
  let* _, d1' = infer_unconstrained_value_expr ctx (List.nth args 1) in
  let* _, d2' = infer_unconstrained_value_expr ctx (List.nth args 2) in
  match (d1'.expr_desc, d2'.expr_desc) with
  | ELiteral (LitInt r), ELiteral (LitInt c) ->
      let result_ty =
        Types.ty_array val_ty
          [ TyConstInt (Int64.to_int r); TyConstInt (Int64.to_int c) ]
      in
      let param_tys = [ val_ty; ty_int; ty_int ] in
      let callee' =
        with_inferred_type callee (ty_func param_tys result_ty ~pure:true)
      in
      Ok
        (result_ty, inferred_call_expr expr callee' [ val'; d1'; d2' ] result_ty)
  | _ -> (
      match expected_type_opt ctx with
      | Some expected_ty
        when match Types.array_parts expected_ty with
             | Some (_, dims) ->
                 List.length dims = 2
                 && List.for_all
                      (function TyVarDims _ -> false | _ -> true)
                      dims
             | None -> false ->
          let param_tys = [ val_ty; ty_int; ty_int ] in
          let callee' =
            with_inferred_type callee (ty_func param_tys expected_ty ~pure:true)
          in
          Ok
            ( expected_ty,
              inferred_call_expr expr callee' [ val'; d1'; d2' ] expected_ty )
      | _ ->
          error loc
            "matrix() requires compile-time constant dimensions (use literals \
             or #N dim parameters)")

(** tensor3/4/5(value, dim...): N-dimensional constructors with compile-time dims. *)
and infer_tensorN_ctor ctx expr callee name args loc =
  let ndims = match name with "tensor3" -> 3 | "tensor4" -> 4 | _ -> 5 in
  if List.length args <> ndims + 1 then
    error loc
      (Printf.sprintf "%s takes %d arguments (value + %d dimensions)" name
         (ndims + 1) ndims)
  else begin
    let elem_ctx =
      match expected_type_opt ctx with
      | Some expected_ty -> (
          match Types.array_parts expected_ty with
          | Some (elem, _) -> with_expected ctx elem
          | None -> without_expected ctx)
      | _ -> without_expected ctx
    in
    let* val_ty, val' = infer_expr elem_ctx (List.hd args) in
    let dim_args = List.tl args in
    let* dim_results =
      List.fold_left
        (fun acc arg ->
          let* acc = acc in
          let* _, arg' = infer_unconstrained_value_expr ctx arg in
          match arg'.expr_desc with
          | ELiteral (LitInt n) ->
              Ok (acc @ [ (TyConstInt (Int64.to_int n), arg') ])
          | _ ->
              error loc
                (Printf.sprintf "%s() requires compile-time constant dimensions"
                   name))
        (Ok []) dim_args
    in
    let dims = List.map fst dim_results in
    let dim_exprs = List.map snd dim_results in
    let result_ty = Types.ty_array val_ty dims in
    let param_tys = val_ty :: List.init ndims (fun _ -> ty_int) in
    let callee' =
      with_inferred_type callee (ty_func param_tys result_ty ~pure:true)
    in
    Ok (result_ty, inferred_call_expr expr callee' (val' :: dim_exprs) result_ty)
  end

(* ============================================================================
   Builtin Inference Registry (Phase 5.2)
   ============================================================================
   [dispatch_builtin_inference] is a single place that routes a bare-name
   builtin call to its specialized inference handler. Before 5.2 each arm
   lived as an [EIdent "name" when Env.is_builtin_func ctx.env "name" -> …]
   clause inline in [infer_call]; adding a new builtin required inserting a
   guard-laden match arm, and the [Env.is_builtin_func] check was copy-
   pasted 16 times. The registry now applies that guard uniformly in
   [infer_call]; handlers here just branch on [(name, arity)] and call the
   existing [infer_*] helpers.

   Returns [None] when [name] isn't a recognized builtin — [infer_call]
   falls through to the generic call path. Returns [Some _] with either
   the successful inference result or a structured error. *)

and dispatch_builtin_inference ctx expr callee name args loc :
    (type_expr * expr) infer_result option =
  let argc = List.length args in
  match Builtin_metadata.special_inference name with
  | Some Checked_get -> Some (infer_checked_get ctx expr args loc)
  | Some Checked_set -> Some (infer_checked_set ctx expr args loc)
  | Some Checked_slice -> Some (infer_checked_slice ctx expr args loc)
  | Some Matrix_checked_get -> Some (infer_matrix_checked_get ctx expr args loc)
  | Some Matrix_checked_set -> Some (infer_matrix_checked_set ctx expr args loc)
  | Some (Tensor_checked_get n) ->
      if argc = n + 1 then
        Some (infer_nd_checked_get ctx expr (List.hd args) (List.tl args) loc)
      else
        Some (error loc (Printf.sprintf "%s takes %d arguments" name (n + 1)))
  | Some (Tensor_checked_set n) ->
      if argc = n + 2 then
        let coll = List.hd args in
        let rest = List.tl args in
        let indices = List.filteri (fun i _ -> i < n) rest in
        let val_arg = List.nth rest n in
        Some (infer_nd_checked_set_call ctx expr coll indices val_arg loc)
      else
        Some (error loc (Printf.sprintf "%s takes %d arguments" name (n + 2)))
  | Some Assert_shape -> Some (infer_assert_shape ctx expr args loc)
  | Some Length_refined when argc = 1 ->
      Some (infer_length_refined ctx expr callee args loc)
  | Some Type_name when argc = 1 -> Some (infer_type_name ctx expr args loc)
  | Some Is_heap when argc = 1 -> Some (infer_is_heap ctx expr args loc)
  | Some Vector_ctor when argc = 2 ->
      Some (infer_vector_ctor ctx expr callee args loc)
  | Some Matrix_ctor when argc = 3 ->
      Some (infer_matrix_ctor ctx expr callee args loc)
  | Some (Tensor_ctor _) ->
      Some (infer_tensorN_ctor ctx expr callee name args loc)
  | Some Bitwise -> Some (infer_bitwise_call ctx expr name args loc)
  | Some Length_refined
  | Some Type_name
  | Some Is_heap
  | Some Vector_ctor
  | Some Matrix_ctor ->
      None
  | _ -> None

and refined_length_return_type arg_ty =
  match Types.array_parts arg_ty with
  | Some (_, dim :: _) -> (
      match dim with
      | TyConstInt _ -> Some dim
      | TyVar name when Types.Dim.is_var_name name -> Some dim
      | _ -> None)
  | _ -> None

(** [length]/[vector_length] with a tensor arg: refine the return type to
    the dim type (#N / #3000) instead of plain Int. Enables
    [vector(0.0, length(v))] to infer the correct dimension. *)
and infer_length_refined ctx expr callee args loc =
  let arg = List.hd args in
  let* arg_ty, arg' = infer_unconstrained_value_expr ctx arg in
  let* () =
    if is_parallel_list_type arg_ty then
      error loc
        (Printf.sprintf "No function 'length' available for type %s"
           (type_to_string arg_ty))
    else check_trait_bound_on_arg ctx ~is_builtin:true "length" arg_ty loc
  in
  let dim_ty = refined_length_return_type arg_ty in
  let ret_ty = match dim_ty with Some d -> d | None -> ty_int in
  let callee' =
    with_inferred_type callee (ty_func [ arg_ty ] ret_ty ~pure:true)
  in
  Ok (ret_ty, inferred_call_expr expr callee' [ arg' ] ret_ty)

and debug_only_name_for_callee ctx callee =
  match callee.expr_desc with
  | EIdent name
    when Env.is_debug_only_func ctx.env name
         || Env.is_debug_only_overload_set ctx.env name ->
      Some name
  | EFieldAccess ({ expr_desc = EIdent alias; _ }, func_name) -> (
      match List.assoc_opt alias ctx.module_aliases with
      | Some module_path
        when Modules.exported_func_is_debug_only module_path func_name ->
          Some func_name
      | _ -> None)
  | _ -> None

and reject_debug_only_callee ctx callee =
  if ctx.allow_debug_only_calls || ctx.in_debug_context then Ok ()
  else
    match debug_only_name_for_callee ctx callee with
    | None -> Ok ()
    | Some name ->
        error_with ~notes:[]
          ~help:
            (Some
               "Wrap the diagnostic call in a debug: block, compile with \
                --debug, or keep direct reflection assertions in blorp test \
                code")
          callee.expr_loc
          (Printf.sprintf
             "debug-only function '%s' can only be used inside a debug: block"
             name)

(* ============================================================================
   Call Inference — Main Dispatcher
   ============================================================================ *)

and infer_call ctx expr callee args loc =
  let* () = reject_debug_only_callee ctx callee in
  let infer_new_type_constructor name =
    match Env.get_new_type_constructor ctx.env name with
    | None -> None
    | Some (resolved_name, type_params, target_ty) ->
        let result =
          match args with
          | [ arg ] ->
              let* arg_ty, arg' =
                infer_expected_argument_expr ctx target_ty arg
              in
              let target_ty_r =
                normalize_type ctx ArgumentCompatibility target_ty
              in
              let arg_ty_r =
                normalize_type ctx ArgumentCompatibility
                  (expr_value_type_or arg' arg_ty)
              in
              if types_compatible ~type_params target_ty_r arg_ty_r then
                let subst = build_subst ~type_params target_ty_r arg_ty_r in
                let args =
                  List.map
                    (fun param -> apply_subst subst (TyVar param))
                    type_params
                in
                let ret_ty = TyNamed (resolved_name, args) in
                Ok (ret_ty, with_inferred_type arg' ret_ty)
              else
                let message =
                  Printf.sprintf
                    "Argument type mismatch: in call to '%s', argument 1 \
                     expected %s, got %s"
                    name
                    (type_to_string target_ty_r)
                    (type_to_string arg_ty_r)
                in
                error arg.expr_loc message
          | _ ->
              error loc
                (Printf.sprintf
                   "new type constructor '%s' expects 1 argument, got %d" name
                   (List.length args))
        in
        Some result
  in
  match callee.expr_desc with
  | EIdent name -> (
      match infer_new_type_constructor name with
      | Some result -> result
      | None -> infer_call_after_new_type ctx expr callee args loc)
  | EFieldAccess (obj, "value") when args = [] -> (
      match infer_unconstrained_value_expr ctx obj with
      | Ok (obj_ty, obj') -> (
          match Env.new_type_underlying ctx.env obj_ty with
          | Some underlying ->
              Ok (underlying, with_inferred_type obj' underlying)
          | None -> infer_call_after_new_type ctx expr callee args loc)
      | Error _ -> infer_call_after_new_type ctx expr callee args loc)
  | _ -> infer_call_after_new_type ctx expr callee args loc

and infer_call_after_new_type ctx expr callee args loc =
  (* Builtin inference dispatch — registry shape (Phase 5.2, 2026-04-21).
     [dispatch_builtin_inference] returns [Some result] when [name] is a
     recognized builtin (and [Env.is_builtin_func] confirms the user hasn't
     shadowed it), [None] otherwise. On [None] we fall through to the
     generic call path below. When Phase 3.1 / 3.2 / 5.3 add trait-aware /
     operator-overload / refinement-aware builtins, each becomes a one-line
     addition in [dispatch_builtin_inference]. *)
  let builtin_result =
    match callee.expr_desc with
    | EIdent name when Env.is_builtin_func ctx.env name ->
        dispatch_builtin_inference ctx expr callee name args loc
    (* [type_name] / [is_heap] live in [std/debug] but need compile-time
       constant-folding at the call site regardless of how they were
       resolved (the bodies are [builtin], so without folding the
       generated C would reference a non-existent [type_name] symbol).
       Fire the dispatcher whenever the name resolves at all. *)
    | EIdent (("type_name" | "is_heap") as name)
      when Env.lookup ctx.env name <> None ->
        dispatch_builtin_inference ctx expr callee name args loc
    | _ -> None
  in
  match builtin_result with
  | Some result -> result
  | None -> (
      let is_flexible_lambda_arg arg =
        match arg.expr_desc with
        | ELambda f when not f.func_is_pure -> true
        | _ -> false
      in
      let overload_pure_callback_count (entry : Env.overload_entry) =
        match entry.ol_func_type with
        | TyFunc { params; _ } ->
            List.fold_left
              (fun acc param_ty ->
                match param_ty with
                | TyFunc { is_pure = true; _ } -> acc + 1
                | _ -> acc)
              0 params
        | _ -> 0
      in
      let select_pure_overload_for_flexible_lambdas
          (entries : Env.overload_entry list) (arg_exprs : expr list) :
          Env.overload_entry option =
        if not (List.exists is_flexible_lambda_arg arg_exprs) then None
        else
          let arg_satisfies_param entry subst arg param_ty =
            let param_ty = apply_subst subst param_ty in
            let arg_result =
              match expr_semantic_type_opt arg with
              | Some ty -> Ok (ty, arg)
              | None -> infer_expected_argument_expr ctx param_ty arg
            in
            match arg_result with
            | Error _ -> None
            | Ok (arg_ty, _) ->
                let param_ty_r =
                  normalize_type ctx ArgumentCompatibility param_ty
                in
                let arg_value_ty = expr_value_type_or arg arg_ty in
                let arg_ty_r =
                  default_arg_type_for_param param_ty_r
                    (normalize_type ctx ArgumentCompatibility arg_value_ty)
                in
                if
                  types_compatible
                    ~type_params:(Env.overload_type_param_names entry)
                    param_ty_r arg_ty_r
                then
                  Some
                    (subst
                    @ build_subst
                        ~type_params:(Env.overload_type_param_names entry)
                        param_ty_r arg_ty_r)
                else None
          in
          let entry_accepts_args entry =
            match entry.Env.ol_func_type with
            | TyFunc { params; _ }
              when List.length params = List.length arg_exprs ->
                let rec loop subst params args =
                  match (params, args) with
                  | [], [] -> true
                  | param_ty :: rest_params, arg :: rest_args -> (
                      match arg_satisfies_param entry subst arg param_ty with
                      | Some subst' -> loop subst' rest_params rest_args
                      | None -> false)
                  | _ -> false
                in
                loop [] params arg_exprs
            | _ -> false
          in
          let pure_matches =
            entries
            |> List.filter (fun entry -> entry.Env.ol_purity = Env.Pure)
            |> List.filter entry_accepts_args
          in
          match pure_matches with
          | [] -> None
          | [ single ] -> Some single
          | many -> (
              let sorted =
                List.sort
                  (fun a b ->
                    compare
                      (overload_pure_callback_count b)
                      (overload_pure_callback_count a))
                  many
              in
              match sorted with
              | best :: rest
                when not
                       (List.exists
                          (fun entry ->
                            overload_pure_callback_count entry
                            = overload_pure_callback_count best)
                          rest) ->
                  Some best
              | _ -> None)
      in
      (* Method-call rewriting: obj.method(args) → method(obj, args)
     When callee is EFieldAccess(obj, name), try field access first (record fields
     that are functions). If that fails AND obj is a valid value expression (not a
     module alias), try rewriting as a function call with obj prepended to args.
     If neither works, return the original field access error so existing error
     filters handle it gracefully for unresolved imports. *)
      let* callee_ty, callee', callee, args =
        match callee.expr_desc with
        | EFieldAccess (obj, method_name) -> (
            (* Module-qualified impl-method dispatch: before plain field-access
           inference, check if [obj] is a module alias AND the field names a
           trait-impl method in that module. If so, rewrite the callee to
           the impl's mangled name. Runs first because [infer_field_access]
           has a successful fallback path (via bare-identifier lookup) that
           would otherwise swallow the case and leave the [EFieldAccess]
           structure intact — producing [V->to_string] in generated C. *)
            let impl_first =
              let alias_name =
                match obj.expr_desc with EIdent n -> Some n | _ -> None
              in
              let mod_path =
                match alias_name with
                | Some name -> List.assoc_opt name ctx.module_aliases
                | None -> None
              in
              match mod_path with
              | None -> None
              | Some mp -> (
                  match args with
                  | first :: _ -> (
                      match infer_unconstrained_value_expr ctx first with
                      | Ok (first_ty, first') -> (
                          match
                            lookup_module_impl_method mp method_name first_ty
                          with
                          | Some (mangled, callee_ty) ->
                              let mangled_ident =
                                inferred_ident_expr callee mangled callee_ty
                              in
                              let args' = first' :: List.tl args in
                              Some
                                (callee_ty, mangled_ident, mangled_ident, args')
                          | None -> None)
                      | Error _ -> None)
                  | [] -> None)
            in
            match impl_first with
            | Some (callee_ty, callee', ident, args') ->
                Ok (callee_ty, callee', ident, args')
            | None -> (
                match infer_unconstrained_value_expr ctx callee with
                | Ok (callee_ty, callee') ->
                    Ok (callee_ty, callee', callee, args)
                | Error original_err -> (
                    (* Field access failed. Only try method-call rewrite if obj is a
                valid value (not a module alias). Module aliases like Dict, O, Str
                aren't in the value env, so infer_expr on them would fail. *)
                    match infer_unconstrained_value_expr ctx obj with
                    | Error _ -> (
                        (* obj isn't a value — check if it's a module alias (qualified call) *)
                        let alias_name =
                          match obj.expr_desc with
                          | EIdent name -> Some name
                          | _ -> None
                        in
                        let module_path =
                          match alias_name with
                          | Some name -> List.assoc_opt name ctx.module_aliases
                          | None -> None
                        in
                        match module_path with
                        | Some mod_path -> (
                            (* Module alias — look up function type from module's exports *)
                            let ident =
                              { callee with expr_desc = EIdent method_name }
                            in
                            match
                              lookup_module_func_type mod_path method_name
                            with
                            | Some callee_ty ->
                                let callee' =
                                  with_inferred_type callee callee_ty
                                in
                                Ok (callee_ty, callee', ident, args)
                            | None -> (
                                (* Not a top-level function. Before erroring, try
                               resolving against the module's trait impls: if
                               [M] declares [implements Trait for Foo:] and
                               [method_name] is one of the impl's methods,
                               dispatch on the first arg's type. Lets stdlib
                               migrate top-level functions into proper
                               [implements] blocks without breaking existing
                               [M.method(value)] callers. *)
                                let impl_result =
                                  match args with
                                  | first :: _ -> (
                                      match
                                        infer_unconstrained_value_expr ctx first
                                      with
                                      | Ok (first_ty, first') -> (
                                          match
                                            lookup_module_impl_method mod_path
                                              method_name first_ty
                                          with
                                          | Some (mangled, callee_ty) ->
                                              let mangled_ident =
                                                inferred_ident_expr callee
                                                  mangled callee_ty
                                              in
                                              (* Replace args' first with the already-inferred [first'] to
                                               avoid re-inferring it downstream. *)
                                              let args' =
                                                first' :: List.tl args
                                              in
                                              Some
                                                (Ok
                                                   ( callee_ty,
                                                     mangled_ident,
                                                     mangled_ident,
                                                     args' ))
                                          | None -> None)
                                      | Error _ -> None)
                                  | [] -> None
                                in
                                match impl_result with
                                | Some r -> r
                                | None -> (
                                    (* Not in exports, no impl — try env as fallback for constructors etc *)
                                    match
                                      infer_unconstrained_value_expr ctx ident
                                    with
                                    | Ok (callee_ty, _callee') ->
                                        let qualified_callee =
                                          with_inferred_type callee callee_ty
                                        in
                                        Ok
                                          ( callee_ty,
                                            qualified_callee,
                                            ident,
                                            args )
                                    | Error _ ->
                                        let mod_name =
                                          match alias_name with
                                          | Some n -> n
                                          | None -> "<unknown>"
                                        in
                                        let help =
                                          match
                                            Modules.find_cached mod_path
                                          with
                                          | Some m ->
                                              Modules.suggest_export m
                                                method_name
                                          | None -> None
                                        in
                                        error_with ~notes:[] ~help loc
                                          (Printf.sprintf
                                             "Module '%s' has no exported \
                                              function '%s'"
                                             mod_name method_name))))
                        | None ->
                            (* Not a module alias — return original error *)
                            Error original_err)
                    | Ok (_, obj') -> (
                        (* obj is a value — try method-call rewrite *)
                        let receiver_arg = annotate_method_receiver_expr obj' in
                        let ident =
                          { callee with expr_desc = EIdent method_name }
                        in
                        let normal_result =
                          match infer_unconstrained_value_expr ctx ident with
                          | Ok (callee_ty, callee') ->
                              (* Check if the resolved function can actually
                                 accept the receiver as its first argument. If
                                 not, try UFCS-only methods. *)
                              let first_param_matches =
                                let obj_ty =
                                  match expr_semantic_type_opt obj' with
                                  | Some t -> t
                                  | None -> ty_void
                                in
                                let builtin_trait_accepts_receiver () =
                                  match
                                    ( Env.is_builtin_func ctx.env method_name,
                                      Env.get_function_trait ctx.env method_name
                                    )
                                  with
                                  | true, Some trait_name ->
                                      trait_obligation_satisfied ctx.env obj_ty
                                        trait_name
                                  | _ -> true
                                in
                                let normal_function_type_params =
                                  match
                                    Env.get_func_info ctx.env method_name
                                  with
                                  | Some (_, type_params, _) ->
                                      Env.bound_type_param_names type_params
                                  | None -> Env.get_type_params ctx.env
                                in
                                let receiver_family = function
                                  | TyNamed (name, _) -> Some name
                                  | TyArray _ -> Some Types.array_head_name
                                  | _ -> None
                                in
                                match callee_ty with
                                | TyFunc { params = first_param :: _; _ } -> (
                                    let first_param =
                                      normalize_type ctx UfcsCandidateFiltering
                                        first_param
                                    in
                                    let obj_ty =
                                      normalize_type ctx UfcsCandidateFiltering
                                        obj_ty
                                    in
                                    (* Generic builtin trait functions like
                                       [length(T)] are only valid method
                                       candidates when the receiver satisfies
                                       the trait.

                                       For non-trait functions, this is a
                                       prefilter rather than final argument
                                       checking: same-family named receivers may
                                       still contain unresolved type args at
                                       this phase, but cross-family candidates
                                       like tensor get on List should fall
                                       through to UFCS-only methods. *)
                                    if
                                      Env.is_builtin_func ctx.env method_name
                                      && Option.is_some
                                           (Env.get_function_trait ctx.env
                                              method_name)
                                    then builtin_trait_accepts_receiver ()
                                    else
                                      match
                                        ( receiver_family first_param,
                                          receiver_family obj_ty )
                                      with
                                      | Some param_family, Some obj_family ->
                                          param_family = obj_family
                                      | _ ->
                                          types_compatible
                                            ~type_params:
                                              normal_function_type_params
                                            first_param obj_ty)
                                | _ -> false
                              in
                              if first_param_matches then
                                Some
                                  (Ok
                                     ( callee_ty,
                                       callee',
                                       ident,
                                       receiver_arg :: args ))
                              else None (* Type mismatch — try UFCS methods *)
                          | Error _ -> None
                        in
                        match normal_result with
                        | Some r -> r
                        | None -> (
                            (* Method not in normal scope or type mismatch — check UFCS-only methods
                          (auto-imported when a type is imported from a module) *)
                            let obj_ty =
                              match expr_semantic_type_opt obj' with
                              | Some t -> t
                              | None -> ty_void
                            in
                            let ufcs_matches =
                              Env.lookup_ufcs_methods ctx.env method_name obj_ty
                            in
                            match ufcs_matches with
                            | _ :: _ -> (
                                (* Found UFCS method(s) — use mangled names to avoid
                              conflicts with the current module's own functions.
                              E.g., list's get becomes __ufcs_std$list__get
                              Uses $ for path separators to avoid ambiguity with _ in names *)
                                (* Phase 2.7 tasks 48/49: when pure/impure overloads
                              exist, try to pick by callback purity — but ONLY
                              when every function-typed arg has a firm purity
                              (i.e. a named [func]/[pure func] reference).
                              Lambdas without [pure] are purity-flexible:
                              [infer_lambda] upgrades them to pure when the
                              call-site expects pure; resolving them too early
                              forces impure and breaks stdlib call sites like
                              [entries(self).sort_by(func(p): p.0)] where the
                              lambda would upgrade. If any arg is a flexible
                              lambda OR any arg fails standalone inference,
                              fall back to the caller-context preference
                              (pure in pure scope, impure otherwise). *)
                                let has_flexible_lambda =
                                  List.exists
                                    (fun a ->
                                      match a.expr_desc with
                                      | ELambda f when not f.func_is_pure ->
                                          true
                                      | _ -> false)
                                    args
                                in
                                let selected =
                                  match
                                    select_pure_overload_for_flexible_lambdas
                                      ufcs_matches (receiver_arg :: args)
                                  with
                                  | Some entry -> Some entry
                                  | None -> (
                                      if has_flexible_lambda then None
                                      else
                                        let arg_tys_opt =
                                          List.map
                                            (fun a ->
                                              match
                                                expr_semantic_type_opt a
                                              with
                                              | Some ty -> Some ty
                                              | None -> (
                                                  match
                                                    infer_unconstrained_value_expr
                                                      ctx a
                                                  with
                                                  | Ok (ty, _) -> Some ty
                                                  | Error _ -> None))
                                            (receiver_arg :: args)
                                        in
                                        match all_some arg_tys_opt with
                                        | Some arg_tys ->
                                            Env.select_overload_for_args
                                              ufcs_matches arg_tys
                                        | None -> None)
                                in
                                let in_pure_ctx =
                                  ctx.env.current_function_pure
                                in
                                let mod_path =
                                  match selected with
                                  | Some entry -> (
                                      match entry.Env.ol_module_path with
                                      | Some p -> p
                                      | None -> "")
                                  | None -> (
                                      match
                                        (List.hd ufcs_matches)
                                          .Env.ol_module_path
                                      with
                                      | Some p -> p
                                      | None -> "")
                                in
                                let base_mangled =
                                  "__ufcs_"
                                  ^ String.map
                                      (fun c -> if c = '/' then '$' else c)
                                      mod_path
                                  ^ "__" ^ method_name
                                in
                                (* A3.3 UFCS handoff: encode the selected
                              overload's [ol_def_id] directly in the
                              mangled identifier as a ["#<id>"] suffix.
                              [Core_lower] strips the suffix into
                              [Core.var.vdef_id], letting downstream
                              passes recover the exact overload identity
                              without a session-level side-channel. Two
                              call sites that select *different*
                              overloads of the same name produce
                              distinct mangled identifiers here (suffix
                              differs), so they never collide — the
                              earlier [Session.ufcs_def_ids] hashtable
                              was keyed on the unsuffixed form and
                              last-write-wins produced wrong-body
                              mangling for pure/impure pairs. *)
                                let mangled =
                                  match selected with
                                  | Some entry ->
                                      Printf.sprintf "%s#%d" base_mangled
                                        entry.Env.ol_def_id
                                  | None -> base_mangled
                                in
                                (* When selection is firm, [mangled] already
                              includes [entry]'s def_id, so only [entry]
                              belongs under that name in the temp env —
                              registering other overloads there would
                              invite spurious resolution between
                              distinct IDs. *)
                                let to_register =
                                  match selected with
                                  | Some entry -> [ entry ]
                                  | None ->
                                      if in_pure_ctx then
                                        (* In pure context: put pure overloads last (found first by lookup) *)
                                        List.sort
                                          (fun a b ->
                                            match
                                              (a.Env.ol_purity, b.Env.ol_purity)
                                            with
                                            | Env.Pure, Env.Impure -> 1
                                            | Env.Impure, Env.Pure -> -1
                                            | _ -> 0)
                                          ufcs_matches
                                      else
                                        (* In impure context: put impure overloads last (found first by lookup) *)
                                        List.sort
                                          (fun a b ->
                                            match
                                              (a.Env.ol_purity, b.Env.ol_purity)
                                            with
                                            | Env.Impure, Env.Pure -> 1
                                            | Env.Pure, Env.Impure -> -1
                                            | _ -> 0)
                                          ufcs_matches
                                in
                                let temp_env =
                                  List.fold_left
                                    (fun env e ->
                                      Env.add_func env mangled
                                        e.Env.ol_func_type
                                        ~type_params:e.Env.ol_type_params
                                        ~param_names:e.ol_param_names
                                        ~purity:e.ol_purity ~origin:e.ol_origin
                                        ?module_path:e.ol_module_path
                                        ~dim_constraints:e.ol_dim_constraints
                                        ?loop_producer:e.ol_loop_producer
                                        ~debug_only:e.ol_debug_only ())
                                    ctx.env to_register
                                in
                                let temp_ctx = { ctx with env = temp_env } in
                                let ident2 =
                                  { callee with expr_desc = EIdent mangled }
                                in
                                match
                                  infer_expr (without_expected temp_ctx) ident2
                                with
                                | Ok (callee_ty, callee') ->
                                    Ok
                                      ( callee_ty,
                                        callee',
                                        ident2,
                                        receiver_arg :: args )
                                | Error e -> Error e)
                            | [] ->
                                (* No UFCS method either — give helpful error *)
                                let obj_ty_str =
                                  match expr_semantic_type_opt obj' with
                                  | Some ty -> type_to_string ty
                                  | None -> "this value"
                                in
                                let ufcs_hint =
                                  match
                                    renamed_string_method_hint obj_ty_str
                                      method_name
                                  with
                                  | Some hint -> hint
                                  | None ->
                                      if Env.has_ufcs_method ctx.env method_name
                                      then
                                        Printf.sprintf
                                          "'%s' is available as a method on \
                                           other types but not %s"
                                          method_name obj_ty_str
                                      else
                                        Printf.sprintf
                                          "method syntax `value.%s(...)` is \
                                           shorthand for `%s(value, ...)` — \
                                           ensure '%s' is imported"
                                          method_name method_name method_name
                                in
                                error_with
                                  ~notes:
                                    [
                                      Printf.sprintf
                                        "'%s' is not defined in the current \
                                         scope"
                                        method_name;
                                    ]
                                  ~help:(Some ufcs_hint) loc
                                  (Printf.sprintf
                                     "No function '%s' available for type %s"
                                     method_name obj_ty_str))))))
        | _ ->
            let* callee_ty, callee' =
              infer_unconstrained_value_expr ctx callee
            in
            Ok (callee_ty, callee', callee, args)
      in
      (* Overload resolution: when multiple signatures exist for a name,
     use the argument types to select the correct one. Phase 2.7 tasks
     48/49 — paired pure/impure overloads of HOFs like list.map /
     list.flat_map. After the [EFieldAccess]→[EIdent] rewrite above,
     method-syntax calls land here too, so this path is on the hot
     line for [nums.flat_map(impure_helper)]-style tests.

     Skip the full-args tiebreak when any arg is a purity-flexible
     lambda — see the matching comment in the UFCS path. Fall back
     to first-arg-only resolution in that case to preserve the lambda
     purity-upgrade pathway in [infer_lambda]. *)
      let callee_ty, callee', resolved_overload =
        let name =
          match callee.expr_desc with EIdent n -> Some n | _ -> None
        in
        let from_entry entry =
          ( entry.Env.ol_func_type,
            with_inferred_type callee' entry.Env.ol_func_type,
            Some entry )
        in
        match name with
        | Some n ->
            let overloads = Env.get_overloads ctx.env n in
            if Env.is_local_func ctx.env n then (callee_ty, callee', None)
            else if List.length overloads > 1 && args <> [] then
              let has_flexible_lambda =
                List.exists
                  (fun a ->
                    match a.expr_desc with
                    | ELambda f when not f.func_is_pure -> true
                    | _ -> false)
                  args
              in
              let inferred =
                List.map
                  (fun a ->
                    match infer_unconstrained_value_expr ctx a with
                    | Ok (ty, _) -> Some ty
                    | Error _ -> None)
                  args
              in
              let try_with_args () =
                if has_flexible_lambda then None
                else
                  match all_some inferred with
                  | Some arg_tys ->
                      Env.select_overload_for_args overloads arg_tys
                  | None -> None
              in
              let try_with_first_arg () =
                match inferred with
                | Some first_arg_ty :: _ ->
                    Env.resolve_overload ctx.env n first_arg_ty
                | _ -> None
              in
              (* Fall back to context-purity bias when the arg-based resolvers
             are stuck (ambiguous first-arg head + flexible lambda). Mirrors
             the UFCS path's fallback above: impure callers prefer impure
             overloads, pure callers prefer pure. Only applies when the
             overload set is a pure/impure pair for the SAME receiver type
             (map/filter/flat_map etc. from std/list.brp) — not when the
             overloads come from different modules (length across
             List/String/Set, where the correct pick is by first-arg type). *)
              let try_by_context_purity () =
                let head_name ty =
                  match ty with TyNamed (n, _) -> Some n | _ -> None
                in
                let overloads =
                  match inferred with
                  | Some first_arg_ty :: _ ->
                      let first_arg_head = head_name first_arg_ty in
                      List.filter
                        (fun (entry : Env.overload_entry) ->
                          match entry.ol_func_type with
                          | TyFunc { params = first_param :: _; _ } -> (
                              match (head_name first_param, first_arg_head) with
                              | Some pn, Some an -> pn = an
                              | None, _ ->
                                  Types.types_compatible
                                    ~type_params:
                                      (Env.overload_type_param_names entry)
                                    first_param first_arg_ty
                              | _ -> false)
                          | _ -> false)
                        overloads
                  | _ -> overloads
                in
                match overloads with
                | [ a; b ] when a.Env.ol_purity <> b.Env.ol_purity ->
                    let same_receiver =
                      match (a.ol_func_type, b.ol_func_type) with
                      | ( TyFunc { params = ap :: _; _ },
                          TyFunc { params = bp :: _; _ } ) -> (
                          match (head_name ap, head_name bp) with
                          | Some an, Some bn -> an = bn
                          | None, None -> true (* both generic — likely T *)
                          | _ -> false)
                      | _ -> false
                    in
                    if not same_receiver then None
                    else
                      let pref =
                        if ctx.env.current_function_pure then Env.Pure
                        else Env.Impure
                      in
                      List.find_opt (fun e -> e.Env.ol_purity = pref) overloads
                | _ -> None
              in
              match try_with_args () with
              | Some entry -> from_entry entry
              | None -> (
                  match
                    select_pure_overload_for_flexible_lambdas overloads args
                  with
                  | Some entry -> from_entry entry
                  | None -> (
                      match try_with_first_arg () with
                      | Some entry -> from_entry entry
                      | None -> (
                          match try_by_context_purity () with
                          | Some entry -> from_entry entry
                          | None -> (callee_ty, callee', None))))
            else (callee_ty, callee', None)
        | None -> (callee_ty, callee', None)
      in
      (* Trait method dispatch for type variable arguments:
     If the first argument is a type variable with trait bounds, and the callee
     matches a trait method, re-resolve the callee type using the trait method
     signature with Self→T substitution. This enables generic code like:
       func safe_div[T: Integer](a: T, b: T) -> Option[T]: checked_div(a, b) *)
      let callee_ty, callee' =
        let try_trait_dispatch param_name param_ty func_name =
          match
            Env.find_trait_method_for_param ctx.env param_name func_name
          with
          | Some (method_sig, _trait_name) ->
              let resolved = Env.get_resolved_method_sig method_sig param_ty in
              let new_ty =
                TyFunc
                  {
                    params = resolved.tm_params;
                    return = resolved.tm_return;
                    is_pure = resolved.tm_is_pure;
                  }
              in
              Some (new_ty, with_inferred_type callee' new_ty)
          | None -> None
        in
        match (callee.expr_desc, args) with
        | EIdent func_name, first_arg :: _ -> (
            (* Use existing type if already inferred (e.g., UFCS-resolved obj'),
           otherwise infer. Avoids re-inferring expressions with UFCS mangled names. *)
            let first_arg_result =
              match expr_semantic_type_opt first_arg with
              | Some t -> Ok (t, first_arg)
              | None -> infer_unconstrained_value_expr ctx first_arg
            in
            match first_arg_result with
            | Ok (TyVar param_name, _) -> (
                match
                  try_trait_dispatch param_name (TyVar param_name) func_name
                with
                | Some result -> result
                | None -> (callee_ty, callee'))
            | Ok (TyNamed (param_name, []), _)
              when List.mem param_name (Env.get_type_params ctx.env) -> (
                match
                  try_trait_dispatch param_name
                    (TyNamed (param_name, []))
                    func_name
                with
                | Some result -> result
                | None -> (callee_ty, callee'))
            | _ -> (callee_ty, callee'))
        | _ -> (callee_ty, callee')
      in
      (* Resolve type aliases: [Decoder[T]] for `type alias Decoder[T] = pure (JsonValue) -> Result[T, _]`
     must unfold to its TyFunc target before we can dispatch as a function call. *)
      let callee_ty = normalize_type ctx CalleeDispatch callee_ty in
      match callee_ty with
      | TyFunc { params; return; is_pure = _ } ->
          if List.length args <> List.length params then
            (* Track B: qualify the callee name with its home module when
           overload resolution pinned a specific entry. Falls back to
           bare name when no overload is resolved (closure calls, etc.). *)
            let name_str =
              match (get_callee_name callee, resolved_overload) with
              | Some n, Some entry ->
                  Printf.sprintf "'%s' " (Env.format_overload_ref n entry)
              | Some n, None -> Printf.sprintf "'%s' " n
              | None, _ -> ""
            in
            let expected = List.length params in
            let got = List.length args in
            let notes =
              [
                Printf.sprintf "Expected %d argument%s, got %d" expected
                  (if expected = 1 then "" else "s")
                  got;
              ]
            in
            error_with ~notes ~help:None loc
              (Printf.sprintf "Function %sexpects %d argument%s, got %d"
                 name_str expected
                 (if expected = 1 then "" else "s")
                 got)
          else begin
            (* Extract callee name and type params early — needed for types_compatible and build_subst *)
            let callee_name = get_callee_name callee in
            let callee_type_params =
              match resolved_overload with
              | Some entry -> Env.overload_type_param_names entry
              | None -> (
                  match callee_name with
                  | Some name -> (
                      match Env.get_func_info ctx.env name with
                      | Some (_, tp, _) -> Env.bound_type_param_names tp
                      | None -> (
                          (* Check UFCS mangled name — extract type params from the function type *)
                          let from_ufcs =
                            if
                              String.length name > 7
                              && String.sub name 0 7 = "__ufcs_"
                            then
                              match expr_semantic_type_opt callee' with
                              | Some (TyFunc { params = _; _ } as ft) ->
                                  Types.collect_type_vars ft
                              | _ -> []
                            else []
                          in
                          if from_ufcs <> [] then from_ufcs
                          else
                            (* Constructor — get type params from parent union
                           (must run before the generic [TyFunc] fallback so
                           [collect_type_vars] doesn't muddle the order). *)
                            match Env.get_constructor ctx.env name with
                            | Some (_, tp, _, _) -> tp
                            | None ->
                                (* Qualified module call (`C.put`, `M.sorted_map`) or
                               anything else whose callee carries a [TyFunc]
                               with free type vars. Dedup — [collect_type_vars]
                               visits each var once per occurrence.

                               Filter out caller's rigid type params: calling
                               a local parameter like [f: (A) -> B] inside
                               [func foo[A, B]...] must NOT re-instantiate A, B
                               — they're the caller's rigid vars, not quantified
                               over the callee. *)
                                let caller_tps = Env.get_type_params ctx.env in
                                let raw =
                                  match expr_semantic_type_opt callee' with
                                  | Some (TyFunc _ as ft) ->
                                      List.filter
                                        (fun v ->
                                          (not (Types.Dim.is_var_name v))
                                          && not (List.mem v caller_tps))
                                        (Types.collect_type_vars ft)
                                  | _ -> []
                                in
                                List.fold_left
                                  (fun acc v ->
                                    if List.mem v acc then acc else acc @ [ v ])
                                  [] raw))
                  | None -> [])
            in
            let callee_bound_params =
              match resolved_overload with
              | Some entry -> Some entry.Env.ol_type_params
              | None -> (
                  match callee_name with
                  | Some name -> (
                      match Env.get_func_info ctx.env name with
                      | Some (_, tp, _) -> Some tp
                      | None -> None)
                  | None -> None)
            in
            (* HM instantiation: replace each rigid callee type param with a
           fresh [TyMeta]. Every call site gets its own distinct metas, so
           there's no name-collision between caller and callee, and a
           binding discovered at one call site flows to another via the
           global meta environment.

           We keep the original [callee_type_params] list (names + trait
           bounds) for bookkeeping (trait-bound enforcement, conflict
           detection) and maintain a separate [meta_map] from stripped
           rigid name to meta id. Downstream code that expects a
           name-keyed subst reconstructs one by zonking each meta. *)
            let meta_map : (string * int) list =
              List.map
                (fun tp_name ->
                  let stripped = Env.type_param_name tp_name in
                  match Types.fresh_meta ~origin:stripped () with
                  | TyMeta id -> (stripped, id)
                  | _ -> assert false)
                callee_type_params
            in
            let rename_ty =
              Types.map_type_expr (fun ty ->
                  match ty with
                  | TyVar name -> (
                      match List.assoc_opt name meta_map with
                      | Some id -> Some (TyMeta id)
                      | None -> None)
                  | TyNamed (name, []) -> (
                      match List.assoc_opt name meta_map with
                      | Some id -> Some (TyMeta id)
                      | None -> None)
                  | _ -> None)
            in
            (* Freshen [#_] wildcard dims per call site: each occurrence gets its
           own fresh meta so the signature's "discarded dim" positions unify
           with any concrete dim at the call. Must happen here (per call)
           not at signature registration (once for all calls) — otherwise
           every call site shares the same meta. *)
            let rename_and_freshen ty =
              Types.freshen_dim_wildcards (rename_ty ty)
            in
            let params, return =
              (List.map rename_and_freshen params, rename_and_freshen return)
            in
            (* Build a name-keyed subst for bookkeeping (trait bounds, conflict
           detection). For each callee type-param, look up its meta — if
           bound, materialise a name→concrete entry. Refreshed after each
           unify call below so later unifications see the latest. *)
            let subst_from_metas () : subst_map =
              List.filter_map
                (fun (name, id) ->
                  match Types.lookup_meta id with
                  | Some t ->
                      Some
                        { var_name = name; concrete_type = Types.zonk_type t }
                  | None -> None)
                meta_map
            in
            let callee_param_names =
              match resolved_overload with
              | Some entry -> entry.Env.ol_param_names
              | None -> (
                  match callee_name with
                  | Some name -> (
                      match Env.get_func_param_names ctx.env name with
                      | Some names -> names
                      | None -> [])
                  | None -> [])
            in
            (* Handle TySelf in trait method calls: resolve Self from first argument type *)
            let has_self =
              List.exists contains_ty_self params || contains_ty_self return
            in
            let params, return, resolved_self_ty =
              if has_self && args <> [] then
                (* Use existing type if already inferred (UFCS-resolved args),
               otherwise infer. *)
                let first_arg = List.hd args in
                let first_arg_result =
                  match expr_semantic_type_opt first_arg with
                  | Some t -> Ok (t, first_arg)
                  | None -> infer_unconstrained_value_expr ctx first_arg
                in
                match first_arg_result with
                | Ok (first_arg_ty, _) ->
                    let self_slot =
                      Type_widening.method_receiver_slot first_arg_ty
                    in
                    let self_ty = Type_widening.value_type self_slot in
                    let resolve = resolve_self self_ty in
                    (List.map resolve params, resolve return, Some self_ty)
                | Error _ -> (params, return, None)
              else (params, return, None)
            in
            (* Verify that the concrete type implements the required trait *)
            let* () =
              match (callee_name, resolved_self_ty) with
              | Some name, Some concrete_ty -> (
                  match get_function_trait ctx.env name with
                  | Some trait_name ->
                      if
                        trait_obligation_satisfied ctx.env concrete_ty
                          trait_name
                      then Ok ()
                      else
                        error loc
                          (Printf.sprintf
                             "Type %s does not implement trait %s (required by \
                              %s)"
                             (type_to_string concrete_ty)
                             (Env.format_trait_name ctx.env trait_name)
                             name)
                  | None -> Ok ())
              | _ -> Ok ()
            in
            (* If we have an expected type, extract initial substitutions.
           [build_subst] still produces name-keyed entries for any literal
           type params remaining in [return] (e.g. when [callee_type_params]
           is non-empty). The main binding work happens at arg unification
           time through the meta env; [initial_subst] is a supplementary
           hint for callees whose return is fully generic and no args
           constrain the params (e.g. [SortedMap.sorted_map() : SortedMap[K, V]]
           with declared [: SortedMap[Int, Int]]). *)
            let initial_subst =
              match expected_type_opt ctx with
              | Some expected ->
                  build_subst ~type_params:callee_type_params return expected
              | None -> []
            in
            (* Also commit meta bindings from the expected return type when
           arg-derived bindings won't cover them. Walk in parallel; only
           bind metas to subterms that are already concrete after the meta
           env lookup. Crucially, skip if [expected] points to a rigid
           TyVar from the caller — those conflict with arg-inferred types
           later (e.g. in [cache.get] where the outer [V] is caller-rigid
           but the call's [V] unifies to [(V, Int)] from arg). *)
            let caller_tps = Env.get_type_params ctx.env in
            let rec meta_contains_rigid_tyvar ty =
              match ty with
              | TyVar n | TyNamed (n, []) -> List.mem n caller_tps
              | TyNamed (_, args) -> List.exists meta_contains_rigid_tyvar args
              | TyTuple es -> List.exists meta_contains_rigid_tyvar es
              | TyFunc { params; return; _ } ->
                  List.exists meta_contains_rigid_tyvar params
                  || meta_contains_rigid_tyvar return
              | TyRange inner -> meta_contains_rigid_tyvar inner
              | TyDimOp (_, a, b) ->
                  meta_contains_rigid_tyvar a || meta_contains_rigid_tyvar b
              | _ -> false
            in
            let rec bind_meta_from_expected ret exp =
              match (ret, exp) with
              | TyMeta n, _
                when Option.is_none (Types.lookup_meta n)
                     && (not (Types.occurs_meta n exp))
                     && not (meta_contains_rigid_tyvar exp) ->
                  Types.bind_meta n exp
              | TyNamed (n1, a1), TyNamed (n2, a2)
                when Types.normalize_type_name n1 = Types.normalize_type_name n2
                     && List.length a1 = List.length a2 ->
                  List.iter2 bind_meta_from_expected a1 a2
              | TyTuple e1, TyTuple e2 when List.length e1 = List.length e2 ->
                  List.iter2 bind_meta_from_expected e1 e2
              | TyFunc f1, TyFunc f2
                when List.length f1.params = List.length f2.params ->
                  List.iter2 bind_meta_from_expected f1.params f2.params;
                  bind_meta_from_expected f1.return f2.return
              | _ -> ()
            in
            (match expected_type_opt ctx with
            | Some expected -> bind_meta_from_expected return expected
            | None -> ());
            let initial_subst_with_sources =
              List.map
                (fun (entry : subst_entry) ->
                  (entry, "from expected return type"))
                initial_subst
            in
            (* NOTE: Do NOT pre-apply initial_subst to params here.
           The fold below starts with initial_subst in acc_subst and applies it
           to each param_ty. Pre-applying would cause double-substitution when
           the substitution maps a type var to a type containing the same-named
           var (e.g. Option[T]'s T → (T, List[T]) in a generic func with T). *)
            (* Infer argument types with expected types from parameters.
           Forward-propagate type substitutions: resolutions from earlier arguments
           (e.g. T=Int from arg 1) are applied to later parameter types
           (e.g. (T) -> Int becomes (Int) -> Int for arg 2). *)
            let* typed_args_and_subst =
              List.fold_left2
                (fun acc arg param_ty ->
                  match acc with
                  | Error e -> Error e
                  | Ok (results, acc_subst, arg_pos) -> (
                      (* Apply accumulated substitutions to current parameter type *)
                      let param_ty = apply_subst acc_subst param_ty in
                      (* If arg is already typed (e.g., UFCS-resolved obj prepended to args),
                 use its type to avoid re-inferring expressions with mangled UFCS names. *)
                      match
                        match expr_semantic_type_opt arg with
                        | Some t -> Ok (t, arg)
                        | None -> infer_expected_argument_expr ctx param_ty arg
                      with
                      | Error e -> Error e
                      | Ok (arg_ty, arg') -> (
                          if
                            (* Prevent Void expressions from being passed as arguments *)
                            arg_ty = TyNamed ("Void", [])
                          then
                            error arg.expr_loc
                              "Cannot use Void expression as a function \
                               argument"
                          else
                            let param_ty_r =
                              normalize_type ctx ArgumentCompatibility param_ty
                            in
                            let arg_value_ty = expr_value_type_or arg' arg_ty in
                            let arg_ty_r =
                              default_arg_type_for_param param_ty_r
                                (normalize_type ctx ArgumentCompatibility
                                   arg_value_ty)
                            in
                            (* LiteralString parameters require the argument to be a string literal *)
                            let is_literal_string_param =
                              param_ty_r = TyNamed ("LiteralString", [])
                            in
                            let arg_is_string_literal =
                              match arg'.expr_desc with
                              | ELiteral (LitString _) -> true
                              | _ -> false
                            in
                            if
                              is_literal_string_param
                              && not arg_is_string_literal
                            then
                              let param_name_hint =
                                match
                                  List.nth_opt callee_param_names (arg_pos - 1)
                                with
                                | Some (Some pname) ->
                                    Printf.sprintf " ('%s')" pname
                                | _ -> ""
                              in
                              let callee_hint =
                                match callee_name with
                                | Some n -> Printf.sprintf " in call to '%s'," n
                                | None -> ""
                              in
                              error arg.expr_loc
                                (Printf.sprintf
                                   "Argument type mismatch:%s argument %d%s \
                                    expected LiteralString, got String"
                                   callee_hint arg_pos param_name_hint)
                            else
                              (* Element-wise tensor lift: for scalar math functions (sqrt,
                     abs, exp, log, ...) called with a Tensor arg, allow the
                     tensor's element type to satisfy the scalar param. The
                     return type is then lifted to match the tensor shape by
                     the existing lift code after arg checking. *)
                              let is_tensor_elementwise_compatible =
                                let is_ew =
                                  match callee_name with
                                  | Some n ->
                                      List.mem n
                                        Codegen_builtins
                                        .elementwise_tensor_functions
                                  | None -> false
                                in
                                is_ew
                                &&
                                match Types.array_parts arg_ty_r with
                                | Some (elem, _) ->
                                    types_compatible
                                      ~type_params:callee_type_params param_ty_r
                                      elem
                                | _ -> false
                              in
                              if
                                types_compatible ~type_params:callee_type_params
                                  param_ty_r arg_ty_r
                                || is_literal_string_param
                                || is_tensor_elementwise_compatible
                              then
                                (* Build new substitutions from this argument *)
                                let new_subst =
                                  build_subst ~type_params:callee_type_params
                                    param_ty_r arg_ty_r
                                in
                                Ok
                                  ( results @ [ (arg_ty_r, arg') ],
                                    acc_subst @ new_subst,
                                    arg_pos + 1 )
                              else
                                let param_name_hint =
                                  match
                                    List.nth_opt callee_param_names (arg_pos - 1)
                                  with
                                  | Some (Some pname) ->
                                      Printf.sprintf " ('%s')" pname
                                  | _ -> ""
                                in
                                match callee_name with
                                | Some n ->
                                    let message =
                                      Printf.sprintf
                                        "Argument type mismatch: in call to \
                                         '%s', argument %d%s expected %s, got \
                                         %s"
                                        n arg_pos param_name_hint
                                        (type_to_string param_ty_r)
                                        (type_to_string arg_ty_r)
                                      |> append_new_type_conversion_hint ctx.env
                                           ~expected:param_ty_r ~actual:arg_ty_r
                                    in
                                    error arg.expr_loc message
                                | None ->
                                    let message =
                                      Printf.sprintf
                                        "Argument type mismatch: argument %d%s \
                                         expected %s, got %s"
                                        arg_pos param_name_hint
                                        (type_to_string param_ty_r)
                                        (type_to_string arg_ty_r)
                                      |> append_new_type_conversion_hint ctx.env
                                           ~expected:param_ty_r ~actual:arg_ty_r
                                    in
                                    error arg.expr_loc message)))
                (Ok ([], initial_subst, 1))
                args params
            in
            let typed_args, _propagated_subst, _next_arg_pos =
              typed_args_and_subst
            in
            let args' = List.map snd typed_args in
            let arg_types = List.map fst typed_args in

            (* Check trait bounds on type parameter arguments *)
            let* () =
              match callee_name with
              | None -> Ok ()
              | Some name ->
                  (* Check each argument - if it's a type param, verify trait bounds *)
                  List.fold_left
                    (fun acc arg_ty ->
                      match acc with
                      | Error e -> Error e
                      | Ok () -> check_trait_bound_on_arg ctx name arg_ty loc)
                    (Ok ()) arg_types
            in

            (* Build substitution from type variables to actual argument types.
           Arg-derived entries override bidirectional initial entries because
           they're more specific (from actual arguments, not expected types
           which may contain unresolved type params). *)
            let params_resolved =
              List.map (normalize_type ctx ArgumentCompatibility) params
            in
            let arg_subst_with_sources =
              List.concat
                (List.mapi
                   (fun i (param_ty_r, arg_ty_r) ->
                     let entries =
                       build_subst ~type_params:callee_type_params param_ty_r
                         arg_ty_r
                     in
                     List.map
                       (fun (entry : subst_entry) ->
                         (entry, Printf.sprintf "from argument %d" (i + 1)))
                       entries)
                   (List.combine params_resolved arg_types))
            in
            let arg_var_names =
              List.map
                (fun ((s : subst_entry), _) -> s.var_name)
                arg_subst_with_sources
            in
            let filtered_initial_with_sources =
              List.filter
                (fun ((s : subst_entry), _) ->
                  not (List.mem s.var_name arg_var_names))
                initial_subst_with_sources
            in
            let subst_with_sources =
              arg_subst_with_sources @ filtered_initial_with_sources
            in
            (* Augment with meta bindings discovered during unification above.
           [types_compatible]/[build_subst] bind metas as side effects via
           [Types.unify]; [subst_from_metas] materialises those bindings as
           name-keyed entries so downstream [check_subst_conflicts] and
           [check_callee_trait_bounds] see the resolved types. *)
            let meta_derived_sources =
              List.map
                (fun (e : subst_entry) -> (e, "from meta unification"))
                (subst_from_metas ())
            in
            let subst_names_already =
              List.map
                (fun ((s : subst_entry), _) -> s.var_name)
                subst_with_sources
            in
            let meta_derived_sources =
              List.filter
                (fun ((s : subst_entry), _) ->
                  not (List.mem s.var_name subst_names_already))
                meta_derived_sources
            in
            let subst_with_sources =
              subst_with_sources @ meta_derived_sources
            in
            let subst = List.map fst subst_with_sources in

            (* Check for conflicting type variable substitutions *)
            let* () =
              check_subst_conflicts subst_with_sources callee_type_params
                callee_name ctx.env loc
            in

            (* Check trait bounds on concrete type substitutions *)
            let* () =
              check_callee_trait_bounds ?callee_bound_params callee_name subst
                ctx.env loc
            in
            (* Validate that no dimension substitution resolved to a negative value *)
            let* () =
              List.fold_left
                (fun acc entry ->
                  let* () = acc in
                  match Types.Dim.find_negative entry.concrete_type with
                  | Some n ->
                      let func_hint =
                        match callee_name with
                        | Some f -> Printf.sprintf " in call to '%s'" f
                        | None -> ""
                      in
                      error loc
                        (Printf.sprintf
                           "Dimension arithmetic produces non-positive result: \
                            %s = %d%s (dimensions must be >= 1)"
                           entry.var_name n func_hint)
                  | None -> Ok ())
                (Ok ()) subst
            in
            (* Check dimension where-clause constraints.
           Prefer resolved_overload (correct for UFCS/overloaded calls),
           fall back to env lookup for direct calls. *)
            let* () =
              let dim_constraints =
                match resolved_overload with
                | Some entry -> entry.Env.ol_dim_constraints
                | None -> (
                    match callee_name with
                    | Some name -> Env.get_dim_constraints ctx.env name
                    | None -> [])
              in
              List.fold_left
                (fun acc (lhs, rhs) ->
                  let* () = acc in
                  let lhs' = apply_subst subst lhs in
                  let rhs' = apply_subst subst rhs in
                  let lookup_meta = Types.lookup_meta in
                  let cl = Dim_solver.to_canonical ~lookup_meta lhs' in
                  let cr = Dim_solver.to_canonical ~lookup_meta rhs' in
                  if Dim_solver.equal cl cr then Ok ()
                  else
                    let func_hint =
                      match callee_name with
                      | Some f -> Printf.sprintf " in call to '%s'" f
                      | None -> ""
                    in
                    (* Show evaluated values without # prefix for constants *)
                    let dim_val_str ty =
                      match ty with
                      | TyConstInt n -> string_of_int n
                      | _ -> type_to_string ty
                    in
                    (* Show the substitution mapping for dim vars *)
                    let dim_subst_strs =
                      List.filter_map
                        (fun (entry : subst_entry) ->
                          if
                            String.length entry.var_name > 0
                            && entry.var_name.[0] = '#'
                          then
                            Some
                              (Printf.sprintf "%s = %s" entry.var_name
                                 (dim_val_str entry.concrete_type))
                          else None)
                        subst
                    in
                    let with_str =
                      match dim_subst_strs with
                      | [] -> ""
                      | strs ->
                          Printf.sprintf "\n   = with %s"
                            (String.concat ", " strs)
                    in
                    error loc
                      (Printf.sprintf
                         "Dimension constraint violated%s\n\
                         \   = constraint: %s == %s%s\n\
                         \   = but: %s ≠ %s"
                         func_hint (type_to_string lhs) (type_to_string rhs)
                         with_str (dim_val_str lhs') (dim_val_str rhs')))
                (Ok ()) dim_constraints
            in
            (* Apply substitution to return type *)
            let instantiated_return = apply_subst subst return in
            let instantiated_return =
              match (callee_name, arg_types) with
              | Some (("length" | "vector_length") as name), [ arg_ty ]
                when Env.is_builtin_func ctx.env name -> (
                  match refined_length_return_type arg_ty with
                  | Some ret_ty -> ret_ty
                  | None -> instantiated_return)
              | _ -> instantiated_return
            in
            (* Element-wise tensor lift: for FloatingPoint/Absolute trait methods called on
           tensors, the return type should be the tensor type, not the scalar element type.
           sqrt(Float[#M, #N]) -> Float[#M, #N], not Float *)
            let instantiated_return =
              let is_elementwise_math =
                match callee_name with
                | Some n ->
                    List.mem n Codegen_builtins.elementwise_tensor_functions
                | None -> false
              in
              if is_elementwise_math && List.length arg_types = 1 then
                let arg_ty = List.hd arg_types in
                if Types.is_array_type arg_ty then arg_ty
                else instantiated_return
              else instantiated_return
            in
            (* Resolve variadic dims in return type: build a name→concrete_dims map
           by scanning params, then replace each TyVarDims name in the return type
           with its resolved dims. Different names resolve independently. *)
            let is_vardims = function TyVarDims _ -> true | _ -> false in
            (* Build name→dims map from param/arg pairs.
           If the same name appears in multiple params, verify they resolve to the
           same concrete dims — otherwise it's a type error. *)
            let vardims_map, vardims_conflict =
              List.fold_left2
                (fun (map, conflict) param_ty arg_ty ->
                  let param_ty =
                    normalize_type ctx VariadicDimensionExtraction param_ty
                  in
                  let param_dims, arg_dims =
                    match
                      (Types.array_parts param_ty, Types.array_parts arg_ty)
                    with
                    | Some (_, pdims), Some (_, adims) -> (pdims, adims)
                    | _ -> (
                        match (param_ty, arg_ty) with
                        | TyNamed (_, param_args), TyNamed (_, arg_args) ->
                            (param_args, arg_args)
                        | _ -> ([], []))
                  in
                  match (param_dims, arg_dims) with
                  | param_args, arg_args when List.exists is_vardims param_args
                    ->
                      let non_vardims_prefix =
                        List.filter (fun a -> not (is_vardims a)) param_args
                      in
                      let arg_suffix =
                        List.filteri
                          (fun i _ -> i >= List.length non_vardims_prefix)
                          arg_args
                      in
                      List.fold_left
                        (fun (m, c) a ->
                          match a with
                          | TyVarDims name -> (
                              match List.assoc_opt name m with
                              | None -> ((name, arg_suffix) :: m, c)
                              | Some existing ->
                                  if
                                    List.length existing
                                    = List.length arg_suffix
                                    && List.for_all2 types_equal existing
                                         arg_suffix
                                  then (m, c)
                                    (* consistent — keep existing binding *)
                                  else (m, Some (name, existing, arg_suffix))
                                    (* conflict *))
                          | _ -> (m, c))
                        (map, conflict) param_args
                  | _ -> (map, conflict))
                ([], None) params arg_types
            in
            let* () =
              match vardims_conflict with
              | Some (name, dims1, dims2) ->
                  let dims_str d =
                    String.concat ", " (List.map type_to_string d)
                  in
                  error loc
                    (Printf.sprintf
                       "Variadic dimension %s... has conflicting shapes: [%s] \
                        vs [%s]. Use different names for independent \
                        dimensions"
                       name (dims_str dims1) (dims_str dims2))
              | None -> Ok ()
            in
            (* Helper: resolve vardims in a TyNamed using the map *)
            let resolve_vardims_args ret_args =
              List.concat_map
                (fun a ->
                  match a with
                  | TyVarDims name -> (
                      match List.assoc_opt name vardims_map with
                      | Some concrete_dims -> concrete_dims
                      | None -> [ a ])
                  | _ -> [ a ])
                ret_args
            in
            let resolve_vardims_in_named ret_name ret_args =
              if vardims_map = [] then TyNamed (ret_name, ret_args)
              else
                let new_args = resolve_vardims_args ret_args in
                TyNamed (normalize_type_name ret_name, new_args)
            in
            let resolve_vardims_in_array elem dims =
              if vardims_map = [] then TyArray (elem, dims)
              else Types.ty_array elem (resolve_vardims_args dims)
            in
            let instantiated_return =
              match instantiated_return with
              | TyNamed (ret_name, ret_args)
                when List.exists is_vardims ret_args ->
                  resolve_vardims_in_named ret_name ret_args
              | TyArray (elem, dims) when List.exists is_vardims dims ->
                  resolve_vardims_in_array elem dims
              | TyTuple elems when List.exists Types.Dim.contains_vardims elems
                ->
                  (* Resolve #N... in each tuple element independently *)
                  TyTuple
                    (List.map
                       (fun elem ->
                         match elem with
                         | TyNamed (name, args) when List.exists is_vardims args
                           ->
                             resolve_vardims_in_named name args
                         | TyArray (array_elem, dims)
                           when List.exists is_vardims dims ->
                             resolve_vardims_in_array array_elem dims
                         | _ -> elem)
                       elems)
              | _ -> instantiated_return
            in
            (* Validate no negative dimensions in the resolved return type *)
            let* () =
              match Types.Dim.find_negative instantiated_return with
              | Some n ->
                  let func_hint =
                    match callee_name with
                    | Some f -> Printf.sprintf " in call to '%s'" f
                    | None -> ""
                  in
                  error loc
                    (Printf.sprintf
                       "Dimension arithmetic produces non-positive result: \
                        %d%s (dimensions must be >= 1)"
                       n func_hint)
              | None -> Ok ()
            in
            Ok
              ( instantiated_return,
                with_inferred_type
                  { expr with expr_desc = ECall (callee', args') }
                  instantiated_return )
          end
      | _ ->
          error loc
            (Printf.sprintf "Cannot call non-function type: %s"
               (type_to_string callee_ty)))

(** Extract the upper bound from an expression, checking both literal values
    and structured inferred type information (e.g., length(v) returning
    TyConstInt n).
    Returns Some n for positive upper bounds, None otherwise. *)
and extract_upper_bound expr =
  match expr.expr_desc with
  | ELiteral (LitInt n) when n > 0L -> Some (TyConstInt (Int64.to_int n))
  | _ -> (
      match expr_proof_semantic_type_opt expr with
      | Some (TyConstInt n) when n > 0 -> Some (TyConstInt n)
      | Some (TyVar v) when Types.Dim.is_var_name v -> Some (TyVar v)
      | _ -> None)

(** Extract range-narrowing constraints from a boolean condition.
    Returns (var_name, upper_bound) pairs where var is proven in [0, upper_bound)
    when the condition is true. Requires both >= 0 and < N for Int variables.
    Operates on the inferred condition so structured semantic metadata is
    available for recognizing length(v) and other compile-time-constant
    expressions. *)
and extract_range_narrowings cond =
  let rec collect expr =
    match expr.expr_desc with
    | ELogical (And, left, right) -> collect left @ collect right
    (* var >= 0 *)
    | EBinary
        ( Ge,
          { expr_desc = EIdent var; _ },
          { expr_desc = ELiteral (LitInt 0L); _ } ) ->
        [ (var, `Lower) ]
    (* 0 <= var *)
    | EBinary
        ( Le,
          { expr_desc = ELiteral (LitInt 0L); _ },
          { expr_desc = EIdent var; _ } ) ->
        [ (var, `Lower) ]
    (* var < EXPR where EXPR has a known positive upper bound *)
    | EBinary (Lt, { expr_desc = EIdent var; _ }, rhs) -> (
        match extract_upper_bound rhs with
        | Some ty -> [ (var, `Upper ty) ]
        | None -> [])
    (* var <= EXPR  ->  var < EXPR+1 (only for concrete bounds) *)
    | EBinary (Le, { expr_desc = EIdent var; _ }, rhs) -> (
        match extract_upper_bound rhs with
        | Some (TyConstInt n) when n < max_int ->
            [ (var, `Upper (TyConstInt (n + 1))) ]
        | _ -> [])
    (* EXPR > var  ->  var < EXPR *)
    | EBinary (Gt, lhs, { expr_desc = EIdent var; _ }) -> (
        match extract_upper_bound lhs with
        | Some ty -> [ (var, `Upper ty) ]
        | None -> [])
    (* EXPR >= var  ->  var < EXPR+1 (only for concrete bounds) *)
    | EBinary (Ge, lhs, { expr_desc = EIdent var; _ }) -> (
        match extract_upper_bound lhs with
        | Some (TyConstInt n) when n < max_int ->
            [ (var, `Upper (TyConstInt (n + 1))) ]
        | _ -> [])
    | _ -> []
  in
  let constraints = collect cond in
  let has_lower var =
    List.exists (fun (v, c) -> v = var && c = `Lower) constraints
  in
  let get_upper var =
    List.fold_left
      (fun acc (v, c) ->
        match c with
        | `Upper ty when v = var -> (
            match (acc, ty) with
            | None, _ -> Some ty
            | Some (TyConstInt m), TyConstInt n -> Some (TyConstInt (min m n))
            | Some _, _ -> acc (* keep first bound if types don't compare *))
        | _ -> acc)
      None constraints
  in
  let vars = List.sort_uniq String.compare (List.map fst constraints) in
  List.filter_map
    (fun var ->
      if has_lower var then
        match get_upper var with
        | Some ub_ty -> Some (var, ub_ty)
        | None -> None
      else None)
    vars

(** Infer the type of an if expression *)
and infer_if ctx expr cond then_branch else_branch loc =
  let* cond_ty, cond' = infer_unconstrained_value_expr ctx cond in
  (* Validate condition is Bool *)
  let* () =
    match cond_ty with
    | TyNamed ("Bool", []) -> Ok ()
    | _ ->
        error cond.expr_loc
          (Printf.sprintf "If condition must be Bool, got %s"
             (type_to_string cond_ty))
  in
  (* Conditional range narrowing: if i >= 0 and i < N, narrow i to ..#N in then-branch.
     Uses the inferred condition (cond') so structured type metadata is available for length(v) etc.
     Only narrows immutable bindings -- mutable vars could be reassigned after the check. *)
  let narrowings = extract_range_narrowings cond' in
  let branch_ctx =
    match else_branch with Some _ -> ctx | None -> without_expected ctx
  in
  let then_ctx =
    match narrowings with
    | [] -> branch_ctx
    | _ ->
        let env' = apply_branch_range_narrowings branch_ctx.env narrowings in
        { branch_ctx with env = env' }
  in
  let* then_ty, then' = infer_expr then_ctx then_branch in
  match else_branch with
  | None ->
      if not (types_equal then_ty ty_void) then
        error_with
          ~notes:
            [
              "the then-branch returns " ^ type_to_string then_ty
              ^ ", but without an else branch the if-expression has type Void";
            ]
          ~help:
            (Some "add an else: branch, or discard the value with `_ = ...`")
          loc "if-expression without else cannot produce a value"
      else
        Ok (ty_void, with_inferred_desc expr (EIf (cond', then', None)) ty_void)
  | Some else_expr -> (
      let* else_ty, else' = infer_expr ctx else_expr in
      let tp = Env.get_type_params ctx.env in
      match common_inferred_type ~type_params:tp then_ty else_ty with
      | Some result_ty ->
          Ok
            ( result_ty,
              with_inferred_desc expr (EIf (cond', then', Some else')) result_ty
            )
      | None ->
          error loc
            (Printf.sprintf
               "If-else type mismatch: then-branch returns %s, else-branch \
                returns %s"
               (type_to_string then_ty) (type_to_string else_ty)))

(** Pretty-print a literal for diagnostics *)
and literal_to_string = function
  | LitInt n -> Int64.to_string n
  | LitInt128 n -> n
  | LitFloat f -> string_of_float f
  | LitString (s, _) -> Printf.sprintf "\"%s\"" s
  | LitBool true -> "True"
  | LitBool false -> "False"
  | LitChar c -> Printf.sprintf "'\\u{%X}'" c

(** Infer the type of a match expression *)
and infer_match ctx expr scrutinee cases loc =
  let* scrutinee_ty, scrutinee' =
    infer_unconstrained_value_expr ctx scrutinee
  in
  let* () =
    reject_void_value ~context:"match scrutinee" scrutinee.expr_loc scrutinee_ty
  in
  if cases = [] then error loc "Match expression has no cases"
  else begin
    let* first_ty, cases' = infer_match_cases ctx scrutinee_ty cases in
    Ok (first_ty, with_inferred_desc expr (EMatch (scrutinee', cases')) first_ty)
  end

(** Pretty-print a pattern for diagnostics *)
and pattern_to_string = function
  | PatWildcard -> "_"
  | PatVar name -> name
  | PatLiteral lit -> literal_to_string lit
  | PatTuple pats ->
      Printf.sprintf "(%s)"
        (String.concat ", " (List.map pattern_to_string pats))
  | PatConstructor (ctor_name, []) -> ctor_name
  | PatConstructor (ctor_name, sub_patterns) ->
      Printf.sprintf "%s(%s)" ctor_name
        (String.concat ", " (List.map pattern_to_string sub_patterns))
  | PatQualified (mod_name, ctor_name, []) ->
      Printf.sprintf "%s.%s" mod_name ctor_name
  | PatQualified (mod_name, ctor_name, sub_patterns) ->
      Printf.sprintf "%s.%s(%s)" mod_name ctor_name
        (String.concat ", " (List.map pattern_to_string sub_patterns))
  | PatList (elems, spread) -> (
      let elems_s = String.concat ", " (List.map pattern_to_string elems) in
      match spread with
      | None -> Printf.sprintf "[%s]" elems_s
      | Some spread_pat when elems = [] ->
          Printf.sprintf "[..%s]" (pattern_to_string spread_pat)
      | Some spread_pat ->
          Printf.sprintf "[%s, ..%s]" elems_s (pattern_to_string spread_pat))
  | PatOr pats -> String.concat " | " (List.map pattern_to_string pats)

(** Infer types for match cases, returning the common result type *)
and infer_match_cases ctx scrutinee_ty cases =
  let* first_case =
    match cases with
    | [] ->
        Error
          {
            message = "No cases";
            loc = dummy_loc;
            phase = TypeCheck;
            kind = OtherError;
            notes = [];
            help = None;
          }
    | c :: _ -> infer_case ctx scrutinee_ty c
  in
  let first_ty = fst first_case in
  let indexed_rest_cases =
    List.mapi (fun i case -> (i + 2, case)) (List.tl cases)
  in
  let* result_ty, typed_cases =
    List.fold_left
      (fun acc (arm_index, case) ->
        match acc with
        | Error e -> Error e
        | Ok (current_ty, results) -> (
            match infer_case ctx scrutinee_ty case with
            | Error e -> Error e
            | Ok (case_ty, case') -> (
                let tp = Env.get_type_params ctx.env in
                match
                  common_inferred_type ~type_params:tp current_ty case_ty
                with
                | Some result_ty -> Ok (result_ty, case' :: results)
                | None ->
                    let pattern_str = pattern_to_string case.case_pattern in
                    Error
                      {
                        message =
                          Printf.sprintf
                            "Match case has incompatible type (arm %d, pattern \
                             %s): previous arms return %s, this arm returns %s"
                            arm_index pattern_str
                            (type_to_string current_ty)
                            (type_to_string case_ty);
                        loc = case.case_body.expr_loc;
                        phase = TypeCheck;
                        kind = OtherError;
                        notes = [];
                        help = None;
                      })))
      (Ok (first_ty, [ snd first_case ]))
      indexed_rest_cases
  in
  let typed_cases = List.rev typed_cases in
  Ok (result_ty, typed_cases)

(** Infer type for a single match case *)
and infer_case ctx scrutinee_ty case =
  (* Push scope for pattern bindings *)
  let ctx = { ctx with env = push_scope ctx.env } in
  let* ctx =
    bind_pattern ctx scrutinee_ty case.case_pattern case.case_body.expr_loc
  in
  let* body_ty, body' = infer_expr ctx case.case_body in
  Ok (body_ty, { case with case_body = body' })

(** Bind constructor pattern variables — shared by PatConstructor and PatQualified *)
and bind_constructor_pattern ctx scrutinee_ty ctor_name sub_patterns loc =
  match get_constructor ctx.env ctor_name with
  | Some (parent, type_params, field_types, _tag) ->
      (* Track B: qualify the constructor and parent type with their
         home modules when known, so users can disambiguate between
         multiple types that might have a constructor of the same name. *)
      let ctor_q = Env.format_constructor_ref ctx.env ctor_name in
      let parent_q = Env.format_type_name parent in
      let* () =
        match scrutinee_ty with
        | TyNamed (type_name, _) when type_name <> parent ->
            let type_q = Env.format_type_name type_name in
            error loc
              (Printf.sprintf "Constructor %s belongs to type %s, not %s" ctor_q
                 parent_q type_q)
        | _ -> Ok ()
      in
      let subst =
        match scrutinee_ty with
        | TyNamed (_, args) when List.length args = List.length type_params ->
            List.map2
              (fun p a -> { var_name = p; concrete_type = a })
              type_params args
        | _ -> []
      in
      let concrete_fields = List.map (apply_subst subst) field_types in
      if List.length sub_patterns <> List.length concrete_fields then
        error loc
          (Printf.sprintf
             "Constructor %s expects %d field(s), but pattern has %d" ctor_q
             (List.length concrete_fields)
             (List.length sub_patterns))
      else
        List.fold_left2
          (fun acc pat ty ->
            let* ctx = acc in
            bind_pattern ctx ty pat loc)
          (Ok ctx) sub_patterns concrete_fields
  | None -> Ok ctx

(** Bind pattern variables to types in the environment *)
and bind_pattern ctx scrutinee_ty pattern loc : infer_ctx infer_result =
  match pattern with
  | PatWildcard -> Ok ctx
  | PatVar name -> (
      (* Check if this is a known constructor *)
      match get_constructor ctx.env name with
      | Some (parent, _, field_types, _) -> (
          match scrutinee_ty with
          | TyNamed (type_name, _) when type_name = parent ->
              (* Constructor of the correct type *)
              if field_types = [] then
                (* Nullary constructor — treat as constructor match, don't bind *)
                Ok ctx
              else
                (* Constructor with fields used without parens *)
                error loc
                  (Printf.sprintf "Constructor %s expects %d argument(s)" name
                     (List.length field_types))
          | TyNamed (type_name, _) ->
              error loc
                (Printf.sprintf "Constructor %s belongs to type %s, not %s" name
                   parent type_name)
          | _ ->
              (* Scrutinee is not an ADT (e.g., type param) — bind as variable *)
              Ok { ctx with env = add_var ctx.env name scrutinee_ty () })
      | None ->
          (* Not a constructor — bind as variable *)
          Ok { ctx with env = add_var ctx.env name scrutinee_ty () })
  | PatConstructor (ctor_name, sub_patterns) ->
      bind_constructor_pattern ctx scrutinee_ty ctor_name sub_patterns loc
  | PatLiteral lit -> (
      match (lit, scrutinee_ty) with
      | LitInt n, TyNamed (type_name, [])
        when Types.is_any_integer_type scrutinee_ty && type_name <> "Int" ->
          let lo, hi = Types.int_type_range type_name in
          if n >= lo && n <= hi then Ok ctx
          else
            error loc
              (Printf.sprintf "Literal %Ld is out of range for %s (%Ld to %Ld)"
                 n type_name lo hi)
      | LitInt128 _, TyNamed ("Int128", []) -> Ok ctx
      | LitFloat _, TyNamed ("Float32", []) -> Ok ctx
      | LitFloat _, TyNamed ("Float16", []) -> Ok ctx
      | _ ->
          let lit_ty =
            match lit with
            | LitInt _ -> TyNamed ("Int", [])
            | LitInt128 _ -> TyNamed ("Int128", [])
            | LitFloat _ -> TyNamed ("Float", [])
            | LitString _ -> TyNamed ("String", [])
            | LitBool _ -> TyNamed ("Bool", [])
            | LitChar _ -> TyNamed ("Char", [])
          in
          if ctx_types_compatible ctx lit_ty scrutinee_ty then Ok ctx
          else
            error loc
              (Printf.sprintf
                 "Literal pattern has type %s, but scrutinee has type %s"
                 (type_to_string lit_ty)
                 (type_to_string scrutinee_ty)))
  | PatTuple pats -> (
      match scrutinee_ty with
      | TyTuple elem_tys when List.length elem_tys = List.length pats ->
          List.fold_left2
            (fun acc_ctx ty pat ->
              let* ctx = acc_ctx in
              bind_pattern ctx ty pat loc)
            (Ok ctx) elem_tys pats
      | TyNamed ("Tuple", elem_tys) when List.length elem_tys = List.length pats
        ->
          List.fold_left2
            (fun acc_ctx ty pat ->
              let* ctx = acc_ctx in
              bind_pattern ctx ty pat loc)
            (Ok ctx) elem_tys pats
      | TyTuple elem_tys ->
          error loc
            (Printf.sprintf
               "Tuple pattern has %d elements, but scrutinee tuple has %d \
                elements"
               (List.length pats) (List.length elem_tys))
      | _ ->
          error loc
            (Printf.sprintf "Tuple pattern cannot match scrutinee of type %s"
               (type_to_string scrutinee_ty)))
  | PatQualified (_mod_name, ctor_name, sub_patterns) ->
      bind_constructor_pattern ctx scrutinee_ty ctor_name sub_patterns loc
  | PatList (elems, spread) -> (
      (* Validate scrutinee is List[T] *)
      let elem_ty =
        match scrutinee_ty with
        | TyNamed ("List", [ t ]) -> Ok t
        | TyNamed ("List", _) -> Ok (TyVar "_list_elem")
        | _ ->
            error loc
              (Printf.sprintf "List pattern cannot match scrutinee of type %s"
                 (type_to_string scrutinee_ty))
      in
      let* elem_ty = elem_ty in
      (* Bind each fixed element pattern to the element type *)
      let* ctx =
        List.fold_left
          (fun acc pat ->
            let* ctx = acc in
            bind_pattern ctx elem_ty pat loc)
          (Ok ctx) elems
      in
      (* Bind spread to List[T] *)
      match spread with
      | None -> Ok ctx
      | Some spread_pat -> bind_pattern ctx scrutinee_ty spread_pat loc)
  | PatOr pats -> (
      (* All alternatives must bind the same set of variables with the same types.
         Bind all sub-patterns independently; check variable sets match. *)
      let rec actual_vars env pat =
        (* Collect variable bindings excluding known constructors *)
        match pat with
        | PatVar name -> (
            match get_constructor env name with
            | Some _ -> []
            | None -> [ name ])
        | PatConstructor (_, subs) | PatQualified (_, _, subs) ->
            List.concat_map (actual_vars env) subs
        | PatTuple subs -> List.concat_map (actual_vars env) subs
        | PatList (elems, spread) -> (
            List.concat_map (actual_vars env) elems
            @ match spread with Some p -> actual_vars env p | None -> [])
        | PatOr (p :: _) -> actual_vars env p
        | _ -> []
      in
      match pats with
      | [] -> Ok ctx
      | first :: rest ->
          (* Bind the first pattern to get the reference set of variables *)
          let first_ctx = { ctx with env = push_scope ctx.env } in
          let* first_ctx = bind_pattern first_ctx scrutinee_ty first loc in
          let first_vars =
            List.sort String.compare (actual_vars ctx.env first)
          in
          (* Check each alternative binds the same variables *)
          let* () =
            List.fold_left
              (fun acc alt ->
                let* () = acc in
                let alt_ctx = { ctx with env = push_scope ctx.env } in
                let* _alt_ctx = bind_pattern alt_ctx scrutinee_ty alt loc in
                let alt_vars =
                  List.sort String.compare (actual_vars ctx.env alt)
                in
                if first_vars <> alt_vars then
                  error loc
                    (Printf.sprintf
                       "Or-pattern alternatives must bind the same variables: \
                        '%s' vs '%s'"
                       (String.concat ", " first_vars)
                       (String.concat ", " alt_vars))
                else Ok ())
              (Ok ()) rest
          in
          (* Use the first pattern's bindings *)
          Ok first_ctx)

(** Infer the type of a block expression *)
and infer_block ctx expr exprs _loc =
  if exprs = [] then Ok (ty_void, with_inferred_type expr ty_void)
  else begin
    let rec infer_block_exprs ctx acc = function
      | [] -> error expr.expr_loc "Internal error: empty block during inference"
      | [ last ] ->
          let* last_ty, last' = infer_expr ctx last in
          Ok (last_ty, List.rev (last' :: acc))
      | stmt :: rest ->
          let stmt_ctx = without_expected ctx in
          let* _, stmt' = infer_statement_expr ctx stmt in
          let stmt_ctx' = ctx_after_inferred_expr stmt_ctx stmt' in
          let ctx' = { ctx with env = stmt_ctx'.env } in
          infer_block_exprs ctx' (stmt' :: acc) rest
    in
    let* last_ty, exprs' = infer_block_exprs ctx [] exprs in
    Ok
      ( last_ty,
        with_inferred_type { expr with expr_desc = EBlock exprs' } last_ty )
  end

(** Infer the type of an array literal *)
and infer_array ctx expr elements loc =
  if elements = [] then
    (* Empty array needs expected type *)
    match expected_type_opt ctx with
    | Some (TyNamed ("Dict", _) as dict_ty) ->
        Ok (dict_ty, with_inferred_type expr dict_ty)
    | Some (TyNamed ("Set", _) as set_ty) ->
        Ok (set_ty, with_inferred_type expr set_ty)
    | Some expected_ty -> (
        match Types.array_parts expected_ty with
        | Some (elem_ty, [ _ ]) ->
            let array_ty = Types.ty_array elem_ty [ TyConstInt 0 ] in
            Ok (array_ty, with_inferred_type expr array_ty)
        | _ ->
            error loc
              "Cannot infer type of empty array. Add an explicit type \
               annotation, e.g. v: Int[#0] = {}")
    | _ ->
        error loc
          "Cannot infer type of empty array. Add an explicit type annotation, \
           e.g. v: Int[#0] = {}"
  else begin
    let first = List.hd elements in
    let* first_ty, first_elem' =
      infer_collection_literal_target ctx Type_widening.VectorLiteral
        ~mismatch_label:"Tensor element" ~void_context:"tensor element" first
    in
    let* typed_elems =
      List.fold_left
        (fun acc elem ->
          let* results = acc in
          let* elem_ty, elem' =
            infer_checked_collection_element ctx Type_widening.VectorLiteral
              ~target_ty:first_ty ~mismatch_label:"Tensor element"
              ~void_context:"tensor element" elem
          in
          Ok ((elem_ty, elem') :: results))
        (Ok [ (first_ty, first_elem') ])
        (List.tl elements)
    in
    let typed_elems = List.rev typed_elems in
    let elements' = List.map snd typed_elems in
    let count = List.length elements in
    let* ty =
      match Types.array_parts first_ty with
      | Some (inner_elem, inner_dims) when inner_dims <> [] ->
          (* Check if all elements are literal EVector (nested tensor literal) *)
          let all_literal =
            List.for_all
              (fun e -> match e.expr_desc with EVector _ -> true | _ -> false)
              elements
          in
          if all_literal then
            (* Flatten: {{1,2},{3,4}} -> Int[#2, #2] not Int[#2][#2] *)
            Ok (Types.ty_array inner_elem (TyConstInt count :: inner_dims))
          else
            error loc
              "Multi-dimensional tensor literals must use nested literal \
               syntax (e.g., {{1,2},{3,4}}). Constructing from tensor \
               variables is not yet supported"
      | _ ->
          (* Scalar elements: {1, 2, 3} -> Int[#3] *)
          Ok (Types.ty_array first_ty [ TyConstInt count ])
    in
    Ok (ty, with_inferred_type { expr with expr_desc = EVector elements' } ty)
  end

(** Infer the type of a list literal *)
and infer_list ctx expr elements loc =
  (* Extract expected element type from List[T] if available *)
  let expected_elem_ty =
    match expected_type_opt ctx with
    | Some (TyNamed ("List", [ elem_ty ])) -> Some elem_ty
    | _ -> None
  in
  if elements = [] then
    match expected_elem_ty with
    | Some elem_ty ->
        let list_ty = ty_list elem_ty in
        Ok (list_ty, with_inferred_type expr list_ty)
    | None ->
        error loc
          "Cannot infer type of empty list. Add an explicit type annotation, \
           e.g. xs: List[Int] = []"
  else begin
    let first = List.hd elements in
    let* target_ty, first_elem' =
      infer_collection_literal_target ctx Type_widening.ListLiteral
        ?expected_ty:expected_elem_ty ~mismatch_label:"List element"
        ~void_context:"list element" first
    in
    let* typed_elems =
      List.fold_left
        (fun acc elem ->
          let* results = acc in
          let* elem_ty, elem' =
            infer_checked_collection_element ctx Type_widening.ListLiteral
              ~target_ty ~mismatch_label:"List element"
              ~void_context:"list element" elem
          in
          Ok ((elem_ty, elem') :: results))
        (Ok [ (target_ty, first_elem') ])
        (List.tl elements)
    in
    let typed_elems = List.rev typed_elems in
    let elements' = List.map snd typed_elems in
    let ty = ty_list target_ty in
    Ok (ty, with_inferred_type { expr with expr_desc = EList elements' } ty)
  end

(** Infer the type of a record literal *)
and infer_record ctx expr fields loc =
  let check_missing_fields field_types =
    let provided = List.map fst fields in
    let missing =
      List.filter (fun (fname, _) -> not (List.mem fname provided)) field_types
    in
    match missing with
    | [] -> Ok ()
    | _ ->
        let missing_names = String.concat ", " (List.map fst missing) in
        error_with ~notes:[] ~help:None loc
          (Printf.sprintf "Record literal is missing field(s): %s" missing_names)
  in
  let infer_known_record target_ty field_types =
    let* fields' = infer_record_fields ctx field_types fields in
    let* () = check_missing_fields field_types in
    Ok
      ( target_ty,
        with_inferred_type { expr with expr_desc = ERecord fields' } target_ty
      )
  in
  let infer_from_fields () =
    if fields = [] then
      error loc
        "Cannot infer record type without annotation. Add an explicit record \
         type, e.g. p: Point = {x = 1, y = 2}"
    else
      let field_names = List.map fst fields in
      match Env.find_records_with_fields ctx.env field_names with
      | [] ->
          error loc
            "Cannot infer record type without annotation. Add an explicit \
             record type, e.g. p: Point = {x = 1, y = 2}"
      | [ single_type ] -> (
          match resolve_record_field_types ctx.env single_type [] with
          | Some field_types ->
              infer_known_record (TyNamed (single_type, [])) field_types
          | None ->
              error loc
                (Printf.sprintf
                   "Internal error: matched record type '%s' has no field \
                    metadata"
                   single_type))
      | matching_types ->
          let type_list = String.concat " or " matching_types in
          error_with ~notes:[]
            ~help:
              (Some
                 "Add an explicit type annotation, e.g. v: Vec2 = {x = 1.0, y \
                  = 2.0}") loc
            (Printf.sprintf
               "Ambiguous record literal: could be %s. Multiple types share \
                fields {%s}"
               type_list
               (String.concat ", " field_names))
  in
  match record_literal_target_from_expected ctx fields with
  | RecordLiteralTarget { target_ty; field_types } ->
      infer_known_record target_ty field_types
  | EmptyCollectionLiteralTarget target_ty ->
      Ok
        ( target_ty,
          with_inferred_type { expr with expr_desc = ERecord [] } target_ty )
  | InferRecordLiteralFromFields -> infer_from_fields ()
  | InvalidRecordLiteralTarget target_ty ->
      if fields = [] then
        error loc
          (Printf.sprintf
             "Cannot use {} for type %s — not a record, struct, or collection \
              type"
             (type_to_string target_ty))
      else
        error loc
          (Printf.sprintf "Cannot use record literal for type %s"
             (type_to_string target_ty))

(** Infer types for record fields with expected field types. *)
and infer_record_fields ctx field_types fields =
  List.fold_left
    (fun acc (name, value) ->
      match acc with
      | Error e -> Error e
      | Ok results -> (
          (* Check field exists in record definition *)
          let* () =
            match List.assoc_opt name field_types with
            | None ->
                let valid = String.concat ", " (List.map fst field_types) in
                Error
                  {
                    loc = value.expr_loc;
                    message =
                      Printf.sprintf
                        "Unknown field '%s' in record literal. Valid fields: %s"
                        name valid;
                    phase = TypeCheck;
                    kind = OtherError;
                    notes = [];
                    help = None;
                  }
            | Some _ -> Ok ()
          in
          (* Look up expected type for this field *)
          let expected_ty = List.assoc name field_types in
          match infer_expected_value_expr ctx expected_ty value with
          | Error e -> Error e
          | Ok (actual_ty, value') -> (
              match
                reject_void_value ~context:"record field value" value.expr_loc
                  actual_ty
              with
              | Error e -> Error e
              | Ok () -> (
                  (* Verify type matches expected if we have one *)
                  let type_mismatch =
                    if not (ctx_types_compatible ctx expected_ty actual_ty) then
                      Some (expected_ty, actual_ty)
                    else None
                  in
                  match type_mismatch with
                  | None -> Ok ((name, value') :: results)
                  | Some (expected_ty, _actual_ty) ->
                      Error
                        {
                          loc = value.expr_loc;
                          message =
                            Printf.sprintf
                              "Record field '%s': expected %s, got %s" name
                              (type_to_string expected_ty)
                              (type_to_string actual_ty);
                          phase = TypeCheck;
                          kind = OtherError;
                          notes = [];
                          help = None;
                        }))))
    (Ok []) fields
  |> Result.map List.rev

(** Infer the type of a record update expression: { base | field = val, ... } *)
and infer_record_update ctx expr base fields loc =
  (* Infer base expression type without expected type context *)
  let* base_ty, base' = infer_unconstrained_value_expr ctx base in
  match base_ty with
  | TyNamed (type_name, type_args) -> (
      match resolve_record_field_types ctx.env type_name type_args with
      | Some field_types ->
          (* Verify all update field names exist in the record *)
          let valid_fields = String.concat ", " (List.map fst field_types) in
          let* () =
            List.fold_left
              (fun acc (name, _) ->
                let* () = acc in
                if List.mem_assoc name field_types then Ok ()
                else
                  error loc
                    (Printf.sprintf
                       "Record %s has no field '%s'. Valid fields: %s" type_name
                       name valid_fields))
              (Ok ()) fields
          in
          (* Infer each field value with expected type *)
          let* fields' =
            List.fold_left
              (fun acc (name, value) ->
                match acc with
                | Error e -> Error e
                | Ok results -> (
                    let expected_ty = List.assoc name field_types in
                    match infer_expected_value_expr ctx expected_ty value with
                    | Error e -> Error e
                    | Ok (actual_ty, value') ->
                        if ctx_types_compatible ctx expected_ty actual_ty then
                          Ok ((name, value') :: results)
                        else
                          Error
                            {
                              loc = value.expr_loc;
                              message =
                                Printf.sprintf
                                  "Record update field '%s' type mismatch: \
                                   expected %s, got %s"
                                  name
                                  (type_to_string expected_ty)
                                  (type_to_string actual_ty);
                              phase = TypeCheck;
                              kind = OtherError;
                              notes = [];
                              help = None;
                            }))
              (Ok []) fields
            |> Result.map List.rev
          in
          Ok
            ( base_ty,
              with_inferred_desc expr (ERecordUpdate (base', fields')) base_ty
            )
      | None -> error loc (Printf.sprintf "Type %s is not a record" type_name))
  | _ ->
      error loc
        (Printf.sprintf "Record update requires a record type, got %s"
           (type_to_string base_ty))

(** Infer the type of a field access *)
and infer_field_access ctx expr obj field loc =
  let obj_result = infer_unconstrained_value_expr ctx obj in
  (* If obj fails to infer, check if it's a module alias *)
  match obj_result with
  | Error _ -> (
      let alias_name =
        match obj.expr_desc with EIdent name -> Some name | _ -> None
      in
      let module_path =
        match alias_name with
        | Some name -> List.assoc_opt name ctx.module_aliases
        | None -> None
      in
      match module_path with
      | Some mod_path -> (
          (* Module alias — try module-scoped lookup first, then fall back to env.
              Preserve EFieldAccess structure so codegen recognizes qualified calls.
              Tag the inner [obj] EIdent with a sentinel type so the typed-AST
              invariant ([expr_type <> None]) holds. The alias doesn't have a
              value type — codegen resolves the whole [EFieldAccess] via
              [module_aliases], never inspects the obj's expr_type. *)
          let module_alias_ty = TyNamed ("Module", []) in
          let typed_obj = with_inferred_type obj module_alias_ty in
          match lookup_module_func_type mod_path field with
          | Some func_ty ->
              Ok
                ( func_ty,
                  with_inferred_desc expr
                    (EFieldAccess (typed_obj, field))
                    func_ty )
          | None -> (
              match lookup_module_var_type mod_path field with
              | Some value_ty ->
                  Ok
                    ( value_ty,
                      with_inferred_desc expr
                        (EFieldAccess (typed_obj, field))
                        value_ty )
              | None -> (
                  let ident = { expr with expr_desc = EIdent field } in
                  match infer_expr ctx ident with
                  | Ok (ty, _) ->
                      Ok
                        ( ty,
                          with_inferred_desc expr
                            (EFieldAccess (typed_obj, field))
                            ty )
                  | Error e -> Error e)))
      | None ->
          (* Not a module alias — propagate original error *)
          let* _, _ = obj_result in
          error loc "unreachable")
  | Ok (obj_ty, obj') -> (
      match obj_ty with
      (* Tuple field access *)
      | TyTuple elems | TyNamed ("Tuple", elems) -> (
          match int_of_string_opt field with
          | Some idx when idx >= 0 && idx < List.length elems ->
              let elem_ty = List.nth elems idx in
              Ok
                ( elem_ty,
                  with_inferred_desc expr (EFieldAccess (obj', field)) elem_ty
                )
          | _ ->
              error loc
                (Printf.sprintf "Tuple of arity %d has no field %s"
                   (List.length elems) field))
      (* Record field access *)
      | TyNamed (type_name, type_args) -> (
          match resolve_record_field_types ctx.env type_name type_args with
          | Some field_types -> (
              match List.assoc_opt field field_types with
              | Some field_type ->
                  Ok
                    ( field_type,
                      with_inferred_desc expr
                        (EFieldAccess (obj', field))
                        field_type )
              | None ->
                  let valid = String.concat ", " (List.map fst field_types) in
                  error loc
                    (Printf.sprintf
                       "Record %s has no field '%s'. Valid fields: %s" type_name
                       field valid))
          | None ->
              error loc
                (Printf.sprintf
                   "Cannot access field on type %s. Field access is supported \
                    on record fields and tuple indices (e.g., .0, .1)"
                   (type_to_string obj_ty)))
      | _ ->
          error loc
            (Printf.sprintf
               "Cannot access field on type %s. Field access is supported on \
                record fields and tuple indices (e.g., .0, .1)"
               (type_to_string obj_ty)))

(** Infer the type of a lambda expression *)
and infer_lambda ctx expr func loc =
  (* Check for mutable captures - closures cannot capture var *)
  match check_no_mutable_captures ctx.env func loc with
  | Some err -> Error err
  | None ->
      (* Check if we have an expected function type for parameter inference *)
      let param_types =
        match expected_type_opt ctx with
        | Some (TyFunc { params; _ })
          when List.length params = List.length func.func_params ->
            List.map Option.some params
        | _ -> List.map (fun _ -> None) func.func_params
      in

      (* Build parameter types. An untyped param with no expected type gets a
     fresh meta that the body's unification will resolve; zonking at end
     of function body replaces bound metas with their concrete bindings. *)
      let param_type_slots =
        List.map2
          (fun (param : Ast.param) expected_ty ->
            match (param.param_type, expected_ty) with
            | Some ty, _ ->
                let resolved = resolve_function_parameter_annotation ctx ty in
                ( Type_resolution.canonical resolved,
                  Some (Type_resolution.source resolved) )
            | None, Some ty -> (ty, None)
            | None, None ->
                let origin =
                  match param.param_name with
                  | Some n -> n
                  | None -> "lambda_param"
                in
                (Types.fresh_meta ~origin (), None))
          func.func_params param_types
      in
      let params_with_types = List.map fst param_type_slots in

      (* Validate no negative dimensions in parameter types *)
      let* () =
        List.fold_left
          (fun acc ((param : Ast.param), ty) ->
            let* () = acc in
            match Types.Dim.find_negative ty with
            | Some n ->
                let param_hint =
                  match param.param_name with
                  | Some p -> Printf.sprintf " for parameter '%s'" p
                  | None -> ""
                in
                error param.param_loc
                  (Printf.sprintf
                     "Dimension arithmetic produces non-positive result: %d%s \
                      (dimensions must be >= 1)"
                     n param_hint)
            | None -> Ok ())
          (Ok ())
          (List.combine func.func_params params_with_types)
      in
      (* Create new scope with parameters and type parameter bounds *)
      let ctx = { ctx with env = push_scope ctx.env } in
      (* Set up type parameter bounds from function signature (e.g., T:Equatable) *)
      let ctx =
        {
          ctx with
          env = Env.set_type_param_bounds ctx.env func.func_type_params;
        }
      in
      let ctx =
        match func.func_type_params with
        | [] -> ctx
        | params ->
            let stripped = Ast.type_param_names params in
            {
              ctx with
              rigid_type_params =
                stripped
                @ List.filter
                    (fun name -> not (List.mem name stripped))
                    ctx.rigid_type_params;
            }
      in
      let ctx =
        List.fold_left2
          (fun ctx (param : Ast.param) (ty, source_ty) ->
            match param.param_name with
            | Some name ->
                {
                  ctx with
                  env =
                    add_var ctx.env name ty ?source_type:source_ty
                      ~origin:FuncParam ();
                }
            | None -> ctx)
          ctx func.func_params param_type_slots
      in

      (* Determine expected return type for body inference.
     Priority: 1) explicit annotation (func_return_type), 2) call-site expected type.
     This enables bidirectional inference: constructors like Some/None inside the body
     will use the expected return type to instantiate type parameters correctly.
     Rigid type params make that context safe for generic function bodies. *)
      let expected_return =
        match func.func_return_type with
        | Some ret_ty -> (
            match
              resolve_function_return_annotation_type ctx ret_ty
              |> return_annotation_inference
            with
            | ReturnAnnotationGuidesInference ret_ty ->
                AnnotatedExpectedType ret_ty
            | ReturnAnnotationDoesNotGuideInference -> NoExpectedType)
        | None -> (
            (* Fall back to return type from call-site expected function type *)
            match expected_type_opt ctx with
            | Some (TyFunc { return; _ }) -> ExpectedType return
            | _ -> NoExpectedType)
      in

      (* Infer body type with expected return type for bidirectional inference *)
      let* body_type, typed_body =
        match func.func_body with
        | FuncBodyExpr body ->
            let body_ctx =
              match expected_return with
              | AnnotatedExpectedType ret_ty ->
                  with_annotated_expected ctx ret_ty
              | ExpectedType ret_ty -> with_expected ctx ret_ty
              | ExpectedValueSlot { expected_ty; slot_context } ->
                  with_expected_value_slot ctx expected_ty slot_context
              | NoExpectedType -> without_expected ctx
            in
            let* ty, body' = infer_expr body_ctx body in
            Ok (ty, Some body')
        | FuncBuiltinBody _ | FuncForeign _ | FuncNoBody -> Ok (ty_void, None)
      in

      (* Use annotated return type when present. The annotation is the declared contract;
     the body type was already checked against it via expected-type inference. *)
      let return_type =
        match func.func_return_type with
        | Some ret_ty -> resolve_function_return_annotation_type ctx ret_ty
        | None -> body_type
      in
      (* Validate no negative dimensions in the resolved return type *)
      let* () =
        match Types.Dim.find_negative return_type with
        | Some n ->
            let func_hint =
              match func.func_name with
              | Some f -> Printf.sprintf " in return type of '%s'" f
              | None -> ""
            in
            error expr.expr_loc
              (Printf.sprintf
                 "Dimension arithmetic produces non-positive result: %d%s \
                  (dimensions must be >= 1)"
                 n func_hint)
        | None -> Ok ()
      in
      let* () =
        match typed_body with
        | Some body when not (ctx_types_compatible ctx return_type body_type) ->
            let body_loc =
              match body.expr_desc with
              | EBlock exprs when exprs <> [] ->
                  (List.nth exprs (List.length exprs - 1)).expr_loc
              | _ -> body.expr_loc
            in
            error body_loc
              (Printf.sprintf
                 "Lambda returns wrong type\n    expected: %s\n       found: %s"
                 (type_to_string return_type)
                 (type_to_string body_type))
        | _ -> Ok ()
      in

      (* Infer lambda purity: if the user didn't write 'pure func' but the call-site
     expects a pure function, upgrade only when the shared purity analysis finds
     no impure calls in the typed body. *)
      let inferred_pure =
        func.func_is_pure
        ||
        match (expected_type_opt ctx, typed_body) with
        | Some expected_ty, Some body
          when Env.function_type_purity ctx.env expected_ty = Some Pure ->
            Purity_analysis.can_upgrade_lambda_body_to_pure ctx.env
              ctx.module_aliases body
        | _ -> false
      in
      let func_type =
        TyFunc
          {
            params = params_with_types;
            return = return_type;
            is_pure = inferred_pure;
          }
      in

      (* Write back inferred param types so downstream passes (core_lower's
     [require_type] on lambda params) can see the real types, not the
     [None] placeholders the parser left when the user omitted annotations. *)
      let func_params' =
        List.map2
          (fun (p : Ast.param) inferred_ty ->
            {
              p with
              param_type =
                Some (canonicalize_inferred_type_for_ast ctx inferred_ty);
            })
          func.func_params params_with_types
      in
      Ok
        ( func_type,
          with_inferred_desc expr
            (ELambda
               {
                 func with
                 func_is_pure = inferred_pure;
                 func_body =
                   (match typed_body with
                   | Some body -> FuncBodyExpr body
                   | None -> func.func_body);
                 func_return_type =
                   Option.map
                     (fun ty ->
                       resolve_function_return_annotation ctx ty
                       |> Type_resolution.source)
                     func.func_return_type;
                 func_params = func_params';
               })
            func_type )

let infer_expr_with_annotated_expected ctx expected_ty expr =
  infer_annotated_value_expr ctx expected_ty expr

let infer_expr_with_return_annotation ctx return_ty expr =
  match return_annotation_inference return_ty with
  | ReturnAnnotationGuidesInference expected_ty ->
      infer_annotated_value_expr ctx expected_ty expr
  | ReturnAnnotationDoesNotGuideInference ->
      infer_unconstrained_value_expr ctx expr
