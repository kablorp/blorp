# Blorp 2 e2e compile-cost ceilings, reset 2026-11-05

The 66 programs ported in T3 batch 1 (`blorp_2/test/e2e/self_hosted_calls.brp`)
carry compile-cost ceilings that Keith approved re-measuring. Each new ceiling is
the measured cost plus 15%, rounded up to a whole count, which is the rule the
legacy ceilings used.

## Why the legacy ceilings were reset

The legacy ceilings came from `test/e2e/test_*.brp` files that no runner has
executed for weeks. Most were set on 2026-10-12 to 2026-10-20, when the target
library was 423 lines. It is 1,560 lines now, and the prelude imports `dict`,
so every compile checks `Dict`. Against the compiler as it stands, 7 of the 66
programs exceed their legacy allocation ceilings (47,000 to 56,000) and 49 of
66 exceed their legacy instruction ceilings (counting `written_names` against
`call_one`'s, which it shared); none of the failures is a regression in a
ported program.

Effect of the prelude `Dict` on a trivial compile (`fixtures/return/zero.brp`,
**one run each**, same compiler, library root `blorp_2/standard_library` with
and without the `dict: Dict` line of `prelude.brp`):

| Library | Allocations | Retired instructions |
| --- | --- | --- |
| as committed | 89,511 | 511,684,621 |
| prelude without `Dict` | 52,444 | 181,582,586 |
| difference | 37,067 | 330,102,035 |

`Dict` is therefore about 37 thousand allocations and 330 million instructions
(65% of the instructions) of every compile. Loading it only on import would
change these numbers and is separate compiler work, not part of this reset.

## What was measured

- **Compiler:** built from `b006327828db` (the last commit touching
  `blorp_2/src` and `blorp_2/standard_library`; the T3 branch changes neither),
  `make -C blorp_2 test-compiler`: `-O0 -DBLORP_MEMORY_DIAGNOSTICS=1`.
- **Host:** Apple M4, macOS 26.7.1, Apple clang 21.0.0, runs strictly serial.
  Other sessions shared the machine. The two sweep runs did not record the load
  average; the gate runs around them show 3.2 to 4.0 (1-minute), and the `Dict`
  runs 3.21.
- **Allocations:** the compiler's strict report
  (`BLORP_LEAK_CHECK=strict`). The two sweep runs agree exactly. Repeated runs of
  one input can still differ by 1 or 2 (`recursion/generic.brp`: 90,933, 90,932,
  90,932), which the margin covers.
- **Instructions:** `/usr/bin/time -l` through the driver's
  `INSTRUCTION_CHECK=on`. They differ between sweep runs by a fraction of a
  percent, so the table takes the larger of the two. `return_zero` has one valid
  reading, because the second run's output line was interleaved with other
  output; it uses the first.
- **Two clusters of instruction counts.** Seven programs measure 436M to 487M
  (`recursion_generic`, `constant_aggregate`, `conversion_integer`,
  `conversion_float`, `tail_accumulator`, `recursive_tree`, `int_comparisons`)
  while siblings at near-equal allocation counts measure 510M to 530M:
  `recursion_generic` is 90,933 allocations and 436M, `recursion_binding`
  90,932 and 515M. Three more runs of each give 435.6M to 436.4M and 513.6M to
  513.7M. The cause was not investigated.
  (One earlier probe of `generic.brp` read 461M once.)
- **Samples:** the driver was temporarily changed to print each measurement
  instead of failing on it. Raw samples are kept out of the repository, in the
  ignored directory `/Users/keithphilpott/CLionProjects/blorp/build/blorp2-e2e-ceilings-2026-11-05/`:

| File | sha256 |
| --- | --- |
| `remeasure1.log` | `bc01e01481cd9e9efaf34156c56f0588b7860bf6e0fb97b68c69e84eacb61d81` |
| `remeasure2.log` | `4ec10cd23f3d54f3b04406ff17df42984d162cec61e69075ea933fe35ec355dd` |
| `measured_final.json` | `1207b2ea859b00a3349d0de986d09bafcf688e7be99b3f9de6176470a73936dd` |
| `ceilings_measured.tsv` (earlier single run, legacy ceilings) | `bc134116b7444fe68dc9f9cea6370d43ff6cbb77f64cf9c131a925b522310d5b` |
| `dict_with.stderr` / `dict_with.time` | `388bf6b234adfa851343809372881a69645cde5e45bd9666083dbfab4358e66e` / `a1ff5c0c1a669af32e6ae0b37b9ef66027a314d6285854d5f475115b5690f3f4` |
| `dict_without.stderr` / `dict_without.time` | `b311e0dc795d21ce61db5ad02a58f8f384258637291f881166a2083daf652e90` / `f123bda94c61bef8497c5b5546e18ed710241f3df30a4fffd7876f200563ccb6` |
| `dict_load.txt` | `0f326c82678e0e76067d5f46dfd00c75a34a6e822d8e6c9017282a59ff51bbff` |
| `bimodal_probe.txt` | `e0634743a0c2886bce17d67306705c105496218973ff638e51eedad9e9d2d9f1` |

```sh
make -C blorp_2 test-compiler
make -C blorp_2 test-e2e INSTRUCTION_CHECK=on   # twice, serial, measurement build
make -C blorp_2 test                            # default: allocation ceilings only
make -C blorp_2 test-e2e INSTRUCTION_CHECK=on   # opt-in: both ceilings
```

## Per-program ceilings

"Old" is the legacy ceiling (`written_names` had none and shared
`call_one`'s). "New" is measured +15%.

| Program | Old allocs | Measured allocs | New allocs | Old instr | Measured instr | New instr |
| --- | --- | --- | --- | --- | --- | --- |
| `call_one` | 131,300 | 89,757 | 103,221 | 440,000,000 | 510,926,221 | 587,565,155 |
| `constant_aggregate` | 140,000 | 94,949 | 109,192 | 500,000,000 | 469,524,939 | 539,953,680 |
| `constant_aliases` | 140,000 | 91,006 | 104,657 | 500,000,000 | 515,188,326 | 592,466,575 |
| `constant_callable` | 140,000 | 91,322 | 105,021 | 500,000,000 | 516,913,801 | 594,450,872 |
| `constant_float` | 140,000 | 90,710 | 104,317 | 500,000,000 | 514,071,193 | 591,181,872 |
| `constant_imported` | 140,000 | 90,079 | 103,591 | 500,000,000 | 513,535,528 | 590,565,858 |
| `constant_integer` | 140,000 | 89,577 | 103,014 | 500,000,000 | 511,056,114 | 587,714,532 |
| `constant_managed_generic` | 140,000 | 92,581 | 106,469 | 500,000,000 | 519,007,751 | 596,858,914 |
| `constant_nested` | 140,000 | 107,896 | 124,081 | 500,000,000 | 569,101,197 | 654,466,377 |
| `constant_pipe` | 140,000 | 90,456 | 104,025 | 500,000,000 | 512,994,505 | 589,943,681 |
| `constant_seven` | 140,000 | 89,577 | 103,014 | 500,000,000 | 511,144,173 | 587,815,799 |
| `constant_string` | 140,000 | 90,433 | 103,998 | 500,000,000 | 513,080,037 | 590,042,043 |
| `conversion_float` | 250,000 | 96,303 | 110,749 | 740,000,000 | 471,809,623 | 542,581,067 |
| `conversion_integer` | 235,000 | 96,300 | 110,745 | 700,000,000 | 471,963,069 | 542,757,530 |
| `conversion_nul_bytes` | 206,000 | 95,659 | 110,008 | 610,000,000 | 529,039,096 | 608,394,961 |
| `conversion_projection_stress` | 260,000 | 108,613 | 124,905 | 800,000,000 | 566,994,255 | 652,043,394 |
| `int_add` | 155,000 | 89,937 | 103,428 | 550,000,000 | 511,915,210 | 588,702,492 |
| `int_cancel` | 155,000 | 89,939 | 103,430 | 550,000,000 | 512,555,850 | 589,439,228 |
| `int_comparisons` | 56,000 | 101,299 | 116,494 | 150,000,000 | 487,094,700 | 560,158,905 |
| `int_equals` | 230,000 | 96,318 | 110,766 | 700,000,000 | 530,255,257 | 609,793,546 |
| `int_negative` | 155,000 | 90,441 | 104,008 | 550,000,000 | 512,430,774 | 589,295,391 |
| `int_nested` | 155,000 | 90,289 | 103,833 | 550,000,000 | 515,715,798 | 593,073,168 |
| `int_ufcs` | 155,000 | 89,945 | 103,437 | 550,000,000 | 511,554,225 | 588,287,359 |
| `int_wrap_max` | 155,000 | 90,441 | 104,008 | 550,000,000 | 512,661,900 | 589,561,185 |
| `int_wrap_min` | 155,000 | 90,441 | 104,008 | 550,000,000 | 512,238,708 | 589,074,515 |
| `int_wrap_twice` | 155,000 | 90,438 | 104,004 | 550,000,000 | 512,294,015 | 589,138,118 |
| `integer_maximum` | 140,000 | 89,760 | 103,224 | 500,000,000 | 511,168,685 | 587,843,988 |
| `integer_minimum` | 140,000 | 89,758 | 103,222 | 500,000,000 | 510,908,825 | 587,545,149 |
| `lexical_trivia` | 132,000 | 89,511 | 102,938 | 440,000,000 | 510,521,107 | 587,099,274 |
| `nested_calls` | 132,000 | 90,116 | 103,634 | 440,000,000 | 511,955,844 | 588,749,221 |
| `nested_order` | 132,000 | 90,238 | 103,774 | 440,000,000 | 512,165,825 | 588,990,699 |
| `pure_calls` | 131,600 | 90,003 | 103,504 | 440,000,000 | 513,215,000 | 590,197,250 |
| `recursion_argument` | 140,000 | 91,064 | 104,724 | 500,000,000 | 518,723,718 | 596,532,276 |
| `recursion_binding` | 140,000 | 90,932 | 104,572 | 500,000,000 | 515,194,990 | 592,474,239 |
| `recursion_generic` | 140,000 | 90,933 | 104,573 | 500,000,000 | 436,854,179 | 502,382,306 |
| `recursion_mutual` | 140,000 | 91,569 | 105,305 | 500,000,000 | 515,797,760 | 593,167,424 |
| `recursion_record` | 140,000 | 91,536 | 105,267 | 500,000,000 | 516,010,469 | 593,412,040 |
| `recursion_self` | 140,000 | 90,714 | 104,322 | 500,000,000 | 515,550,135 | 592,882,656 |
| `recursion_string_live_local` | 140,000 | 91,678 | 105,430 | 500,000,000 | 515,847,364 | 593,224,469 |
| `recursion_string_result` | 140,000 | 91,292 | 104,986 | 500,000,000 | 514,589,721 | 591,778,180 |
| `recursion_ufcs` | 140,000 | 90,718 | 104,326 | 500,000,000 | 513,521,738 | 590,549,999 |
| `recursive_branches` | 49,000 | 95,429 | 109,744 | 94,000,000 | 524,941,692 | 603,682,946 |
| `recursive_group` | 49,000 | 96,245 | 110,682 | 95,000,000 | 527,031,455 | 606,086,174 |
| `recursive_kinds` | 49,000 | 95,704 | 110,060 | 95,600,000 | 525,933,658 | 604,823,707 |
| `recursive_linked` | 47,000 | 93,782 | 107,850 | 91,000,000 | 521,216,070 | 599,398,481 |
| `recursive_links` | 48,000 | 94,503 | 108,679 | 92,700,000 | 523,954,219 | 602,547,352 |
| `recursive_tree` | 54,000 | 98,889 | 113,723 | 111,100,000 | 479,720,389 | 551,678,448 |
| `return_42` | 131,100 | 89,511 | 102,938 | 440,000,000 | 510,772,198 | 587,388,028 |
| `return_zero` | 131,100 | 89,511 | 102,938 | 440,000,000 | 512,330,437 | 589,180,003 |
| `tail_accumulator` | 230,000 | 96,686 | 111,189 | 700,000,000 | 473,920,139 | 545,008,160 |
| `tail_arm_bindings` | 140,000 | 91,276 | 104,968 | 500,000,000 | 515,664,039 | 593,013,645 |
| `tail_arm_current` | 140,000 | 91,269 | 104,960 | 500,000,000 | 517,295,856 | 594,890,235 |
| `tail_base` | 140,000 | 90,936 | 104,577 | 500,000,000 | 514,564,830 | 591,749,555 |
| `tail_carry_boundary` | 140,000 | 97,789 | 112,458 | 500,000,000 | 532,266,598 | 612,106,588 |
| `tail_countdown` | 230,000 | 101,774 | 117,041 | 900,000,000 | 541,730,888 | 622,990,522 |
| `tail_direct` | 140,000 | 90,798 | 104,418 | 500,000,000 | 513,776,626 | 590,843,120 |
| `tail_duplicates` | 140,000 | 91,070 | 104,731 | 500,000,000 | 515,293,573 | 592,587,609 |
| `tail_duplicates_right` | 140,000 | 91,056 | 104,715 | 500,000,000 | 515,038,438 | 592,294,204 |
| `tail_managed_helper` | 140,000 | 91,927 | 105,717 | 500,000,000 | 516,576,460 | 594,062,929 |
| `tail_payload` | 140,000 | 91,254 | 104,943 | 500,000,000 | 514,659,608 | 591,858,550 |
| `tail_prefix` | 140,000 | 91,360 | 105,064 | 500,000,000 | 516,021,251 | 593,424,439 |
| `tail_record` | 140,000 | 91,641 | 105,388 | 500,000,000 | 516,425,853 | 593,889,731 |
| `tail_swap_left` | 140,000 | 91,070 | 104,731 | 500,000,000 | 514,753,416 | 591,966,429 |
| `tail_swap_right` | 140,000 | 91,070 | 104,731 | 500,000,000 | 515,830,185 | 593,204,713 |
| `tail_ufcs` | 140,000 | 92,452 | 106,320 | 500,000,000 | 519,002,120 | 596,852,438 |
| `written_names` | 131,300 | 89,989 | 103,488 | 440,000,000 | 511,262,026 | 587,951,330 |
