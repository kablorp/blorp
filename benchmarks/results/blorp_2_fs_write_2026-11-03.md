# Blorp 2 fs library, atomic `write_text` (phase 2a, landing i-b) (2026-11-03)

`fs.write_text` joins the `SystemCall` contract as one new `SystemOperation`
row, `FsWriteText`, with the existing `Result[Void, Int]` shape: two borrowed
Strings, no success payload, an Int code that `standard_library/fs.brp`
decodes. No `SystemPayload` or `RuntimeResult` shape was added, and `own` and
`verify` are unchanged. The seed rotation (ii) and the migration of the
compiler's own writes (iii) are not here; `src/` still writes its C with
`system.write_file`.

## The problem, reproduced

`system.write_file` opens its target with `fopen(path, "wb")`, which empties
it before the first byte is written. With a file-size limit, the compiler's
own output is cut short (base compiler, this worktree):

```bash
make -C blorp_2 compiler
mkdir -p build/repro
blorp_2/build/compiler --library-root blorp_2/standard_library blorp_2/test/e2e/fixtures/fs/read.brp build/repro/out.c
wc -c build/repro/out.c        # 143117
(ulimit -f 8; blorp_2/build/compiler --library-root blorp_2/standard_library blorp_2/test/e2e/fixtures/fs/read.brp build/repro/out.c)
                               # exit 153: SIGXFSZ ends the compiler
wc -c build/repro/out.c        # 4096
```

The previous 143,117-byte output was replaced by its first 4,096 bytes, and
the compiler was killed by SIGXFSZ, so it reported nothing. With the signal
ignored the write fails with EFBIG and the String error carries only a
number. `write_text` instead leaves the target as it was in every such case
(the `file_too_large` runtime case, which uses a real `RLIMIT_FSIZE`).

## The algorithm

1. A NUL is `PathContainsNul`; `""` is `NotFound`; a path ending in `/` is
   `IsADirectory`. None of these makes a system call.
2. `lstat`. ENOENT: a new file in `realpath(parent)`. A link: `realpath(path)`,
   then `lstat` of the result (D4). A directory is `IsADirectory`, any other
   non-regular file `NotARegularFile`. An existing regular file is opened
   `O_WRONLY | O_NONBLOCK | O_CLOEXEC` without `O_TRUNC`, `fstat`ed for owner
   and mode, and closed.
3. `.blorp-tmp-<pid>-<counter>` in the target's directory, `O_CREAT | O_EXCL`,
   0600 for a replacement and 0666 for a new file. The counter is a
   process-wide `_Atomic uint64_t`. EEXIST takes the next counter, up to
   `BLORP_FS_TEMPORARY_ATTEMPTS` (100); exhaustion is `OtherOs(EEXIST)`.
4. `fchown` to the target's owner and group; on EPERM, `fchown` of the group
   alone, whose EPERM is ignored. Then `fchmod`, then the write loop.
5. `F_BARRIERFSYNC` on macOS, `fsync` on ENOTSUP; `fsync` elsewhere. EINTR is
   retried, any other error is final. One close; its failure fails the write.
6. `rename`. Every failure up to here unlinks the temporary file.
7. `open(dir, O_RDONLY | O_DIRECTORY)` and `fsync`; EINVAL and ENOTSUP count
   as success.

## Provenance

| | Base | Candidate |
| --- | --- | --- |
| Commit | `d2bbd1f0e` (`git archive`, no `.git`) | `42d585548`, the `blorp2/fs-write` commit before this report was added |
| B (sha256) | `1d1874d9ed9144db42af9ada1943e655f1d6aa2966c15c13a601f2367313d948` | `6865cf0c3d7299b81451a7d6bdbf8312ba678cace4f4201a6dccdff1a909b710` |
| B's C (sha256) | `265dc0a7f359199da199dc1e71889d108eaa1e1d89e1b42c654b41e003fa161f` | `d181647e78db7c37eb4356976a5fbceef9fb681fc932e759fcb7c18b7c6efdf7` |
| Self C (sha256) | `cde87d5ba0523ce085fbce8ea3f84e3459b45dc555a70b0f6cf1c5c45d42e17f` | `4e2e098b4596d834c5b854f43e971f6c0a13ac6d385f38ef9118091e5062b294` |
| Self C bytes | 23,060,412 | 23,104,590 |
| `-O2` compiler (sha256) | `2eb3607db480d5040afe9b1f9cfa172996d43aebd184c4a9def489fbcc63d7a2` | `9dd09be58e9d7a8204918695cdd81749a2cf01729f283462d60cdcec8b3bf9b2` |

Both B build from the pinned seed (`blorp2-seed-0d11bd3de938`). The
fixpoint's stages A, B and C all emit the candidate self C above. After the
measurement the commit changed only the file mode of `prepare_write.sh`.

Review fixes, after the measurement, changed `src/runtime/` text only (the
group-only `fchown` retry, an `OtherOs` helper, the barrier's result test and
the prelude's `#error` wording) and no compiler logic. Rechecked afterwards:
the base `src` still compiles to the base self C byte for byte; the candidate
self C is `8aa524a3dfec84b64b00135d03e6228ca92fe04e4a864af2dcd870886c3fd4a2`,
23,106,425 bytes, emitted by fixpoint stages A, B and C; self-compile
allocations are 14,812,654 (+0.021% over the base). Instructions were not
re-measured: the fixes add 9 lines of String constants and no compiler code.

Machine: Apple M4, macOS 26.7.1, Apple clang 21.0.0, load average 4.3 to 5.4
from other sessions. Every run was serial, base then candidate in each round.
Raw samples are under the ignored `build/fs_write/` of the candidate worktree,
with the script `build/fs_write/measure.sh`.

## Ceilings

| Metric | Ceiling | Used by (i-a) | Measured here |
| --- | --- | --- | --- |
| Compiler logic, `src/` without `src/runtime/`, net | at most 10 for this operation, +40 for 2a | +9 | +3 (`syntax` +2, `builtins` +1) |
| `src/runtime/`, net | reported | +159 | +245: see below |
| Fixed-input instructions, `-O2` | +0.2% for 2a, cumulative | +0.033% | minimum of 15: 12,771,867,323 to 12,769,571,594 (-0.018%); median of the second 10: +0.09% |
| Self-compile allocations | +1.0% for 2a, cumulative | +0.065% | 14,809,593 to 14,812,645 (+0.021%) |
| Self-compile instructions, `-O2` | +1.0% for 2a, cumulative | +0.073% | 12,775,472,058 to 12,762,649,897 (-0.10%) |
| Self-compile instructions, `-O0` | +1.0% for 2a, cumulative | +0.094% | 37,049,309,295 to 37,045,354,044 (-0.011%) |
| Self C of the base `src` | byte-identical | met | met, below |

Instructions are the minimum of five interleaved runs (fixed input: of five
plus ten alternating). The spread between runs of one binary was 0.2% to 0.3%,
larger than every difference above, so the signed figures are noise around
zero, not savings. The deterministic signals are the allocation count, +3,052
for the compiler's new source, and the self C, +44,178 bytes (+0.19%), which
is the new fragment and prelude text the compiler now carries as String
constants. Cumulative for 2a, every metric stays below its ceiling.

`src/runtime/`: `fs.brp` +238 -4, nearly all C text, with 11 Blorp comment
and declaration lines; the removed lines include the read fragment's request
cap, which moved to the shared helpers as `BLORP_FS_REQUEST_MAXIMUM` because
the write loop needs the same cap, and the `OtherOs` encoding, which moved
into `blorp_fs_other_os_code`. `process.brp` +10 -2 (the prelude's two new
definitions, their comment and the `#error` wording) and `system.brp` +6 -3,
of which +2 net is table logic.

Tests and library: `standard_library/fs.brp` +26 -1. Tests +1,498 -50, of
which `test/runtime/fixtures/fs_write_test.c` is 1,053 lines. Docs: the two
READMEs, `blorp_2/AGENTS.md`, `grammar.ebnf` and the Makefile.

## Self C

The candidate `-O2` compiler compiled the base `src` and library. Its output
is byte-identical to the base self C (`cde87d5b...d42e17f`): the base `src`
uses neither `FsWriteText` nor the prelude, so neither the new row nor the
prelude change reaches it.

## Platform findings

- **glibc hides `realpath` under `_POSIX_C_SOURCE` alone.** On Ubuntu 24.04
  (glibc 2.39, GCC 13.3, `-std=c11 -Werror`), a probe that defines only
  `_POSIX_C_SOURCE 200809L` fails with an implicit declaration of
  `realpath`. The prelude therefore also defines `_XOPEN_SOURCE 700` when it
  is not already defined.
- **macOS hides `F_BARRIERFSYNC` under `_POSIX_C_SOURCE`.** Confirmed with
  Apple clang: the constant is visible only with `_DARWIN_C_SOURCE`. The
  prelude defines it under `__APPLE__` when it is not already defined (the
  guard avoids a redefinition warning against `-D_DARWIN_C_SOURCE`), and the
  write fragment has `#if defined(__APPLE__) && !defined(F_BARRIERFSYNC)` /
  `#error`.

## Gates

- `make -C blorp_2 test`: exit 0, 1,018 PASS lines, 0 FAIL. The new tests in
  its output:
  - `fs write label` (1), `fs write builtin contract` (3), and 2 in the
    shared `fs builtin C emission` suite (`test_emit/test_fs_operations.brp`,
    renamed from `test_fs_read.brp`);
  - `fs runtime`: 18 new C cases (27 in all);
  - the e2e write example and the direct native program (2).
- `scripts/blorp2-fixpoint --prove`: exit 0. A, B and C emit one self C, and
  the fixture parity pass covers 671 fixtures.
- The runtime C fixtures build and pass under
  `-std=c11 -Wall -Wextra -Werror -pedantic` with ASan and UBSan and the strict
  leak check, 0 leaked: on macOS in the suite, and on Ubuntu 24.04 (arm64, uid
  1001) with GCC 13.3 under ASan and UBSan, and with GCC at `-O2` without
  sanitizers, in the repository's Docker image. On Linux the flush path is
  `fsync` and the fcntl wrapper is not compiled.
- The write example and the direct native program build under GCC with
  `-Werror` there, run with 0 leaked, and the example's output is identical
  to the output pinned on macOS.
- `git diff --check`: clean.

## Oracles

Each run broke `src/runtime/fs.brp` in one place, rebuilt the write probe
from the broken fragment, restored the source, and ran every write case.
Failing cases, and only these:

| Broken | Failed |
| --- | --- |
| 1. The flush moved after the rename | `order_replace`, `order_new`, `interrupted`, `flush_failure`, `barrier_unsupported` |
| 2. The flush retried after EIO | `flush_failure` |
| 3. The temporary file not unlinked on a failure | `flush_failure`, `close_failure`, `rename_failure`, `owner`, `file_too_large` |
| 4. `O_TRUNC` added to the writability probe | `flush_failure`, `close_failure`, `rename_failure`, `temporary_names_exhausted`, `owner`, `file_too_large`, `permission_kinds` |
| 5. The temporary file created in the link's directory | `symlinks` |
| 6. EEXIST exhaustion mapped to `AlreadyExists` | `temporary_names_exhausted` |
| 7. `fchmod` before `fchown` | `order_replace`, `owner` |
| 8. A write before `fchmod` | `order_replace` |
| 9. An extra `close` on the flush-failure path | `flush_failure` |
| 10. No group-only `fchown` after EPERM | `owner` |

The strengthened read case: with the writer's open moved before its wait for
the tick, so that only the read is interrupted, `interrupted_open` now fails
on `interrupted_opens >= 1`. Before, it passed.

## Deviations from the plan and brief

- **The temporary name has no base name in it**, `.blorp-tmp-<pid>-<counter>`,
  so it always fits NAME_MAX (the plan said to truncate the base name).
- **`prepare_write.sh` is a second script**, not part of `prepare.sh`. The
  harness runs every example twice (normal, then strict) with the same
  arguments, and the write example changes its directory, so the directory
  must be rebuilt before each run; `prepare.sh` builds the read tree once and
  is not rerunnable. The harness's `run_fixture` is split into `run_normal`
  and `run_strict` so that `verify_fs_write` can prepare between them.
- **A `write` that returns 0** for a non-empty request is reported as
  `OtherOs(EIO)` rather than looped on forever. POSIX allows 0 only for an
  empty request to a regular file. Not in the brief.
- **The directory descriptor's close is not checked**, like the probe's:
  nothing is written through either.
- **The suite leaves out the permission case as root**, as the e2e examples
  are left out, using `/usr/bin/id -u`, so that it earns no PASS credit; the
  case itself asserts that it is not root.
- **EPERM from `fchown` retries the group alone.** Otherwise a shared 0660
  file would take the writer's group while keeping the old group's bits.
- **`self_hosted.brp` is unchanged**: the write probe is part of
  `fs_suite.brp`, which it already runs.

## Follow-ups

- **(ii) and (iii).** The seed rotation, then moving `src`'s writes, which
  today truncate their target as shown above, to `fs.write_text`.
- **GCC 13.3 prints a note for long emitted lines.** Building the fs
  examples' generated C with GCC 13.3 (Ubuntu 24.04) prints
  `-Wmisleading-indentation is disabled ... since column-tracking was
  disabled` on stderr (exit 0), for the read example as well as this one. The
  harness requires an empty C compiler stderr. GCC 15.2, which CI's GCC leg
  uses, prints nothing, so this is not a CI failure.
