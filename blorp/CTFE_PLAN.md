# Compile-time evaluation plan

**Status: approved 2026-11-24.** Keith answered six points of the design
memo on 2026-11-23, and on 2026-11-24 accepted every recommendation for K2 to
K6, K8, K9 and T1 to T6 (see [Decisions](#decisions)). A soundness review and
an ergonomics review both approved it with fixes, which are folded in here.
Nothing is implemented. L1 is next.

**The direction:**

- **Values (L1 to L4).** Constants become computed values. The compiler
  evaluates each one once, in-process, and emits the result as static C data.
  Primitive operations are delegated to the compiler's own compiled runtime.
- **Sizes in types (T-landings, after L4).** Principle 14 is met by a closed
  size language in `check`. Sizes are passed as hidden arguments, never
  specialized. This half is a direction, and T6 moves it to a plan of its
  own before T1.
- **The language assumed.** The design targets the language after
  [`PRIVATE_VARIANTS_PLAN.md`](PRIVATE_VARIANTS_PLAN.md): there is no
  `into_opaque` and no opaque type. Any new identity type here is a union
  with a private variant, so L2 and L3 come after that plan's seed rotation
  (see [Where the plans meet](#where-the-plans-meet)).

**Evidence.**

- **Cited code.** Every `file:line` was checked against `origin/main` at
  `f9423ade5`. Paths are under `blorp/` unless they start with `../`.
- **Measurements.** The scripts, raw data and self C are in the ignored
  `../build/ctfe-k2-2026-11-23/`, with paths relative to that directory (see
  [Measurements](#measurements)).
- **The retired evaluator.** The old CTFE, `e1cae3971^:blorp/src/compiler/stage_07_ctfe/`,
  was 9,308 lines. A post-mortem of it, a scratch document outside the
  repository, informed this plan.

## Problem

A module constant must be closed. Calls, operators, other constants, lambdas
and control expressions are rejected (`README.md:288-294`), and each read
rebuilds the value. Two reproductions, compiled with `blorp compile` at
`f9423ade5`:

```blorp
KINDS: List[Kind] = [Alpha, Beta]
NAMES: List[String] = KINDS.map(kind_name)                     -- legend.brp:8

KEYWORDS: Dict[String, Keyword] = { "if" => If, "else" => Else }   -- keywords.brp:6
```

```text
legend.brp:8:23: error: constant initializer is not a closed value
help: use literals, constructor data, or named function references; calls, operators, constant references and lambdas are not allowed
keywords.brp:6:35: error: constant initializer is not a closed value
help: use literals, constructor data, or named function references; calls, operators, constant references and lambdas are not allowed
```

Both should compile, and each read should cost nothing.

| # | Requirement | Who waits | Priority |
| --- | --- | --- | --- |
| R1 | Computed constants: calls, operators, other constants, interpolation, and private-variant constructors applied to computed values | `token_legend` (`src/lsp/tokens.brp:205`), `builtin_label_help` (`src/common/syntax/parse.brp:4575`), `program_names` (`src/common/syntax/names.brp:116`), `begin_program` (`src/common/analysis/assemble.brp:137`), `string_append_int_runtime` (`src/common/codegen/runtime/string_concat.brp:77`), Bytes signatures (`NEXT.md:257`) | First |
| R2 | No construction at each read: static C data | Every aggregate constant. A read copies the checked template (`src/common/analysis/check/expressions.brp:4585`). | With R1: without it, a computed constant would rerun its initializer at every read |
| R3 | Dict constants | `token_legend` (`Json.Object` holds a Dict), keyword tables | Comes free with R1: a Dict literal is `dict(n)` followed by `set` calls (`expressions.brp:1242-1264`), and hashing is pure Blorp (`standard_library/string.brp:93`, `dict.brp:122`) |
| R4 | Sizes in types (principle 14) | Fixed-size vectors and proven indices | After L4 ([Sizes in types](#design-sizes-in-types)) |

## Decisions

### Keith, 2026-11-23

1. **Actual CTFE.** Initializing each constant at its first read at run time
   (the memo's C2) is rejected: "This feels wonky. I'd prefer actual CTFE."
2. **Primitives are delegated, Lean's way.** "Lean approach seems ok."
   - The evaluator calls the compiler's own compiled runtime for each
     `RuntimeOperation`, as Lean 4's IR interpreter calls natively compiled
     code.
   - This settles K7. The compiler binary runs the seed's runtime text, so a
     change to a pure primitive reaches CTFE one seed rotation late.
   - Such a change therefore takes two rotations, by the procedure in
     [Changing a primitive](#changing-a-primitive).
3. **The LSP gap is accepted.** "We can accept the gap and document the
   requirements for the change later if desired. Just erring toward
   simplicity." [The LSP](#the-lsp-what-showing-these-errors-would-need)
   records what a later change would need, and the README says so in one
   sentence.
4. **Type-level values: "Let's plan".** See
   [Sizes in types](#design-sizes-in-types).
5. **Static data before the evaluator (K2): "Not sure."**
   [Measurements](#measurements) gives a measured basis, and K2 asked again;
   Keith accepted it on 2026-11-24.
6. **No `into_opaque`.** "Keep in mind into_opaque is going to be removed.
   Instead we'll have the ability to define union variants as private, which
   can serve the same purpose with less complexity."
   - Nothing here uses `into_opaque` or the opaque machinery that
     `PRIVATE_VARIANTS_PLAN.md` deletes.
   - The sketches' identity types (`ConstantInstanceId`, `ConstantTable`) are
     written as unions with a private variant.

Approving this plan approves the new `evaluate` phase, a new pipeline layer
(`AGENTS.md:79`).

### Keith, 2026-11-24

7. **"Accept all."** Every recommendation below and in
   [Decisions for sizes](#decisions-for-sizes) is decided as written: K2 to
   K6, K8, K9 and T1 to T6. This approves the plan and the new `evaluate`
   phase. The alternatives stay listed as the record of what was weighed.

### Settled on 2026-11-24, as recommended

- **K2. Static data first: L1 and L2 before the evaluator.**
  - Recommended: yes, with static objects that start at the literal base
    count.
  - The evidence: L1 removes 1,520 of a self-compile's allocations, and
    0.20% to 0.47% of its instructions across three measurement sets. L2
    removes 8,192 of the decoder witness's 8,193 allocations and 29.6% of its
    `-O2` instructions.
  - The memo's zero-count marker costs +4.87% and is rejected.
- **K3. Cycle rule.**
  - Recommended: Go's static rule, built in `specialize`. A constant depends
    on every constant that an instance its initializer reaches, by call or by
    function value, can read. It is stricter than run time, and the error
    says so.
  - The alternative: exact detection during evaluation.
- **K4. Budgets.**
  - Recommended: three fixed language limits, documented in the README, the
    same on every host, and with no command-line flag. L3 sets their values by
    measurement, so that ordinary tables pass: `sieve(1_000_000)` and a table
    of a million elements must evaluate in about a second.
  - `elements` counts the logical length of the Lists and Strings that
    results hold, never the copies made along the way.
  - Depth is a pure language limit, because frames live on an explicit heap
    stack; 10,000 nested calls is the starting point.
  - The alternative: a flag. It makes a second compiler language, which the
    ergonomics review also rejects.
- **K5. NaN's sign.** Recommended: make it unobservable. `copysign` treats a
  NaN sign argument as positive, so emitted C does not depend on the host.
- **K6. Which constants are evaluated.** Recommended: every user-module
  constant, so that an error does not depend on reachability, as `check`
  does for bodies; library constants only when reached.
- **K8. Lambdas in constants.**
  - Recommended (a): a lambda that captures nothing is a function constant,
    and a constant whose value holds a capturing closure is rejected.
  - (b) Reject every closure.
  - (c) Emit static closures.
- **K9. Where evaluation runs.**
  - Recommended (a): after `verify`, interpreting the verified ownership IR.
    Every owner discharge, whether a drop, a consumed argument, a stored
    payload or a moved result, clears its frame slot and the borrowed slots
    derived from it, so updates reuse storage exactly as native code does.
  - (b) After `lower`, with the evaluator computing last uses itself. That
    recomputes a fact `own` already established (`AGENTS.md` principle 1).
- **T1 to T6:** see [Decisions for sizes](#decisions-for-sizes).

## Background

**What the old evaluator taught.** The post-mortem counted about 2,000
inherent lines: the evaluator, a value shape, ordering with cycle rejection,
and static output. Most of the rest came from four choices, and it shipped
with two gaps. Its estimates overlap.

| Old choice | About | This plan |
| --- | --- | --- |
| Evaluating typed ASTs inside type inference, through a second IR, a matcher and checking modes | 2,350 lines | Evaluate lowered code after `check` |
| Reimplemented intrinsics and library functions | 2,600 lines | Delegate the closed `RuntimeOperation`, and run library code as lowered Blorp |
| Per-module mutable environments with pending markers | 1,960 lines | One dense table, filled in dependency order |
| Materializing values back into source ASTs | 790 lines | One value shape, emitted directly |
| No budgets, and no native-versus-evaluator test | — | Both are in L3 |

**Today's pipeline.** It runs `check`, `specialize`, `lower`, `own`,
`verify` and `emit` (`src/common/codegen/generate_c.brp:18`).

- **Constants die in `check`.** A `CheckedConstant` is a construction
  template (`src/common/analysis/check/model.brp:1205-1210`), copied at each
  read (`expressions.brp:4585`). Initializers are checked in a closed mode
  (`ExpressionSite`, `expressions.brp:395`), with ten
  `NonClosedInitializer` rejections.
- **Specialization has one root.** It expands from `main` alone
  (`src/common/codegen/specialize/specialize.brp:5938`).
- **Static-ish storage exists twice.**
  - A string literal's site builds its String on first use, published once
    under a lock, with a count that starts at `BLORP_STRING_LITERAL_REFERENCES`,
    the count's top bit. A normal build never writes that count again: retain
    and release skip a String at or above the base. This is the literal section
    of `src/common/codegen/runtime/string.brp`, after the concurrency plan's
    landings 1 and 1b.
  - `[]` is one `const` root per layout, recognised by its address
    (`src/common/codegen/runtime/list.brp:287-296,358,372-374`).

## Design: values

### Where evaluation runs (K9)

A new phase, `evaluate`, has its home at
`src/common/codegen/evaluate/evaluate.brp`. It interprets the lowered form
of each initializer:

- `LoweredFunction` steps (`src/common/codegen/lower/lower.brp:178-182,304`);
- `ValueOperation`s (`lower.brp:141`);
- selection graphs (`lower.brp:252-277`);
- calls through `CallTarget` (`specialize.brp:245`).

Under K9 (a) these arrive as the verified program's ownership operations
(`src/common/codegen/own/own.brp:143`).

**Not the specialized form.** It still has `ReassignBinding` and source
`break` and `continue` (`specialize.brp:343`), which would need a mutable,
name-scoped environment, the shape of the old evaluator.

**Updates must reuse storage as native code does.** The runtime updates in
place only at count 1 (`list.brp:480`, `string_concat.brp:48`). A frame that
kept every value alive would make `map` over n elements copy about n²/2 of
them. Under K9 (a), every discharge of an owner clears its frame slot.

- **Which discharges.**
  - `DropOwner` and `ConsumedArgument`;
  - an `OwnedPayload` moved into a constructed value;
  - an `OwnedReturn` at a join's yield or a loop's carry.
- **Borrowed slots.** Discharging a root owner also clears every borrowed
  slot derived from it. A projection's slot holds a host reference, and
  `verify` proves it dead by then.
- **Operands.** An operand moves into the host operation with no alias left
  in the operand list or its `ConstantValue` wrapper.

So `{ contents | values = contents.values.set(position, value) }`
(`standard_library/dict.brp:243-255`) reaches the host's `set` at count 1, as
in native code.

L3's memory test builds a Dict of 2,000 entries and maps 10,000 elements,
then repeats at double the size. The soundness review measured native code
at 4,055 and 8,060 allocations for the two sizes.

**An explicit frame stack.** Frames are records on a heap `List`, and
`evaluate` loops; it never recurses on the host stack. So depth is a
language limit, the same at `-O0` and under ASan.

**The emitted set.** `specialize` marks only initializer bodies as
`InitializerInstance(ConstantInstanceId)`, one per constant. Every other
instance is a `RuntimeInstance` and is emitted. That includes a helper
reached only by initializers, which may then be dead C.

The rule needs no fact that only evaluation knows. A function that a
constant's value holds is therefore always emitted. Pruning the dead helpers
after `evaluate` is a later change, if their C size is measured to matter.

### Constants gain identity

```blorp
-- L2. specialize.brp: constants are monomorphic, so each reached constant
-- has one instance, numbered densely like functions.
union ConstantInstanceId:
    private Init(Int)

-- check/model.brp:  CheckedForm (model.brp:975) gains   ReadConstant(ConstantId)
-- lower.brp:        ValueOperation gains               ReadConstantValue(ConstantInstanceId)

-- L3. check/model.brp (BodyOwner at model.brp:843): an initializer is a body
-- owned by its constant, so its bindings, lambdas and name uses scope to it.
fixed union BodyOwner:
    DeclaredBody(FunctionId)
    LambdaBody(LambdaId)
    DerivedEqualityBody(AggregateId)
    DerivedTupleEquality(Int)
    InitializerBody(ConstantId)

-- L3. specialize.brp
record ConcreteConstant {
    constant: ConstantId,                       -- for labels and spans only
    value_type: TypeRef,
    initializer: FunctionInstanceId             -- an InitializerInstance
}
```

**Checking.** L3 checks an initializer as a pure body with no parameters,
whose result is the annotation. It deletes the closed mode.

**Roots.** Every user-module constant becomes a root of specialization
(K6), and so does a library constant when a reached body reads it.

**Private variants.** Inside its module, a constant builds a private
variant as any body there may. A Dict constant is built by `dict.brp`'s own
functions through `Dict.Init(...)`.

### Value model and publication

```blorp
-- A value carries no type: the constant's TypeRef and specialize's layouts
-- give it. An erased union (private-variants rule 8) is its payload's value,
-- so a Dict is a RecordConstant of its DictContents.
union ConstantValue:
    VoidConstant
    Int64Constant(Int)
    UInt8Constant(UInt8)
    FloatConstant(Float)
    StringConstant(String)
    RecordConstant(List[ConstantValue])                     -- fields in layout order
    VariantConstant(VariantInstanceId, List[ConstantValue])
    ListConstant(List[ConstantValue])
    FunctionConstant(FunctionInstanceId)                    -- includes lambdas that capture nothing (K8)
    ClosureConstant(FunctionInstanceId, ConstantValue)      -- while evaluating only

-- Built only by `publish`, which applies K8's rejection and nothing else.
-- Emit's walk follows each value's TypeRef and reports a shape it cannot
-- follow as an internal error, as it does for a missing layout today. Both
-- walks use an explicit stack: a recursive union chain is bounded only by
-- the step budget.
union ConstantTable:
    private Init(List[ConstantValue])                       -- dense by ConstantInstanceId
```

**`UInt8` in compiler source.** The `UInt8` arms use `UInt8` in compiler
source, as `src/lsp/positions.brp:32` already does. The bootstrap-subset
sentence in `AGENTS.md:10-12` predates `UInt8` and is reported as stale.

### Primitives: delegated

The compiler is compiled Blorp, so its `left + right` on Ints already is
`blorp_int_add`. Each arm calls the host operation of the same label.

- **The match.** It is over the closed `RuntimeOperation`
  (`src/common/analysis/namespace/builtins.brp:170-219`). That has 43
  variants, 40 of them pure by `runtime_contract` (`builtins.brp:256`), and
  the match has no default arm.
- **Its size.** About 200 lines of unpacking, and they state no semantics.

```blorp
private pure func apply_operation(
    operation: RuntimeOperation[VariantInstanceId, TypeRef],
    operands: List[ConstantValue]
) -> Result[ConstantValue, EvaluationFault]:
    match operation:
        IntegerAdd(Int64Format):
            operands.int64_pair().map(pure func(pair): Int64Constant(pair[0] + pair[1]))
        FloatToString:
            operands.float_operand().map(pure func(value): StringConstant(value.to_string()))
        -- Checking proved every initializer pure, so reaching one is a compiler fault.
        StringPrint | StringPrintError | SystemCall(_, _):
            Err(ImpureOperationReached)
        -- ... one arm for each remaining variant
```

#### Changing a primitive

The seed's runtime is what CTFE runs. So a primitive never changes meaning
while a gate compares the seed's runtime with the current runtime text: the
L3 oracle, and the fixpoint's fixtures rung (`../scripts/blorp-fixpoint:8-9`).

1. **Add, do not edit.** A new operation, or new semantics for an old one,
   lands as a new `RuntimeOperation` variant beside the old. Its arm returns
   the named fault `OperationNotHostedYet`. That fault renders as "`label` is
   not yet available while compiling a constant", and it has a test.
2. **Rotate** the seed. It now hosts the variant.
3. **Delegate.** The arm calls the host operation, callers switch to the new
   variant, and its oracle fixture is added.
4. **Delete** the old variant and its arm.

At every step, each constant that a gate evaluates uses an operation whose
semantics are the same in the seed and in the current text.

### Static storage and its read forms

**The storage.** Each static String, List, counted record and boxed union is
a writable static object whose count starts at the literal base:

- `BLORP_STRING_LITERAL_REFERENCES` for `size_t` counts;
- `UINT64_MAX/2` for records' `uint64_t` counts.

**Why it is safe.** Retain, release and the uniqueness test need no new
code. The object is never freed, and every update copies it. The soundness
review traced each runtime path:

- release to the base, and uniqueness;
- copy on update;
- deep release;
- the allocator headers;
- threads, and overflow.

**The 32-bit case.** `list.brp:287-296` weighs three costs of a large count:
shared writes, writable storage, and a weaker argument where `size_t` is 32
bits. The first two are accepted here because the alternative measured
+4.87%. The third still holds: each count unit is a stored pointer, and
fewer than 2^30 fit in a 32-bit address space.

**Links between static objects.** A link from a static object to a static
child is not counted. So the strict leak check can require every static
object to be back at its base at exit, using a static table of them.

**The C form.** Bytes and elements are written as initializer lists, as
literal sites are today (`src/common/codegen/emit/emit.brp:342-345,359`),
never as C string tokens. The union of a sized image with the managed struct
avoids the GNU extension for initializing a flexible array member. It
compiles with no diagnostic under:

- `-std=c11 -pedantic` with Apple clang 21;
- `-O2 -fstrict-aliasing` with GCC 13.3, which the soundness review ran.

The decoder prototype runs clean under `-fsanitize=address,undefined`.

The read form follows the layout (`specialize.brp:110-134,218-236`):

| Layout | Static form | A read |
| --- | --- | --- |
| Scalars, `Void`, payload-free enums | none | the literal |
| `InlineFields` records, `PlainCases` unions | a `static const` C value | a copy of it |
| `ValueFields` records, `OwningCases` unions | a static C value whose counted children are static objects | a copy, borrowed |
| `CountedFields` records, `BoxedCases` unions, Lists, Strings | a static object at the base count | its address, borrowed |
| An empty List | the layout's `[]` root | as `[]` today |
| A function constant | none | `{&entry,(void*)0}`, as `emit.brp:1200-1213` writes a free callable |

```c
/* constant probe.KEYWORDS: "if" hashes to slot 0 of 7 and "else" to slot 3,
   by dict.brp's home_slot. blorp_r_0 is DictContents[String, Keyword]. */
static union {struct {atomic_size_t references;int64_t length;int64_t code_points;size_t capacity;char bytes[3];} image;struct blorp_string value;}
 blorp_k_0_0={.image={BLORP_STRING_LITERAL_REFERENCES,2,2,2,{105,102,0}}};
/* blorp_k_0_1 "else"; blorp_k_0_2 keys; blorp_k_0_3 values; blorp_k_0_4 live, likewise */
static union {struct {atomic_size_t references;int64_t length;size_t capacity;int64_t values[7];} image;struct blorp_l_0_i value;}
 blorp_k_0_5={.image={BLORP_STRING_LITERAL_REFERENCES,7,7,{INT64_C(0),INT64_C(-1),INT64_C(-1),INT64_C(1),INT64_C(-1),INT64_C(-1),INT64_C(-1)}}};
static struct blorp_r_0 blorp_k_0={UINT64_MAX/2,&blorp_k_0_2.value,&blorp_k_0_3.value,&blorp_k_0_4.value,&blorp_k_0_5.value,INT64_C(0)};
/* A read borrows: no call, no allocation, no count change. */
const blorp_r_0 blorp_vl_3=&blorp_k_0;
```

### Ownership: `StaticBorrow`, paired

**What `own` produces.** A read of a managed constant gets
`BorrowedResult(StaticBorrow)`, a fourth case of `BorrowSource`
(`own.brp:80`). A borrowing use costs no count operation, and an owning use
acquires, as for any borrow.

**What `verify` accepts.** It pairs `StaticBorrow` as it pairs the other
sources (`src/common/codegen/verify/verify.brp:386-403,1845-1855`):

- it accepts `BorrowedResult(StaticBorrow)` only on a constant-read
  definition;
- it accepts a `StaticBorrow` use only of a value whose known result is
  that.

Malformed-IR tests cover a call result that claims `StaticBorrow`, and an
owned value used as one.

**Literals.** In L1 and L2, string literals keep `OwnedResult`.

### Dependency order (K3)

**Built in `specialize`, on purpose.** The checker cannot be exact. Its
reach sends a trait call on a type parameter to every implementation
(`src/common/analysis/check/bodies.brp:2195-2222`). For example, a
`Dict[String, Int]` constant would depend on every user `Hashable`
implementation. Only instances are exact, so this is a check that
monomorphization forces (`../AGENTS.md:233`).

**One mechanism for every evaluated cycle.**

- **In `specialize`.** A direct cycle among evaluated constants, such as
  `A: Int = B + 1`, `B: Int = A + 1`, also goes to this pass, so that one
  rule covers every cycle `evaluate` could meet. This is the first user
  diagnostic `specialize` reports.
- **In `check` (T1).** Constants used as sizes are computed there (size rule
  3). So `check` detects cycles among them while computing, and reports them
  with the same message shape. Their dependencies are names only, so
  detection is exact.

**The message.** It points at the read that closes the loop, lists each hop,
and says why the rule is stricter than run time:

```text
src/cli.brp:9:11: error: constant `HANDLERS` depends on itself: `HANDLERS` holds `show_help`, which reads `HANDLERS` here
note: src/cli.brp:4:1: `HANDLERS` is declared here
help: a constant is computed while compiling, so nothing it holds or calls may read it, even a function never called while computing it; pass the table to `show_help` as a parameter
```

With more hops the message reads, for example: "`A` calls `f`, which reads
`B`; `B` calls `g`, which reads `A` here". A direct cycle reads "`A` reads
`B`, which reads `A` here".

### Diagnostics a user meets in L3

The span is the loop or call where a budget ran out. A budget that runs out
inside a library constant renders as a fault in the standard library, with
the constant's name, because the user cannot fix it.

```text
config.brp:3:20: error: a constant cannot call `read_file`, which is impure
help: a constant is computed once, while compiling, so it can call only pure functions; read the file in `main` and pass the text where it is needed

adders.brp:4:52: error: constant `ADDERS` would hold a function that captures `n`
help: a constant may hold named functions and lambdas that capture nothing; make this a named function, or build the list inside a function at run time

tables.brp:7:26: error: computing `PRIMES` took too long: this loop ran 9,000,000 times before the limit of N operations
help: a constant must finish while compiling, with the same limit on every machine. If the loop never ends, check its exit; if it is just large, build the table in `main` with `table = build_table()` and pass it where it is needed

tables.brp:3:9: error: `TABLE` holds more than M list elements and string bytes
help: a constant this large would also make the C very large; build it in a function at run time, or keep it in a file and read it in `main`

math.brp:4:5: error: computing `FIB` nested more than D calls: `fib` calls itself here without stopping
help: check that `fib` reaches a case that returns; every constant has the same limit of D nested calls
```

The impure-call message replaces `render.brp:1085-1089`'s "mark the callee
pure" help for an initializer, because it has no `pure func` to change.

**The README paragraph** that L3 writes, in place of `README.md:288-294`:

```markdown
A module constant has an explicit annotation, as in `LIMIT: Int = 7`. Its
initializer is any pure expression of that type. The compiler computes it once,
while compiling, so reading a constant is free and behaves exactly like the same
code at run time. A constant can call pure functions, read other constants and
build Lists, Dicts and records. It cannot call an impure function, so it cannot
read files, the clock or the environment, and its value may not hold a lambda
that captures a value. Computing it must finish within N operations, M list
elements and string bytes, and D nested calls, the same on every machine. For
work that needs `for` or `var`, write a `pure func` and call it; to see a value,
print it from `main`. Errors from computing a constant appear in `blorp compile`,
not yet in the editor. Constants obey privacy, cannot be shadowed and take no
part in UFCS.
```

### Floats and natives

**Arithmetic and text agree between host and target.**

- **Arithmetic.** Both sides use binary64 with `FLT_EVAL_METHOD==0` and
  contraction off (`src/common/codegen/runtime/float.brp:13-17`).
- **Text.** `to_string` and parsing rely on `snprintf` and `strtod`, which
  round correctly on glibc, macOS and musl.

**NaN's sign is the one exception** (K5). It differs between x86-64 and
arm64, and `copysign` exposes it (`emit.brp:293`).

**Natives.** Every pure native is a `RuntimeOperation`. A future
`foreign func` reached from an initializer is rejected in the dependency
pass.

## Design: sizes in types

This half is a direction, not a brief. T6 recommends that it become its own
plan, with parser-specialist and ergonomics input, before T1 is briefed.

### The goal and the crux

Principle 14 asks for statically verified dimensions and proven indexing.

- **Today.** Nothing supports it. A type argument is a type
  (`grammar.ebnf:584-586`, `src/common/syntax/syntax.brp:312`), and
  `TypeRef` has no size (`model.brp:101-112`).
- **The retired compiler** had `#N`, `#Ds...`, `+ - * /` on sizes,
  `where #M + #N == #R` and `..#N` (`e1cae3971^:docs/GUIDE.md:901,1155,1736`).
  It normalized sizes in a 952-line `dim_solver.brp` that sorted factors by
  their spelling.
- **The crux.** Phases run over the whole program, so a type that mentions a
  computed value would need that value before `check` finishes.

| Route | How | Verdict |
| --- | --- | --- |
| (a) A closed size language in `check` | Literals, size parameters, constants made of numbers, `+` and `*`. `check` normalizes them to canonical polynomials. Go's checker evaluates its constants this way, and GHC compares such normal forms through `ghc-typelits-natnormalise`. | **Recommended.** Sizes need exact natural arithmetic and symbolic equality, which CTFE does not give, so even (b) would need this. |
| (b) Stratified compilation | The constants that types mention are checked, specialized, lowered and evaluated first. This is how Lean compiles, and how Rust evaluates a const in an array length on demand. | Later, and only for a consumer that needs a computed size. |
| (c) Residual constraints after evaluation | `check` treats a constant as opaque, and a later pass checks what is left. | Rejected. `WIDTH` against `640` becomes undecidable in `check`. |

### The spelling (T4): parser-specialist input

`../AGENTS.md` (Agent Coordination) requires parser-specialist input before
new syntax is implemented. This section is that input. The ergonomics review
reached the same recommendation.

| Aspect | `#` sigil, as the retired compiler had | Declared names, **recommended** |
| --- | --- | --- |
| Declaring | `[T, #N]` | `[T, N: Size]` |
| A literal | `Vector[Float, #3]` | `Vector[Float, 3]` |
| Arithmetic | `Vector[T, #M + #N]` | `Vector[T, M + N]` |
| A constant | `Vector[Float, #WIDTH * #HEIGHT]` | `Vector[Float, WIDTH * HEIGHT]` |
| In a body | needs a separate `size: #N` value | `N` is an `Int` |
| Parsing | `#` starts a size | in `type_arguments`, a digit or `+` or `*` starts a size; a bare name is resolved by namespace from its declaration |
| A first-time reader | Python reads `#` as a comment, and no mainstream language uses it | it matches Rust's `const N: usize`, Lean's `(n : Nat)` and C++'s `size_t N` |

Under declared names the grammar changes only in type arguments:

```ebnf
type_arguments  = "[" spaces type_argument { spaces "," spaces type_argument } trailing_comma spaces "]" ;
type_argument   = size_expression | type_annotation ;
size_expression = size_term { spaces ( "+" | "*" ) spaces size_term } ;
size_term       = integer | identifier | "(" spaces size_expression spaces ")" ;
```

**How names resolve.**

- **The ambiguity.** A lone name, such as `N` in `Vector[T, N]`, parses both
  ways. The parser keeps it as one `NamedArgument`, and namespace resolves it
  by its declaration's identity: a type, a type parameter, a size parameter
  or a constant. No meaning comes from the spelling.
- **`Size`.** A parameter whose bound is `Size` is a size parameter and takes
  no other bound. `Size` is a base-declared kind that nothing implements.

The teaching errors are in [Errors](#errors).

### The rules

1. **Sizes.** A size is a natural literal, a size parameter, a constant, `+`
   or `*` of sizes, or a parenthesized size. There is no `-` or `/` (T2).
2. **Binding a size parameter.**
   - **Where.** `[T, N: Size]` on a record, a union or a function. Size
     parameters are named like type parameters.
   - **How.** `N` is bound by matching a bare `N`: in a parameter's type at a
     call, or in the expected type at a call or at a constructor of a sized
     union. That is how `Vector.Elements(...)` and `Index.Init(...)` get
     their `N`. A compound size is computed after binding, never solved.
   - **Without a binding site** the call or construction is rejected.
3. **Constants in sizes.**
   - **Which constants.** A constant may appear in a size when its
     initializer is a size expression. `check` computes the exact value there
     and rejects one above `INT_MAX` there.
   - **Its runtime value** still comes from `evaluate`, and a constant never
     used as a size is untouched. Int arithmetic is exact modulo 2^64, so the
     two values agree whenever the exact value fits. So
     `MASK: Int = 4294967296 * 4294967296` stays an ordinary constant (it
     wraps to 0), and it is rejected only if it is used as a size.
4. **No singleton types.**
   - **Where sizes live.** Only in types. In a body, a size parameter reads as
     an `Int`.
   - **Ordinary arithmetic is unchanged.** Literals and arithmetic in ordinary
     expressions keep their `Int` types and wrapping arithmetic, and every
     existing diagnostic text stays the same.
5. **Equality.** Sizes compare in canonical form: a sum of terms, each a
   natural coefficient times a product of size parameters ordered by
   `SizeParameterId`. A polynomial over ℕ that vanishes everywhere is zero,
   so the form is complete for `+` and `*`: `M + N` equals `N + M` with no
   solver.
6. **Sizes are passed, not specialized** (T1). This is dictionary passing,
   as against Rust's specialization.
   - **What `specialize` drops.** Sizes leave layouts and instance keys, so
     `Vector[T, 3]` and `Vector[T, 4]` share code.
   - **Hidden arguments.** Each size parameter of a function becomes a
     hidden `Int` argument, and so, under T1 (b), does each size inside its
     instance's type arguments. A call passes a literal when the size is known.
     Otherwise it computes the size from the caller's own sizes with size
     operations that abort on overflow, as a List whose capacity cannot
     exist aborts today.
   - **In CTFE**, those operations delegate to `add_checked` and
     `multiply_checked`, so an overflow is an evaluation error, never a
     compiler abort.
   - **Function values.** A function value of a sized function captures its
     sizes.
7. **Traits.** A receiver takes fresh size parameters, as in
   `implements Describe for Vector[T: Describe, N: Size]`.
   - **Concrete sizes are rejected.** `implements X for Vector[T, 3]` is a
     concrete receiver pattern, and today's rule rejects those
     (`README.md:957-959`). So no implementation can tell sizes apart.
   - **No new instances.** Sizes add none, so the proof of finitely many
     instantiations (`README.md:960-962`) is unaffected, including for
     polymorphic recursion such as `g(v.concat(v))`.
8. **Indices** (T3, T5).
   - **`Index[N]`** is a union whose variant is private to `vector.brp`.
   - **`at`** keeps one bounds compare that aborts as an internal fault, so a
     bug in `vector.brp` cannot read out of bounds. The C compiler removes the
     compare where it can prove the index fits.

### The library surface and the acceptance examples (T3)

```blorp
-- standard_library/vector.brp. Only this module builds a Vector or an Index,
-- and each constructor has a test of its length.
union Vector[T, N: Size]:
    private Elements(List[T])

union Index[N: Size]:
    private Init(Int)

pure func filled[T, N: Size](value: T) -> Vector[T, N]:
    Elements(repeat(value, N))                         -- N is an Int here
pure func from_list[T, N: Size](items: List[T]) -> Option[Vector[T, N]]   -- checks the length
pure func generate[T, N: Size](make: pure (Index[N]) -> T) -> Vector[T, N]
pure func map[T, U, N: Size](vector: Vector[T, N], change: pure (T) -> U) -> Vector[U, N]
pure func zip[T, U, N: Size](left: Vector[T, N], right: Vector[U, N]) -> Vector[(T, U), N]
pure func concat[T, M: Size, N: Size](left: Vector[T, M], right: Vector[T, N]) -> Vector[T, M + N]
pure func to_list[T, N: Size](vector: Vector[T, N]) -> List[T]
pure func length[T, N: Size](vector: Vector[T, N]) -> Int:
    N
pure func indices[T, N: Size](vector: Vector[T, N]) -> List[Index[N]]
pure func get[T, N: Size](vector: Vector[T, N], position: Int) -> Option[T]   -- principle 14's get()
pure func checked_index[T, N: Size](vector: Vector[T, N], position: Int) -> Option[Index[N]]
pure func at[T, N: Size](vector: Vector[T, N], position: Index[N]) -> T
```

These must compile before T3 is accepted:

```blorp
WIDTH: Int = 640
HEIGHT: Int = 480

record Frame {
    pixels: Vector[Float, WIDTH * HEIGHT]
}

pure func blank_frame() -> Frame:
    { pixels = filled(0.0) }                           -- N is bound from the field: 307200

pure func join(a: Vector[Int, 2], b: Vector[Int, 3]) -> Vector[Int, 5]:
    a.concat(b)                                        -- 2 + 3 normalizes to 5

record Packet {
    header: Vector[UInt8, 4],
    body: Vector[UInt8, 60]
}

union Matrix[T, R: Size, C: Size]:
    private Rows(Vector[Vector[T, C], R])

pure func multiply[R: Size, K: Size, C: Size](
    left: Matrix[Float, R, K],
    right: Matrix[Float, K, C]
) -> Matrix[Float, R, C]
```

**Questions for the sizes plan:**

- **Literals.** Does a List literal of known length build a `Vector`, as in
  `v: Vector[Int, 3] = [1, 2, 3]`?
- **Indexing.** Does `v[i]` with an `Index[N]` call `at`? Postfix `[ ]`
  indexes only tuples today (`README.md:316,531`).
- **Shrinking.** Operations that shrink, such as `head`, `tail` and `take`,
  wait for T2. Until then they return Lists, and the README says so.

### Errors

The phases follow the rules above, and none comes after `check`.

| Error | Phase | Message, then help |
| --- | --- | --- |
| `-` or `/` in a size | parse | "sizes can be added and multiplied, but not subtracted", then "Blorp cannot yet prove `N - 1` is not negative; return a List, or an `Option[Vector[T, M]]` built with a check" |
| A type where a size is expected | check | "`Vector`'s second argument is a size, but `Int` is a type", then "write a number, such as `Vector[Float, 3]`" |
| A type parameter where a size is expected | check | "`N` is a type parameter, but `Vector`'s second argument is a size", then "declare it as a size: `[T, N: Size]`" |
| A constant where a type is expected | check | "`WIDTH` is a constant, not a type", then "a constant can be a size, as in `Vector[Float, WIDTH]`" |
| A run-time value in a size | check | "`count` is computed at run time, so it cannot be a size", then "use a literal, a size parameter or a constant made of numbers, `+` and `*`, such as `COUNT: Int = 3`; for a length known at run time use List" |
| A constant whose initializer is not a size expression | check | "`LAST` is used as a size, so its initializer must use only numbers, other such constants, `+` and `*`", then "`LAST: Int = WIDTH - 1` can be used as a value, but not as a size" |
| An unbound size parameter | check | "`N` of `zeros` is never given", then "use `N` in a parameter's type or in the result's expected type, as in `filled[T, N: Size](value: T) -> Vector[T, N]`" |
| Sizes that differ | check | "expected `Vector[Float, WIDTH * HEIGHT]` (307200), found `Vector[Float, WIDTH + WIDTH]` (1280)", then "`Frame.pixels` holds `WIDTH * HEIGHT` = 640 * 480 = 307200 values". Both the symbolic and the evaluated forms are always printed. |
| One size bound two ways | check | "`left` and `right` must have the same size, but `left` has 3 and `right` has 4", then "`zip` needs equal sizes; use `left.to_list().zip(right.to_list())` for the shorter length" |
| An `Int` where an `Index` is needed | check | "`at` needs an `Index[3]`, but `i` is an `Int`", then "loop over `v.indices()` for proven indices, or use `v.get(i)`, which returns an `Option`" |
| A size above `INT_MAX` | check | "`4294967296 * 4294967296` is 18446744073709551616, more than the largest size, 9223372036854775807", then "a size must fit in an `Int`" |
| A size parameter that shadows a constant | check | "the size parameter `N` has the same name as the constant `N`", then "rename the size parameter or the constant" |
| A private constant in a public type | check | "the public `Frame` names the private constant `WIDTH` in a size", then "make `WIDTH` public, or `Frame` private" |
| A concrete size in a receiver | check | today's rejection of a concrete receiver pattern (`README.md:957-959`) |
| A cycle among constants used as sizes | check | K3's message shape: "constant `A` depends on itself: `A` reads `B`, which reads `A` here" |

### Compatibility with L1 to L4

T1 changes nothing in how constants are evaluated: under rule 3, a constant
used as a size is checked where it is used. Hidden size arguments are
ordinary `Int` parameters, so `own`, `verify` and `evaluate` need nothing
new. The two size operations are added by
[Changing a primitive](#changing-a-primitive). Route (b) could later call
`evaluate` through the same interface.

### Decisions for sizes

Keith accepted each recommendation here on 2026-11-24.

- **T1. Route (a), with sizes passed as hidden arguments.** Recommended.
  The alternatives are route (b), or specializing per size.
  - **The problem (N2).** A generic body, such as `show[T: Describe](x: T)`
    instantiated at `Vector[Int, 3]`, has no `N` to pass to
    `Describe for Vector[T, N: Size]` once sizes leave instance keys.
  - **(a) Keep sizes nested in type arguments in instance keys.** A caller
    whose own sizes are hidden makes those keys symbolic. That cascades into
    specializing per size in general.
  - **(b) Recommended: pass every size in an instance's type arguments as a
    hidden `Int`.** Each size inside its type arguments becomes a hidden
    argument in a fixed order, as a function's own size parameters do. This
    is Haskell's `KnownNat` dictionaries, resolved per instance. It is one
    mechanism, only instances with sized type arguments pay for it, and
    `Self`-returning methods such as `Default` work.
  - **(c) Forbid reading a receiver's sizes** in an implementation body, and
    `Self`-returning methods on sized receivers. It is the simplest, but it
    rules out `Default` and any implementation that uses `N`.
  - **The detail** belongs to the sizes plan (T6).
- **T2. Only `+` and `*` at first.** Recommended. `-` and `/` need `where`
  bounds and proofs.
- **T3. `Index[N]`, with no `..#N` shorthand.** Recommended, as the
  ergonomics review advised.
  - **Why no shorthand.** `..` is the range operator, and `..#N` would give
    it a second meaning.
  - **Principle 14's wording** becomes `Index[N]` in place of `..#N`.
  - **Run-time access** is `get`, which returns `Option[T]`.
- **T4. Declared names, `[T, N: Size]`, over `#`.** Recommended.
- **T5. `at` keeps one bounds compare.** Recommended, because safety comes
  first. The alternative trusts `vector.brp`: an assertion in diagnostic
  builds, and a length test for each constructor.
- **T6. Split this half into its own plan before T1.** Recommended. The
  surface, the diagnostics and the hidden-argument lowering need their own
  briefs and reviews.

## Where the plans meet

| Private-variants landing | CTFE |
| --- | --- |
| 1 to 3: private variants, erasure, the union-headed `Dict`, the seed rotation | L1 is independent of them. L2 and L3 come after landing 3, so their identity types are unions with a private variant from the start: compiler source cannot use private variants before that rotation. Erasure is in `specialize`, so the evaluator's input is the same either way. L3's Dict constants use `check`'s one Dict-literal path, which landing 2 updates. |
| 4: migrate | L4 follows it. Its consumers build `NameId`, `NameTable` and `ParsedAssembly`, which use `into_opaque` today (`names.brp:112,217`, `assemble.brp:139`), so L4 writes `NameId.Init(...)`. |
| 5 and 6: delete | Nothing here builds on `ConstructOpaque`, opaque ids or opaque layouts. L2 and L3 leave `resource_free(scope.opaques, ...)` (`check/constants.brp:43`) alone, so landing 6 still changes one site. |
| Rotations | Each plan rotates separately, and each rotation is judged as a rotation. Every landing is measured against its own parent beforehand, so the costs stay apart. |

T3's `vector.brp` needs private-variants landings 1 and 2.

## The LSP: what showing these errors would need

The server analyses with `analyze` (`src/lsp/server.brp:96`), which ends at
`check` (`src/common/analysis/check/check.brp:257`). So the editor shows
neither evaluation errors nor cycle errors. A later change would need only
three things:

1. **The phases.** After a successful analysis, run `specialize`, `lower`,
   `own`, `verify` and `evaluate` under K9 (a). Under K9 (b), run only
   `specialize`, `lower` and `evaluate`.
2. **The roots.** Specialization rooted at the user constants alone (K6).
   Today it needs an entry function (`specialize.brp:5938`, `check.brp:333`).
3. **The diagnostics.** Publish these with their spans, as check's are.

**Cost.** In a sampled self-compile, `specialize` and `lower` take 64% of
`check`'s samples, and `own` and `verify` another 79%. Rooted at constants
alone, they cover only the constants' dependency closure.

## Landings

Each landing brief is within `../docs/HANDOFF_SPEC.md`'s limits, and none
adds syntax.

**L1: static string literals.** It touches `runtime/string.brp` and
`emit/emit.brp`: the literal sites at `emit.brp:350-356`, and their use at
1196.

- **What changes.** Each literal becomes a writable static String at the
  literal base. The lazy site, its first-use test and its first-use
  allocation go. Ownership is unchanged.
- **What it inherits from the concurrency plan's landings 1 and 1b.**
  - **A normal build** already skips a literal in retain and release, so a
    static String at the base needs no change there, and could even be
    `const`.
  - **A diagnostics build** still counts literals, so the static String stays
    writable there and each read still retains.
  - **`blorp_string_literals_finish`** must stop releasing static objects.
  - **The publish lock** goes with the lazy site. Keep the threaded literal
    test, which then checks static literals.
- **Oracle.** Every e2e fixture's output is unchanged. A compiler built from
  L1's own C writes the same C as L1's compiler.

**L2: static constants (today's closed initializers).** After
private-variants landing 3.

- **Phases.**
  - `check`: `ReadConstant`.
  - `specialize`: `ConstantInstanceId`, with the closed template translated
    to a `ConstantValue`. L3 deletes that translation, about 150 lines.
  - `lower`: `ReadConstantValue`.
  - `own`: `StaticBorrow`.
  - `verify`: the pairing rule.
  - `emit`: the read forms.
- **Documents.** It updates the `grammar.ebnf:714-721` comment and the
  README paragraph's storage sentence.

**L3: computed constants.**

- **Phases.**
  - `check`: `InitializerBody`, pure initializers, the impure-call message,
    and deleting the closed mode.
  - `specialize`: `ConcreteConstant`, initializer roots, instance roles, and
    the dependency order with its message.
  - The new `evaluate.brp`, placed under K9: an explicit frame stack,
    budgets, delegation and `publish`.
  - `generate_c.brp`.
- **Documents.** The README paragraph, the README's phase list, and root
  `AGENTS.md` rule 8's phase list.
- **No grammar change.** `initializer` already takes an expression
  (`grammar.ebnf:651`).

**L4: consumers.** After private-variants landing 4, and the seed rotation
that carries L3. It makes constants of `TOKEN_LEGEND`, `BUILTIN_LABEL_HELP`,
`PROGRAM_NAMES`, an empty assembly, `STRING_APPEND_INT_RUNTIME` and the Bytes
signature. Semantic tokens then stop rebuilding `program_names()` on every
request (`tokens.brp:456`).

**After L4.** The sizes landings T1 (sizes in types), T2 (the bounds-checked
read for `at`) and T3 (`vector.brp`) belong to the plan that T6 splits out.

## Ceilings

These bind the fixed-input row of `scripts/self-compile-cost PARENT CANDIDATE
--rounds 5`. Line ceilings are estimates from sketches. Exceeding one stops
the landing for a growth audit (`../AGENTS.md`).

| Landing | Instructions | Allocations | Peak heap | Production lines | Test lines |
| --- | --- | --- | --- | --- | --- |
| L1 | +0.1% | +0.05% | +0.1% | +20 | +150 |
| L2 | +0.2% | +0.1% | +0.2% | +650 | +700 |
| L3 | +0.5% | +0.5% | +0.5% | +1,300 | +1,900 |
| L4 | reported | reported | reported | 0 | 0 |

**Stage-2 bounds.**

- **L1.** The seed builds both compilers, so neither runs static literals
  itself. A compiler built from L1's own C must therefore make at least 1,000
  fewer allocations than B's in a self-compile, a deterministic figure
  (measured: 1,520). Instructions are reported, not bound, because the gain
  is within twice the noise.
- **L2.** It binds the decoder witness's e2e allocation ceiling at 1.

## Testing

**Phase suites.** Small typed inputs, under each source file's mirrored
`test_` folder.

- `check` publishes reads, not copies; for an initializer, the impure-call
  message.
- `specialize`:
  - one instance per constant;
  - instance roles;
  - a constant that holds a function only its initializer reaches;
  - cycle messages for one hop, several hops and a direct cycle.
- `own` gives static borrows. `verify` rejects a call result that claims
  `StaticBorrow`, and an owned value used as one.
- `emit` writes each read form in the table.
- `evaluate`:
  - each budget's message, help and span, with the depth limit tested under
    the `-O0` diagnostics build;
  - K8's rejection and its message;
  - `OperationNotHostedYet`;
  - a library constant's failure rendered as a library fault.

**Runtime C tests** (`test/test_common/test_codegen/test_runtime/`):

- a static object is never freed, and an update copies it;
- the strict leak check fails when a static object is not back at its base;
  break the check once to prove it.

**Differential oracle (L3).** Each fixture declares `K: T = f(x)`, and its
`main` prints `K` and `f(x)` computed at run time, in the same binary. Swap
one delegation arm, then one step arm, to prove that the oracle fails.
Fixtures cover:

- each pure `RuntimeOperation`, in both integer formats;
- Float `-0.0`, the infinities and NaN, and multibyte slices;
- each of the 16 `ValueOperation`s (`lower.brp:141`);
- `Join`, `Loop`, `Break`, `Recur` and `TransferLoop` (`lower.brp:178-211`);
- the three decision tests (`lower.brp:266-270`) and the four
  `SelectionDefinition`s (`lower.brp:252-256`);
- closures, and an early `break` out of nested joins;
- a Dict with collisions and removals.

**The memory test (L3).** A Dict of 2,000 entries and a map over 10,000
elements are evaluated as a constant, then the same at double the size.

- **Linear growth.** Doubling the input multiplies the evaluator's
  allocations by at most 2.1, as native code's 4,055 to 8,060 does.
- **The native check.** The same fixture's native run reports native code's
  counts beside them.
- **The proof.** Removing the slot clearing of moves must break the bound.

**Commands.**

1. While iterating: `make -C blorp test-target-components TARGET_COMPONENT_SOURCES=<suite>`.
2. Then: `make -C blorp test INSTRUCTION_CHECK=on`.
3. Then a dispatched Seed job for each landing.

## Acceptance criteria

- [ ] **L1:**
  - e2e outputs are unchanged;
  - the stage-2 compiler writes the same C, and makes at least 1,000 fewer
    allocations;
  - `blorp_string_literal` and its site struct are gone;
  - the gates pass.
- [ ] **L2:**
  - the decoder witness makes 1 allocation;
  - reading a closed List constant allocates nothing, under an e2e ceiling;
  - both verify malformed-IR tests fail when the pairing is loosened.
- [ ] **L3:**
  - `legend.brp` and `keywords.brp` from [Problem](#problem) compile and run;
  - every oracle class above has a fixture;
  - the memory test's evaluator allocations grow at most 2.1 times when the
    input doubles, checked against native code's counts for the same
    fixture;
  - each message in [Diagnostics](#diagnostics-a-user-meets-in-l3) has an
    exact-text test;
  - the README paragraph is in.
- [ ] **L4:**
  - the five consumers and the Bytes signature are constants;
  - L4 adds no `into_opaque`.
- [ ] **Each landing:** the ceilings hold, and the gates pass.

## Measurements

**Setup.** The host was an Apple M4 on macOS 26.7.1, with Apple clang 21.0.0
at `-O2` unless stated. The source was `f9423ade5`, compiled with compiler
B, which seed `blorp-seed-8eb8e16546b3` built.

| Artifact | SHA-256, first 16 digits |
| --- | --- |
| Compiler B | `a40bf306ed0ff047` |
| Self C | `47693459b6901d27` |

**Method.** An instruction figure is the median of a set's runs, taken with
`/usr/bin/time -l`. Every variant's output C was compared byte for byte with
the self C, and allocation counts are deterministic.

**Files.** In `../build/ctfe-k2-2026-11-23/`, each script sources
`common.sh` and writes beside itself:

- `self.sh` writes `self/`: reference counts by kind, literal calls, `-O2`
  instructions and allocation sites;
- `spike.sh` writes `spike/`, for the zero-count marker;
- `literals.sh`, with `ROUNDS=5`, writes `literals/`, for L1's prototype;
- `decoder.sh` writes `decoder/`, for L2's prototype on the decoder.

The raw self C and the time files are kept.

**Reference counting in a self-compile** (`instrument_rc.py --kinds`):

| Kind | Increments | Decrements |
| --- | --- | --- |
| String | 13,841,605 | 14,852,265 |
| List | 26,734,855 | 31,067,461 |
| Counted record | 50,654,581 | 56,715,930 |
| Boxed union | 25,358,597 | 26,982,019 |

**What the zero-count test costs.** It was added to a copy of the self C, in
which no static object exists. The base ran 13,216,474,921 instructions.
`spike.sh` adds the variants with `__builtin_expect`.

| Variant | Instructions | Change |
| --- | --- | --- |
| S: a test in String retain and release | 13,571,500,300 | +2.69% |
| L: `[]`'s address test becomes a count test | 13,177,439,721 | −0.30% |
| R: a test in counted-record and boxed-union dup and drop (428 of 441 drops; 13 top-level drops, `emit.brp:1086`, unpatched) | 13,686,213,036 | +3.55% |
| S, L and R together | 13,860,115,812 | **+4.87%** |
| S with `__builtin_expect` | 13,611,991,022 | +2.98% |
| R with `__builtin_expect` | 14,479,601,869 | +9.55% |

**The cause is a hypothesis.** It is about 12 instructions per String
operation, far above the two the test adds. Code layout and inlining effects
are the likely cause: static code grew 2.4%, and the branch hints made it
worse. The conclusion does not depend on the cause, because the base-count
marker adds no code to these paths.

**L1's prototype** (`static_literals.py`) makes the literal sites static,
with ownership unchanged and the output identical.

| Set | Rounds | Static | Base | Change |
| --- | --- | --- | --- | --- |
| First run | 3 | 13,163,612,855 | 13,207,910,800 | −0.34% |
| The soundness review's paired rerun | 3 | — | — | −0.20% |
| `literals.sh`, alternating order | 5 | 13,140,717,817 | 13,203,280,746 | −0.47%, with rounds from −0.37% to −0.51% |

- **Allocations.** 1,520 first uses, out of 6,663,259 literal evaluations.
- **Noise.** Base runs spread about 0.25%.

**Constant reads in a self-compile.** They make 117 allocations, out of
13,029,662: 114 in `parse.builtin_operation`, 2 in `emit.emit` and 1 in
`main.parse_command`.

**The decoder witness** (`decoder/decoder.brp`). It runs 4,096 rounds that
decode codes 2, 12 and −37 through `io/_errors.native_error_kind`, which
reads `NATIVE_ERROR_KINDS`. `decoder_static.py` hand-writes L2's C for that
read.

| Variant | Allocations | `-O2` | `-O0` |
| --- | --- | --- | --- |
| Today | 8,193 | 16,523,036 | 30,870,726 |
| A static List, borrowed (`StaticBorrow`) | 1 | 11,630,396 (−29.6%) | 23,954,771 (−22.4%) |
| A static List, acquired and dropped at each read (`--acquire`) | 1 | 12,635,924 (−23.5%) | 24,270,596 (−21.4%) |

- **Output.** All three print `208896`.
- **The leak check.** The strict run is clean, but the prototype has no
  check of static objects, so it does not exercise one.
- **`StaticBorrow`.** It saves about 123 instructions per read on top of
  static storage.

**Phase shares for the LSP estimate.** Three `sample` runs of about 700
samples each give these medians:

| Phase | Samples | Share |
| --- | --- | --- |
| `check` | 218 | 31% |
| `specialize` | 111 | 16% |
| `lower` | 29 | 4% |
| `own` | 107 | 15% |
| `verify` | 66 | 9% |
| `emit` | 139 | 20% |
| other | 25 | 4% |

**What the numbers suggest for K2.** Static data pays on its own, if it uses
the literal base:

- **L1** removes 1,520 allocations deterministically, and instructions
  within twice the noise.
- **L2** is a large win for code that reads table constants in a loop, and
  it makes the README's promise that a read is free true.
- **The compiler itself** gains little from L2: its constant reads are
  0.001% of its allocations.

## Handback

Each landing returns:

- its commit and gate logs;
- the `self-compile-cost` table, and its stage-2 bound;
- its C identity evidence;
- its lines against the ceilings.

Stop and ask when a ceiling fails beyond a routine correction, when an oracle
fails, or when a step needs the opaque machinery that the private-variants
plan deletes.
