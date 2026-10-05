# Frozen assembled-root binder checkpoint

Independent validation passed at clean root revision
`8a45807177bfeaca1c5ace1a9196d7c141930a24`. This is a historical source-matched
checkpoint, not a freshness claim after subsequent documentation commits.
O2 build and separate before/after build-status checks reported FRESH:
compiled_by `dev-d44472d3a5d0`, CLI/runtime O2, split 8, Apple clang 21,
memory diagnostics 0. The unchanged normal binary SHA256 was
`22466c87b0069d04555db10a09a2512438c00c7670b05521dc6a669e8bcdcc3d`.

## Actual serial checks

From the repository root:

```bash
BLORP_CLI_C_OPTIMIZATION=-O2 make
scripts/compiler-build-status
BLORP_CLI_C_OPTIMIZATION=-O2 scripts/compiler-check --changed --base 2ec7b5dfe34480aadb528cc1723dc9bce05a1516
BLORP_CLI_C_OPTIMIZATION=-O2 scripts/compiler-check --stage ctfe
```

Selected checks passed 609/609; CTFE passed 191/191. Under this evidence
directory, run each of `default_inner_call_probe.brp`, `custom_default_probe.brp`,
`purity_refinement_probe.brp`, and `independent_not_equals_probe.brp` with
`bin/blorp test --leak-check --timeout 180 <source>`: 2+2+1+2 passed with zero
tracked leaks. These overlapping suites are not summed as unique coverage.

Each of `default_inner_call_program.brp`, `custom_default_program.brp`, and
`purity_refinement_program.brp` was compiled and run using:

```bash
bin/blorp compile --no-format --dump-core-after=lower --dump-core-file=<artifact>/<label>.lower.core -o <artifact>/<label>.c <launcher>
bin/blorp run --no-format --leak-check --timeout 180 <launcher>
scripts/compiler-build-status
```

All compile/run commands exited 0. Selected call and callee metadata retained
outer/inner IDs: Eq 123/124, custom 123/124, purity 124/125. Eq/custom folded
globals were Bool True in lower Core and 1 in actual C. Runtime defaults called
the selected implementations; the purity control retained its impure outer
contract with a pure implementation. Process-end allocation/release/leak counts
were Eq 9/9/0, custom 9/9/0, purity 7/7/0—not workload cost measurements.

## Retention and limits

Complete commands, status, logs, raw Core/C and identity excerpts are retained at
`/tmp/blorp-binder-root-frozen.w1lrEj/`. Report SHA256:
`79cc3de301b42e703275988128ae201be69bb09103ba2cc94d88c3871a1e8046`.
The 16-file `source-manifest.sha256`, unchanged before/after, has SHA256
`a086601246e0b39e0e02f0cca0238e312e73e1ed0dc872ca6f14a422439bd00f`.
The retained `artifacts.sha256` has SHA256
`aebd8670b15dd9cd54cad7de64cb4701cdd21d91bd5e36030cff9666603a7149`.

The earlier `/tmp/blorp-binder-assembled.hIK5kL` attempt was rejected: concurrent
coordinator documentation edits changed dirty-state sampling during the build,
leaving stale link identity. Its interrupted gate has no accepted count. The
frozen rerun above passed without source/build-script workarounds. A separate
initial freshness wrapper also failed on zsh's read-only `status` variable;
the corrected wrapper independently passed before gates.

Historical broad 12,397, audits 228 at each stage and raw-C fixpoint proofs in
[EVIDENCE.md](EVIDENCE.md) were **not rerun** or relabeled assembled-root results.
The canonical candidate's owner 538/538, styled controls 7/7 and measured lookup
cost remain separate snapshots. This checkpoint includes no new broad,
sanitizer, fixpoint, performance, bootstrap, release or declaration-conversion
claim; all compiled jobs stopped and the runner released its token.
