# Independent ranked output diagnostic: completed

One authorized diagnostic run used unchanged FRESH O2 compiler `a17a6ed3…`,
production HEAD2ee + accepted dictionary309, owning tests-v3 `1355d3d4…`,
scratch proposal `5fe71603…` and probe source `e0799303…`. The probe's `src`
symlink resolves to this checkout's `blorp/src`; symlink target and all resolved
tracked source hashes are frozen/verified before and after. Full authority is in
`probe-frozen-provenance.json`; copied source is `probe.frozen.brp`.

| Command | Result | Purpose |
| --- | --- | --- |
| scripts/compiler-build-status | FRESH O2, exit0 | exact baseline |
| bin/blorp run --no-format <frozen probe> | exit0 within180-second cap | diagnostic observation |
| scripts/compiler-build-status | FRESH O2, exit0 | final authority |

The run prints faithful emitter Result OK/ERR and C; its exit0 is not a promise
that emitted C contains no `#error`. No Bool controls or operational rank matrix
were rerun. All four emission Results were OK, with these actual observations:

- Receiver C declares `blorp_Vector* __call_arg_0;`, executes the cooperative
  checkpoint, separately assigns `__call_arg_0 = tensor;`, then performs the
  ranked inline read. V3 expected a combined declaration/assignment literal.
- The `_shape_f16` lookalike emits an unsupported-function artifact with
  `#error "Blorp backend could not emit function body: ranked_getter_control"`
  and no ranked inline value temporary. V3 incorrectly expected runtime fallback.
- Plain rank3 struct input becomes a shape runtime call inside
  `blorp_unbox_struct(..., RankedPoint)`. It does not contain the inline temporary
  or memcpy. Explicit shape rank3 struct input instead emits zero initialization,
  storage/element-size guards and inline memcpy. V3 treated both forms alike.

These observations explain failing baseline expectations, not a new production
compiler defect or authorization to alter existing plain/shape behavior. Probe
coverage is representative rank3 only; v3 separately reported369/3 over372 and
existing365 passed. Runtime/candidate/all-rank identity acceptance remains pending.

Raw full C stdout is retained at `probe-run-packet/stdout.log` (7881 bytes); its
actual hash is in `probe-results.json`. `diagnostic-sections.json` selects compact
contexts. No raw output was rewritten. `commands.json` has exact argv, the
maintained `record-validation --timeout180`, durations and three packets.

All three packets have `source_changed_during_run: false`, full repo/test/docs,
proposal/probe/symlink source guards match, batch source_changed is false, and
compiler remains `a17`. No source/test/doc fixes or retries were made. Foreground
session61686 exited0, all synchronous children were waited, no matching owned
scheduler/probe process remains and shared native slot is released. No further
native command is authorized by this report.
