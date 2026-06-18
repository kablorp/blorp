(** IEEE-754 bit-pattern helpers used by CTFE and static C emission. *)

let round_to_float32 value = Int32.float_of_bits (Int32.bits_of_float value)
let float64_bits value = Int64.bits_of_float value
let float32_bits value = Int32.bits_of_float value
let binary16_fraction_bits = 10
let binary16_exponent_bits = 5
let binary16_exponent_bias = 15
let binary16_special_exponent = (1 lsl binary16_exponent_bits) - 1
let binary16_sign_mask = 0x8000
let binary16_infinity_bits = 0x7c00
let binary16_quiet_nan_bits = 0x7e00
let binary16_min_normal_bits = 0x0400

let binary16_subnormal_exponent =
  1 - binary16_exponent_bias - binary16_fraction_bits

let binary64_fraction_bits = 52
let binary64_exponent_bits = 11
let binary64_exponent_bias = 1023
let binary64_special_exponent = (1 lsl binary64_exponent_bits) - 1
let binary64_sign_shift = binary64_fraction_bits + binary64_exponent_bits

let binary64_fraction_mask =
  Int64.sub (Int64.shift_left 1L binary64_fraction_bits) 1L

let round_shift_right_nearest_even value shift =
  let quotient = Int64.shift_right_logical value shift in
  let remainder_mask = Int64.sub (Int64.shift_left 1L shift) 1L in
  let remainder = Int64.logand value remainder_mask in
  let halfway = Int64.shift_left 1L (shift - 1) in
  let quotient_is_odd = not (Int64.equal (Int64.logand quotient 1L) 0L) in
  if
    Int64.compare remainder halfway > 0
    || (Int64.equal remainder halfway && quotient_is_odd)
  then Int64.succ quotient
  else quotient

let round_float_to_int_nearest_even value =
  let nearest_even_tie = 0.5 in
  let lower = floor value in
  let lower_int = int_of_float lower in
  let fraction = value -. lower in
  if fraction > nearest_even_tie then lower_int + 1
  else if fraction < nearest_even_tie then lower_int
  else if lower_int mod 2 = 0 then lower_int
  else lower_int + 1

let float16_bits value =
  let bits = Int64.bits_of_float value in
  let sign =
    if Int64.equal (Int64.shift_right_logical bits binary64_sign_shift) 0L then
      0
    else binary16_sign_mask
  in
  let exponent =
    Int64.to_int
      (Int64.logand
         (Int64.shift_right_logical bits binary64_fraction_bits)
         (Int64.of_int binary64_special_exponent))
  in
  let fraction = Int64.logand bits binary64_fraction_mask in
  if exponent = binary64_special_exponent then
    if Int64.equal fraction 0L then sign lor binary16_infinity_bits
    else sign lor binary16_quiet_nan_bits
  else if Int64.equal fraction 0L && exponent = 0 then sign
  else
    let value_magnitude = abs_float value in
    let binary16_min_subnormal = ldexp 1.0 binary16_subnormal_exponent in
    let half_exponent =
      exponent - binary64_exponent_bias + binary16_exponent_bias
    in
    if half_exponent <= 0 then
      let subnormal =
        round_float_to_int_nearest_even
          (value_magnitude /. binary16_min_subnormal)
      in
      if subnormal = 0 then sign
      else if subnormal >= binary16_min_normal_bits then
        sign lor binary16_min_normal_bits
      else sign lor subnormal
    else
      let significand =
        Int64.logor (Int64.shift_left 1L binary64_fraction_bits) fraction
      in
      let shift = binary64_fraction_bits - binary16_fraction_bits in
      let rounded =
        Int64.to_int (round_shift_right_nearest_even significand shift)
      in
      let half_exponent, rounded =
        if rounded = 1 lsl (binary16_fraction_bits + 1) then
          (half_exponent + 1, rounded lsr 1)
        else (half_exponent, rounded)
      in
      if half_exponent >= binary16_special_exponent then
        sign lor binary16_infinity_bits
      else
        sign
        lor (half_exponent lsl binary16_fraction_bits)
        lor (rounded land ((1 lsl binary16_fraction_bits) - 1))

let binary16_bits_to_float bits =
  let sign = bits land binary16_sign_mask <> 0 in
  let exponent =
    (bits lsr binary16_fraction_bits) land binary16_special_exponent
  in
  let fraction = bits land ((1 lsl binary16_fraction_bits) - 1) in
  let magnitude =
    if exponent = 0 then
      if fraction = 0 then 0.0
      else ldexp (float_of_int fraction) binary16_subnormal_exponent
    else if exponent = binary16_special_exponent then
      if fraction = 0 then infinity else nan
    else
      ldexp
        (1.0
        +. (float_of_int fraction /. float_of_int (1 lsl binary16_fraction_bits))
        )
        (exponent - binary16_exponent_bias)
  in
  if sign then -.magnitude else magnitude

let round_to_float16 value = value |> float16_bits |> binary16_bits_to_float
