# Pilot compiler cleanup

Status: retained source validated. Specialization optimization rejected and
restored exactly. The full gate passed on one unchanged retry after a small
instruction-ceiling miss; both outcomes are retained below.

The immediate baseline is the reviewed, uncommitted multiple-union-parameter
implementation on `blorp-2`, above `276250fb8`. Preserve that work. The pilot is
not self-hostable; all pilot compilation measurements below are owned-input
proxies, not self-compilation results. Existing host compiler sources and build
flags remain unchanged.

## Scope and acceptance fixed before implementation

| Slice | Intended result | Formatted production LOC | Performance acceptance |
| --- | --- | --- | --- |
| Inference collection | Apply ordered constraints to local inference slots without growing-prefix concatenation | Target reduction; stop and report before net growth | Demonstrate removal of prefix-copy scaling on wide applications; set the numerical targeted threshold after an unedited baseline probe, before implementation |
| Specialization collection | Prepare type occurrences and collect calls in one local traversal, preserving all-types-before-call-request ordering | Target reduction; stop and report before net growth | Demonstrate improvement on a representative many-occurrence input; set the targeted threshold before implementation; retain linear instance lookup unless a measured index design is separately approved |
| Diagnostic boundary | Separate pure presentation from accepted semantic facts and checking without weakening sealed construction | Target flat or reduced total; investigate more than 25 added production lines across all moved files and importers | Target identical pilot allocations; investigate any repeatable increase or more than 2% retired-instruction growth |
| Evidence workflow | Use the existing validation recorder and one clearly named results entrypoint | No new production tooling; report documentation changes separately | No compiler/runtime work or additional compiled gates merely for evidence packaging |

Inference and specialization investigate repeatable per-workload allocation or
minimum-retired-instruction increases above 2% against the immediate baseline.
Every comparison uses matched source inputs, host/toolchain, flags and three
serialized samples. The six existing comparison inputs are return/zero,
nested/calls, mortal_string/basic, generic/box, union/values and
match/constructor_spine, plus the five generic/union_parameters examples.
All fixture ceilings remain unchanged. Do not treat thresholds as a budget.

Preserve exact accepted types, identities, substitution order, first-error
priority, diagnostic kind/message/help/note/spans and every preexisting test.
All 78 valid fixture programs must emit byte-identical C. New tests use Blorp
TestSuite and directly observe phase facts. Each changed behavior or ordering
oracle must reject a relevant deliberate mutation. Inspect generated host C
for ownership and COW effects. Report production and test LOC separately;
moved lines, compressed formatting and removed coverage are not reductions.

Workers first return source-grounded designs and proposed measurements.
Inference and specialization may edit disjoint files after baseline/design
approval. Diagnostic extraction waits for inference's checker edits to freeze.
All compiled commands and measurements use one coordinator-assigned lane.
The final integrated code receives independent compiler/code and test review,
strict ASan/UBSan/leak unit tests, and `make -C blorp_2 test` with one O0 pilot
build per end-to-end run. No commit or push is requested.

The user's additional acceptance requirement is independent compiler-expert
review with an explicit judgment that each retained slice and the combined
project are better in correctness, architecture, readability and measured
cost. Review may reject a passing or shorter implementation. Code and test
reviewers must state unresolved limitations rather than infer approval from
green gates.

## Evidence convention

Use `blorp_2/build/cleanup/run.md` as the single local entrypoint. It names the
baseline source snapshot, binaries, matched samples and recorder packets by
their purpose. Source identity and artifact identity remain distinct; no
overlapping artifact manifests or additional controller are needed.
Use `scripts/record-validation` for actual validation commands, preserving its
metadata and logs. This retained report records runnable commands, measurements,
limitations and review outcomes, so an ignored scratch directory is not the
only explanation of the result. Historical union-increment evidence is retained
unchanged.

## Frozen baseline

The host is FRESH, SHA-256
`f6d946861a5a07faa506cb598e0e64d8af0f89289551737b5e0dc42443554a8c`.
The immediate baseline source archive is
`blorp_2/build/cleanup/baseline/sources.tar`, SHA-256
`9a07177ff73ae7d9809f1aebdcebed3792afc4afc647006b2c61d927fb69fc17`.
Baseline pilot binary SHA-256 is
`bd7fb1ba3c0c05ecebd7e4c646453d717be575d7e3f3c7a7b0b6d26727db2267`;
generated C SHA-256 is
`72c4db3ca599afa29911bdac7f9294b0939267f627f215e572b07e962c5fbe5a`.
These artifacts were explicitly reused after checking every current production
and fixture input against the union increment's recorded checksums. Raw timing
samples will be rerun as matched pairs. Baseline physical formatted Blorp lines:
10,670 production and 22,711 tests.

## Targeted probes

Specialization's unedited probe uses one mutable binding and one reused generic
identity instance, with 64, 256 or 1,024 assignments. It checks once outside the
measured allocation interval and specializes the frozen checked input 10 or 30
times. Existing scalar memory counters isolate managed allocations. The
difference between the two iteration counts estimates retired instructions per
specialization plus its small validation/release loop; this is a proxy, not a
native phase counter. At 1,024 assignments, estimated setup is 5.89% of the
30-iteration process cost.

Before source edits, the targets are fixed at at least 10% less instruction
slope at 1,024 occurrences and an excess-cost scaling ratio of at most 5:
`(cost1024 - cost64) / (cost256 - cost64)`. The original ratio is 9.684.
Exact baseline allocations per specialization are 2,147 / 8,293 / 32,871;
minimum-instruction slopes are 5,389,927.75 / 27,949,010.25 / 223,873,577.9.
The ignored `specialization_probe/` directory contains its Blorp benchmark,
generated C, frozen executable and all 18 raw baseline samples.

Inference's unedited probe checks an already parsed wide fieldless union
application 100 times, using active and control programs with identical
declarations. The active program adds the generic call. Before edits, fixed
targets are at least 20% fewer active-minus-control allocations and minimum
instructions at width 256, and at most sixfold excess-instruction growth from
width 64 to 256. A 64-distinct-parameter guard investigates repeatable increases
above 2%. Scalar allocation endpoints exclude parsing/setup; instruction excess
is a repeated-check process proxy. The baseline excesses for widths 16/64/256
are 16,200 / 54,800 / 208,600 allocations and 37,086,607 / 140,533,258 /
773,111,780 instructions. The distinct-parameter guard is 68,200 allocations /
213,358,237 instructions. Raw samples and frozen binaries are under
`blorp_2/build/cleanup/inference/`.

The retained inference implementation uses a direct recursive slot fold;
agreeing constraints leave the original slot unchanged. Eight new narrow
callbacks pass. It removes 3 formatted checker lines. At width 256, excess
allocations fall from 208,600 to 55,400 (-73.44%) and excess instructions from
772,821,402 to 171,063,103 (-77.87%). Candidate excess-instruction scaling from
64 to 256 is 3.47, below the fixed ceiling of 6. The 64-distinct-parameter
active program improves from 110,000 to 78,300 allocations (-28.82%) and
404,344,436 to 352,825,763 instructions (-12.74%). Final paired files supersede
the preliminary samples: all 48 runs exited zero with checksum 300, equal
interval allocations/releases and strict zero-leak reports. The new eight
callbacks and 172 focused callbacks pass; a first-origin mutation fails its
intended callback, then exact source restoration passes. Generated C still
retains slots across recursion and uses the standard uniqueness/COW branch.
The claim is removal of intermediate constraint-prefix work, not universally
linear physical inference or copy-free slots.

## Rejected specialization experiment

The candidate reduced large-case allocation counts by 6.25% and its instruction
slope by 47.58%, but its incremental scaling ratio remained 7.272, exceeding
the fixed ceiling of 5. Independent compiler review located growing-prefix
copying inside the changed collector: a live PreparedBody/Result still owned
the call list while its field was appended. A bounded explicit-field projection
did not end that lifetime. In `specialization_probe/projection.c`, the Result
is retained at line 68326, calls retained at 68343, append capacity checked at
68354, and owners released only at 68385/68389. No further workaround, index,
framework or relaxed threshold was introduced.

The cleanup was rejected. `src/specialize.brp` is restored byte-for-byte to
the immediate pre-cleanup dirty baseline, SHA-256
`0e1a974215fdcfcc0b866b7239729bdc805efbb9069ad9defb96310f5b13a0ac`.
The earlier multiple-union implementation remains intact. Candidate speedups
are **not shipping**. Five new ordering/provenance callbacks remain useful:
they pass on the baseline; the candidate's call-order mutation failed two
callbacks including the distinct direct-nested-call case, and its type-order
mutation failed the intended diagnostic-span callback. Candidate focused
validation passed 82 callbacks, but does not validate an accepted optimization.
The raw 36 samples, candidate/projection source, C, binaries and mutation
receipts remain in `specialization_probe/`.

All occurrence types before call-target requests is structurally preserved by
the existing specializer. The current sealed, one-way-inferred call products
do not provide a distinguishing accepted-source oracle for that particular
future-facing ordering contract. We record that limitation rather than add an
unchecked product constructor merely for a test.

## Retained diagnostic boundary and line counts

`check_render.brp` depends on `check`; semantic model types, accepted products
and failure construction remain sealed in `check`. The new read-only
`failure_program` reader lets failure rendering use its original parsed
authority. No facade or second model was added. Main and four unit importers
use the new module. All 142 renderer string literals retain their exact order.
Focused validation passes 117 callbacks; three mutations independently fail
their intended frozen-count, spelling-authority and collection-order oracles,
then exact restoration passes.

Formatted physical Blorp production is 10,679 versus 10,670: **+9**, comprising
inference -3, renderer boundary +12, and specialization 0 after restoration.
Moving about 600 presentation lines is not a reduction. Tests are 23,408 versus
22,711: **+697**, comprising 297 inference, 256 specialization, 141 renderer
and 3 import lines. No existing coverage was removed or formatting compressed.
Evidence changes add documentation, with no new executable production tooling.

## Integrated measurements and output identity

Three serialized baseline/final/pre-renderer samples per workload produce 99
raw rows in `costs/samples.tsv`. Both counters come from each same compilation,
with strict zero-leak diagnostics; all runs exit zero and have empty stdout.
All 78 valid fixture C pairs are byte-identical; `identity/inputs.txt` names
their inputs and adjacent files retain generated C and diagnostics.

| Workload | Baseline → final allocations | Baseline → final minimum instructions |
| --- | ---: | ---: |
| return_zero | 690 → 690 | 31,656,283 → 31,720,551 |
| nested_calls | 1,341 → 1,341 | 33,562,923 → 33,581,873 |
| mortal_string | 1,039 → 1,039 | 32,702,977 → 32,695,469 |
| generic_box | 2,211 → 2,208 | 36,081,469 → 35,997,032 |
| union_values | 3,661 → 3,661 | 40,031,543 → 40,052,080 |
| match_constructor_spine | 8,738 → 8,738 | 53,746,904 → 53,816,907 |
| new_ok | 2,268 → 2,268 | 36,184,482 → 36,244,100 |
| new_err | 2,269 → 2,269 | 36,184,359 → 36,171,748 |
| new_third | 2,306 → 2,306 | 36,409,363 → 36,380,750 |
| new_unwrap_or | 3,275 → 3,257 | 38,986,262 → 38,924,820 |
| new_phantom_keys | 3,762 → 3,755 | 40,499,285 → 40,488,289 |

No workload increases allocations; maximum instruction growth is 0.203%,
below the 2% investigation threshold. These small changes do not establish a
whole-pipeline speedup. Isolated renderer comparison uses the same inferred
checker and restored specializer, reverting only the diagnostic extraction:
every allocation count is identical, and no minimum instruction count grows.
Raw paths differ by variant name, so tiny process-level instruction differences
should not be attributed to the module boundary.

Host source-to-C and native linking are separate from pilot execution. On the
same FRESH host with Apple clang 21, both final and pre-renderer builds take
0.89 seconds to host C emission and 1.00 seconds to native linking in single
observational runs. These are not matched performance claims. Pilot and probe
native builds use `-O0 -DBLORP_MEMORY_DIAGNOSTICS=1`, linked with `-lm -lpthread`;
host CLI/runtime remain O0/O2. Final binary SHA-256 is
`4440a0c3b3ef3ae19a4998bfeb9be2bd37cc6c667ccc1728fbd9c1b8ed0b3707`;
generated C is
`51182781bed0f4a94be0805c5955844f35475da6910f742260a58a69109ab1e6`.

## Runnable reproduction

The benchmark entrypoints are Blorp, distinct from TestSuite correctness tests.
From the repository root, rebuild the current inference probe with:

```sh
bin/blorp compile --no-format blorp_2/build/cleanup/inference/harness.brp \
  -o blorp_2/build/cleanup/inference/rebuilt.c
clang -O0 -DBLORP_MEMORY_DIAGNOSTICS=1 \
  blorp_2/build/cleanup/inference/rebuilt.c \
  -o blorp_2/build/cleanup/inference/rebuilt -lm -lpthread
/usr/bin/time -l -o blorp_2/build/cleanup/inference/rebuilt.time \
  env BLORP_LEAK_CHECK=strict blorp_2/build/cleanup/inference/rebuilt \
  256 repeat active
```

Use `16`, `64`, `256` with `repeat control`/`repeat active`, and `64 distinct
control`/`64 distinct active`, three sequential baseline/candidate pairs each.
Frozen executables are `inference/baseline` and `inference/candidate`; to
rebuild the baseline, copy the same harness under
`baseline/tree/blorp_2/build/cleanup/inference/` and compile it there so its
relative imports reach the frozen baseline source. Final authoritative paired
tables are `inference/paired-{baseline,candidate,comparison}.tsv`.

Specialization's rejected experiment can be inspected or rerun from its frozen
executables with the existing benchmark arguments:

```sh
/usr/bin/time -l -o /tmp/blorp-specialize.time env BLORP_LEAK_CHECK=strict \
  blorp_2/build/cleanup/specialization_probe/baseline 1024 30
/usr/bin/time -l -o /tmp/blorp-specialize-candidate.time \
  env BLORP_LEAK_CHECK=strict \
  blorp_2/build/cleanup/specialization_probe/candidate 1024 30
```

Its source is `specialization_probe/benchmark.brp`; compilation/link flags are
the same as the inference probe. Inputs are 64/256/1024 assignments and 10/30
iterations. The current production specializer is the restored baseline.

Reproduce one whole-pilot matched sample with the same command for `baseline`,
`final` and `renderer-before`, then repeat three times for each path in
`costs/workloads.txt`:

```sh
/usr/bin/time -l -o /tmp/blorp-pilot.time env BLORP_LEAK_CHECK=strict \
  blorp_2/build/cleanup/final/compiler blorp_2/src/prelude_temp.brp \
  blorp_2/test/e2e/fixtures/union/values.brp /tmp/blorp-pilot.c
```

Recheck all retained C pairs and source inputs without compiling:

```sh
while read -r input; do
  relative=${input#blorp_2/test/e2e/fixtures/}
  prefix=blorp_2/build/cleanup/identity/${relative%.brp}
  cmp "$prefix-baseline.c" "$prefix-final.c" || exit 1
done < blorp_2/build/cleanup/identity/inputs.txt
shasum --check --quiet blorp_2/build/cleanup/final/inputs.sha256
```

## Final validation and review

`validation/strict-unit/` passes **512/512** callbacks across 31 suites with
ASan, UBSan and strict leak checking. Its source fingerprint is unchanged.
The first `validation/full-pilot/` run fails the `union_values` instruction
ceiling at **40,004,573 / 40,000,000**, a 0.0114% miss. Its other leaves pass.
The one unchanged `validation/full-pilot-rerun/` passes **683/683** reported
checks: 681 leaves (512 unit, 9 runtime C, 94 e2e and 66 grammar) plus two
orchestration checks. That run measures `union_values` at **39,920,129**
instructions. Both packets are retained; a passing retry does not erase the
first failure or prove the ceiling robust. The frozen baseline also exceeds
40 million in the separate matched process benchmark, so the available margin
is weak; no ceiling was raised and no repeatable candidate regression was found.

Both full runs use the same source fingerprint, and each e2e run generates and
links the pilot once at O0. Formatting checks pass on ten cleanup source/test
modules; `git diff --check` passes. Recorded gate commands are:

```sh
scripts/record-validation --output blorp_2/build/cleanup/validation/strict-unit \
  --timeout 180 -- bin/blorp test --suite --sanitize --leak-check \
  --timeout 180 blorp_2/test/unit
scripts/record-validation --output blorp_2/build/cleanup/validation/full-pilot \
  --timeout 180 -- make -C blorp_2 test
```

Use a fresh packet directory to rerun, preserving prior outcomes. Independent
compiler/code and compiler/test reviewers assess the exact frozen retained
inputs, raw counters, C identity, mutation oracles and generated ownership C.
Their reports are `code-review.md` and `test-review.md`. They agree that the
retained inference, presentation boundary and evidence convention improve the
project, and that rejecting the specialization cleanup was correct. Remaining
limitations are possible inference-slot COW, the rejected specialization's
quadratic accumulation problem, the stated source-oracle gap and the fragile
instruction ceiling. No commit or push is part of this task.

After validation, only this retained report and the README's module-boundary
description changed. Production, tests, grammar and fixture bytes still match
`final/inputs.sha256`; no compiled rerun is needed solely for these prose edits.
