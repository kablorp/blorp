# Host file/output contract coverage

## Problem and scope

Base `ddd1855092c1daec0726eb929207de4a1506e34c`, branch
`codex/host-file-output-tests`.
Reviewed status (2026-10-17): tests +391/-1; production 0.
10 public callbacks passed; 9 nested native cases and 1 outer driver passed separately.
Runtime 4,844 / leak 1,315 reported checks and hygiene passed.
Three compiled native mutants killed; exact restores returned native 9/9 green.
Open errors still use locale text; fixed operation/numeric codes with valid UTF-8
remain uncovered. Stderr interruption/failure policy remains unspecified.
Root/peer final code/evidence reviews approved with zero findings.
The planned procedure below records the original design.

Host signatures fit: `system.brp:41` supplies String write_file; `io.brp:31–36`
instantiates Stringable print_error with identity conversion
(`string.brp:1066–1068`). Temporary APIs stay monomorphic String; no API change.

## Actual code and two small cases

Current `blorp/src/lib/runtime/native/runtime.c:35170–35178`:

```c
size_t n = fwrite(content->data, 1, (size_t)content->len, f);
if (n != (size_t)content->len) {
    fclose(f);
    return blorp_result_err_cstr("write_file: short write");
}
```

Case one: ordinary Blorp TestSuite writes long UTF-8/NUL/CRLF content, then
`"é\0\r\n"`, then empty. Require Ok and independent read_bytes length/bytes
after each write. Middle bytes: `[195, 169, 0, 13, 10]`; no suffix survives.
Missing-parent Err needs useful nonempty valid text, without locale wording.
NUL-path Err equals `write_file: string contains embedded NUL`; no prefix-named
file may appear.

Current stderr helper, `runtime.c:7643–7647`:

```c
if (s && s->len > 0) {
    fwrite(s->data, 1, s->len, stderr);
}
fputc('\n', stderr);
```

Case two: capture real stdout/stderr descriptors; production prints
`"é\0\r\nx\n"` exactly plus one LF, with zero stdout bytes. Also cover empty,
non-ASCII and internal-LF messages. Flush/capture/restore through real libc.
Stderr interruption/retry/unrecoverable-error policy remains open.

## Native failures and ownership

Follow existing `test_read_file_safety.brp:196–259` and
`fixtures/read_file_admission.c:19–59,86–98,201–225`: one native compile per suite,
named cases through its real main, included production runtime, narrowly scoped
libc seams, sanitizer checks and physical free observations. Native flags:
`-std=gnu11 -O0 -DBLORP_MEMORY_DIAGNOSTICS=1 -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer`;
existing BLORP_CC selection.

Inject short fwrite after real prefix transfer; fclose error after real closure;
both failures with different cleanup errno; fdopen failure leaving the real
descriptor for production close. Otherwise delegate real syscalls. Assert exact
short-write/close Err, primary-error preservation, one fclose/close, and actual
F_GETFD/EBADF closure. Check descriptor closure before counters so omitting
cleanup kills that oracle. Validate error UTF-8 with the existing validator.

Observe owned Err payload/result freed once. Borrowed inputs survive unchanged
until explicit release; observe their frees separately. Record identities before
release; never dereference freed storage. Counters alone are insufficient.

Add one native positive long→short→empty counted-write case, independently reading
raw bytes with libc. It directly exercises the included current runtime.

## Budget and proposed files

Production **0**. Extend existing test_file_io.brp: 80–110 lines; new
test_file_output_contract.brp ordinary native-suite launcher: 70–90; new
fixtures/file_output_contract.c: 260–300 including the small positive case.
Total estimate **410–500 added/net**,
hard **500 added/+500 net**, including C, comments and blank lines; no deleted
coverage or compression. No language fixtures. Owning notes0, maximum20 if needed;
plan separate. Stop if inadequate. Three ordinary behaviors; nine native cases:
four failures, four stderr payloads, one positive write/truncation.

No replacement runtime, framework/controller, generated-symbol language driver,
alternate entrypoint, cache, decoder, error-policy fix or performance claim.

## Commands, acceptance and handback

Later serial slot only: own `make`, require `scripts/compiler-build-status` FRESH,
then run each proposed suite separately:

```bash
cd /Users/keithphilpott/.codex/worktrees/host-dirname/blorp
bin/blorp test --suite --timeout 180 --std-dir "$PWD/standard_library/src" blorp/test/test_runtime/test_sys/test_file_io.brp
bin/blorp test --suite --timeout 180 --std-dir "$PWD/standard_library/src" blorp/test/test_runtime/test_sys/test_file_output_contract.brp
scripts/test --serial --no-build runtime leak
make hygiene-check artifact-scan
```

Keep the Blorp host/driver pinned. Its public Blorp cases do **not** prove
mutations to runtime.c. Each native-suite invocation recompiles the fixture
including the actual current runtime.c; record that hash and compiler command.
All three mutants use this same native suite: strlen write count must fail the
positive case; omitted stderr LF must fail stderr bytes; omitted short-write
fclose must fail the actual descriptor-closure assertion. Require successful
compilation, named failures, exact restores and native-green between/after
mutants. No mutant lands or host rebuild is silently substituted.

Accept only exact bytes/errors, real cleanup and ownership observations,
sanitizer success, three killed mutants, exact restores and production diff zero.
Return counts, source/test/binary/patch hashes, raw commands/status/output under
ignored build/, and limitations. Stop for unexpected production behavior,
unavailable fault seams, budget breach or scope growth; request root's decision.
