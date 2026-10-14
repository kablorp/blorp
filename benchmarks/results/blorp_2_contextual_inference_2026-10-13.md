# Contextual generic-call inference

Status: implementation, matched measurements, two independent expert reviews
and the combined live branch gate pass. This is one frontend
increment of the [roadmap](../../blorp_2/ROADMAP.md), not bootstrap readiness.

## Accepted facts and local inference

Argument constraints precede declared result constraints. Nested calls can use
later sibling evidence. A known nominal union head supplies constructor context,
including a uniquely resolved UFCS receiver; overloaded methods still require
receiver-based selection. Repeated parameter projections merge compatible
nominal guidance without binding inference variables. Caller-owned type
parameters remain rigid. New bindings, match scrutinees and discarded Void tails
receive no containing-function result context.

One expression-local work loop owns fresh variables and local work/operand
builders. Pending operations use immutable reverse links, extended in constant
time and frozen in source order. Closed calls validate immediately when possible;
deferred descendants retain child-first diagnostic ordering. Publication exposes
complete checked substitutions or typed errors with stable source origins.
No temporary solver identity enters the checked program or public diagnostics.

## Validation and provenance

Repository host compiler SHA256:
`286a1720a36a75599f910e1b8ab838df642a3983409cd30ed3a6ef3dcf16ba79`.
The isolated final checker is
`4ef2ba6540e5d9d78f8a225f3c4b0f3afa7f02093c4f780047876ccf8fb2e226`;
source archive
`1c8d8d6884d49fb485b9e367e8d5e42a789f05fb308a9d3b192452532fed159e`;
diagnostic pilot binary
`e58a8e35ab7efe6004ec0269dd515e599e7b892480515d384657e38f46564bed`;
generated host C
`79af560f41fa32c4cabc6f4fc9d89a0eb87e5bca6a600b313e5e0c077302e7be`.
Apple Clang 21 builds use O0 and memory diagnostics. The isolated ownership and
emission files exclude concurrent owned-prefix changes.

Ignored local evidence is in repository-root `build/roadmap/contextual/`:

| Check | Result and packet |
| --- | --- |
| Initial new positive/control tests | Seven expected failures and three passing controls, `red/`. |
| Repeated nominal-head regression | Six of eight new controls fail before repair, `merge-red/`. |
| Final admission-priority regression | Exactly three new callbacks fail on the previous checker; 40 controls pass, `list-admission-red-43/`. |
| Final focused suites | 138 callbacks pass, `list-admission-focused/`. |
| Final whole frozen unit inventory | 1,559 callbacks in 100 suites pass, `list-admission-unit/`. |
| Matched five-compiler measurement | 300 strict zero-leak compilations; all 20 generated C outputs identical across samples and compilers, `scaling/list-admission/`. |

Forty-three direct contextual tests assert complete substitutions and exact errors,
including rigid/fresh separation, independent calls, structural occurs failures,
partial nominal heads, source-first origins, phantom ambiguity, nested error
priority, substituted annotations and List/Box shapes. Six normal-main native
fixtures are registered and pass the final combined branch run. Earlier native
packets remain separately labeled because they predate the private repairs.

Final review exposed an error-priority regression: a closed generic call checked
purity or mismatches before admitting substituted List types. A source-directed
signature traversal now admits parameters in declaration order, then the result,
then checks purity and ordinary mismatches. One local parameter vector is reused;
complete substitutions remain terminal. A shared helper preserves the existing
List rule without restricting diagnostic/occurs snapshots. The three regressions
pin exact kinds, spans, messages and help; six normal CLI diagnostic compilations
also confirm the old/new competing errors, with strict zero leaks.

## Measured repairs and remaining costs

The first draft eagerly decomposed and reconstructed already complete compound
types. The repair retains those accepted subtrees, opens one structural level
only where comparison or hints require it, and rebuilds annotations when actual
substitution changes them. Closed calls reuse the complete return type already
computed by argument validation. No cache or second semantic authority was added.
Generated host C shows local solver/vector mutation without retained growing
prefixes at setters. The rejected recursive-state and operation-vector COW
implementations remain as diagnostic artifacts, not alternate compiler paths.

Three interleaved samples compare the same inputs, frozen library path and
toolchain using pre-feature `9aa053`, semantic draft `da51937`, first repair,
closed-result repair and final admission repair. Minimum retired instructions
are primary; medians are retained
separately. The targets, established before repair, require removal of at least
75% of the feature's excess allocations and instructions for both dimensions.

| Workload | Pre-feature / draft / final allocations | Pre-feature / draft / final minimum instructions | Excess removed, allocations / instructions |
| --- | --- | --- | --- |
| Constructor depth 64 | 47,514 / 91,008 / 49,598 | 188,805,981 / 289,909,148 / 194,215,614 | 95.2% / 94.6% |
| Constructor depth 128 | 130,242 / 299,051 / 134,313 | 631,922,282 / 1,024,298,244 / 644,730,697 | 97.6% / 96.7% |
| Nested-call depth 64 | 82,314 / 120,766 / 88,123 | 303,257,696 / 406,077,121 / 316,978,640 | 84.9% / 86.7% |
| Nested-call depth 128 | 244,887 / 387,213 / 256,394 | 1,179,595,224 / 1,566,729,376 / 1,208,117,544 | 91.9% / 92.6% |

Unaffected controls change by at most +0.92% minimum instructions and +1.38%
allocations against the semantic draft, within the 3% ceilings. The admission
repair itself adds at most 1.39% allocations and 1.07% minimum instructions over
the closed-result repair. Costs against
the pre-feature compiler remain higher. At size 128, allocations/instructions
increase 3.13%/2.03% for constructors, 4.70%/2.42% for nested calls,
7.00%/3.73% for fields, 15.71%/6.90% for wide calls and 40.76%/22.08% for UFCS.
These proxy workloads do not establish self-compilation performance or overall
linear complexity. Existing signature, specialization-key and output growth
remain visible. Earlier samples with a different library-root path are preserved
separately; no offset was subtracted to make them comparable.

Handwritten growth against the frozen first-record slice is +1,210 physical
production lines (+933 excluding blank/comment-only lines) and +1,133 test lines
(+973 active). This is feature growth, not a source-size reduction claim.
Exact manifests, raw samples, commands, C excerpts and limitations are linked
from `build/roadmap/contextual/HANDBACK.md`.

Combined live integration passes 1,800 unit/runtime/grammar printed checks across
115 suites and 275 normal-main end-to-end cases, with no source drift. Standard
packets and preserved source/compiler artifacts are under repository-root
`build/roadmap/integrated-20261013/`. Its compiler SHA256 is
`370bb7b4cb406d2c7008fc721e7a5554d077776299d0ca70f596f213722ebcad`;
it includes the independently reviewed owned-prefix changes as well.
