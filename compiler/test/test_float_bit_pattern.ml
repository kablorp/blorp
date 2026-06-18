(** Unit tests for IEEE-754 bit-pattern helpers shared by CTFE and codegen. *)

module F = Blorp.Float_bit_pattern

let check_int label expected actual = Alcotest.(check int) label expected actual

let check_int32 label expected actual =
  Alcotest.(check int32) label expected actual

let check_int64 label expected actual =
  Alcotest.(check int64) label expected actual

let check_float label expected actual =
  Alcotest.(check (float 0.0)) label expected actual

let test_float_bits () =
  check_int64 "Float 1.5 bits" 0x3ff8000000000000L (F.float64_bits 1.5);
  check_int32 "Float32 2.25 bits" 0x40100000l (F.float32_bits 2.25);
  check_int "Float16 3.5 bits" 0x4300 (F.float16_bits 3.5)

let test_float16_rounding () =
  check_float "Float16 rounds 1.0001 to 1.0" 1.0 (F.round_to_float16 1.0001);
  check_float "Float16 preserves 3.5" 3.5 (F.round_to_float16 3.5)

let suite =
  [
    ( "bit_patterns",
      [
        Alcotest.test_case "float widths" `Quick test_float_bits;
        Alcotest.test_case "float16 rounding" `Quick test_float16_rounding;
      ] );
  ]
