# Blorp 2 audit follow-ups, 2026-10-10

Baseline: `b83ef1d767d843d4ec7052e603e3ed86a1e623de` on `blorp-2`.
This report records the bounded follow-ups to the
[architecture audit](blorp_2_architecture_audit_2026-10-10.md), together with
the host-backend failure that prevented the broad sanitizer gate from running.
It does not replace the original audit or claim that an incomplete gate passed.

## F1: validate every union layout before publication

The verifier now rejects an empty raw union layout even when no operation
references it. All layouts are validated before function verification and
publication of `VerifiedProgram`. Existing record and entrypoint error
precedence is preserved. Parsed source already rejected empty declarations;
this repairs the independently checked raw-IR boundary.

Nine direct Blorp callbacks cover unused valid and invalid rows and error
precedence. Four relevant callbacks failed before the change and under a
temporary removal mutation, then passed with the check restored. The focused
verifier/emitter batch passed 95/95; independent execution passed 9/9 and
compiler-expert review approved with zero findings.

## F2: use concrete operations in compiler source

Eleven trait-dispatched operators in five production modules were replaced
with the existing `IntOps` comparisons and `Text.concat`. The verifier's
remaining comparison was replaced in F1. No input-language feature, helper
framework, scanner, or test execution path was added.

The affected unit/grammar batch passed 251/251. Normal pilot CLI comparison
produced byte-identical target C for all 95 unchanged fixtures and identical
status/stdout/stderr for eight rejected inputs covering the edited help text
and declaration ordering. Independent compiler-expert review approved with
zero findings. The five-module production delta is +3 physical lines;
tests are unchanged. This is a bootstrap-subset cleanup, not a performance claim.

## F3: verifier arm storage

The verifier now stores a borrowed immutable prefix and an arm-local ordinal
interval containing only actual rows. Function-wide value and owner IDs stay
unchanged. Relative owner updates and absolute leak diagnostics are checked;
the existing managed-prefix restriction remains enforced. `UnavailableOwner`
and padding loops are removed without a map, cache, or second identity authority.

Fourteen additional direct callbacks cover ordinal gaps, sibling access,
negative/future owners, second-arm acquisition/discharge/transfer and absolute
leak diagnostics. A bad-origin mutation exposed an inadequate existing
sibling-value oracle: it queried before any current-arm row existed. The new
after-definition case fails that mutation. An owner-discharge mutation also
fails its intended regression. Restored focused validation passed 109/109.

Three serial matched pairs used frozen baseline/candidate binaries built by
the same preserved host, Apple Clang 21, `-O0`, and matching normal/diagnostic
runtime modes. The phase probe prepares raw ownership inputs before its exact
allocation bracket, then runs verification and result cleanup 1,000 times.
Instruction counts are whole-process amortized measurements, including input
preparation, emission, startup and loop overhead; zero-repeat controls provide
a separately labelled marginal estimate. They are not direct phase hardware
counters. Construction and lookup are both inside the measured verification.

| 512-arm workload | Exact verification allocation change | Amortized instruction change |
| --- | ---: | ---: |
| Unmanaged result | -35.91% | -80.27% |
| Managed result | -39.89% | -89.40% |
| Managed cleanup | -31.07% | -92.21% |

All one-arm and straight-line representatives reduced instructions by more
than 4.5%. Across 95 unchanged fixture inputs compiled through the normal pilot
CLI, allocations decreased from 280,277 to 277,369 (-1.04%). Summed per-fixture
minimum instructions decreased from 3,329,697,488 to 3,318,191,397 (-0.35%).
The largest individual instruction increase was 0.321%, within the 1% ceiling;
every allocation count decreased. Target C was byte-identical across every
pair and normal/diagnostic mode. These are owned-input compilation proxies,
not pilot self-compilation or target runtime measurements.

Conservative F3 production growth is +8 physical lines versus the frozen F1
baseline, within the +30 cap; this includes four lines formatting F1. F3 tests
grow by 374 lines. Final F1/F3 verifier growth versus HEAD is +22 lines, plus
the new 163-line union suite. No production-line reduction is claimed.

## Host backend stack exhaustion

The broad `compiler-core-sanitize` gate exhausted the host compiler's main
thread stack during C generation, before the sanitizer test callbacks ran.
This is a compiler robustness defect and leaves that gate unvalidated.
Focused sanitizer execution passed 171/171 in the earlier comparison task;
that does not substitute for the broad gate.

The diagnostic reduction reproduces the crash without sanitizers: a single
existing emitter suite, and a small TestSuite with 400 callback tuples.
Generated host C reserves approximately 12.6 KB in each recursive
`emit_function_body` frame. Product-evaluation normalization builds nested
`LetExpr` bindings for nonliteral list elements; both binding RHS and body
edges recurse in emission. Retained final Core contains 1,201 Let and 400 Drop
nodes. The emitter repair replaces recursive binding traversal with explicit
typed continuations; the original 400-callback source now passes 400/400 at
the default settings, including independent execution on the final host
binary. A complete small-program C oracle is established against the frozen
original emitter; candidate equality remains pending.

The new 4,096-depth raw-Core regression exposed a separate recursive query:
`core_expr_type` follows Let/BorrowLet bodies and the second Seq operand.
The generated test child, rather than its compiling host, reported an ASan
stack overflow in that query. The repair follows those three edges iteratively
and preserves every other node's stored result type. The owning Core type
suite now passes 13/13 under ASan/UBSan, including independent execution.

The complete emitter suite remains blocked: its normal generated child exits
139, and the sanitizer run times out after 180 seconds. A live sample of the
sanitizer child shows deep recursion in the existing Core cancellation
planner's `analyze_current_behavior_expr`, called during preparation before
emission. This is evidence of another traversal limit, but it is not an ASan
stack-overflow diagnostic or an exact crash-stack attribution for the normal
run. That planner allocates preorder site/owner identities and combines
postorder ownership facts. Its separate handoff preserves those identities,
child order and slot lifetimes through a typed continuation and the existing
finishing rules. Compiler-expert review agrees with that design direction.
It starts with a direct public-planner reproduction and mutation-sensitive
small plan oracles, then returns to the unchanged emitter regressions. The
preliminary estimate is +75–110 production lines, requiring a separate slice
and a fresh cost ceiling. No planner implementation change is included.

The host repair is a draft, not ready to land. Its independent static review
has zero findings, with approval conditional on the still-pending emitter,
focused backend, codegen, leak and broad sanitizer checks, matched costs and
applicable stage2/output-identity validation. Production growth is +98 lines
and tests grow by 359 lines. The broad sanitizer gate has not completed, and
no general stack-safety or performance claim is made for the host changes.
Unchanged producer/emitter sources alone do not establish that an older
compiler binary reproduces the original defect.

## Final independent pilot integration

The fresh host binary has SHA-256
`8d9c5a7b33b2fc4203f90d14b671cfead8ba63b5b3b4f645142015645683ad66`,
with CLI `-O0`, runtime `-O2`, Apple Clang 21 and the pinned bootstrap.
Independent serial execution passed 642 pilot unit callbacks, 19 native
String-runtime callbacks and 82 grammar callbacks: 743/743 combined.

The unchanged normal end-to-end wrapper passed 112/112 inner callbacks and
its 1/1 wrapper callback in 51.626 seconds. It built the pilot once, compiled
95 measured fixture inputs through their normal entrypoints, and passed all
allocation/instruction ceilings and its existing sanitizer checks. Stderr
was empty. All three independent packets, including the host type suite,
report stable sources; before/after source and host hashes match. These pilot
results do not substitute for the incomplete host compiler gates above.

The current pilot unit/runtime/grammar batch also passed 743/743 using the
preserved original repository host `ab0f9087...`, whose hash was checked
before and after execution. This deliberately uses the baseline compiler,
not a claim that it is fresh for the changed host sources. The recorder's
`bin_blorp_sha256` describes the installed candidate; its actual command
explicitly invokes `build/host-backend-stack/baseline-blorp`. A baseline-host
e2e rerun was not performed because the wrapper's Make target explicitly
uses installed `bin/blorp` for its pilot build. No adapter or executable
swapping was introduced.

## Evidence

Local ignored evidence has one navigator:
`blorp_2/build/audit-followups/README.md`. It links frozen sources and binaries,
recorder packets, independent reviews, raw measurements and gate results by
purpose. Builds and measurements are serialized on the shared machine.
Tests are Blorp TestSuite callbacks; the existing approved C String-runtime
unit tests remain the only native test-language exception.
