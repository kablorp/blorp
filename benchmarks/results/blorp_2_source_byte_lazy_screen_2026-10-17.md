# Source-byte migration: failed historical screen and bounded landing policy

The original R0/D cumulative allocation experiment **FAILED**. Candidate D used
9959 allocations on c0004 against the unchanged 9923 cap, 36 above it. The
coordinator subsequently approved one explicit landing-policy exception after
two independent expert recommendations, under the user's authorization to
adjust roadmaps. Candidate acceptance remains pending; this report claims no
normal-instruction, corpus, proxy or self-compilation acceptance.

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
corpus, normal samples, host proxy or further optimization followed the failure.
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

## Benefit, bounds and remaining work

The intended bootstrap benefit is replacing compiler-source Char and String
classification dependencies with accepted counted-byte/scalar operations.
Measured c0004 local allocations improve; no broader improvement is claimed.
Migration LOC is production +285/-209 (net +76), tests +136/-2 (net +134).
Lazy construction is production +9/-8 (net +1), tests +30/-4 (net +26). Their
separate reviewed ceilings remain unchanged; no new language fixtures were added.

Remaining acceptance requires every exact current A/D input, original absolute
caps, three unfiltered alternating normal samples, and the original
`artifact_construction_complete total_allocations` proxy with status 0/Generated
stdout and `BLORP_MEMORY_STATS=1` while leak mode is unset. Exit-time strict
totals are not a substitute. Full current owner/unit/runtime/grammar/e2e and
source-inventory checks remain required. A new failed gate or unexplained
difference stops for root review. Do not alter D, roll A to D, apply this policy
to another pilot or change another threshold. Genuine self-compilation and any
future host transition need separate matched evidence; the historical failure
remains a failure. This report authorizes no execution or candidate publication.
