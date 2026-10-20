# Internal pipes preserve closed standard descriptors

The reported eligible-suite forwarding assertion expected exit 1 but observed
exit 0 and only `candidate-stderr-marker`. With stdin and stdout both closed,
the signal broker's internal pipe could acquire descriptors 0 and 1. Forwarding
captured stdout then successfully wrote into that pipe instead of observing
`EBADF`. The signal dispatcher consumed those bytes. The CI runner's exact
inherited stdin state was not available; the dual-closed reproduction establishes
this failure mechanism, rather than proving that runner state.

The bounded plan was to move every internal pipe endpoint above stderr, reuse
the process-pipe relocation logic, and preserve close-on-exec and spawn-lock
requirements. No output-forwarding, signal, cache or status policy changes were
needed. The new native regression closes descriptors after executable loading
and checks endpoint identities, closed descriptors, close-on-exec, blocking mode
and exact bytes including NUL. The existing CLI failure oracle is retained, with
an additional invocation whose stdin is closed.

## Validation

Base: `09bdd5fb9db85df3d488ac02264845231770b943`. Candidate: the reviewed delta
on `codex/eligible-output-forwarding`, tested with dirty build metadata. Linux x86_64 ran in
`blorp-test-linux-amd64:latest` (image `7373c8c71984`), Ubuntu 24.04,
Clang 18.1.3, through x64 translation on the macOS arm64 host.

| Check | Result |
| --- | --- |
| Native matrix against exact baseline runtime | 8 pass, 56 assertion failures, 0 errors |
| Same matrix against candidate runtime | 64 pass, 0 failures/errors |
| Fresh normal and diagnostic compiler builds | PASS, CLI O2/runtime O2, FRESH |
| Current runtime objects, embedded provider and matching metadata | PASS |
| Candidate stdout-only and dual-closed constructor controls | All four exit 1 with forwarding diagnostic |
| Generated C contains the relocated-pipe helper | PASS |
| Process commands / process sessions | 20/20 and 35/35 PASS |
| Full CLI gate, same binaries with `--no-build` | 155/155 PASS, 0 failures, 2m53s |

The matrix covers all eight closed-standard-descriptor subsets, blocking and
nonblocking helpers, native and forced portable pipe creation, and atomic and
portable duplication. Against the baseline, every nonempty closed subset fails
the intended descriptor assertion. There are no platform skips.

Translation itself can occupy an initially closed descriptor, masking the
compiler reproduction. A retained constructor therefore closes stdout (and,
for the decisive case, stdin) after loading but before Blorp initialization;
it checks `EBADF` and clears the preload/control environment before children.
Both traced and clean controls reproduce baseline exit 0 for the dual-closed
case and candidate exit 1. The trace shows baseline `pipe2` endpoints 0/1 and a
successful stdout write; the candidate stdout write fails with `EBADF` after
relocation. This control does not claim validation on native x86_64 hardware.

The initial baseline CLI run was 113 pass / 41 fail. Its container setup made
the default cache parent unwritable by mounting the bootstrap cache underneath
it, causing unrelated host-runtime mismatch failures. That run is retained as
rejected setup evidence. Accepted runs instead mount it at `/bootstrap-cache` and set
`BLORP_COMPILER_BOOTSTRAP_CACHE_DIR`; production cache behavior is unchanged.
The fresh full CLI run has no remaining host-runtime mismatch failures.

## Evidence and scope

Raw commands, logs, baseline runtime snapshot, constructor sources and probes,
matrix counts, binary/runtime-object hashes and generated C remain under
`build/eligible-output/` in the task worktree. `review-stage-a.launch.command`
and `review-stage-a.sh` reproduce the accepted 189-second validation sequence.
`review-a-native-matrices.json`, `review-a-provenance.log`, and
`review-a-process-suites.log` hold the principal receipts. Stage B's exact command
is in `review-stage-b.launch.command`; `review-cli/cli.log` and
`review-stage-b.launch.log` retain the full CLI result. Normal and diagnostic
binary hashes are unchanged from Stage A.

Production runtime: 43 added / 32 deleted, net +11 lines. Test code: 144 added;
gate registration: 7 added. This note is separate. This is a correctness fix,
with no compiler data-model refactor or performance claim.

Independent code review found no issues and approved the implementation and
evidence note. Independent test-runner validation completed both stages with no
candidate failures. Main integration and publication belong to the parent task.
