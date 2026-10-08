# Current-main data-model measurement

Parent: a8413c9f38b22884c12fad3722c49be243ee0eeb.
Candidate staged tree before and after: 5ecc42b2772ea39fa4aea10b83bdb7ceea854bf3.
Clean detached baseline: /tmp/blorp-model-current-measure.MfT6Gi/baseline.
Candidate: /tmp/blorp-model-current-land.1ecbMz/blorp.

Both stage-1 builds passed and were FRESH under BLORP_CLI_C_OPTIMIZATION=-O2.
Both bootstrap.env hashes: ccf4a77ab353a03e81e2868e0635facfb8967877e0974497a79d9d96607bb616.
Pinned bootstrap: dev-0e1598ed616e.
Apple clang version 21.0.0 (clang-2100.3.34.2), cli/runtime O2.

Initial runs used each checkout's benchmarks/self_compile_measure --stage2
--input-rev a8413c9f38b22884c12fad3722c49be243ee0eeb --samples 2,
with baseline.json/candidate.json, --keep-output baseline.c/candidate.c,
and candidate --baseline baseline.json --require-identical.
They were wrapped in self_compile_measure lock --, which current main
documents and implements as a no-op. No host-wide lock exists.

One bounded resample used --compiler bin/blorp-stage2
--diagnostic-compiler bin/blorp-stage2-diagnostic --skip-build-check,
the same frozen input and two samples. No further builds. Binary hashes
match the initial runs exactly. The resample JSON reports compiler_stage=1
because this field reflects the --stage2 flag; the paths, hashes and self-
compiled provenance establish that these are the same stage-2 binaries.

All four measurements generated identical 86,912,985-byte C, SHA-256
c5bcc86e9777d0919a6fa36a27fd54f7fb462d4366169666f3b7fcc30d924b5d.
Normal and diagnostic output identity is checked by the harness.
Allocations repeat exactly: baseline 284,632,215; candidate 284,184,846.
Savings 447,369: typed_frontend_complete 398,939, backend match 2,323,
Perceus 2,323, backend_emission_complete 43,784. Other phase deltas zero.

Initial baseline instruction samples: 271909132666, 271880989808;
candidate: 271419602326, 271475991050.
Resample baseline: 271584020785, 271823337901;
candidate: 272755125251, 272195470885.
Initial minimum delta -0.1697%; resample minimum delta +0.2251%.
Instruction evidence has mixed signs; a stable nonregression is not proven.
Both rounds fall within the coordinator's predeclared significant-growth
ceiling of greater than 1%; neither supports an instruction-win claim.

Host observations: an external build/test task intermittently ran during
setup and the initial baseline window (baseline timestamp 18:36:46 UTC).
An observed normal baseline process PID35421 overlapped external bin/blorp
PID35352 and program.bin PID35416. This observation did not record its own
wall-clock timestamp; do not infer a precise contamination time.
Resample snapshots at 18:42:48 and 18:43:30 UTC showed only our diagnostic
and normal baseline processes. At 18:44:09 UTC, after baseline resample
completed, external bootstrap PID41432 was observed; it exited before
the candidate sample check. At 18:45:07 UTC only our candidate normal
process PID41779 was visible. Snapshots cannot prove continuous quietness.
/usr/bin/time -l reports the timed utility's rusage; instructions are
process-scoped, not a sum of unrelated host processes. Contention can
still perturb runtime paths and scheduling. No wall-time acceptance claim.

The full verbatim phase tables and RSS rows are candidate-measure.log and
candidate-resample.log. JSONs retain toolchain fingerprints and raw samples.
The candidate tracked files and index were not modified. No commits,
merges, pushes or broad correctness gates were run by this worker.
Recommend accepting allocation/output evidence and the observed less-than-1%
growth ceiling, rejecting a speedup claim, and leaving stronger instruction
nonregression assertions unresolved for coordinator review.
