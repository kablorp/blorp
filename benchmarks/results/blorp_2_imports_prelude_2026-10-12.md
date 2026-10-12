# Blorp 2 imports and prelude integration

Workload baseline: detached `45f59148cf3671faa7ed65f09a41c56f45f87b80`
with the pre-existing argv/calculator changes. Frozen sources and patch are in
`blorp_2/build/imports_prelude/baseline/`; the current change does not claim
self-compilation performance.

The repository host was FRESH. Its SHA256 was
`e6b05f8452c2c30d57999734619417ab89f49e6b5202168d584ecfc03201dea1`.
Both pilot binaries use `clang -O0 -DBLORP_MEMORY_DIAGNOSTICS=1`; native fixture
binaries use `-O0`. Allocation counts come from strict leak reports, retired
instructions from macOS `/usr/bin/time -l`.

## Cost budget for mandatory default scope

Before accepting the full default-scope slice, an explicit-import probe loaded
all seven existing operation modules through the frozen baseline compiler:
`int`, `float`, `string`, `list`, `bool`, `option`, and `result`. Its source and
raw reports are retained under `blorp_2/build/imports_prelude/`.

The probe measured **110,081 allocations**, **292,567,981 retired instructions**,
and **zero leaked allocations/bytes**. Previously return-zero loaded only its
small temporary prelude (~956 allocations). These are intentionally different
loaded workloads. The new default prelude makes the full library mandatory;
reading/parsing its retained commented source is included.

For each existing e2e fixture, the investigation budget is its former allocation
limit plus **130,000 allocations**, and its former instruction limit plus
**400,000,000 retired instructions**. These allowances include the complete
measured library-loading cost, canonical foundation declarations, type-scope
closure and receiver association, with bounded headroom. They are assigned to
each fixture's numeric limits directly, not added secretly by the harness.
Repeatable excess must be investigated at the owning phase before acceptance.
The original incremental fixture limits remain visible in the frozen baseline.
New small multi-module cases use 150,000 allocations / 600,000,000 instructions.

Equivalent loaded workloads still have the roadmap's +15% allocation / +10%
instruction investigation ceilings. Final paired results, source/binary hashes,
line counts, behavior checks and limitations will be recorded below.

## Implemented boundaries

The loader reads/parses each normalized module path once, publishes its explicit
role and source row, and seals the designated foundation IDs. The base owns
builtin types and ordinary Bool/Option/Result declarations. The prelude supplies
its written import scope to user roots/helpers; operation modules receive base
plus their own imports. Foundation inputs cannot be explicitly imported.

Namespace construction carries original type/constructor/function identities
through a finite forwarding closure. It publishes parsed visibility and method
requests, with no accepted semantic authorities. Checking accepts signatures
once, builds scope-owned DirectAndUfcs/UfcsOnly bindings from selected modules'
local functions, resolves by the complete receiver type and then arity, and
publishes complete call contracts. It retains neither a runtime-name fallback
nor a second signature authority. Generic callee contextual inference remains
unchanged: annotate an otherwise ambiguous generic constructor/record receiver.

Independent compiler-expert review approved the final source with zero open
confirmed issues. Review caught and fixed cross-file equal-offset import
conflicts, a Result propagation boundary that bypassed contextual diagnostics,
builtin/nominal foundation collisions, and filesystem-root library role
classification. The collision and root-role tests were red before their fixes.

## Validation

The host remained FRESH; no existing-compiler implementation or host library
source was changed. Native compilation and measurements were serialized.
Repository-owned `scripts/record-validation` packets are retained under
`blorp_2/build/imports_prelude/`:

| Gate | Result | Packet |
| --- | --- | --- |
| Complete unit suite | 1,412 passed, 0 failed, 94 suites | `validation-unit-final` |
| Pilot grammar | 153 passed | `validation-components` |
| Runtime C invariants | 35 native cases plus passing suite orchestration | `validation-components` |
| Comparison tooling contracts | 7 passed | `validation-components` |
| Complete e2e suite | 216 group cases passed, 0 failed | `validation-e2e` |

Commands:

```sh
BLORP_NO_FORMAT=1 bin/blorp test --suite --timeout 180 blorp_2/test/unit
BLORP_NO_FORMAT=1 bin/blorp test --suite --timeout 180 \
  blorp_2/test/runtime blorp_2/test/test_grammar blorp_2/test/tooling
BLORP_NO_FORMAT=1 bin/blorp test --suite --timeout 0 blorp_2/test/e2e
scripts/compiler-build-status --quiet
git diff --check
```

E2e builds the pilot once at `-O0` with allocation diagnostics. Successful
fixture compilations require balanced allocation/release counts and zero leaks.
Native fixture and runtime C tests compile at `-O0` with AddressSanitizer,
UndefinedBehaviorSanitizer, and `-fno-sanitize-recover=all`. Native entrypoints
and input/output/status expectations remain the verdict; tests do not rewrite
emitted C or call internal generated functions. Five new positive multi-module
fixtures and three negative fixtures cover method composition, forwarding,
helper defaults, receiver selection, generic managed values, direct-call
rejection, and the independent-type requirement.

The final unit and component packets have stable start/end source fingerprints.
The e2e packet reports a whole-worktree change because GUIDE/GRAMMAR wording
was clarified during execution. Independent test-runner review checked all 386
active compiler/test/library/script/Makefile/EBNF inputs: none changed after
its start at `2026-10-12T19:41:21.665736Z`. Only the two unconsumed documentation
files changed during that run. This is a documented docs-only reuse boundary,
not a claim that the whole-worktree fingerprint stayed identical.

Three bounded mutations proved the new negative tests protect behavior:

| Deliberate breakage | Intended failures | Restored result |
| --- | --- | --- |
| Permit UfcsOnly bindings in direct lookup | 2 | 15/15 visibility tests pass |
| Ignore nongeneric receiver type identity | 8 | 31/31 resolution tests pass |
| Forward a target module's imported dependency functions | 1 | 15/15 visibility tests pass |

`mutation-receipt.json` retains commands, logs, failed case names, and original/
restored source hashes. All mutations were restored before final gates.
Independent test review confirmed that phase fixtures still assert exact
ValueIds, owner obligations, transfers, drops, and verifier errors. Phase-only
programs use an explicit primitive foundation and empty prelude. Real library
calls require written imports there. Actual default scope is exercised through
the loader and e2e tests. Exact compact C and structural-depth checks remain
at that isolated phase boundary, while default-scope e2e accepts the changed
library declaration inventory.

## Matched cost evidence

The matched measurements and line counts below describe the integration snapshot
before the subsequent removal of empty Option/Result operation modules. Their
retained manifests identify those inputs; they are not measurements of the
post-cleanup library.

Three alternating baseline/candidate samples used identical probe root bytes
and loaded all seven operation modules. The baseline uses its frozen library
and positional prelude; the candidate uses the new canonical foundation and
ordinary prelude. The declaration inventories deliberately differ, including
an ordinary String length wrapper. This is an equivalent loaded-work proxy,
not byte-identical source inventories or self-compilation.

| Median metric | Frozen baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 110,081 | 111,726 | +1.494% |
| Retired instructions | 284,986,493 | 290,627,370 | +1.979% |
| Leaked allocations/bytes | 0 / 0 | 0 / 0 | unchanged |

Both are below the +15% allocation/+10% instruction investigation ceilings.
Allocation counts are identical across each compiler's three runs. Retired
instructions vary, particularly on each compiler's first sample; wall time is
not used as evidence. All existing/new e2e cost limits pass.

`paired/provenance.json` records exact command arguments, alternating order,
C flags, toolchain identity, workload/source manifests, and binary/generated-C
hashes; `paired/samples.tsv` and each sample's `.time`/`.stderr` retain raw data.
Both probe C outputs were independently compiled with the same O0 sanitizer
flags and exited 0 with empty stdout/stderr. C hashes are stable within each
compiler; different declaration inventories make cross-compiler C equality
inapplicable.

Binary SHA256:

- Frozen baseline: `3c8f1f9941205bd114f22b5922470ea85bbd54c0bde646b8e9c3d329b71faa9c`
- Candidate: `c4a013818b48ba0abedc6bd7fe57774c90b787baeed1e91af055916863be7780`
- Candidate input manifest: `56f3cf0b9c1d4e777a749034341752cd01629f4233f86c70525f660d7110ff32`

Generated C inspected for `method_modules`, `generic_methods`, and `forwarding`
is retained beside the packets. It uses resolved numeric function identities,
ordinary calls to the selected declarations, and existing union/String
retain/release helpers. E2e covers managed copies, replacement, return, and
exhaustive destruction through these imports.

## Line counts and limits

Counts compare the frozen pre-task pilot with the final pilot, preserving the
pre-existing argv/calculator work. Generated artifacts are excluded. Physical
counts include blank/comment lines; the second column excludes those lines.
Exact category counts are retained in `line-counts.txt`.

| Handwritten scope | Physical line change | Nonblank/noncomment change |
| --- | ---: | ---: |
| Compiler production | +559 | +498 |
| Unit tests | +1,932 | +1,717 |
| E2e tests and fixtures | +132 | +128 |
| Grammar tests | +16 | +8 |
| Runtime tests | 0 | 0 |
| Tooling tests | -1 | -1 |
| Target library | +26 | +15 |

This feature adds production code overall. Foundation cleanup removes 275
lines; explicit namespace/method resolution and typed diagnostics account for
the net growth. Reviews found no new cache, registry, compiler layer, or
whole-program method cross-product. No source-size reduction is claimed.

The default prelude now requires the full active operation library, including
its retained commented upstream source. Existing specialization eagerly emits
all nongeneric functions, so even return-zero includes unused library wrappers
and associated runtime support. This work measures that cost; it does not add
dead-code elimination or a cache. Future optimization should measure actual
loading/checking/emission work before introducing either.

General module cycles remain allowed. Function reexports, general overload
ranking, private items, prelude opt-out, and broader List support remain deferred
as specified. Host code generation rejected some qualified function values and
complex nested patterns during validation; equivalent explicit calls/matches
were used, with no host compiler patch or target-language semantic workaround.

## Empty operation module cleanup

At the user's request, removed `standard_library_temp/option.brp` and
`standard_library_temp/result.brp`, which contained no active operations.
Option/Result and their constructors remain ordinary declarations owned by
`_base/types.brp`. The prelude, library adapters, twelve existing fixtures and
documentation examples no longer import the deleted modules. Fixture bodies and
assertions are unchanged; no compiler implementation changed in this cleanup.

`validation-remove-empty-ops` records a fresh complete e2e run: 216 group cases
passed, zero failed, and the outer build-once wrapper passed. Its start/end
source fingerprints match. Native sanitizers, exact output/status assertions,
leak checks and existing compilation-cost ceilings all pass. Documentation-only
authority/visibility corrections followed the recorded run. No post-cleanup
performance improvement is claimed.
