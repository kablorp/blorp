# Blorp 2 generic unions

One declared union parameter now works with atomic written applications,
argument-driven generic functions, constructors and exhaustive payload matching.
`box(7)`/`unbox` returns 7. Rigid declaration checking remains independent of
specialization; union and function parameters have distinct typed owners.
Specialization translates complete signatures, bindings, occurrences, calls,
constructors and patterns into concrete instance identities before lowering.
Keys include the declaration and complete concrete argument; equal layouts
retain distinct nominal identities, and repeated direct/UFCS requests reuse
instances. Checked signature `TypeUse` fields retain one semantic type and its
written location. Request provenance is separate from key equality and survives
forwarding.

Concrete payloads remain absent or Int. Unsupported payloads diagnose at the
written application or initiating concrete call, with a note at the original
payload annotation. Exact tests cover written `Box[String]`, symbolic forwarding,
semantic `box(box(7))`, and wrapping an already-typed ordinary union. Phantom
String applications and a String argument with an explicitly Int field remain
accepted. Nested written applications, managed fields and host/runtime changes
remain outside this increment.

## Frozen evidence

The original post-tail baseline is unchanged under
`blorp_2/build/generics/baseline/`, including source archive, dirty patch, binary
and original samples. `union-candidate/` contains the frozen final sources,
input hashes before/after measurement, pilot C/binary, matched raw samples,
`costs.json`, `native-results.json`, `depths.json` and `loc.json`.
Host `bin/blorp` is FRESH and unchanged:
`f6d946861a5a07faa506cb598e0e64d8af0f89289551737b5e0dc42443554a8c`.
Baseline pilot:
`a470cffab70ad57d94866b7ad69c5a0bb7c7ae5fd86136bbbb5b4d5914e5ec1b`.
Union pilot:
`1ae9b44ff3642fc6e098314bea5fe812c18d85c3877f22631f96c4dd8f928b01`.
Both pilots use the same host and Apple clang 21.0.0, arm64 Darwin;
`-O0 -DBLORP_MEMORY_DIAGNOSTICS=1 -lm -lpthread`.

Three serialized alternating baseline/candidate samples per unchanged input ran
under `benchmarks/self_compile_measure lock --`, with `/usr/bin/time -l` and
`env -u BLORP_MEMORY_STATS BLORP_LEAK_CHECK=strict`. Fresh baseline samples
rerun the original frozen post-tail binary and unchanged workloads; they do
not advance the baseline. Values below are deterministic allocations and
minimum retired instructions from those matched triples.

| Input | Baseline allocations | Final allocations | Baseline instructions | Final instructions |
| --- | ---: | ---: | ---: | ---: |
| return_zero | 624 | 684 (+9.62%) | 30,567,271 | 30,779,025 (+0.69%) |
| mortal_string | 920 | 1,020 (+10.87%) | 31,365,990 | 31,746,683 (+1.21%) |
| match_string_first | 1,788 | 2,044 (+14.32%) | 33,871,512 | 34,525,694 (+1.93%) |
| match_many_arms | 66,760 | 74,897 (+12.19%) | 313,367,115 | 337,186,729 (+7.60%) |

All twelve final C files are byte-identical to their matched baseline files.
All 24 compilations have empty stdout and zero leaked allocations/bytes.
The 256-arm output retains maximum brace depth 3. No metric reaches the
cumulative 25% investigation threshold, and existing fixture caps are unchanged.
These are owned-input compilation proxies, not self-compilation measurements.
The earlier recursive-carrier probe was independently accepted before broad
union implementation; its raw evidence remains in `carrier-probe/`.

## Checks actually executed

The initial generic-union fixture failed at line 1, column 16 with
`expected ':' after the union type name` and help
`use a fixed union without type parameters`.
`union-failing-before.stderr.txt` retains that parser diagnostic.
After implementation and restoring the deliberate mutation:

```sh
bin/blorp test --suite --sanitize --leak-check --timeout 180 \
  blorp_2/test/unit/test_generic_unions.brp \
  blorp_2/test/unit/test_specialize.brp blorp_2/test/unit/test_match.brp \
  blorp_2/test/unit/test_parse.brp blorp_2/test/unit/test_check.brp \
  blorp_2/test/unit/test_prelude.brp blorp_2/test/unit/test_names.brp \
  blorp_2/test/unit/test_syntax.brp blorp_2/test/unit/test_unions.brp \
  blorp_2/test/test_grammar
make -C blorp_2 test-compiler
git diff --check
```

The focused run passes 224 callbacks: 160 affected unit callbacks, including
22 generic-union and 10 specialization cases, plus 64 grammar cases. No
sanitizer errors were reported; the leak report is zero. The final independent
strict-unit and full pilot gates below validate the completed tree. The older
function-stage full gate is not claimed to validate these new tests.

Each new fixture was compiled once by the frozen pilot, collecting both cost
counters, then its unmodified C was linked with strict C11 warnings, `-O0`,
UBSan and no sanitizer recovery. Each executable ran its real `main`:

| Fixture | Allocations | Instructions | Exit |
| --- | ---: | ---: | ---: |
| generic_box | 2,091 | 34,898,507 | 7 |
| generic_union_identity | 3,430 | 38,450,494 | 7 |
| generic_phantom | 3,171 | 37,880,379 | 1 |
| generic_tagged_int | 1,961 | 34,692,644 | 7 |

All native stdout/stderr are empty and all new 20,000-allocation /
200,000,000-instruction caps pass. C inspection confirms Int payload storage
and extraction, concrete union arguments through forwarding, repeated instance
symbols, distinct phantom enum types, and no managed children for phantom
String/explicit Int payloads.

Ignoring union-key argument equality deliberately fails only the phantom
nominal/reuse callback (1/22); restored code passes. Raw mutation failure and
status are in `mutation-union-key.*`. Source fingerprints remain unchanged
through final measurements.

The inferred-binding provenance regression previously highlighted `bad` at
10:2 for `bad = box(7.to_string())`; it now highlights `box` at 10:8. Both show
the payload note at 2:6. Before/after real stderr is retained in
`unsupported-binding-box-before/after.stderr.txt`. Exact tests also protect
payload-neutral rigid constructor/pattern help and complete applied-type
names such as `P[String]` in expected-type diagnostics.

Production operator scan finds no trait/operator sugar; the three diagnostic
string joins identified in review use `concat`. The host formatter can rewrite
wrapped literal joins to `+`; those introduced joins were corrected before
freezing. An authored duplicate wildcard in an initial deep identity test
caused a host backend `#error`; removing the duplicate resolves it. The failing
source/error and exact reproduction are under `host-test-friction/`. This is
incidental host diagnostic friction, not unsupported nested equality.

A final test-only addendum adds exact prelude-checking rejection oracles for
runtime parameter `Int[String]` (bytes 66–77) and return `String[Int]` (74–85).
Both require `prelude builtin types cannot be applied` and help
`use the concrete Int or String runtime type without an argument`. Replacing
the `AppliedType` rejection with `Ok(name)` fails exactly those two callbacks
(2/29). Production was restored byte-for-byte, then a separate focused run
passed all 29 prelude callbacks with strict leak mode, ASan and UBSan:

```sh
env BLORP_LEAK_CHECK=strict bin/blorp test --suite --sanitize --leak-check \
  --timeout 180 blorp_2/test/unit/test_prelude.brp
```

`union-prelude-addendum-sanitized.log` and `mutation-prelude-applied.*` retain
those results. The earlier 224-callback run predates these two cases; it is not
claimed to include them. The refreshed source archive/manifest and LOC include
this +32 physical / +28 code test addition. Production inputs and pilot binary
are unchanged, so final native/cost evidence remains reusable. The independent
strict/full gates below include both new prelude cases.

Handwritten growth against the original post-tail baseline is +1,938 physical /
+1,639 nonblank noncomment production lines and +2,467 / +2,171 test lines.
Against the accepted function stage alone, the union slice adds +770 / +671
production and +914 / +824 test lines. The feature adds explicit type syntax,
source provenance and concrete union instance construction; no cache, registry,
host fix, target-runtime change or alternate fixture entrypoint was added.

## Final independent review and validation

Independent compiler review approves the final source with zero blockers,
should-fixes or nits. The three diagnostic findings and requested coverage
additions are closed with exact oracles and restored mutation checks.
The review is retained in
[`union-review.md`](../../blorp_2/build/generics/union-review.md).

The independent test runner executed, serially:

```sh
BLORP_LEAK_CHECK=strict scripts/record-validation \
  --output blorp_2/build/generics/union-test-runner-strict -- \
  bin/blorp test --suite --sanitize --leak-check --timeout 180 blorp_2/test/unit
scripts/record-validation \
  --output blorp_2/build/generics/union-test-runner-full -- make -C blorp_2 test
```

Strict units pass **374/374**, with no sanitizer or leak failures. The fresh full
gate passes **525 reports**: 374 unit, 9 runtime C, 76 end-to-end and 64 grammar
cases, plus two wrappers (523 leaf cases). It generates and links the pilot
once. All 60 fixture cost reports pass unchanged limits. The four new native
fixtures return 7/7/1/7 with empty output; the 256-arm output remains at brace
depth 3. The rebuilt pilot C is byte-identical to the frozen candidate C.

Both validation packets record identical start/end source fingerprints and
`source_changed_during_run: false`; all 118 source/test hashes match before and
after. Host build status remains FRESH and `git diff --check` passes. The runner
also verified all 24 retained cost samples, 12 C pairs and restored mutations;
it did not repeat measurements without a discrepancy. Exact commands,
provenance, counts and limits are in
[`union-test-runner-report.md`](../../blorp_2/build/generics/union-test-runner-report.md).
