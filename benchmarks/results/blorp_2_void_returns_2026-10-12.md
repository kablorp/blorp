# Pilot Void returns and main signatures

Validated 2026-10-12 in worktree `1332`, based on
`1279c51d583cc3a08107467a16e8702c1bfbbc72`. Validation used the working-tree
changes on that baseline.
Scope is the pilot compiler; the existing host compiler is unchanged.

## Semantics and phase ownership

An omitted function return annotation means Void, just like explicit `-> Void`.
The final expression is still checked and evaluated, then its value is discarded.
Owned results follow the normal destruction path. Pure functions cannot return
Void, including generic instantiations whose concrete return type is Void.
Function bodies still require an expression.

Main accepts either zero arguments or `args: List[String]`, and either Int or
Void as its result. Int supplies the exit status; Void always supplies zero.
Pure main remains valid with Int and invalid with Void.

Parsing preserves an optional written return annotation. Checking resolves the
semantic type and publishes typed argument and result conventions for main.
Specialization translates the function identity while preserving those accepted
conventions; independent ownership verification checks them against the concrete
signature. Emission consumes the conventions directly.

Before publishing a checked Void body, checking normalizes a returned expression
into an ordinary discard followed by canonical Void. Each terminal match arm is
normalized separately, allowing arms with different discarded result types.
Tail recursion retains its explicit recurrence exit. Lowering, ownership and the
runtime need no new discard mechanism.

## Validation

Repository host build status was FRESH: compiler inputs from `e950541abeb9`,
CLI `-O0`, runtime `-O2`, Apple Clang 21 on macOS arm64. Host SHA256:
`286a1720a36a75599f910e1b8ab838df642a3983409cd30ed3a6ef3dcf16ba79`.
The native gate built the pilot once at `-O0`; its SHA256 was
`7553806f9b6ba8e011494f8c0b121dd0e8cd8f4399ec58fbb1bcb97f6ba8015e`.

All local packet paths below are relative to `blorp_2/build/void-return/`.
The recorder retains commands, stdout, stderr, elapsed time and fingerprints.

| Boundary | Result | Packet |
| --- | --- | --- |
| Initial failing tests | Nine intended failures; existing pure Int control passed | `before` |
| Final focused Void and reachability tests | 45/45 passed | `focused-followup-second` |
| Full unit, runtime, grammar and tooling | 1,643 Blorp callbacks and 35 C runtime checks passed, 18.916s | `full-unit-final-2` |
| Full end-to-end | 224 grouped checks, 329 native executions, 200 measured fixture compilations passed, 125.624s | `full-e2e-final` |

The strict full unit process reported 2,413,804 allocations and releases, zero
leaked objects and zero leaked bytes. The stripped host does not support
`BLORP_MEMORY_STATS`; the final command uses `BLORP_LEAK_CHECK=strict`, which
selects diagnostic test children without rebuilding the host. Native fixtures
compile as unmodified strict C11 at `-O0` with ASan and UBSan. The e2e harness
uses its ordinary one-build path and real fixture main functions. Existing cost
ceilings are unchanged; eight new main-signature fixtures use the existing
argument-development envelope. These are acceptance results, not a performance
comparison.

Both final full-gate packets record the same source fingerprint,
`6952ab44e6432d3172026a562915dc59ced119c5501ca641733b5238a318e5c7`,
with `source_changed_during_run=false`. This documentation report was added
after those gates.

Tests cover omitted and explicit annotations, both main arities, exact typed
pure-Void rejection diagnostics, direct and transitive generic rejection,
discard normalization, heterogeneous terminal match arms, preserved recurrence,
String/union/List cleanup, borrowed argv identity, malformed entry conventions,
and native side effects and exit statuses. The owned List test requires exactly
one drop of the returned obligation while preserving the borrowed argument.

Representative emitted programs are retained in
`generated-c/{void_nullary,void_arguments,implicit_void_arguments}.c`, with
individual `c-inspection-*` packets. Inspection confirms calls execute before
discard, owned String/List/Option obligations are released, argv roots are
released after the language entrypoint returns, and Void wrappers return zero.

## Review and limits

An independent compiler-expert review approved the implementation and final
test changes with zero remaining findings. A separate test-runner executed the
final gates and inspected generated C. `git diff --check` passed.

Earlier failed packets remain available. A stale reachability assertion was
updated to inspect the retained call in its new discard position. An initial
fixture attempted an owned expression before a terminal match, which is beyond
the current pilot boundary; the final fixture uses an ordinary borrowed Option
helper instead. The existing restrictions on owned tail-match prefixes and
managed values in tail-recursive functions remain. Full host premerge gates
were outside this pilot-only change. These checks do not establish exact
per-object destruction totals or native LeakSanitizer coverage.
