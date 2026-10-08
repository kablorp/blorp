# Record construction prerequisite for tuple storage

Status: the current candidate based on `fca8644296c7` passes the final
correctness gates and O2 fixpoint. The matched O2 comparison measures +4.25%
managed allocations and +8.00% median retired instructions. This prerequisite
establishes the shared ownership boundary; it is not a performance improvement.
This report covers shared record construction and field evaluation before typed
tuple storage. The roadmap commit is `ace0cecc6a99`. Earlier intermediate
results and the `3434c656d073` measurement are retained as historical evidence.

## Final correctness validation

A fresh O2 CLI/runtime compiler validates 540 unchanged source, header and
linked runtime inputs. Its binary hash is
`564974b609941322ba0fc388c13e2d60613ab1728ad3912222d8ac4007e756c3`.
All commands finish with exit zero, compiled workloads run serially, and
allocation ceilings remain unchanged.

| Gate | Result |
| --- | ---: |
| Selected compiler checks | 5,999/5,999 |
| Compiler Blorp, new and parity | 7,043 + 1,007 + 3,637 passed |
| Runtime | 4,781/4,781 |
| Core sanitizer | 2,569/2,569 |
| Leak | 1,231/1,231 |
| Hygiene | PASS; 3,500 identity rows, 506 magic sites, zero stale sites |
| O2 fixpoint | All three stages emit identical C |

Fixpoint C is 83,164,509 bytes, SHA256
`0d6b03fbd56f7b2929f823581abcfe2a2e1d78b166b9f5741084111b9179c16c`.
Record cancellation reports 17 allocations/17 releases and tensor cancellation
12/12 in both ordinary and ASan executions, with zero leaks. The focused matrix
passes 33/33 in ordinary and leak-check runs; the global tensor control reports
9 allocations/9 releases and meets all four generated-C expectations.

## Correctness boundary and earlier repair evidence

A checked `CoreProductBuild` carries values in written order and their storage
ordinals. It replaces record literal/construct duplication and the late
record-literal reordering pass. Product field evaluation binds every nonliteral
field to an immutable owner before ownership inference and Perceus. This
preserves evaluation order and cancellation protection across later fields.
Conditional expressions cannot safely acquire an owner by an emitter guess:
a rejected backend-only draft caused a demonstrated cancellation use-after-free.

Literal constructor trees remain static only in a global initializer. A reused
record source remains direct when its exact identity is a declared local and
no field assigns it; globals, calls and rebound locals are snapshotted first.
Checked Core replay seeds the shared binder supply below existing minted IDs
and reports exhausted counter bands instead of issuing colliding owners.

The pre-restoration focused suites pass 1,103/1,103, and Core ASan/UBSan
passes 2,527/2,527. Fresh restored reuse tests pass 74/74 and the complete
C audit passes 236/236. Expanded cancellation controls cover
fresh values, mortal globals, duplicated locals, closure captures and both
conditional result branches: 17 allocations, 17 releases, zero leaked objects
in ordinary and ASan runs. Static C controls pass 15/15. The compiled aggregate
matrix passes both measured windows with equal plain/instrumented output
hashes. Its exact name/id joins retain sensitive/neutral field decisions after
field evaluation moves them into binding RHS expressions.

The earlier selected gate passed 5,907 cases and failed nine allocation controls:
seven nested record field-take cases and two hoisted append/update cases.
Paired origin, pre-restoration and restored probes retain correct values,
balanced allocation/release counts and zero final live objects. Both prerequisite
versions reproduce the regressions: hoisted updates rise from 10 to 1,001
allocations, and affected nested cases also copy on every iteration. Field
normalization obscures the existing transfer/consume proofs. The allocation
ceilings remain unchanged.

The bounded repair follows only exact typed product-field temporary relays to
one transfer at the same ordinal, with conservative source-use and exit checks.
It preserves the later field bindings and explicit retain/release operations.
The corrected owning suite fails four positive cases against the frozen old
implementation (82/86), then passes 86/86 after the repair. All 14 retained
record allocation controls pass. Scalar probes restore hoisted updates to 10
allocations and affected nested cases to their baseline 11–20 allocations;
values remain correct and final live counts are zero. Ordinary and ASan
cancellation probes still report 17 allocations and 17 releases.

Focused generated C changes at exactly three field reads: plain retains become
the existing unique-source field-take guard. Normalized relay retains and the
matching original-owner drops remain. These focused comparisons preceded the
final validation reported above.

## Current-main integration and resolved failures

The first current-main candidate passed 5,987 selected cases and 11,677 broad cases,
and the separate Core sanitizer and leak gates passed 2,568 and 1,230 cases.
Its runtime suite failed during native C compilation before any runtime case
executes. An exact matrix control passes 33/33 on current main and fails with
the candidate. Its negative record field is normalized into a Core binding;
the boxed tensor literal writer still uses simple-expression-only boxing and
cannot emit that binding. Paired generated C and final Core retain the failure.
That first candidate did not reach fixpoint. Its runtime failure blocked
acceptance until the element-evaluation boundary was repaired.

The shared tensor literal issuer now projects ranked scalar storage before
ownership analysis. Nonliteral elements get immutable `TensorElementTemp`
bindings through the same shared frontier as product fields, before tensor
allocation. Boxed, inline-record, raw and packed literals use this boundary;
no backend cleanup or retain heuristic was added. Rank-two/rank-three,
origin-role and zero-ID sequence controls pass in the owning suite (22/22).

The matrix suite now passes 33/33. Its narrow leak check reports 12 allocations
and 12 releases, zero leaks. Current main's same workload reports 12 allocations
and 8 releases, leaking four `Ranked` objects (96 bytes): that ARC defect is
inherited. A fixed-record tensor with a negative field passed current main and
failed the first candidate, confirming a second introduced emission regression.
A raw scalar projection of a record literal failed both versions; the uniform
evaluation boundary also covers that inherited expression-emission gap.
Fresh and captured-record cancellation controls pass with zero final live
objects in ordinary and ASan runs. An additional rank-one managed tensor scalar
field-read probe still leaks two record objects and one vector (112 bytes),
with identical 6-allocation/3-release results on current main and this candidate.
That inherited ownership gap is outside this repair; these controls establish
construction behavior, not safety of every tensor field-read shape. The final
correctness reruns above include the repaired construction boundary.

The merged JSON, pipeline, traversal, reuse and product-evaluation suites pass
377 tests before the final sparse-update repair. All 14 unchanged allocation
controls then pass with the repaired compiler. The expanded reuse suite passes
93/93, against 91/93 on the implementation before that repair; both intended
positive regressions fail before the change.

Sparse authored updates stage the dictionary replacement before the spelling
list replacement in the name-table control. Perceus wraps the remaining result
of each stage in a typed result binding. Product-field normalization obscured
the transfer proof through these frames: values remained correct and releases
balanced, but dictionary COW allocated on every iteration, increasing the
control from current-main's 11 allocations to 1,010.

The bounded repair follows exact immutable `DropTemp` identity-return frames
and safe `RecordUpdateTemp` prefixes. Alias relays still require the explicit
`ProductFieldTemp` origin. Source-slot reads, owner writes, resource scopes and
early exits reject the proof. It preserves every binding, evaluation and
explicit ownership operation. The control returns to 11 allocations with all
value checks true and zero final live objects. Ordinary and sanitized
cancellation controls each report 17 allocations and 17 releases.

The repair changes generated C at exactly one line: the dictionary's plain
retain becomes the existing unique-parent field-take guard. Its later field
evaluations, result wrappers, spelling-list take, terminal record reuse and
cleanup remain byte-identical. This focused comparison is separate from the
current common-source C comparison below.

## Current matched cost

Both baseline and candidate stage-2 compilers compile the same frozen
`fca8644296c7` compiler source and standard library. Compiler bodies and native
runtimes use `-O2`, Apple Clang 21.0.0, and identical mode-specific runtime
objects. Normal and diagnostic executables share each side's compiled body.
Two instruction samples per side run serially; all frozen workload hashes stay
unchanged. The measurement tool's `lock` command is a passthrough, so team
serialization does not establish a machine-exclusive measurement. Other app
work was not forced idle, and no wall-time speed claim is made.

| Metric | Baseline | Record prerequisite | Change |
| --- | ---: | ---: | ---: |
| Managed allocations | 249,581,197 | 260,182,197 | +4.25% |
| Retired instructions, minimum | 232,955,497,215 | 251,570,929,454 | +7.99% |
| Retired instructions, median | 233,022,054,860 | 251,660,264,159.5 | +8.00% |
| Peak RSS, bytes | 2,218,786,816 | 2,290,417,664 | +3.23% |
| Generated C, bytes | 84,352,176 | 85,070,434 | +0.85% |

The candidate's product-evaluation pass allocates 4,453,419 objects. Perceus
allocations rise from 58,025,837 to 61,462,315; cancellation planning rises
from 10,833,636 to 12,269,474. Final typed tuple storage needs its own matched
measurement. These measured construction costs are retained for optimization
work with the same cancellation, field-take, static and reuse controls.

The first current-main experiment is rejected: the baseline body used the
Makefile's default `-O0` while the candidate used `-O2`. Its raw JSON was
preserved with the original labels, and the unsupported supplemental O2
baseline claim was corrected. The replacement baseline has captured actual
compile/link arguments at `-O2` and matching normal/diagnostic version stamps.
Its generated compiler C is identical to the earlier baseline C; only body
optimization changes. The valid comparison above replaces that experiment.

## Earlier measured cost

These measurements describe the implementation before the field-transfer
repair; they are retained intermediate evidence, not final acceptance results.

The matched workload is the frozen compiler source at `3434c656d073` and its
standard library, compiled by separately built baseline and candidate stage-2
compilers. Both use Apple Clang 21.0.0, CLI/runtime `-O2`, equal runtime object
hashes, and separate normal/diagnostic executables. The two instruction samples
per side are serialized; other independent app tasks were not forced idle.
There is no wall-time speed claim.

| Metric | Baseline | Record prerequisite | Change |
| --- | ---: | ---: | ---: |
| Managed allocations | 251,245,327 | 261,061,171 | +3.91% |
| Retired instructions, minimum | 236,513,375,102 | 256,665,952,484 | +8.52% |
| Retired instructions, median | 236,618,752,892.5 | 256,899,120,370 | +8.57% |
| Peak RSS, bytes | 2,233,892,864 | 2,306,490,368 | +3.25% |

Product evaluation accounts for 4,453,105 allocations in the candidate.
Perceus allocation increases from 58,027,201 to 61,461,490, and cancellation
planning from 10,845,021 to 12,283,390. These are measured costs of the
prerequisite, not a claim about the later tuple storage improvement.

These are the restored implementation's measurements. The provenance manifest
also retains the earlier pre-restoration pair separately. Late record reuse now
descends through immutable bindings with the explicit product-field temporary
origin, preserving each RHS and written order, and transfers the dropped source
only at the terminal compatible constructor. Source writes, resource scopes,
and early exits reject this optimization. The old `3434c656d073` compiler also
failed the new literal-reuse C expectation; preserving that optimization is a
property of this construction slice, rather than an established main regression.

The measured cost does not justify weakening the ownership boundary
that prevents the demonstrated cancellation failure. Optimization is a separate
bounded pilot with the same conditional, static, reused and borrowed-owner
controls. Typed tuple storage must receive its own final matched measurement.

[Provenance](tuple-record-construction-provenance.json) joins binary, compiler
C, generator and source hashes. The raw measurement tool records explicitly
supplied binaries outside a checkout as `compiler_rev=unknown`,
`compiler_stage=1`, with no stage-2 generator hash; those fields are a limitation
of this invocation, not evidence that the binaries came from the bootstrap.
The paired build logs and `compiled_by: self-...` fingerprints establish their
actual stage-2 construction. The manifest preserves that distinction without
rewriting the raw records.

## Current common-source C review

The current main generator and the candidate generator compile the same
candidate compiler source into 82,410,983 and 83,164,509 bytes (+753,526).
This common-source comparison attributes emission differences; it is separate
from the matched performance workload. The lexical census finds 32,181
functions in each output, 5,579 changed and 26,602 identical, with zero
prototype differences. Authentic final Core metadata identifies 5,572 changed
bodies exactly, six callback symbols as three source-lambda encounter
permutations, and one body as global initialization. Outside function bodies,
the only change is relocation of a static closure declaration and initializer
to its matching callback symbol. The six renamed bodies are identical after
substituting their callback symbol. All 5,572 stable source bodies retain equal
functional call counts; 5,543 retain call order and 29 retain the same call
multiset. ARC text changes in 3,221 bodies. Reviewed borrowed-helper contracts
have matching caller retain/drop changes, and global initialization preserves
all 202 target assignments and 2,633 literal references. This evidence, the
ownership gates and fixpoint support the construction change; they do not
claim that every changed body was manually proved safe.

The fresh aggregate benchmark now supplies exact declared field identities to
sparse updates and COW fields; the old synthetic JSON was rejected before
measurement. Plain and instrumented Core match in both direct and prepared
windows. Each measures 46 aggregate visits, 32 original roots reused and 14
rebuilt. The earlier 30/16 split changes because a fourth operand family,
boxed tensor literal elements, now moves ownership protection into an ordinary
binding before Perceus. Each of the two sensitive tensor roots therefore keeps
its terminal construction while the binding protects its transferred owner.

## Earlier C and compiler-source impact

For one common compiler input, the old and new stage-1 generators emit
82,347,321 and 82,921,257 bytes respectively (+573,936). A lexical function
census finds 32,155 bodies in each output: 5,571 changed and 26,584 identical,
with identical prototypes. Every changed source function is joined to its
actual Core identity; the remaining changed body is global initialization.
Case-safe artifact hashes identify bodies because mixed-case C symbols can
collide as filenames on the host filesystem.

Changes include explicit field-owner temporaries and substantive borrow,
retain, transfer and cleanup changes. The pre-restoration ownership review
traced matching caller/callee behavior in traversal, linear contract scheduling,
mutable assignment stabilization, closure conversion and discovery projection.
New field owners account for balanced additional retain/release operations;
helpers that now borrow input aggregates have matching removal of argument
transfers and cleanup in their owning callers. Three lambda encounter-order
swaps preserve the callbacks' actual Core identities and closure roles.
Restoration-specific review confirms compatible terminal construction replaces
`make` plus source release with `reuse(source, fields)`. Existing unique-field
takes clear the old field; shared-source paths retain it. The reuse helper either
destroys remaining old fields and overwrites all ordinals, or allocates fresh and
releases the shared source. The refreshed callback identity correspondence still
consists of the same three permutations. These sampled traces and
equal prototypes do not replace the ownership-sensitive gates or claim that
every changed body was manually inspected.

The prerequisite splits heterogeneous loop payload alternatives in ownership
contracts, the scalar Perceus walker and late invariants. Restoring the old
ownership/scalar groups in independent source mirrors does not fail the current
loop control: all three mirrors pass. That control has therefore not established
those sites as live-wrong; reachability and payload-layout evidence remain
separate from the successful regression tests. The measured loop walker emits
correct named `iterable` and `body` member reads in both generators. Foreign
pointer ABI exposure preserves those member names and can mask the first
alternative's ordinal in this checkout. This is an inference from the source
contracts and paired C, rather than a dumped-Core proof of the old pattern.
The same-layout concurrent-loop split does not imply a field-layout correction.
