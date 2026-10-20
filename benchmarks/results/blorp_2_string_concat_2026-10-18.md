# Blorp 2 counted String concatenation, 2026-10-18

`string.add(left: String, right: String) -> String` now borrows both operands
and returns one fresh counted UTF-8 String. Aliasing and embedded NUL are valid;
the helper copies each operand once. This supplies the concrete operation
needed by `utils/text.concat`. Checked slicing and growing-buffer join remain
separate work. The [phase matrix](https://github.com/kablorp/blorp/blob/b1dd8fda7d5f6c3451f6dd492c54cd8d876fdd2b/blorp_2/STRING_CONCAT_PHASE_MATRIX.md)
owns the approved scope and ceilings.

All correctness and matched cost gates pass. Maximum shared-input increases
are **2.471655% allocations** and **1.164548% normal retired instructions**;
both are below the independent +5% hard ceilings. The host proxy increases
**0.121432% TOTAL allocations** and **0.043463% normal min3 instructions**.
The host's known strict failure remains failed under the narrow
[bootstrap limitation](../../blorp_2/HOST_BOOTSTRAP_LIMITATIONS.md).
Root and independent compiler code/test reviews approve the original 29-path
packet with zero findings. Destination integration passed 33 focused checks,
and `8a0417724` was verified on `origin/main`.

## Frozen inputs and tools

Collection ran on October 17–18 in managed worktree
`/Users/keithphilpott/.codex/worktrees/finish-concat/blorp`, branch
`codex/finish-concat`. Baseline B is accepted byte-source commit
`abd0aa1a01c77fd89768e1bc28c2453695495ce4`; C is exactly B plus concat.
The later `c0368c71c` documentation commit changes no compiler, target-library
or test input, so it did not move the fixed baseline. The complete production
patch SHA256 is
`60b17899464277fef7d3978b1a6c4f48d136d02b1bbef0c45d29979940ff89d5`.

| Frozen inventory | B | C |
| --- | ---: | ---: |
| Compiler source files | 39 | 40 |
| Target-library files, including README | 9 | 9 |
| Shared fixture files | 461 | 461 |
| New concat fixture | 0 | 1 |

Only C adds `src/runtime/string_concat.brp`. Installing B explicitly removes
that one owned C-only path; exact directory membership and complete SHA maps
are checked. Both variants use their own exact target library. All 461 inherited
fixture bytes and all 150 retained generated dependencies match the accepted
read_file registry; no fixture source was rewritten. The complete invocation
manifest SHA256 is
`31fa521837b623135d0b23364e29778653f70f21b8b20bd211d4db5e4231e44d`.
It includes both source/library and registry maps, every argument and oracle,
and all 487 output-state invocations: 486 shared and one C-only. There are
456 absent-output and 31 preserve-output states. The 119 states without inherited
absolute limits retain that absence; their relative +5% checks still bind.

The producer is `/Users/keithphilpott/CLionProjects/blorp/bin/blorp`, SHA256
`c04f68ba64ac06f6cd3f924cdb4d87ce6b3d40d0f8fba2ef89b20e324b21ca57`.
Every host compilation explicitly selects
`/Users/keithphilpott/CLionProjects/blorp/standard_library/src`; all 91 library
files are pinned before and after. The accepted FEATURE proxy executables are
`host-dirname/blorp/build/host-file-errors/cost-721-01/{normal,diagnostic}`
under managed worktrees, with hashes respectively
`4cc4b91240e8bb02fbfbe44a6bdecca8df3085874ad138cfbaa196500a98d78c`
and `485a9dc4257b3f5c5a54f843129b42037962a0084b154c3bf616881f3b6259bb`.
No host was rebuilt or relabelled. Platform is Darwin arm64, Apple Clang
21.0.0 (`clang-2100.3.34.2`); Clang, time and unlink executable bytes are pinned.

## Commands and observation boundary

All setup and measured invocations use one canonical physical working directory,
source, input and output path under `blorp_2/build/finish-concat/cost/canonical`.
Source/library installation and output-state preparation occur outside each
measured invocation. The fixed setup generates C once per variant and links
it once in each mode:

```sh
env -u BLORP_CC -u BLORP_LEAK_CHECK -u BLORP_MEMORY_STATS \
  "$PRODUCER" compile --no-format --std-dir "$HOST_STD" \
  blorp_2/src/main.brp -o "$OUTPUT"
/usr/bin/clang -O0 -DBLORP_MEMORY_DIAGNOSTICS=0 "$C" -o "$NORMAL" -lm -lpthread
/usr/bin/clang -O0 -DBLORP_MEMORY_DIAGNOSTICS=1 "$C" -o "$DIAGNOSTIC" -lm -lpthread
```

Both emits and four links succeed. Every link retains 87 warnings; this is
not a warning-free build. The full paired generated-compiler diff, 111,733
lines, was retained without normalization. Whole-compiler B/C C identity is
not claimed: the source adds an operation, contract, fragment and enum cases.

| Artifact | B SHA256 | C SHA256 |
| --- | --- | --- |
| Compiler C | 37615f0a5ad4dfc304f71f61083fdb5049eb67d7873c74ec7257f3845b3c3fe7 | 567a2dd0122edf7c38298ba196a3cf222df08c0d3f69ef2322fd5ddcd2e9d91e |
| Normal pilot | c4a34e338a5f8525899031b04b9a74ba9b9098a3f64159abc17139fe3cd5c144 | 9dc2a929173dabd1e256c777c25cf9bafa7d3b459c15a0f4d68e75f88573c4e8 |
| Diagnostic pilot | 708d3045f24597a76b6715244a7b1e10721ecbbd78ee88220267588557e77953 | fe9fb292c78daaef9a83496f6ae147980ce03107d376057d0e4d91c597bf9f0e |

Strict target calls use diagnostic pilots, `BLORP_LEAK_CHECK=strict`, and unset
memory stats. All 973 report positive balanced allocations/releases and zero
leaked objects/bytes. Normal calls unset all three memory/CC variables and use
`/usr/bin/time -l`, alternating B1,C1,C2,B2,B3,C3. Every input has exactly three
normal samples per applicable variant; min3 is the instruction metric. Existing
absolute fixture limits remain unchanged. Every status, stdout, exact diagnostic,
output state and complete raw C is checked. Shared fixture C is byte-identical
across B/C; all normal outputs match their own strict output.

Exactly **973 strict target + 2,919 normal target + 8 host proxy = 3,900**
measured calls completed. No failed sample was retried, excluded, filtered or
normalized, and no baseline was refrozen. Exact ordered ID/variant/sample keys,
command counts, source/library membership, fixtures, generated dependencies,
host library, tools, pilots, collector scripts and case oracles pass final
integrity checks. The direct bounded shell recipes reuse the accepted collector
shape; no persistent runner or compiler cache was introduced.

## Correctness and independent oracles

The frozen C source/library/test map contains 830 files and is unchanged from
the passing full run: **3,151 unit/runtime/grammar PASS observations** and
**462 e2e cases, zero failures**. The full e2e run uses the existing harness,
required instruction checks, strict pilot leak checks and unmodified generated
C with ASan/UBSan at the fixture's real main. Its generated pilot C is exactly
the C setup output above. No alternate fixture main or internal generated
symbol is called.

The retained original focused packet proves the prefeature parser red and
restored 24 phase cases, 121 existing exact-help/grammar cases and eight native
helper cases. It separately kills eight compile-successful mutations: wrong
parsed operation, wrong borrow authority, missing inserted drop, zero-filled
right copy, disabled independent live-owner check, retained native input,
suppressed native free and correlated wrong lowering spans. Each restoration
passes; source originals compare equal. Initial test-indentation failures and
an initial free-removal mutant that failed compilation are retained and are
not counted as oracle proof.

Native cases use the actual production runtime fragments, allocator wrappers
that delegate to real allocation/free, strict C11 warnings and ASan/UBSan.
They check exact counted bytes, aliasing, independent lifetimes and one fresh
result. The INT64_MAX/SIZE_MAX impossible-storage guards have source-inspection
evidence only, as approved; there is no runtime execution claim for them.

The concat fixture exits 0 with exactly 24 stdout bytes and empty stderr:
`c3a900f09f9880c3a900f09f98800ac3a900f09f98800a0a`.
Its retained complete C SHA256 is
`748d38b419fbed5a557c1b18bb574e0d3e6ac3fd986acb47e6c5fdc548b666ea`.
Generated C shows two aliased borrows, one result transfer/drop, a source that
survives result destruction, and independent empty-root cleanup.

## Additional post-CI-fix functional checks

`codex/concat-final-integration` preserves reviewed concat `be34eab96` and
incorporates main through `db286f6c`. The same 830-file Blorp 2 inventory changes
only the two native test writers that append final LF. The later three legacy
runtime test repairs are outside this inventory. Compiler, library and fixture
bytes remain identical to the measured candidate; the explicit reconciled map
has SHA256 `45617e34558999c32aa97c80493ba38b2d1d59bb29bb68a3e59d0c21e8bc27f3`.

Using the same pinned c04/ROOT std and warmed configuration, component checks
pass **3,151/0, exit 0**; one compiler emit/link both exit **0**; full e2e passes
**462/0, exit 0**. Generated compiler C remains `567a2dd0122edf7c38298ba196a3cf222df08c0d3f69ef2322fd5ddcd2e9d91e`.
This additional e2e run overlaps local compiled work from the legacy runtime
gate: it is **functional integration evidence**, not a quiet cost measurement.
No cost sample is repeated, no baseline moves, and the original 3,900 matched cost
calls remain authoritative. Exact commands, logs, exits, hashes and before/after
maps were retained under `blorp_2/build/finish-concat/post-ci-functional/`.

## Costs and scope

| Observation | B | C | Change / ceiling |
| --- | ---: | ---: | --- |
| Largest shared allocation ratio, return/zero | 8,820 | 9,038 | +2.471655%; +5% |
| Largest shared normal min3 ratio, conversion/nul_bytes | 47,642,946 | 48,197,771 | +1.164548%; +5% |
| New concat allocations | — | 12,390 | 205,000 absolute |
| New concat normal min3 instructions | — | 40,553,537 | 600,000,000 absolute |
| Host proxy TOTAL allocations | 23,425,399 | 23,453,845 | +0.121432%; +5% |
| Host proxy normal min3 instructions | 20,820,946,943 | 20,829,996,366 | +0.043463%; +5% |

The proxy uses the accepted FEATURE **exit-time TOTAL** allocation denominator,
not the source-byte checkpoint metric. Both strict host calls return **99**,
empty stdout and complete C: B has 515,949 leaked objects / 35,090,966 bytes;
C has 516,337 / 35,115,967. Both remain
`FAILED_HOST_LEAK_LIMITATION`. Allocations are not reduced by leaked counts.
The full ordered report, including the type table, was validated before landing;
17 static checks against accepted reports and malformed copies validate the
bounded collector repair without extra host samples. Every strict/normal proxy
C matches its own setup C exactly. This is owned-input compilation plus a host
construction proxy, **not target self-compilation**; it omits the target compiler
executing on its own source. No whole-feature speedup is claimed.

| Physical lines | Gross added | Net | Approved maximum |
| --- | ---: | ---: | ---: |
| Production | 47 | 42 | 110 |
| Native portion | 19 | 19 | 50 |
| Shared wiring portion | 28 | 23 | 60 |
| Tracked tests | 679 | 676 | 750 including temporary runner |
| Temporary retained-artifact TestSuite | 23 | 23 | included above: 702 gross total |
| Language fixture | 14 | 14 | 30 |
| Public README/grammar/parity documentation | 11 | 8 | 25 |

Plan and result-report lines are separate. No coverage was deleted or formatting
compressed to meet a ceiling. The independently approved 750-test-line allowance
replaces the initial 400-line allowance over 399 prepared lines; other caps did
not change.

## Retained artifacts

**Retention correction after landing `8a0417724`.** Archiving the completed
chat also archived its managed worktrees and removed their ignored build files.
The source snapshots were restored, but the original 3,900-call raw packet and
the supporting host binaries below were not recovered in the checked locations.
The measurements and independent reviews above predate that loss; their summary
remains recorded here, while the original raw paths are unavailable. The separate
destination check remains in the primary checkout's `build/concat-destination/`
(33 PASS events, exit 0, with all 830 input pins checked before archival).
Remaining bootstrap evidence was copied with complete SHA256 maps to that
checkout's `build/bootstrap-evidence/retained-2026-10-18/`. Future measurements
must freeze available tools explicitly; these missing artifacts cannot be reused.

In `finish-concat/blorp/blorp_2/build/finish-concat/`, `full/` held complete
correctness logs, the functional pilot and its maps. `cost-preparation/` held
the frozen invocation manifest, complete snapshots, script/case pins, commands,
installers, validator checks, setup logs, production patch, generated-compiler
diff and `verified-summary.json`; `cost/` held all raw target/proxy calls,
times, streams, statuses, C, TSVs and pilot artifacts. No measured input moved
after freezing. Metadata-only setup errors before collection were preserved:
an initial nested-root calculation and relative oracle paths were corrected
before any compiler sample; a docs-only main advance did not move B.

The original worktree `b0da/blorp/blorp_2/build/string-concat/` retained every
semantic red, mutation/restoration, original source and normal-main delivery
artifact. Its old absolute fixture observation (12,491 allocations / 71,039,732
instructions) is historical and was not reused as a matched current result.
Unlanded host/slice drafts were left in that original worktree and were excluded
from this change. Static hygiene and artifact-scan records were kept alongside
the finishing packet, alongside the additional functional receipts above.
