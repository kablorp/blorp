# Blorp 2 validated namespace publication

This records Part B of the [authority plan](blorp_2_authority_fixes_2026-10-13.md).
The baseline is `e59346426d42f39d139408f44a4b030f695028b8`, incorporating main
`4dcb0d20a6bb81ed2dd038332cfc82eac3810196`. The component is implemented and
independently reviewed. Namespace and combined build/test/cost gates pass below;
Independent final receipt review approved with zero findings; rebasing onto
current main is structurally validated and its fresh gates pass in the
[rebase receipt](blorp_2_main_rebase_2026-10-14.md). Lowering is
outside namespace-only attribution; the final branch receipt includes it.

Previously, `build_namespace` published an opaque Namespace containing import
problems. Checking revalidated declaration and visibility uniqueness, and could
report an invalid annotation before a duplicate declaration:

```blorp
pure func answer(value: Missing) -> Int:
    1
pure func answer() -> Int:
    2
func main() -> Int:
    0
```

The baseline reports `unknown type` at 1:25, with help: `declare or import this
type; builtin types and declared type parameters are also available`.
The candidate reports `duplicate function name` at 3:11, with help: `give every
function a distinct name`. The exact typed error is
`SignatureRejection(DuplicateFunction(answerNameId, previousSpan))`; tests match
the NameId against the parser's name inventory and assert current root-source
span `[57,63)`, previous root-source span `[10,16)`, and no diagnostic note.
The genuine baseline run of the function, union and record priority controls
was **0 passed, 3 failed** (`namespace/red-behavior.*`); CLI reproductions also
pin each baseline UnknownType diagnostic. Setup failures are separate evidence.

The new boundary publishes either complete scope facts or a nonempty typed
failure:

```blorp
fixed record NamespaceFailure {
    first: NamespaceProblem,
    remaining: List[NamespaceProblem]
}

pure func build_namespace(program: ParsedProgram) -> Result[Namespace, NamespaceFailure]
```

The private builder expands prelude functions, constructors and methods before
validation. Only an empty problem collection seals a Namespace; successful
contents have no problems field. Local function, visible function and type
lookups return Option identities. Constructor candidates remain a collection:
distinct union owners may share a constructor spelling. Issued declaration IDs
are carried unchanged. Checking maps namespace faults into its existing typed
diagnostics without revalidating scope or rebuilding direct-call visibility.
Annotations, accepted signatures and type-directed receiver/constructor decisions
remain checker-owned.

Diagnostic order is foundation checking, import-selection problems, constructor
import clashes, function import clashes, local nominal/variant order, then local
function inventory order. Namespace clashes precede annotations and bodies.
Producer tests assert remaining-problem ordering; checking reports the first.
Private VariantBinding records the original issued declaration span once and
preserves it through forwarding and prelude exposure. Named function exposure
promotes a same-ID diagnostic origin; method-only exposure retains that origin.
These tests use real assembly and issued rows. The receiver self-edge control
does not alter the loader's rejection of cyclic imports, including self-imports.

Production changes span nine files: **+290/−441, net −151 lines**. Five existing
test readers contribute net +151; the new publication suite contributes 473,
for **net +624 test lines**. All 109 prior owning callbacks remain; 15 publication
controls and one separate valid-namespace UnknownType control add **16 callbacks**.
The six owning suites contain **125 callbacks**. See
[publication tests](../../blorp_2/test/unit/test_namespace_publication.brp),
[namespace producer](../../blorp_2/src/namespace.brp), and
[diagnostic adapter](../../blorp_2/src/check_imports.brp).

Evidence paths below are relative to `build/next-increments-20261014/`:

| Check | Retained result | Evidence / remaining action |
| --- | --- | --- |
| Initial priority controls | 0 passed, 3 failed before production | `namespace/red-behavior.stdout.log` |
| Preliminary owning suites | 89 passed | `namespace/preliminary-unit-3.stdout.log` |
| Final publication / module checking | 15 / 24 passed | `namespace/final-focused-3.stdout.log` |
| Final type-import reader | 27 passed after exact offset correction | `namespace/final-type-import.stdout.log` |
| Duplicate-producer mutation | 12 passed, 3 failed | `namespace/mutation-duplicate.stdout.log` |
| Declaration-span corruption | 13 passed, 2 failed | `namespace/mutation-origin-span.stdout.log` |
| Method-origin corruption | 13 passed, 2 failed | `namespace/mutation-method-origin.stdout.log` |
| Preliminary broad unit/runtime/grammar | 2092 passed, 1 failed | `namespace/broad-unit.stdout.log`; old priority oracle corrected |
| Restored final unit/runtime/grammar | 2106 passed, 0 failed in 138 suites; exit 0 | `namespace/final-broad.stdout.log`; empty stderr |
| Combined `make -C blorp_2 test` | Exit 0; 2109 unit/runtime/grammar passed, 0 failed in 138 suites | `final-pilot.stdout.log` and `final-pilot.stderr.log` |
| Required e2e on combined sources | 325 passed, 0 failed | `final-pilot.stdout.log` |
| Combined native cost / C / balance | 36 inputs, 216 samples; all per-input costs within +3% | `combined-cli.stdout.json`; details below |
| Final receipt review | **Approved, zero findings** | Independent compiler-expert source and evidence review |
| Current-main rebase | **Fresh gates pass** | [Preservation and matched validation](blorp_2_main_rebase_2026-10-14.md) |

The final-focused run's one type-import failure was a newly strengthened oracle
using `[18,21)` for the prelude's Int exposure. The literal prefix
`import:\n    _base: ` is 19 ASCII bytes; the corrected assertion pins `[19,22)`
and all 27 callbacks pass. Earlier footer discovery, indentation, reserved-binder
and missing-import setup errors did not execute behavior assertions. Each native
mutation was restored to exact snapshot source bytes; the final 15-path manifest
has no drift. The final broad run executes all 125 owning callbacks after the
namespace and method-origin sources were restored, with the unchanged baseline
lowering source. Its stderr is zero bytes. The later combined Make run builds the
pilot once and passes all 325 e2e cases; its unit prefix has 2109 callbacks in
138 suites. The additional three callbacks belong to the final lowering slice.
Independent compiler-expert review (`compiler_increment_review`) reports **0
findings**, approving source, tests and the README/ROADMAP contract updates.

The namespace-only cost comparison uses 36 frozen valid inputs and **216
alternating samples**, three runs of each native compiler per input. Per-input
allocations are deterministic; retired-instruction comparisons use each
compiler's minimum sample. Maximum allocation increase is **+0.270257%**
(`fields-128`, 61,423 → 61,589); maximum minimum-instruction increase is
**+0.458624%** (`fields-int-32`, 67,325,999 → 67,634,772). Both satisfy the +3%
component ceiling. All target C hashes match and strict process allocation /
release balance passes. These are owned-input CLI proxies; pilot self-compilation
is unsupported, and no self-compile performance claim is made.

The final namespace-plus-lowering branch comparison also passes: 36 frozen inputs,
216 alternating samples, identical target C and strict process balance. Maximum
allocation increase is **+0.299562%**; the maximum minimum-instruction delta is
**−0.059467%**, with every input within the +3% ceiling. This receipt supports
combined branch acceptance, not attribution to namespace publication. Its raw
samples and summary are in `build/authority-fixes/next-preparations-combined-20261014/`; its compact result is
`build/next-increments-20261014/combined-cli.stdout.json`. The separate namespace
measurements above remain the component evidence.

Raw evidence is `build/authority-fixes/namespace-publication-20261014/samples.json`,
its `summary.json`, and `namespace/cli-candidate.stdout.json`. Native flags are
`-O0 -DBLORP_MEMORY_DIAGNOSTICS=1`, linked with `-lm -lpthread`. The common host is
FRESH, Apple clang 21.0.0 on aarch64-apple-darwin, with host CLI -O0/runtime -O2;
its recorded build label is `c7290b5ffa7a-dirty`. Baseline provenance explicitly
reuses the reviewed `build/main-sync-20261014/provenance.json` native receipt.
Candidate linking succeeds with **53 warnings**: 3 discard-qualifier, 41 parentheses-equality
and 9 pointer-integer-compare, retained in `namespace/compiler-link.stderr.log`.
No baseline warning-category comparison is claimed.

| Artifact | SHA-256 |
| --- | --- |
| Common host `bin/blorp` | `92d1e10d88bd1048d101a9864528695e4c34de6251435ab1c4e6c68ac743b30b` |
| Baseline native compiler | `e6ac8ab7d079670fbceac2eaefb1abd04f1010e7e7230dfb561caf0305d1a4e1` |
| Candidate native compiler | `74ea1731260446f7383e460755fce5c39ab1439a36eada021955e86ab27e9b17` |
| Baseline compiler C | `04d8f3401ec6e7bc01650916aef803ce63e26c04732628ab863f176beb78ea57` |
| Candidate compiler C | `a30c205f62f12f06a0ce064b1246892f8f57972e8107515af97c59641b00db01` |
| Final owned source/test manifest | `3e0142b27066801dcce39631d7e51557dacef08c92089d725fd358c7543c4cee` |

The manifest is `namespace/final-files.json` (nine production and six test paths);
full baseline source/host/flag provenance is `baseline/{source,provenance}.json`.
The compiler's own C differs between versions; target-program C is identical.
No cache, new accepted-semantic table or additional per-query declaration scan
was introduced. Existing declaration/import validation scans moved to their producer.
Existing forwarding costs remain; the measurements do not establish
global linearity or performance at self-compile scale.
