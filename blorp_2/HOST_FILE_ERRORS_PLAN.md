# Counted file I/O returns stable, owned OS errors

## Problem, authority and boundary

Initially a plan at `72164f17a21d8e375efceb77503b92318e97340d`, branch
`codex/host-file-errors`; root and independent review preceded separately granted
implementation, tests, builds and measurements. The scoped change is now
implemented; final review precedes a separately granted commit. Preserve previous
branches, ignored evidence, main and every frozen epoch; compiled work is serialized.

[M6](ROADMAP.md#m6-library-and-shell) requires valid-text fixed-operation/numeric
OS errors. At that base, `runtime.c:35164` routed write_file open failure through
`blorp_path_errno_result:35083`, copying unchecked locale strerror bytes.
Read seek/tell/I/O/close and write short-write/close errors omitted numeric codes.
Read-open capture at `35107–35112` is already correct and tested: leave it intact.
The other starting references are [HOST_FILE_OUTPUT_TEST_PLAN](HOST_FILE_OUTPUT_TEST_PLAN.md)
and the existing read-admission/output native fixtures, not a new harness.

## Proposed implementation and exact diagnostics

Only `blorp_read_file`, `blorp_write_file` and one local static helper change.
Keep the shared locale helper and its other callers unchanged. The helper takes
a trusted fixed ASCII prefix and an already-saved int, builds decimal text using
the existing read-open precedent, and returns an owned Err with release_mask=1:

```c
static blorp_Result* blorp_file_errno_result(const char* prefix, int code) {
    blorp_String* message = blorp_string_append_int(
        blorp_string_create(prefix), code);
    return blorp_result_err_owned(message);
}
```

Before (`runtime.c:35163–35166`):

```c
blorp_Result* res = blorp_path_errno_result(path, cpath);
free(cpath);
return res;
```

Planned replacement:

```c
int open_errno = errno;
free(cpath);
return blorp_file_errno_result("write_file: open failed; errno=", open_errno);
```

Capture errno immediately after each failing operation, before cleanup, free,
release, ferror or message construction. Never infer/fix the code or call
strerror. Before (`35132–35136`), every short fread returns `read_file: short read`.
Planned distinction, with the same physical cleanup and unpublished-data lifetime:

```c
if (n != (size_t)len) {
    int read_errno = errno;
    bool io_failed = ferror(f) != 0;
    fclose(f);
    blorp_release(content);
    if (io_failed) {
        return blorp_file_errno_result("read_file: read failed; errno=", read_errno);
    }
    return blorp_result_err_cstr("read_file: short read");
}
```

Append the captured decimal int to these exact prefixes:

| Failure | Old diagnostic | New prefix |
| --- | --- | --- |
| Read seek end | `read_file: non-seekable file` | `read_file: seek end failed; errno=` |
| Read tell | `read_file: non-seekable file` | `read_file: tell failed; errno=` |
| Read seek start | `read_file: seek failed` | `read_file: seek start failed; errno=` |
| Read I/O short transfer, ferror set | `read_file: short read` | `read_file: read failed; errno=` |
| Read close | `read_file: close failed` | `read_file: close failed; errno=` |
| Write open | path plus locale message | `write_file: open failed; errno=` |
| Write short transfer | `write_file: short write` | `write_file: short write; errno=` |
| Write close | `write_file: close failed` | `write_file: close failed; errno=` |

EOF/non-I/O short read keeps exact `read_file: short read`, ignoring stale errno.
Preserve single attempts, including EINTR and partial transfers: no retry loop.
Attempt close once even if close reports EINTR; never reuse that FILE afterward.
Primary failure wins over cleanup failure; release staging before publishing Err.
NUL rejection precedes open; transfer failure precedes close/UTF-8 admission;
close failure precedes malformed-content diagnosis, preserving current priority.
Keep exact NUL and invalid-UTF-8 teaching messages. Borrow inputs; success remains
read Ok(String)/mask1 and write Ok(void)/mask0. No success-path data-model change.

## Test-first changes and independent oracles

Extend existing TestSuites/C fixtures only. New public write-open prefix assertions
in `test_io_errors.brp:test_write_file_err_msg` and
`test_file_io.brp:test_missing_parent_error` replace/strengthen nonempty checks;
retain UTF-8 validation. Existing read-open prefix/ENOENT tests remain unchanged.
Update output fixture's exact short-write/close expectations to prefix+platform
EIO/ENOSPC; fdopen failure becomes exact write-open/EMFILE. Preserve ownership,
byte, NUL, truncation and all stderr cases. No existing exact seek/EOF public
oracle needs replacement; FIFO tests still return Err.

Add these named native read cases to read_file_admission.c and its existing
test_read_file_safety.brp driver:

| New case | Observation |
| --- | --- |
| `read_seek_end_errno` | EINTR captured, one seek/close, distinct cleanup errno cannot replace it |
| `read_tell_errno` | EIO captured before close; no fread/staging publication |
| `read_seek_start_errno` | ESPIPE captured; no fread/staging publication |
| `read_io_errno` | EIO/EINTR subcases, real prefix transfer, one fread, ferror classification |
| `read_io_cleanup_errno` | EIO survives ferror/close clobbering with different codes |
| `read_eof_short` | Real EOF, clean/error cleanup subcases retain non-errno text |
| `read_close_errno` | ENOSPC/EINTR survive release clobbering; close once; close error precedes malformed bytes |

Tell seam can advertise one extra byte for EOF; delegated full fread then really
reaches EOF. Assert feof set/ferror clear. I/O seams delegate a real prefix read
then supply the named failure/ferror; ferror may clobber errno to prove early save.
Other seeks/tells delegate normally except the selected failure. Close delegates
physically before reporting the injected failure. No replacement runtime/buffers.

Add `write_open_errno_ascii`, `write_short_eintr`, `write_close_eintr` through the
existing file-output fixture/driver. Open case uses a genuinely absent parent and
a scoped strerror fake returning invalid `0xff`: assert zero calls and exact
ASCII prefix+ENOENT. This must fail on the old producer. Existing read-open stays
green. Transfer/close EINTR cases require one attempt; combined failure keeps EIO
over cleanup ENOSPC. Numeric expectations use independent snprintf plus errno
constants, exact length/bytes, Err tag/mask and existing UTF-8 validation.

Observe real target descriptors via F_GETFD/EBADF before counters or oracle opens.
Observe staging freed once on post-allocation read errors, no staging-free event
on earlier failures, owned Err/result freed once and borrowed inputs surviving
until explicit release. Clear recorded identities before address reuse; never
dereference freed storage. New observations use scalar counter deltas, not reset
assumptions; preserve existing read-success allocation/UTF-8 admission oracles.

First run reviewed tests against unchanged native source: new text/code oracles
must fail semantically after successful compilation. Keep a pinned host driver;
each native invocation freshly compiles included CURRENT runtime.c. Public
runtime errors require an actually rebuilt candidate host, not a stale host
compiling new test source. Capture commands/hashes at both boundaries.

After implementation, kill mutants that use cleanup errno, erase the ferror/EOF
distinction, restore the locale write-open path, and omit read-error staging
release. Require intended named failures, exact runtime restores and native green
between/after mutants. Preserve read-open/NUL/invalid-UTF-8 controls throughout.

## Budgets, docs and non-goals

Hard physical limits: production C <=80 added/+50 net; tests <=300 added/+280 net;
public docs <=24 added/+20 net. Estimate C 40–65 added/+20–40 net; read fixture
155–190 added, write fixture 60–75, Blorp/public/driver 15–25, total tests
230–290 added and <=280 net. Docs 8–14 added, <=12 net. Count C fixtures, comments
and blanks; delete no coverage and do not compress. Stop/rescope if insufficient.
This plan is separately limited to220 lines; implementation is recorded below.

Public docs: system.brp file comments, GUIDE.md near2080 and GRAMMAR.md near192
state fixed operation/numeric OS errors, EOF distinction and fail-fast policy;
no syntax rule changes. Only the file functions, listed tests/docs and this plan
may change. Stderr policy and stdio-versus-fd design are explicitly independent,
OUT OF SCOPE, as are other OS APIs, shared locale-helper cleanup, retries,
registries, caches/frameworks, target/temp-library changes and epoch updates.

## Later validation, costs and handback

Only after root grants ownership/compiled slots: pin accepted source/host/std,
build own candidate, require FRESH; run each focused suite with --suite,
--timeout180 and explicit own --std-dir: test_io_errors, test_file_io,
test_read_file_safety and test_file_output_contract. Use existing GNU11/O0,
diagnostics1, ASan+UBSan/no-recovery native compile pattern. Keep nested native
cases separate from outer-driver counts. Then run:

```bash
scripts/compiler-check --changed --plan
scripts/test --serial --no-build runtime leak std-check doctest
make hygiene-check artifact-scan
```

Suggested acceptance cost ceiling: <=+0.5% allocations and normal min3 retired
instructions on BOTH self and retained small workloads. Native helpers require
strict zero leaks; the [host bootstrap limitation](HOST_BOOTSTRAP_LIMITATIONS.md)
records the user's separate decision. Use the existing stage2 normal/diagnostic
pairing, same input/std/toolchain/bootstrap/optimization and small.brp hash.
Root must approve paired baselines/input first. This plan grants no new baseline,
epoch transition, leased-host rebuild or measurement. After a separate grant:

```bash
benchmarks/self_compile_measure --stage2 --samples 3 --program self \
  --input-rev "$approved_input_rev" --baseline "$approved_self_json" \
  --label host-file-errors-self --output "$fresh_self_json" --keep-output "$fresh_self_c"
```

Repeat with small and root-approved small baseline/fresh paths. Retain all samples;
no exclusions/retries/waivers. Normal/diagnostic C must match within each variant;
deterministic fixpoint stays exact. Cross-change C includes intentional new helper
and error-text deltas: review full raw diffs, never normalize unexplained drift.
Schedule the standard `scripts/compiler-fixpoint` for exact stage2==stage3 proof
when root grants acceptance work; no additional compiler controller is proposed.
No speedup is claimed. Preserve staged/binary provenance; run manifest-selected
handback gates proportionately, with final current-main integration owned by root.

Accept test-first red/candidate green, exact error/ownership/priority oracles,
killed mutants/restores, required gates and agreed costs within caps. Return
separate production/test/docs counts, full hashes/commands/statuses, raw ignored
build evidence and concise limitations here. Stop for host defects, unexpected
drift, scope/budget/cost breach or unavailable baseline authority. Root/peer review
precedes commits; no push/main modification is authorized by this plan.

## Implementation and acceptance record (2026-10-17)

Counts: C +26/-8 (net18), tests +286/-21 (net265), public docs +14/-1 (net13).
Native read20/write12 and public errors6/file-I/O10 pass; all six mutants failed
as intended, with exact runtime restores/green. Broad 7,231 tests passed at the
prior 284-added-test-line epoch; the two later close assertions have native greens.
O2 SELF/SMALL allocations are unchanged; normal min3 instructions -0.0370%/+0.0512%,
within +0.5%; measured C is exact. Measured input source/std is `72164f17a21d`.
Raw explicit-pair metadata remains stage1/unknown revision/freshness; standard
builder receipts establish stage2. At `artifact_construction_complete`, allocator
bytes are +16,384/workload versus B; this phase snapshot is not final balance.
O0 fixpoint: all three C outputs SHA256 `d96c1d3d8195fe3135b7e98a089b34a2aa2d694be78b6154742786f36808e3e6`.
Raw evidence under `build/host-file-errors/`: `cost-721-01/` and
`fixpoint-01.log`, `fixpoint-01.result.json`, `fixpoint-01/` (full C retained).
