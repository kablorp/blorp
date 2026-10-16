# Blorp 2 scaffolding cleanup — 2026-10-12

The four pilot cleanup slices and the bounded host callable-identity fix are
implemented and independently reviewed. Pilot validation passes. Integration is
not gate-clean: the broad host sanitizer harness timed out and the compiler
batch crashed. Their isolated suites pass, which does not establish the cause
of either broad failure. A separate nested-or-pattern defect reproduces on the
frozen and rebuilt hosts and remains a follow-up.

## Changes and boundaries

- Removed the empty Bool operation module and its imports. `_base/types.brp`
  remains the sole owner of Bool, Option and Result.
- Replaced spelling-based unit-library assembly with explicit module sources
  and dependency ordinals. Root-only phase inputs receive primitive base types
  and an empty prelude; written imports require explicit inputs. Loader and
  e2e tests still use the actual configured target library.
- Specialization seeds its existing worklist from accepted `main`, preserving
  declaration identity plus complete concrete arguments as the instance key.
  The existing traversal discovers reachable callees and required layouts.
  Every variant's payload dependencies are retained, including inactive
  variants. Checking still rejects errors in unreachable declarations.
  Phantom type arguments remain part of complete nominal instance keys; this
  is not runtime-use pruning of generic arguments.
- Active library modules contain only supported declarations. Exact upstream
  copies were retained separately at this point; those redundant copies have
  since been removed. Revision/hash provenance remains in adapter headers, and
  the original modules live in [standard_library/src](../../standard_library/src/).
  Checked native primitives remain explicit; this
  change does not claim self-hosting or implement unsupported library features.
- Host Stage 08 now preserves the accepted callable identity for qualified
  function values using the existing checked projections. It does not resolve
  names again or weaken the downstream malformed-Core invariant.

No cache, pipeline pass, emit-all mode, alternate fixture entrypoint or fixture
rewrite was introduced. The e2e harness itself is byte-identical to the frozen
cleanup baseline. Each run builds the pilot once at O0 and compiles/runs the
unmodified fixtures. `main` returns process status; stdout and stderr have
independent exact assertions.

## Evidence and provenance

The ignored local evidence root is
`blorp_2/build/cleanup_2026-10-12/`. Its baseline is the dirty worktree before
this cleanup, including the preceding argv and imports/prelude work, rather
than HEAD. The [committed cleanup design](https://github.com/kablorp/blorp/blob/4b05ea3b431d9fbe4e906a0802bd41060b6f397f/blorp_2/CLEANUP_PLAN.md) fixed the slices, workloads and ceilings
before implementation: investigate repeatable allocation growth above 2% or
median retired-instruction growth above 3%; compiler production lines must fall.

Key artifacts:

- `baseline/blorp_2/`, `baseline/host-blorp`, `baseline/compiler.c`, and
  `baseline/worktree.patch`: frozen inputs and original generated code.
- `baseline-source-generation-relative/`: fresh generation from frozen pilot
  sources using the frozen host and explicit host standard-library directory.
  Its output is byte-identical to retained baseline C, without normalization:
  SHA256 `1ccf0334cdef7ebf9d669a19055ef2ebb2493047ac1487ed16e9a2ee1c9a8354`.
- `baseline-rebuild/`, `candidate-build/`: recorded native construction. Both
  use `clang -O0 -DBLORP_MEMORY_DIAGNOSTICS=1 ... -lm -lpthread`;
  candidate C was also produced by the frozen host. Measured baseline binary
  SHA256 is `c189ebccad0f7b4621fcbbe298a74b41771e8e0ddc53b515fe54e007c041da86`.
- `measurements/`: retained input/library/source manifests and preliminary
  samples. `confirmed-measurements/` and `performance-confirmed/` are the
  authoritative 36 matched samples after baseline reconstruction. Do not use
  preliminary values as final results.
- `native/`, `native-behavior/`: 18 normal-entrypoint native sanitizer builds,
  exact status/stream checks and native compilation timing.
- `unit-second/`, `pilot-components/`, `pilot-e2e/`, `host-focused/`,
  `host-regressions/`, `host-gate-logs/`: recorder packets and gate logs.
- `host-repro/qualified-real-helpers/`: authoritative Prelude/Own callback
  probes; earlier pilot entries in `green-and-patterns*` are retired invalid
  scratch probes. The valid basic callback/nested-or results remain in
  `green-and-patterns/`; valid nested-list results are in
  `green-and-patterns-corrected/`.

Frozen host SHA256:
`e6b05f8452c2c30d57999734619417ab89f49e6b5202168d584ecfc03201dea1`.
Rebuilt host SHA256:
`0edad2dceb3fac290a40476a1d449997796556a71ef33271cbb997b065673727`.
Source, C, binary, workload and both library snapshots have SHA256 manifests.
Native commands were serialized. Passing pilot/cost packets report stable
source. The broad host packet reports source changes because pilot test
migrations occurred during that run; host production sources were frozen, but
the packet does not prove a globally frozen tree.

## Matched cost results

Three alternating baseline/candidate pairs per workload and per library,
Apple clang 21, `/usr/bin/time -l`, strict compiler leak checks. All 36
samples balance allocations/releases with zero leaked objects. These measure
the whole pilot CLI through C emission, including loading and paths; they are
not self-compilation measurements. Frozen and slim library roots are retained
explicit inputs. Within each compiler/workload, emitted C is byte-identical
across library variants and all three samples.

Using the same frozen library isolates the specialization code change:

| Workload | Baseline allocations | Candidate allocations | Baseline median instructions | Candidate median instructions |
| --- | ---: | ---: | ---: | ---: |
| return-zero | 103,446 | 98,176 | 271,979,078 | 258,081,899 |
| calculator integer | 132,104 | 129,523 | 360,108,080 | 350,422,054 |
| method modules | 106,639 | 101,618 | 282,573,997 | 268,939,100 |

Allocation changes are −5.09%, −1.95%, −4.71%; instruction changes are
−5.11%, −2.69%, −4.83%. Every matched workload passes the declared ceilings.

With the slim library, candidate totals are:

| Workload | Allocations | Median instructions | Allocation change from frozen baseline | Instruction change from frozen baseline |
| --- | ---: | ---: | ---: | ---: |
| return-zero | 9,207 | 59,223,457 | −91.10% | −78.22% |
| calculator integer | 38,206 | 147,076,446 | −71.08% | −59.16% |
| method modules | 12,629 | 70,761,980 | −88.16% | −74.96% |

Generated C changes intentionally. Native code was read and compiled with
strict C11 warnings, O0, ASan and UBSan. No source or emitted C was rewritten.

| Workload | Baseline C bytes | Candidate C bytes | Median native build seconds, baseline → candidate | Native oracle |
| --- | ---: | ---: | ---: | --- |
| return-zero | 15,249 | 181 | 0.06 → 0.04 | status 0, empty streams |
| calculator integer | 33,792 | 27,411 | 0.07 → 0.06 | `add 20 22`: status 0, stdout `42` + LF |
| method modules | 16,390 | 1,810 | 0.06 → 0.04 | status 42, empty streams |

Native build times have 0.01-second resolution and are directional evidence,
not a precise speedup claim. All 18 runs have empty stderr. macOS ASan leak
detection is disabled; strict compiler leak checks and the repository leak gate
are separate evidence.

## Validation and review

| Check | Result |
| --- | --- |
| Full pilot unit suites | 1,432 callbacks passed; 8.840 s |
| Runtime, grammar, tooling | 196 callbacks passed; 10.955 s |
| Full pilot e2e, `--suite --timeout 0` | 216 aggregate cases passed; 117.620 s; exactly one pilot generation/link |
| Matched compiler samples | 36 passed; zero leaks; ceilings passed |
| Native ASan/UBSan builds and normal entrypoints | 18 passed |
| Focused host lowering/function-ref/record/invariant suites | 210 callbacks passed |
| Focused host lowering/function-ref suites, sanitized | 185 callbacks passed |
| Isolated host DCE, sanitized | 42 passed; 3.059 s |
| Isolated host collection pipeline | 36 passed; 2.907 s |
| Host code-generation audit | 241 passed |
| Host bootstrap fixpoint | All three stages emit byte-identical C |
| Broad host sanitizer harness | 364 passed, one batch timed out after 180 s |
| Broad host compiler gate | 1,822 passed, one batch exited 139 |
| Host leak gate | 1,267 checks passed |

The audit and fixpoint recorder packets are `host-codegen-audit/` and
`host-fixpoint/`. All three fixpoint outputs are 85,154,138 bytes with SHA256
`e0425aef1ed760ff7480a06e9167a184fb3272e8789a44eadbfc308a919231b7`.
Both packets and `host-focused-sanitize/` report stable source. The two broad
failures remain unresolved; passing isolated suites neither resolves them nor
classifies them as pre-existing.

New helper tests demonstrated three passes and two failures before explicit
input assembly and 5/5 passes afterward. The corrected specialization red run
first accepts all seven valid inputs with the frozen implementation, then fails all seven new
reachability oracles; its unreachable-error oracle still passes. Candidate
focused suites pass 39/39. Host lowering regressions fail before the callable
fix and pass afterward; real Prelude/Own callbacks source-check on both hosts,
but only the rebuilt host successfully compiles them.

Independent compiler-expert code and migration reviews found zero issues.
Test-runner review verified receipts, hashes and raw measurements. All 62
original verifier function bodies and 39 exact error strings remain unchanged;
four raw verifier suites are byte-identical. Existing test definitions are
retained. Inventories and exact C expectations were migrated to accepted main0
and first-discovery ordering, without weakening ownership or output assertions.

| Source inventory | Before | After | Delta |
| --- | ---: | ---: | ---: |
| Pilot compiler `.brp` | 18,449 | 18,376 | −73 |
| Active target library `.brp` | 3,815 | 107 | −3,708 |
| Unit tests/helpers `.brp` | 43,508 | 44,537 | +1,029 |
| E2E suites/fixtures `.brp` | 7,010 | 7,010 | 0 |

The separate host fix adds 11 production lines and 125 test/helper lines.
At this milestone, 3,688 lines of exact upstream reference source were moved
outside compiler inputs rather than deleted. Those redundant copies have since
been removed; the original standard-library modules remain.

## Separate nested-or follow-up

This valid existing-compiler example source-checks but leaves a raw match in C
on both frozen and rebuilt hosts:

```blorp
union Kind:
    One
    Two
    Three

pure func choose(left: Kind, right: Kind) -> Int:
    match (left, right):
        (One | Two, One): 42
        _: 0

func main() -> Int:
    choose(Two, One)
```

Owner: `blorp/src/compiler/stage_09_core/match_lowering.brp`.
`expand_or_match_case_at` expands top-level alternatives; tuple matrix columns
retain nested `OrPattern`, which `compile_pattern_matrix` cannot consume.
`compile_expr_at` then retains `RawMatchExpr`; native C compilation rejects
`choose child_kind=raw_match`.

Existing CorePattern data is sufficient, but expansion must freshen outer
pattern binders and their body references as well as body-local binders.
The current body-only cloning helper is insufficient. This is separate from
the qualified-callable identity fix. A follow-up must test nested tuple,
constructor and list alternatives; neighboring binders such as
`(One | Two, value)`; duplicated body-local bindings; first-arm priority;
unique identities, valid ownership and native results without surviving raw
matches. The suspected five-element nested-list binder failure did not
reproduce: the valid probe returns 42 on both hosts.
