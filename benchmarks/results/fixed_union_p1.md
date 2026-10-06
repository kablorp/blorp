# Fixed union P1 local readiness and evidence

Status: **LOCAL SYNTAX CUT REVIEWED AND VALIDATED / NOT MERGED**.
Full P0/P1 acceptance remains pending; this cut implements only the initial synonym.
Matched local stage-2 costs and fixpoint are retained; this is not checked fixed
admission or release acceptance. See the [roadmap](../../docs/FIXED_UNION_ROADMAP.md).
Full P0 semantic/native closure and P2 ABI/capability-bootstrap gates remain open.

## Provenance

- Baseline revision: `133eaf73a63830522b659ab6a2da65f9f2963711`.
- Baseline compiler: `<worktree:43a9>/bin/blorp`;
  SHA-256 `29f646a02726705420cce82ac5d5c7282a50967667628fb4ec69c5f3097bba4c`.
- Candidate: `<worktree:fixed-union-frontend>`;
  compiler `bin/blorp`, local dirty source revision, build status **FRESH**.
- Candidate compiler SHA-256: `d107945c079c76cf57f8b12baa0d7b57295b615be6737c67c37b97ef17abff0a`.
- Generated `blorp/build/_build/blorp-cli/blorp_cli_main.c` SHA-256:
  `927f6c78428d1437a1134c7b23ff2e5ec512b1bee9f3ee87bbc35ae9119b2ea2`.
- Both builds: bootstrap `dev-d44472d3a5d0`, CLI/runtime `-O2`/`-O2`, split 8,
  memory diagnostics 0, aarch64-apple-darwin,
  Apple Clang 21.0.0 (`clang-2100.3.34.2`). Hashes/status rechecked read-only.

## Bounded source census and contract

| Census | Baseline | Candidate | Interpretation |
| --- | ---: | ---: | --- |
| Raw anchored enum lines in selected roots | 366 | 369 | Includes one prose line, not a declaration |
| Exact lexical enum declarations in selected roots | 365 | 368 | Three source-form metadata enums added; existing declarations retained |
| Exact lexical enum declarations, full inventory | 425 | 429 | Also adds formatter fixture `Legacy` |
| Selected AST bridge `.is_enum`/`is_enum: Bool` lines | 11 | 0 | Explicit source forms replace the AST boolean at the selected boundary |

Production roots are `blorp/src`, `standard_library`, `pkg`, and `examples`, `*.brp` only.
Added headers are legacy/discovery `UnionDeclarationForm` and formatter `UnionSpelling`;
full inventory also adds `Legacy` in `blorp/test/format/should_pass/fixed_union.brp`.
No existing enum declaration is migrated in P1. The bridge census selects
`compiler/stage_03_parse/{parsed_ast,parsed_ast_json,language_parser}.brp`,
`compiler/discovery_adapter.brp`, `compiler/stage_06_typecheck/headers/type_header_graph.brp`,
`compiler/stage_08_core_lower/lower.brp`, `format/projection.brp`, and `lint/command.brp`
under `blorp/src`. These lexical counts do not classify all embedded source strings,
native contracts, constructor identities, or runtime behavior; P0 is not accepted.
The [classified census](fixed_union_p1/census/REPORT.md) retains 50 embedded headers,
native/prose exclusions, full inventories and a reproducible script. Dynamic generators,
imported trait identity and exhaustive native-call closure still require manual gates.

Legacy AST forms are `OrdinaryUnion | FixedUnion | LegacyEnum`; discovery records
written form and source row kind. Formatter `UnionSpelling`/`TypeDeclarationKind`
preserve spelling through direct projection and required JSON forms. Legacy enum
semantics remain supported; fixed follows ordinary union typechecking and ownership.
There is no placement/allocation/ABI promise. Future P5 must reject direct/nested
`String` payloads even in unused variants; ordinary unions remain available for them.

## Reviewed native requirements for P2, not union migration proofs

| Boundary | Required preserved contract | Source/test authority |
| --- | --- | --- |
| Bool | C `int`, `True = 1`, `False = 0`, independent of declaration order | [bool.brp](../../standard_library/src/bool.brp), [c_type_layout.brp](../../blorp/src/compiler/stage_09_core/c_type_layout.brp) |
| MemoryCounter | `blorp_read_memory_counter(long)`, stable selector tags 0–15 | [memory.brp](../../standard_library/src/memory.brp), [runtime.c](../../blorp/src/lib/runtime/native/runtime.c) |
| DirectoryEntry.kind | Native field `long`, defined tags 0–4 | [fs.brp](../../standard_library/src/fs.brp), [runtime.c](../../blorp/src/lib/runtime/native/runtime.c) |
| IpFamily | Builtin native `long family`, IPv4=0 / IPv6=1 | [tcp.brp](../../standard_library/src/net/tcp.brp), [runtime.c](../../blorp/src/lib/runtime/native/runtime.c) |
| User foreign enum fields | `sizeof(long)` and fixture `state == 1` | [layout fixture](../../blorp/test/compiler/pipeline/codegen_audit/should_pass/compiler_record_layout.brp), [FFI assertions](../../blorp/test/compiler/pipeline/codegen_audit/should_pass/compiler_record_layout_ffi.h) |

These declarations/contracts have not been migrated or tested under union spellings.
No scalar adapter or common native ABI capability is claimed complete.

## Reviewed local validation and remaining checkpoints

Independent runner report: `/tmp/fixed-union-candidate-tests.CBLieV/REPORT.md`.
All assigned local gates pass; overlapping suites/gates are not additive totals.

| Boundary | Passing result |
| --- | --- |
| Narrow legacy / discovery and formatter | 669/669 / 180/180 after repairs |
| Changed owner selection | 4725/4725: suites 963, Core sanitizer 2375, tools 222, leak 1165 |
| Compiler-new / compiler-new-parity | 832/832 / 3542/3542; actual `kind_fixed_union=5` |
| Compiler-blorp | 6518/6518: suites 5688 + real marked fixtures 830 |
| Broad LSP / doctest / retained leak repeat | 36/36 / 1057/1057 / 1165/1165 |
| New ownership / editor | 3/3 / 5 Python tests plus drift guard |

Independent review: zero findings; bounded after-cut cleanup inventory leaves
`LegacyEnum`, formatter legacy JSON form, table enum rows, and boolean fixture
helpers for later enum retirement, not this syntax cut.
- Narrow Core lower: 150/150 pass; synthetic fixed/ordinary inputs produce equal
  whole Core JSON with existing `ErasedUnionPayloadStorage` for managed `String`.
- Runtime ownership: 3/3 per-test passes establish zero tracked live objects in
  the exercised tests. [test.brp](../../standard_library/src/test.brp) resets counters
  before EACH test (line 341), checks `current_objects`, then resets again (line 380).
  Process-end 3 allocations/3 releases describe the POST-suite harness interval,
  not fixture allocation cost. Churn returns 128; retained C has actual calls,
  loop, string/record/List work, and releases. No zero-allocation or universal proof.
- Same-path legacy ordinary input: baseline/candidate raw C is identical,
  SHA-256 `4f8da5ef7fe81e6c5ae857e55e5269d22c2492d67a3413a21782618a37c11f82`.
  Fixed versus ordinary raw C differs in offset-derived binder names; mismatch retained.
  Same-path, equal-width ordinary/fixed input control yields identical raw C,
  SHA-256 `85113219768ae2fed323e894e5d6201488de8fdf72ca0310ecd081e270842ac2`.
  Compensation is in the input source, not normalization of generated C.

Typed-preview limitation: ordinary `union U[T:\n\tA` and its fixed counterpart
both produce ordered `ExpectedName(NameInTraitName)` and
`ExpectedRightBracket(RightBracketInTypeParameters)` and stop at the newline.
Table parsing adds `ExpectedColon(ColonInUnionVariants)` and recovers to EOF
for both forms. This existing ordinary-input boundary is isolated by focused
13/13 controls; missing-colon and unclosed-payload controls retain strict
table/tree parity for both ordinary and fixed forms.
No production parser routing change or universal diagnostic/recovery parity is claimed.

Resolved failures remain in session logs: multiline test syntax, malformed-header
control boundaries, and mandatory diagnostic pins were repaired and rerun.
Seven task-owned new fixtures had to be staged for the `git ls-files` parity corpus;
the maintained fixture count changed 829→830. Strict coverage/equality checks
remain unchanged; these are resolved history, not active failures.

## Matched local stage-2 costs and self-hosting

Two samples per workload; table uses retired-instruction minima. Exact allocations
and raw emitted C match; these small instruction differences are cost-neutral, not
a speedup claim. Host noise remains possible. [Raw report](fixed_union_p1/measurement-report.md)
retains verbatim comparisons/commands; four measurement JSON files are unchanged.

| Frozen baseline input | Baseline / candidate allocations | Baseline / candidate instructions | Raw C |
| --- | --- | --- | --- |
| Self | 241,661,755 / 241,661,755 | 223,730,287,224 / 223,693,748,427 (-0.02%) | Identical, 77,451,514 bytes |
| Small | 1,733,952 / 1,733,952 | 1,604,900,420 / 1,604,854,246 (~-0.003%) | Identical, 39,575 bytes |

Normal/diagnostic modes 0/1 used the matched stage-2 pairs. The unmodified helper
mislabels externally supplied small pairs `compiler_stage=1` and leaves the
stage-2 generator hash null; actual binary hashes match the self-run stage-2 pair.
Raw metadata is preserved, not corrected. [Final provenance](fixed_union_p1/final-provenance.md)
retains binary hashes (only its extra EOF blank line was trimmed from the temporary
original; gate content is unchanged). Unmodified O2 fixpoint passed: stage 1/2/3 raw C SHA-256
`8ca7411914f20a815e11132f035eb8bb2a9a33201f4b8bfce5eefc424253fc27`.
Stage-2 ownership fixture passed 3/3 with per-test `current_objects` checks;
the post-suite harness interval is not a fixture allocation-cost guarantee.

- [x] Matched normal/diagnostic stage-2 cost packet and local fixpoint/self-host proof.
- [ ] Immutable release assets/digests/pin and actual-pin self-host/build/package gates.
- [ ] P0/P1 acceptance; no enum conversion or checked guarantee activation authorized here.

Session artifacts (temporary, not durable raw performance metrics):
`/tmp/fixed-union-candidate-tests.CBLieV/REPORT.md` indexes complete gate and resolved-failure logs.
`/tmp/blorp-fixed-union-oracle.CSvGp4/EVIDENCE.md` retains Core/C/source and exact recovery controls.
Editor red/green/drift logs: `/tmp/fixed-union-editor-indent-{red,green,drift}.log`.

## Reproduce the bounded checks

Run compiled commands serially on macOS after confirming the intended build:

```bash
scripts/compiler-build-status
shasum -a 256 bin/blorp blorp/build/_build/blorp-cli/blorp_cli_main.c
git grep -n -E '^[[:space:]]*(private[[:space:]]+)?enum[[:space:]]+' 133eaf73a63830522b659ab6a2da65f9f2963711 -- 'blorp/src/**/*.brp' 'standard_library/**/*.brp' 'pkg/**/*.brp' 'examples/**/*.brp'
rg -n '^[[:space:]]*(private[[:space:]]+)?enum[[:space:]]+' --glob '*.brp' blorp/src standard_library pkg examples
bridge_paths=(blorp/src/compiler/stage_03_parse/{parsed_ast,parsed_ast_json,language_parser}.brp
  blorp/src/compiler/discovery_adapter.brp blorp/src/compiler/stage_06_typecheck/headers/type_header_graph.brp
  blorp/src/compiler/stage_08_core_lower/lower.brp blorp/src/format/projection.brp blorp/src/lint/command.brp)
git grep -n -E '\.is_enum|is_enum: Bool' 133eaf73a63830522b659ab6a2da65f9f2963711 -- "${bridge_paths[@]}"
rg -n '\.is_enum|is_enum: Bool' "${bridge_paths[@]}"
python3 editor/test_record_spelling_grammar.py
scripts/check-editor-drift
bin/blorp test --timeout 180 blorp/test/compiler/stage_03_parse/test_parser.brp
bin/blorp test --timeout 180 blorp/test/lsp/analysis/test_lsp_semantic_index.brp
bin/blorp test --timeout 180 blorp/test/format/engine/test_declaration_documents.brp
bin/blorp test --timeout 180 blorp/test/compiler/stage_08_core_lower/test_core_lower.brp
bin/blorp test --leak-check --timeout 180 blorp/test/runtime/memory/test_fixed_union_synonym_ownership.brp
scripts/test --serial compiler-new compiler-new-parity compiler-tools lsp
```

The local gates and matched cost/fixpoint checks passed; semantic closure and
release/actual-pin checkpoints remain separate and are not implied by these commands.
