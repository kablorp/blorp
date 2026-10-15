# Blorp 2 emission: one program inventory and one runtime-requirements record, 2026-10-16

Validated 2026-10-15 in worktree `blorp2-emit-runtime`, branch
`blorp2/emit-runtime-requirements`, on main `522a49036`. Scope is the pilot
compiler's emitter; the host compiler is unchanged. Owned-input measurements
are proxies: the pilot cannot compile itself yet, so they use generated
programs and the e2e fixture corpus, not a self-compile.

## Summary

Emission asked "what does this program need from the runtime" by walking the
whole program once per question: seven `needs_runtime` calls, one String scan
and one Float scan, plus `list_layouts` and `list_update_helpers`, each
rebuilding every function's blocks (12 `function_blocks` calls per function).
An independent bug hunt reported this; a measured plan and two independent
reviews followed, and review asked for the whole class to be solved, not only
the reported instance.

Now one walk builds a `ProgramInventory` (the type of every declared field,
payload and defined value, and every runtime operation called). Commit 1
makes the list layouts and the list update helpers read it. Commit 2 fills a
`RuntimeRequirements` record from it. `function_blocks` runs twice per
function (the inventory and `owner_types`).

| | result |
| --- | --- |
| Emitted C, stdout, stderr, exit status | identical on all 425 e2e fixtures (348 compile, 77 rejected), 25 probe programs and every generated input, against a pilot built from `522a49036`, at both commits |
| Production lines (`emit.brp`) | 2,620 to 2,463: -157 |
| Test lines | +297 (a 15-case suite and one list update-helper case) |
| Instructions, generated programs | -1.5% to -3.6% (commit 1 alone -0.4% to -1.1%) |
| Allocations, generated programs | -0.6% to -1.5% |
| Emit phase instructions | -11% on `gen.py 1024 24 16`, -11% on `gen.py 0 64 16` |
| Instructions, e2e corpus (425 files) | -0.47% |

## Changes

1. **`a3fbb9272`, the inventory (preparatory).** `ProgramInventory { types,
   runtime_calls }` is built by one walk of the records, unions and every
   function's blocks. `list_layouts` folds over its types and
   `list_update_helpers` over its calls; the per-block walkers
   (`operation_list_layouts`, `block_list_layouts`, `operation_list_update`,
   `add_block_list_updates`) are gone. A runtime call needs no layout arm of
   its own: its operands and result are defined `List[element]` values, so the
   types already yield the same layouts (`call_list_layouts` was deleted; C is
   unchanged). The signature loops are gone as well, because the verifier
   ties every signature type to a defined value: `verify.brp:1129-1150` types
   each `ParameterDefinition` from the signature, `:1175` ties a call result to
   the callee's return type, `:1829` and `:1904` tie the returned value to the
   function's, and `:2412-2429` rejects a parameter with no definition.
   Lowering produces those definitions (`lower.brp:769-789`).
2. **`48d9380a0`, the requirements.** `RuntimeRequirements` has nine named
   flags: String and Float types (the ABI preludes) and one per runtime helper.
   `runtime_requirements(inventory)` folds the types and the runtime calls
   once. `emit` reads `requirements.float_parsing` where it called
   `needs_runtime(checked, FloatParsing)`. Deleted: `RuntimeFeature`,
   `runtime_matches` (a 50-line cross product), `operations_need_runtime`,
   `needs_runtime`, `operations_need_strings`, `operations_need_floats`,
   `needs_string_runtime`, `needs_float_runtime`. `is_string` and `is_float`
   had one shape, so one recursive `innermost_element` replaces them and the
   fold is a three-arm `match`.

Review items, each answered:

- **Signature loops.** Deleted from every consumer. C is identical on all
  fixtures and on the review probes (unused String and List parameters, a main
  with and without arguments, phantom records, recursive and generic cases).
  No case needed them. The suite's "unused String parameter" case pins the
  premise: leaving parameters out of the inventory fails exactly that case.
- **Comments.** The old comments said the prelude choice "is not reachability".
  The rule is: a String or Float anywhere in a record, union or function that
  specialization kept selects the prelude, even if no value of it is built,
  because a phantom type argument keeps its record
  (`blorp_2/test/e2e/fixtures/record/phantom_union_fields.brp`).
  `innermost_element` says so. "Inventory" now names only `ProgramInventory`;
  the list layouts are the "table" and the update helpers the "helper list".
  The inventory's comment names the verifier as the authority for dropping
  signature types.
- **Names.** `actual` is `operation`; the record is bound as `requirements`.
- **Include choice and `arguments_runtime`.** Kept where they are, with the
  record's comment narrowed to scalar helper preludes. They answer a different
  question, "which layouts exist" and "does the entrypoint take arguments",
  and each already has one authority (the layout tables and the typed
  `Entrypoint`). Moving them into the record would copy the entrypoint into a
  second place and add a field fed by no scan.
- **Tests.** The oracle is built from the fragment functions and from
  `INTEGER_ADD_RUNTIME` and `INTEGER_ARITHMETIC_RUNTIME`, now exported, so no
  test copies runtime text. Labels are sentences naming the behaviour.
  Multiplication, division and remainder each have a program, and a list case
  pins update-helper selection for `ListSet` and `ListConcat`.
- **The whole class.** Adopted; see the next section.

## Inventory decision

The review found that `list_layouts`, `list_update_helpers` and
`runtime_requirements` share one traversal skeleton. Two designs were built:

| design | `emit.brp` lines | `function_blocks` calls per function |
| --- | ---: | ---: |
| main | 2,620 | 12 |
| A: keep three passes (requirements as its own walk, signature loops removed, same renames) | 2,532 (-88) | 4 |
| B: one inventory feeds all three (adopted) | 2,463 (-157) | 2 |

A is the prototype as first built. The two later simplifications
(`innermost_element`, and no layout arm for runtime calls) apply to it as well
and would trim about 30 lines, leaving B smaller by about 40. B also keeps each fact in one place: what the program mentions
is one value, and the layouts, the update helpers and the requirements are
three read-only projections of it. A's three walks each restate the record,
union and block traversal. B is faster as well (tables below). The inventory
is not a cache: it has no key, is built once per emission and is dropped after
it.

## Production and test lines

| commit | production added | removed | net | tests added | removed |
| --- | ---: | ---: | ---: | ---: | ---: |
| `a3fbb9272` inventory | 64 | 89 | -25 | 28 | 0 |
| `48d9380a0` requirements | 72 | 204 | -132 | 269 | 0 |
| total | 136 | 293 | -157 | 297 | 0 |

Production is `blorp_2/src/emit/emit.brp`. Commit 1 also edits three lines of
`blorp_2/README.md`, and its tests are one case in
`test/unit/test_runtime/test_list.brp`; commit 2's are the new
`test/unit/test_emit/test_runtime_requirements.brp`.

## Method

Everything ran serially on Apple M4, macOS 26.7.1, Apple clang 21.0.0.

- **Host.** `make` built `bin/blorp` (SHA-256 prefix `0c763ea8968a`); `scripts/compiler-build-status` reported FRESH.
- **Pilots.** `clang -O0 -DBLORP_MEMORY_DIAGNOSTICS=1 ... -lm -lpthread` over the pilot's generated C, as `make -C blorp_2 test-compiler` does. Baseline: main `522a49036` exported with `git archive` (binary prefix `aa299d63d649`); commit 1 (`7eaeb98bdde8`); commit 2 (`7a74f46d755f`).
- **Cost.** `measure.sh LABEL COMPILER blorp_2/standard_library_temp INPUT OUT 3`: three `/usr/bin/time -l` "instructions retired" samples (`ulimit -s 65520`; the minimum is quoted), plus one `BLORP_LEAK_CHECK=strict` run for allocations, and the SHA-256 prefix of the emitted C. `campaign.sh` runs every row below in one pass.
- **Inputs.** `gen.py N G K` writes N concrete functions (a binary call tree, 17 lines each) and G chained generic functions, each used at K types. Hash prefixes: `1024 24 16` `479eece033da`, `1024 0 0` `b717545bf247`, `0 64 16` `86f1be5c810c`; scaling inputs are `gen.py N 0 0` and `gen.py 0 G 16`. The compiler has 1,038 functions, 6 of them generic.
- **Ablation pilots** (built from `522a49036` sources): E1 makes `needs_runtime` return False; E2 also `needs_string_runtime` and `needs_float_runtime`. P* pilots return from `compile` after each stage to split phases.
- **Identity.** `cmp.sh BASE CAND LIB DIRECTORY OUT` compiles every `.brp` under a directory (the e2e fixtures, then the review probes) with both pilots and compares the C, stdout, stderr and exit status. `compare_fixtures.sh` does the same with three instruction samples per file.
- **Retention.** Raw samples, scripts and logs are in the ignored `blorp_2/build/measure/emit_runtime_requirements/` and a copy in the session scratchpad (`scratchpad/emit_impl2/`). The raw rows are reproduced at the end of this report. Script SHA-256 prefixes: `gen.py` `67d5027f8e40`, `measure.sh` `d12c7d8c122e`, `campaign.sh` `e570ec99617d`, `compare_fixtures.sh` `ade514269a46`, `cmp.sh` `e30665816ce8`, `mutate.py` `d9cdfc4710c3` (the script that produced `mutation.txt`).

## Results

### Fix, generated programs

| input | pilot | instructions | vs baseline | allocations | vs baseline |
| --- | --- | ---: | ---: | ---: | ---: |
| `gen.py 1024 24 16`: 1,462 instances, 17.7K lines | 522a49036 | 15,531.4M |  | 10,178,152 |  |
|  | commit 1 (inventory) | 15,467.9M | -0.41% | 10,136,869 | -0.41% |
|  | commit 2 (requirements) | 15,292.3M | -1.54% | 10,114,496 | -0.63% |
| `gen.py 1024 0 0`: 1,043 instances, no generics | 522a49036 | 14,277.0M |  | 9,459,042 |  |
|  | commit 1 (inventory) | 14,217.1M | -0.42% | 9,424,679 | -0.36% |
|  | commit 2 (requirements) | 14,063.9M | -1.49% | 9,406,077 | -0.56% |
| `gen.py 0 64 16`: 1,068 instances, 64 generics at 16 types | 522a49036 | 2,834.1M |  | 1,886,212 |  |
|  | commit 1 (inventory) | 2,802.5M | -1.11% | 1,868,112 | -0.96% |
|  | commit 2 (requirements) | 2,733.0M | -3.57% | 1,858,501 | -1.47% |

Emitted C is identical in every row (same SHA-256 prefix; see the raw rows).
The per-commit split:

| input | commit 1 alone | commit 2 on top of commit 1 | both |
| --- | ---: | ---: | ---: |
| `gen.py 1024 24 16` | -0.41% | -1.13% | -1.54% |
| `gen.py 1024 0 0` | -0.42% | -1.08% | -1.49% |
| `gen.py 0 64 16` | -1.11% | -2.48% | -3.57% |

### What the nine scans cost (ablation)

| input | seven `needs_runtime` scans removed (E1) | all nine scans removed (E2) |
| --- | ---: | ---: |
| `gen.py 1024 24 16` | -130.0M (-0.84%); -17,403 allocations | -181.6M (-1.17%); -22,374 allocations |
| `gen.py 1024 0 0` | -115.0M (-0.81%); -14,469 allocations | -152.0M (-1.06%); -18,602 allocations |
| `gen.py 0 64 16` | -51.2M (-1.81%); -7,476 allocations | -69.2M (-2.44%); -9,611 allocations |

Each ablation is one execution of the scan removed, so it measures the scan's
own cost. The E1 and E2 pilots change the emitted C, so identity does not
apply. The difference between E1 and E2 (the String and Float scans) is small
against this campaign's noise; the claim is the total, about 1% to 2.4% of
instructions.

### Growth

Savings of commits 1 and 2 together against the same row's baseline:

| concrete functions | baseline | saving (commits 1+2) | allocations saved | C |
| ---: | ---: | ---: | ---: | --- |
| 256 | 3,293.5M | 53.4M (1.62%) | 13,415 | identical |
| 512 | 6,743.2M | 109.8M (1.63%) | 26,598 | identical |
| 1024 | 14,274.4M | 200.2M (1.40%) | 52,965 | identical |
| 2048 | 31,866.2M | 408.8M (1.28%) | 105,700 | identical |

Exponent of the saving per doubling: 256->512: 1.04, 512->1024: 0.87, 1024->2048: 1.03. The saving grows
linearly with program size and stays 1.3% to 1.6%.

| generic functions (16 types each) | baseline | saving (commits 1+2) | allocations saved | C |
| ---: | ---: | ---: | ---: | --- |
| 16 | 749.6M | 26.3M (3.51%) | 7,409 | identical |
| 32 | 1,428.0M | 51.7M (3.62%) | 14,176 | identical |
| 64 | 2,834.3M | 98.6M (3.48%) | 27,711 | identical |
| 128 | 5,838.3M | 204.5M (3.50%) | 54,782 | identical |

Exponent of the saving per doubling: 16->32: 0.97, 32->64: 0.93, 64->128: 1.05.

### Phase split of the baseline

`gen.py 1024 24 16`:

| load | check | specialize | lower | own | verify | emit | total |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 2,732.3M (17.6%) | 6,711.2M (43.2%) | 1,510.8M (9.7%) | 639.0M (4.1%) | 777.8M (5.0%) | 1,006.7M (6.5%) | 2,153.6M (13.9%) | 15,531.4M |

Emit phase with the change: 2,153.6M to 1,914.5M (-11.10%); the other phases run the same code, so the total's saving of 239.1M is all emit's.

`gen.py 0 64 16`:

| load | check | specialize | lower | own | verify | emit | total |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 122.4M (4.3%) | 162.8M (5.7%) | 718.7M (25.4%) | 238.3M (8.4%) | 354.5M (12.5%) | 343.8M (12.1%) | 893.6M (31.5%) | 2,834.1M |

Emit phase with the change: 893.6M to 792.4M (-11.32%); the other phases run the same code, so the total's saving of 101.2M is all emit's.

### Corpus and identity

- `cmp.sh` against the `522a49036` pilot: **425 fixtures, 348 compiled, 77 rejected, 0 differences**, for the commit 1 pilot and the commit 2 pilot. The 25 probe programs (22 from the review, 3 from the first pass: unused String and List parameters, `main` with and without arguments, phantom records and unions, recursive and generic cases) are identical at both commits.
- `compare_fixtures.sh` (minimum of three samples per file and pilot), baseline to commit 2: 17,581,653,875 to 17,499,404,810 instructions, **-0.468%**, 0 differences. Per-file rows: `samples/corpus_final/costs.tsv` (SHA-256 prefix `aa1f57247d13`).

### Other findings

The specialization traversal, `find_instance` and the checker's name lookups
were measured in the repeated-scans plan (session scratchpad,
`tier2/repeated_scans_plan.md`). They are outside this change.

## Tests

`blorp_2/test/unit/test_emit/test_runtime_requirements.brp`, 15 cases. Each
compiles one small program and asserts the exact set of helper families in the
emitted C. Fragments come from `string_runtime()`, `string_print_runtime()`,
`string_parse_int_runtime()`, `string_equals_runtime()`, `float_runtime()`,
`float_string_runtime()`, `float_parse_runtime()`, `INTEGER_ADD_RUNTIME` and
`INTEGER_ARITHMETIC_RUNTIME`. Cases: addition, subtraction, multiplication,
division and remainder (one program each), print, integer parsing, string
equality, float arithmetic, float formatting, float parsing, a phantom record
String field, a phantom record Float field, a union String payload, and an
unused String parameter. `test_list.brp` gains "set and concat helpers exist
where called". With the two integer constants exported, the requirements suite
also passes against main's selection logic (see Gates).

Mutation check (`mutate.py`, output `mutation.txt`): 23 mutants, 23 killed.
Dropping `IntSubtract`, `IntMultiply`, `IntDivide` or `IntRemainder` from the
arithmetic arm each fails its own program and nothing else. Swapping
`IntAdd`, `StringPrint` or `StringEquals` to another flag, ignoring
`StringParseInt`, `FloatToString` or `StringParseFloat`, and swapping the
emit-site condition each fail their program. Not inventorying record fields
fails the two phantom cases; not inventorying union payloads fails the union
case; not inventorying defined value types or runtime calls fails the
operation cases; leaving `ParameterDefinition` out of the inventory fails only
the parameter case; not peeling List layers fails the parameter case; crossing
the String and Float flags fails every case of that family. Dropping the
`ListSet` or `ListConcat` update helper, or making `ListSet` select the append
helper, fails the new list case; dropping `ListAppend` fails the existing one.

## Gates

Run at `48d9380a0` (the report commit changes only documentation):

| gate | result |
| --- | --- |
| `make`, then `scripts/compiler-build-status` | built; FRESH |
| `make -C blorp_2 test` (unit, runtime, grammar, e2e) | exit 0 in 4:05; 3,689 passing cases and none failing; e2e 426 cases passed, 0 failed (`make_test_final.log`) |
| C, stdout, stderr and exit status against the `522a49036` pilot | identical on all 425 fixtures and 25 probes at commit 1 and at commit 2; identical on all generated inputs |
| `scripts/blorp2-fixpoint --frontier` | `parsed 32/34`, as on main; the two files that do not parse are `lex/lex.brp` (Char literals) and `specialize/specialize.brp` (`pure` used as a name), neither touched (`fixpoint.log`) |
| requirements suite against main's selection logic (integer constants exported) | 15 of 15 pass |
| subset grep over the added `blorp_2/src` lines | no hits (command below); the added lines with commas inside parentheses are all calls and patterns, no tuple |
| `git diff --check 522a49036 HEAD` | clean |

Subset grep: `git diff 522a49036 HEAD -U0 -- blorp_2/src | grep '^+' | grep -v '^+++' | grep -nE '==|!=|func\(|\+ "|\) \+ |lambda'`.

## Caveats

- Instruction counts of one pilot and input vary by about 0.3% between campaigns and a first run can read 4% to 36% high. Only rows measured in the same campaign are compared, using the minimum of three. The savings above are several times larger; the E1 to E2 difference is not.
- Pilots are `-O0` (the e2e configuration); `-O2` was not measured.
- Inputs are synthetic and call-tree shaped. The shares of check and emit differ on real programs.

## Raw samples

Columns: pilot, input, instruction samples (in run order), minimum, allocations, SHA-256 prefix of the emitted C. The phase pilots emit no C, so their prefix is that of empty output (`e3b0c44298fc1c14`).

Headline (`samples/headline.tsv`):

```
baseline	comp_1024_24x16.brp	15532675256,15531394576,15532773052	15531394576	10178152	e599684752a19826
inventory	comp_1024_24x16.brp	15489487112,15467863476,15469019571	15467863476	10136869	e599684752a19826
final	comp_1024_24x16.brp	15292340115,15293321198,15294783833	15292340115	10114496	e599684752a19826
E1	comp_1024_24x16.brp	15413621555,15403196959,15401424582	15401424582	10160749	3c2e40d09f741a4f
E2	comp_1024_24x16.brp	15361122544,15349755191,15357691218	15349755191	10155778	5d3375b3f71b8972
baseline	conc_1024.brp	14291728054,14277028267,14293646823	14277028267	9459042	87fb636ee8ebf5ff
inventory	conc_1024.brp	14232690731,14233201841,14217137425	14217137425	9424679	87fb636ee8ebf5ff
final	conc_1024.brp	14083864317,14063933233,14069676841	14063933233	9406077	87fb636ee8ebf5ff
E1	conc_1024.brp	14162060490,14167151005,14171767585	14162060490	9444573	0627953d0b20bd86
E2	conc_1024.brp	14125045385,14131737741,14127777843	14125045385	9440440	4127073a5d0e4fe4
baseline	gen_64x16.brp	2836459087,2834143831,2834343971	2834143831	1886212	dbecad30feb38e88
inventory	gen_64x16.brp	2803669399,2803432235,2802544330	2802544330	1868112	dbecad30feb38e88
final	gen_64x16.brp	2734792404,2734446614,2732987069	2732987069	1858501	dbecad30feb38e88
E1	gen_64x16.brp	2783012933,2785129773,2782962750	2782962750	1878736	d8bb8095cd5c60cd
E2	gen_64x16.brp	2764906147,2765886372,2767057651	2764906147	1876601	b4c3677df0428f21
```

Phases (`samples/phases.tsv`):

```
Pload	comp_1024_24x16.brp	2734695354,2732624703,2732272866	2732272866	1736473	e3b0c44298fc1c14
Pcheck	comp_1024_24x16.brp	9447630593,9443855388,9443453007	9443453007	6027509	e3b0c44298fc1c14
Pspec	comp_1024_24x16.brp	10960147460,10955567042,10954228512	10954228512	6938480	e3b0c44298fc1c14
Plower	comp_1024_24x16.brp	11604125390,11599034764,11593274301	11593274301	7572065	e3b0c44298fc1c14
Pown	comp_1024_24x16.brp	12391834229,12372165633,12371113776	12371113776	8278458	e3b0c44298fc1c14
Pverify	comp_1024_24x16.brp	13386826322,13377807326,13384799956	13377807326	9102493	e3b0c44298fc1c14
Pload	gen_64x16.brp	123025296,122542633,122419277	122419277	64619	e3b0c44298fc1c14
Pcheck	gen_64x16.brp	285774329,285262215,285333646	285262215	188741	e3b0c44298fc1c14
Pspec	gen_64x16.brp	1004266224,1004143557,1003973556	1003973556	565335	e3b0c44298fc1c14
Plower	gen_64x16.brp	1243410279,1242299564,1243372861	1242299564	803561	e3b0c44298fc1c14
Pown	gen_64x16.brp	1597705076,1596892082,1596785720	1596785720	1127167	e3b0c44298fc1c14
Pverify	gen_64x16.brp	1941192204,1940971616,1940593557	1940593557	1417033	e3b0c44298fc1c14
```

Concrete scaling (`samples/scaling_concrete.tsv`):

```
baseline	conc_256.brp	3297982869,3294249667,3293495915	3293495915	2379926	61f97cb1542c5a76
final	conc_256.brp	3242975945,3240498213,3240133536	3240133536	2366511	61f97cb1542c5a76
baseline	conc_512.brp	6743753962,6743236119,6743317470	6743236119	4739630	c764eae30f823c3f
final	conc_512.brp	6635928540,6634553675,6633462010	6633462010	4713032	c764eae30f823c3f
baseline	conc_1024.brp	14293905613,14292077294,14274374900	14274374900	9459042	87fb636ee8ebf5ff
final	conc_1024.brp	14074148120,14083897091,14075983333	14074148120	9406077	87fb636ee8ebf5ff
baseline	conc_2048.brp	31877840725,31873433521,31866209786	31866209786	18899324	a2f3da3734abc83d
final	conc_2048.brp	31470460938,31457377971,31465225443	31457377971	18793624	a2f3da3734abc83d
```

Generic scaling (`samples/scaling_generic.tsv`):

```
baseline	gen_16x16.brp	752346163,749612071,749797574	749612071	506436	73624cdeef8753c5
final	gen_16x16.brp	724376243,723269202,723443521	723269202	499027	73624cdeef8753c5
baseline	gen_32x16.brp	1428644643,1428026470,1428854199	1428026470	966450	c02faa85b47f6654
final	gen_32x16.brp	1377484373,1376343849,1378447719	1376343849	952274	c02faa85b47f6654
baseline	gen_64x16.brp	2844032855,2834334680,2836070166	2834334680	1886212	dbecad30feb38e88
final	gen_64x16.brp	2735824071,2735691669,2735864990	2735691669	1858501	dbecad30feb38e88
baseline	gen_128x16.brp	5840885310,5838319351,5841289596	5838319351	3725715	c751495d67579d9e
final	gen_128x16.brp	5633772988,5634760950,5634097326	5633772988	3670933	c751495d67579d9e
```
