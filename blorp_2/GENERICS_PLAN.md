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
   This is a separate bounded increment after argument support is validated.

2. **Multiple type parameters.** First independent function parameters, then
   `fixed union Result[T, E]` with `Ok(T)` and `Err(E)`. Begin with Int payloads.
   Parameter identity gains its position within the declaring owner. Preserve
   order in substitutions and instance keys; duplicate declarations, incomplete
   inference, cross-owner parameters and swapped substitutions need exact tests.

3. **Nested types and unmanaged union payloads.** First admit written nested
   applications, then execute `box(box(7))` and extract the nested value. Publish
   concrete payload types and dependency-ordered inline layouts once. Retain
   complete nominal identities even when two instances share a layout shape.

4. **Managed union payloads.** Start with `Box[String]` and a borrowed payload
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

5. **Contextual inference.** Let known parameter and expected-result types guide
   constructors and constrain call substitutions. Check all constraints for
   consistency and diagnose remaining ambiguity without a default type. Keep
   rigid declaration checking separate. Explicit call type arguments require a
   separate surface-language decision and are not implied by this plan.

6. **Subsequent language features.** Add generic records alongside record support.
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

- [ ] Multiple runtime arguments, one type parameter.
- [ ] Typed checking errors and direct error-data/renderer tests.
- [ ] Multiple function type parameters.
- [ ] Multiple union type parameters.
- [ ] Written nested applications.
- [ ] Unmanaged union payloads.
- [ ] Managed String union payloads and exhaustive destruction.
- [ ] Contextual inference.

Record later record/recursion increments when their concrete example and scope
are established. Do not mark an item complete until its affected phase tests,
native checks and independent reviews pass.
