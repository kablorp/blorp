# Incremental generic support

This is the ordered implementation plan agreed after the first generic-function
and generic-union increment. The supported language is still defined by
[README.md](README.md) and [grammar.ebnf](grammar.ebnf); this plan does not claim
that its unchecked steps work. Both [AGENTS.md](AGENTS.md) and the parent
[AGENTS.md](../AGENTS.md) apply.

## Invariants

Check every generic body once with rigid declaration-owned parameters, including
unused bodies. A call records its checked substitution. Specialization translates
complete signatures, bindings, calls, constructors and patterns to concrete
identities before lowering. Later stages do not repeat inference or name
resolution. A function or union instance is identified by its declaration and
complete ordered concrete type arguments, never by spelling or physical layout.

Keep the existing pure pipeline, local builders and sealed immutable products.
Replace the old representation in the same slice; do not maintain a unary path
beside a general argument path. Add no persistent cache, registry or new pipeline
layer. Target ownership is independent of whether a declaration was generic.

Use bidirectional checking: synthesize expression types and check expressions
against known expected types. Declaration-owned type parameters are rigid;
inference variables introduced for calls are local and solvable. Current
argument inference uses one-way structural matching. Introduce structural
unification, including an occurs check, when contextual inference needs it;
publish complete substitutions with no unresolved inference variables. Purity,
name resolution and exhaustiveness remain separate checks. Implicit let
polymorphism is outside the current scope.

The checking/synthesis distinction follows Dunfield and Krishnaswami's
[Bidirectional Typing](https://arxiv.org/abs/1908.05839). The
[Rust compiler's inference guide](https://rustc-dev-guide.rust-lang.org/type-inference.html)
provides implementation precedent for local inference variables and constraints
that retain their origin. These inform the design; each mechanism enters only
when the next supported example requires it.

For specialization identity, the Rust compiler's
[Instance](https://doc.rust-lang.org/nightly/nightly-rustc/rustc_middle/ty/struct.Instance.html)
couples a definition with its generic arguments. Adopt that complete-key idea
while retaining this pilot's immutable `SpecializedProgram`; Rust's on-the-fly
MIR substitution does not dictate this pipeline's boundaries.

The publication boundary remains `Result[CheckedProgram, CheckFailure]`.
Temporary inference variables, tentative substitutions and mutable builders stay
private. A checked generic body may contain its declaration-owned rigid
parameters, and a checked call may substitute a caller's rigid parameter.
Specialization is responsible for producing concrete types. Errors retain stable
semantic facts and spans, without references to live inference state.

## Ordered examples

1. **Multiple runtime arguments; one type parameter.**

   ```blorp
   pure func keep_first[T](first: T, second: T) -> T:
       first
   func main() -> Int:
       keep_first(7, 9)
   ```

   Expected exit: 7. Infer a consistent substitution from all argument positions;
   reject conflicting types at the argument that conflicts. Support direct and
   UFCS calls with explicit arguments. Lower receiver and arguments left to right,
   exactly once, before invoking C. Test both parameter return positions and
   managed values surviving caller replacement. Constructors remain zero/one
   payload, and main remains zero arguments.

   **Before the next generic increment: typed checking errors.** The user added
   this requirement while argument support was in progress. Checker tests call
   the checker directly inside TestSuite; no subprocess per input is needed.
   Publish structured checking failures carrying their semantic variant, relevant
   identities, expected/actual types, argument position and source location as
   applicable. Render diagnostic text separately. Test error data directly and
   keep dedicated exact message/help/span tests for rendering. Do not classify
   errors by message strings or maintain text as a second semantic authority.
   The bounded implementation returns a complete checked program or an opaque
   failure with a nonempty typed error collection and the original sealed parsed
   authority. Checking currently stops at the first error; collecting independent
   failures requires a later explicit recovery policy. The renderer and CLI
   preserve the full collection. No temporary inference or builder state escapes.
   Bidirectional checking and structural unification remain a separate follow-up
   before extending generic inference.

2. **Explicit checking and synthesis.** Preserve current accepted programs and
   diagnostics while making the two expression operations explicit. A function
   return, known argument or match arm checks against its receiving type; a
   binding initializer or match scrutinee synthesizes where no receiving type is
   available. Share the recursive implementation, preserve constructor-directed
   context and resolve each call contract once. Argument checking retains its
   current delayed obligation boundary and error priority. This is bounded
   preparation, not expected-result inference for generic calls. Protect the
   behavior with direct typed-fact/error tests and demonstrate their failure
   under a relevant mutation before changing production code.

3. **Multiple function type parameters.** Use independent ordered parameters:

   ```blorp
   pure func second[A, B](first: A, second: B) -> B:
       second
   func main() -> Int:
       second(7, 42.to_string()).length()
   ```

   Expected exit: 2. Replace zero/one type-parameter and call-substitution
   carriers with ordered collections; keep one-way argument inference for this
   slice. Check each generic declaration once, including unused bodies.
   Parameter identity gains its position within the declaring owner. Preserve
   order in substitutions and instance keys; duplicate declarations, incomplete
   inference, cross-owner parameters and swapped substitutions need exact tests.
   Substitution is simultaneous: replacing a callee parameter preserves the
   supplied caller-owned type without applying callee substitutions inside it.
   Preserve the existing constructor-context distinction: explicit arguments
   use their individual concrete annotations, while a generic UFCS receiver
   receives no constructor hint. Contextual inference changes remain separate.

4. **Multiple union type parameters.** Add `fixed union Result[T, E]` with
   `Ok(T)` and `Err(E)`. Begin native examples with Int payloads. Check written
   application arity, declaration-owned parameter positions, constructor/pattern
   substitution and complete nominal instance keys separately from function
   inference. A single union argument may constrain multiple function parameters;
   visit its type arguments in declaration order and preserve the first inference
   occurrence. At the first conflict, the diagnostic expectation uses established
   candidates and retains not-yet-inferred declaration-owned rigid parameters.
   This error snapshot is separate from strict complete successful substitution;
   it does not infer later constraints or publish a tentative builder.
   Written arguments remain atomic, and each variant still has zero or one field.
   Retain the managed-payload restriction until its own increment.

5. **Nested types and unmanaged union payloads.** First admit written nested
   applications, then execute `box(box(7))` and extract the nested value. Publish
   concrete payload types and dependency-ordered inline layouts once. Retain
   complete nominal identities even when two instances share a layout shape.

6. **Managed union payloads.** Start with `Box[String]` and a borrowed payload
   returned owned. Then replace an enclosing binding while a saved result stays
   live. State root storage, owned-child destruction, projection dependencies,
   acquisition and return transfer explicitly. Check only active variant children
   during destruction. Use [MEMORY_PLAN.md](MEMORY_PLAN.md) for granular tests;
   sanitizer silence or balanced totals alone do not establish correctness.
   Payload extraction uses a tail match: admit a borrowed managed parameter as
   its scrutinee, preserve the projection's dependency on that parameter, and
   acquire/transfer returned children independently in each selected arm. Extend
   independent verification with the same admitted shapes. Owned managed prefix
   values still require separate edge-cleanup support; do not remove that guard
   or imply that general non-tail joins are necessary for this example.
   The current fixed-union synonym permits managed payloads; the parent guide's
   planned checked-fixed restriction remains a separate future language decision.
   Recursive aggregates and COW remain separate work.

7. **Contextual inference.** Let known parameter and expected-result types guide
   constructors and constrain call substitutions. Check all constraints for
   consistency and diagnose remaining ambiguity without a default type. Keep
   rigid declaration checking separate. Explicit call type arguments require a
   separate surface-language decision and are not implied by this plan.
   Start with a declared `Choice[Int]` return constraining a call to
   `empty[T]() -> Choice[T]`, then cover nested calls and conflicting argument
   and result constraints. Introduce private fresh call variables and structural
   unification here. Test rigid parameters, variable independence, substitution
   chains, nominal mismatch, occurs checks and unresolved ambiguity directly.

8. **Subsequent language features.** Add generic records alongside record support.
   Establish ordinary recursion before recursion through generic instances that
   reuse a finite set of concrete keys. A recursion policy must distinguish that
   case from continually creating different instances; do not hide it behind an
   arbitrary specialization limit. These are separate executable increments,
   not speculative infrastructure for the preceding steps. Traits/bounds,
   higher-kinded types and polymorphic function values remain deferred.

## Validation and costs

Each example starts with a failing regression. Keep grammar conformance, rigid
checking, inference and specialization tests separate. Later phase tests supply
small typed inputs directly, including malformed ownership IR for independent
verification. Test complete nominal keys, parameter position and ownership
provenance, not only successful native results. Deliberately break a protected
operation or translation and require its own regression to fail.

Run narrow tests during implementation, then strict ASan/UBSan/leak unit checks
and the full pilot suite. Build the pilot once per end-to-end run. Fixtures run
their actual main through unmodified emitted C; development builds use -O0.
Review emitted C for evaluation order, layout and cleanup. Keep evidence under
ignored `build/generic-expansion/` and retain a concise results document for
completed increments. Every increment receives code and test-runner review.

Compiler-expert review examines the design before implementation and the full
producer-to-consumer change afterward, including the adequacy of test oracles.
Keep dependent increments sequential and validate each before building on it.
The first checking/synthesis slice starts from `a121b61b7`; its immediate
baseline must produce identical C for all 68 existing native fixtures. Target
flat or reduced production line count; investigate growth above 80 production
lines or repeatable per-workload allocation/instruction increases above 2%.
These are investigation thresholds, not an efficiency budget. Retain matched
immediate-baseline evidence alongside the cumulative baseline below, and set
similarly explicit costs before each following implementation.

The function-parameter increment uses the accepted checking/synthesis source
as its immediate baseline. Freeze that source and toolchain before changing
the cardinality. Investigate net production growth above 300 formatted lines
or repeatable per-existing-workload allocation/instruction increases above 10%
against this immediate baseline; the cumulative 25% threshold below still
applies. Target flat or reduced production size through removal of unary
carriers. Keep the same six comparison workloads and require identical C for
all 68 preexisting valid fixtures. These investigation stops do not authorize
raising fixture caps or adding special cases to hide a host-compiler cost.

The union-parameter increment starts from `276250fb8`, with the same toolchain
and six comparison workloads. Freeze that immediate baseline before changing
applied-type cardinality, and require identical C for all 73 preexisting valid
fixtures. Investigate net formatted production growth above 300 lines or
repeatable per-workload allocation/instruction increases above 10% against
this immediate baseline; the original cumulative 25% threshold still applies.
These stops do not authorize raising fixture caps. Retain complete ordered
arguments while removing the unary representation in the same slice.

Freeze the accepted starting revision `da8fa4c71`, toolchain and unchanged
workloads for baseline/candidate comparison. Change fixture ceilings only with
retained measurements and an explicit explanation. The argument increment raises
only the tight `union_values` allocation limit from 3,600 to 4,000 after measuring
3,574 baseline versus 3,641 candidate allocations (+1.87%); its instruction limit
is unchanged. Investigate repeatable cumulative allocations or retired instructions
above 25% against this baseline before proceeding; a threshold is not permission
to consume that budget needlessly. Report production and test line counts
separately. The pilot cannot self-compile yet, so owned-input measurements are
proxies, not self-compilation results. Do not advance the baseline between steps.

## Progress

- [x] Multiple runtime arguments, one type parameter.
- [x] Typed checking errors and direct error-data/renderer tests (independent code and test reviews approved).
- [x] Explicit checking/synthesis boundary with preserved behavior (independent compiler and test reviews approved).
- [x] Multiple function type parameters (independent compiler and test reviews approved).
- [x] Multiple union type parameters (independent compiler and test reviews approved).
- [ ] Written nested applications.
- [ ] Unmanaged union payloads.
- [ ] Managed String union payloads and exhaustive destruction.
- [ ] Contextual inference.

Record later record/recursion increments when their concrete example and scope
are established. Do not mark an item complete until its affected phase tests,
native checks and independent reviews pass.
