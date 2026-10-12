# Remove temporary compiler scaffolding

Approved on 2026-10-12 after the imports/prelude integration. Existing argv,
imports and other dirty work is preserved. This change does not expand the
input language merely to make a cleanup easier.

## Slices and boundaries

1. Remove the inactive Bool operation module and imports. Base retains sole
   ownership of Bool and its constructors. Relocate commented upstream source
   outside compiler input modules, preserving the reference and provenance.
2. Remove automatic substitute-library selection from unit-test assembly.
   Existing pure assembly accepts explicit source modules, dependency edges,
   and a chosen foundation. Actual loader/e2e tests retain the real library.
3. Seed the existing specialization worklist from the accepted entrypoint.
   Checking still validates all source declarations. Reachable function
   requests use original declaration identity plus concrete type arguments;
   selected bodies request their complete callees and layout dependencies.
   The builder freezes once into the existing SpecializedProgram. No new
   pipeline layer, cache, emission mode, or string-based dependency keys.
   Prune unused layouts as a separately reviewable part of this slice.
4. Keep active target library modules small and their primitive contracts
   explicit. Composite operations can migrate to ordinary Blorp as examples
   require supporting functions/data. Current native primitives remain valid;
   full self-hosting is a later milestone, not a claim of this cleanup.
5. Reduce the reported host qualified-function-value/nested-pattern failures
   to minimal regressions, repair confirmed bounded defects in their owning
   phase, and simplify affected pilot code only where that improves clarity.
   Host changes remain separate from pilot production changes. An inability
   to reproduce or a larger architectural prerequisite is reported explicitly.

## Tests and acceptance

Write new regressions before implementation. Specialization tests cover direct
and UFCS calls, finite self/mutual recursion, generic instance identity, all
match arms, calls inside arguments, unused bindings and discarded expressions,
including impure calls. Unreachable type errors still fail checking. Return-zero
specializes one function; unused library functions and runtime fragments are
absent from its generated C. Existing phase tests explicitly make tested
functions reachable or directly supply their typed phase inputs; no
test-only emit-everything switch is introduced.

Keep exact phase invariants and native main/status/stdout/stderr assertions.
Run unit, grammar, runtime, tooling and complete e2e suites with O0 pilot/native
builds; e2e retains --timeout 0 and builds the pilot once. Read generated C.
Host fixes additionally run owning compiler regressions and selected repository
gates, with before/after failure evidence. Independent compiler-expert review
and test-runner verification are required. No commits/pushes are requested.

## Baseline, cost ceilings, and stop conditions

The frozen pre-cleanup pilot sources, diagnostic executable, fresh host binary
and tracked patch are in build/cleanup_2026-10-12/baseline/. This explicitly
includes the preceding uncommitted argv/imports work. Retain one evidence root
at build/cleanup_2026-10-12/ and use scripts/record-validation for gates.

Compare baseline/candidate compilation of frozen return-zero, calculator and
multi-module workloads, alternating three samples on the same quiet machine.
Record exact compiler, input/library and toolchain hashes; allocations, retired
instructions, generated C bytes and native compilation latency. A +2% allocation
or +3% median instruction increase on any matched workload requires owning-phase
investigation and rescoping if repeatable; no increases in fixture ceilings are
authorized. Production code must not grow overall for this cleanup. Necessary
regression-test growth is reported separately. These are owned-input proxies,
not self-compilation results; emitted C intentionally changes, while native
behavior and ownership must agree. Preserve input library identity when
isolating specialization cost; measure slim-library effects separately.

Stop and report instead of adding fallback machinery when a host defect, phase
authority gap, unresolved semantic decision, or wider prerequisite appears.

## Outcome

The four pilot slices and bounded host callable-identity fix are implemented.
Pilot unit, component and e2e validation passes; matched costs satisfy these
ceilings. Host focused sanitizer tests, code-generation audit and bootstrap
fixpoint pass. Two broad host harness failures remain unresolved. Nested-or
pattern lowering requires a separate binder-identity follow-up rather than an
extension of the qualified-callable fix. The
[cleanup report](../benchmarks/results/blorp_2_cleanup_2026-10-12.md) records
the exact evidence, line counts, cost results and remaining work.
