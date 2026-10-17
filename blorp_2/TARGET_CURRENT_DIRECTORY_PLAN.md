# Target current-directory Result slice

**Status: implemented and validated; integration review pending.** The target
phase/native gates, six mutation oracles and 483-case cost corpus pass. The
host source-to-C proxy meets its cost ceilings under the user's explicit
host-only bootstrap leak exception; its strict memory observations remain
failed. No pilot/native memory exception or source-cleanup cap waiver applies.
Commits and integration still require a separate coordinator grant.

## Problem, pins, and scope

At the planning baseline, target programs could not import
`system.get_current_directory`: the temporary library had no `system.brp`, and
the parser had no corresponding builtin tag.
Existing imports, ordinary match, String, and owning unions suffice for this
single native Result witness. It may overlap M2/M3 after review; broader M6 and
actual compiler loader migration retain their roadmap order. This neither
completes M6 nor establishes target self-compilation.

Plan base: `ddd1855092c1daec0726eb929207de4a1506e34c`, branch
`codex/target-current-directory-plan`, in the separate managed
`target-current-directory-plan/blorp` worktree. Base SHA256 pins:

| Input | SHA256 |
| --- | --- |
| `ROADMAP.md` | `d3a3bacf446cc39c12291aa3cc7dab13755ded88aeb343f7bcf40659c23e4788` |
| `src/namespace/builtins.brp` | `7a4df23c56ae354151967a884867ac202a1168b400880ed4c5b0eadf47ad9cb4` |
| `src/runtime/string.brp` | `d23510a3bf481aa821c67b022dec037b14678396b832ca1b0e4f5d248e33040d` |

The source-byte implementation, original failed cost run, hosts `34ac`/`be31`,
and original cumulative/local 3% rules remain frozen and unchanged. This feature
uses a separate future measurement packet; it neither replaces that baseline
nor subtracts accepted feature costs from its failed result.

## Witness and authoritative facts

Proposed `standard_library_temp/system.brp`:

```blorp
import:
    _base: String, Result

func get_current_directory() -> Result[String, String]:
    builtin("system.get_current_directory")
```

The adapter must follow existing temp-module upstream revision/SHA256 headers.
Use the actual accepted supporting-host `standard_library/src/system.brp` once
its new API lands; base DDD does not contain that function. Record the accepted
commit and exact source-file hash, and review this explicit provenance update
before the feature freeze. Do not land placeholder/older header pins or treat a
later header change as permission to silently alter a frozen measurement epoch.
This source provenance requirement does not import the host's native ABI.

Proposed `test/e2e/fixtures/current_directory/basic.brp`:

```blorp
import:
    system: get_current_directory
    io: print

func main() -> Int:
    match get_current_directory():
        Ok(path):
            print(path)
            0
        Err(error):
            print(error)
            1
```

Run its normal unmodified main at CWD `/`: exit 0, stdout exactly `/\n`, stderr
empty. A second run in an explicitly selected existing temporary directory uses
the exact stdout bytes of `/bin/pwd -P` in that same CWD (already one LF), status 0
and empty stderr; do not trim or normalize the oracle. No PWD/environment fallback.
The fixture's Err arm specifies exit 1, error payload plus LF on stdout and
empty stderr, but is not claimed as deterministic native-Err main coverage.
The pre-implementation rejection and its exact diagnostic are retained in
`build/target-current-directory/first-red-root/receipt.json`; the original
first-red packet is unchanged.

The planning-baseline [builtins](src/namespace/builtins.brp) contained:

```blorp
fixed union RuntimeResult[Variant, Element]:
    ValueResult(RuntimeType[Element])
    OptionalResult(RuntimeType[Element], DesignatedOption[Variant])
    BooleanResult(DesignatedBoolean[Variant])
```

Add only `ResultResult(RuntimeType[Element], RuntimeType[Element],
DesignatedResult[Variant])` and operation
`GetCurrentDirectory(DesignatedResult[Variant])`. Existing
`DesignatedResult {ok, err}` and foundation designation at `builtins:389–422`
already establish role identities once. Schematic accepted facts:

```text
k/e = foundation's opaque Ok/Err VariantIds; no numeric positions assumed
operation = GetCurrentDirectory({ok=k, err=e})
contract = {purity=Impure, parameters=[],
  return_type=ResultResult(PrimitiveRuntimeType(BuiltinString),
    PrimitiveRuntimeType(BuiltinString), {ok=k, err=e})}
checked result = AppliedUnionType(variant_owner(k), [StringType, StringType])
```

`runtime_contract` is the sole signature authority. Add parsed tag
`GetCurrentDirectoryBuiltin`, exact label recognition/help in `parse/parse.brp`,
and operation acceptance in `check/signatures.brp:352`. Its existing
`runtime_result_type:405` currently constructs only value/Option/Bool types;
extend it to use the designated owner and ordered success/error payload types.
`validate_builtin_body:412` rejects pure, generic, parameterized, or wrong-result
declarations. Proposed rendered contract rejection is exactly
`builtin declaration does not match its runtime contract`, help
`declare an impure nongeneric function with no parameters returning Result[String, String]`.
Keep the existing builtin span and no note. Pure callers receive the existing
purity diagnostic, with exact message/help/span pinned by a regression.

## Concrete identity, ownership, verifier, and emission

Mirror `translate_option` in [specialize:2034](src/specialize/specialize.brp):
translate both declaration IDs through the call's concrete result instance.
Existing `translate_variant:2209` checks declaration ownership and membership.
Extend `runtime_signature:187` for ResultResult. No spelling recovery, raw ID
equivalence across authorities, repeated signature solving, or new registry.

Existing layout rules produce `ConcreteUnion {variants=[[StringType],
[StringType]], representation=InlineOwningPayload}`. Its ABI is a by-value
tagged union, with one String pointer in each alternative and no union heap box.
`value_ownership:444` publishes `InlineOwnedFields`; `own/own.brp:611` already
makes managed calls `OwnedResult`. Payloads borrow their parent; an escaping
child acquires ownership before parent retirement. Ordinary generated union
dup/drop selects the active slot and retains/releases that String. Do not change
generic lowering or ownership unless a concrete missing invariant is reported
and separately reviewed.

`verify/verify.brp:473` currently hardcodes an empty second payload:

```blorp
first_type ?= variant_type(first, first_payload, unions, span)
second_type ?= variant_type(second, [], unions, span)
```

Add an explicit second-payload argument; existing Option/Bool calls pass `[]`,
Result passes its exact error payload. Independently verify both payloads,
distinct variants, common owner, two-variant coverage, result type and ownership
obligation. Equal String payloads cannot distinguish swapped semantic roles;
foundation designation establishes roles, and reversed-order/branch tests must
protect their use rather than re-resolving names in verification.

The existing [emit:1133](src/emit/emit.brp) transfer precedent is:

```blorp
-- Some takes the fresh root. Scratch is neither retained nor released here.
append_optional_value(prefix, id, option, scratch.concat("_some"), scratch, unions, span)
```

Add one operation-specific emitter: initialize one String scratch, invoke the
native helper exactly once, and use `c_union_value:968` with designated Ok/Err
IDs, passing that same fresh scratch to either selected constructor. No retain
or release follows this transfer. Update exhaustive operation observers,
declaration help, `c_callable`, runtime inventory/requirements and fragment
selection directly. The helper is selected only when called, not by adding a
system import to the implicit prelude. Append the new exported fragment constant
directly; do not introduce a zero-argument literal-returning function or convert
the existing fragment functions in this slice.

## Total native contract and reviewed test seam

New `src/runtime/system.brp` exports the literal String constant
`SYSTEM_CURRENT_DIRECTORY_RUNTIME`; its raw initializer contains the helper
below and its body. The publication form is:

```blorp
SYSTEM_CURRENT_DIRECTORY_RUNTIME: String =
    raw
        |/* target current-directory helper definitions */
```

This needs no grammar extension: `parse/parse.brp:1245` maps PipeString to
StringExpression, `consume_constant:3464` accepts the existing initializer, and
`check/constants.brp:55` admits StringExpression as StringConstant. Existing
integer-runtime constants at `emit/emit.brp:1951` establish the direct constant
consumer precedent. Aggregate and computed constants remain outside scope.

The constant emits this native ABI:

```c
uint8_t blorp_get_current_directory(struct blorp_string **result);
/* 1 = Ok, 0 = Err. Every normal return writes exactly one fresh,
 * nonnull, valid-UTF-8 String with references == 1. */
```

Name the discriminator constants, initial capacity (256), representable bound,
and formatting capacity. Grow only on ERANGE, doubling without overflow and
capping at the smaller bound imposed by String's Int64 length and allocation
size including header/terminator. Exhaustion returns numeric EOVERFLOW. Other
errors, including EINTR, return immediately. Save errno before any cleanup.
Normal successful getcwd supplies a terminator inside capacity; test stubs must
honor that contract. Inspect only through that terminator, reject empty/relative
success before UTF-8 validation, and preserve valid pathname bytes exactly.

Reuse target `string_runtime()`'s `blorp_utf8_is_valid`, trusted
`blorp_string_from_bytes`, and String release. Free staging once on every normal
exit; realloc transfers its one staging obligation. No pathname String is
allocated before validation. OOM keeps existing target malloc/realloc abort
behavior as an infrastructure failure. Numeric errors use one bounded stack
format followed by one fresh String, not a host append/Result constructor.
Exact payloads:

```text
get_current_directory: failed; errno=<saved platform decimal code>
get_current_directory: native path must be nonempty and absolute
get_current_directory: invalid UTF-8; use a working directory with a UTF-8 path
```

The reviewed host plan in the separate `host-current-directory-plan` checkout,
SHA256 `35a0a69bca538114d9b7ccdbe5b25e835c625ed25bcd214e020878e3dfd490a2`,
provides a 13-case precedent. Its current uncommitted fixture was inspected, not
accepted as measured target evidence. Reuse only the local wrapper pattern:
headers first, wrappers calling real malloc/realloc/free, then macro aliases
around includes of the unchanged production fragments, then undefine aliases.
Only getcwd outcomes are scripted; observation records allocation occurrences,
not reads after free or pointer-address uniqueness. No production hook, flag,
tracing, alternate language main, rewritten C or generated language-symbol call.

Native cases: real query; growth beyond 4096; growth then EACCES; one-call EINTR;
cleanup clobbers errno; exact root/multibyte/whitespace; malformed spare bytes
after terminator; malformed UTF-8 classes; empty success; relative success;
simultaneously live fresh calls; owned Ok cleanup; owned Err cleanup. Each
normal query has one managed String allocation/final release, not the host's
outer Result allocation. Assert staging allocation/realloc/free occurrences and
zero live storage. Test generated active-slot destruction separately with normal
aggregate fragments. The 4096 case is synthetic growth coverage, not a claim
about real OS pathname limits. Exhaustion/OOM bounds receive source review;
do not add configurable capacities or forced allocation sizes.

## Tests, commands, and acceptance

Blorp TestSuites own every callback. Initial red:
`test/unit/test_check/test_current_directory.brp` expresses the builtin using
existing APIs before adding new enum names. Then add granular callbacks:

Its first callback `test_current_directory_checks_as_designated_result` feeds
this aligned source to existing `parse_modules(...).and_then(check...)`, using
`setup_diagnostic` as current checker tests do, and expects success:

```blorp
func query() -> Result[String, String]:
    builtin("system.get_current_directory")
func main() -> Int:
    0
```

That is a genuine pre-implementation parser/checker red without references to
unintroduced enum variants. Subsequent callbacks inspect the published typed
operation and both constructors rather than merely testing compilation.

| Boundary | Required oracle |
| --- | --- |
| Parse/check | Exact label/tag/span; impure nongeneric zero-argument contract; wrong purity/arity/payload/ordinary Result and tail-annotation rejections; pure caller rejection |
| Specialize/lower | Concrete designated IDs, reversed Err/Ok declaration order, both String fields, InlineOwningPayload, zero operands, preserved span |
| Own | Fresh call owner, unused drop, duplicate result, both branch projections, acquire-child-before-parent destruction |
| Verify | Wrong second payload, missing/duplicate/cross-owner constructor, unmanaged managed-result, missing/duplicate drops rejected independently |
| Emit/runtime | One query; discriminator rather than payload selects actual IDs; no scratch release/extra retain; ordinary active-slot release; 13 native cases under ASan/UBSan |
| Runtime fragment unit | Import SYSTEM_CURRENT_DIRECTORY_RUNTIME directly; small publication checks for the declared uint8/out-pointer contract; native runtime tests own OS behavior, exact bytes and allocation lifetimes |
| Literal constant admissibility | Parse/check a raw module String constant containing C quotes and a literal backslash-n; exact StringConstant bytes and ordinary ReadConstant, without a new grammar form |
| Harness unit | NativeCase constructors default to None; native_command preserves None and forwards an explicit Some CWD unchanged |
| Real main | Basic witness in two explicit CWDs: exact pathname + LF, stderr empty, exit 0; second fixture ignores a result and preserves a projected owned String past its Result, same exact output |

Reuse existing `test/unit/module_input.brp`. Planned unit files are
`test_check/test_current_directory.brp`, `test_specialize/test_current_directory.brp`,
`test_lower/test_result_contracts.brp`, `test_own/test_current_directory.brp`,
`test_verify/test_result_ownership.brp`, and `test_emit/test_current_directory.brp`,
all under `test/unit/`; extend existing
`test_parse/test_string_literals_syntax.brp`. New `src/runtime/system.brp` also
has its required mirrored unit suite, `test/unit/test_runtime/test_system.brp`,
following the existing String/Float/List fragment-publication precedent. Keep
that suite small; do not duplicate native algorithm assertions as source-text
checks. Add one callback
`test_raw_string_constant_preserves_c_fragment_bytes` to existing
`test/unit/test_check/test_constants.brp`: a raw literal containing
`const char *message="a\nb";` must publish those exact C bytes as a StringConstant
and retain StringType on its ordinary read. Existing parse constant tests cover
next-line pipe literals; this single new checker case pins raw/backslash
admissibility rather than broadening constant kinds. It shares the same test
ceiling. Native files are only
`test/runtime/test_current_directory.brp` and
`test/runtime/fixtures/current_directory_test.c`. Add `test/e2e/test_current_directory.brp`,
register it in `test_end_to_end.brp`, and use exactly two named fixture files
under `fixtures/current_directory/` (`basic.brp`, `ownership.brp`). The e2e
NativeCase may add explicit `cwd: Option[String]`, default None, forwarded to
the existing ProcessCommand.cwd; no automatic directory selection or new runner.
Permitted test changes explicitly include `test/e2e/harness.brp` and existing
`test/unit/test_harness/test_harness.brp`. Add callbacks
`test_native_case_defaults_to_inherited_cwd` (both native_case and argv_case),
`test_native_command_preserves_inherited_cwd`, and
`test_native_command_forwards_explicit_cwd`: a Some relative path containing
spaces/UTF-8 and parent components must reach ProcessCommand.cwd byte-for-byte,
without resolution, trimming or normalization. Inventory all direct NativeCase
record literals and mechanically add `cwd = None` where needed; preserve their
other inputs and expectations. These owners and updates fit inside the same
approved 1100-gross/+1080-net test ceiling, not an additional allowance.

Native Err is deterministic only in direct helper tests; no native-Err language
main coverage is claimed. Ordinary Err[String] phase/aggregate tests cover that
owned branch. Stop if acceptance requires injecting generated-language failures.
Run native helper and aggregate checks with the supported macOS/Linux Clang/GCC
toolchains; retain sanitizer results separately from normal cost measurements.
Prove separate compile-successful mutations: no ERANGE growth, errno read after
free, UTF-8 bypass, missing staging free, swapped result tags, missing owner/drop;
restore exactly and rerun the owning test green.

The original planned validation commands were below. The execution record at
the end documents the later explicit borrowed-host grant and actual pins:

```sh
scripts/compiler-build-status
# If not FRESH: make, then recheck; do not borrow an embedded runtime by --std-dir.
bin/blorp test --suite --timeout 180 blorp_2/test/unit/test_check/test_current_directory.brp
bin/blorp test --suite --timeout 180 blorp_2/test/unit/test_runtime/test_system.brp blorp_2/test/unit/test_harness/test_harness.brp
bin/blorp test --suite --timeout 180 blorp_2/test/runtime/test_current_directory.brp
bin/blorp test --suite --timeout 180 blorp_2/test/unit
BLORP_CC=/usr/bin/clang BLORP_2_INSTRUCTION_CHECK=required make -C blorp_2 test
make hygiene-check
make artifact-scan
git diff --check
```

The fixture's exact compiler invocation is
`blorp_2/build/compiler --library-root blorp_2/standard_library_temp blorp_2/test/e2e/fixtures/current_directory/basic.brp build/target-cwd/basic.c`.
The existing harness compiles each fixture once and links its unmodified C at
O0, then invokes actual main. No manual duplicate compile is needed for review.
Preserve complete raw generated C; this feature intentionally adds its helper,
call and owned union construction. Explain every changed shared-fixture C or
diagnostic; do not normalize or assume cross-feature identity.

## Approved ceilings, cost boundary, and handback

Root and the independent reviewer approved the limits below. The earlier
250–450-test-line estimate omitted the full native matrix and granular
malformed-IR coverage.

Checkpoint 1 stopped at 823 gross added / 2 deleted / +821 net test lines,
exceeding the original +820 net ceiling. Following review, root approved one
test-only extension for the estimated 180–230 necessary lines: missing negative
cases, exact normal/reversed tag and payload oracles, independent help/span
checks, and readable formatting. Existing tests and coverage are retained.
This is no production, API, runner, or mechanism expansion. The original
checkpoint and first-red receipts remain immutable; all other ceilings,
including the source-cleanup 3% policy, and frozen epochs are unchanged.
Another overrun requires a new explicit decision, not an automatic waiver.

| Physical scope | Estimate gross/net | Approved hard gross/net ceiling | Actual gross/net |
| --- | --- | --- | --- |
| Production, including temp declaration | 200–260 / +180–240 | 300 / +280 | 158 / +142 |
| Tests, including native C, excluding language fixtures | 1003–1053 / +1001–1051 | 1100 / +1080 | 1079 / +1073 |
| Language fixtures | 2 files, 25–40 lines | 2 files, 50 added / +50 net | 2 files, 26 / +26 |
| Public docs, excluding this plan/roadmap | 20–35 / +20–35 | 40 / +40 | 40 / +39 |

The final test census is 1079 added / 6 deleted / +1073 net lines, within the
accepted 1100-gross/+1080-net ceiling. The earlier estimate is not a different
cap. Public documentation includes the concise benchmark report; this plan and
the roadmap are counted separately. Original checkpoint receipts stay unchanged.

Allowed production: `utils/syntax.brp`, `parse/parse.brp`,
`namespace/builtins.brp`, `check/signatures.brp`, `specialize/specialize.brp`,
`verify/verify.brp`, `emit/emit.brp`, new `runtime/system.brp`, and new temporary
`system.brp`. Update README, grammar, parity and temp-library documentation with
only this API's contract/provenance. No unrelated temp-library README cleanup,
host-native changes, loader/main migration, eager-error cleanup,
generic FFI, framework/cache, other shell APIs or budget stacking.

Freeze separate accepted feature baseline B, actual candidate C, supporting
normal/diagnostic host, host and target libraries, toolchain, flags, CWD/paths and
unchanged corpus before any cost run. The plan base is not permission to
silently rebase or change an already frozen measurement. Approved hard ceilings
are +5% for both allocations and normal min3 retired instructions per unchanged input and
the host source-to-C proxy; every stricter existing fixture ceiling still binds.
Cover every baseline registered e2e input, including rejections, both new
fixtures, and the proxy; retain the frozen input list and byte hashes.
Each new fixture has approved absolute caps of 205,000 allocations and
600,000,000 normal instructions. Record raw strict counts separately from normal B/C,C/B,B/C
samples; pilot/compiler-fixture/native runs require strict zero leaks and balanced
positive counters, exact status/diagnostic oracles and complete C review.
Supporting-host compile-time leaks follow [the bootstrap decision](HOST_BOOTSTRAP_LIMITATIONS.md).
New-only native calls have no fictional baseline.
Report success/error native allocation counts and growth work independently.
The host compiling B/C target sources is a proxy, not target self-compilation.
Retain exact source/binary/library hashes and production/test LOC separately.
Approve the concrete measurement recipe before execution; no new controller or
reuse of the source-byte failed packet. Stop on drift, breach or unexplained C.

Root and an independent compiler/runtime reviewer approved the plan/native seam;
code-reviewer and test-runner then review implementation/evidence before commit.
Return exact patch/source hashes, separate LOC, red/mutant/restored results,
phase/native/main verdicts, raw C and measured costs. No commit/push until the
coordinator grants the concrete step. Shared compiler files have one writer;
coordinate M2/M3/host changes rather than altering their worktrees. If the ABI,
test seam, bounds or budgets require broader mechanisms, stop for root.

## Validation and cost record, 2026-10-17

The [benchmark report](../benchmarks/results/blorp_2_target_current_directory_2026-10-17.md)
records measured results. The measurement baseline is accepted main
`72164f17a21d8e375efceb77503b92318e97340d`, compiler source tree
`8a45f02fdf5c9d1bf5e8634426817c9df664568c`; the candidate is the unchanged
feature source snapshot. Its exact B/C file hashes are in
`build/target-current-directory/cost/snapshot-manifests.json`.

Explicitly borrowed main host `e74cd095ab86d1d0035c6a9b319167bd17988fda061fb91dd9a2eb44ca9fdaf1`
and pinned main standard library produced the B/C pilots. Actual host metadata
remains `192bc8639d39-dirty`, CLI O0/runtime O2/diagnostics0; this is not an
own-worktree FRESH claim. Pilots are O0 normal/diagnostic variants. The separate
host proxy uses the fixed O2 pair pinned in `cost/proxy-pair.json`, with actual
`59679bf6b9d0-dirty` / `self-59679bf6b9d0` metadata, not an e74 counterpart.

Correctness evidence is 2604 unit / 229 runtime / 179 grammar reported checks
(nested and repeated checks included), 458 e2e cases and 13 direct native cases
under ASan/UBSan. Both new fixtures run their actual main in `/` and a temporary
physical CWD with exact status/stdout/stderr. Six compile-successful mutations
fail their intended oracles; each exact restoration is green. Native evidence
in this packet is Darwin arm64, Apple Clang 21; Linux/GCC is not claimed here.

The 483 logical cost cases comprise 481 shared output states and two new C-only
states. All strict pilot counts balance with zero leaks; all stream/output
oracles, raw C identities, +5% comparisons and stricter absolute ceilings pass.
Shared allocations are unchanged; worst normal min3 growth is +0.552871%.
The two new inputs measure 11785 / 12297 allocations and 48231276 / 49022765
normal min3 instructions, below 205000 / 600000000. The first case's eight
accepted observations were reused; the remaining corpus made 3848 calls.

Host proxy TOTAL allocations are 23224178 -> 23328551 (+0.449415%); normal min3
instructions are 20631844365 -> 20734800215 (+0.499014%). Both unchanged +5%
ceilings pass. Per-variant normal/diagnostic C equals the retained producer C.
This is host source-to-C evidence, not target self-compilation.

Both host diagnostic observations still fail strict memory with exit 99:
B reports 512964 leaked allocations / 34890725 bytes; C reports 515331 /
35048857. The user explicitly accepts this known host-compiler bootstrap
limitation only. Those observations are not relabeled zero-leak passes; TOTAL
allocation counts include all allocations. The seven remaining proxy calls
reuse the original B diagnostic, so no diagnostic or normal sample was rerun.
Report-parser whitespace errors were corrected offline on the original raw
reports; their stop history and every raw observation remain unchanged.

Exact commands, all binary/source/std hashes, original failures and raw reports
are retained under `build/target-current-directory/cost/`. The actual compiler
source byte census is 943206 -> 949206 (+6000); temporary library source is
4577 -> 4927 (+350). Historical snapshot totals have different inventories and
are not source-growth measurements. The original source-byte R0 failure,
hosts, epochs and cumulative/local 3% policy remain frozen and binding.
