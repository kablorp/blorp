# Void, ordered statements and concrete print

Status: implemented and independently validated. The
[results report](../benchmarks/results/blorp_2_void_print_2026-10-12.md) retains
tests, mutation evidence, C inspection and matched costs.

Calculator step 4 starts with an ordinary executable:

```blorp
import:
    io: print
func main() -> Int:
    print("Hello, World!")
    0
```

Its stdout is exactly `Hello, World!\n`, stderr is empty and exit status is
zero. This follows the completed UTF-8 literal increment. The existing compiler
still builds the pilot. No input, conversion, Float, general effect system,
empty function bodies or additional control-flow form enters this increment.

## Semantics and precedent

`Void` is a real type with one value, `void`. It is unmanaged and distinct from
Int. The temporary input prelude declares `type Void = builtin` alongside Int
and String; its accepted identity owns the type role. The lexer reserves
`void`, and parsing publishes an explicit literal variant. Consumers never
recognize either role by spelling after parsing.

This uses the ordinary single-value unit model described by the
[Rust reference](https://doc.rust-lang.org/reference/types/tuple.html#type.tuple.unit),
without adding tuple syntax. Ordered statement evaluation follows the simple
sequence semantics described by the
[OCaml manual](https://ocaml.org/manual/5.3/expr.html#sss:expr-sequence).
The [Rust statement rules](https://doc.rust-lang.org/reference/statements.html#expression-statements)
also distinguish evaluated statements from a final block result. Blorp's
bounded rule here is stricter than Rust's semicolon discard: a non-final bare
expression must return Void. Other values must be bound or returned.

Bindings, reassignments and expression statements may interleave. One ordered
statement list replaces the existing binding/assignment prefix in each parsed,
checked and concrete function or arm. A final expression remains mandatory,
including for Void-returning functions. A missing return annotation means
Void. Each Void function evaluates and discards its final expression, of any
type, and returns canonical void; each selected match arm does the same.
Function tail matches remain terminal, and nested arm matches remain
outside scope. Blank lines and comments do not affect statement classification.

```blorp
import:
    io: print
func show() -> Void:
    var text = "first"
    print(text)
    text = "second"
    print(text)
func main() -> Int:
    show()
    0
```

This prints `first\nsecond\n`. `show` evaluates its final print and returns
Void. Pure functions cannot return Void, including concrete generic instances;
they may mutate their local variables but cannot call print or any impure
helper. Discarded final expressions still receive ordinary semantic checking.

## Facts, identity and lifetime

| Fact | Authority | Consumer contract |
| --- | --- | --- |
| Void type role | Checked prelude's builtin identity | Checker publishes VoidType; later types remain explicit. |
| Unit literal | Parser-owned literal variant | Checked/concrete Void leaf, then a function-local ValueId. |
| Statement order | One function/arm statement list | Checking and specialization preserve order; lowering appends ordered definitions. |
| Binding identity | Existing function-owned BindingId inventory | A discarded expression introduces no binding or synthetic name. |
| Print behavior | Closed StringPrint operation and runtime contract | Impure, one String parameter, Void result. |
| Print lifetime | Existing borrow and owner analyses | String argument stays live through the call; no ownership obligation for Void. |

Local builders publish complete immutable products as before. Lowering an
expression statement retains all its ordinary definitions and ignores only
the final value reference. An unused Void result cannot erase a call. All
visitors migrate, including reachable-call collection, specialization discovery,
self-tail-call checks and managed intermediate-value checks.

Void is accepted in helper parameters, returns, locals, generic instantiations
and generic union payloads. Existing record-field and direct union-payload
restrictions remain; Void does not implicitly widen those rules. Matching still
requires a union. Main takes no parameters or one List[String] parameter and
returns Int or Void. Int supplies its exit status; Void exits 0. Accepted
entrypoint facts carry both conventions explicitly through specialization and
ownership verification to C emission.

The existing restrictions on managed values before a function tail match and
inside annotated tail loops remain. Thus printing a literal before a tail match
is still rejected; printing inside the selected arm is supported. A Void-only
helper call before a match introduces no managed prefix.

## Target library and C boundary

Copy the selected io source into `standard_library_temp/io.brp`, retaining
upstream provenance and commenting unsupported declarations. Adapt print to
the concrete signature `func print(value: String) -> Void` with the exact raw
label `builtin("string.print")`. No traits, FFI, automatic import, host-library
fallback or name-based backend dispatch is added.

The accepted operation contract owns purity and types. Invalid purity, arity,
parameter/result types, generic builtin declarations, builtin prefixes and
tail annotations are rejected before lowering with diagnostic help. A bare
expression statement of another type reports that it must return Void and
suggests binding or returning the value.

C projects every Void value uniformly to `uint8_t`, with canonical zero. This
is an internal unit carrier, not another surface numeric type. It works in
parameters, locals, generic payloads and returns without C void special cases.
Emission and independent verification derive this from the typed operations.

```c
uint8_t blorp_string_print(const struct blorp_string *value) {
    (void)fwrite(value->bytes,1,(size_t)value->length,stdout);
    (void)fputc('\n',stdout);
    return (uint8_t)0;
}
```

This borrows the String, writes its explicit bytes including NUL and UTF-8, and
appends LF. It follows the existing runtime and io.print newline contract.
The [C11 draft, section 7.21.8.2](https://www.open-std.org/jtc1/sc22/wg14/www/docs/n1570.pdf)
defines fwrite's counted output. Print returns Void rather than exposing stream
errors, matching the existing API. A print fragment in the existing runtime
module is emitted only when the closed operation occurs, following Int addition
selection. Prior fixtures should therefore keep byte-identical generated C.

## Acceptance and evidence

Before production edits, retain failing Blorp TestSuite callbacks using existing
public compile/check boundaries and a failing native input. Add granular tests
at syntax, checking, specialization, lowering, ownership, verification and
emission boundaries. Include:

- Void literal/type identity, parameters, locals, generic identity and generic
  union payloads; no owner for any Void result.
- Source order for interleaved bindings, mutation, discarded calls, nested
  arguments and UFCS; selected-arm effects and explicit final expressions.
- Exact typed diagnostics, text, help and spans for non-Void discards, pure
  callers, invalid builtin contracts, missing final results and invalid main.
- Print borrowing and last-use drop after the call; aliases surviving the call;
  malformed ownership IR with a falsely managed or wrongly typed Void result.
- Preserved managed-prefix and annotated-tail-loop restrictions.
- Normal-main native output for Hello, empty, UTF-8, embedded NUL and repeated
  prints, under strict C11, ASan and UBSan. Native stdout is now an exact byte
  oracle for the full literal-to-runtime path. A deliberately omitted or reordered
  print must make the relevant test fail.
- A moderate sequence compiled with default C structural limits, inspecting
  emitted order and flat depth. No output formatting target is introduced.

Reuse the existing Blorp e2e harness with explicit expected stdout; old helpers
retain their empty-output contract. Build the pilot once per e2e run and compile
each fixture once at -O0. No alternate main, rewritten C, C assertion driver,
compiler cache or new test execution path is added.

Focused loop: affected Blorp unit/grammar suites with `--suite --timeout 180`.
Final gates: all pilot unit/runtime/grammar/tooling suites with sanitizers and
strict leak checking, then `bin/blorp test --suite --timeout 0 blorp_2/test/e2e`.
Use scripts/record-validation; serialize compiled commands. Independent
compiler-expert and test-runner reviews are required.

Baseline source, tests, library, compiler binary and generated compiler C are
frozen under `build/effects/baseline/`. The source archive is byte-identical to
the approved String increment's archive (SHA256
`9d68da14f0ea46c755e4c098c568f4cba16e99fba4df6194a6d2ba408c8d85a0`).
Three paired samples over frozen prior executable roots compare allocations and
retired instructions through C emission, each with a +10% aggregate ceiling.
Both compile the same frozen program/library sources, but use their respective
preludes: the new mandatory Void declaration is an explicit input difference.
This is an owned-input proxy, not self-compilation. Require generated C identity
for prior fixtures, balanced releases and no leaks. Set new fixture ceilings
from retained costs with headroom. Aim for at most 700 net added production
lines for the complete increment; report production/test changes separately.

Record exact inputs, toolchain, binaries, samples, output identity, mutation
evidence and limitations in one retained results report. Stop and report if a
new mechanism, broader ownership policy or host-compiler workaround is needed.
The previously measured concat growth remains a separate follow-up.
