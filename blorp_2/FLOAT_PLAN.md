# Float64 literals, arithmetic and conversion

Status: implemented and independently reviewed. Granular phase/ownership tests,
native numeric/calculator cases, deliberate mutations and matched cost gates pass;
[retained results](../benchmarks/results/blorp_2_calculator_2026-10-12.md)
include extreme-subnormal cost and the host carrier's physical representation.
This completes calculator steps 8–9 after
the ordinary Option, input and operation-selection work in
[CALCULATOR_COMPLETION_PLAN.md](CALCULATOR_COMPLETION_PLAN.md).

```blorp
import:
    float: add, to_string
    io: print
func main() -> Int:
    print(to_string(add(0.1, 0.2)))
    0
```

The exact stdout is `0.30000000000000004\n`, with exit zero and empty stderr.
The final calculator accepts `multiply\n6.5\n2\n` and prints `13\n` through
its ordinary main. Exit status cannot observe a Float value precisely.

## Identity, representation and phase boundaries

The required explicit prelude declares `type Float = builtin`. Prelude checking
accepts its unique identity alongside Int, String and Void. No optional fallback
or later spelling recognition is added. Parsing converts each complete numeric
token once through the existing pure host `string.parse_float` API, after strict
grammar validation and a finite-result check. Source spelling ends there:

```blorp
-- Each phase has its own existing variant/type boundary.
FloatLiteral(String)       -- lexer token and original byte span
FloatExpression(Float)    -- parsed native binary64 value
ReturnFloat(Float)        -- checked and concrete leaf variants
FloatValue(Float)         -- lowered function-local ValueId
FloatDefinition(Float)    -- ownership definition
```

FloatType is unmanaged, with no operands, owner, retain or drop. Independent
verification checks the type and unmanaged result contract, and rejects a
nonfinite literal definition; runtime arithmetic may produce nonfinite values.
Float works in function parameters, returns, locals, generic arguments and
concrete generic payloads. Existing declarations permit only Int in record
fields and direct primitive union payload annotations; those restrictions stay.
Option[Float] uses the already supported generic payload substitution and the
existing nominal union/variant identities. This does not widen Void or
managed-value policies. Main still returns Int.

The emitter consumes the Float value, without reparsing text or indexing a
literal table. `float_literal.c_float_literal` emits exact C hexadecimal
constants: `0.1` becomes `0x1.999999999999ap-4`. Scaling by powers of two
normalizes a finite magnitude; thirteen hexadecimal fractional digits encode
all 52 fraction bits exactly. Normalization needs at most 1,074 iterations,
including the smallest subnormal. Negative zero becomes `-0x0p+0`.
Each digit uses at most fifteen exact subtractions rather than a numeric cast.
The current host's `float.to_int` and `int.to_float` wrappers compile into
self tail-call loops; the initial isolated nonzero projection run timed out.
This bounded arithmetic extraction avoids those host APIs without changing the
Float carrier or adding a converter framework. The host defect remains separate.
The timeout packet is `build/calculator/float-isolated-green-2`; the minimal
compile-only reproduction, generated C, wrapper excerpt and hashes are retained
under `build/calculator/float-host-cast-hang/`. The repaired 21-callback run is
`build/calculator/float-isolated-green-3` (793 ms, unchanged source fingerprint).
The helper also projects nonfinite host values to standard C math macros so its
public Float interface is total; those values do not become accepted literals.
No compiler FFI, bit-cast API, custom decimal converter or new pass is needed.

## Syntax and conversion

Source Float grammar is an optional adjacent minus, an integer part without
leading zeros except `0`, and either a dot with at least one following digit or
an exponent. A fractional form may also have an exponent. Exponents use `e` or
`E`, an optional sign and one or more decimal digits. Thus `1.0`, `1e2`,
`-0.0` and `2.5e-3` work; `.5`, `1.`, leading plus, separators and hex do not.
A dot before an identifier still starts UFCS: `1.identity()` and
`1.0.identity()` retain their existing call grammar. Malformed exponent/dot
forms have precise byte spans and help suggesting `0.5`, `1.0` or `1e2`.
Integers retain Int type; no implicit numeric coercion is introduced.

Runtime `parse_float(String) -> Option[Float]` accepts the complete grammar
`[+-]?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?`. Integer-only mantissas and leading
zeros are convenient input forms. Empty/sign-only input, whitespace, NUL,
non-ASCII, commas, suffixes, hex, separators and nan/inf spellings produce None.
A short counted-byte scanner precedes strtod; the returned end pointer must
equal `bytes + length`. Nonfinite conversion is None. Source overflow instead
reports a finite-Float64-range diagnostic with help to use a smaller magnitude
or exponent. Both paths accept subnormals and underflow rounded to signed zero;
ERANGE alone must not reject representable subnormals.

Parsing borrows String and creates an unmanaged Float payload. The runtime
helper returns internal C success/value facts; accepted concrete Option roles
determine target tags and payload fields during emission. No name or shape
guess determines Option's identity, variant order or ownership.

## Arithmetic, formatting and execution model

Closed pure operations provide add, subtract, multiply, divide and remainder.
Division or remainder by either signed zero returns positive zero, following
the parent language principle. This deliberately adapts the current host
library: `standard_library/src/float.brp:18` and its native runtime describe IEEE
Float zero division as infinity/NaN. Other supported binary64 arithmetic uses
nearest/ties-even, gradual underflow and ordinary infinity/NaN propagation.
Remainder uses fmod, whose quotient truncates toward zero, rather than C's
nearest-quotient remainder function. NaN sign/payload are unspecified.

Formatting returns one fresh ordinary String via the existing byte constructor.
It canonicalizes `nan`, `inf` and `-inf`, and preserves negative zero as `-0`.
Finite values use the host's established six-significant-digit `%g` form when
it parses back to identical bits; otherwise a bounded linear search tries
precisions seven through DBL_DECIMAL_DIG (17). This is a round-trip promise,
not a universally shortest spelling: the smallest subnormal may print
`4.94066e-324`. The host exposes this policy through pure Float `to_string`;
its `format_float` API instead controls fractional places, not significant
digits. Target runtime code uses snprintf/strtod directly with fixed buffers.

Supported standalone targets require binary64 double, FLT_EVAL_METHOD zero,
default nearest-even rounding, gradual underflow and the C startup locale.
Compile-time float.h/size guards, including DBL_DECIMAL_DIG equal to 17 and
DBL_HAS_SUBNORM equal to one, reject
incompatible representation and fast math. FP contraction is disabled for the
emitted Float fragment. No supported
pilot operation changes locale or rounding mode; no setlocale, fesetround or environment
read chooses numeric semantics. The supported Clang toolchain is tested at
`-O0`. C11 alone does not promise correctly rounded decimal conversion on every
implementation, so portability beyond the tested execution model is not claimed.

The isolated module publishes three pure String builders. `float_runtime()`
contains common target guards and arithmetic. `float_string_runtime()` requires
that fragment plus the String base and supplies fresh-String formatting.
`float_parse_runtime()` has the same dependencies and supplies
`int blorp_string_parse_float(const struct blorp_string*, double *out)`.
Existing typed fragment selection includes only needed dependencies. It adds no
pipeline layer, registry or cache, and preserves prior generated C.

## Acceptance and costs

Tests precede integration. Named granular callbacks cover token kind/span,
decimal grammar and teaching diagnostics, prelude identity, exact Float carrier,
generic substitution and preserved record/direct-payload restrictions, ordered lowering, unmanaged
ownership, String borrow/drop, independent malformed IR and exact C projection.
Include halfway rounding, adjacent values, signed zero, smallest subnormal,
smallest normal, largest finite, overflow and underflow.

Normal-main fixtures print exact full-width results for all arithmetic and
exception cases, strict conversion failures, embedded NUL followed by digits,
and the stdin calculator. Reuse the same executable across stdin cases. A
moderate 64-value/call fixture must compile at default C limits with flat depth.
Mutating literal projection or reducing formatting to six digits must break
the relevant native oracle; removing full-consumption validation must break
the NUL/suffix cases. No additional direct C unit-test exception is required.
Pure fragment-shape unit tests do not substitute for native semantic fixtures.

The Float implementer owns shared integration; root owns integration evidence
and a separate compiler expert owns independent review. The
runtime/projection author does not independently approve those files.
Run focused tests in the assigned serial lane, then all four pilot suite roots
with ASan/UBSan and strict leak checking, followed by the complete e2e gate.

Freeze prior executable roots before each stage. Three serial paired samples
must remain within +10% aggregate allocations and retired instructions through
C emission, with balanced releases and complete prior C identity. This is an
owned-input proxy, not self-compilation; the mandatory Float prelude declaration
is an explicit input difference. Measure extreme-subnormal projection and the
native Float carrier's host representation. Aim for at most 1,000 net production
lines for steps 8–9 within the overall 2,000-line aim; report tests, inactive
upstream comments and physical production totals separately. Reassess excess
rather than compress formatting or build an optimization framework.

Primary references: [Rust literals](https://doc.rust-lang.org/reference/expressions/literal-expr.html#floating-point-literal-expressions),
[Rust numeric tokens](https://doc.rust-lang.org/reference/tokens.html#floating-point-literals),
[OCaml Float option/classification](https://ocaml.org/manual/5.3/api/Float.html),
[C11 draft](https://www.open-std.org/jtc1/sc22/wg14/www/docs/n1570.pdf)
(6.4.4.2, 7.11.1.1, 7.12.10.1, 7.21, 7.22.1.3 and Annex F), and
[Clang floating-point behavior](https://clang.llvm.org/docs/UsersManual.html#controlling-floating-point-behavior).
