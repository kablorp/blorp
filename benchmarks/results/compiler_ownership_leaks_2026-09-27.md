# Compiler ownership leak investigation

Base: `04ecfd2d10a845cbc765d153239a53df83f6fb0b`.
This is a correctness investigation, not an allocator comparison. No allocator
policy or compiler pass representation is changed.

## Reproduction and phase localization

The diagnostic compiler compiling this program leaked 451 managed objects
(27,039 requested bytes) after normal teardown:

```blorp
func main(args: List[String]) -> Int:
    0
```

The larger self-compile observation was 6,793,940 remaining managed objects
after global cleanup. Its approximately 473 MB allocator in-use reading is
not an exact measurement of leaked managed bytes: it also includes allocator
size rounding and non-managed allocations.

To separate phase ownership from overlapping live roots, a diagnostic build
executed passes through a chosen cutoff, then returned ownership-correct
identity results for later passes before normal teardown. On the tiny program:

| Last executed pass | Remaining objects | Requested managed bytes |
| --- | ---: | ---: |
| `consume_specialize` | 7 | 392 |
| `static_string_literals` | 7 | 392 |
| `record_update_ownership` | 385 | 22,255 |
| `dict_literal_ownership` | 385 | 22,255 |
| `ownership_contracts` | 385 | 22,255 |
| `perceus` | 459 | 27,407 |

The seven earlier objects already appear when the late pass list is constructed;
they are not allocations left by a particular transformation. Internal pass
names are not necessarily valid CLI `--stop-after` stages. An invalid stop name
initially ran more of the pipeline than intended; those observations were
discarded in favor of the explicit cutoff diagnostic.

## Two independently reproduced defects

### Optional closure fields were not released

`nullable_managed_option_payload_release_policy` excluded `FunctionType`, even
though the nullable representation contains a managed closure pointer. The
generated `CorePass` destructor consequently omitted both optional invariant
callbacks. Seven captured closures of 56 bytes each survived pass-list teardown.

A small record containing `Option[pure (Int) -> Int]` reproduces this without
the compiler: a captured scalar leaves one closure; a captured dynamic string
leaves both the closure and its string. Regression coverage includes `Some`,
`None`, scalar and managed captures, and copied records.

### Nested matches could lose branch-specific ownership

Consumed-parameter balancing rejected a direct-owner constructor match when
one arm contained a nested literal or length discriminator. Its fallback used
the maximum consumption across branches. One consuming arm therefore hid the
release needed by a borrowing arm.

`prepare_record_update_expr` has this exact shape. Generated C transferred an
owned expression to the function, but the borrowing default path did not
release it. A scoped literal-only Core program reproduces three remaining
objects (`CoreType`, `CoreLiteral`, `CoreExpr`); a changed record-update fixture
leaves thirteen. Both new assertions fail in the ordinary pipeline suite:
52/54 passed before the fix.

The candidate balances at terminal leaves, after discriminator reads, and
carries borrowed payload bindings down to those leaves. Used managed payloads
must remain valid if the outer owner is released or consumed. Removing the
old guard alone would be unsafe.

## Candidate validation

The candidate compiler was rebuilt from the changed sources (`FRESH`, CLI and
runtime `-O2`). Its emitted test binaries pass:

- Pipeline assertions: 54/54, including both new scoped release regressions.
- Perceus IR assertions: 393/393, including nested literal and length cases.
- Nullable closure policy: 2/2.
- Optional closure runtime leak checks: 4/4.
- Nested constructor runtime leak checks: 5/5, including consuming an owner
  and then reading its borrowed payload. Before the fix, generated C released
  that owner before an unretained payload read; the candidate retains the
  payload before consumption and releases it afterward.

The stricter whole pipeline-suite leak check improves from 46 failing cases to
7 failing cases. Those remaining failures are not waived; they cluster around
record-reuse fixtures and are under separate investigation.

### Compiler's own teardown

`benchmarks/build_stage2_compiler --diagnostic-output` generated the compiler
body using the fixed compiler, then linked a diagnostic runtime. The standard
script used a single C translation unit; its inherited build stamp says split
8, so the build log, not that stamp, owns this detail. Both stages used `-O2`.

| Workload | Before objects | Candidate objects | Before bytes | Candidate bytes |
| --- | ---: | ---: | ---: | ---: |
| Tiny program, full metadata | 451 | 141 | 27,039 | 8,816 |
| Small fixture, full metadata | 4,325 | 2,978 | 278,953 | 188,497 |
| Frozen self-compile, post-global cleanup | 6,793,940 | 4,737,938 | 473,186,032 | 330,960,096 |

The first two rows report requested leaked managed bytes. The self-compile row
reports whole-process allocator in-use bytes, **not** exact leaked managed
bytes. Its runtime-only teardown observer is linked to the same fixed compiler
body; source-side lifetime pilot instrumentation is unnecessary for this final
checkpoint. Frozen input is the archived base revision, not the modified
compiler sources. The self-compile candidate performs 187,227,152 allocations
and 182,489,214 releases through global cleanup.

The fixes remove 2,056,002 remaining self-compile objects (30.3%) and reduce
allocator in-use by 142,225,936 bytes. They do **not** establish a leak-free
compiler. Further allocator tuning remains out of scope.

### Broader gates and remaining boundary

`scripts/compiler-check --changed --base main` passes 2,657/2,657 checks:
473 focused compiler checks plus 2,184 Core ASan/UBSan checks. The serial
runtime leak gate passes 986/986; the serial generated-C audit passes 221/221.
These passing gates do not supersede the
seven failures in the additional pipeline-wide leak experiment.

With the fixed stage-2 compiler, supported CLI stop boundaries through
`consume_specialize` leave zero managed objects on the tiny input. `perceus`,
`reuse`, `closure`, and `final` each leave 141 objects / 8,816 bytes. Runs
without Core-dump observation confirm the endpoints. A separate scoped
`heap_record_self_update_program()` fixture leaves zero objects through
`record_update_ownership`, `dict_literal_ownership`, and `ownership_contracts`,
then 28 objects / 1,656 bytes after Perceus. Thus the remaining defect is
inside Perceus execution, not an allocator retention policy or old Core
surviving intentionally at the sampling point. The exact unmatched ownership
operation is not yet established; no additional speculative fix is included.

Local evidence:

- `/tmp/blorp-record-update-lifetime-before-plain.log`
- `/tmp/blorp-record-update-lifetime-before.log`
- `/tmp/blorp-optional-closure-before.log`
- `/tmp/blorp-nested-constructor-before.log`
- `/tmp/minimal-cutoff-<pass>.stderr`
- `/tmp/blorp-lifetime-self-teardown.stderr`
- `/tmp/blorp-core-pipeline-after.log`
- `/tmp/blorp-core-pipeline-leak-after.log`
- `/tmp/blorp-nested-owner-perceus-suite.log`
- `/tmp/blorp-ownership-fixed-{minimal,small,self}.stderr`
- `/tmp/blorp-ownership-fixed-stage2-build.log`
- `/tmp/blorp-ownership-fixed-teardown.sha256`
- `/tmp/blorp-ownership-fix-compiler-check.log`
- `/tmp/blorp-ownership-fix-leak.log`
- `/tmp/blorp-ownership-fix-codegen-audit.log`
- `/tmp/blorp-remaining-phases-summary.log`
- `/tmp/blorp-remaining-nodump-summary.log`
- `/tmp/blorp-reuse-span-sweep.log`
