# Scalar constant boundary — 2026-10-18

Status: **accepted for landing**. Independent code/resource reviews and all
functional gates pass. The separately reviewed
[plan](../../blorp_2/SCALAR_CONSTANT_BOUNDARY_PLAN.md) is commit `7a78a9c9d`;
fixed B is `355d050a8fcab68508c48ec3d596ad922c9d8280`.

## Change and scope

Check projects an accepted scalar constant at its existing direct/qualified
lookup into an existing Int, Float or String literal leaf. The successful
checked product no longer carries `ReadConstant` or a constant table. Specialize
loses its duplicate lookup and nine threaded constant parameters. Checker-local
declaration IDs/rows, annotation/initializer validation, imports/privacy and
constant-called diagnostics remain unchanged. Existing occurrence spans, including
the inner base under grouping and full qualified base, remain authoritative.

Six production modules change: **43 ADD / 60 DEL, net −17**. Test owners change
**105 ADD / 44 DEL, net +61**; the one new ordinary native fixture is **18 lines**.
Documentation is separate. No Lower/Own/Verify/Emit production change, evaluator,
pool, runtime global or other audit finding is included. Deferred aggregate/
reference constant designs remain documented separately from current scalars.
Production patch SHA256:
`822e3d1c30f47b1577144abb96ea4e58b7f406be3d1cf345e5c431c82a201ff5`.

## Original frozen epoch: correctness and identity

The checker representation oracle compiles on B and yields **6 FAIL / 1 PASS**:
six reads still publish references, while the existing UFCS rejection control
passes. Candidate focused phase suites pass **30/30**, covering scalar values,
decoded UTF-8/NUL and raw String bytes, grouped Int endpoints, qualified reads,
exact diagnostics, generic instances, per-use value identities and owners/drops.

Replacing the String projection with an empty String gives **4 FAIL / 7 PASS**
across 11 checks, including decoded/raw bytes and both generic instances. Exact
file restoration returns **11/11 PASS** and the original production patch hash.
The first candidate invocation stopped at an indentation error in the new test;
that setup failure was fixed before these results and is not semantic RED or
mutation evidence.

All **495 frozen fixture roots / 990 normal CLI calls** (399 successful C outputs
and 96 matching diagnostic failures per producer) agree exactly on exit
status, stdout, stderr, C presence and successful C bytes. This includes the new
`constant/managed_generic.brp`, supported by both compilers. Its normal main
reads a UTF-8/NUL String twice in each Int/Float generic instance and prints
exact bytes plus `-0` for a negative-zero constant, through the existing harness.
Existing alias/reassignment, independent-owner/drop and unused-emission tests
remain intact. Native stdout alone does not prove unused constants allocate zero.

Full components: **3,516 PASS / 0 FAIL**. Tooling: **7 PASS / 0 FAIL**.
Native: **1,093 PASS / 0 FAIL** (493 fixture/group callbacks, 599 nested native
checks and one umbrella). Every gate exits zero with empty stderr and all 1,007
pins unchanged. All 401 compiler-cost rows have positive required counters within
that epoch's unchanged caps and strict zero accounting; target native C keeps C11/O0 with
ASan/UBSan. Focused/mutation counts overlap these gates; do not add them to claim
unique coverage.

## Original frozen epoch: matched costs

One diagnostic sample and three serial normal samples per producer/input use
fixed source/library/output paths. Normal order is B1,C1,C2,B2,B3,C3; no original
sample was discarded or replaced. Allocation is the unique schema-1 cumulative
`artifact_construction_complete` checkpoint for source construction, and positive
balanced strict totals with zero live objects/bytes for pilot fixture compilation.
Instructions are original normal min3; peak RSS is original normal median3.

| Input | Allocations B → C | Instructions B → C | Median RSS change |
| --- | ---: | ---: | ---: |
| proxy | 25,539,404 → 25,518,069 (-0.084%) | 46,824,818,989 → 46,773,824,860 (-0.109%) | -1,097,728 B (-0.437%) |
| constant/integer.brp | 9,130 → 9,129 (-0.011%) | 35,776,547 → 35,812,482 (+0.100%) | +32,768 B (+0.664%) |
| constant/float.brp | 10,706 → 10,705 (-0.009%) | 38,555,417 → 38,515,207 (-0.104%) | -16,384 B (-0.313%) |
| constant/pipe.brp | 10,294 → 10,293 (-0.010%) | 37,855,841 → 37,869,793 (+0.037%) | +16,384 B (+0.315%) |
| constant/aliases.brp | 11,278 → 11,275 (-0.027%) | 39,231,334 → 39,167,715 (-0.162%) | +16,384 B (+0.315%) |
| constant/managed_generic.brp | 13,787 → 13,784 (-0.022%) | 43,043,526 → 43,047,435 (+0.009%) | +16,384 B (+0.310%) |
| generic/named/managed.brp | 22,918 → 22,918 (+0.000%) | 54,615,779 → 54,475,074 (-0.258%) | -49,152 B (-0.877%) |

The whole construction proxy saves **21,335 allocations (0.084%)** and
**50,994,129 min3 instructions (0.109%)**; sampled normal median peak RSS is
**1,072 KiB lower (0.437%)**. These are modest observations, not a material
elapsed-speedup claim. Targeted movements are mixed: allocations fall by one or
three objects for each constant control and remain unchanged for the nonconstant
control; instructions range from −0.258% to +0.100%, RSS from −0.877% to +0.664%.
Every value stays below the prospective attention/hard thresholds and that epoch's unchanged
native caps. No repeat or exception is needed. Acceptance uses overall direction,
as the user requested, rather than requiring every individual metric to decline.

The single instrumented host artifact checkpoint records current objects
1,433,809 → 1,432,527 and managed allocator bytes 120,620,240 → 120,563,136.
These are construction-checkpoint observations, separate from normal RSS.
The host construction proxy omits linking, target self-compilation and unavailable
target self-compilation liveness measurements. Removing a transported table does
not establish early physical retirement of its String bytes: checked literal
occurrences and existing parsed/phase roots can still retain immutable data.

## Provenance, C inspection and review

All 41 B source hashes match the accepted F1 candidate, permitting reuse of its
same-C pilot pair: B normal `a197b6a6` / diagnostic `b3e84543`, C SHA `0bff8c81`.
Candidate normal `405899c2` / diagnostic `e0c27424` link once from unmodified C
SHA `9dbcc103` at `-O0`, diagnostics=0/1, `-lm -lpthread`, Apple clang21.
Both links retain 90 inherited warnings in the same three classes. The FRESH
repository host is `97479b34`; paired construction hosts are `6852e1c6` /
`a362b0df`. Host library 91 files and target library 12 files match frozen pins.

Generated compiler C shows the checked product losing its constant-list field
and corresponding release. Fixture emissions are byte-identical across roles
and each normal/diagnostic sample. The new fixture uses ordinary separate String
materialization/concatenation and generic static calls; no pooled runtime owner
or alternative fixture entrypoint is introduced.

The original raw evidence is under ignored
`build/scalar-constant-boundary-2026-10-18/` in the implementation worktree:
BASELINE/INPUT/SOURCE_FREEZE, per-command/raw sample files, COSTS, IDENTITY,
MUTATION, compiler artifacts and independent review receipts. Prior artifacts are
reused only after source/tool/library checks; all original F2 measurements were
fresh against fixed B.

## Main integration: separate target input epoch

Main advanced to `cf41b4a6f53a39195ab78fd89f4191142b91de2a` during validation.
Its List API change modifies the target library, fixtures and native cost caps.
All 41 compiler source files and the host library/toolchain are unchanged from
fixed B; the squash-composed compiler sources exactly match reviewed candidate
`480e2d8edd5c671462ca00a33a91d66a5af0d75c`. The original epoch remains intact.
The source-to-C construction proxy above remains valid because its B/C compiler
sources and host inputs are identical; it does not consume the target library.

A separate `target-integration-01` freeze uses the current 12-file target library
and all **496 fixture roots**. Both existing pilot pairs are source-matched,
so they need no rebuild or relink. All **496 pairs / 992 normal CLI calls** agree
on status, stdout, stderr, C presence and successful C bytes: **400 successful
C outputs and 96 diagnostic failures** per producer. The six control comparisons
are fresh, using the original serial sampling order and aggregation rules.

| Input | Allocations B → C | Instructions B → C | Median RSS change |
| --- | ---: | ---: | ---: |
| constant/integer.brp | 10,443 → 10,442 (-0.010%) | 37,846,096 → 37,847,397 (+0.003%) | -16,384 B (-0.311%) |
| constant/float.brp | 12,019 → 12,018 (-0.008%) | 40,480,419 → 40,481,844 (+0.004%) | 0 B (0.000%) |
| constant/pipe.brp | 11,607 → 11,606 (-0.009%) | 40,044,682 → 40,048,719 (+0.010%) | -32,768 B (-0.606%) |
| constant/aliases.brp | 12,660 → 12,657 (-0.024%) | 41,339,922 → 41,328,614 (-0.027%) | -16,384 B (-0.302%) |
| constant/managed_generic.brp | 15,100 → 15,097 (-0.020%) | 44,782,899 → 44,763,727 (-0.043%) | -32,768 B (-0.595%) |
| generic/named/managed.brp | 24,231 → 24,231 (0.000%) | 56,283,802 → 56,320,852 (+0.066%) | -49,152 B (-0.862%) |

These target comparisons stay below the plan's attention and hard ceilings.
They use a new target-input epoch; they do not replace any original sample or
roll the construction baseline forward. Integration gates use cf41's inherited
caps, which this F2 change does not alter.

Fresh primary-checkout gates pass: **3,516 components**, **7 tooling**, and
**1,095 native checks** (494 fixture/group callbacks, 600 nested checks and one
umbrella), all with **zero failures**, exit zero and empty stderr. All **402**
native compiler-cost rows have positive required counters within cf41's inherited
caps and strict zero accounting; sanitizer settings remain C11/O0 with
ASan/UBSan. All **1,009** before/after pins agree for each gate. Integration
receipt SHA256:
`b85cb8533318a725eb28e17ebc466d82bf0e161ab071e0b83854e6074227f9f3`.

The primary checkout retains a hash-verified copy of all original evidence plus
the separate integration freeze, costs, identity and gate receipts under ignored
`build/bootstrap-evidence/scalar-constant-boundary-2026-10-18/`.

Both reviewers approved the separate plan, final implementation/resource
direction and composed-tree validation. Final code-reviewer and test-runner
publication checks cover the staged report and the integration receipt. No
functional or cost concern remains; no measurement exception is required.
