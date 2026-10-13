# Calculator arguments

Replace the calculator's stdin protocol with explicit `main(args: List[String])`.
The calculator's parsing and computation are pure; only its output boundary
prints and chooses a process status. Remove the pilot's `read_line` operation.

## Working example and scope

```text
calculator add 6 7
13
```

Follow the existing compiler's argument convention: index 0 is the executable
name, index 1 is the operation, and indexes 2 and 3 are operands. The addition
fixture takes its two operands at indexes 1 and 2. Missing arguments produce
`missing input`, invalid operands produce the existing numeric errors, and an
unknown operation produces `unknown operation`. Preserve left-to-right error
precedence. Extra arguments remain ignored. Empty, spaced, newline-containing
and Unicode arguments are individual values, without splitting or trimming.
OS arguments cannot contain embedded NUL; source-literal conversion regressions
continue to exercise counted NUL bytes separately.

All argument access, operation decoding, validation and arithmetic belong in
`pure func` helpers. They return an ordinary library `Result[Int, String]` or
`Result[Float, String]`. One small impure result consumer prints the result or
error and returns 0 or 1. This needs no new control-flow syntax or intrinsic.

The temporary prelude adds a real unary builtin declaration:

```blorp
type List[T] = builtin
```

This increment supports concrete `List[String]`, including passage through
ordinary generic helpers as `List[T]`. Other concrete elements receive an
explicit support diagnostic at checking, or at specialization when the element
becomes known. List literals, general element storage, append, mutation and COW
are later increments. Existing zero-argument main fixtures continue to work.

The first target-library operations are ordinary, explicitly imported functions:

```blorp
pure func length(values: List[String]) -> Int:
    builtin("list.length")
pure func get(values: List[String], index: Int) -> Option[String]:
    builtin("list.get", Some, None)
```

`get` returns None for negative or out-of-range indexes. A successful lookup
retains its String once and returns an owned Option; it has no hidden lifetime
dependency on the list.

## Facts, identity and ownership

Parsing establishes List's builtin constructor identity and unary arity.
The designated foundation module owns its declaration. Checking accepts that
builtin identity and publishes structural `ListType(element)` facts. Equality,
substitution and generic inference
recurse through the element. Later stages never recognize a List by spelling.

Signature acceptance constructs an `Entrypoint[FunctionIdentity]` variant:
`NoArguments(id, result)` or `WithArguments(id, result)`. Both require a nongeneric
root function returning Int or Void; `result` is the typed `IntegerExitStatus`
or `SuccessfulExit` convention. The second requires exactly one List[String]
parameter, whose binding name is arbitrary. Specialization translates only the function identity;
lowering and ownership carry the accepted case. Independent verification checks
the signature correspondence. Emission consumes it without deciding validity.

The C wrapper receives argc/argv, copies each argument into a counted-byte
String, and owns one immutable ARC list root containing those String owners.
The target main borrows the list. The wrapper releases its root after the call,
then returns the saved Int status or 0 for Void. Final root destruction releases every child once.
The runtime uses checked allocation sizes and atomic reference counts.
Ownership insertion and independent verification classify List ownership
separately from inline union fields. Existing acquisition/transfer rules handle
list aliases, helper returns and generic unions containing a list.

String-only storage is explicit in the current concrete contract. Do not add
arbitrary-element descriptors, a parallel execution path, a registry, a cache,
or entrypoint-specific fake types. The existing host compiler is precedent for
the public List/get interface and argv convention, rather than an implementation
template. [Rust's OS argument contract](https://doc.rust-lang.org/std/env/fn.args_os.html)
also distinguishes process arguments from Unicode validation, and
[Lean's ownership guidance](https://lean-lang.org/doc/reference/latest/Run-Time-Code/Reference-Counting/)
provides established owned/borrowed reference-counting boundaries.

## Tests and acceptance

Write failing Blorp TestSuite cases first. Cover builtin declaration/arity,
valid and invalid main signatures with exact errors, structural List inference,
substitution, specialization, lowering, borrowing, acquisition, transfer and
exhaustive destruction. Test malformed ownership IR independently, including
forged get result ownership, unsupported elements, wrong roles and mismatched
entrypoint cases. Each new source module has its own unit suite.

Extend NativeCase with explicit user arguments. The process API supplies argv[0];
tests must not synthesize it or split a command string. Keep build-once and
compile/link-once behavior, unchanged generated C, ordinary fixture main,
exact status/stdout/stderr and -O0 ASan/UBSan execution. Exercise empty/spaced/
Unicode arguments, ordering, missing/extra arguments, all calculator operations,
safe get bounds, aliasing and escaped String ownership. Retain numeric NUL
coverage using normal-main source fixtures. A 64-access case checks emitted
structural depth with default C limits.

The existing direct C component exception covers String runtime tests. Removing
the superseded read_line component cases is in scope; expanding that exception
to direct List tests requires separate explicit approval. Stage tests and
ordinary native fixtures are the current List verdict.

Run focused tests during development, then strict unit/runtime/grammar/tooling
and the full e2e gate. Inspect generated C for both entrypoint shapes and every
new ownership operation. Deliberately break successful get retention and
require the protected native case to fail, restoring exact source afterward.
Aim for at most 1,200 net production lines after read_line removal; report
production and test growth separately. The matched previous-input cost proxy
has +10% allocation and retired-instruction ceilings, with identical C for
unchanged nullary fixtures. This remains a proxy until self-hosting is possible.
Set new fixture ceilings from measured runs; do not weaken unrelated limits.

Compiler-expert implementation and separate compiler-expert/code review, plus
independent test-runner verification, are required before publication. Root
owns integration and documentation; workers coordinate serialized compiled
commands and do not commit or push.
