# Identity census reconciliation review, 2026-10-05

Source audited: `ff4da4b31dc2f5e0e1b9425a2ac96c06f6399a63`.
Existing baseline labels its source `d63979ecee34ab080f9991969d8f075261f675c6`
(348 commits earlier). This record proposes a new reviewed lexical starting point;
it does not declare semantic identity completion.

[Full evidence](compiler_identity_reconciliation_2026-10-05.json) records all 186
added and 193 removed exact keys, source excerpts, all 29 budget increases,
203 source hashes, capabilities, and the two newly observed rendering boundaries.
At the historical audit step the baseline was held pending source freeze and
coordinator approval; the final publication below records that separate step.

## Integration onto current main

The reviewed feature commit is `1590a2f9b`; the squash parent is
`6205aba411eb322df8a0b8e40043b53b45101965`. The four intervening main commits are
preserved. Their Perceus loop-retention change alters only `borrowed.brp` among
the 203 scanned source hashes. The lexical inventory still has 3,402 rows,
121 unchanged budgets, 859 exact keys, ten unchanged capability rows and twelve
boundaries; the installed baseline remains byte-identical. The full evidence's
`integration_snapshot` records the new hashes separately from the historical
audit and feature snapshot. Postmerge native acceptance is recorded alongside
the current-main measurements in the call-diagnostic result record.
Focused compiler checks pass 422/422; broader compiler and tooling gates pass
6,843/6,843. The final build is FRESH with CLI/runtime `-O2`. The observed matched
instruction results meet the enabling budget with the recorded nonquiet-host
caveat; generated C and all allocation checkpoints are identical.

## Exact drift

86 added/removed pairs retain path, owning function/type, category, family and
matched detail, with a changed structural fingerprint. Examples include
`resolve.brp` constructors now carrying binder origins, accepted record/union
locator representations, and backend signatures using prepared type authorities.
These are lexical correspondence, not a semantic-equivalence oracle.

The remaining additions comprise 13 Perceus protection comparisons moved from
`protect_repeated_consumes_impl` into iterative spine/node helpers, plus three new
select/concurrent shadow comparisons (`protect.brp:917`, `1640`, `1670`) that retain
name-based identity debt; 11
origin/name agreement diagnostic inventory string maps; 10 callback tables now
finding callback definitions by explicit origin while retaining string type keys;
19 synthetic-local constructor shapes; one `CoreTaskCapture.id` carrier;
13 other source comparisons, 28 string collection shapes and two inline closure
emitter projection sites split into a helper. All remain counted.
`def_id=None` is normal for local binders, including `core_question_bind_var`,
whose `id` is already nonzero; the lexical pending category is not proof of a
missing binder ID. New Perceus mutable name comparisons, alternative-pattern
canonicalization, callback type keys and name-keyed consumer catalogs remain
explicit migration debt. Diagnostic inventory maps do not prove id-only output.

107 removed keys lack a direct fingerprint pair. Source deletion/rewriting,
exact field/variant identities, prepared emission tables, and helper centralization
explain these changes; removal of a key does not prove its entire consumer family
has migrated. The evidence preserves the old source at every removed site.

Replaying the current scanner over the stated old revision yields five exact
keys absent from the checked-in baseline: two effective type-parameter maps and
three callback projection sites. The historical revision label therefore does
not describe an exact pristine inventory. Those absences are recorded separately;
they are not disguised as new compiler regressions.

## Increased exact budgets

| Family and directory | Before → current | Reviewed source cause and remaining boundary |
| --- | --- | --- |
| `CoreTaskCapture` identity fields, Core | 1 → 2 | Explicit capture ID added beside spelling; `ir.brp:2487`; legacy spelling remains. |
| `.name` predicates, lowering | 2 → 3 | Alternative-pattern canonicalization at `lower.brp:2543` still compares names. |
| `.name` predicates, Perceus | 53 → 64 | Iterative protection moves plus mutable release/tail-call/select comparisons; name fallback remains. |
| `def_id=None`, lowering | 1 → 2 | Question-bind producer at `lower.brp:1492` has a nonzero source-derived binder ID; local definition absence remains normal. |
| `Dict[String]`, Core | 164 → 180 | Origin diagnostics, callback type-key indexes, record-update/closure carriers and signatures; key purpose needs typed per-consumer oracles. |
| `Dict[String]`, Perceus | 23 → 25 | Combined shadow/body catalogs and let alias source catalog; compatibility name keys remain. |
| `Set[String]`, typecheck graph | 1 → 2 | Exported source-name demand set in `definition_index.brp:162`; source resolution boundary. |
| `Set[String]`, type system | 0 → 5 | Accepted fieldless-enum evidence/shadow removal and scope snapshot; enum spelling evidence remains. |
| `Set[String]`, Core | 31 → 33 | Consuming clone record-type set plus associated state; string type keys remain. |
| `Set[String]`, backend | 10 → 11 | Record-layout unresolved type sets/signatures; lexical shape remains, not a semantic key proof. |

The other 19 increases are heuristic: ten member-read budgets (`name`, `id`,
`def_id`) and nine sparse-option carrier budgets. New origin/capture/carrier
plumbing, frontend authority work, Perceus walk/catalog changes and tuple
flattening explain source growth. The full artifact provides changed source
rows per budget. Receiver typing and optional-field purpose remain unverified;
heuristic counts stay heuristic and all ten unsupported capability rows remain.

## New rendering boundaries

`c_naming.brp:349`, `c_binder_name`: only the discard spelling or id-zero
compatibility path uses `c_local_name`; minted IDs select projected spellings.
`c_naming.brp:495`, `derived_anchor_key`: temporary origins and nonzero anchors
use origin/ID keys; the remaining id-zero anchor uses escaped compatibility
spelling. Both are narrow rendering fallbacks, not general semantic allowances.

Scanner fixtures accept reviewed exact projection sites and reject rewritten
projection sites in each class. Existing `test_c_symbol_projection.brp:1886`
checks nonzero derived-anchor output, but direct id-zero/discard compiled oracle
coverage was absent at the audit snapshot. Two focused tests were added to that suite for reserved id-zero/discard spelling
and id-zero derived anchors, with renamed nonzero-ID countercases. The coordinator
owns running those output oracles; they are not reported as passing here. Scanner keys do not include the enclosing guard; fixtures alone do not establish output semantics.

## Enforcement and evidence

`make hygiene-check` now invokes `compiler-identity-census --check` and the magic
scanner with `--strict`. Existing Linux CI Quality runs this target through
`make quality`; default `scripts/test` routing stays unchanged. Three execution
contracts failed before wiring: the old recipe omitted the census and accepted
both an injected exact site and a stale magic fixture. They pass after wiring.
The test executes the repository's actual hygiene recipe with isolated source
and stubbed unrelated guards; it does not require a compiler/native build.

Python scanner contracts: 47 passed (32 census, 15 magic), no skips. Raw logs:
`/tmp/blorp-identity-reconciliation/enforcement-before.log` and
`/tmp/blorp-identity-reconciliation/tooling-after.log`. Historical source `--check` was
red before the reviewed baseline was restored. No native tests or performance
claims belong to this tooling delivery.

## Final frozen publication

The coordinator froze compiler sources with only the call-diagnostic helper
change in `infer.brp`, SHA-256
`125bb68ef0a597a015dc6e1aaf6b526728d517dde42f08160ff83967d389b93b`.
The JSON `final_snapshot` appends all final source/test hashes without rewriting
the historical 186-added/193-removed classification evidence. Exact keys are
unchanged by the diagnostic change. Final inventory: 3,402 rows, 139 legacy
semantic sites, 720 legacy source shapes, 2,521 heuristic candidates, 12 reviewed
boundaries and ten unchanged unsupported capabilities. The single added row
is a heuristic `.name` reader in the diagnostic helper; the typecheck-directory
name-candidate budget changes 241 → 242. It does not establish semantic coverage.

Both direct fallback output tests passed in the coordinator's owning compiled
C-symbol suite, 64/64: `/tmp/blorp-identity-execution-20261005/c-symbol-projection.log`.
After that result and explicit approval, the reviewed candidate was installed.
Its exact 859-key inventory, complete budgets, 203-file coverage, all ten
capabilities and all 12 boundary keys equal the final report. The old ten
boundary metadata rows are preserved exactly; two narrow rendering rows name
the direct output-test oracles. The historical revision label remains a base
revision; the appended hashes bind the dirty frozen source snapshot precisely.

Candidate/final baseline SHA-256:
`6f0a339782ee716c4f406766e34e4f2a6329101b74f3c6fce0859175c901f0c5`.
Final Python tools: 47/47 passed, no skips, in
`/tmp/blorp-identity-reconciliation/tooling-final.log`. Candidate source check
passes in `/tmp/blorp-identity-reconciliation/candidate-check.log`.

Final `make hygiene-check` passed, including source census and magic strict;
log `/tmp/blorp-identity-reconciliation/hygiene-final.log`. `git diff --check`
passed. Full `scripts/test compiler-tools` includes native fixtures and was not
run by this static tooling worker; owning Python contracts were run directly.
