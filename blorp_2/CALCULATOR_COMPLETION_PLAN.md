# Completing the calculator

The original stdin/read_line design below is retained as the completed
historical increment. [ARGUMENTS_PLAN.md](ARGUMENTS_PLAN.md) supersedes its input
protocol and impure parser helpers with explicit List[String] arguments and
pure Result-returning evaluation. The pilot no longer exposes read_line.

Status: steps 5–9 complete. Independent review, strict component tests, all
native calculator cases, deliberate mutations and the predeclared cost/size
criteria pass. [Retained results](../benchmarks/results/blorp_2_calculator_2026-10-12.md)
record the executable verdict, granular coverage and limitations.

This is the bounded implementation plan for steps 5–9 of
[CALCULATOR_PLAN.md](CALCULATOR_PLAN.md). Each step starts with failing Blorp
TestSuite callbacks and a normal-entrypoint executable. Complete, immutable
facts cross the existing pipeline boundaries; no new pipeline or execution
framework is needed. The existing compiler remains the host.

## Library results and input

`Option[T]`, `Result[Value, Error]` and `Bool` are ordinary fixed unions owned by
`standard_library_temp/_base/types.brp`. Their types and constructors are available
in every module without imports. Separate Option and Result operation modules
are deferred until operations need them. The
[imports design](IMPORTS_AND_PRELUDE_PLAN.md) defines explicit selections for
other types and their operations.

```blorp
pure func parse_int(text: String) -> Option[Int]:
    builtin("string.parse_int", Some, None)
```

The builtin declaration explicitly binds runtime success/failure roles to
constructors. Checking validates their owner, instantiated payload types and
the complete result union, then publishes accepted declaration identities.
Specialization translates those identities to concrete union/variant identities.
Ownership and emission consume the concrete result contract. The independent
verifier rejects malformed contracts. Neither spelling nor variant order
determines meaning. Bool comparison follows the same boundary with its own
precise two-empty-constructor role carrier:
`builtin("string.equals", True, False)`.

Named function imports permit direct and UFCS calls. Prelude type selections
supply UFCS-only candidates. Checking selects applicable UFCS functions using
accepted receiver types and arity; ambiguous applicable candidates are rejected.
For example, `float: to_string` supports direct Float formatting while
`1.to_string()` resolves through the Int prelude methods. An unimported module's
functions do not enter another module's scope. Base builtin type identities
remain unique.

`parse_int` borrows its String, accepts an optional ASCII sign followed by one
or more ASCII decimal digits, and consumes the complete byte sequence. Leading
zeros in input are allowed. Empty input, whitespace, NUL, non-ASCII digits,
suffixes and values outside Int64 produce None. Accumulate with checked bounds;
do not copy the host's unchecked strtol wrapper. Some(Int) is unmanaged.

`read_line() -> Option[String]` is impure. It removes one LF, preserves CR and
all other bytes, returns Some("") for an empty line, and returns the last nonempty
unterminated line before EOF. EOF with no bytes returns None. Some(String)
contains one fresh owner; existing exhaustive union destruction handles it.
No stream-error API is introduced beyond the existing Option contract.

Existing managed-prefix restrictions remain. Small consumers match borrowed
parameters, rather than requiring a fresh managed scrutinee before a tail match:

```blorp
func main() -> Int:
    first_line(read_line())
func first_line(line: Option[String]) -> Int:
    match line:
        Some(text): first_number(parse_int(text))
        None:
            print("missing input")
            1
```

Add exact counted-byte String equality for operation selection. A local
Operation union and small Bool-consuming functions decode `add`, `subtract`,
`multiply`, `divide` and `remainder`. No calculator-specific intrinsic, string
pattern syntax, if expression or loop is required. Int add/subtract/multiply
wrap; division and remainder return zero for a zero divisor. Int64 minimum
divided by -1 wraps to minimum, and its remainder is zero, without C undefined
behavior.

## Float64

The prelude owns the Float builtin identity. Parse decimal source literals into
Float values, then retain typed values through checking, specialization,
lowering and ownership. Spelling is discarded after parsing. Source literals
require digits on both sides of a decimal point or an exponent: `1.0`, `1e2`,
`-0.0`. Preserve integer UFCS such as `1.identity()`. Reject `.5`, `1.`, source
leading plus, leading-zero integer parts, hexadecimal forms and separators with
helpful diagnostics.

Runtime parse_float borrows its String and returns ordinary Option[Float]. It
accepts a complete ASCII decimal with optional sign, integer-only mantissa or
digits on both sides of a decimal point, and optional signed exponent. Leading
zeros are allowed. Reject
whitespace, NUL, suffixes, non-ASCII, nan/inf spellings and overflow to infinity.
Accept subnormals and underflow rounded to signed zero. Source literals use the
same range rule. A short strict scanner gates libc strtod; no custom decimal
conversion algorithm is introduced.

Float arithmetic uses binary64. Division and remainder by either signed zero
return positive zero, as required by Blorp's infallible arithmetic rule.
Remainder otherwise uses fmod (quotient truncated toward zero). Other arithmetic
can produce infinity or NaN. Formatting uses canonical `nan`, `inf`, `-inf`,
and preserves negative zero. Finite formatting follows the existing host's
six-significant-digit %g form when it round-trips; otherwise it checks precisions
7 through 17 in order. Bit equality protects the signed-zero round trip.
NaN payloads are unspecified. C projection of finite literal values is exact.

The supported native execution model is binary64, C startup locale and default
rounding, with no target capability to change either. Do not set global locale
or rounding state, read an environment variable to choose semantics, or claim
identical conversion on every C11 implementation. Require the binary64 target
properties explicitly and test the supported toolchain. C11 sections 6.4.4.2,
7.12, 7.21 and 7.22 specify the relevant literal, math, formatting and conversion
interfaces; [the standard draft](https://www.open-std.org/jtc1/sc22/wg14/www/docs/n1570.pdf)
does not itself promise every platform's correctly rounded decimal conversion.
[Rust's parsing documentation](https://doc.rust-lang.org/std/str/trait.FromStr.html#input-format-and-round-tripping)
also makes the input grammar and round-trip promise explicit rather than
assuming every formatter/parser pair provides them.

## Executable verdict and granular checks

The integer addition fixture consumes two lines. Integer and Float operation
fixtures consume three lines: operation, first operand, second operand.
There are no prompts. Success prints the formatted result and LF, exits zero,
and has empty stderr. Invalid operands print `invalid integer` or `invalid float`
and LF; missing required input prints `missing input` and LF; unknown operations
print `unknown operation` and LF. These cases exit one with empty stderr.
Read and validate left to right: decode the operation before reading operands,
then validate the first operand before reading the second. Unknown operation
alone therefore reports `unknown operation`; an invalid first operand followed
by EOF reports the numeric error. A valid first operand with no second line
reports `missing input`. Extra lines are ignored. CRLF is not silently adapted; preserved CR fails strict
conversion or operation selection. The last nonempty unterminated operand works.

Extend the existing e2e harness directly with explicit stdin/status/stdout/stderr
cases. Compile the pilot once, compile each fixture once, link its unmodified C
once, then run that binary for each input using the existing process BytesStdin
API. Old examples become one-case examples. Keep -O0, strict C11, ASan and UBSan.
No Python, native assertion driver, rewritten C, alternate entrypoint or cache.

Granular tests cover selective type/constructor imports and ambiguities; builtin
role identities and exact rejected contracts; numeric grammar, bounds and
signed zero; checked/concrete return types and role translation; lowering;
borrow liveness, fresh Option[String] ownership and exhaustive destruction;
independent malformed-IR verification; conditional runtime fragments and exact
C projection. Runtime behavior is observed through ordinary main fixtures.
The previously approved direct String-runtime C suite may test additions to
that same fragment. It does not authorize a new C test execution framework.
Deliberately break a representative parse bound, input/result projection or
calculation and require the relevant tests to fail before restoring it.

Compiler-expert implementers and separate compiler-expert/code-reviewer and
test-runner reviews are required for each slice. Serial compiled commands use
one coordinated lane. Final gates are all unit/runtime/grammar/tooling suites
under strict leak checking and sanitizers, followed by all e2e fixtures with
timeout zero. Read emitted C for each new runtime family and inspect moderate
input/numeric stress cases using default C limits.

## Cost and handback

Before production changes, freeze current sources, compiler C and executable
under `build/calculator/baseline/`. Source archive SHA256 is
`6d797347ebcd34ca4f84771ae3381c90e3739a81e0ece9c8ee901e91e4f95c40`;
compiler executable SHA256 is
`0e1ba57649bfca7f7625062378dc6e82ffb106ac3d710b47b7f3533e276aa92b`.
The workload is 170 prior executable roots. Three serial paired measurements
must stay within +10% aggregate allocations and retired instructions through
C emission. This is an owned-input proxy, not self-compilation. Compare the
same frozen source/library programs with each compiler's prelude; the added
Float role is an explicit input difference. Prior output should stay identical
except documented necessary type/ABI projection changes. Require balanced
releases and zero leaks. Set new fixture limits from measured costs with headroom.

Aim for at most 2,000 net production lines for the full remaining roadmap,
excluding copied inactive upstream comments but reporting those separately;
report total production and test growth too. Reassess a repeatable cost excess
or a design needing additional mechanisms before extending it. Retain one
results report with commands, input/source/toolchain fingerprints, reviewer
verdicts, raw artifacts, mutation results and limitations. Updating this plan
to complete requires the executable and component tests, not merely source
checking or a successful host build.
