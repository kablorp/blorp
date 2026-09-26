# Importable declaration facts built from local lists (2026-09-25)

## Mechanism and scope

The legacy `typecheck_graph` path builds an `ImportableModuleGraph` before
header completion. Its `importable_declaration_facts` previously passed an
`ImportableDeclarationFacts` record through a helper once per parsed
declaration. On function-heavy modules, updating `signature_decls` inside
that record retained the list before append; each header could copy the
growing payload. The retained change owns `declared_imports`,
`signature_decls`, and `impl_decls` as local lists during the scan and
constructs the facts record once at the end. Private declarations still
contribute only nested import blocks. Generated C shows direct local
`blorp_list_ensure_capacity_checked` calls with no pre-append list retain,
and one final `ImportableDeclarationFacts` construction.

This is an ownership/representation cut, not a new table or a change to
import semantics. The temporary phase-copy probes used to locate the site
were removed; they are not part of the production diff because profile
window resets could make their counter deltas misleading.

## Diagnostic wide-header profile

Both sides used the same `dev-048a5864cd98` bootstrap and fresh Apple
clang 21 `-O2` compiler builds. `compiler_callable_header_profile` generated
profile-mode host C at `-O0`, then ran one retained-program iteration with
one module, no parameters, and no dimension constraints. The transient
probes measured the legacy importable-graph boundary in the same profile
window as the process-wide collection-copy counters. The candidate at this
checkpoint used local lists but preceded the final private-import `Option`
refinement; the fixture contains no private declarations. All rows reported
matching declaration counts, checksum, zero errors, and a valid workload.

| Headers | Importable-graph copied-list bytes, before | After |
| ---: | ---: | ---: |
| 32 | 4,200 | 456 |
| 64 | 16,616 | 968 |
| 128 | 66,024 | 1,992 |
| 256 | 263,144 | 4,040 |
| 512 | 1,050,600 | 8,136 |

At 512 headers, the *process-wide* copied-list payload also fell from
1,531,912 to 489,448 bytes, and allocations from 92,414 to 91,402.
The phase copy counter includes capacity growth and does not distinguish
every shared COW branch. The 512-header raw logs are
`/tmp/typecheck-phase-list-boundaries-512.log` (SHA-256
`bf7025f178c8caff93bbc599318b3c770a78c47c03ff5c8f783642727e007f2e`)
and `/tmp/typecheck-phase-list-localowner-512.log` (SHA-256
`c1eae336f3549307775623ffb6b7ac511962d4bc3dbe48e9b2533d8e7184daeb`).

## Frozen-input acceptance

The production-only candidate was compared with a freshly rebuilt clean
`9e19f8c7` baseline, not just with an older result. Both builds were
`-O2`, used the same bootstrap and clang, and compiled frozen input
`101976d38fb0b3153141ab7440b7db1684db8174` to C without compiling
the emitted C. The baseline and final-candidate JSON are
`/tmp/typecheck-importable-local-lists-matched-baseline.json` (SHA-256
`7cd44a7ad050a270176b2c55f6d0c155dc59a16ef8a1c4f8fdbdd603afb82f0f`)
and `/tmp/typecheck-importable-local-lists-matched-candidate.json`
(SHA-256 `1f645ca3afc6095abfd277a24150c65a4ea7a56c845dd703989edbe28904f506`).

| Frozen workload | Baseline | Candidate | Interpretation |
| --- | ---: | ---: | --- |
| Self typed-frontend allocations | 29,825,136 | 29,816,707 | −8,429 |
| Self total allocations | 209,621,686 | 209,613,257 | −8,429 |
| Self minimum retired instructions | 168,761,018,307 | 168,753,644,733 | Overlapping samples; no speedup claim |
| Small typed-frontend allocations | 847,363 | 845,746 | −1,617 |
| Small total allocations | 1,544,653 | 1,543,036 | −1,617 |
| Small minimum retired instructions | 1,288,311,015 | 1,288,481,068 | +0.01%; overlapping samples |

Self instruction samples were baseline `[168784272905, 168882817602,
168761018307]` and candidate `[168753644733, 168841183127, 168801020299,
169000874458, 168795144786]`. The candidate's single high sample and
the overlap preclude a reliable instruction improvement or regression
claim. The earlier noncontemporaneous comparison looked like a regression;
that was the reason for rebuilding and measuring a same-session baseline.
Self generated C was byte-identical (83,571,359 bytes, SHA-256
`7c413d235c7e3ff080474e4f79f87dd15e528310597de53cfdd8c5120dd77195`).
The small output was also byte-identical (42,475 bytes, SHA-256
`b14e002cf83bd89ace4c862a0cf0137f36b21cde683a993671641f0c2e3b096a`).
The corresponding small JSON files are in `/tmp` under the same
`typecheck-importable-local-lists-small-{baseline,candidate}.json` names.

Focused declaration and bound-graph suites passed 166/166 and 23/23. The
selected `scripts/compiler-check --changed` passed 1,175/1,175, including
its leak check; `scripts/test --no-build compiler-blorp` passed 5,115/5,115.
An independent read-only review found no semantic-ordering defect and
confirmed the generated-C local-list ownership path.
When this cut was prepared separately for local main `7a409820`, a fresh
`-O2` compiler passed 167/167 declaration tests, 23/23 bound-graph tests,
1,176/1,176 selected checks including the leak check, and 5,120/5,120
`compiler-blorp` tests. These are integration-gate results, not new
performance measurements on main.

This cut affects the typecheck frontend only. The harness's generic
stage-2 warning about older runtime sources does not hide this
`module_binding.brp` edit from the bootstrap-built compiler. The copies
left in other typecheck boundaries remain separate candidates, not a
reason to widen this change.
