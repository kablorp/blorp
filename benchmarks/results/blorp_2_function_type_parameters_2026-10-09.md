# Pilot function type parameters

The pilot now accepts multiple function type parameters, infers a complete ordered substitution from runtime arguments, and specializes complete concrete instances. Union declarations and written union applications remain unary. No contextual return inference, solver, cache, host change, or new pipeline stage was added.

## Boundary and retained facts

The five production files changed are `syntax.brp`, `parse.brp`, `prelude.brp`, `check.brp`, and `specialize.brp`. Header syntax uses ordered written names; the union parser explicitly retains its one-parameter limit. A rigid type parameter has declaring owner and position. The checker keeps written declaration facts locally, detects duplicate names at the second declaration with the first span, and scans runtime arguments once in source order. Local optional `TypeUse` slots preserve the earliest inferred occurrence. A complete ordered substitution is published only after all parameters have candidates. Generic conflicts and missing inference retain their priority over ordinary argument mismatches.

Substitution is simultaneous: replacing a parameter returns the supplied type unchanged, preserving caller-owned rigid identities during permuted forwarding. Specialization validates owner, position, and count, then uses the entire ordered argument list in each instance key, including unused parameters. Its materialized immutable product remains the downstream authority. Explicit children retain concrete per-annotation constructor hints; a generic UFCS receiver still receives no hint. Expected return types do not infer missing parameters.

Malformed list diagnostics now describe lists. One intentional help correction changes explicit call type arguments to “omit the brackets at calls; argument types determine the type parameters”. Other unchanged-language diagnostics are preserved. README and EBNF describe these boundaries.

## Correctness evidence

The runnable preimplementation suite had exactly one failure among three callbacks: the new two-parameter program. The frozen pilot also produced the actual comma diagnostic. The fixture moved from `generic/function_parameters_second.brp` into `generic/function_parameters/second.brp`; retained TDD logs keep the original path. A strengthened same-signature baseline pair separately confirms `receiver(Number(8), 7)` succeeds while `Number(8).receiver(7)` rejects with the existing constructor diagnostic.

The final focused run passes **278 callbacks**, including 18 new semantic/renderer callbacks and all 65 grammar callbacks. All previous callbacks remain; the 16 synthesis/checking contract assertions survive one carrier-pattern migration. New tests pin three distinct parameters downstream, owner/position identity, duplicate spans, missing/result-inference behavior, error precedence, structural conflict origins, caller-ID permutation and concrete target translation, later-only instance-key differences, and exact diagnostics.

Eight temporary mutations each failed their intended oracle: annotation origin, parameter position, substitution order, later instance-key argument, terminal substitution, conflict order, earliest inference span, and duplicate wording. Exact checker/specializer bytes were restored before the final focused run.

All **68 preexisting fixture C outputs are byte-identical** to the frozen immediate baseline. Five new real-main programs pass strict C11, `-O0`, ASan/UBSan, correct exits 2/3/2/3/7, and empty sanitizer output. The saved-result case retains the second borrowed String (length 3) while caller replacements have lengths 5 and 7. Generated C retains that second argument before returning and evaluates caller operands into ordered locals. Existing caps are unchanged.

The independent runner passed **469/469 strict ASan/UBSan/leak unit callbacks** and the full `make -C blorp_2 test`: **632 leaf checks** (469 unit, 9 runtime C, 89 e2e, 65 grammar) plus two wrappers. No sanitizer, native, leak or timeout failure occurred. The e2e run generated and linked the pilot exactly once, all 73 cost rows stayed within caps, and the 256-arm stress retained brace depth 3. Compiler-expert code, test-oracle and documenter review approved with no open findings. Detailed independent reports are `test-review.md` and `code-review.md` in the evidence directory.

## Physical costs and provenance

These are owned-input compilation proxies, **not self-compilation**. Serialized `/usr/bin/time -l` runs use strict leak checking, deterministic allocations, and minimum retired instructions from three samples per row. All allocations are released. The immediate baseline is the accepted synthesis/checking pilot; the original cumulative baseline remains `da8fa4c7134e3c636fb7b67f35918f8d7cdc50b0`.

| Existing workload | Immediate allocations → candidate | Immediate instructions → candidate |
| --- | ---: | ---: |
| return_zero | 687 → 690 | 30,781,439 → 30,728,099 |
| nested_calls | 1,330 → 1,341 | 32,615,892 → 32,630,236 |
| mortal_string | 1,036 → 1,039 | 31,848,089 → 31,734,449 |
| generic_box | 2,152 → 2,190 | 34,928,998 → 35,052,688 |
| union_values | 3,634 → 3,661 | 39,096,015 → 39,084,860 |
| match_constructor_spine | 8,665 → 8,705 | 52,671,477 → 52,625,247 |

Maximum immediate increases are **1.77% allocations / 0.35% instructions**; cumulative maxima are **14.12% / 5.92%**, below investigation thresholds. New second/third/forwarding/saved-result/boxed workloads measure respectively 1,662/2,002/2,331/2,855/2,545 allocations and 33,375,835/34,316,645/35,251,325/36,720,147/35,847,460 instructions. Their syntax has no baseline counterpart.

Generated pilot C confirms managed owner-position records and substitution rows incur allocation/ARC costs; row construction grows a locally owned list through capacity checks and raw append. These costs are measured rather than hidden by model changes. Formatted production is **10,445 (+204)** physical lines; tests are **21,256 (+863)**. No coverage was deleted.

Evidence resides in `blorp_2/build/generic-expansion/function-parameters/`: baseline/final archives and manifests, `tdd*.log`, `focused-final.log`, mutation logs/restoration hashes, `native/`, `identity/`, `matched.tsv`, and `cost-summary.tsv`. `provenance.txt` identifies the FRESH host, Clang, pilot flags, binary hashes, exact commands, and inspected C regions. Existing `scripts/record-validation` packets in `validation/` retain independent gate commands and unchanged start/end source fingerprints. All 147 frozen source entries matched through both gates. This report's final results and the plan's progress checkbox were updated afterward; production and tests are unchanged.

`final/source-manifest.sha256` includes the pre-review versions of this report and the root-owned plan. `artifact-manifest.sha256` records 839 pre-gate artifacts, validated before the runner replaced its provisional report; that exact prior version is preserved at `validation/provisional-test-review.md`. Historical `pre-mutation.sha256` predates the final checker correction; script-captured originals and `mutation-restoration.txt`, matching the frozen source, establish byte-exact restoration. No host defect remains open.
