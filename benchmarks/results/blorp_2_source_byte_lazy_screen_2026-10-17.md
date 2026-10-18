# Source-byte migration: failed historical screen and bounded landing policy

The original R0/D cumulative allocation experiment **FAILED**. Candidate D used
9959 allocations on c0004 against the unchanged 9923 cap, 36 above it. The
coordinator subsequently approved one explicit landing-policy exception after
two independent expert recommendations, under the user's authorization to
adjust roadmaps. The subsequently completed fixed A/D corpus and original
checkpoint-proxy cost gates **PASS** under that published exception. Current
owner/unit/runtime/grammar/e2e correctness, fresh source reconciliation and
three lazy diagnostic sensitivity proofs also pass. Independent final landing
review remains pending; genuine source self-compilation is not established.

The [owning plan](../../blorp_2/SOURCE_BYTE_MIGRATION_PLAN.md#one-time-landing-policy-after-the-failed-screen)
retains the original source freeze and defines the exact exception. Only this
frozen byte-migration/lazy-error slice may instead land through fixed accepted
A/D comparisons, each capped at 3% allocations and normal minimum-of-three
instructions, per input and for the original checkpoint proxy. All absolute,
LOC, strict zero-leak, complete C/diagnostic identity and correctness gates stay
binding. This changes a criterion after failure; it is not a new host epoch,
feature-cost deduction, rolling denominator or permission for another exception.

## Observed original screen

Original physical workload CWD:
`/Users/keithphilpott/.codex/worktrees/source-byte-migration-plan/blorp/build/source-byte-migration/cost-run/input`.
Input: `blorp_2/test/e2e/fixtures/binding/basic.brp` (`c0004`). Output:
the original sibling `cost-run/same-output.c`. New raw artifacts are under
`/Users/keithphilpott/.codex/worktrees/source-port-current/blorp/build/source-port-current/cost-run/`.

| Fresh serial variant | Exit | Allocations/releases | Leaked objects/bytes |
| --- | ---: | ---: | ---: |
| Historical reset R0 | 0 | 9634 / 9634 | 0 / 0 |
| Historical accepted B | 0 | 10081 / 10081 | 0 / 0 |
| Accepted read_file A | 0 | 10081 / 10081 | 0 / 0 |
| Actual deliverable D | 0 | 9959 / 9959 | 0 / 0 |

R0 and B exactly reproduce their original allocation counts. D/R0 grows 325
allocations (+3.373468964%); `995900 > 992302`. D/A and D/B save 122
(-1.210197401%). A=B here, so CWD/read_file explain none of this difference.
No specific host defect is established. All target stdout and semantic
diagnostics are empty. All four complete C files are byte-identical SHA256
`7f351aaa39ead7981b4439ea57603339c28be3b7fa75e80938c29ffb0c38c8ee`;
retained raw B/D and R0/D diffs are empty. Strict-mode instruction reports are
supporting raw observations only, not normal min3 evidence.

Exactly two setup host generations, four O0 links and four strict target calls
ran, without repetition. All process exits were 0; the subsequent cumulative
cap assertion exited 1. Generations require exact `Generated <output>` plus LF
stdout and empty stderr; target pilots require empty stdout and one positive,
balanced zero-leak footer. Full streams, statuses and C are retained. No broad
corpus, normal samples, host proxy or further optimization followed under the
original failed-screen grant. The separately authorized remaining schedule below
ran only after publication of the explicit landing-policy exception.
Reuse these four strict observations; do not resample c0004 under the exception.

## Frozen identities and reproduction authority

A is `0cdba16a459c1a1f5792a70ea2071f98f453b96f`. D's exact production/test diff
SHA256 is `81cfcf7586761ff70204c805e1bc3f237bcbb1b3aaf83ee77537d2f9e0d83f96`.
A/D snapshots each contain 39 compiler modules and all 9 temporary-library files.
Their complete target library is identical at the explicit new path
`cost-run/libraries/actual-D-read-file` under the historical packet root.
Historical reset/local library paths, source snapshots, pilots and raw data are
unchanged. Main `8ed7687dfa12d548fdb099d29a143092c1578bf2` has the same compiler
source/library trees as A; intervening changes are tests/docs only.

| Pin | Identity |
| --- | --- |
| A compiler source tree | `30cb259e19bd3bde4e7ffda952059910fd78c5b9` |
| Complete A/D library tree | `38530dc355893aca1207580a3dcd4ab810a55f17` |
| A source/library SHA256 manifest | `c8f0a1b4db556d92f4fd40432768895adad108611acf4716cbcb1f517eac0119` |
| D source/library SHA256 manifest | `295d7182722e0dbc0e46164b33764975c46bc2279a81e6b41c52278b4d775d60` |
| Complete staged library manifest | `fb5bce88f7ce9944531da95458275af320d9dfff79fa8a400a6901a95c2b9750` |
| Frozen normal host SHA256 | `34ac1a913c79fc14130c77fe4339f24885a2fa65f1d25fc4b873b627e10e1f33` |
| Frozen diagnostic host SHA256 | `be31a5a3a070deef54707d8676a7c6157042484f40d0424dd5fb46835c09ff93` |
| Host compiler source/std trees | `33d50604c606ce0eaaa7dddd6f11783e8b66eed2` / `090ed68c5bd688cb8e2197c72bc572e4dc32e6d7` |
| A compiler-C/pilot artifact manifest | `28d7011556e874fe94492ec9f24c4166d0d68ec204714bdd3deb187741c511dc` |
| D compiler-C/pilot artifact manifest | `414ca65a503d31eca80ea03b086fad5899f0afda41128723e54cfcfcdc2a3160` |
| Original SCREEN_RESULT.md SHA256 | `cc50edb58f81cad1e59a78056d57d73b2097036a1c21c1f5eded33ba509d422f` |

Frozen hosts remain in `host-utf8-file-admission/blorp/bin/`, with explicit
uniform `standard_library/src` from that worktree. Producer flags:
`compile --std-dir <frozen-host-std> --no-format blorp_2/src/main.brp -o <original-output>`.
Links: `/usr/bin/clang -O0 -DBLORP_MEMORY_DIAGNOSTICS={0,1} <unmodified-C> -o <pilot> -lm -lpthread`.
Strict target calls use the diagnostic pilot, explicit target-library root,
`BLORP_LEAK_CHECK=strict`, and unset `BLORP_CC`/`BLORP_MEMORY_STATS`.
Clang is the pinned Apple 21.0.0 arm64 toolchain; unchanged tool hashes and literal
commands are in `build/source-port-current/preparation/COMMAND_PROPOSAL.md`.
Only the root-approved non-PTY transport correction changed execution delivery.

Within the new raw root, `pilots/{A,D}/artifacts.sha256` binds each complete
compiler C and both pilot binaries; `strict-screen/c0004/{R0,B,A,D}/` retains
every observation. `SCREEN_RESULT.md` and `strict-screen-summary.tsv` provide
the initial result. Original direct command/assertion authority remains the
historical `cost-preparation/direct/{config,strict,normal,new-fixtures,host-proxy}.sh`.
Those old scripts are not edited or replayed over existing data. End checks
verified all 598 host pins, 596 actual host source/library names, historical
source/pilot/library pins, original fixture bytes and preserved canonical inputs.

## Fixed accepted A/D cost acceptance

The exclusive remaining window executed exactly 3,694 new measured CLI calls:
902 original-input strict, 2,712 original-input normal, 18 newer-input strict,
54 newer-input normal and eight original host-proxy calls. The two A/D c0004
strict observations were explicitly reused, with no strict resampling. Normal
sampling used exactly three unfiltered alternating pairs A/D, D/A, A/D for
each input and the proxy. No candidate change, repeated sample or optimization
occurred. All four direct primitives exited 0 with empty wrapper stderr.

All 461 exact accepted-A fixture paths passed complete A/D C, status and
semantic-diagnostic identity. Every target strict record had positive balanced
allocation/release counts and zero leaked objects/bytes. All per-input integer
allocation and normal-min3 instruction comparisons passed `100*D <= 103*A`;
the nine API/current inputs also passed their unchanged absolute ceilings.
The original 452 shared allocation counts all decreased. Their smallest
relative decrease was c0184, A=98760/D=98639 (-0.122519239%). Their largest
normal-min3 increase was c0364, A=37621583/D=38163472 (+1.440367355%).
These are observed boundary results, not a whole-source self-compilation claim.

| Boundary | A | D | Change | Verdict |
| --- | ---: | ---: | ---: | --- |
| c0004 strict allocations, reused | 10081 | 9959 | -1.210197401% | PASS local only |
| c0004 new normal min3 instructions | 36339560 | 36526894 | +0.515509819% | PASS |
| Original host artifact checkpoint allocations | 23422861 | 23429346 | +0.027686626% | PASS |
| Original host normal min3 instructions | 20836207964 | 20841105530 | +0.023505074% | PASS |

The proxy retained the original unique schema1
`artifact_construction_complete total_allocations` checkpoint with
`BLORP_MEMORY_STATS=1`, leak mode unset, exit 0 and exact Generated LF stdout.
Its six normal runs used the frozen normal host and original flags; its two
checkpoint runs used the frozen diagnostic host. Each complete emitted compiler
C was byte-identical to that variant's frozen setup C. Exit-time strict totals
were not used as proxy counters. Historical R0/B evidence remains read-only;
the original R0/D cumulative result above remains **FAILED**.

Raw observations and literal commands are retained under
`build/source-port-current/remaining-cost-run/`: `strict.tsv`, `normal.tsv`,
`new-strict.tsv`, `new-normal.tsv`, `allocation-caps.tsv`, `normal-minima.tsv`,
`new-caps.tsv`, and `host-proxy/{normal,diagnostic}.tsv`, with full per-call
streams, statuses, time counters and C. `completeness.audit.log` independently
checks unique expected ID/variant/sample keys, complete counts, integer caps
and own-oracle hashes. The approved finite schedule and inspectable primitive
deltas are in `remaining-preparation/REMAINING_SCHEDULE.md` and
`remaining-preparation/*.recipe-delta.diff`; its SHA256 is
`4465eda06b8b2034cf6bce957557b52a6352f088e0875d5d32d6be708ee6b88b`.

End verification passed all 598 supporting-host pins, frozen Clang/time/unlink,
all original direct scripts, A/D source/library snapshots and pilot artifacts,
the complete installed target library, all original fixture bytes and five
new accepted-A fixture bytes. The canonical source/library map is complete D;
prior complete installations are preserved. Candidate code/test diff remains
exact `81cfcf7586761ff70204c805e1bc3f237bcbb1b3aaf83ee77537d2f9e0d83f96`;
the old candidate diff remains `4afdbb7ffa98064f6073a8acdf269eb11e58af7fe04b76d2df7c512088ac571f`.
Final `*.verify.log` receipts accompany the raw data. The measurement lane was
returned before functional compilation resumed.

## Current-stack correctness

The exact 12-file patch was reapplied without conflict onto accepted main
`e29a5396a147fc94b91a51f5285f2b0bd265429a`; its diff stayed `81cfcf...` and
all 39 source plus nine target-library files still matched frozen D. The
functional host is separately pinned SHA256
`c04f68ba64ac06f6cd3f924cdb4d87ce6b3d40d0f8fba2ef89b20e324b21ca57`
at `/Users/keithphilpott/CLionProjects/blorp/bin/blorp`, verified FRESH in its
own checkout, with explicit host standard library
`/Users/keithphilpott/CLionProjects/blorp/standard_library/src`.
Its current source tree is `e34e2fbb50ec0d19b143f6041d869165a973a8c8`.
It does not replace either frozen measurement host.

The full current-base unit/runtime/grammar command exited 0 with 3,109 PASS
events and no failures, including all affected owner suites:

```sh
/Users/keithphilpott/CLionProjects/blorp/bin/blorp test \
  --std-dir /Users/keithphilpott/CLionProjects/blorp/standard_library/src \
  --suite --timeout 180 blorp_2/test/unit blorp_2/test/runtime blorp_2/test/test_grammar
```

`build/source-port-current/functional/current-main-full.{log,status}` retains
the final gate. The earlier frozen-A log printed 3,079 PASS events, but its
post-process zsh assignment used the reserved name `status` and lost the CLI
exit receipt; it is not the final gate. A redundant confirmation already
started when the coordinator requested the current-main refresh was canceled
with transport exit 143 before completion, with its empty log retained. No
measurement was affected or repeated.

One functional compiler generation used the explicit current host/std and
`compile --no-format blorp_2/src/main.brp -o <functional/compiler.c>`; one O0
link used `-DBLORP_MEMORY_DIAGNOSTICS=1 -lm -lpthread`. Both exited 0, generation
stdout was exact Generated LF and stderr empty. Unmodified compiler C SHA256 is
`37615f0a5ad4dfc304f71f61083fdb5049eb67d7873c74ec7257f3845b3c3fe7`;
the pilot is `8651ffde7e8bdddde5ab8bdafb9e536e97fc381d1427e24e6d930ba1e2a4d5a9`.
The link's 87 inherited warning occurrences are three discarded const
qualifiers, 56 extraneous-parentheses comparisons and 28 pointer/integer
comparisons; there is no generated-C repair. Raw streams/statuses and
`artifacts.sha256` are retained in that functional directory.

Full e2e exited 0, exercising all 461 accepted fixtures and existing allocation/
instruction gates. Its nested fixture/native suites printed 1,006 PASS events,
zero FAIL; `functional/e2e.{log,status}` retains the full record. The exact command
was the same explicit host/std test command with `--suite --timeout 0
blorp_2/test/e2e` and
`BLORP2_COMPILER=/Users/keithphilpott/.codex/worktrees/source-port-current/blorp/build/source-port-current/functional/compiler`.

The existing pre-DCE lower observer then ran once with the same explicit host/
std and `compile --no-format --stop-after=lower --dump-core-after=lower
blorp_2/src/main.brp`, exit 0. Raw log SHA256 is
`a8fb36ed12cf8c055138dfd482061c3e1b098f6986f07723e82d5d189f127f68`.
All 39 actual source modules reconcile to declarations, with 1,089 source
function headers and 1,089 top-level user functions; runtime/system has two
String globals and no Blorp function headers. Source imports/aliases, globals,
types and retained slices were manually reconciled with the existing JSON facts.
There are zero compiler-owned Char types/literals, forbidden String calls or
references, or unresolved selected-direct callees. All 176 resolved String calls
belong to allowed byte/scalar, actual String-data, diagnostic or emission uses.
The 3,378 unknown selections are 3,328 known constructor IDs, 49 typed union/
member constructors and the existing generic translate parameter; the one
deferred trait call is the tagged generated entrypoint. Full facts and limits
are in `functional/resolved-source-inventory.final.json` (SHA256
`0f8a9a16dca95870f146a97ab12d452d6d515c341101a141015bcae2c8230565`)
and `final/SOURCE_INVENTORY.md`. This establishes the migration dependency
boundary; no generic late-resolution or complete bootstrap claim follows.

The lazy plan's three early-None diagnostic proofs ran after final review found
they were absent from the retained historical packet. A complete ignored scratch
copy preserved relative imports and the exact D source/library bytes. Each
Repeat/Set/Concat mutant replaced only its corresponding None error with the
existing `checker_invariant(site.span, RuntimeContractMismatch)`. Each compiled
successfully, exited 1 with exactly its intended diagnostic callback failing and
16 other callbacks passing, then restored byte-exactly to 17/17 and exit 0.
Every restoration reverified all 39 source and nine library files. Patches,
full logs, exact exits and verification receipts are under
`final/lazy-mutations/{Repeat,Set,Concat}.{patch,red.log,red.status,restored.log,restored.status}`.
Actual candidate diff stayed `81cfcf...` throughout. The old before/after greens
remain semantic characterizations, not a failing-before proof; the original
historical cost result remains FAILED.

The separately documented old supporting-host compile-time strict leak
limitation remains FAILED status 99 with complete valid C; no such exception
was used for target/native strict runs or the original checkpoint proxy.
Independent final landing review remains pending. All compiled lanes were
returned after these finite gates; no further sample or source optimization ran.

## Benefit, bounds and remaining work

The intended bootstrap benefit is replacing compiler-source Char and String
classification dependencies with accepted counted-byte/scalar operations.
Measured per-input allocations improve, while normal instruction and proxy
costs remain within the explicit fixed-A/D ceilings.
Migration LOC is production +285/-209 (net +76), tests +136/-2 (net +134).
Lazy construction is production +9/-8 (net +1), tests +30/-4 (net +26). Their
separate reviewed ceilings remain unchanged; no new language fixtures were added.

The fixed A/D measured input/proxy, byte-membership pin, fresh pre-DCE dependency,
lazy mutation/restoration and full current correctness requirements are complete.
Independent final landing review remains required. A new failed gate or unexplained
difference stops for root review. Do not alter D, roll A to D, apply this policy
to another pilot or change another threshold. Genuine self-compilation and any
future host transition need separate matched evidence; the historical failure
remains a failure. This report authorizes no execution or candidate publication.
