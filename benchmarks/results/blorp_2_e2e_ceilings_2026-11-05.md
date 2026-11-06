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
