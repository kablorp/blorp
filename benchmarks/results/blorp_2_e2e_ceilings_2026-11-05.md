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
