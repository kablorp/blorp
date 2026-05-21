(** Built-in types and functions for the blorp environment.

    Registers primitive types (Int, Float, String, etc.),
    Boolean/Option constructors, core traits, arithmetic operations,
    I/O functions, type conversions, and unsafe arithmetic builtins. *)

open Ast
open Types
open Env

let generic_param name bounds = Generic_params.make_bound_type_param name bounds
let generic_type name bounds = TyBoundVar (generic_param name bounds)

(** Create an environment with built-in types and functions.

    Scope symbols (primitive type names, constructors, aliases, builtin
    function signatures) are added to [env] on every call — they live
    in the env's scope list, not in session state.

    Trait impls ([Integer for Int], [Equatable for String], …) are
    registered into the session's [impl_index] via [Env.add_impl].
    Multiple calls in one session would produce duplicate entries;
    [add_builtin_impl] below is a no-op on subsequent calls via the
    [sess.builtins_populated] flag. *)
let with_builtins (env : env) : env =
  let sess = Session.current () in
  let add_builtin_impl env impl =
    if sess.builtins_populated then env else add_impl env impl
  in
  let env =
    env
    (* Primitive types - no variants needed *)
    |> fun e ->
    add_symbol e
      {
        name = "Int";
        kind =
          TypeSymbol
            { type_params = []; variants = []; type_kind = TypeBuiltin };
      }
    |> fun e ->
    add_symbol e
      {
        name = "Float";
        kind =
          TypeSymbol
            { type_params = []; variants = []; type_kind = TypeBuiltin };
      }
    |> fun e ->
    add_symbol e
      {
        name = "Bool";
        kind =
          TypeSymbol
            { type_params = []; variants = []; type_kind = TypeBuiltin };
      }
    |> fun e ->
    add_symbol e
      {
        name = "String";
        kind =
          TypeSymbol
            { type_params = []; variants = []; type_kind = TypeBuiltin };
      }
    |> fun e ->
    add_symbol e
      {
        name = "Char";
        kind =
          TypeSymbol
            { type_params = []; variants = []; type_kind = TypeBuiltin };
      }
    |> fun e ->
    add_symbol e
      {
        name = "Void";
        kind =
          TypeSymbol
            { type_params = []; variants = []; type_kind = TypeBuiltin };
      }
    |> fun e ->
    add_symbol e
      {
        name = "Bytes";
        kind =
          TypeSymbol
            { type_params = []; variants = []; type_kind = TypeBuiltin };
      }
    |> fun e ->
    add_symbol e
      {
        name = "Ptr";
        kind =
          TypeSymbol
            { type_params = []; variants = []; type_kind = TypeBuiltin };
      }
    |> fun e ->
    add_symbol e
      {
        name = "Fixed";
        kind =
          TypeSymbol
            { type_params = []; variants = []; type_kind = TypeBuiltin };
      }
    (* Internal runtime array ABI type. Source programs use postfix T[#N] syntax. *)
    |> fun e ->
    add_symbol e
      {
        name = "Tensor";
        kind =
          TypeSymbol
            { type_params = [ "T" ]; variants = []; type_kind = TypeBuiltin };
      }
    (* Sized integer types *)
    |> fun e ->
    add_symbol e
      {
        name = "Int8";
        kind =
          TypeSymbol
            { type_params = []; variants = []; type_kind = TypeBuiltin };
      }
    |> fun e ->
    add_symbol e
      {
        name = "Int16";
        kind =
          TypeSymbol
            { type_params = []; variants = []; type_kind = TypeBuiltin };
      }
    |> fun e ->
    add_symbol e
      {
        name = "Int32";
        kind =
          TypeSymbol
            { type_params = []; variants = []; type_kind = TypeBuiltin };
      }
    |> fun e ->
    add_symbol e
      {
        name = "Int128";
        kind =
          TypeSymbol
            { type_params = []; variants = []; type_kind = TypeBuiltin };
      }
    |> fun e ->
    add_symbol e
      {
        name = "UInt8";
        kind =
          TypeSymbol
            { type_params = []; variants = []; type_kind = TypeBuiltin };
      }
    |> fun e ->
    add_symbol e
      {
        name = "UInt16";
        kind =
          TypeSymbol
            { type_params = []; variants = []; type_kind = TypeBuiltin };
      }
    |> fun e ->
    add_symbol e
      {
        name = "UInt32";
        kind =
          TypeSymbol
            { type_params = []; variants = []; type_kind = TypeBuiltin };
      }
    |> fun e ->
    add_symbol e
      {
        name = "UInt64";
        kind =
          TypeSymbol
            { type_params = []; variants = []; type_kind = TypeBuiltin };
      }
    |> fun e ->
    add_symbol e
      {
        name = "UInt128";
        kind =
          TypeSymbol
            { type_params = []; variants = []; type_kind = TypeBuiltin };
      }
    (* Sized float types *)
    |> fun e ->
    add_symbol e
      {
        name = "Float32";
        kind =
          TypeSymbol
            { type_params = []; variants = []; type_kind = TypeBuiltin };
      }
    |> fun e ->
    add_symbol e
      {
        name = "Float16";
        kind =
          TypeSymbol
            { type_params = []; variants = []; type_kind = TypeBuiltin };
      }
  in

  (* Int64 is an alias for Int *)
  let env = add_alias env "Int64" [] (TyNamed ("Int", [])) in

  (* Option type and constructors (auto-imported).
     [variant_def_id = None] here because these variants are emitted via
     runtime helpers ([blorp_option_some], [blorp_option_none]) rather
     than user-generated C functions. No downstream consumer reads the
     DefId off an env-builtin variant. std/option.brp's own [union]
     declaration, when loaded, mints [Some id] on its own AST copies
     via [second_pass]. *)
  let env =
    add_symbol env
      {
        name = "Option";
        kind =
          TypeSymbol
            {
              type_params = [ "T" ];
              type_kind = TypeBuiltin;
              variants =
                [
                  {
                    variant_name = "Some";
                    variant_fields = [ TyVar "T" ];
                    variant_tag = 0;
                    variant_loc = dummy_loc;
                    variant_def_id = None;
                  };
                  {
                    variant_name = "None";
                    variant_fields = [];
                    variant_tag = 1;
                    variant_loc = dummy_loc;
                    variant_def_id = None;
                  };
                ];
            };
      }
  in
  let env =
    add_symbol env
      {
        name = "Some";
        kind =
          ConstructorSymbol
            {
              parent_type = "Option";
              constructor_id = Session.mint_def_id (Session.current ());
              type_params = [ "T" ];
              field_types = [ TyVar "T" ];
              tag = 0;
            };
      }
  in
  let env =
    add_symbol env
      {
        name = "None";
        kind =
          ConstructorSymbol
            {
              parent_type = "Option";
              constructor_id = Session.mint_def_id (Session.current ());
              type_params = [ "T" ];
              field_types = [];
              tag = 1;
            };
      }
  in

  (* Result type and constructors (auto-imported). See Option comment
     above for why [variant_def_id = None]. *)
  let env =
    add_symbol env
      {
        name = "Result";
        kind =
          TypeSymbol
            {
              type_params = [ "T"; "E" ];
              type_kind = TypeBuiltin;
              variants =
                [
                  {
                    variant_name = "Ok";
                    variant_fields = [ TyVar "T" ];
                    variant_tag = 0;
                    variant_loc = dummy_loc;
                    variant_def_id = None;
                  };
                  {
                    variant_name = "Err";
                    variant_fields = [ TyVar "E" ];
                    variant_tag = 1;
                    variant_loc = dummy_loc;
                    variant_def_id = None;
                  };
                ];
            };
      }
  in
  let env =
    add_symbol env
      {
        name = "Ok";
        kind =
          ConstructorSymbol
            {
              parent_type = "Result";
              constructor_id = Session.mint_def_id (Session.current ());
              type_params = [ "T"; "E" ];
              field_types = [ TyVar "T" ];
              tag = 0;
            };
      }
  in
  let env =
    add_symbol env
      {
        name = "Err";
        kind =
          ConstructorSymbol
            {
              parent_type = "Result";
              constructor_id = Session.mint_def_id (Session.current ());
              type_params = [ "T"; "E" ];
              field_types = [ TyVar "E" ];
              tag = 1;
            };
      }
  in
  (* ========================================================================
     Numeric type family traits — Integer, SignedInteger, UnsignedInteger,
     FloatingPoint, FixedPoint.  Trait definitions live in std/traits.brp;
     here we register trait defs + impls so they're always available.
     ======================================================================== *)
  let no_methods = [] in

  (* Helper: construct a trait_method_sig for a no-default, built-in
     trait method. All builtin trait methods in env_builtins share the
     same shape ([tm_has_default = false], no default body, anonymous
     params), so this cuts per-method noise and makes future field
     additions single-edit. *)
  let method_sig ~name ~params ~ret ~is_pure : Env.trait_method_sig =
    {
      tm_name = name;
      tm_params = params;
      tm_return = ret;
      tm_is_pure = is_pure;
      tm_has_default = false;
      tm_default_body = None;
      tm_param_names = [];
    }
  in

  (* Absolute trait — single method [abs]. Supertrait of Integer and FloatingPoint.
     Defined in std/traits.brp; registered here so [abs] resolves without
     requiring [traits] to be imported. *)
  let env =
    add_trait env
      {
        td_def_id = Session.mint_def_id (Session.current ());
        td_name = "Absolute";
        td_type_params = [];
        td_supertraits = [];
        td_methods =
          [
            method_sig ~name:"abs" ~params:[ TySelf ] ~ret:TySelf ~is_pure:true;
          ];
        td_loc = None;
        td_module_path = None;
      }
  in

  (* Bounded trait — [min]/[max]. Supertrait of Integer and FloatingPoint.
     Registered here so the bare [min]/[max] calls resolve on primitive
     numeric types without a [traits] import. *)
  let env =
    add_trait env
      {
        td_def_id = Session.mint_def_id (Session.current ());
        td_name = "Bounded";
        td_type_params = [];
        td_supertraits = [];
        td_methods =
          [
            method_sig ~name:"min" ~params:[ TySelf; TySelf ] ~ret:TySelf
              ~is_pure:true;
            method_sig ~name:"max" ~params:[ TySelf; TySelf ] ~ret:TySelf
              ~is_pure:true;
          ];
        td_loc = None;
        td_module_path = None;
      }
  in

  (* Integer trait — supertraits defined in std/traits.brp, we just register the trait + impls *)
  let env =
    add_trait env
      {
        td_def_id = Session.mint_def_id (Session.current ());
        td_name = "Integer";
        td_type_params = [];
        td_supertraits =
          [
            "Addable";
            "Subtractable";
            "Multipliable";
            "Divisible";
            "Modulable";
            "Orderable";
            "HasZero";
            "HasOne";
            "Stringable";
            "Absolute";
            "Bounded";
            "ToInt";
          ];
        td_methods =
          [
            method_sig ~name:"checked_div" ~params:[ TySelf; TySelf ]
              ~ret:(TyNamed ("Option", [ TySelf ]))
              ~is_pure:true;
            method_sig ~name:"checked_mod" ~params:[ TySelf; TySelf ]
              ~ret:(TyNamed ("Option", [ TySelf ]))
              ~is_pure:true;
            method_sig ~name:"bit_and" ~params:[ TySelf; TySelf ] ~ret:TySelf
              ~is_pure:true;
            method_sig ~name:"bit_or" ~params:[ TySelf; TySelf ] ~ret:TySelf
              ~is_pure:true;
            method_sig ~name:"bit_xor" ~params:[ TySelf; TySelf ] ~ret:TySelf
              ~is_pure:true;
            method_sig ~name:"bit_not" ~params:[ TySelf ] ~ret:TySelf
              ~is_pure:true;
            method_sig ~name:"shift_left" ~params:[ TySelf; ty_int ] ~ret:TySelf
              ~is_pure:true;
            method_sig ~name:"shift_right" ~params:[ TySelf; ty_int ]
              ~ret:TySelf ~is_pure:true;
          ];
        td_loc = None;
        td_module_path = None;
      }
  in
  let env =
    add_trait env
      {
        td_def_id = Session.mint_def_id (Session.current ());
        td_name = "SignedInteger";
        td_type_params = [];
        td_supertraits = [ "Integer"; "Negatable" ];
        td_methods = no_methods;
        td_loc = None;
        td_module_path = None;
      }
  in
  let env =
    add_trait env
      {
        td_def_id = Session.mint_def_id (Session.current ());
        td_name = "UnsignedInteger";
        td_type_params = [];
        td_supertraits = [ "Integer" ];
        td_methods = no_methods;
        td_loc = None;
        td_module_path = None;
      }
  in

  (* Register Integer impls for all integer types *)
  let signed_int_types =
    [ "Int"; "Int8"; "Int16"; "Int32"; "Int64"; "Int128" ]
  in
  let unsigned_int_types =
    [ "UInt8"; "UInt16"; "UInt32"; "UInt64"; "UInt128" ]
  in
  let env =
    List.fold_left
      (fun env ty_name ->
        let ty = TyNamed (ty_name, []) in
        let env =
          add_builtin_impl env
            {
              ii_def_id = Session.mint_def_id (Session.current ());
              ii_trait = "Integer";
              ii_for_type = ty;
              ii_bounds = [];
              ii_is_builtin = true;
              ii_loc = None;
            }
        in
        add_builtin_impl env
          {
            ii_def_id = Session.mint_def_id (Session.current ());
            ii_trait = "SignedInteger";
            ii_for_type = ty;
            ii_bounds = [];
            ii_is_builtin = true;
            ii_loc = None;
          })
      env signed_int_types
  in
  let env =
    List.fold_left
      (fun env ty_name ->
        let ty = TyNamed (ty_name, []) in
        let env =
          add_builtin_impl env
            {
              ii_def_id = Session.mint_def_id (Session.current ());
              ii_trait = "Integer";
              ii_for_type = ty;
              ii_bounds = [];
              ii_is_builtin = true;
              ii_loc = None;
            }
        in
        add_builtin_impl env
          {
            ii_def_id = Session.mint_def_id (Session.current ());
            ii_trait = "UnsignedInteger";
            ii_for_type = ty;
            ii_bounds = [];
            ii_is_builtin = true;
            ii_loc = None;
          })
      env unsigned_int_types
  in

  (* FloatingPoint trait *)
  let env =
    add_trait env
      {
        td_def_id = Session.mint_def_id (Session.current ());
        td_name = "FloatingPoint";
        td_type_params = [];
        td_supertraits =
          [
            "Addable";
            "Subtractable";
            "Multipliable";
            "Divisible";
            "Negatable";
            "Orderable";
            "HasZero";
            "HasOne";
            "Stringable";
            "Absolute";
            "Bounded";
            "ToFloat";
          ];
        td_methods =
          [
            method_sig ~name:"floor" ~params:[ TySelf ] ~ret:TySelf
              ~is_pure:true;
            method_sig ~name:"ceil" ~params:[ TySelf ] ~ret:TySelf ~is_pure:true;
            method_sig ~name:"round" ~params:[ TySelf ] ~ret:TySelf
              ~is_pure:true;
            method_sig ~name:"trunc" ~params:[ TySelf ] ~ret:TySelf
              ~is_pure:true;
            method_sig ~name:"sqrt" ~params:[ TySelf ] ~ret:TySelf ~is_pure:true;
            method_sig ~name:"sin" ~params:[ TySelf ] ~ret:TySelf ~is_pure:true;
            method_sig ~name:"cos" ~params:[ TySelf ] ~ret:TySelf ~is_pure:true;
            method_sig ~name:"tan" ~params:[ TySelf ] ~ret:TySelf ~is_pure:true;
            method_sig ~name:"asin" ~params:[ TySelf ] ~ret:TySelf ~is_pure:true;
            method_sig ~name:"acos" ~params:[ TySelf ] ~ret:TySelf ~is_pure:true;
            method_sig ~name:"atan" ~params:[ TySelf ] ~ret:TySelf ~is_pure:true;
            method_sig ~name:"atan2" ~params:[ TySelf; TySelf ] ~ret:TySelf
              ~is_pure:true;
            method_sig ~name:"sinh" ~params:[ TySelf ] ~ret:TySelf ~is_pure:true;
            method_sig ~name:"cosh" ~params:[ TySelf ] ~ret:TySelf ~is_pure:true;
            method_sig ~name:"tanh" ~params:[ TySelf ] ~ret:TySelf ~is_pure:true;
            method_sig ~name:"asinh" ~params:[ TySelf ] ~ret:TySelf
              ~is_pure:true;
            method_sig ~name:"acosh" ~params:[ TySelf ] ~ret:TySelf
              ~is_pure:true;
            method_sig ~name:"atanh" ~params:[ TySelf ] ~ret:TySelf
              ~is_pure:true;
            method_sig ~name:"exp" ~params:[ TySelf ] ~ret:TySelf ~is_pure:true;
            method_sig ~name:"exp2" ~params:[ TySelf ] ~ret:TySelf ~is_pure:true;
            method_sig ~name:"expm1" ~params:[ TySelf ] ~ret:TySelf
              ~is_pure:true;
            method_sig ~name:"log" ~params:[ TySelf ] ~ret:TySelf ~is_pure:true;
            method_sig ~name:"log2" ~params:[ TySelf ] ~ret:TySelf ~is_pure:true;
            method_sig ~name:"log10" ~params:[ TySelf ] ~ret:TySelf
              ~is_pure:true;
            method_sig ~name:"log1p" ~params:[ TySelf ] ~ret:TySelf
              ~is_pure:true;
            method_sig ~name:"pow" ~params:[ TySelf; TySelf ] ~ret:TySelf
              ~is_pure:true;
            method_sig ~name:"cbrt" ~params:[ TySelf ] ~ret:TySelf ~is_pure:true;
            method_sig ~name:"hypot" ~params:[ TySelf; TySelf ] ~ret:TySelf
              ~is_pure:true;
            method_sig ~name:"fmod" ~params:[ TySelf; TySelf ] ~ret:TySelf
              ~is_pure:true;
            method_sig ~name:"copysign" ~params:[ TySelf; TySelf ] ~ret:TySelf
              ~is_pure:true;
            method_sig ~name:"fma" ~params:[ TySelf; TySelf; TySelf ]
              ~ret:TySelf ~is_pure:true;
            method_sig ~name:"is_nan" ~params:[ TySelf ] ~ret:ty_bool
              ~is_pure:true;
            method_sig ~name:"is_inf" ~params:[ TySelf ] ~ret:ty_bool
              ~is_pure:true;
            method_sig ~name:"is_finite" ~params:[ TySelf ] ~ret:ty_bool
              ~is_pure:true;
          ];
        td_loc = None;
        td_module_path = None;
      }
  in
  let float_types = [ "Float"; "Float32"; "Float16" ] in
  let env =
    List.fold_left
      (fun env ty_name ->
        let ty = TyNamed (ty_name, []) in
        add_builtin_impl env
          {
            ii_def_id = Session.mint_def_id (Session.current ());
            ii_trait = "FloatingPoint";
            ii_for_type = ty;
            ii_bounds = [];
            ii_is_builtin = true;
            ii_loc = None;
          })
      env float_types
  in

  (* FixedPoint trait — Fixed has signed arithmetic, so [abs] (via Absolute)
     and [min]/[max] (via Bounded) are meaningful operations. Mirrors
     Integer/FloatingPoint supertrait lists. *)
  let env =
    add_trait env
      {
        td_def_id = Session.mint_def_id (Session.current ());
        td_name = "FixedPoint";
        td_type_params = [];
        td_supertraits =
          [
            "Addable";
            "Subtractable";
            "Multipliable";
            "Divisible";
            "Orderable";
            "HasZero";
            "Stringable";
            "Absolute";
            "Bounded";
          ];
        td_methods =
          [
            method_sig ~name:"get_scale" ~params:[ TySelf ] ~ret:ty_int
              ~is_pure:true;
            method_sig ~name:"round_to" ~params:[ TySelf; ty_int ] ~ret:TySelf
              ~is_pure:true;
          ];
        td_loc = None;
        td_module_path = None;
      }
  in
  let env =
    add_builtin_impl env
      {
        ii_def_id = Session.mint_def_id (Session.current ());
        ii_trait = "FixedPoint";
        ii_for_type = TyNamed ("Fixed", []);
        ii_bounds = [];
        ii_is_builtin = true;
        ii_loc = None;
      }
  in

  (* Register trait method -> trait name mappings for dispatch *)
  let env =
    List.fold_left
      (fun env m -> add_trait_function env m "Integer")
      env
      [
        "checked_div";
        "checked_mod";
        "bit_and";
        "bit_or";
        "bit_xor";
        "bit_not";
        "shift_left";
        "shift_right";
      ]
  in
  let env =
    List.fold_left
      (fun env m -> add_trait_function env m "FloatingPoint")
      env
      [
        "floor";
        "ceil";
        "round";
        "trunc";
        "sqrt";
        "sin";
        "cos";
        "tan";
        "asin";
        "acos";
        "atan";
        "atan2";
        "sinh";
        "cosh";
        "tanh";
        "asinh";
        "acosh";
        "atanh";
        "exp";
        "exp2";
        "expm1";
        "log";
        "log2";
        "log10";
        "log1p";
        "pow";
        "cbrt";
        "hypot";
        "fmod";
        "copysign";
        "fma";
        "is_nan";
        "is_inf";
        "is_finite";
      ]
  in
  (* [abs] lives on the [Absolute] supertrait (declared in std/traits.brp but
     used unqualified at builtin types). Register it here so typecheck finds
     it for primitive numeric types without requiring a [traits] import. *)
  let env = add_trait_function env "abs" "Absolute" in
  let env = add_trait_function env "min" "Bounded" in
  let env = add_trait_function env "max" "Bounded" in
  let env =
    List.fold_left
      (fun env m -> add_trait_function env m "FixedPoint")
      env
      [ "get_scale"; "round_to" ]
  in

  (* I/O, env, and file-system builtins migrated to std/prelude.brp
     (2026-04-24). Signatures flow in via [Typecheck.prepend_prelude_imports]
     on both the main program and every loaded module.
     Remaining hardcoded entries below are generic conversions whose codegen
     dispatch depends on the concrete argument type. Domain-module wrappers
     live in std modules where they remain part of the public API. *)

  (* Generic conversion builtins - codegen handles type dispatch *)
  let ty_any = TyVar "T" in
  let ty_char = TyNamed ("Char", []) in
  let ty_fixed = TyNamed ("Fixed", []) in
  (* to_string is an abstract function in Prelude.brp, so it needs type_params for signature validation *)
  let env =
    add_func env "to_string"
      (ty_func [ ty_any ] ty_string ~pure:true)
      ~type_params:[ generic_param "T" [ "Stringable" ] ]
      ~purity:Pure ~origin:Builtin ()
  in
  (* debug_string lives in std/debug as an explicit @debug_only API. The
     Core pipeline still specializes its builtin body per call site; keeping
     it out of the global builtins prevents debug helpers from widening the
     prelude surface. *)
  (* These are concrete builtins, not abstract functions *)
  let env =
    add_func env "to_int"
      (ty_func [ ty_any ] ty_int ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  let env =
    add_func env "to_float"
      (ty_func [ ty_any ] ty_float ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  let env =
    add_func env "to_bool"
      (ty_func [ ty_any ] ty_bool ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  let env =
    add_func env "to_char"
      (ty_func [ ty_any ] ty_char ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  let env =
    add_func env "from_char"
      (ty_func [ ty_char ] ty_string ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  let env =
    add_func env "from_chars"
      (ty_func [ TyNamed ("List", [ ty_char ]) ] ty_string ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  let env =
    add_func env "fixed"
      (ty_func [ ty_float; ty_int ] ty_fixed ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  let env =
    add_func env "equals"
      (ty_func [ ty_any; ty_any ] ty_bool ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  let env =
    add_func env "length"
      (ty_func [ ty_any ] ty_int ~pure:true)
      ~type_params:[ generic_param "T" [] ]
      ~purity:Pure ~origin:Builtin ()
  in
  let env = add_trait_function env "length" "HasLength" in
  (* Register builtin generic functions as trait functions so that
     calling them on unbounded type params requires the appropriate bound *)
  let env = add_trait_function env "equals" "Equatable" in
  let env = add_trait_function env "to_string" "Stringable" in
  let env = add_trait_function env "to_int" "ToInt" in
  let env = add_trait_function env "to_float" "ToFloat" in
  (* HasLength builtin impls previously registered here; now covered by
     [std/prelude.brp]'s [list/dict/set/string/bytes { Type }] imports
     which trigger [register_ufcs_methods_for_type] before user programs
     typecheck. Arrays are structural, so they remain hardcoded. *)
  let has_length_types = [ TyArray (TyVar "T", [ TyVarDims "#Ds" ]) ] in
  let env =
    List.fold_left
      (fun env ty ->
        add_builtin_impl env
          {
            ii_def_id = Session.mint_def_id (Session.current ());
            ii_trait = "HasLength";
            ii_for_type = ty;
            ii_bounds = [];
            ii_is_builtin = true;
            ii_loc = None;
          })
      env has_length_types
  in

  (* Stringable builtin impls previously registered here; List/Dict/Set/
     String/Bool/Char/Bytes now arrive via [std/prelude.brp] type imports.
     Arrays are structural, so they remain hardcoded. *)
  let stringable_types = [ TyArray (TyVar "T", [ TyVarDims "#Ds" ]) ] in
  let env =
    List.fold_left
      (fun env ty ->
        add_builtin_impl env
          {
            ii_def_id = Session.mint_def_id (Session.current ());
            ii_trait = "Stringable";
            ii_for_type = ty;
            ii_bounds = [];
            ii_is_builtin = true;
            ii_loc = None;
          })
      env stringable_types
  in

  (* Register Equatable impls for types that need == support.
     Primitives get Equatable via Integer/FloatingPoint supertraits.
     Option/Result/String need explicit registration. *)
  let equatable_simple =
    [
      TyNamed ("String", []);
      TyNamed ("Bool", []);
      TyNamed ("Char", []);
      TyNamed ("Bytes", []);
    ]
  in
  let env =
    List.fold_left
      (fun env ty ->
        add_builtin_impl env
          {
            ii_def_id = Session.mint_def_id (Session.current ());
            ii_trait = "Equatable";
            ii_for_type = ty;
            ii_bounds = [];
            ii_is_builtin = true;
            ii_loc = None;
          })
      env equatable_simple
  in
  let env =
    add_builtin_impl env
      {
        ii_def_id = Session.mint_def_id (Session.current ());
        ii_trait = "Equatable";
        ii_for_type = TyNamed ("Option", [ generic_type "T" [ "Equatable" ] ]);
        ii_bounds = [ Generic_params.make_bound_type_param "T" [ "Equatable" ] ];
        ii_is_builtin = true;
        ii_loc = None;
      }
  in
  let env =
    add_builtin_impl env
      {
        ii_def_id = Session.mint_def_id (Session.current ());
        ii_trait = "Equatable";
        ii_for_type =
          TyNamed
            ( "Result",
              [
                generic_type "T" [ "Equatable" ];
                generic_type "E" [ "Equatable" ];
              ] );
        ii_bounds =
          [
            Generic_params.make_bound_type_param "T" [ "Equatable" ];
            Generic_params.make_bound_type_param "E" [ "Equatable" ];
          ];
        ii_is_builtin = true;
        ii_loc = None;
      }
  in
  let env =
    add_builtin_impl env
      {
        ii_def_id = Session.mint_def_id (Session.current ());
        ii_trait = "Equatable";
        ii_for_type = TyNamed ("List", [ generic_type "T" [ "Equatable" ] ]);
        ii_bounds = [ Generic_params.make_bound_type_param "T" [ "Equatable" ] ];
        ii_is_builtin = true;
        ii_loc = None;
      }
  in

  (* String implements Orderable — comparison uses blorp_string_compare at codegen level *)
  let env =
    add_builtin_impl env
      {
        ii_def_id = Session.mint_def_id (Session.current ());
        ii_trait = "Orderable";
        ii_for_type = TyNamed ("String", []);
        ii_bounds = [];
        ii_is_builtin = true;
        ii_loc = None;
      }
  in

  (* Hashable trait — declared here as an env_builtin stub so
     [T: Hashable] bounds and impl supertrait checks work without
     requiring [import: traits]. The authoritative declaration lives
     in [std/traits.brp]; [try_add_trait]'s stub-replacement path
     swaps this entry for the source-declared one once the traits
     module has been loaded. Supertrait [Equatable] propagates the
     `a == b ⇒ hash(a) == hash(b)` contract to the type system. *)
  let env =
    add_trait env
      {
        td_def_id = Session.mint_def_id (Session.current ());
        td_name = "Hashable";
        td_type_params = [];
        td_supertraits = [ "Equatable" ];
        td_methods =
          [
            method_sig ~name:"hash" ~params:[ TySelf ] ~ret:ty_int ~is_pure:true;
          ];
        td_loc = None;
        td_module_path = None;
      }
  in

  (* Hashable impls for primitive types. All route to the runtime's
     seeded wyhash-class functions ([blorp_dict_hash_int],
     [blorp_dict_hash_string] et al.) at codegen; the impl itself
     is a builtin with no source-level body. *)
  let hashable_primitives =
    [
      TyNamed ("Int", []);
      TyNamed ("Int8", []);
      TyNamed ("Int16", []);
      TyNamed ("Int32", []);
      TyNamed ("Int64", []);
      TyNamed ("Int128", []);
      TyNamed ("UInt8", []);
      TyNamed ("UInt16", []);
      TyNamed ("UInt32", []);
      TyNamed ("UInt64", []);
      TyNamed ("UInt128", []);
      TyNamed ("Float", []);
      TyNamed ("Float32", []);
      Types.ty_float16;
      TyNamed ("Bool", []);
      TyNamed ("Char", []);
      TyNamed ("String", []);
    ]
  in
  let env =
    List.fold_left
      (fun env ty ->
        add_builtin_impl env
          {
            ii_def_id = Session.mint_def_id (Session.current ());
            ii_trait = "Hashable";
            ii_for_type = ty;
            ii_bounds = [];
            ii_is_builtin = true;
            ii_loc = None;
          })
      env hashable_primitives
  in

  (* [hash] as a trait function: enables bare-name dispatch
     [hash(x)] and UFCS [x.hash()] on any type with a Hashable
     impl in scope. Mirrors [to_string -> Stringable] and
     [equals -> Equatable] in this registry. *)
  let env = add_trait_function env "hash" "Hashable" in

  (* Builtin signature for [hash] so typecheck accepts it as a call
     on primitive types before specialize pins the concrete runtime
     function. Uses [ty_any] for the arg to match the polymorphic
     dispatch pattern; specialize routes by receiver type. *)
  let env =
    add_func env "hash"
      (ty_func [ ty_any ] ty_int ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in

  (* [hash_combine(seed, value)] — binary hash mixer for multi-field
     Hashable impls. Global builtin (no import needed) so user code
     can write
       pure func hash(self: T) -> Int:
           var h: Int = self.x.hash()
           h = hash_combine(h, self.y.hash())
           h
     without taking a dependency on a helper module. Not
     commutative by design — swapping seed/value changes the output
     so field order is preserved in the chain. *)
  let env =
    add_func env "hash_combine"
      (ty_func [ ty_int; ty_int ] ty_int ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in

  (* Sized integer conversion builtins (pure) *)
  let env =
    add_func env "to_int8"
      (ty_func [ ty_any ] ty_int8 ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  let env =
    add_func env "to_int16"
      (ty_func [ ty_any ] ty_int16 ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  let env =
    add_func env "to_int32"
      (ty_func [ ty_any ] ty_int32 ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  let env =
    add_func env "to_int128"
      (ty_func [ ty_any ] ty_int128 ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  let env =
    add_func env "to_uint8"
      (ty_func [ ty_any ] ty_uint8 ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  let env =
    add_func env "to_uint16"
      (ty_func [ ty_any ] ty_uint16 ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  let env =
    add_func env "to_uint32"
      (ty_func [ ty_any ] ty_uint32 ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  let env =
    add_func env "to_uint64"
      (ty_func [ ty_any ] ty_uint64 ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  let env =
    add_func env "to_uint128"
      (ty_func [ ty_any ] ty_uint128 ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in

  (* Sized float conversion builtins (pure) *)
  let env =
    add_func env "to_float32"
      (ty_func [ ty_any ] ty_float32 ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  let env =
    add_func env "to_float16"
      (ty_func [ ty_any ] Types.ty_float16 ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in

  (* Bitwise operations (pure, work on all integer types) *)
  let env =
    add_func env "bit_and"
      (ty_func [ ty_any; ty_any ] ty_any ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  let env =
    add_func env "bit_or"
      (ty_func [ ty_any; ty_any ] ty_any ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  let env =
    add_func env "bit_xor"
      (ty_func [ ty_any; ty_any ] ty_any ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  let env =
    add_func env "bit_not"
      (ty_func [ ty_any ] ty_any ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  let env =
    add_func env "shift_left"
      (ty_func [ ty_any; ty_int ] ty_any ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  let env =
    add_func env "shift_right"
      (ty_func [ ty_any; ty_int ] ty_any ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in

  (* Checked arithmetic (opt-in Option-returning division) *)
  let env =
    add_func env "checked_div"
      (ty_func [ ty_int; ty_int ] (TyNamed ("Option", [ ty_int ])) ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  let env =
    add_func env "checked_mod"
      (ty_func [ ty_int; ty_int ] (TyNamed ("Option", [ ty_int ])) ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in

  (* [type_name] and [is_heap] were previously always-available prelude
     builtins. They are now scoped to [std/debug] — users must explicitly
     [import: debug: type_name] to use them. This forces reflection
     to appear as a visible import at every use site, keeping it out of
     production code paths by default. *)

  (* Shape assertion: T[#Ds...] + expected_len -> Option[T[#Ds...]] *)
  let env =
    add_func env "assert_shape"
      (ty_func
         [ TyArray (TyVar "T", [ TyVarDims "#Ds" ]); ty_int ]
         (TyNamed ("Option", [ TyArray (TyVar "T", [ TyVarDims "#Ds" ]) ]))
         ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in

  (* Compile-time bounds-checked subscript operations (desugared from x[i], x[i]=v, x[s..e])
     checked_get: generic peeling — single index on any-dim tensor
     checked_set: 1D element write with COW
     checked_slice: 1D range slice
     matrix_checked_get/set: 2D flat element access
     tensor3..5_checked_get/set: 3-5D flat element access *)
  let env =
    add_func env "checked_get"
      (ty_func [ TyVar "T"; ty_int ] (TyVar "T") ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  (* tensor_peel: single-index peel on multi-dim tensors. Emitted by infer
     when checked_get would return a sub-tensor (not a scalar). Core_specialize
     rewrites the 2-arg form into blorp_tensor_slice_row with the concrete
     row_size / result_first_dim extracted from the collection's type. *)
  let env =
    add_func env "tensor_peel"
      (ty_func [ TyVar "T"; ty_int ] (TyVar "T") ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  let env =
    add_func env "checked_set"
      (ty_func [ TyVar "T"; ty_int; TyVar "T" ] (TyVar "T") ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  let env =
    add_func env "checked_slice"
      (ty_func [ TyVar "T"; ty_int; ty_int ] (TyVar "T") ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  let env =
    add_func env "matrix_checked_get"
      (ty_func [ TyVar "T"; ty_int; ty_int ] (TyVar "T") ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  let env =
    add_func env "matrix_checked_set"
      (ty_func [ TyVar "T"; ty_int; ty_int; TyVar "T" ] (TyVar "T") ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  let env =
    add_func env "tensor3_checked_get"
      (ty_func [ TyVar "T"; ty_int; ty_int; ty_int ] (TyVar "T") ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  let env =
    add_func env "tensor3_checked_set"
      (ty_func
         [ TyVar "T"; ty_int; ty_int; ty_int; TyVar "T" ]
         (TyVar "T") ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  let env =
    add_func env "tensor4_checked_get"
      (ty_func
         [ TyVar "T"; ty_int; ty_int; ty_int; ty_int ]
         (TyVar "T") ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  let env =
    add_func env "tensor4_checked_set"
      (ty_func
         [ TyVar "T"; ty_int; ty_int; ty_int; ty_int; TyVar "T" ]
         (TyVar "T") ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  let env =
    add_func env "tensor5_checked_get"
      (ty_func
         [ TyVar "T"; ty_int; ty_int; ty_int; ty_int; ty_int ]
         (TyVar "T") ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  let env =
    add_func env "tensor5_checked_set"
      (ty_func
         [ TyVar "T"; ty_int; ty_int; ty_int; ty_int; ty_int; TyVar "T" ]
         (TyVar "T") ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in

  (* Array constructors — all pure (referentially transparent, explicit dimensions) *)
  let env =
    add_func env "vector"
      (ty_func [ TyVar "T"; ty_int ]
         (TyArray (TyVar "T", [ TyVar "#N" ]))
         ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  let env =
    add_func env "matrix"
      (ty_func
         [ TyVar "T"; ty_int; ty_int ]
         (TyArray (TyVar "T", [ TyVar "#N"; TyVar "#M" ]))
         ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  let env =
    add_func env "tensor3"
      (ty_func
         [ TyVar "T"; ty_int; ty_int; ty_int ]
         (TyArray (TyVar "T", [ TyVar "#X"; TyVar "#Y"; TyVar "#Z" ]))
         ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  let env =
    add_func env "tensor4"
      (ty_func
         [ TyVar "T"; ty_int; ty_int; ty_int; ty_int ]
         (TyArray (TyVar "T", [ TyVar "#A"; TyVar "#B"; TyVar "#C"; TyVar "#D" ]))
         ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in
  let env =
    add_func env "tensor5"
      (ty_func
         [ TyVar "T"; ty_int; ty_int; ty_int; ty_int; ty_int ]
         (TyArray
            ( TyVar "T",
              [ TyVar "#A"; TyVar "#B"; TyVar "#C"; TyVar "#D"; TyVar "#E" ] ))
         ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in

  (* enumerate2 — 2D loop combinator: for (i, j, val) in enumerate2(matrix).
     enumerate/windows are declared in std/tensor and imported explicitly
     where needed. *)
  let env =
    add_func env "enumerate2"
      (ty_func
         [ TyArray (TyVar "T", [ TyVar "#M"; TyVar "#N" ]) ]
         (TyNamed ("List", [ TyTuple [ ty_int; ty_int; TyVar "T" ] ]))
         ~pure:true)
      ~purity:Pure ~origin:Builtin ~loop_producer:LoopProducerEnumerate2 ()
  in
  (* zip — parallel tensor/vector iteration. Keep the builtin signature in
     sync with runtime dispatch ([blorp_vector_zip] returns blorp_Vector ptr),
     otherwise for-loops can infer a List iterator but emit a Vector call. *)
  let env =
    add_func env "zip"
      (ty_func
         [
           TyArray (TyVar "T", [ TyVar "#N" ]);
           TyArray (TyVar "U", [ TyVar "#N" ]);
         ]
         (TyArray (TyTuple [ TyVar "T"; TyVar "U" ], [ TyVar "#N" ]))
         ~pure:true)
      ~purity:Pure ~origin:Builtin ()
  in

  (* ConcurrencyError type and constructors (auto-imported for concurrent: blocks).
     See Option comment above for why [variant_def_id = None]. *)
  let env =
    add_symbol env
      {
        name = "ConcurrencyError";
        kind =
          TypeSymbol
            {
              type_params = [];
              type_kind = TypeBuiltin;
              variants =
                [
                  {
                    variant_name = "Timeout";
                    variant_fields = [];
                    variant_tag = 0;
                    variant_loc = dummy_loc;
                    variant_def_id = None;
                  };
                  {
                    variant_name = "TaskFailed";
                    variant_fields = [ ty_string ];
                    variant_tag = 1;
                    variant_loc = dummy_loc;
                    variant_def_id = None;
                  };
                ];
            };
      }
  in
  let env =
    add_symbol env
      {
        name = "Timeout";
        kind =
          ConstructorSymbol
            {
              parent_type = "ConcurrencyError";
              constructor_id = Session.mint_def_id (Session.current ());
              type_params = [];
              field_types = [];
              tag = 0;
            };
      }
  in
  let env =
    add_symbol env
      {
        name = "TaskFailed";
        kind =
          ConstructorSymbol
            {
              parent_type = "ConcurrencyError";
              constructor_id = Session.mint_def_id (Session.current ());
              type_params = [];
              field_types = [ ty_string ];
              tag = 1;
            };
      }
  in

  (* Concurrency builtins (sleep, max_threads — concurrent blocks and detach replaced spawn/join) *)
  let ty_t = TyVar "T" in
  let env =
    add_func env "sleep" (ty_func [ ty_int ] ty_void) ~origin:Builtin ()
  in
  let env =
    add_func env "max_threads" (ty_func [] ty_int) ~purity:Pure ~origin:Builtin
      ()
  in

  (* Channel type for bounded MPMC channels *)
  let env =
    add_symbol env
      {
        name = "Channel";
        kind =
          TypeSymbol
            { type_params = [ "T" ]; variants = []; type_kind = TypeBuiltin };
      }
  in

  (* Channel builtins (impure - block on send/recv, close) *)
  let ty_channel_t = TyNamed ("Channel", [ ty_t ]) in
  let ty_option_t = TyNamed ("Option", [ ty_t ]) in
  let env =
    add_func env "channel"
      (ty_func [ ty_int ] ty_channel_t)
      ~type_params:[ generic_param "T" [] ]
      ~origin:Builtin ()
  in
  let env =
    add_func env "send"
      (ty_func [ ty_channel_t; ty_t ] ty_bool)
      ~type_params:[ generic_param "T" [] ]
      ~origin:Builtin ()
  in
  let env =
    add_func env "recv"
      (ty_func [ ty_channel_t ] ty_option_t)
      ~type_params:[ generic_param "T" [] ]
      ~origin:Builtin ()
  in
  let env =
    add_func env "try_send"
      (ty_func [ ty_channel_t; ty_t ] ty_bool)
      ~type_params:[ generic_param "T" [] ]
      ~origin:Builtin ()
  in
  let env =
    add_func env "try_recv"
      (ty_func [ ty_channel_t ] ty_option_t)
      ~type_params:[ generic_param "T" [] ]
      ~origin:Builtin ()
  in
  let env =
    add_func env "recv_timeout"
      (ty_func [ ty_channel_t; ty_int ] ty_option_t)
      ~type_params:[ generic_param "T" [] ]
      ~origin:Builtin ()
  in
  let env =
    add_func env "send_timeout"
      (ty_func [ ty_channel_t; ty_t; ty_int ] ty_bool)
      ~type_params:[ generic_param "T" [] ]
      ~origin:Builtin ()
  in
  let env =
    add_func env "seal"
      (ty_func [ ty_channel_t ] ty_void)
      ~type_params:[ generic_param "T" [] ]
      ~origin:Builtin ()
  in
  let env =
    add_func env "close"
      (ty_func [ ty_channel_t ] ty_void)
      ~type_params:[ generic_param "T" [] ]
      ~origin:Builtin ()
  in

  (* Push a new scope so user declarations are separate from builtins.
     This lets lookup_in_current_scope see only user symbols while
     lookup still finds builtins in the outer scope. *)
  let env = push_scope env in

  (* Mark the session as populated so subsequent [with_builtins] calls
     in this session skip impl registration. *)
  sess.builtins_populated <- true;

  env
