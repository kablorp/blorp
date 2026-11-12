# Blorp 2 e2e compile-cost ceilings, reset 2026-11-05

> Instruction ceilings were reset again on 2026-11-09; see the last section, "Instruction ceilings reset after the dense path closure, 2026-11-09".

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

## T1 examples folded into `Program`, 2026-11-05

The 100 examples T1 declared as `Example` (plus the two current-directory
programs that used `verify_runs`) are now `Program`s built with the same
constructors as the group above, so each compile is held to a `CompileCeiling`.
They had no compile ceiling before, so there is no "old" column. Each new ceiling
is the measured cost plus 15%, rounded up to a whole count, the larger of the
samples taken.

- **Compiler:** built from the tree of `6c973b3cd032` (the last commit touching
  `blorp_2/src` and `blorp_2/standard_library`), `make -C blorp_2 test-compiler`,
  `-O0 -DBLORP_MEMORY_DIAGNOSTICS=1`. Host: Apple M4, macOS 26.7.1, strictly
  serial; load average 3.4 to 4.7 when the sweeps started, other sessions shared
  the machine.
- **Samples:** three `make -C blorp_2 test-e2e INSTRUCTION_CHECK=on` runs with the
  driver temporarily printing each measurement instead of failing on it. Two of
  the three were interrupted by the process-spawn flake (`create child group;
  errno=1`, an arbitrary case each, and a stdout line cut by interleaved stderr),
  so 100 programs have three samples, `owned_propagation_exit` and `opaque_empty`
  two; the table counts them in its last column. Allocations agree exactly across
  samples. Instructions differ by 0.02% to 0.73% between samples; the table takes
  the largest.
- **Ranking:** the costs follow the programs. `lookup_errors` (5.34G instructions,
  1.82M allocations) imports the compiler's own `lex` and `parse` modules, so it
  compiles far more than a fixture of the language; `arithmetic_long_sum` (3.76G,
  800k) is a 2,000-term sum and a 2,000-part join; `arithmetic_nesting`,
  `ordering_nesting`, the `fs_*` and `dict_*` programs are the next largest, each
  with a larger fixture. The smallest (`opaque_empty` 449M, `opaque_wrap` 451M,
  `supertrait_generic_receiver` 461M) belong to the lower instruction cluster the
  batch 1 section above describes (siblings at near-equal allocation counts
  measure about 517M, for example `fs_native_close`); its cause is still not
  investigated.
- **Samples are kept out of the repository** in the ignored directory
  `/Users/keithphilpott/CLionProjects/blorp/build/blorp2-e2e-ceilings-2026-11-05/`:

| File | sha256 |
| --- | --- |
| `fold_measure1.log` | `5c53390d1decd5517526c8412e481a0ffdbd15af6b6e059bc8465c74a13ca26f` |
| `fold_measure2.log` | `59044735765a336bbcddc50e6cea243dc5c6e023fe0fa77b2249f4db8a5f22d5` |
| `fold_measure3.log` | `36b24ccc634045795e948def1042a5e2570e0545658adfc943e7eea716b1e75b` |
| `fold_samples.json` (all valid samples per program) | `30781bde942921b9640ffd33a718f6bfa225344640b5c2dede965eb47678e587` |
| `fold_ceilings.json` (the values in the table) | `0b45c479971cf9c2ceb8537a121dde19a19d22e3f073d5692939977642ec7898` |
| `fold_expectations_before.txt` | `16852cfcdfa4fe9ee03ac3b22ac25a832c6d4d97bdbe07fc5034da74d8822534` |
| `fold_expectations_after.txt` | `0d31470fbc986b71edfabad5f99b571a0e48a3884c3393322c06f4d11b58f5f8` |

The two expectation files list every native program's name, compiler inputs and
every run's arguments, directory, status, stdout and allocation count, taken from
the driver before and after the fold (each a dump patch that prints instead of
verifying); they differ only in the added ceilings and a `suites` label the dump
patch used before the fold.

| Program | Measured allocs | New allocs | Measured instr | New instr | Samples |
| --- | --- | --- | --- | --- | --- |
| `append_reuse` | 112,943 | 129,885 | 515,815,794 | 593,188,164 | 3 |
| `arithmetic_checked` | 114,019 | 131,122 | 576,970,788 | 663,516,407 | 3 |
| `arithmetic_long_sum` | 799,691 | 919,645 | 3,761,595,790 | 4,325,835,159 | 3 |
| `arithmetic_nesting` | 160,010 | 184,012 | 711,886,310 | 818,669,257 | 3 |
| `arithmetic_operators` | 121,594 | 139,834 | 596,341,765 | 685,793,030 | 3 |
| `arithmetic_order` | 97,941 | 112,633 | 533,515,416 | 613,542,729 | 3 |
| `arithmetic_traits` | 110,959 | 127,603 | 492,300,056 | 566,145,065 | 3 |
| `branch_accumulator` | 120,165 | 138,190 | 533,191,969 | 613,170,765 | 3 |
| `current_directory_basic` | 92,103 | 105,919 | 519,773,634 | 597,739,680 | 3 |
| `current_directory_ownership` | 92,367 | 106,223 | 518,528,925 | 596,308,264 | 3 |
| `declaration_bounds` | 102,392 | 117,751 | 487,009,052 | 560,060,410 | 3 |
| `dict_absent_sequential` | 115,124 | 132,393 | 542,191,287 | 623,519,981 | 3 |
| `dict_call_chain_cost` | 113,624 | 130,668 | 538,787,303 | 619,605,399 | 3 |
| `dict_case_insensitive_keys` | 153,270 | 176,261 | 641,203,280 | 737,383,772 | 3 |
| `dict_churn_large` | 124,516 | 143,194 | 566,421,189 | 651,384,368 | 3 |
| `dict_churn_small` | 124,516 | 143,194 | 567,060,915 | 652,120,053 | 3 |
| `dict_compaction_boundary` | 117,427 | 135,042 | 548,292,810 | 630,536,732 | 3 |
| `dict_int_keys` | 149,881 | 172,364 | 631,517,699 | 726,245,354 | 3 |
| `dict_linear_build` | 115,828 | 133,203 | 544,629,138 | 626,323,509 | 3 |
| `dict_literal_cost` | 113,422 | 130,436 | 569,144,284 | 654,515,927 | 3 |
| `dict_literal_order` | 120,544 | 138,626 | 534,071,626 | 614,182,370 | 3 |
| `dict_literals` | 206,175 | 237,102 | 775,232,955 | 891,517,899 | 3 |
| `dict_record_keys` | 161,074 | 185,236 | 660,893,500 | 760,027,525 | 3 |
| `dict_string_keys` | 152,299 | 175,144 | 636,863,783 | 732,393,351 | 3 |
| `discard` | 100,159 | 115,183 | 536,715,899 | 617,223,284 | 3 |
| `every_in_place_helper` | 93,858 | 107,937 | 469,199,120 | 539,578,988 | 3 |
| `fixed_record` | 100,962 | 116,107 | 538,288,908 | 619,032,245 | 3 |
| `fixed_union` | 98,621 | 113,415 | 536,403,430 | 616,863,945 | 3 |
| `fs_directories` | 254,008 | 292,110 | 878,778,924 | 1,010,595,763 | 3 |
| `fs_lines` | 293,604 | 337,645 | 1,051,259,500 | 1,208,948,425 | 3 |
| `fs_native_both` | 94,083 | 108,196 | 522,751,291 | 601,163,985 | 3 |
| `fs_native_close` | 92,147 | 105,970 | 517,721,999 | 595,380,299 | 3 |
| `fs_native_create_directories` | 92,158 | 105,982 | 517,598,883 | 595,238,716 | 3 |
| `fs_native_create_directory` | 92,158 | 105,982 | 517,535,171 | 595,165,447 | 3 |
| `fs_native_create_temporary_directory` | 92,368 | 106,224 | 518,491,976 | 596,265,773 | 3 |
| `fs_native_directories` | 113,187 | 130,166 | 518,810,869 | 596,632,500 | 3 |
| `fs_native_entry_kind` | 92,304 | 106,150 | 517,893,868 | 595,577,949 | 3 |
| `fs_native_lines` | 108,360 | 124,614 | 505,734,567 | 581,594,753 | 3 |
| `fs_native_list_directory` | 92,486 | 106,359 | 518,335,074 | 596,085,336 | 3 |
| `fs_native_next_lines` | 92,598 | 106,488 | 519,940,786 | 597,931,904 | 3 |
| `fs_native_open_read` | 93,805 | 107,876 | 468,383,865 | 538,641,445 | 3 |
| `fs_native_read_text` | 92,312 | 106,159 | 517,969,747 | 595,665,210 | 3 |
| `fs_native_remove_directory` | 92,160 | 105,984 | 517,478,674 | 595,100,476 | 3 |
| `fs_native_remove_directory_tree` | 92,162 | 105,987 | 517,521,845 | 595,150,122 | 3 |
| `fs_native_remove_file` | 92,159 | 105,983 | 517,610,043 | 595,251,550 | 3 |
| `fs_native_rename` | 92,277 | 106,119 | 517,552,416 | 595,185,279 | 3 |
| `fs_native_write_text` | 92,271 | 106,112 | 517,500,787 | 595,125,906 | 3 |
| `fs_read` | 181,988 | 209,287 | 690,949,389 | 794,591,798 | 3 |
| `fs_write` | 175,127 | 201,397 | 669,809,059 | 770,280,418 | 3 |
| `grouped_suites` | 106,258 | 122,197 | 557,172,474 | 640,748,346 | 3 |
| `import_all` | 92,113 | 105,930 | 462,831,479 | 532,256,201 | 3 |
| `import_drop` | 93,676 | 107,728 | 466,052,881 | 535,960,814 | 3 |
| `import_find` | 92,266 | 106,106 | 462,224,686 | 531,558,389 | 3 |
| `import_remove` | 94,753 | 108,966 | 467,905,532 | 538,091,362 | 3 |
| `import_reverse` | 92,694 | 106,599 | 463,386,018 | 532,893,921 | 3 |
| `import_take` | 93,643 | 107,690 | 466,349,423 | 536,301,837 | 3 |
| `library_linear` | 115,385 | 132,693 | 520,922,488 | 599,060,862 | 3 |
| `library_loops` | 137,929 | 158,619 | 577,054,931 | 663,613,171 | 3 |
| `list_callbacks` | 127,753 | 146,916 | 534,857,362 | 615,085,967 | 3 |
| `list_join` | 100,840 | 115,966 | 487,569,636 | 560,705,082 | 3 |
| `list_queries` | 110,350 | 126,903 | 510,584,008 | 587,171,610 | 3 |
| `literal` | 93,636 | 107,682 | 466,371,909 | 536,327,696 | 3 |
| `literal_append` | 91,684 | 105,437 | 519,182,630 | 597,060,025 | 3 |
| `literal_indirect` | 96,708 | 111,215 | 476,270,589 | 547,711,178 | 3 |
| `literal_loop` | 92,173 | 105,999 | 519,154,615 | 597,027,808 | 3 |
| `lookup_errors` | 1,820,822 | 2,093,946 | 5,342,439,768 | 6,143,805,734 | 3 |
| `loop_entry_accumulator` | 112,629 | 129,524 | 516,428,724 | 593,893,033 | 3 |
| `nonzero` | 89,511 | 102,938 | 512,060,103 | 588,869,119 | 3 |
| `number_tuples` | 92,680 | 106,582 | 518,188,087 | 595,916,301 | 3 |
| `opaque_empty` | 92,574 | 106,461 | 448,722,360 | 516,030,714 | 2 |
| `opaque_nesting` | 99,925 | 114,914 | 465,888,704 | 535,772,010 | 3 |
| `opaque_phantom` | 92,510 | 106,387 | 519,692,533 | 597,646,413 | 3 |
| `opaque_trait` | 100,416 | 115,479 | 476,084,699 | 547,497,404 | 3 |
| `opaque_wrap` | 93,119 | 107,087 | 450,933,399 | 518,573,409 | 3 |
| `orderable` | 102,247 | 117,585 | 544,552,559 | 626,235,443 | 3 |
| `ordering_nesting` | 138,370 | 159,126 | 659,817,504 | 758,790,130 | 3 |
| `ordering_operators` | 118,243 | 135,980 | 592,872,851 | 681,803,779 | 3 |
| `ordering_order` | 95,821 | 110,195 | 527,599,151 | 606,739,024 | 3 |
| `owned_loop_accumulator` | 97,404 | 112,015 | 476,704,119 | 548,209,737 | 3 |
| `owned_propagation_exit` | 98,537 | 113,318 | 480,939,235 | 553,080,121 | 2 |
| `plain_private` | 93,283 | 107,276 | 521,367,878 | 599,573,060 | 3 |
| `plain_record` | 99,403 | 114,314 | 555,871,220 | 639,251,903 | 3 |
| `record_field_accumulator` | 108,518 | 124,796 | 507,532,435 | 583,662,301 | 3 |
| `remove_int` | 103,059 | 118,518 | 490,599,297 | 564,189,192 | 3 |
| `single_suite` | 103,370 | 118,876 | 548,298,003 | 630,542,704 | 3 |
| `sort_by` | 155,383 | 178,691 | 627,468,676 | 721,588,978 | 3 |
| `sort_by_nested` | 121,975 | 140,272 | 525,665,538 | 604,515,369 | 3 |
| `sort_by_orderable` | 124,006 | 142,607 | 528,420,985 | 607,684,133 | 3 |
| `sort_by_ties` | 107,723 | 123,882 | 501,797,758 | 577,067,422 | 3 |
| `static_empty` | 99,588 | 114,527 | 482,540,316 | 554,921,364 | 3 |
| `static_environment` | 96,615 | 111,108 | 531,559,913 | 611,293,900 | 3 |
| `supertrait_bundle` | 96,832 | 111,357 | 531,044,704 | 610,701,410 | 3 |
| `supertrait_entailment` | 106,409 | 122,371 | 535,644,133 | 615,990,753 | 3 |
| `supertrait_generic_receiver` | 97,984 | 112,682 | 461,210,347 | 530,391,900 | 3 |
| `supplement_bounds` | 115,279 | 132,571 | 519,715,257 | 597,672,546 | 3 |
| `supplement_managed` | 120,055 | 138,064 | 536,099,281 | 616,514,174 | 3 |
| `supplement_predicates` | 121,722 | 139,981 | 516,768,699 | 594,284,004 | 3 |
| `take_int` | 101,428 | 116,643 | 488,331,787 | 561,581,556 | 3 |
| `take_remove_managed` | 107,100 | 123,165 | 500,375,853 | 575,432,231 | 3 |
| `take_remove_moderate` | 102,142 | 117,464 | 487,266,382 | 560,356,340 | 3 |
| `take_remove_void` | 101,496 | 116,721 | 486,194,211 | 559,123,343 | 3 |
| `text` | 90,409 | 103,971 | 513,117,103 | 590,084,669 | 3 |
| `update_reuse` | 109,548 | 125,981 | 511,237,863 | 587,923,543 | 3 |

## T3 batch 2: strings and paths, 2026-11-05

The 63 programs ported in batch 2 (`blorp_2/test/e2e/self_hosted_strings.brp`, from
11 legacy files) carry ceilings set by the same rule: measured cost plus 15%,
rounded up to a whole count, except the two `*_unreached` programs at plus 5%
(below). "Old" is the ceiling in the deleted
`test_*.brp` file; `interpolation_*` were held to 600,000 and 2,000,000,000 by
`run_accounted_example`. The foundation-diagnostic rejection in
`test_strings` compiles nothing that is run, so it has no ceiling.

- **Compiler:** built from the tree of `6c973b3cd032` (the last commit touching
  `blorp_2/src` and `blorp_2/standard_library`; this branch changes neither),
  `make -C blorp_2 test-compiler`, `-O0 -DBLORP_MEMORY_DIAGNOSTICS=1`. Host: Apple
  M4, macOS 26.7.1, Apple clang 21.0.0, strictly serial; 1-minute load average 3.6
  to 4.6 around the sweeps, other sessions shared the machine.
- **Samples:** three `make -C blorp_2 test-e2e INSTRUCTION_CHECK=on` runs with the
  driver temporarily restricted to this suite and printing each compile
  measurement and each strict native report instead of failing on it
  (`batch2_measure.patch`). All three completed; no sample was interrupted or
  interleaved, so every program has three. Allocations, for the compile and for
  all 183 native runs, agree exactly across the three. Instructions differ by
  0.004% to 1.7% (`join_tail_arm`: 520.0M, 520.0M, 528.8M); the table takes the
  largest.
- **Ranking:** the two lowest instruction counts, `string_slice_bounds` (470M) and
  `string_starts_with_arguments` (473M), belong to the lower instruction cluster the
  batch 1 section describes. The highest allocation counts are the path programs
  (`path_normalize_edges` 122,933, `path_dirname_edges` 114,135), which import
  `path`; the highest instruction counts are `path_join_*` (562M to 565M).
- **Legacy ceilings:** 24 of 63 programs exceed their legacy allocation ceilings
  and 38 of 63 their legacy instruction ceilings, for the reason given above (the
  prelude's `Dict` is about 37 thousand allocations of every compile).
- **Two programs keep a tight bound at measured + 5%, approved by Keith
  2026-11-05.** `string_literal_long_unreached` and
  `string_literal_many_escapes_unreached` were held to 41,000 and 43,000
  allocations so that a decoder allocating per byte would fail: before the fix
  they measured 12,000 and 10,639 allocations more than after it
  (`blorp_2_string_decoding_2026-10-16.md`). Their literal sits in a function
  nothing calls and `main` returns 0, so the compile ceiling is their only
  check. At + 15% (103,135 and 106,202) that regression (89,682 + 12,000 =
  101,682 and 92,349 + 10,639 = 102,988) would pass, so both columns use + 5%
  instead: 94,167 and 96,967 allocations, 540,944,094 and 544,669,648
  instructions (sample spread at most 1.7%).
- **Samples are kept out of the repository** in the ignored directory
  `/Users/keithphilpott/CLionProjects/blorp/build/blorp2-e2e-ceilings-2026-11-05/`:

| File | sha256 |
| --- | --- |
| `batch2_measure1.log` | `0da39f7a928d49d2015b5e370db51a6d3ca263547cef80c252c0cb7f231c09e1` |
| `batch2_measure2.log` | `6d586c79e189a9e8def3893c6d1d71b2023887a0a85928b52b231a837bbac78c` |
| `batch2_measure3.log` | `ff005ddecaf66ab55e6f86be9f2406302db27b402ce86d2b2245d5ade25ebada` |
| `batch2_measure.patch` (the temporary driver change) | `a12ee7aba13c18912da4c3015deec060b663ccd8806d81599aa2f301c3ec6b6a` |
| `batch2_samples.json` (all three instruction samples per program) | `af1bde10413a353c868651a977b3f5d772b6605d7aed47ab25fa6f4d0d0b57da` |
| `batch2_ceilings.json` (the ceiling literals in program order, then each run's strict allocations) | `5333eb2302822f95aedbb029d49f9303ecf6eab1097ca6d89e16e940a2ad545c` |

| Program | Old allocs | Measured allocs | New allocs | Old instr | Measured instr | New instr |
| --- | --- | --- | --- | --- | --- | --- |
| `interpolation_eight` | 600,000 | 91,251 | 104,939 | 2,000,000,000 | 514,723,058 | 591,931,517 |
| `interpolation_one_hundred_twenty_eight` | 600,000 | 103,851 | 119,429 | 2,000,000,000 | 549,381,938 | 631,789,229 |
| `interpolation_ordered` | 600,000 | 96,194 | 110,624 | 2,000,000,000 | 529,971,547 | 609,467,280 |
| `interpolation_thirty_two` | 600,000 | 93,771 | 107,837 | 2,000,000,000 | 521,885,623 | 600,168,467 |
| `join_bound_int` | 46,000 | 93,737 | 107,798 | 97,842,731 | 519,808,618 | 597,779,911 |
| `join_bound_managed` | 45,000 | 92,846 | 106,773 | 89,000,000 | 518,316,332 | 596,063,782 |
| `join_carried_duplicate` | 46,000 | 93,292 | 107,286 | 150,000,000 | 520,517,814 | 598,595,487 |
| `join_carried_existing` | 42,000 | 90,689 | 104,293 | 150,000,000 | 513,629,220 | 590,673,603 |
| `join_carried_int` | 44,000 | 92,106 | 105,922 | 150,000,000 | 518,690,829 | 596,494,454 |
| `join_carried_nested` | 60,000 | 101,244 | 116,431 | 300,000,000 | 541,655,395 | 622,903,705 |
| `join_carried_order` | 46,000 | 93,425 | 107,439 | 150,000,000 | 520,632,005 | 598,726,806 |
| `join_carried_projected` | 47,000 | 93,942 | 108,034 | 150,000,000 | 522,151,720 | 600,474,478 |
| `join_carried_rhs` | 44,000 | 92,168 | 105,994 | 150,000,000 | 518,809,501 | 596,630,927 |
| `join_carried_string_alias` | 46,000 | 93,275 | 107,267 | 150,000,000 | 521,614,478 | 599,856,650 |
| `join_carried_swap` | 47,000 | 93,468 | 107,489 | 150,000,000 | 520,872,252 | 599,003,090 |
| `join_carried_unused` | 45,000 | 92,321 | 106,170 | 150,000,000 | 517,727,524 | 595,386,653 |
| `join_deep` | 57,000 | 103,060 | 118,519 | 117,896,899 | 542,729,883 | 624,139,366 |
| `join_nested` | 48,000 | 95,736 | 110,097 | 96,043,217 | 524,383,783 | 603,041,351 |
| `join_statement` | 45,000 | 92,882 | 106,815 | 89,000,000 | 518,172,253 | 595,898,091 |
| `join_tail_arm` | 46,000 | 93,665 | 107,715 | 90,000,000 | 528,773,338 | 608,089,339 |
| `join_void_tail` | 45,000 | 93,326 | 107,325 | 90,331,263 | 519,083,859 | 596,946,438 |
| `mortal_string_alias` | 150,000 | 90,339 | 103,890 | 600,000,000 | 512,533,331 | 589,413,331 |
| `mortal_string_basic` | 150,000 | 90,092 | 103,606 | 600,000,000 | 511,997,298 | 588,796,893 |
| `mortal_string_identity` | 150,000 | 90,520 | 104,098 | 600,000,000 | 513,158,625 | 590,132,419 |
| `mortal_string_maximum` | 150,000 | 90,016 | 103,519 | 600,000,000 | 511,709,803 | 588,466,274 |
| `mortal_string_minimum` | 150,000 | 90,028 | 103,533 | 600,000,000 | 511,771,137 | 588,536,808 |
| `mortal_string_unused` | 150,000 | 89,862 | 103,342 | 600,000,000 | 511,466,184 | 588,186,112 |
| `path_dirname_edges` | 200,000 | 114,135 | 131,256 | 600,000,000 | 519,495,198 | 597,419,478 |
| `path_join_arguments` | 205,000 | 109,700 | 126,155 | 600,000,000 | 562,489,827 | 646,863,302 |
| `path_join_counted_aliases` | 205,000 | 109,419 | 125,832 | 600,000,000 | 565,049,632 | 649,807,077 |
| `path_normalize_edges` | 200,000 | 122,933 | 141,373 | 600,000,000 | 541,818,591 | 623,091,380 |
| `stderr_alias` | 205,000 | 92,243 | 106,080 | 600,000,000 | 517,572,560 | 595,208,444 |
| `stderr_bytes` | 205,000 | 90,565 | 104,150 | 600,000,000 | 513,162,195 | 590,136,525 |
| `string_append_int` | 43,000 | 90,589 | 104,178 | 150,000,000 | 514,792,443 | 592,011,310 |
| `string_append_int_builtin` | 205,000 | 96,365 | 110,820 | 1,800,000,000 | 530,074,666 | 609,585,866 |
| `string_append_int_edges` | 45,000 | 91,622 | 105,366 | 200,000,000 | 518,037,825 | 595,743,499 |
| `string_concat` | 205,000 | 91,897 | 105,682 | 600,000,000 | 517,415,433 | 595,027,748 |
| `string_concat_reuse` | 205,000 | 93,952 | 108,045 | 600,000,000 | 522,602,477 | 600,992,849 |
| `string_literal_basic` | 134,000 | 89,805 | 103,276 | 450,000,000 | 510,814,934 | 587,437,175 |
| `string_literal_comment_text` | 134,000 | 89,805 | 103,276 | 450,000,000 | 511,902,650 | 588,688,048 |
| `string_literal_copy_return` | 134,000 | 90,631 | 104,226 | 450,000,000 | 512,814,805 | 589,737,026 |
| `string_literal_empty` | 134,000 | 89,805 | 103,276 | 450,000,000 | 511,525,040 | 588,253,796 |
| `string_literal_escapes` | 134,000 | 89,832 | 103,307 | 450,000,000 | 511,617,275 | 588,359,867 |
| `string_literal_generic` | 134,000 | 90,218 | 103,751 | 450,000,000 | 512,742,965 | 589,654,410 |
| `string_literal_long` | 170,000 | 90,284 | 103,827 | 540,000,000 | 521,034,198 | 599,189,328 |
| `string_literal_long_unreached` | 41,000 | 89,682 | 94,167 | 82,000,000 | 515,184,851 | 540,944,094 |
| `string_literal_many_escapes_unreached` | 43,000 | 92,349 | 96,967 | 86,000,000 | 518,732,998 | 544,669,648 |
| `string_literal_normalization` | 134,000 | 90,381 | 103,939 | 450,000,000 | 513,468,499 | 590,488,774 |
| `string_literal_nul_digits` | 134,000 | 89,808 | 103,280 | 450,000,000 | 510,198,981 | 586,728,829 |
| `string_literal_tail_arms` | 156,000 | 91,524 | 105,253 | 500,000,000 | 515,550,258 | 592,882,797 |
| `string_literal_trigraphs` | 134,000 | 89,805 | 103,276 | 450,000,000 | 511,678,066 | 588,429,776 |
| `string_literal_unicode` | 134,000 | 89,805 | 103,276 | 450,000,000 | 511,740,294 | 588,501,339 |
| `string_literal_unicode_escapes` | 134,000 | 89,811 | 103,283 | 450,000,000 | 511,900,535 | 588,685,616 |
| `string_literal_union` | 134,000 | 91,628 | 105,373 | 450,000,000 | 519,854,464 | 597,832,634 |
| `string_literal_unused` | 134,000 | 89,816 | 103,289 | 450,000,000 | 510,525,493 | 587,104,317 |
| `string_match_cleanup` | 150,000 | 91,685 | 105,438 | 600,000,000 | 516,844,757 | 594,371,471 |
| `string_match_first` | 150,000 | 91,227 | 104,912 | 600,000,000 | 514,805,473 | 592,026,294 |
| `string_match_second` | 150,000 | 91,227 | 104,912 | 600,000,000 | 514,572,485 | 591,758,358 |
| `string_slice_bounds` | 25,000 | 95,667 | 110,018 | 90,000,000 | 470,161,241 | 540,685,428 |
| `string_slice_bytes` | 35,000 | 94,395 | 108,555 | 120,000,000 | 524,165,999 | 602,790,899 |
| `string_slice_ownership` | 45,000 | 95,482 | 109,805 | 150,000,000 | 527,387,581 | 606,495,719 |
| `string_starts_with_arguments` | 150,000 | 96,915 | 111,453 | 600,000,000 | 473,318,437 | 544,316,203 |
| `string_starts_with_counted` | 150,000 | 97,393 | 112,002 | 600,000,000 | 530,698,665 | 610,303,465 |

## T3 batch 3: records, unions, tuples, opaque types and equality, 2026-11-05

The 112 programs ported in batch 3 (`blorp/test/e2e/self_hosted_data.brp`, from
12 legacy files) carry ceilings set by the same rule: measured cost plus 15%,
rounded up to a whole count. "Old" is the ceiling in the deleted `test_*.brp`
file, or `none` for the two accepted-only derived-equality compiles, which the
legacy file only compiled and ran. The legacy ceilings were feature limits or
older measurements ("about 30% headroom" at 17,838 allocations, "first direct
compiler samples", "operators 236,887 / 1,914,654,836"); none of them guards a
named regression, so every program takes the plain +15%. The suite has 138 tests: these 112 programs and 26 rejection checks, which
compile nothing that is run and so have no ceiling.

One ported expectation changed: "public record field rejects private type" expected
`2:32`, but `Secret` in `record Envelope { value: Secret }` starts at column 26, where the
compiler reports it and where the five sibling cases point. The legacy file never ran, so
`2:32` was stale; the driver checks `2:26`.

- **Compiler:** the tree of `d49241001` (the last commit touching `blorp/src`
  and `blorp/standard_library`, a rename; this branch changes neither),
  `make -C blorp test-compiler`: `-O0 -DBLORP_MEMORY_DIAGNOSTICS=1`. Host: Apple
  M4, macOS 26.7.1, Apple clang 21.0.0, strictly serial; 1-minute load average
  3.3 to 4.5 at the start of the three sweeps, other sessions shared the machine.
- **Samples:** three `make -C blorp test-e2e INSTRUCTION_CHECK=on` runs with the
  driver temporarily restricted to this suite and printing each compile
  measurement and each strict native report instead of failing on it
  (`batch3_measure.patch`). Compile allocations, and the allocations of all 117
  native runs, agree exactly across the samples. Instructions differ by at most
  1.0% (`derived_recursive`); the table takes the largest. Two spawn flakes
  (`process.run_to_files: create child group; errno=1`) cost one native run
  sample each, `record_reordered` in the first sweep and `tuple_patterns` in the
  third; their compiles completed, so every program has three compile samples and
  those two have two native samples.
- **Reduced library:** the seven `derived_*` programs compile against
  `blorp/test/e2e/trait_inputs/derived/library`, which has no `Dict`, so their
  compiles cost 4,073 to 45,137 allocations and 30M to 141M instructions, 20 to
  50 times less than a standard-library compile. Their old ceilings
  (55,000 to 150,000 allocations) were loose for the same reason.
- **Ranking:** the highest allocation and instruction counts are
  `equality_operators` (132,778 and 604,051,308), then `equality_nesting`
  (116,322) and `tuple_moderate_nested` (110,886). The lower instruction
  cluster from batch 1 (460M to 480M) reappears in `generic_record_union_field`,
  `union_direct_symbolic_list_admission`, the four `record_update_*`
  programs and `opaque_list`/`opaque_recursive`. No program is far from its
  siblings.
- **Legacy ceilings:** 16 of the 110 programs with an old ceiling exceed their
  old allocation ceiling and 99 their old instruction ceiling (the `Dict` base
  cost described above).
- **Samples are kept out of the repository** in the ignored directory
  `/Users/keithphilpott/CLionProjects/blorp/build/blorp2-e2e-ceilings-2026-11-05/`:

| File | sha256 |
| --- | --- |
| `batch3_measure1.log` | `ae0b7db15ad330950202555c7b9b4bf90381c86eb9dfaa5c7c17a5331eaf11c2` |
| `batch3_measure2.log` | `a4effb269d4907527942cfd1f23f64254e472a63e2ebca87e092df7e911dd5ad` |
| `batch3_measure3.log` | `9d8c7e1ae2a0fd69bc218cf149191309490806179633dbec263017f7b371923b` |
| `batch3_measure.patch` (the temporary driver change) | `fd1a39b3becfcdb8eca2a906907ac3eaa754954137b52a6c9acc8dbd84313ad0` |
| `batch3_samples.json` (every sample per program) | `30e2a524e7cd6ef4a8f2fce6f2313a68425f69c413a4c02ecf1a64686395d58b` |
| `batch3_ceilings.json` (the ceiling literals, then each run's strict allocations) | `8137cd3eaf4919354d4a7dfab7b12ad0eb86b18b9fe693f36bfa5df407e2c210` |

| Program | Old allocs | Measured allocs | New allocs | Old instr | Measured instr | New instr |
| --- | --- | --- | --- | --- | --- | --- |
| `derived_accepted_generic_head` | none | 4,073 | 4,684 | none | 29,680,025 | 34,132,029 |
| `derived_accepted_nested_generic_head` | none | 4,183 | 4,811 | none | 29,921,757 | 34,410,021 |
| `derived_callables` | 62,000 | 20,805 | 23,926 | 170,000,000 | 74,846,108 | 86,073,025 |
| `derived_generic` | 150,000 | 45,137 | 51,908 | 400,000,000 | 141,384,805 | 162,592,526 |
| `derived_recursive` | 150,000 | 40,704 | 46,810 | 315,000,000 | 124,122,533 | 142,740,913 |
| `derived_semantics` | 65,000 | 23,221 | 26,705 | 175,000,000 | 80,185,667 | 92,213,518 |
| `derived_values` | 100,000 | 33,642 | 38,689 | 260,000,000 | 109,533,381 | 125,963,389 |
| `equality_dispatch` | 150,000 | 94,654 | 108,853 | 1,900,000,000 | 522,921,871 | 601,360,152 |
| `equality_nesting` | 205,000 | 116,322 | 133,771 | 2,200,000,000 | 596,922,287 | 686,460,631 |
| `equality_operators` | 275,000 | 132,778 | 152,695 | 2,250,000,000 | 604,051,308 | 694,659,005 |
| `equality_order` | 145,000 | 93,473 | 107,494 | 1,850,000,000 | 520,564,832 | 598,649,557 |
| `generic_record_box_float` | 140,000 | 92,036 | 105,842 | 500,000,000 | 523,374,313 | 601,880,460 |
| `generic_record_box_int` | 140,000 | 90,949 | 104,592 | 500,000,000 | 518,486,132 | 596,259,052 |
| `generic_record_box_list` | 140,000 | 95,152 | 109,425 | 500,000,000 | 530,097,141 | 609,611,713 |
| `generic_record_box_string` | 140,000 | 92,113 | 105,930 | 500,000,000 | 522,908,867 | 601,345,198 |
| `generic_record_box_void` | 140,000 | 92,257 | 106,096 | 500,000,000 | 522,644,665 | 601,041,365 |
| `generic_record_managed_alias_reassignment` | 140,000 | 93,185 | 107,163 | 500,000,000 | 527,252,534 | 606,340,415 |
| `generic_record_nested_managed_escape` | 140,000 | 92,930 | 106,870 | 500,000,000 | 526,773,301 | 605,789,297 |
| `generic_record_nested_projection` | 140,000 | 92,245 | 106,082 | 500,000,000 | 523,279,696 | 601,771,651 |
| `generic_record_nested_string_list` | 140,000 | 94,672 | 108,873 | 500,000,000 | 538,346,174 | 619,098,101 |
| `generic_record_partial_direct_int` | 140,000 | 90,572 | 104,158 | 500,000,000 | 520,333,152 | 598,383,125 |
| `generic_record_partial_direct_string` | 140,000 | 91,704 | 105,460 | 500,000,000 | 522,646,902 | 601,043,938 |
| `generic_record_partial_nested` | 140,000 | 91,087 | 104,751 | 500,000,000 | 525,408,647 | 604,219,945 |
| `generic_record_partial_pair_order` | 140,000 | 92,928 | 106,868 | 500,000,000 | 529,419,401 | 608,832,312 |
| `generic_record_partial_ufcs` | 140,000 | 90,576 | 104,163 | 500,000,000 | 519,860,230 | 597,839,265 |
| `generic_record_partial_union_child` | 140,000 | 91,959 | 105,753 | 500,000,000 | 525,466,213 | 604,286,145 |
| `generic_record_phantom_arguments` | 140,000 | 92,947 | 106,890 | 500,000,000 | 529,257,159 | 608,645,733 |
| `generic_record_result_context` | 140,000 | 91,046 | 104,703 | 500,000,000 | 519,266,699 | 597,156,704 |
| `generic_record_rigid_owner_positions` | 140,000 | 91,723 | 105,482 | 500,000,000 | 526,058,736 | 604,967,547 |
| `generic_record_same_reader_twice` | 140,000 | 93,092 | 107,056 | 500,000,000 | 524,325,397 | 602,974,207 |
| `generic_record_swapped_pair` | 140,000 | 95,114 | 109,382 | 500,000,000 | 534,256,993 | 614,395,542 |
| `generic_record_union_field` | 140,000 | 93,552 | 107,585 | 500,000,000 | 462,209,620 | 531,541,063 |
| `generic_record_unused_generic_and_passthrough` | 140,000 | 90,964 | 104,609 | 500,000,000 | 519,734,289 | 597,694,433 |
| `generic_record_unused_list_int` | 140,000 | 89,943 | 103,435 | 500,000,000 | 518,742,153 | 596,553,476 |
| `generic_record_void_argument` | 140,000 | 91,717 | 105,475 | 500,000,000 | 521,451,283 | 599,668,976 |
| `opaque_inline` | 48,000 | 95,123 | 109,392 | 180,000,000 | 530,955,799 | 610,599,169 |
| `opaque_int` | 42,000 | 90,877 | 104,509 | 140,000,000 | 516,071,681 | 593,482,434 |
| `opaque_keys` | 50,000 | 96,835 | 111,361 | 140,000,000 | 534,562,296 | 614,746,641 |
| `opaque_list` | 60,000 | 96,934 | 111,475 | 240,000,000 | 475,950,801 | 547,343,422 |
| `opaque_managed` | 58,000 | 101,225 | 116,409 | 220,000,000 | 549,794,170 | 632,263,296 |
| `opaque_recursive` | 75,000 | 99,142 | 114,014 | 300,000,000 | 480,159,702 | 552,183,658 |
| `opaque_scalar` | 44,000 | 91,943 | 105,735 | 140,000,000 | 517,995,843 | 595,695,220 |
| `record_aliases` | 140,000 | 90,599 | 104,189 | 500,000,000 | 513,328,276 | 590,327,518 |
| `record_basic` | 140,000 | 90,671 | 104,272 | 500,000,000 | 514,416,263 | 591,578,703 |
| `record_context` | 140,000 | 90,574 | 104,161 | 500,000,000 | 512,792,391 | 589,711,250 |
| `record_extrema` | 140,000 | 90,276 | 103,818 | 500,000,000 | 513,497,579 | 590,522,216 |
| `record_field_order` | 140,000 | 92,878 | 106,810 | 500,000,000 | 519,340,713 | 597,241,820 |
| `record_generic` | 140,000 | 91,494 | 105,219 | 500,000,000 | 514,792,055 | 592,010,864 |
| `record_identity_escape` | 140,000 | 91,063 | 104,723 | 500,000,000 | 515,673,869 | 593,024,950 |
| `record_identity_reassignment` | 140,000 | 92,679 | 106,581 | 500,000,000 | 521,803,780 | 600,074,347 |
| `record_list_field` | 140,000 | 95,185 | 109,463 | 500,000,000 | 525,901,517 | 604,786,745 |
| `record_managed_aliases` | 140,000 | 93,295 | 107,290 | 500,000,000 | 521,888,974 | 600,172,321 |
| `record_managed_self_assignment` | 140,000 | 90,828 | 104,453 | 500,000,000 | 513,829,675 | 590,904,127 |
| `record_mixed` | 140,000 | 91,334 | 105,035 | 500,000,000 | 516,431,543 | 593,896,275 |
| `record_mixed_fields` | 140,000 | 92,290 | 106,134 | 500,000,000 | 518,686,282 | 596,489,225 |
| `record_nested_escape` | 140,000 | 92,490 | 106,364 | 500,000,000 | 518,682,520 | 596,484,898 |
| `record_nested_projection` | 140,000 | 91,359 | 105,063 | 500,000,000 | 516,288,420 | 593,731,683 |
| `record_nested_union_field` | 140,000 | 93,613 | 107,655 | 500,000,000 | 525,066,941 | 603,826,983 |
| `record_owning_union_field` | 140,000 | 93,144 | 107,116 | 500,000,000 | 524,321,783 | 602,970,051 |
| `record_phantom_union_fields` | 140,000 | 92,557 | 106,441 | 500,000,000 | 522,506,121 | 600,882,040 |
| `record_reassigned` | 140,000 | 90,637 | 104,233 | 500,000,000 | 513,235,748 | 590,221,111 |
| `record_recursive_direct` | 140,000 | 89,640 | 103,086 | 500,000,000 | 510,242,209 | 586,778,541 |
| `record_recursive_mutual` | 140,000 | 89,906 | 103,392 | 500,000,000 | 514,384,368 | 591,542,024 |
| `record_recursive_union` | 140,000 | 90,148 | 103,671 | 500,000,000 | 518,638,873 | 596,434,704 |
| `record_reordered` | 140,000 | 90,777 | 104,394 | 500,000,000 | 513,154,162 | 590,127,287 |
| `record_scalar_nested_field` | 140,000 | 92,540 | 106,421 | 500,000,000 | 519,285,413 | 597,178,225 |
| `record_shared_record` | 140,000 | 92,208 | 106,040 | 500,000,000 | 517,471,964 | 595,092,759 |
| `record_shared_string` | 140,000 | 91,448 | 105,166 | 500,000,000 | 515,674,827 | 593,026,052 |
| `record_union_aliases` | 140,000 | 93,627 | 107,672 | 500,000,000 | 526,311,161 | 605,257,836 |
| `record_union_payload` | 140,000 | 92,711 | 106,618 | 500,000,000 | 526,180,064 | 605,107,074 |
| `record_unmanaged_union_field` | 140,000 | 92,303 | 106,149 | 500,000,000 | 516,910,925 | 594,447,564 |
| `record_unused_managed` | 140,000 | 90,468 | 104,039 | 500,000,000 | 513,677,421 | 590,729,035 |
| `record_update_aliases` | 47,000 | 93,325 | 107,324 | 150,000,000 | 467,573,427 | 537,709,442 |
| `record_update_escaped_children` | 51,000 | 96,251 | 110,689 | 150,000,000 | 474,231,068 | 545,365,729 |
| `record_update_managed_reorder` | 51,000 | 96,218 | 110,651 | 100,000,000 | 474,118,621 | 545,236,415 |
| `record_update_order` | 48,000 | 94,141 | 108,263 | 180,000,000 | 469,535,288 | 539,965,582 |
| `record_void_field` | 140,000 | 90,122 | 103,641 | 500,000,000 | 512,769,491 | 589,684,915 |
| `record_wide` | 140,000 | 93,748 | 107,811 | 500,000,000 | 522,750,072 | 601,162,583 |
| `recursive_union_deep` | 47,000 | 94,435 | 108,601 | 91,000,000 | 523,103,243 | 601,568,730 |
| `recursive_union_depth` | 44,000 | 92,053 | 105,861 | 87,000,000 | 516,557,432 | 594,041,047 |
| `recursive_union_list_payload` | 44,000 | 89,743 | 103,205 | 87,000,000 | 510,830,095 | 587,454,610 |
| `recursive_union_shared` | 46,000 | 93,294 | 107,289 | 90,000,000 | 519,927,669 | 597,916,820 |
| `recursive_union_trail` | 46,000 | 93,979 | 108,076 | 90,000,000 | 521,840,155 | 600,116,179 |
| `tuple_callable_members` | 140,000 | 95,271 | 109,562 | 500,000,000 | 524,966,053 | 603,710,961 |
| `tuple_loops_capture` | 140,000 | 98,364 | 113,119 | 500,000,000 | 532,535,766 | 612,416,131 |
| `tuple_moderate_nested` | 140,000 | 110,886 | 127,519 | 500,000,000 | 575,355,546 | 661,658,878 |
| `tuple_patterns` | 140,000 | 99,756 | 114,720 | 500,000,000 | 539,491,481 | 620,415,204 |
| `tuple_triple` | 140,000 | 89,939 | 103,430 | 500,000,000 | 511,861,986 | 588,641,284 |
| `tuple_values` | 140,000 | 94,951 | 109,194 | 500,000,000 | 525,109,151 | 603,875,524 |
| `tuple_void_order` | 140,000 | 94,191 | 108,320 | 500,000,000 | 525,553,465 | 604,386,485 |
| `union_direct` | 140,000 | 90,860 | 104,489 | 500,000,000 | 513,197,660 | 590,177,309 |
| `union_direct_float_output` | 140,000 | 92,579 | 106,466 | 500,000,000 | 518,251,969 | 595,989,765 |
| `union_direct_forward_finite` | 140,000 | 92,245 | 106,082 | 500,000,000 | 516,779,173 | 594,296,049 |
| `union_direct_managed_record_escape` | 140,000 | 93,353 | 107,356 | 500,000,000 | 520,512,311 | 598,589,158 |
| `union_direct_nested_nominal_escape` | 140,000 | 94,424 | 108,588 | 500,000,000 | 526,928,414 | 605,967,677 |
| `union_direct_parent_alias_reassignment` | 140,000 | 93,236 | 107,222 | 500,000,000 | 520,361,677 | 598,415,929 |
| `union_direct_string_escape` | 140,000 | 91,737 | 105,498 | 500,000,000 | 515,656,077 | 593,004,489 |
| `union_direct_symbolic_list_admission` | 140,000 | 91,480 | 105,202 | 500,000,000 | 467,659,615 | 537,808,558 |
| `union_direct_void_empty` | 140,000 | 90,713 | 104,320 | 500,000,000 | 513,138,896 | 590,109,731 |
| `union_direct_void_tag` | 140,000 | 90,778 | 104,395 | 500,000,000 | 514,870,663 | 592,101,263 |
| `union_first` | 140,000 | 90,493 | 104,067 | 500,000,000 | 513,370,295 | 590,375,840 |
| `union_identity` | 140,000 | 90,862 | 104,492 | 500,000,000 | 514,662,494 | 591,861,869 |
| `union_multiple_alias_whole_reassignment` | 140,000 | 95,307 | 109,604 | 500,000,000 | 526,290,993 | 605,234,642 |
| `union_multiple_distinct_second_escape` | 140,000 | 92,523 | 106,402 | 500,000,000 | 518,086,897 | 595,799,932 |
| `union_multiple_generic_swapped` | 140,000 | 94,708 | 108,915 | 500,000,000 | 533,438,484 | 613,454,257 |
| `union_multiple_mixed_positions` | 140,000 | 93,392 | 107,401 | 500,000,000 | 519,996,965 | 597,996,510 |
| `union_multiple_pair_duplicate_escape` | 140,000 | 92,039 | 105,845 | 500,000,000 | 516,032,265 | 593,437,105 |
| `union_multiple_phantom_instances` | 140,000 | 94,629 | 108,824 | 500,000,000 | 527,764,464 | 606,929,134 |
| `union_multiple_written_argument_effects` | 140,000 | 93,016 | 106,969 | 500,000,000 | 519,697,689 | 597,652,343 |
| `union_receiver` | 140,000 | 90,863 | 104,493 | 500,000,000 | 513,365,105 | 590,369,871 |
| `union_second` | 140,000 | 90,493 | 104,067 | 500,000,000 | 513,372,122 | 590,377,941 |
| `union_values` | 135,000 | 92,166 | 105,991 | 445,000,000 | 517,355,767 | 594,959,133 |


## T3 batch 4: control flow, patterns, process input and entry points, 2026-11-06

The 83 programs ported in batch 4 (`blorp/test/e2e/self_hosted_control.brp`, from 12
legacy files) carry ceilings set by the same rule: measured cost plus 15%,
rounded up to a whole count. "Old" is the ceiling in the deleted `test_*.brp`
file, or `none` for the four `test_entry` programs, which the legacy file only
compiled and ran. The legacy ceilings were "initial absolute feature gates",
"prospective feature ceilings" and "measured normal fixture compilations ... modest
headroom" from before the library grew; none of them names a regression it
guards, so every program takes the plain +15%. The suite has 90 tests: these 83
programs and 7 rejection checks, which compile nothing that is run and so have
no ceiling. The 256-arm match's one-body-and-one-incoming-edge check is now a unit test
on the lowered join (`test_lower/test_match_arms.brp`), not a count of C text.
No test now checks the emitted C's brace depth: that is emit's property, the
legacy check never ran, and emit exposes no structure to assert it on without
counting characters of the C.

- **Compiler:** the tree of `35e2e0a86` (the last commit touching `blorp/src` and
  `blorp/standard_library`; this branch changes neither), `make -C blorp
  test-compiler`: `-O0 -DBLORP_MEMORY_DIAGNOSTICS=1`. Host: Apple M4, macOS 26.7.1,
  Apple clang 21.0.0, strictly serial; 1-minute load average 2.5 to 2.6 at the
  start of the three sweeps, other sessions shared the machine.
- **Samples:** three `make -C blorp test-e2e INSTRUCTION_CHECK=on` runs with the
  driver temporarily restricted to this suite and printing each compile
  measurement and each strict native report instead of failing on it
  (`batch4_measure.patch`). Compile allocations and the allocations of all 163
  native runs agree exactly across the samples; instructions differ by at most
  0.5%, and the table takes the largest. No spawn flake occurred.
- **Ranking:** the highest allocation and instruction counts are `match_many_arms`
  (355,304 and 1,212,641,145, a 517-line source), then `pattern_moderate_nested`
  (227,502) and `calculator_float_stress` (118,779). Every other program is
  between 89,511 and 113,870 allocations, the library's base cost plus its own
  source. No program is far from its siblings.
- **Legacy ceilings:** 13 of the 79 programs with an old ceiling exceed their old
  allocation ceiling and 48 their old instruction ceiling (the `Dict` base cost
  described above). The reset also lowers the loose ones: for example
  `source_loops_nesting` from 1,500,000 allocations and 5,000,000,000 instructions
  to its measured cost plus 15%.
- **Native counts:** the legacy `ZeroTargetAllocations` of
  `previous_or_pattern` and the "positive and balanced" checks of the other eight
  structural-pattern programs were not exact counts, and every `run_source_example`,
  `run_output_example` and `argv_case` program checked no native allocations at all;
  all 163 runs now check an exact strict count.
- **Samples are kept out of the repository** in the ignored directory
  `/Users/keithphilpott/CLionProjects/blorp/build/blorp2-e2e-ceilings-2026-11-05/`:

| File | sha256 |
| --- | --- |
| `batch4_measure1.log` | `c155310c4c3497825bde0d261ee78363e0494c7faefc43d0795ba2116ea9f271` |
| `batch4_measure2.log` | `da95d6e1ae14a51975ef7cc7669f6063cbc232b361feb1461d21ee5c560f421d` |
| `batch4_measure3.log` | `78e86257394ba6e31141654d1072fdff85ccd469af61ba841a6e2cd41ffd59b9` |
| `batch4_measure.patch` (the temporary driver change) | `41aa74f0ea3f5b3c895842ab4fd3872eee8d5253adaf8c486dbdfd65c0ae24e9` |
| `batch4_samples.json` (every sample per program) | `eab87e5872a2f049cac151984db2617acbc15f8b2dab4161c6272eb86ef73d56` |
| `batch4_ceilings.json` (the ceiling literals, then each run's strict allocations) | `b6017f16cf81de798d5df645f7134e8e53b663389d6d4a4f8a9e33386a35ee96` |

| Program | Old allocs | Measured allocs | New allocs | Old instr | Measured instr | New instr |
| --- | --- | --- | --- | --- | --- | --- |
| `argument_input` | 195,000 | 96,530 | 111,010 | 620,000,000 | 473,642,928 | 544,689,368 |
| `argument_input_access_stress` | 270,000 | 113,870 | 130,951 | 850,000,000 | 525,204,485 | 603,985,158 |
| `argument_input_escaped_string` | 210,000 | 95,676 | 110,028 | 650,000,000 | 475,719,128 | 547,076,998 |
| `calculator_addition` | 240,000 | 99,649 | 114,597 | 710,000,000 | 481,562,553 | 553,796,936 |
| `calculator_float` | 270,000 | 113,218 | 130,201 | 800,000,000 | 515,771,339 | 593,137,040 |
| `calculator_float_literals` | 190,000 | 95,844 | 110,221 | 590,000,000 | 529,433,557 | 608,848,591 |
| `calculator_float_stress` | 230,000 | 118,779 | 136,596 | 720,000,000 | 597,475,280 | 687,096,572 |
| `calculator_integer` | 255,000 | 113,217 | 130,200 | 800,000,000 | 514,564,710 | 591,749,417 |
| `effects_alias` | 145,000 | 90,895 | 104,530 | 500,000,000 | 514,378,599 | 591,535,389 |
| `effects_bytes` | 145,000 | 90,565 | 104,150 | 500,000,000 | 513,325,488 | 590,324,312 |
| `effects_hello` | 145,000 | 90,404 | 103,965 | 500,000,000 | 513,979,167 | 591,076,043 |
| `effects_nested` | 145,000 | 91,151 | 104,824 | 500,000,000 | 514,824,609 | 592,048,301 |
| `effects_order` | 145,000 | 90,960 | 104,604 | 500,000,000 | 516,192,676 | 593,621,578 |
| `effects_selected_arm` | 145,000 | 91,951 | 105,744 | 500,000,000 | 516,675,101 | 594,176,367 |
| `effects_sequence` | 230,000 | 100,105 | 115,121 | 800,000,000 | 543,428,480 | 624,942,752 |
| `effects_unit` | 145,000 | 92,270 | 106,111 | 500,000,000 | 523,628,986 | 602,173,334 |
| `main_implicit_void_arguments` | 195,000 | 92,659 | 106,558 | 620,000,000 | 464,229,589 | 533,864,028 |
| `main_implicit_void_nullary` | 195,000 | 90,907 | 104,544 | 620,000,000 | 513,875,444 | 590,956,761 |
| `main_int_arguments` | 195,000 | 90,144 | 103,666 | 620,000,000 | 456,334,856 | 524,785,085 |
| `main_int_nullary` | 195,000 | 89,511 | 102,938 | 620,000,000 | 510,293,794 | 586,837,864 |
| `main_pure_implicit_void_arguments` | 195,000 | 89,800 | 103,270 | 620,000,000 | 509,862,336 | 586,341,687 |
| `main_pure_int_arguments` | 195,000 | 90,145 | 103,667 | 620,000,000 | 456,757,371 | 525,270,977 |
| `main_pure_int_nullary` | 195,000 | 89,512 | 102,939 | 620,000,000 | 510,485,725 | 587,058,584 |
| `main_pure_void_nullary` | 195,000 | 90,884 | 104,517 | 620,000,000 | 435,899,616 | 501,284,559 |
| `main_void_arguments` | 195,000 | 91,683 | 105,436 | 620,000,000 | 462,041,177 | 531,347,354 |
| `main_void_nullary` | 195,000 | 90,669 | 104,270 | 620,000,000 | 513,937,029 | 591,027,584 |
| `match_binding_current` | 140,000 | 91,667 | 105,418 | 500,000,000 | 515,963,538 | 593,358,069 |
| `match_binding_empty` | 140,000 | 91,541 | 105,273 | 500,000,000 | 516,145,333 | 593,567,133 |
| `match_binding_original` | 140,000 | 91,428 | 105,143 | 500,000,000 | 515,150,194 | 592,422,724 |
| `match_binding_outer` | 140,000 | 91,247 | 104,935 | 500,000,000 | 515,682,953 | 593,035,396 |
| `match_constructor_argument` | 140,000 | 90,980 | 104,627 | 500,000,000 | 514,895,292 | 592,129,586 |
| `match_constructor_spine` | 230,000 | 95,305 | 109,601 | 900,000,000 | 527,602,254 | 606,742,593 |
| `match_empty` | 140,000 | 90,690 | 104,294 | 500,000,000 | 513,104,716 | 590,070,424 |
| `match_many_arms` | 230,000 | 355,304 | 408,600 | 900,000,000 | 1,212,641,145 | 1,394,537,317 |
| `match_qualified_flat` | 140,000 | 97,107 | 111,674 | 500,000,000 | 532,582,632 | 612,470,027 |
| `match_scalar_capture` | 140,000 | 91,053 | 104,711 | 500,000,000 | 513,558,075 | 590,591,787 |
| `match_selected_arm` | 140,000 | 91,333 | 105,033 | 500,000,000 | 514,889,523 | 592,122,952 |
| `match_shadow` | 140,000 | 91,095 | 104,760 | 500,000,000 | 513,670,320 | 590,720,868 |
| `match_sibling_empty` | 140,000 | 91,038 | 104,694 | 500,000,000 | 514,898,200 | 592,132,930 |
| `match_sibling_payload` | 140,000 | 90,856 | 104,485 | 500,000,000 | 513,262,938 | 590,252,379 |
| `match_value` | 135,000 | 90,859 | 104,488 | 500,000,000 | 513,461,727 | 590,480,987 |
| `match_values` | 140,000 | 91,460 | 105,179 | 500,000,000 | 515,018,941 | 592,271,783 |
| `match_whole_empty` | 140,000 | 91,288 | 104,982 | 500,000,000 | 514,274,708 | 591,415,915 |
| `match_wildcard` | 140,000 | 90,505 | 104,081 | 500,000,000 | 512,495,064 | 589,369,324 |
| `option_byte_at` | 205,000 | 90,713 | 104,320 | 600,000,000 | 513,534,199 | 590,564,329 |
| `option_byte_at_zero` | 205,000 | 90,715 | 104,323 | 600,000,000 | 512,207,804 | 589,038,975 |
| `option_from_codepoint_nul` | 250,000 | 91,546 | 105,278 | 800,000,000 | 515,334,460 | 592,634,629 |
| `option_from_codepoint_ownership` | 250,000 | 91,420 | 105,133 | 800,000,000 | 515,458,095 | 592,776,810 |
| `option_imported` | 205,000 | 90,989 | 104,638 | 600,000,000 | 513,006,052 | 589,956,960 |
| `option_parse_int` | 145,000 | 91,099 | 104,764 | 500,000,000 | 513,483,100 | 590,505,565 |
| `option_repeated` | 170,000 | 106,488 | 122,462 | 550,000,000 | 555,191,874 | 638,470,656 |
| `pattern_alternative_inputs` | 140,000 | 93,844 | 107,921 | 500,000,000 | 521,789,767 | 600,058,233 |
| `pattern_list_rest` | 140,000 | 96,821 | 111,345 | 500,000,000 | 528,095,902 | 607,310,288 |
| `pattern_moderate_nested` | 140,000 | 227,502 | 261,628 | 500,000,000 | 987,915,286 | 1,136,102,579 |
| `pattern_nested_fallthrough` | 140,000 | 93,988 | 108,087 | 500,000,000 | 521,211,636 | 599,393,382 |
| `pattern_ordered_inputs` | 140,000 | 98,156 | 112,880 | 500,000,000 | 532,670,180 | 612,570,707 |
| `pattern_previous_list` | 140,000 | 90,915 | 104,553 | 500,000,000 | 457,937,475 | 526,628,097 |
| `pattern_previous_or` | 140,000 | 90,645 | 104,242 | 500,000,000 | 512,346,319 | 589,198,267 |
| `pattern_previous_string` | 140,000 | 90,289 | 103,833 | 500,000,000 | 511,308,323 | 588,004,572 |
| `pattern_string_bytes` | 140,000 | 93,622 | 107,666 | 500,000,000 | 521,000,785 | 599,150,903 |
| `result_chain_1` | 60,000 | 93,622 | 107,666 | 200,000,000 | 519,832,523 | 597,807,402 |
| `result_chain_16` | 60,000 | 105,262 | 121,052 | 200,000,000 | 548,408,356 | 630,669,610 |
| `result_chain_2` | 60,000 | 94,394 | 108,554 | 200,000,000 | 522,695,129 | 601,099,399 |
| `result_chain_5` | 60,000 | 96,726 | 111,235 | 200,000,000 | 527,127,066 | 606,196,126 |
| `result_chain_9` | 60,000 | 99,830 | 114,805 | 200,000,000 | 534,102,806 | 614,218,227 |
| `result_propagation_managed` | 51,000 | 97,321 | 111,920 | 200,000,000 | 529,859,905 | 609,338,891 |
| `result_rhs_carriers` | 60,000 | 94,997 | 109,247 | 200,000,000 | 523,958,782 | 602,552,600 |
| `source_loops_control` | 600,000 | 104,889 | 120,623 | 2,000,000,000 | 550,370,372 | 632,925,928 |
| `source_loops_list_sum` | 300,000 | 91,216 | 104,899 | 1,000,000,000 | 514,134,353 | 591,254,506 |
| `source_loops_managed_headers` | 1,000,000 | 108,003 | 124,204 | 3,000,000,000 | 506,298,424 | 582,243,188 |
| `source_loops_nesting` | 1,500,000 | 109,380 | 125,787 | 5,000,000,000 | 575,910,583 | 662,297,171 |
| `source_while_evaluation_order` | 150,000 | 95,437 | 109,753 | 500,000,000 | 525,529,550 | 604,358,983 |
| `source_while_header_swap` | 150,000 | 93,205 | 107,186 | 500,000,000 | 520,708,344 | 598,814,596 |
| `source_while_location` | 150,000 | 99,018 | 113,871 | 500,000,000 | 535,478,876 | 615,800,708 |
| `source_while_nested` | 300,000 | 100,751 | 115,864 | 1,000,000,000 | 540,076,464 | 621,087,934 |
| `test_entry_counts` | none | 102,388 | 117,747 | none | 545,647,554 | 627,494,688 |
| `test_entry_empty` | none | 102,140 | 117,461 | none | 545,568,306 | 627,403,552 |
| `test_entry_failing` | none | 104,108 | 119,725 | none | 549,358,205 | 631,761,936 |
| `test_entry_passing` | none | 103,320 | 118,818 | none | 546,966,730 | 629,011,740 |
| `value_if_answer` | 45,000 | 90,654 | 104,253 | 200,000,000 | 512,894,437 | 589,828,603 |
| `value_if_effects` | 45,000 | 98,552 | 113,335 | 200,000,000 | 535,663,388 | 616,012,897 |
| `value_if_list_aliases` | 45,000 | 96,405 | 110,866 | 200,000,000 | 473,237,885 | 544,223,568 |
| `value_if_return` | 45,000 | 90,050 | 103,558 | 200,000,000 | 511,410,998 | 588,122,648 |

## T3 batch 5: language surface, 2026-11-06

The 166 programs ported in batch 5 (`blorp/test/e2e/self_hosted_surface.brp`, from
13 legacy files) carry ceilings set by the same rule: measured cost plus 15%,
rounded up to a whole count. "Old" is the ceiling in the deleted `test_*.brp`
file (`run_accounted_example` ones took the limits they were given). The suite has
214 tests: 166 programs and 48 rejection checks (the cross-file and cycle
rejections among them), which compile nothing that is run and so have no ceiling.
The legacy `generic/lambda/capture_managed` case is not run (below), so it has none.

- **Compiler:** the tree of `3887c855e` (the last commit touching `blorp/src` and
  `blorp/standard_library`; this branch changes neither), `make -C blorp
  test-compiler`: `-O0 -DBLORP_MEMORY_DIAGNOSTICS=1`. Host: Apple M4, macOS 26.7.1,
  Apple clang 21.0.0, strictly serial; 1-minute load average 4.1, 3.4 and 3.3 at the
  start of the three sweeps, and another session ran its own driver during
  the final gate run.
- **Samples:** three `make -C blorp test-e2e INSTRUCTION_CHECK=on` runs with the
  driver temporarily restricted to this suite and printing each compile
  measurement and each strict native report instead of failing on it
  (`batch5_measure.patch`). Compile allocations and the allocations of all 189
  native runs agree exactly across the samples; instructions differ by at most
  2.1% (`traits_concrete`, a 28M-instruction compile) and mostly by under 0.5%; the table takes the
  largest. Two measurement lines per sweep were cut by interleaved driver output
  (`lists_concat_points`, `namespace_alias_call`); the sweeps agree on their other
  samples. No spawn flake occurred.
- **Ranking:** `imports_flat` (174,624 allocations, 2.2 G instructions) and
  `imports_direct_chain` (169,547; 808 M) are by far the largest, then
  `generics_managed_deep` (123,414) and `generics_nested_deep` (122,480). The six
  `traits` and `trait_bounds` programs are the smallest (3,717 to 18,377 allocations) because they
  compile against their own library roots, which are not the standard library.
  Every other program is between 89,578 and 123,414 allocations.
- **Legacy ceilings:** 44 of the 166 programs exceed their old allocation ceiling
  and 79 their old instruction ceiling (the `Dict` base cost described above); the
  `lists` ones are the largest group (23 of them, 34,043 to 47,991 allocations over).
  The reset also lowers the loose ones: for example every `generics` and `imports`
  program from 600,000,000 instructions, and `stored_callables_*` from
  about 1,500,000,000, to its measured cost plus 15%.
- **Two ceilings guard a regression and need a decision.** `imports_direct_chain`
  (old 110,000 allocations, 300,000,000 instructions) and `imports_flat` (old
  60,000 and 160,000,000) were set when "the namespace scopes commit measured the
  direct chain at 248 M instructions and 79,774 allocations and the flat program at
  132 M and 27,515, where the program-wide namespace before it measured 528 M and
  375 M": they exist to reject a program-wide namespace that grows with the
  square of the module count. Both exceed their old ceilings by more than the
  `Dict` base cost explains, and the flat program's cost is no longer linear in
  its 64 modules. One compile each of the same generated programs at other sizes
  (`batch5_scale.txt`):

| Modules | `flat` allocations | `chain` allocations |
| --- | --- | --- |
| 16 | 104,680 | 109,735 |
| 32 | 123,896 | 129,676 |
| 64 | 174,630 | 169,553 |
| 128 | 325,224 | 249,303 |

  The chain grows by 1,250 per module at every size; the flat program by 950, 1,200,
  1,590 and 2,350 per module over the same steps. The table below gives both
  programs plain measured +15% ceilings, which would not detect a further
  regression of this kind; the right ceilings, or a fix of the flat program's growth,
  are not decided here.
- **`capture_managed` is not ported.** `generic/lambda/capture_managed.brp` (legacy
  "immutable managed captures retain aliases, nested values and written operand
  order") does not link: its `from_void(unit: Void)` lambda captures a Void
  parameter, and the emitter declares that closure environment as an empty
  `struct blorp_r_N{};`, which `-pedantic -Werror` rejects (`empty struct is a GNU
  extension`, then `excess elements in struct initializer`). It reduces to one
  helper taking a callback and one lambda mentioning the Void parameter.
- **Native counts:** the legacy `ZeroTargetAllocations` of `traits_concrete`
  is kept (exact 0); the "positive and balanced" checks of the other 11
  `run_accounted_example` programs, and every `run_source_example`,
  `run_output_example` and `argv_case` program, checked no exact native allocation
  count. All 189 runs now check an exact strict count.
- **A stale expectation fixed:** the legacy `a module does not reexport an
  imported union` expected the note `box.brp:1:13`; the declaration is
  `union Box[T]:`, so the compiler's `1:7` (the name) is right, and the case now
  expects it.
- **Samples are kept out of the repository** in the ignored directory
  `/Users/keithphilpott/CLionProjects/blorp/build/blorp2-e2e-ceilings-2026-11-05/`:

| File | sha256 |
| --- | --- |
| `batch5_measure1.log` | `8db79a277c222b69cf09fe3131468e7269de9335ce2b4332555e7942e00e5196` |
| `batch5_measure2.log` | `9192754bf09731d1c300a7d4e9282bc0cf827f1d149dee3a7b9b7194150a967d` |
| `batch5_measure3.log` | `bf54ef902eeadbd7a2cc2afe332a62234958ac6c34fdabe69ae33b60f63fc68e` |
| `batch5_measure.patch` (the temporary driver change) | `75859496ef73b49a13b927c78547cd89272556b9326e2b66c2d75c1b08dd54ac` |
| `batch5_samples.json` (every sample per program) | `4b64836c80c792c1771adcd8907b84106abfe681589e43156e54b58c60c8167b` |
| `batch5_ceilings.json` (the ceiling literals, then each run's strict allocations) | `0828b13aa888db7d805f5a4c806085782e9dc371be76200f4f52360c42016f41` |
| `batch5_load.txt` (load averages at the sweeps) | `981d515efc458dd8b3e448eb781181fc0f97a49480820ea33243c048be790d0a` |
| `batch5_scale.txt` (module-count scaling) | `50bdf6b9a31657bc7a80a7b2534873b3ed676e98789759be11123a4807e32f4b` |

| Program | Old allocs | Measured allocs | New allocs | Old instr | Measured instr | New instr |
| --- | --- | --- | --- | --- | --- | --- |
| `bindings_basic` | 140,000 | 90,333 | 103,883 | 500,000,000 | 512,328,900 | 589,178,235 |
| `bindings_capture_shadow` | 140,000 | 91,151 | 104,824 | 500,000,000 | 513,781,282 | 590,848,475 |
| `bindings_ordered_calls` | 140,000 | 90,979 | 104,626 | 500,000,000 | 513,968,741 | 591,064,053 |
| `bindings_parameter_shadow` | 140,000 | 90,097 | 103,612 | 500,000,000 | 511,742,078 | 588,503,390 |
| `bindings_pure_mutation` | 140,000 | 90,375 | 103,932 | 500,000,000 | 512,471,970 | 589,342,766 |
| `bindings_self_assignment` | 140,000 | 89,916 | 103,404 | 500,000,000 | 511,597,595 | 588,337,235 |
| `bindings_union_current` | 140,000 | 91,172 | 104,848 | 500,000,000 | 513,906,907 | 590,992,944 |
| `bindings_union_original` | 140,000 | 91,240 | 104,926 | 500,000,000 | 514,838,340 | 592,064,091 |
| `bindings_unused_initializer` | 140,000 | 90,198 | 103,728 | 500,000,000 | 512,121,463 | 588,939,683 |
| `bindings_values` | 140,000 | 90,272 | 103,813 | 500,000,000 | 512,453,165 | 589,321,140 |
| `generics_annotations_contextual_list` | 43,000 | 91,461 | 105,181 | 180,000,000 | 514,302,637 | 591,448,033 |
| `generics_annotations_identity` | 43,000 | 89,623 | 103,067 | 180,000,000 | 510,859,258 | 587,488,147 |
| `generics_arguments` | 150,000 | 90,031 | 103,536 | 600,000,000 | 511,991,333 | 588,790,033 |
| `generics_arguments_box` | 150,000 | 91,801 | 105,572 | 600,000,000 | 520,214,856 | 598,247,085 |
| `generics_arguments_first_string` | 150,000 | 91,180 | 104,857 | 600,000,000 | 514,750,428 | 591,962,993 |
| `generics_arguments_later` | 150,000 | 90,030 | 103,535 | 600,000,000 | 512,374,536 | 589,230,717 |
| `generics_arguments_repeated_string` | 150,000 | 91,080 | 104,742 | 600,000,000 | 514,056,577 | 591,165,064 |
| `generics_arguments_second_string` | 150,000 | 91,183 | 104,861 | 600,000,000 | 514,852,692 | 592,080,596 |
| `generics_bindings` | 150,000 | 91,058 | 104,717 | 600,000,000 | 513,877,990 | 590,959,689 |
| `generics_box` | 150,000 | 91,336 | 105,037 | 600,000,000 | 519,731,093 | 597,690,757 |
| `generics_contextual_expected_result` | 150,000 | 91,268 | 104,959 | 600,000,000 | 522,294,196 | 600,638,326 |
| `generics_contextual_nested_rigid` | 150,000 | 92,076 | 105,888 | 600,000,000 | 453,692,381 | 521,746,239 |
| `generics_contextual_nominal_siblings` | 150,000 | 98,665 | 113,465 | 600,000,000 | 539,959,001 | 620,952,852 |
| `generics_contextual_partial_constructor` | 150,000 | 91,176 | 104,853 | 600,000,000 | 521,398,986 | 599,608,834 |
| `generics_contextual_partial_ufcs` | 150,000 | 91,183 | 104,861 | 600,000,000 | 523,168,740 | 601,644,051 |
| `generics_contextual_repeated_hint` | 150,000 | 91,716 | 105,474 | 600,000,000 | 536,625,425 | 617,119,239 |
| `generics_contextual_sibling` | 150,000 | 91,949 | 105,742 | 600,000,000 | 523,392,160 | 601,900,984 |
| `generics_forward` | 150,000 | 90,354 | 103,908 | 600,000,000 | 434,680,775 | 499,882,892 |
| `generics_forward_string` | 150,000 | 91,176 | 104,853 | 600,000,000 | 436,619,986 | 502,112,984 |
| `generics_function_parameters_boxed` | 150,000 | 91,629 | 105,374 | 600,000,000 | 521,943,443 | 600,234,960 |
| `generics_function_parameters_forwarding` | 150,000 | 91,142 | 104,814 | 600,000,000 | 442,224,583 | 508,558,271 |
| `generics_function_parameters_saved_result` | 150,000 | 91,446 | 105,163 | 600,000,000 | 516,476,368 | 593,947,824 |
| `generics_function_parameters_second` | 150,000 | 90,579 | 104,166 | 600,000,000 | 512,837,865 | 589,763,545 |
| `generics_function_parameters_third` | 150,000 | 90,794 | 104,414 | 600,000,000 | 513,432,362 | 590,447,217 |
| `generics_identity` | 150,000 | 90,937 | 104,578 | 600,000,000 | 513,371,216 | 590,376,899 |
| `generics_lambda_capture_scalar` | 150,000 | 92,228 | 106,063 | 600,000,000 | 445,093,853 | 511,857,931 |
| `generics_lambda_managed` | 150,000 | 92,862 | 106,792 | 600,000,000 | 520,228,396 | 598,262,656 |
| `generics_lambda_noncapture` | 150,000 | 94,456 | 108,625 | 600,000,000 | 523,607,308 | 602,148,405 |
| `generics_managed_basic` | 150,000 | 92,036 | 105,842 | 600,000,000 | 524,838,173 | 603,563,899 |
| `generics_managed_both_variants` | 150,000 | 93,483 | 107,506 | 600,000,000 | 525,822,685 | 604,696,088 |
| `generics_managed_current` | 150,000 | 92,627 | 106,522 | 600,000,000 | 522,620,473 | 601,013,544 |
| `generics_managed_deep` | 180,000 | 123,414 | 141,927 | 600,000,000 | 604,658,277 | 695,357,019 |
| `generics_managed_nested` | 150,000 | 92,987 | 106,936 | 600,000,000 | 523,925,462 | 602,514,282 |
| `generics_managed_nested_saved` | 150,000 | 93,513 | 107,540 | 600,000,000 | 525,656,484 | 604,504,957 |
| `generics_managed_nullary_variant` | 150,000 | 92,686 | 106,589 | 600,000,000 | 522,618,466 | 601,011,236 |
| `generics_managed_option_result_callbacks` | 150,000 | 119,673 | 137,624 | 600,000,000 | 519,127,640 | 596,996,786 |
| `generics_managed_option_result_helpers` | 150,000 | 110,238 | 126,774 | 600,000,000 | 514,047,037 | 591,154,093 |
| `generics_managed_saved` | 150,000 | 92,483 | 106,356 | 600,000,000 | 524,080,303 | 602,692,349 |
| `generics_managed_shared` | 150,000 | 92,121 | 105,940 | 600,000,000 | 521,037,992 | 599,193,691 |
| `generics_managed_shared_box` | 150,000 | 92,938 | 106,879 | 600,000,000 | 523,871,684 | 602,452,437 |
| `generics_managed_unmanaged_variant` | 150,000 | 93,010 | 106,962 | 600,000,000 | 524,619,928 | 603,312,918 |
| `generics_managed_unused` | 150,000 | 91,298 | 104,993 | 600,000,000 | 519,274,250 | 597,165,388 |
| `generics_multiple_arguments_order` | 150,000 | 91,097 | 104,762 | 600,000,000 | 514,178,017 | 591,304,720 |
| `generics_multiple_arguments_wide` | 150,000 | 93,209 | 107,191 | 600,000,000 | 522,779,690 | 601,196,644 |
| `generics_named_identity` | 150,000 | 90,483 | 104,056 | 600,000,000 | 515,046,025 | 592,302,929 |
| `generics_named_managed` | 150,000 | 98,802 | 113,623 | 600,000,000 | 469,277,163 | 539,668,738 |
| `generics_named_ordered` | 150,000 | 95,755 | 110,119 | 600,000,000 | 528,916,909 | 608,254,446 |
| `generics_nested_current` | 150,000 | 92,887 | 106,821 | 600,000,000 | 524,337,461 | 602,988,081 |
| `generics_nested_deep` | 180,000 | 122,480 | 140,852 | 600,000,000 | 602,816,842 | 693,239,369 |
| `generics_nested_enum_off` | 150,000 | 92,773 | 106,689 | 600,000,000 | 522,482,290 | 600,854,634 |
| `generics_nested_enum_on` | 150,000 | 92,773 | 106,689 | 600,000,000 | 522,420,431 | 600,783,496 |
| `generics_nested_heterogeneous_left` | 150,000 | 93,814 | 107,887 | 600,000,000 | 539,192,910 | 620,071,847 |
| `generics_nested_heterogeneous_right` | 150,000 | 93,599 | 107,639 | 600,000,000 | 539,092,390 | 619,956,249 |
| `generics_nested_inferred` | 150,000 | 92,212 | 106,044 | 600,000,000 | 523,108,974 | 601,575,321 |
| `generics_nested_record_first` | 150,000 | 92,073 | 105,884 | 600,000,000 | 521,181,766 | 599,359,031 |
| `generics_nested_record_second` | 150,000 | 92,073 | 105,884 | 600,000,000 | 520,942,111 | 599,083,428 |
| `generics_nested_saved` | 150,000 | 92,724 | 106,633 | 600,000,000 | 523,113,658 | 601,580,707 |
| `generics_nested_written` | 150,000 | 93,149 | 107,122 | 600,000,000 | 446,372,005 | 513,327,806 |
| `generics_phantom` | 150,000 | 92,164 | 105,989 | 600,000,000 | 521,448,098 | 599,665,313 |
| `generics_tagged_int` | 150,000 | 91,113 | 104,780 | 600,000,000 | 518,010,628 | 595,712,223 |
| `generics_union_identity` | 150,000 | 92,626 | 106,520 | 600,000,000 | 444,027,053 | 510,631,111 |
| `generics_union_parameters_err` | 150,000 | 91,673 | 105,424 | 600,000,000 | 524,820,015 | 603,543,018 |
| `generics_union_parameters_ok` | 150,000 | 91,673 | 105,424 | 600,000,000 | 526,818,855 | 605,841,684 |
| `generics_union_parameters_phantom_keys` | 150,000 | 92,680 | 106,582 | 600,000,000 | 553,544,487 | 636,576,161 |
| `generics_union_parameters_third` | 150,000 | 91,643 | 105,390 | 600,000,000 | 534,009,156 | 614,110,530 |
| `generics_union_parameters_unwrap_or` | 150,000 | 92,517 | 106,395 | 600,000,000 | 527,438,889 | 606,554,723 |
| `imports_basic` | 150,000 | 90,282 | 103,825 | 600,000,000 | 513,056,543 | 590,015,025 |
| `imports_diamond` | 150,000 | 92,220 | 106,053 | 600,000,000 | 521,650,173 | 599,897,699 |
| `imports_direct_chain` | 110,000 | 169,547 | 194,980 | 300,000,000 | 807,930,689 | 929,120,293 |
| `imports_explicit_base` | 150,000 | 91,205 | 104,886 | 600,000,000 | 515,116,088 | 592,383,502 |
| `imports_flat` | 60,000 | 174,624 | 200,818 | 160,000,000 | 2,200,658,109 | 2,530,756,826 |
| `imports_forwarding` | 150,000 | 92,266 | 106,106 | 600,000,000 | 524,493,688 | 603,167,742 |
| `imports_generic_methods` | 150,000 | 94,028 | 108,133 | 600,000,000 | 528,757,253 | 608,070,841 |
| `imports_home` | 150,000 | 90,633 | 104,228 | 600,000,000 | 514,235,530 | 591,370,860 |
| `imports_managed` | 150,000 | 93,331 | 107,331 | 600,000,000 | 527,027,865 | 606,082,045 |
| `imports_method_modules` | 150,000 | 92,919 | 106,857 | 600,000,000 | 523,409,938 | 601,921,429 |
| `imports_prelude_helper` | 150,000 | 90,785 | 104,403 | 600,000,000 | 514,676,462 | 591,877,932 |
| `imports_receiver_types` | 150,000 | 92,122 | 105,941 | 600,000,000 | 522,510,462 | 600,887,032 |
| `lists_append_entries` | 51,000 | 96,378 | 110,835 | 101,000,000 | 472,583,537 | 543,471,068 |
| `lists_append_int` | 50,000 | 95,401 | 109,712 | 107,000,000 | 471,441,816 | 542,158,089 |
| `lists_append_points` | 54,000 | 97,987 | 112,686 | 107,000,000 | 476,493,121 | 547,967,090 |
| `lists_checked_set` | 73,000 | 109,740 | 126,201 | 200,000,000 | 507,809,950 | 583,981,443 |
| `lists_concat_entries` | 53,000 | 97,157 | 111,731 | 105,000,000 | 474,629,583 | 545,824,021 |
| `lists_concat_int` | 51,000 | 96,224 | 110,658 | 110,000,000 | 472,480,160 | 543,352,184 |
| `lists_concat_points` | 54,000 | 98,339 | 113,090 | 108,000,000 | 477,295,982 | 548,890,380 |
| `lists_contains_equatable` | 250,000 | 121,175 | 139,352 | 2,000,000,000 | 512,373,130 | 589,229,100 |
| `lists_contains_int` | 73,000 | 107,043 | 123,100 | 200,000,000 | 500,145,245 | 575,167,032 |
| `lists_empty_string` | 45,000 | 92,681 | 106,584 | 91,000,000 | 464,443,851 | 534,110,429 |
| `lists_entries` | 50,000 | 96,350 | 110,803 | 108,000,000 | 473,543,159 | 544,574,633 |
| `lists_literal_calls` | 48,000 | 94,455 | 108,624 | 95,000,000 | 467,764,622 | 537,929,316 |
| `lists_literal_empty` | 46,000 | 93,194 | 107,174 | 99,000,000 | 464,910,917 | 534,647,555 |
| `lists_literal_entries` | 49,000 | 95,435 | 109,751 | 98,000,000 | 470,524,189 | 541,102,818 |
| `lists_literal_int` | 46,000 | 93,636 | 107,682 | 98,000,000 | 465,943,809 | 535,835,381 |
| `lists_literal_nested` | 49,000 | 94,893 | 109,127 | 97,000,000 | 469,176,927 | 539,553,467 |
| `lists_literal_points` | 46,000 | 93,991 | 108,090 | 91,000,000 | 466,151,120 | 536,073,788 |
| `lists_mortal_entry` | 48,000 | 94,679 | 108,881 | 93,000,000 | 468,462,388 | 538,731,747 |
| `lists_nested` | 49,000 | 95,480 | 109,802 | 98,000,000 | 469,423,267 | 539,836,758 |
| `lists_set_entries` | 53,000 | 97,049 | 111,607 | 105,000,000 | 474,815,915 | 546,038,303 |
| `lists_set_int` | 53,000 | 96,895 | 111,430 | 113,000,000 | 474,194,757 | 545,323,971 |
| `lists_set_points` | 53,000 | 97,730 | 112,390 | 105,000,000 | 475,950,422 | 547,342,986 |
| `lists_supplement_imports_get_or` | 150,000 | 91,006 | 104,657 | 600,000,000 | 458,394,554 | 527,153,738 |
| `lists_supplement_imports_is_empty` | 150,000 | 91,211 | 104,893 | 600,000,000 | 458,656,112 | 527,454,529 |
| `lists_supplement_imports_last` | 150,000 | 91,660 | 105,409 | 600,000,000 | 459,533,234 | 528,463,220 |
| `lists_void` | 45,000 | 91,670 | 105,421 | 91,000,000 | 459,982,195 | 528,979,525 |
| `lists_zero` | 45,000 | 91,739 | 105,500 | 91,000,000 | 459,820,982 | 528,794,130 |
| `namespace_alias_call` | 48,000 | 91,027 | 104,682 | 96,000,000 | 519,975,701 | 597,972,057 |
| `namespace_alias_constructor` | 48,000 | 95,745 | 110,107 | 96,000,000 | 530,214,824 | 609,747,048 |
| `namespace_alias_type` | 48,000 | 94,735 | 108,946 | 96,000,000 | 530,464,092 | 610,033,706 |
| `namespace_combined_import` | 48,000 | 95,380 | 109,687 | 96,000,000 | 530,303,126 | 609,848,595 |
| `namespace_declared_function_imported_type_main` | 48,000 | 92,143 | 105,965 | 96,000,000 | 522,657,285 | 601,055,878 |
| `namespace_private_local` | 48,000 | 96,214 | 110,647 | 96,000,000 | 533,712,311 | 613,769,158 |
| `namespace_public_method` | 48,000 | 92,792 | 106,711 | 96,000,000 | 524,862,204 | 603,591,535 |
| `namespace_qualified_not_called` | 48,000 | 91,576 | 105,313 | 96,000,000 | 521,172,489 | 599,348,363 |
| `owned_prefix_borrowed_child_return` | 140,000 | 93,709 | 107,766 | 500,000,000 | 520,529,043 | 598,608,400 |
| `owned_prefix_borrowed_parameter` | 140,000 | 94,037 | 108,143 | 500,000,000 | 520,424,813 | 598,488,535 |
| `owned_prefix_child_escape` | 140,000 | 92,805 | 106,726 | 500,000,000 | 517,610,362 | 595,251,917 |
| `owned_prefix_default_arm` | 140,000 | 95,445 | 109,762 | 500,000,000 | 524,566,654 | 603,251,653 |
| `owned_prefix_list_escape` | 140,000 | 92,304 | 106,150 | 500,000,000 | 515,866,814 | 593,246,837 |
| `owned_prefix_mixed_int_scrutinee` | 140,000 | 94,429 | 108,594 | 500,000,000 | 531,045,676 | 610,702,528 |
| `owned_prefix_mixed_void_scrutinee` | 140,000 | 94,750 | 108,963 | 500,000,000 | 531,992,390 | 611,791,249 |
| `owned_prefix_owned_union_scrutinee` | 140,000 | 92,444 | 106,311 | 500,000,000 | 516,743,702 | 594,255,258 |
| `owned_prefix_projected_scrutinee` | 140,000 | 93,387 | 107,396 | 500,000,000 | 519,288,532 | 597,181,812 |
| `owned_prefix_projection_escape` | 140,000 | 93,134 | 107,105 | 500,000,000 | 518,405,104 | 596,165,870 |
| `owned_prefix_reassignment_aliases` | 140,000 | 94,715 | 108,923 | 500,000,000 | 523,295,491 | 601,789,815 |
| `owned_prefix_record` | 140,000 | 91,775 | 105,542 | 500,000,000 | 515,918,030 | 593,305,735 |
| `owned_prefix_record_arms` | 140,000 | 93,399 | 107,409 | 500,000,000 | 519,527,897 | 597,457,082 |
| `owned_prefix_root_escape` | 140,000 | 92,919 | 106,857 | 500,000,000 | 519,104,856 | 596,970,585 |
| `owned_prefix_selected_effects` | 140,000 | 94,440 | 108,606 | 500,000,000 | 522,157,468 | 600,481,089 |
| `owned_prefix_shared_child_roots` | 140,000 | 93,980 | 108,077 | 500,000,000 | 521,105,964 | 599,271,859 |
| `owned_prefix_union_escape` | 140,000 | 93,307 | 107,304 | 500,000,000 | 518,891,569 | 596,725,305 |
| `owned_prefix_unused_list` | 140,000 | 91,600 | 105,340 | 500,000,000 | 515,763,511 | 593,128,038 |
| `owned_prefix_unused_record` | 140,000 | 92,020 | 105,823 | 500,000,000 | 515,186,575 | 592,464,562 |
| `owned_prefix_unused_string` | 140,000 | 91,411 | 105,123 | 500,000,000 | 513,827,462 | 590,901,582 |
| `owned_prefix_unused_union` | 140,000 | 92,336 | 106,187 | 500,000,000 | 520,982,284 | 599,129,627 |
| `stored_callables_direct_list_copy` | 150,000 | 101,447 | 116,665 | 1,520,000,000 | 486,119,701 | 559,037,657 |
| `stored_callables_forwarded_capture` | 150,000 | 93,263 | 107,253 | 1,460,000,000 | 520,146,420 | 598,168,383 |
| `stored_callables_heterogeneous` | 150,000 | 96,262 | 110,702 | 1,480,000,000 | 527,281,345 | 606,373,547 |
| `stored_callables_pure_storage` | 150,000 | 92,862 | 106,792 | 1,470,000,000 | 518,428,872 | 596,193,203 |
| `stored_callables_receiver_order` | 150,000 | 92,613 | 106,505 | 1,600,000,000 | 519,489,850 | 597,413,328 |
| `syntax_continuation` | 42,000 | 90,821 | 104,445 | 85,000,000 | 513,453,126 | 590,471,095 |
| `syntax_grouping` | 42,000 | 90,703 | 104,309 | 85,000,000 | 513,152,626 | 590,125,520 |
| `syntax_import_block` | 42,000 | 90,326 | 103,875 | 85,000,000 | 511,863,547 | 588,643,080 |
| `syntax_next_line_value` | 42,000 | 89,629 | 103,074 | 85,000,000 | 511,039,519 | 587,695,447 |
| `syntax_pipe_string` | 42,000 | 91,037 | 104,693 | 85,000,000 | 514,745,562 | 591,957,397 |
| `syntax_standalone_annotated_lambda` | 42,000 | 89,996 | 103,496 | 85,000,000 | 510,892,393 | 587,526,252 |
| `trait_bounds_defaults` | 31,000 | 12,710 | 14,617 | 90,000,000 | 52,178,041 | 60,004,748 |
| `trait_bounds_dispatch` | 49,000 | 18,377 | 21,134 | 170,000,000 | 68,335,469 | 78,585,790 |
| `trait_bounds_finite` | 80,000 | 27,561 | 31,696 | 210,000,000 | 86,882,854 | 99,915,283 |
| `traits_concrete` | 7,500 | 3,717 | 4,275 | 55,000,000 | 28,695,676 | 33,000,028 |
| `traits_location` | 33,000 | 11,701 | 13,457 | 95,000,000 | 49,073,730 | 56,434,790 |
| `traits_managed` | 19,000 | 7,926 | 9,115 | 70,000,000 | 38,002,641 | 43,703,038 |
| `ufcs_calls` | 132,000 | 90,128 | 103,648 | 440,000,000 | 511,144,160 | 587,815,784 |
| `ufcs_chain` | 132,000 | 90,247 | 103,785 | 440,000,000 | 511,442,786 | 588,159,204 |
| `ufcs_chain_64` | 51,000 | 95,595 | 109,935 | 100,000,000 | 529,812,341 | 609,284,193 |
| `unsupported_opaque_import_main` | 40,000 | 90,083 | 103,596 | 140,000,000 | 512,576,580 | 589,463,067 |
| `unsupported_opaque_type` | 40,000 | 89,578 | 103,015 | 140,000,000 | 517,919,029 | 595,606,884 |

## Instruction ceilings reset after the dense path closure, 2026-11-09

**Why.** Commit `e8ea90ca6` replaced a hash `Dict` in `check/instantiation_paths.brp` with a dense table. Retired instructions fell by about 27% on every small compile (`lists_literal_entries`: 501.9M to 366.9M in the brief's probe) while allocations moved by only -67 per compile, so every instruction ceiling carried about 40% slack. The 598 instruction ceilings in `blorp/test/e2e/self_hosted_{calls,control,data,harness,strings,surface,system}.brp` are re-measured and set to the largest of three readings plus 15%, rounded up, except where that would raise a ceiling (below). Allocation ceilings are unchanged.

**Superseded columns.** The instruction columns of every earlier table in this file are superseded by the table below; the allocation columns stand.

- **Compiler:** built from `7b4e6d75e` (`make -C blorp test-compiler`, `-O0` test compiler), driver run with `make -C blorp test-e2e INSTRUCTION_CHECK=on`, three runs strictly serially.
- **Host and load:** Apple M4 MacBook Air, macOS (Darwin 25.6.0); other sessions ran their own gates at the same time. `uptime` before each run: run 1 `4.92 3.81 3.39`, run 2 `3.87 4.09 3.83`, run 3 `2.72 3.42 3.63`.
- **Readings:** each of the three runs gave a complete, uncut reading for all 598 programs (some lines began after other output on the same line, but each `MEASURE_COMPILE` line was whole). A program's measured value is its largest reading.
- **Spread:** the largest spread between the three readings of a program is 5.9% (`current_directory_basic`: 355.8M, 356.5M, 378.0M, which compiles its program for two working directories); next 3.0% (`derived_accepted_generic_head`) and 2.5% (`generics_nested_enum_on`). Every measured value is below its old ceiling (measured/old 55% to 92%).
- **Clusters:** the lower cluster of the first batch is gone: `recursion_generic` measures 339.5M against `recursion_binding` 338.4M (it was 436M against 515M), and `fs_native_close` measures 354.4M. The other five programs of the first batch's list now measure 361M to 378M, slightly above the plainest siblings and in line with their allocation counts.
- **Kept ceilings:** the rule would have raised 12 ceilings, by 0.4% to 5.6%, so they keep their old value (marked "kept" below), which stays at least 8% above every reading: `derived_accepted_generic_head`, `derived_accepted_nested_generic_head`, `derived_callables`, `derived_generic`, `derived_semantics`, `derived_values`, `trait_bounds_defaults`, `trait_bounds_dispatch`, `trait_bounds_finite`, `traits_concrete`, `traits_location`, `traits_managed`. These small programs compile against their own library roots, so the closure fix barely touches them, and their cost has drifted up since they were measured on 2026-11-06.
- **Special cases:** no shared constants. `imports_direct_chain` and `imports_flat` (the module-chain cost tests) take a literal ceiling in `run_generated` like any program and are reset by the same rule. `string_literal_*` programs are named by a helper; their ceilings are reset by program name.
- **Measurement change:** the driver was temporarily changed to print each compile's allocations and instructions instead of failing (`measure.patch`) and reverted before the commit. Raw samples are in the ignored directory `/Users/keithphilpott/CLionProjects/blorp/build/blorp-e2e-ceilings-2026-11-09/`:

| File | sha256 |
| --- | --- |
| `measure_run1.log` | `9ae0e4ed726e9cccc59a34db65bbd1739892b4c6c7a7a7bdd55d980421e86fc3` |
| `measure_run2.log` | `b8f8b2a34fb903a40aa06ad7358b689231fa9c58cf4a159f013354749909a5bc` |
| `measure_run3.log` | `f1e479caee63982f936b48039dec9e870f2fa898ccc7b9b4d60ca4a4b9dfdfc0` |
| `uptime_run1.txt` | `a3e98906f6d00b1b84aa1597ace26859f25cd9516e143810e39bb3512f0b2893` |
| `uptime_run2.txt` | `9b4296bb5b24172cfb36a0e793ec44b420126b416f9a73ab9e94758a7e64618d` |
| `uptime_run3.txt` | `2bed119bf31158a652d423092981e3bb448bcf901392f0cf1f74860f396449fd` |
| `measure.patch` | `2c27bccf53e04775a22df6ae493f347b47344f48eff1d391eb3bc1b09ab70242` |
| `rewrite.py` | `9f912a942765373ce2de3a371dd438af2a257a7de21b12fe792aff34c3c917ac` |
| `ceilings.tsv` | `76102bda58c641939606427f4f256bc70cf2f7d8379a5e1ebcba5ff5c413dc25` |
| `spread.tsv` | `b09bf94cff85ef644e38f3d5ebd62bd2cb75e45bd48dd0bf9bc973affe17a40d` |

| Program | Old instruction ceiling | Measured | New instruction ceiling |
| --- | --- | --- | --- |
| `append_reuse` | 593,188,164 | 408,828,315 | 470,152,563 |
| `argument_input` | 544,689,368 | 366,738,683 | 421,749,486 |
| `argument_input_access_stress` | 603,985,158 | 415,790,640 | 478,159,236 |
| `argument_input_escaped_string` | 547,076,998 | 366,550,258 | 421,532,797 |
| `arithmetic_checked` | 663,516,407 | 414,096,859 | 476,211,388 |
| `arithmetic_long_sum` | 4,325,835,159 | 3,621,194,931 | 4,164,374,171 |
| `arithmetic_nesting` | 818,669,257 | 559,541,646 | 643,472,893 |
| `arithmetic_operators` | 685,793,030 | 434,810,042 | 500,031,549 |
| `arithmetic_order` | 613,542,729 | 369,882,149 | 425,364,472 |
| `arithmetic_traits` | 566,145,065 | 408,180,167 | 469,407,193 |
| `bindings_basic` | 589,178,235 | 337,217,761 | 387,800,426 |
| `bindings_capture_shadow` | 590,848,475 | 338,610,304 | 389,401,850 |
| `bindings_ordered_calls` | 591,064,053 | 338,760,001 | 389,574,002 |
| `bindings_parameter_shadow` | 588,503,390 | 336,703,379 | 387,208,886 |
| `bindings_pure_mutation` | 589,342,766 | 338,092,234 | 388,806,070 |
| `bindings_self_assignment` | 588,337,235 | 335,948,225 | 386,340,459 |
| `bindings_union_current` | 590,992,944 | 338,940,864 | 389,781,994 |
| `bindings_union_original` | 592,064,091 | 339,974,876 | 390,971,108 |
| `bindings_unused_initializer` | 588,939,683 | 336,426,630 | 386,890,625 |
| `bindings_values` | 589,321,140 | 337,065,017 | 387,624,770 |
| `branch_accumulator` | 613,170,765 | 425,040,601 | 488,796,692 |
| `calculator_addition` | 553,796,936 | 372,348,044 | 428,200,251 |
| `calculator_float` | 593,137,040 | 407,919,079 | 469,106,941 |
| `calculator_float_literals` | 608,848,591 | 366,935,050 | 421,975,308 |
| `calculator_float_stress` | 687,096,572 | 434,863,880 | 500,093,462 |
| `calculator_integer` | 591,749,417 | 406,816,423 | 467,838,887 |
| `call_one` | 587,565,155 | 335,589,671 | 385,928,122 |
| `constant_aggregate` | 539,953,680 | 361,453,681 | 415,671,734 |
| `constant_aliases` | 592,466,575 | 351,886,410 | 404,669,372 |
| `constant_callable` | 594,450,872 | 341,911,559 | 393,198,293 |
| `constant_float` | 591,181,872 | 351,174,906 | 403,851,142 |
| `constant_imported` | 590,565,858 | 337,697,388 | 388,351,997 |
| `constant_integer` | 587,714,532 | 334,692,857 | 384,896,786 |
| `constant_managed_generic` | 596,858,914 | 355,617,478 | 408,960,100 |
| `constant_nested` | 654,466,377 | 407,211,533 | 468,293,263 |
| `constant_pipe` | 589,943,681 | 350,392,826 | 402,951,750 |
| `constant_seven` | 587,815,799 | 336,122,228 | 386,540,563 |
| `constant_string` | 590,042,043 | 350,508,378 | 403,084,635 |
| `conversion_float` | 542,581,067 | 365,159,926 | 419,933,915 |
| `conversion_integer` | 542,757,530 | 363,705,212 | 418,260,994 |
| `conversion_nul_bytes` | 608,394,961 | 364,450,194 | 419,117,724 |
| `conversion_projection_stress` | 652,043,394 | 403,759,193 | 464,323,072 |
| `current_directory_basic` | 597,739,680 | 378,016,341 | 434,718,793 |
| `current_directory_ownership` | 596,308,264 | 355,603,116 | 408,943,584 |
| `declaration_bounds` | 560,060,410 | 391,329,592 | 450,029,031 |
| `derived_accepted_generic_head` | 34,132,029 | 31,331,540 | 34,132,029 (kept) |
| `derived_accepted_nested_generic_head` | 34,410,021 | 31,108,988 | 34,410,021 (kept) |
| `derived_callables` | 86,073,025 | 76,277,158 | 86,073,025 (kept) |
| `derived_generic` | 162,592,526 | 142,000,406 | 162,592,526 (kept) |
| `derived_recursive` | 142,740,913 | 123,934,922 | 142,525,161 |
| `derived_semantics` | 92,213,518 | 80,939,474 | 92,213,518 (kept) |
| `derived_values` | 125,963,389 | 111,100,598 | 125,963,389 (kept) |
| `dict_absent_sequential` | 623,519,981 | 412,487,017 | 474,360,070 |
| `dict_call_chain_cost` | 619,605,399 | 405,781,111 | 466,648,278 |
| `dict_case_insensitive_keys` | 737,383,772 | 516,496,563 | 593,971,048 |
| `dict_churn_large` | 651,384,368 | 436,419,361 | 501,882,266 |
| `dict_churn_small` | 652,120,053 | 438,878,302 | 504,710,048 |
| `dict_compaction_boundary` | 630,536,732 | 419,837,351 | 482,812,954 |
| `dict_int_keys` | 726,245,354 | 499,022,049 | 573,875,357 |
| `dict_linear_build` | 626,323,509 | 413,157,233 | 475,130,818 |
| `dict_literal_cost` | 654,515,927 | 405,523,599 | 466,352,139 |
| `dict_literal_order` | 614,182,370 | 424,668,301 | 488,368,547 |
| `dict_literals` | 891,517,899 | 644,536,336 | 741,216,787 |
| `dict_record_keys` | 760,027,525 | 540,581,044 | 621,668,201 |
| `dict_string_keys` | 732,393,351 | 513,502,452 | 590,527,820 |
| `discard` | 617,223,284 | 374,140,623 | 430,261,717 |
| `effects_alias` | 591,535,389 | 352,767,148 | 405,682,221 |
| `effects_bytes` | 590,324,312 | 354,176,484 | 407,302,957 |
| `effects_hello` | 591,076,043 | 358,475,705 | 412,247,061 |
| `effects_nested` | 592,048,301 | 355,411,444 | 408,723,161 |
| `effects_order` | 593,621,578 | 356,647,774 | 410,144,941 |
| `effects_selected_arm` | 594,176,367 | 355,806,745 | 409,177,757 |
| `effects_sequence` | 624,942,752 | 381,755,829 | 439,019,204 |
| `effects_unit` | 602,173,334 | 345,522,344 | 397,350,696 |
| `equality_dispatch` | 601,360,152 | 347,120,134 | 399,188,155 |
| `equality_nesting` | 686,460,631 | 419,310,976 | 482,207,623 |
| `equality_operators` | 694,659,005 | 471,170,683 | 541,846,286 |
| `equality_order` | 598,649,557 | 357,996,930 | 411,696,470 |
| `every_in_place_helper` | 539,578,988 | 359,211,133 | 413,092,803 |
| `fixed_record` | 619,032,245 | 361,720,264 | 415,978,304 |
| `fixed_union` | 616,863,945 | 358,100,487 | 411,815,561 |
| `fs_directories` | 1,010,595,763 | 817,079,944 | 939,641,936 |
| `fs_lines` | 1,208,948,425 | 900,603,295 | 1,035,693,790 |
| `fs_native_both` | 601,163,985 | 359,161,954 | 413,036,248 |
| `fs_native_close` | 595,380,299 | 354,421,993 | 407,585,292 |
| `fs_native_create_directories` | 595,238,716 | 354,166,275 | 407,291,217 |
| `fs_native_create_directory` | 595,165,447 | 354,266,757 | 407,406,771 |
| `fs_native_create_temporary_directory` | 596,265,773 | 354,883,150 | 408,115,623 |
| `fs_native_directories` | 596,632,500 | 412,396,365 | 474,255,820 |
| `fs_native_entry_kind` | 595,577,949 | 355,011,929 | 408,263,719 |
| `fs_native_lines` | 581,594,753 | 396,834,727 | 456,359,937 |
| `fs_native_list_directory` | 596,085,336 | 354,745,021 | 407,956,775 |
| `fs_native_next_lines` | 597,931,904 | 355,368,776 | 408,674,093 |
| `fs_native_open_read` | 538,641,445 | 359,597,985 | 413,537,683 |
| `fs_native_read_text` | 595,665,210 | 354,645,732 | 407,842,592 |
| `fs_native_remove_directory` | 595,100,476 | 354,415,679 | 407,578,031 |
| `fs_native_remove_directory_tree` | 595,150,122 | 356,142,458 | 409,563,827 |
| `fs_native_remove_file` | 595,251,550 | 354,317,058 | 407,464,617 |
| `fs_native_rename` | 595,185,279 | 356,770,674 | 410,286,276 |
| `fs_native_write_text` | 595,125,906 | 354,513,777 | 407,690,844 |
| `fs_read` | 794,591,798 | 631,815,107 | 726,587,374 |
| `fs_write` | 770,280,418 | 613,816,054 | 705,888,463 |
| `generic_record_box_float` | 601,880,460 | 356,610,659 | 410,102,258 |
| `generic_record_box_int` | 596,259,052 | 341,619,505 | 392,862,431 |
| `generic_record_box_list` | 609,611,713 | 364,305,751 | 418,951,614 |
| `generic_record_box_string` | 601,345,198 | 357,618,881 | 411,261,714 |
| `generic_record_box_void` | 601,041,365 | 356,993,282 | 410,542,275 |
| `generic_record_managed_alias_reassignment` | 606,340,415 | 360,057,806 | 414,066,477 |
| `generic_record_nested_managed_escape` | 605,789,297 | 358,652,195 | 412,450,025 |
| `generic_record_nested_projection` | 601,771,651 | 359,222,641 | 413,106,038 |
| `generic_record_nested_string_list` | 619,098,101 | 367,658,960 | 422,807,804 |
| `generic_record_partial_direct_int` | 598,383,125 | 340,069,548 | 391,079,981 |
| `generic_record_partial_direct_string` | 601,043,938 | 355,787,152 | 409,155,225 |
| `generic_record_partial_nested` | 604,219,945 | 345,088,029 | 396,851,234 |
| `generic_record_partial_pair_order` | 608,832,312 | 362,857,945 | 417,286,637 |
| `generic_record_partial_ufcs` | 597,839,265 | 339,912,542 | 390,899,424 |
| `generic_record_partial_union_child` | 604,286,145 | 345,108,823 | 396,875,147 |
| `generic_record_phantom_arguments` | 608,645,733 | 360,810,250 | 414,931,788 |
| `generic_record_result_context` | 597,156,704 | 340,387,750 | 391,445,913 |
| `generic_record_rigid_owner_positions` | 604,967,547 | 345,968,734 | 397,864,045 |
| `generic_record_same_reader_twice` | 602,974,207 | 359,133,064 | 413,003,024 |
| `generic_record_swapped_pair` | 614,395,542 | 366,733,274 | 421,743,266 |
| `generic_record_union_field` | 531,541,063 | 363,660,085 | 418,209,098 |
| `generic_record_unused_generic_and_passthrough` | 597,694,433 | 343,129,179 | 394,598,556 |
| `generic_record_unused_list_int` | 596,553,476 | 339,342,089 | 390,243,403 |
| `generic_record_void_argument` | 599,668,976 | 342,841,707 | 394,267,964 |
| `generics_annotations_contextual_list` | 591,448,033 | 339,115,242 | 389,982,529 |
| `generics_annotations_identity` | 587,488,147 | 335,275,704 | 385,567,060 |
| `generics_arguments` | 588,790,033 | 336,183,945 | 386,611,537 |
| `generics_arguments_box` | 598,247,085 | 342,106,974 | 393,423,021 |
| `generics_arguments_first_string` | 591,962,993 | 338,517,650 | 389,295,298 |
| `generics_arguments_later` | 589,230,717 | 336,090,891 | 386,504,525 |
| `generics_arguments_repeated_string` | 591,165,064 | 339,724,447 | 390,683,115 |
| `generics_arguments_second_string` | 592,080,596 | 338,727,203 | 389,536,284 |
| `generics_bindings` | 590,959,689 | 339,096,006 | 389,960,407 |
| `generics_box` | 597,690,757 | 341,141,926 | 392,313,215 |
| `generics_contextual_expected_result` | 600,638,326 | 341,151,911 | 392,324,698 |
| `generics_contextual_nested_rigid` | 521,746,239 | 347,222,523 | 399,305,902 |
| `generics_contextual_nominal_siblings` | 620,952,852 | 374,610,477 | 430,802,049 |
| `generics_contextual_partial_constructor` | 599,608,834 | 340,859,452 | 391,988,370 |
| `generics_contextual_partial_ufcs` | 601,644,051 | 340,391,345 | 391,450,047 |
| `generics_contextual_repeated_hint` | 617,119,239 | 346,468,520 | 398,438,798 |
| `generics_contextual_sibling` | 601,900,984 | 342,377,102 | 393,733,668 |
| `generics_forward` | 499,882,892 | 340,683,232 | 391,785,717 |
| `generics_forward_string` | 502,112,984 | 341,894,324 | 393,178,473 |
| `generics_function_parameters_boxed` | 600,234,960 | 342,986,044 | 394,433,951 |
| `generics_function_parameters_forwarding` | 508,558,271 | 345,097,730 | 396,862,390 |
| `generics_function_parameters_saved_result` | 593,947,824 | 340,835,896 | 391,961,281 |
| `generics_function_parameters_second` | 589,763,545 | 338,132,979 | 388,852,926 |
| `generics_function_parameters_third` | 590,447,217 | 339,238,284 | 390,124,027 |
| `generics_identity` | 590,376,899 | 339,527,732 | 390,456,892 |
| `generics_lambda_capture_scalar` | 511,857,931 | 347,217,147 | 399,299,720 |
| `generics_lambda_managed` | 598,262,656 | 357,528,679 | 411,157,981 |
| `generics_lambda_noncapture` | 602,148,405 | 346,503,148 | 398,478,621 |
| `generics_managed_basic` | 603,563,899 | 342,990,956 | 394,439,600 |
| `generics_managed_both_variants` | 604,696,088 | 347,028,688 | 399,082,992 |
| `generics_managed_current` | 601,013,544 | 344,207,312 | 395,838,409 |
| `generics_managed_deep` | 695,357,019 | 427,786,544 | 491,954,526 |
| `generics_managed_nested` | 602,514,282 | 345,096,222 | 396,860,656 |
| `generics_managed_nested_saved` | 604,504,957 | 347,227,528 | 399,311,658 |
| `generics_managed_nullary_variant` | 601,011,236 | 344,713,457 | 396,420,476 |
| `generics_managed_option_result_callbacks` | 596,996,786 | 430,018,836 | 494,521,662 |
| `generics_managed_option_result_helpers` | 591,154,093 | 401,784,682 | 462,052,385 |
| `generics_managed_saved` | 602,692,349 | 344,125,338 | 395,744,139 |
| `generics_managed_shared` | 599,193,691 | 342,949,383 | 394,391,791 |
| `generics_managed_shared_box` | 602,452,437 | 347,224,750 | 399,308,463 |
| `generics_managed_unmanaged_variant` | 603,312,918 | 345,596,048 | 397,435,456 |
| `generics_managed_unused` | 597,165,388 | 341,566,093 | 392,801,007 |
| `generics_multiple_arguments_order` | 591,304,720 | 338,913,808 | 389,750,880 |
| `generics_multiple_arguments_wide` | 601,196,644 | 348,715,816 | 401,023,189 |
| `generics_named_identity` | 592,302,929 | 337,123,482 | 387,692,005 |
| `generics_named_managed` | 539,668,738 | 376,194,226 | 432,623,360 |
| `generics_named_ordered` | 608,254,446 | 366,537,084 | 421,517,647 |
| `generics_nested_current` | 602,988,081 | 344,467,854 | 396,138,033 |
| `generics_nested_deep` | 693,239,369 | 429,655,425 | 494,103,739 |
| `generics_nested_enum_off` | 600,854,634 | 344,381,578 | 396,038,815 |
| `generics_nested_enum_on` | 600,783,496 | 353,081,525 | 406,043,754 |
| `generics_nested_heterogeneous_left` | 620,071,847 | 352,372,140 | 405,227,961 |
| `generics_nested_heterogeneous_right` | 619,956,249 | 351,892,798 | 404,676,718 |
| `generics_nested_inferred` | 601,575,321 | 342,838,273 | 394,264,014 |
| `generics_nested_record_first` | 599,359,031 | 342,571,788 | 393,957,557 |
| `generics_nested_record_second` | 599,083,428 | 343,043,596 | 394,500,136 |
| `generics_nested_saved` | 601,580,707 | 344,552,670 | 396,235,571 |
| `generics_nested_written` | 513,327,806 | 348,089,699 | 400,303,154 |
| `generics_phantom` | 599,665,313 | 344,015,197 | 395,617,477 |
| `generics_tagged_int` | 595,712,223 | 341,289,067 | 392,482,428 |
| `generics_union_identity` | 510,631,111 | 348,260,932 | 400,500,072 |
| `generics_union_parameters_err` | 603,543,018 | 352,465,542 | 405,335,374 |
| `generics_union_parameters_ok` | 605,841,684 | 347,170,511 | 399,246,088 |
| `generics_union_parameters_phantom_keys` | 636,576,161 | 351,188,641 | 403,866,938 |
| `generics_union_parameters_third` | 614,110,530 | 347,250,503 | 399,338,079 |
| `generics_union_parameters_unwrap_or` | 606,554,723 | 349,770,226 | 402,235,760 |
| `grouped_suites` | 640,748,346 | 394,566,488 | 453,751,462 |
| `import_all` | 532,256,201 | 340,610,590 | 391,702,179 |
| `import_drop` | 535,960,814 | 343,952,440 | 395,545,306 |
| `import_find` | 531,558,389 | 341,068,219 | 392,228,452 |
| `import_remove` | 538,091,362 | 346,222,357 | 398,155,711 |
| `import_reverse` | 532,893,921 | 341,565,093 | 392,799,857 |
| `import_take` | 536,301,837 | 343,306,330 | 394,802,280 |
| `imports_basic` | 590,015,025 | 339,936,678 | 390,927,180 |
| `imports_diamond` | 599,897,699 | 347,283,046 | 399,375,503 |
| `imports_direct_chain` | 929,120,293 | 639,663,432 | 735,612,947 |
| `imports_explicit_base` | 592,383,502 | 338,538,645 | 389,319,442 |
| `imports_flat` | 2,530,756,826 | 1,745,754,438 | 2,007,617,604 |
| `imports_forwarding` | 603,167,742 | 347,028,969 | 399,083,315 |
| `imports_generic_methods` | 608,070,841 | 351,751,270 | 404,513,961 |
| `imports_home` | 591,370,860 | 340,982,244 | 392,129,581 |
| `imports_managed` | 606,082,045 | 349,043,632 | 401,400,177 |
| `imports_method_modules` | 601,921,429 | 348,411,142 | 400,672,814 |
| `imports_prelude_helper` | 591,877,932 | 339,029,227 | 389,883,612 |
| `imports_receiver_types` | 600,887,032 | 344,861,283 | 396,590,476 |
| `int_add` | 588,702,492 | 335,590,861 | 385,929,491 |
| `int_cancel` | 589,439,228 | 335,507,609 | 385,833,751 |
| `int_comparisons` | 560,158,905 | 377,597,450 | 434,237,068 |
| `int_equals` | 609,793,546 | 366,304,291 | 421,249,935 |
| `int_literal_patterns` | 671,634,888 | 397,358,395 | 456,962,155 |
| `int_negative` | 589,295,391 | 336,454,319 | 386,922,467 |
| `int_nested` | 593,073,168 | 336,630,668 | 387,125,269 |
| `int_ufcs` | 588,287,359 | 335,716,058 | 386,073,467 |
| `int_wrap_max` | 589,561,185 | 336,461,535 | 386,930,766 |
| `int_wrap_min` | 589,074,515 | 336,377,972 | 386,834,668 |
| `int_wrap_twice` | 589,138,118 | 336,376,747 | 386,833,260 |
| `integer_maximum` | 587,843,988 | 335,100,520 | 385,365,598 |
| `integer_minimum` | 587,545,149 | 335,179,258 | 385,456,147 |
| `interpolation_eight` | 591,931,517 | 354,129,062 | 407,248,422 |
| `interpolation_one_hundred_twenty_eight` | 631,789,229 | 387,076,211 | 445,137,643 |
| `interpolation_ordered` | 609,467,280 | 367,131,688 | 422,201,442 |
| `interpolation_thirty_two` | 600,168,467 | 360,320,592 | 414,368,681 |
| `join_bound_int` | 597,779,911 | 344,290,149 | 395,933,672 |
| `join_bound_managed` | 596,063,782 | 356,062,789 | 409,472,208 |
| `join_carried_duplicate` | 598,595,487 | 359,196,938 | 413,076,479 |
| `join_carried_existing` | 590,673,603 | 337,775,182 | 388,441,460 |
| `join_carried_int` | 596,494,454 | 355,368,022 | 408,673,226 |
| `join_carried_nested` | 622,903,705 | 381,160,813 | 438,334,935 |
| `join_carried_order` | 598,726,806 | 360,027,889 | 414,032,073 |
| `join_carried_projected` | 600,474,478 | 360,591,346 | 414,680,048 |
| `join_carried_rhs` | 596,630,927 | 355,762,430 | 409,126,795 |
| `join_carried_string_alias` | 599,856,650 | 358,127,457 | 411,846,576 |
| `join_carried_swap` | 599,003,090 | 359,655,473 | 413,603,794 |
| `join_carried_unused` | 595,386,653 | 355,422,844 | 408,736,271 |
| `join_deep` | 624,139,366 | 370,900,081 | 426,535,094 |
| `join_nested` | 603,041,351 | 349,052,676 | 401,410,578 |
| `join_statement` | 595,898,091 | 356,078,605 | 409,490,396 |
| `join_tail_arm` | 608,089,339 | 357,754,186 | 411,417,314 |
| `join_void_tail` | 596,946,438 | 357,058,982 | 410,617,830 |
| `lexical_trivia` | 587,099,274 | 335,132,604 | 385,402,495 |
| `library_linear` | 599,060,862 | 412,629,691 | 474,524,145 |
| `library_loops` | 663,613,171 | 467,779,252 | 537,946,140 |
| `list_callbacks` | 615,085,967 | 450,370,804 | 517,926,425 |
| `list_join` | 560,705,082 | 378,876,463 | 435,707,933 |
| `list_queries` | 587,171,610 | 402,073,369 | 462,384,375 |
| `lists_append_entries` | 543,471,068 | 366,815,377 | 421,837,684 |
| `lists_append_int` | 542,158,089 | 362,865,729 | 417,295,589 |
| `lists_append_points` | 547,967,090 | 369,493,385 | 424,917,393 |
| `lists_checked_set` | 583,981,443 | 399,068,164 | 458,928,389 |
| `lists_concat_entries` | 545,824,021 | 367,528,613 | 422,657,905 |
| `lists_concat_int` | 543,352,184 | 365,858,284 | 420,737,027 |
| `lists_concat_points` | 548,890,380 | 370,984,954 | 426,632,698 |
| `lists_contains_equatable` | 589,229,100 | 434,239,195 | 499,375,075 |
| `lists_contains_int` | 575,167,032 | 392,469,685 | 451,340,138 |
| `lists_empty_string` | 534,110,429 | 355,436,480 | 408,751,952 |
| `lists_entries` | 544,574,633 | 364,378,076 | 419,034,788 |
| `lists_literal_calls` | 537,929,316 | 360,723,071 | 414,831,532 |
| `lists_literal_empty` | 534,647,555 | 358,027,166 | 411,731,241 |
| `lists_literal_entries` | 541,102,818 | 363,883,052 | 418,465,510 |
| `lists_literal_int` | 535,835,381 | 358,453,261 | 412,221,251 |
| `lists_literal_nested` | 539,553,467 | 361,458,614 | 415,677,407 |
| `lists_literal_points` | 536,073,788 | 358,881,409 | 412,713,621 |
| `lists_mortal_entry` | 538,731,747 | 360,864,073 | 414,993,684 |
| `lists_nested` | 539,836,758 | 362,165,170 | 416,489,946 |
| `lists_set_entries` | 546,038,303 | 367,687,519 | 422,840,647 |
| `lists_set_int` | 545,323,971 | 367,224,853 | 422,308,581 |
| `lists_set_points` | 547,342,986 | 369,067,808 | 424,427,980 |
| `lists_supplement_imports_get_or` | 527,153,738 | 338,355,385 | 389,108,693 |
| `lists_supplement_imports_is_empty` | 527,454,529 | 338,519,086 | 389,296,949 |
| `lists_supplement_imports_last` | 528,463,220 | 339,466,961 | 390,387,006 |
| `lists_void` | 528,979,525 | 339,644,525 | 390,591,204 |
| `lists_zero` | 528,794,130 | 339,938,511 | 390,929,288 |
| `literal` | 536,327,696 | 357,810,887 | 411,482,521 |
| `literal_append` | 597,060,025 | 353,415,332 | 406,427,632 |
| `literal_indirect` | 547,711,178 | 366,548,035 | 421,530,241 |
| `literal_loop` | 597,027,808 | 354,108,290 | 407,224,534 |
| `lookup_errors` | 6,143,805,734 | 5,332,722,992 | 6,132,631,441 |
| `loop_entry_accumulator` | 593,893,033 | 407,873,502 | 469,054,528 |
| `main_implicit_void_arguments` | 533,864,028 | 356,560,059 | 410,044,068 |
| `main_implicit_void_nullary` | 590,956,761 | 351,660,826 | 404,409,950 |
| `main_int_arguments` | 524,785,085 | 336,381,858 | 386,839,137 |
| `main_int_nullary` | 586,837,864 | 334,851,443 | 385,079,160 |
| `main_pure_implicit_void_arguments` | 586,341,687 | 334,814,713 | 385,036,920 |
| `main_pure_int_arguments` | 525,270,977 | 336,125,563 | 386,544,398 |
| `main_pure_int_nullary` | 587,058,584 | 335,092,499 | 385,356,374 |
| `main_pure_void_nullary` | 501,284,559 | 340,674,320 | 391,775,468 |
| `main_void_arguments` | 531,347,354 | 353,087,118 | 406,050,186 |
| `main_void_nullary` | 591,027,584 | 350,831,459 | 403,456,178 |
| `match_binding_current` | 593,358,069 | 341,063,505 | 392,223,031 |
| `match_binding_empty` | 593,567,133 | 340,302,773 | 391,348,189 |
| `match_binding_original` | 592,422,724 | 341,196,825 | 392,376,349 |
| `match_binding_outer` | 593,035,396 | 339,875,869 | 390,857,250 |
| `match_constructor_argument` | 592,129,586 | 340,074,039 | 391,085,145 |
| `match_constructor_spine` | 606,742,593 | 360,633,634 | 414,728,680 |
| `match_empty` | 590,070,424 | 338,001,920 | 388,702,208 |
| `match_many_arms` | 1,394,537,317 | 1,042,290,045 | 1,198,633,552 |
| `match_qualified_flat` | 612,470,027 | 369,928,630 | 425,417,925 |
| `match_scalar_capture` | 590,591,787 | 338,527,842 | 389,307,019 |
| `match_selected_arm` | 592,122,952 | 340,925,162 | 392,063,937 |
| `match_shadow` | 590,720,868 | 338,698,004 | 389,502,705 |
| `match_sibling_empty` | 592,132,930 | 342,175,055 | 393,501,314 |
| `match_sibling_payload` | 590,252,379 | 337,857,905 | 388,536,591 |
| `match_value` | 590,480,987 | 337,598,566 | 388,238,351 |
| `match_values` | 592,271,783 | 339,927,483 | 390,916,606 |
| `match_whole_empty` | 591,415,915 | 338,857,163 | 389,685,738 |
| `match_wildcard` | 589,369,324 | 336,759,767 | 387,273,733 |
| `mortal_string_alias` | 589,413,331 | 336,141,508 | 386,562,735 |
| `mortal_string_basic` | 588,796,893 | 335,583,037 | 385,920,493 |
| `mortal_string_identity` | 590,132,419 | 336,904,287 | 387,439,931 |
| `mortal_string_maximum` | 588,466,274 | 335,603,083 | 385,943,546 |
| `mortal_string_minimum` | 588,536,808 | 335,280,442 | 385,572,509 |
| `mortal_string_unused` | 588,186,112 | 334,917,963 | 385,155,658 |
| `namespace_alias_call` | 597,972,057 | 352,085,858 | 404,898,737 |
| `namespace_alias_constructor` | 609,747,048 | 365,868,754 | 420,749,068 |
| `namespace_alias_type` | 610,033,706 | 362,830,501 | 417,255,077 |
| `namespace_combined_import` | 609,848,595 | 364,800,257 | 419,520,296 |
| `namespace_declared_function_imported_type_main` | 601,055,878 | 358,942,805 | 412,784,226 |
| `namespace_private_local` | 613,769,158 | 370,301,671 | 425,846,922 |
| `namespace_public_method` | 603,591,535 | 359,513,514 | 413,440,542 |
| `namespace_qualified_not_called` | 599,348,363 | 341,731,749 | 392,991,512 |
| `nested_calls` | 588,749,221 | 335,833,381 | 386,208,389 |
| `nested_order` | 588,990,699 | 336,406,556 | 386,867,540 |
| `nonzero` | 588,869,119 | 335,134,914 | 385,405,152 |
| `number_tuples` | 595,916,301 | 342,636,632 | 394,032,127 |
| `opaque_empty` | 516,030,714 | 342,943,567 | 394,385,103 |
| `opaque_inline` | 610,599,169 | 366,746,477 | 421,758,449 |
| `opaque_int` | 593,482,434 | 340,971,811 | 392,117,583 |
| `opaque_keys` | 614,746,641 | 369,060,246 | 424,419,283 |
| `opaque_list` | 547,343,422 | 366,718,663 | 421,726,463 |
| `opaque_managed` | 632,263,296 | 383,402,286 | 440,912,629 |
| `opaque_nesting` | 535,772,010 | 365,056,579 | 419,815,066 |
| `opaque_phantom` | 597,646,413 | 342,870,008 | 394,300,510 |
| `opaque_recursive` | 552,183,658 | 372,533,974 | 428,414,071 |
| `opaque_scalar` | 595,695,220 | 355,905,374 | 409,291,181 |
| `opaque_trait` | 547,497,404 | 386,758,795 | 444,772,615 |
| `opaque_wrap` | 518,573,409 | 347,926,581 | 400,115,569 |
| `option_byte_at` | 590,564,329 | 338,104,091 | 388,819,705 |
| `option_byte_at_zero` | 589,038,975 | 336,719,752 | 387,227,715 |
| `option_from_codepoint_nul` | 592,634,629 | 352,735,658 | 405,646,007 |
| `option_from_codepoint_ownership` | 592,776,810 | 338,911,875 | 389,748,657 |
| `option_imported` | 589,956,960 | 337,963,613 | 388,658,155 |
| `option_parse_int` | 590,505,565 | 338,114,017 | 388,831,120 |
| `option_repeated` | 638,470,656 | 380,451,283 | 437,518,976 |
| `orderable` | 626,235,443 | 382,420,104 | 439,783,120 |
| `ordering_nesting` | 758,790,130 | 487,712,771 | 560,869,687 |
| `ordering_operators` | 681,803,779 | 427,369,323 | 491,474,722 |
| `ordering_order` | 606,739,024 | 363,948,821 | 418,541,145 |
| `owned_loop_accumulator` | 548,209,737 | 368,259,513 | 423,498,440 |
| `owned_prefix_borrowed_child_return` | 598,608,400 | 358,302,063 | 412,047,373 |
| `owned_prefix_borrowed_parameter` | 598,488,535 | 345,568,471 | 397,403,742 |
| `owned_prefix_child_escape` | 595,251,917 | 342,625,173 | 394,018,949 |
| `owned_prefix_default_arm` | 603,251,653 | 348,938,637 | 401,279,433 |
| `owned_prefix_list_escape` | 593,246,837 | 340,829,443 | 391,953,860 |
| `owned_prefix_mixed_int_scrutinee` | 610,702,528 | 351,655,428 | 404,403,743 |
| `owned_prefix_mixed_void_scrutinee` | 611,791,249 | 351,287,731 | 403,980,891 |
| `owned_prefix_owned_union_scrutinee` | 594,255,258 | 340,963,828 | 392,108,403 |
| `owned_prefix_projected_scrutinee` | 597,181,812 | 358,804,473 | 412,625,144 |
| `owned_prefix_projection_escape` | 596,165,870 | 342,862,196 | 394,291,526 |
| `owned_prefix_reassignment_aliases` | 601,789,815 | 361,330,557 | 415,530,141 |
| `owned_prefix_record` | 593,305,735 | 345,267,088 | 397,057,152 |
| `owned_prefix_record_arms` | 597,457,082 | 345,599,371 | 397,439,277 |
| `owned_prefix_root_escape` | 596,970,585 | 346,604,679 | 398,595,381 |
| `owned_prefix_selected_effects` | 600,481,089 | 360,304,921 | 414,350,660 |
| `owned_prefix_shared_child_roots` | 599,271,859 | 345,757,472 | 397,621,093 |
| `owned_prefix_union_escape` | 596,725,305 | 342,959,773 | 394,403,739 |
| `owned_prefix_unused_list` | 593,128,038 | 341,354,180 | 392,557,307 |
| `owned_prefix_unused_record` | 592,464,562 | 341,913,215 | 393,200,198 |
| `owned_prefix_unused_string` | 590,901,582 | 341,948,037 | 393,240,243 |
| `owned_prefix_unused_union` | 599,129,627 | 344,948,558 | 396,690,842 |
| `owned_propagation_exit` | 553,080,121 | 370,772,601 | 426,388,492 |
| `path_dirname_edges` | 597,419,478 | 412,130,339 | 473,949,890 |
| `path_join_arguments` | 646,863,302 | 400,520,104 | 460,598,120 |
| `path_join_counted_aliases` | 649,807,077 | 401,388,094 | 461,596,309 |
| `path_normalize_edges` | 623,091,380 | 436,087,618 | 501,500,761 |
| `pattern_alternative_inputs` | 600,058,233 | 359,108,547 | 412,974,830 |
| `pattern_list_rest` | 607,310,288 | 366,273,852 | 421,214,930 |
| `pattern_moderate_nested` | 1,136,102,579 | 830,302,960 | 954,848,404 |
| `pattern_nested_fallthrough` | 599,393,382 | 358,733,665 | 412,543,715 |
| `pattern_ordered_inputs` | 612,570,707 | 370,249,885 | 425,787,368 |
| `pattern_previous_list` | 526,628,097 | 337,946,118 | 388,638,036 |
| `pattern_previous_or` | 589,198,267 | 337,294,037 | 387,888,143 |
| `pattern_previous_string` | 588,004,572 | 336,971,235 | 387,516,921 |
| `pattern_string_bytes` | 599,150,903 | 359,691,563 | 413,645,298 |
| `plain_private` | 599,573,060 | 357,382,671 | 410,990,072 |
| `plain_record` | 639,251,903 | 381,944,275 | 439,235,917 |
| `process_native_capture` | 589,297,490 | 364,745,817 | 419,457,690 |
| `process_native_fault` | 598,603,461 | 360,884,764 | 415,017,479 |
| `process_native_find_program` | 576,990,239 | 354,947,331 | 408,189,431 |
| `process_native_together` | 591,297,363 | 367,089,242 | 422,152,629 |
| `pure_calls` | 590,197,250 | 336,292,512 | 386,736,389 |
| `record_aliases` | 590,327,518 | 338,071,561 | 388,782,296 |
| `record_basic` | 591,578,703 | 338,515,492 | 389,292,816 |
| `record_context` | 589,711,250 | 337,882,598 | 388,564,988 |
| `record_extrema` | 590,522,216 | 336,751,643 | 387,264,390 |
| `record_field_accumulator` | 583,662,301 | 397,864,442 | 457,544,109 |
| `record_field_order` | 597,241,820 | 356,901,661 | 410,436,911 |
| `record_generic` | 592,010,864 | 340,096,101 | 391,110,517 |
| `record_identity_escape` | 593,024,950 | 338,277,477 | 389,019,099 |
| `record_identity_reassignment` | 600,074,347 | 356,720,855 | 410,228,984 |
| `record_list_field` | 604,786,745 | 361,956,649 | 416,250,147 |
| `record_managed_aliases` | 600,172,321 | 358,367,690 | 412,122,844 |
| `record_managed_self_assignment` | 590,904,127 | 338,014,998 | 388,717,248 |
| `record_mixed` | 593,896,275 | 339,674,454 | 390,625,623 |
| `record_mixed_fields` | 596,489,225 | 355,360,887 | 408,665,021 |
| `record_nested_escape` | 596,484,898 | 342,102,609 | 393,418,001 |
| `record_nested_projection` | 593,731,683 | 340,538,869 | 391,619,700 |
| `record_nested_union_field` | 603,826,983 | 346,138,586 | 398,059,374 |
| `record_owning_union_field` | 602,970,051 | 346,175,460 | 398,101,779 |
| `record_phantom_union_fields` | 600,882,040 | 343,432,803 | 394,947,724 |
| `record_reassigned` | 590,221,111 | 338,931,781 | 389,771,549 |
| `record_recursive_direct` | 586,778,541 | 334,935,012 | 385,175,264 |
| `record_recursive_mutual` | 591,542,024 | 335,702,206 | 386,057,537 |
| `record_recursive_union` | 596,434,704 | 338,137,058 | 388,857,617 |
| `record_reordered` | 590,127,287 | 339,597,544 | 390,537,176 |
| `record_scalar_nested_field` | 597,178,225 | 358,217,587 | 411,950,226 |
| `record_shared_record` | 595,092,759 | 341,741,049 | 393,002,207 |
| `record_shared_string` | 593,026,052 | 340,698,107 | 391,802,824 |
| `record_union_aliases` | 605,257,836 | 346,881,666 | 398,913,916 |
| `record_union_payload` | 605,107,074 | 344,797,311 | 396,516,908 |
| `record_unmanaged_union_field` | 594,447,564 | 343,351,614 | 394,854,357 |
| `record_unused_managed` | 590,729,035 | 337,024,439 | 387,578,105 |
| `record_update_aliases` | 537,709,442 | 358,491,018 | 412,264,671 |
| `record_update_escaped_children` | 545,365,729 | 366,931,608 | 421,971,350 |
| `record_update_managed_reorder` | 545,236,415 | 365,436,930 | 420,252,470 |
| `record_update_order` | 539,965,582 | 360,994,580 | 415,143,767 |
| `record_void_field` | 589,684,915 | 335,994,891 | 386,394,125 |
| `record_wide` | 601,162,583 | 348,014,804 | 400,217,025 |
| `recursion_argument` | 596,532,276 | 338,667,634 | 389,467,780 |
| `recursion_binding` | 592,474,239 | 338,364,090 | 389,118,704 |
| `recursion_generic` | 502,382,306 | 339,512,422 | 390,439,286 |
| `recursion_mutual` | 593,167,424 | 339,550,838 | 390,483,464 |
| `recursion_record` | 593,412,040 | 340,056,163 | 391,064,588 |
| `recursion_self` | 592,882,656 | 337,269,540 | 387,859,971 |
| `recursion_string_live_local` | 593,224,469 | 339,980,478 | 390,977,550 |
| `recursion_string_result` | 591,778,180 | 338,447,297 | 389,214,392 |
| `recursion_ufcs` | 590,549,999 | 337,991,992 | 388,690,791 |
| `recursive_branches` | 603,682,946 | 361,993,906 | 416,292,992 |
| `recursive_group` | 606,086,174 | 363,787,155 | 418,355,229 |
| `recursive_kinds` | 604,823,707 | 362,693,122 | 417,097,091 |
| `recursive_linked` | 599,398,481 | 359,150,112 | 413,022,629 |
| `recursive_links` | 602,547,352 | 360,665,825 | 414,765,699 |
| `recursive_tree` | 551,678,448 | 371,106,249 | 426,772,187 |
| `recursive_union_deep` | 601,568,730 | 361,088,606 | 415,251,897 |
| `recursive_union_depth` | 594,041,047 | 341,779,258 | 393,046,147 |
| `recursive_union_list_payload` | 587,454,610 | 335,041,683 | 385,297,936 |
| `recursive_union_shared` | 597,916,820 | 345,748,321 | 397,610,570 |
| `recursive_union_trail` | 600,116,179 | 359,531,920 | 413,461,708 |
| `remove_int` | 564,189,192 | 381,982,999 | 439,280,449 |
| `result_chain_1` | 597,807,402 | 357,837,372 | 411,512,978 |
| `result_chain_16` | 630,669,610 | 385,936,664 | 443,827,164 |
| `result_chain_2` | 601,099,399 | 358,864,594 | 412,694,284 |
| `result_chain_5` | 606,196,126 | 365,853,975 | 420,732,072 |
| `result_chain_9` | 614,218,227 | 372,258,047 | 428,096,755 |
| `result_propagation_managed` | 609,338,891 | 367,059,438 | 422,118,354 |
| `result_rhs_carriers` | 602,552,600 | 360,973,693 | 415,119,747 |
| `return_42` | 587,388,028 | 334,860,808 | 385,089,930 |
| `return_zero` | 589,180,003 | 336,537,344 | 387,017,946 |
| `single_suite` | 630,542,704 | 384,371,412 | 442,027,124 |
| `sort_by` | 721,588,978 | 517,659,964 | 595,308,959 |
| `sort_by_nested` | 604,515,369 | 433,270,167 | 498,260,693 |
| `sort_by_orderable` | 607,684,133 | 441,112,196 | 507,279,026 |
| `sort_by_ties` | 577,067,422 | 393,164,924 | 452,139,663 |
| `source_loops_control` | 632,925,928 | 387,660,338 | 445,809,389 |
| `source_loops_list_sum` | 591,254,506 | 338,348,011 | 389,100,213 |
| `source_loops_managed_headers` | 582,243,188 | 399,128,993 | 458,998,342 |
| `source_loops_nesting` | 662,297,171 | 413,830,584 | 475,905,172 |
| `source_while_evaluation_order` | 604,358,983 | 363,894,744 | 418,478,956 |
| `source_while_header_swap` | 598,814,596 | 357,614,275 | 411,256,417 |
| `source_while_location` | 615,800,708 | 373,115,015 | 429,082,268 |
| `source_while_nested` | 621,087,934 | 378,182,716 | 434,910,124 |
| `static_empty` | 554,921,364 | 374,399,146 | 430,559,018 |
| `static_environment` | 611,293,900 | 364,721,742 | 419,430,004 |
| `stderr_alias` | 595,208,444 | 355,388,513 | 408,696,790 |
| `stderr_bytes` | 590,136,525 | 351,178,904 | 403,855,740 |
| `stored_callables_direct_list_copy` | 559,037,657 | 366,065,768 | 420,975,634 |
| `stored_callables_forwarded_capture` | 598,168,383 | 358,483,118 | 412,255,586 |
| `stored_callables_heterogeneous` | 606,373,547 | 364,178,053 | 418,804,761 |
| `stored_callables_pure_storage` | 596,193,203 | 342,338,357 | 393,689,111 |
| `stored_callables_receiver_order` | 597,413,328 | 355,997,168 | 409,396,744 |
| `string_append_int` | 592,011,310 | 351,447,617 | 404,164,760 |
| `string_append_int_builtin` | 609,585,866 | 367,010,718 | 422,062,326 |
| `string_append_int_edges` | 595,743,499 | 353,865,769 | 406,945,635 |
| `string_concat` | 595,027,748 | 354,003,777 | 407,104,344 |
| `string_concat_reuse` | 600,992,849 | 360,647,290 | 414,744,384 |
| `string_literal_basic` | 587,437,175 | 334,951,816 | 385,194,589 |
| `string_literal_comment_text` | 588,688,048 | 334,779,551 | 384,996,484 |
| `string_literal_copy_return` | 589,737,026 | 337,454,678 | 388,072,880 |
| `string_literal_empty` | 588,253,796 | 334,494,379 | 384,668,536 |
| `string_literal_escapes` | 588,359,867 | 334,774,018 | 384,990,121 |
| `string_literal_generic` | 589,654,410 | 336,115,226 | 386,532,510 |
| `string_literal_long` | 599,189,328 | 345,364,391 | 397,169,050 |
| `string_literal_long_unreached` | 540,944,094 | 340,266,932 | 391,306,972 |
| `string_literal_many_escapes_unreached` | 544,669,648 | 343,799,922 | 395,369,911 |
| `string_literal_normalization` | 590,488,774 | 337,636,453 | 388,281,921 |
| `string_literal_nul_digits` | 586,728,829 | 334,995,466 | 385,244,786 |
| `string_literal_tail_arms` | 592,882,797 | 339,004,718 | 389,855,426 |
| `string_literal_trigraphs` | 588,429,776 | 335,152,144 | 385,424,966 |
| `string_literal_unicode` | 588,501,339 | 335,035,724 | 385,291,083 |
| `string_literal_unicode_escapes` | 588,685,616 | 336,004,200 | 386,404,830 |
| `string_literal_union` | 597,832,634 | 341,632,776 | 392,877,693 |
| `string_literal_unused` | 587,104,317 | 334,886,798 | 385,119,818 |
| `string_match_cleanup` | 594,371,471 | 341,304,083 | 392,499,696 |
| `string_match_first` | 592,026,294 | 338,307,338 | 389,053,439 |
| `string_match_second` | 591,758,358 | 338,212,493 | 388,944,367 |
| `string_slice_bounds` | 540,685,428 | 363,111,292 | 417,577,986 |
| `string_slice_bytes` | 602,790,899 | 361,108,036 | 415,274,242 |
| `string_slice_ownership` | 606,495,719 | 363,483,953 | 418,006,546 |
| `string_starts_with_arguments` | 544,316,203 | 365,857,900 | 420,736,585 |
| `string_starts_with_counted` | 610,303,465 | 368,343,782 | 423,595,350 |
| `supertrait_bundle` | 610,701,410 | 367,918,177 | 423,105,904 |
| `supertrait_entailment` | 615,990,753 | 416,053,626 | 478,461,670 |
| `supertrait_generic_receiver` | 530,391,900 | 376,891,379 | 433,425,086 |
| `supplement_bounds` | 597,672,546 | 413,200,950 | 475,181,093 |
| `supplement_managed` | 616,514,174 | 425,982,363 | 489,879,718 |
| `supplement_predicates` | 594,284,004 | 434,270,236 | 499,410,772 |
| `syntax_continuation` | 590,471,095 | 338,875,422 | 389,706,736 |
| `syntax_grouping` | 590,125,520 | 338,110,431 | 388,826,996 |
| `syntax_import_block` | 588,643,080 | 337,013,733 | 387,565,793 |
| `syntax_next_line_value` | 587,695,447 | 335,638,482 | 385,984,255 |
| `syntax_pipe_string` | 591,957,397 | 352,383,700 | 405,241,255 |
| `syntax_standalone_annotated_lambda` | 587,526,252 | 335,837,091 | 386,212,655 |
| `tail_accumulator` | 545,008,160 | 364,861,394 | 419,590,604 |
| `tail_arm_bindings` | 593,013,645 | 338,915,978 | 389,753,375 |
| `tail_arm_current` | 594,890,235 | 339,275,387 | 390,166,696 |
| `tail_base` | 591,749,555 | 338,612,848 | 389,404,776 |
| `tail_carry_boundary` | 612,106,588 | 354,553,273 | 407,736,264 |
| `tail_countdown` | 622,990,522 | 366,335,136 | 421,285,407 |
| `tail_direct` | 590,843,120 | 337,296,596 | 387,891,086 |
| `tail_duplicates` | 592,587,609 | 338,359,224 | 389,113,108 |
| `tail_duplicates_right` | 592,294,204 | 339,852,643 | 390,830,540 |
| `tail_managed_helper` | 594,062,929 | 341,212,304 | 392,394,150 |
| `tail_payload` | 591,858,550 | 340,151,408 | 391,174,120 |
| `tail_prefix` | 593,424,439 | 340,470,563 | 391,541,148 |
| `tail_record` | 593,889,731 | 341,038,584 | 392,194,372 |
| `tail_swap_left` | 591,966,429 | 338,664,857 | 389,464,586 |
| `tail_swap_right` | 593,204,713 | 339,271,693 | 390,162,447 |
| `tail_ufcs` | 596,852,438 | 343,598,369 | 395,138,125 |
| `take_int` | 561,581,556 | 379,530,611 | 436,460,203 |
| `take_remove_managed` | 575,432,231 | 391,788,066 | 450,556,276 |
| `take_remove_moderate` | 560,356,340 | 379,676,097 | 436,627,512 |
| `take_remove_void` | 559,123,343 | 376,405,114 | 432,865,882 |
| `test_entry_counts` | 627,494,688 | 382,925,485 | 440,364,308 |
| `test_entry_empty` | 627,403,552 | 381,701,381 | 438,956,589 |
| `test_entry_failing` | 631,761,936 | 386,974,676 | 445,020,878 |
| `test_entry_passing` | 629,011,740 | 384,830,301 | 442,554,847 |
| `text` | 590,084,669 | 352,017,069 | 404,819,630 |
| `trait_bounds_defaults` | 60,004,748 | 53,389,289 | 60,004,748 (kept) |
| `trait_bounds_dispatch` | 78,585,790 | 69,669,343 | 78,585,790 (kept) |
| `trait_bounds_finite` | 99,915,283 | 87,887,759 | 99,915,283 (kept) |
| `traits_concrete` | 33,000,028 | 29,997,505 | 33,000,028 (kept) |
| `traits_location` | 56,434,790 | 49,939,111 | 56,434,790 (kept) |
| `traits_managed` | 43,703,038 | 39,411,062 | 43,703,038 (kept) |
| `tuple_callable_members` | 603,710,961 | 363,058,288 | 417,517,032 |
| `tuple_loops_capture` | 612,416,131 | 369,502,717 | 424,928,125 |
| `tuple_moderate_nested` | 661,658,878 | 416,858,543 | 479,387,325 |
| `tuple_patterns` | 620,415,204 | 373,256,857 | 429,245,386 |
| `tuple_triple` | 588,641,284 | 336,113,642 | 386,530,689 |
| `tuple_values` | 603,875,524 | 362,805,257 | 417,226,046 |
| `tuple_void_order` | 604,386,485 | 360,326,606 | 414,375,597 |
| `ufcs_calls` | 587,815,784 | 335,833,384 | 386,208,392 |
| `ufcs_chain` | 588,159,204 | 336,540,452 | 387,021,520 |
| `ufcs_chain_64` | 609,284,193 | 353,125,747 | 406,094,610 |
| `union_direct` | 590,177,309 | 338,257,114 | 388,995,682 |
| `union_direct_float_output` | 595,989,765 | 358,012,476 | 411,714,348 |
| `union_direct_forward_finite` | 594,296,049 | 341,883,128 | 393,165,598 |
| `union_direct_managed_record_escape` | 598,589,158 | 357,690,133 | 411,343,653 |
| `union_direct_nested_nominal_escape` | 605,967,677 | 362,116,889 | 416,434,423 |
| `union_direct_parent_alias_reassignment` | 598,415,929 | 362,436,852 | 416,802,380 |
| `union_direct_string_escape` | 593,004,489 | 339,253,387 | 390,141,396 |
| `union_direct_symbolic_list_admission` | 537,808,558 | 341,881,429 | 393,163,644 |
| `union_direct_void_empty` | 590,109,731 | 339,132,526 | 390,002,405 |
| `union_direct_void_tag` | 592,101,263 | 337,954,192 | 388,647,321 |
| `union_first` | 590,375,840 | 336,962,563 | 387,506,948 |
| `union_identity` | 591,861,869 | 338,603,347 | 389,393,850 |
| `union_multiple_alias_whole_reassignment` | 605,234,642 | 363,484,157 | 418,006,781 |
| `union_multiple_distinct_second_escape` | 595,799,932 | 355,381,071 | 408,688,232 |
| `union_multiple_generic_swapped` | 613,454,257 | 365,690,120 | 420,543,638 |
| `union_multiple_mixed_positions` | 597,996,510 | 358,056,874 | 411,765,406 |
| `union_multiple_pair_duplicate_escape` | 593,437,105 | 339,836,840 | 390,812,366 |
| `union_multiple_phantom_instances` | 606,929,134 | 362,363,313 | 416,717,810 |
| `union_multiple_written_argument_effects` | 597,652,343 | 356,844,636 | 410,371,332 |
| `union_receiver` | 590,369,871 | 337,806,504 | 388,477,480 |
| `union_second` | 590,377,941 | 337,679,316 | 388,331,214 |
| `union_values` | 594,959,133 | 341,642,367 | 392,888,723 |
| `unsupported_opaque_import_main` | 589,463,067 | 337,386,581 | 387,994,569 |
| `unsupported_opaque_type` | 595,606,884 | 334,871,433 | 385,102,148 |
| `update_reuse` | 587,923,543 | 401,983,836 | 462,281,412 |
| `value_if_answer` | 589,828,603 | 338,331,149 | 389,080,822 |
| `value_if_effects` | 616,012,897 | 372,309,586 | 428,156,024 |
| `value_if_list_aliases` | 544,223,568 | 365,054,600 | 419,812,790 |
| `value_if_return` | 588,122,648 | 335,827,931 | 386,202,121 |
| `written_names` | 587,951,330 | 335,887,606 | 386,270,747 |

## `process_native_together` after process L2, 2026-11-11

**Why.** Process L2 deleted `process.run_to_files`, so
`fixtures/process/natives_together.brp` now calls the three natives that
remain, `capture`, `find_program` and `fault` (declared, and called only with an
argument the run does not pass). Its program changed, so its ceilings are
re-measured by this file's rule: the largest reading plus 15%, rounded up.
Its run now prints `17\n7\n` and makes 10 allocations instead of 13.

- **Compiler:** the `-O0 -DBLORP_MEMORY_DIAGNOSTICS=1` test compiler,
  measured as the harness measures (`BLORP_LEAK_CHECK=strict`,
  `/usr/bin/time -l`), nine readings in three serial sets: two built from the
  uncommitted deletion on `2138b46c7` (on `c4e04dded`), one from `be59d562d`
  (on `7bd2b7047`). The branch was later rebased onto `873869eb0` (lexer
  constants, checking without `main`, plan edits) without re-measuring; the
  gates with `INSTRUCTION_CHECK=on` hold it to these ceilings there. Host:
  Apple M4, macOS 26.7.1, load average about 3 from other sessions.
- **Readings:** allocations 100,264 (eight) and 100,265 (one); instructions
  372,680,865 to 374,848,452.
- **Drift check:** unchanged siblings read slightly above their 2026-11-09
  measurements in the same sets: `process_native_capture` 365.7M to 367.6M
  (was 364.7M) and `process_native_fault` 361.8M to 365.1M (was 360.9M), so
  most of this program's rise over its old 367.1M is its new content.
- **Raw samples:** the task's scratch `logs/` directory: `narrow2.log`
  (`a8a3de7d296afc8ddf14006a7f5cc6359dbd2fba1cc81296570a7c036a8de6fc`),
  `controls.log` (`38c59f753357c61a03bb0fc87c5f1caf8016648d8d91fcf22997a44fcd030b2b`)
  and `gate-fixture.log` (`4f533aec4b705c1ba090b648afb2b78fa6a8fa806890b60fc5a9bb62520d94c4`).

| Program | Old allocations ceiling | New | Old instruction ceiling | New |
| --- | --- | --- | --- | --- |
| `process_native_together` | 116,766 | 115,305 | 422,152,629 | 431,075,720 |
