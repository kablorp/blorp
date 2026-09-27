# Ownership-contract graph allocation attribution (2026-09-27)

Measurement only. The normal compiler's fused ownership-contract/Perceus span
allocates 44,108,636 objects on the frozen self-compile. A direct profile of
the same pre-Perceus Core attributes most of contract inference to graph
construction; the solver is small. No production optimization was made.

## Provenance and method

- Compiler source base: `99d074858788722249130aba89a4c1ef8082c1f7` on
  `codex/perceus-call-cost-pilot`. The diagnostic binary was a FRESH, dirty
  `-O2` build, SHA-256
  `b0cd32cb610499d51533bc7145053c2bb74a594a0352debbe33e05ba1ed6865d`,
  built by bootstrap `dev-2f1a59c43baa` with Apple clang 21.0.0.
- Frozen compiler input:
  `5a1219af7f9167de08c56df3f2232fc7b15fa743`. The post-DCE dump was
  decoded, then advanced through the production consume-specialize,
  static-string, record-update ownership, and dict-literal ownership passes.
  The profile resolved global value references before measuring contracts,
  matching `run_fused_ownership_perceus_pass`.
- Direct calls used `reset_mem_stats()` / `get_mem_stats()` around `build_env`,
  `infer_ownership_contracts`, `build_ownership_contract_graph`, and
  `solve_user_call_contracts`. No generic closure, copied Core snapshot, or
  production checkpoint call surrounded the graph/solver. The graph's last
  source use was the direct solver call. Statistics were captured before
  reporting or comparing contract lists.
- The graph and solver were temporarily made public solely for the split
  profile. Their visibility and both temporary profile modes were restored
  after measurement; the original whole-pass mode was untouched.

## Diagnostic command sequence

These commands record the completed measurement sequence and reference artifact
paths; they are not a directly executable reproduction of the SHA-pinned dirty
compiler. The precise temporary implementation was discarded and must be
reconstructed before rerunning. In particular, `contracts` and
`contracts_split` were temporary diagnostic profile modes and are **not
available on main or in this report-only branch**. Reconstruction requires
adding those modes to `benchmarks/blorp/profiles/perceus_allocations.brp`:
`contracts` directly brackets public `infer_ownership_contracts`; the split
mode directly brackets graph construction and solving, then compares every
ordered contract list. The split mode also requires removing `private` from
only `build_ownership_contract_graph` and `solve_user_call_contracts` in
`ownership_contracts.brp`. Restore all diagnostic source edits afterward.

Run compiled commands serially in an exclusive measurement slot:

```bash
BLORP_CLI_C_OPTIMIZATION=-O2 make
BLORP_CLI_C_OPTIMIZATION=-O2 scripts/compiler-build-status # FRESH
frozen_input=$(benchmarks/self_compile_measure freeze --rev 5a1219af7f9167de08c56df3f2232fc7b15fa743)
bin/blorp compile --no-format --no-embed-runtime \
  --std-dir "$frozen_input/standard_library/src" \
  -o /tmp/blorp-perceus-contract-current-postdce.c \
  --dump-core-after=dce \
  --dump-core-file=/tmp/blorp-perceus-contract-current-postdce.json \
  "$frozen_input/blorp/src/main.brp"
BLORP_CLI_C_OPTIMIZATION=-O2 \
  BLORP_PERCEUS_DUMP_FILE=/tmp/blorp-perceus-contract-current-postdce.json \
  BLORP_PERCEUS_SKIP_BUILD=1 BLORP_PERCEUS_PROFILE_MODE=contracts \
  benchmarks/compiler_perceus_allocations
BLORP_CLI_C_OPTIMIZATION=-O2 \
  BLORP_PERCEUS_DUMP_FILE=/tmp/blorp-perceus-contract-current-postdce.json \
  BLORP_PERCEUS_SKIP_BUILD=1 BLORP_PERCEUS_PROFILE_MODE=contracts_split \
  benchmarks/compiler_perceus_allocations
BLORP_CLI_C_OPTIMIZATION=-O2 benchmarks/self_compile_measure \
  --label perceus-contract-visibility-oracle \
  --input-rev 5a1219af7f9167de08c56df3f2232fc7b15fa743 --samples 1 \
  --baseline /tmp/blorp-core-rewrite-current-main-self.json \
  --output /tmp/blorp-perceus-contract-current-visibility-oracle.json \
  --keep-output /tmp/blorp-perceus-contract-current-visibility-oracle.c \
  --require-identical
```

## Results

| Direct boundary | Allocations |
| --- | ---: |
| `build_env` | 70,859 |
| `build_ownership_contract_graph` | 2,941,302 |
| `solve_user_call_contracts` | 32,147 |
| Sum of split rows | 3,044,308 |
| Public `infer_ownership_contracts`, independently measured twice | 3,060,822 |
| Difference between public total and split sum | 16,514 |

The difference includes contract-table/environment construction and possible
ownership or measurement-boundary effects. It is not a separately measured
function cost. Graph construction is 96.10% of the direct public total and
approximately 6.67% of the 44,108,636-allocation fused span. These are
contextual ratios, not perfect additive attribution to production.

The split profile found 15,562 callable entries and 15,562 contract lists.
Every ordered consumed-parameter list matched the public inference result,
including each list's length and element order. The normal self-compile emitted
byte-identical C (78,679,647 bytes, SHA-256
`2be89ae0e9eed650e84c36937ed8edb30f98975c682bd11ba7199b70fa029485`)
and retained exactly 44,108,636 allocations in the fused pass. Other normal
phase rows differ from the clean `5a1219af` comparison binary because the
diagnostic compiler's source base is later; those changes are not attributed
to this visibility-only probe.

## Stop rule and retained artifacts

`ContractCollectionStep` is constructed and immediately split during equation
collection. Its generated C constructor (`brp_tyi6_make`) allocates a heap
record, but changing the declaration to `struct` is illegal: its fields are
`ContractCollectionState` (a managed record) and
`ContractCollectionTaskStack` (a non-enum union). The Guide and the
`struct_record_field.brp` typecheck fixture prohibit such fields in structs.
No current self-compile visit count was measured, so a saving of at least
500,000 allocations from a different representation is unproven. Earlier
Tranche 1 work already installed sparse reverse flows and a frontier solver;
commit `14f4a4693` retained separate noncapturing flag scans after two
integrated drafts regressed. No bounded production cut met the evidence gate.

- Direct total output: `/tmp/blorp-perceus-contract-current-profile.log`
  (SHA-256 `02a6d9a7c81aefe55c11e26f386e372939a0f0904dfc88af32f9c53b12be5c9f`).
- Graph/solver split output: `/tmp/blorp-perceus-contract-current-split.log`
  (SHA-256 `b78bc35f73274434e3ddf29848168dcab4ffd7b7cb80cea6a6c7c05d1490a490`).
- Frozen post-DCE Core: `/tmp/blorp-perceus-contract-current-postdce.json`
  (SHA-256 `3ed13caf54938d1bac29a67866401dff5763ed4ec20200b992e5bec2bd16b15c`).
- Normal parity run: `/tmp/blorp-perceus-contract-current-visibility-oracle.json`
  and `.c` (JSON SHA-256
  `98cd74e7cf14e09120dfcb34df5ac92750c389662200f762991a5e8c1f31aea9`).
