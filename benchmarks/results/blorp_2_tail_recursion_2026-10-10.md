# Blorp 2 guaranteed self-tail recursion, 2026-10-10

Implemented the [approved MVP](../../blorp_2/TAIL_RECURSION_PLAN.md):
`@tail_recursive` guarantees explicit direct-self loops for nongeneric functions
whose signatures and evaluated values are unmanaged. The guarantee holds at
`-O0`. Generic and managed loops, mutual tail recursion and trampolines remain
deferred. Other helper calls retain their ordinary stack behavior.

## Complete facts and code generation

The optional annotation becomes a function-owned execution variant. Checking
uses resolved function identity and publishes an explicit return-or-recur
terminal. Specialization preserves that terminal; lowering evaluates its
ordered arguments once into immutable value identities. Ownership admission
uses the existing physical classification, including unused managed values.
The independent verifier checks raw backedges, scope, nominal types, arity,
absence of owners, and absence of surviving ordinary self calls.

Emission opens the C loop before parameter snapshots and prefix work, then
replaces parameter slots from complete immutable argument captures and continues.
No new execution framework, cache, C driver, fixture rewrite or optimizer
assumption was added. Ordinary concrete expressions retain their established
callee diagnostic anchors; tail diagnostics and recur terminals retain complete
call occurrence spans. Eight regressions in those existing spans were fixed
at the specialization boundary without weakening their assertions.

## Independent validation

Recorded command:

```sh
scripts/record-validation \
  --output blorp_2/build/tail-recursion/independent-full-gate \
  -- make -C blorp_2 test
```

The independent run finished in 66.605 seconds with exit 0, no timeout, empty
recorder stderr, and `source_changed_during_run=false`.

| Component | Result |
| --- | ---: |
| Unit callbacks | 780/780 |
| Native C runtime cases | 9/9, plus passing Blorp wrapper |
| Grammar callbacks | 86/86 |
| E2e inner cases | 127/127, plus passing Blorp wrapper |

The increment adds 129 unit/helper callbacks, four grammar callbacks, and 15
unchanged real-main fixtures. Tests cover syntax and exact diagnostics,
resolved identity and tail contexts, specialization, evaluation order,
last uses, ownership admission, raw malformed ownership IR, and emission.
The existing unit assertions were migrated to explicit phase terminals;
two invalid-character inputs changed from `@` to `$` because `@` now has syntax.

All 110 valid native fixtures stayed within their individual compiler-cost
budgets. The new examples exercise base arms, direct and UFCS recursion,
swaps, duplicate arguments, aliases and mutable-binding versions, repeated
prefix work, records, union payloads, and helper-internal managed values.
The four-digit countdown executes 65,535 backedges at `-O0` under ASan/UBSan.
Its emitted C has maximum brace nesting 4 and parenthesis nesting 1, using
default Clang limits and no stack override.
Its compilation used 12,552/100,000 allocations and 63,490,816/500,000,000
retired instructions in the independent gate.

Independent compiler-expert review approved source, tests and documentation
with zero blockers, should-fixes or nits. The test-runner independently checked
healthy generated C, the frozen inventories, and fault evidence.

## Tests detect deliberate faults

Temporary production edits were restored exactly after each direct Blorp test:

| Deliberate fault | Unchanged test outcome |
| --- | --- |
| Omit traversal of direct recur arguments | Intended nested-self-call test fails, 1/31 |
| Omit traversal of nonself UFCS arguments | Intended non-tail argument test fails, 1/31 |
| Remove independent backedge arity check | Wrong-arity test fails, 1/19 |
| Hoist snapshots and prefix outside the loop | Loop-placement test fails, 1/7 |

Two native emission faults preserve verification and compile the original
real-main inputs without rewriting source or emitted C. Reading an overwritten
parameter makes the swap return 9 instead of 7. Emitting an ordinary self call
for the countdown produces demonstrated ASan stack exhaustion with repeated
`blorp_f_5` frames. The restored programs return 7 with empty streams.
The coordinator independently re-executed both faulty native binaries through
a Blorp TestSuite: 2/2 assertions passed in `native-blorp/`.

A mistakenly introduced Python behavioral controller was removed. Its
assertion receipts are excluded from acceptance; the direct Blorp reruns and
retained native artifacts provide the evidence above. The hoisted-snapshot
fault was checked structurally rather than executed as a potentially infinite
native program.

## Matched compiler cost and provenance

The baseline is the pre-feature working tree on `blorp-2` at
`b83ef1d767d843d4ec7052e603e3ed86a1e623de`, including earlier uncommitted pilot
audit fixes. It is not clean HEAD. Unrelated preexisting host-backend changes
were preserved and are outside this validation's scope.

Three serial matched pairs compiled the same 95 frozen unannotated inputs,
reversing baseline/candidate order in pair two. Both pilots use the same host
compiler and Apple Clang 21, `-O0`, and normal/diagnostic runtime modes. Normal
mode supplies retired instructions; diagnostic mode supplies deterministic
allocation counts and strict zero-leak checks. Every pair and mode emits
byte-identical target C.

| Owned-input-through-C proxy | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations, summed once per fixture | 277,369 | 282,058 | +1.6905% |
| Sum of per-fixture median retired instructions | 3,315,336,364 | 3,326,608,936 | +0.3400% |

The worst individual increases are +2.4848% allocations and +0.7643%
instructions, both on `match/many_arms.brp`. Aggregate and individual changes
stay below the approved 5% ceiling. These measurements include process startup,
input loading and C emission; they are not self-compilation or target-runtime
measurements. The pilot cannot self-compile yet. No speedup is claimed.

Handwritten physical line changes versus the frozen pre-feature baseline:
production +1,056/-122 = **+934**; tests and fixtures +3,376/-160 = **+3,216**.
This implements a new capability; no line reduction is claimed.

Key SHA-256 identities:

```text
host bin/blorp:
8d9c5a7b33b2fc4203f90d14b671cfead8ba63b5b3b4f645142015645683ad66
final pilot compiler C:
934421948f4ce9a218c5f3e6f3ae16a88dd9796bb523235fc200bc7721d93bf7
final source inventory file:
c4aea0c37d2125f1a7d37178eed0f9e69673cfa9662cc13e79addecee03ceb7a
```

Complete source/binary/fixture hashes, raw samples, direct mutation logs,
healthy and faulty C, and validation receipts are retained in
`blorp_2/build/tail-recursion/`; its README routes the artifacts. Earlier
pre-final measurements are isolated under `early/` and are superseded.

An adjacent host code-generation defect produced a referenced but undefined
C function for an unnecessary checker closure. A clearer named local helper
removed that closure from the pilot; the host defect itself was retained as
evidence and was not repaired in this increment.
