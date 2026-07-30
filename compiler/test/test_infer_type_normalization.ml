(** Unit tests for inference-time type normalization. *)

open Blorp.Ast
open Blorp.Types

let check_true msg b = Alcotest.(check bool) msg true b

let test_alias_normalization_retains_purpose_and_source () =
  let env = Blorp.Env.add_alias (Blorp.Env.empty ()) "UserId" [] ty_int in
  let ctx = Blorp.Infer_type_normalization.make_context ~env () in
  let source = TyNamed ("UserId", []) in
  let normalized =
    Blorp.Infer_type_normalization.normalize ctx
      Blorp.Infer_type_normalization.ArgumentCompatibility source
  in
  check_true "source spelling is retained"
    (types_equal normalized.source source);
  check_true "alias is expanded for inference compatibility"
    (types_equal normalized.normalized ty_int);
  check_true "normalization purpose is retained"
    (normalized.purpose
    = Blorp.Infer_type_normalization.ArgumentCompatibility)

let test_canonical_helper_returns_normalized_type () =
  let env =
    Blorp.Env.add_alias (Blorp.Env.empty ()) "Decoder" [ "T" ]
      (TyFunc
         {
           params = [ TyNamed ("JsonValue", []) ];
           return = TyNamed ("Result", [ TyVar "T"; TyNamed ("String", []) ]);
           is_pure = true;
         })
  in
  let ctx = Blorp.Infer_type_normalization.make_context ~env () in
  let source = TyNamed ("Decoder", [ ty_int ]) in
  let normalized =
    Blorp.Infer_type_normalization.canonical ctx
      Blorp.Infer_type_normalization.CalleeDispatch source
  in
  check_true "function alias is unfolded for callee dispatch"
    (types_equal normalized
       (TyFunc
          {
            params = [ TyNamed ("JsonValue", []) ];
            return = TyNamed ("Result", [ ty_int; TyNamed ("String", []) ]);
            is_pure = true;
          }))

let suite =
  [
    ( "normalization",
      [
        Alcotest.test_case "alias normalization retains purpose and source"
          `Quick test_alias_normalization_retains_purpose_and_source;
        Alcotest.test_case "canonical helper returns normalized type" `Quick
          test_canonical_helper_returns_normalized_type;
      ] );
  ]
