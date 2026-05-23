open Blorp

let test_fast_run_uses_o0 () =
  Alcotest.(check string)
    "fast run opt level" "O0"
    (Compile_profile.opt_level_for_run ~sanitize:false Compile_profile.Fast)

let test_release_run_uses_o2 () =
  Alcotest.(check string)
    "release run opt level" "O2"
    (Compile_profile.opt_level_for_run ~sanitize:false Compile_profile.Release)

let test_sanitized_run_uses_o0_even_in_release () =
  Alcotest.(check string)
    "sanitized release run opt level" "O0"
    (Compile_profile.opt_level_for_run ~sanitize:true Compile_profile.Release)

let suite =
  [
    ( "run_modes",
      [
        Alcotest.test_case "fast_run_uses_o0" `Quick test_fast_run_uses_o0;
        Alcotest.test_case "release_run_uses_o2" `Quick test_release_run_uses_o2;
        Alcotest.test_case "sanitized_release_run_uses_o0" `Quick
          test_sanitized_run_uses_o0_even_in_release;
      ] );
  ]
