# Blorp 2 initial cost limits and lexer cleanup

These measurements run native code for the new compiler, built by the existing
repository compiler. Building that code is outside the measured boundary.
They describe the current host compiler's code generation and runtime; they
do not predict the future self-hosted compiler's cost.

## End-to-end return-zero example

The input is the 23-byte file `blorp_2/test/e2e/fixtures/return_zero.brp`:

```blorp
func main() -> Int:
	0
```

The test builds `blorp_2/src/main.brp` to C once, then builds normal and diagnostic
native compilers from that same C. One diagnostic compiler execution produces
the managed-object allocation count. Three normal compiler executions produce
retired-instruction samples. Each execution starts with no output C file and
must publish exactly `int main(void){return 0;}\n`.

| Metric | Initial clean baseline | Explicit ceiling |
| --- | ---: | ---: |
| Managed allocations, one compiler process | 82 | 90 |
| Retired instructions, minimum of three processes | 18,807,794 | 22,000,000 |

Instruction samples: **20,037,459; 18,807,794; 18,855,287**.
This baseline preceded moving the unchanged input into `e2e/fixtures/`;
commands below use its current location.
The rounded ceilings provide approximately 10% allocation headroom and 17%
instruction headroom. They were chosen for this first example on this host;
they are not project-wide policy. Review intentional changes to the named
`RETURN_ZERO_LIMITS` record in `blorp_2/test/e2e/test_return_zero.brp` as examples
and implementation grow. The test never adjusts its own limits.

Run the check from the repository root:

```sh
scripts/compiler-build-status --quiet
bin/blorp test --suite --timeout 180 blorp_2/test/e2e/test_return_zero.brp
make -C blorp_2 test
```

The test prints actual/ceiling values and all instruction samples. Missing,
malformed, duplicate, or nonpositive counters fail. Allocation diagnostics must
report equal allocations and releases, with zero leaked objects and bytes.
The generated program is subsequently compiled as strict C11 and must exit 0
with empty stdout and stderr. Rejected source must preserve absent/existing
output and produce the exact diagnostic.

Measurement commands inside the Blorp TestSuite are equivalent to:

```sh
bin/blorp compile --no-format blorp_2/src/main.brp -o "$scratch/compiler.c"
clang -O2 -DBLORP_MEMORY_DIAGNOSTICS=0 "$scratch/compiler.c" \
  -o "$scratch/compiler" -lm -lpthread
clang -O2 -DBLORP_MEMORY_DIAGNOSTICS=1 "$scratch/compiler.c" \
  -o "$scratch/compiler-diagnostic" -lm -lpthread
env -u BLORP_LEAK_CHECK -u BLORP_MEMORY_STATS \
  BLORP_LEAK_CHECK=strict "$scratch/compiler-diagnostic" \
  blorp_2/test/e2e/fixtures/return_zero.brp "$scratch/program.c"
env -u BLORP_LEAK_CHECK -u BLORP_MEMORY_STATS \
  /usr/bin/time -l -o "$scratch/instructions.txt" "$scratch/compiler" \
  blorp_2/test/e2e/fixtures/return_zero.brp "$scratch/program.c"
```

Here `scratch` is the test's unique temporary directory. The TestSuite removes
`program.c` before each invocation and the instruction report before each time
invocation, propagating deletion failures. It owns cleanup. Compiler generation
and linking, parent test work, C linking of the generated program, and execution
of that program are outside the measurement. Process startup, arguments,
file I/O, lexing, parsing, checking, emission, and teardown are included.
Allocation counts cover managed ARC objects, not every native `malloc`.
Instructions currently require macOS `/usr/bin/time -l`; startup is a substantial
part of this tiny workload. Other hosts need their own supported counter and
explicit baseline. A missing counter is never a passing zero-cost result.

The five direct cost-reader tests cover complete reports, disabled/malformed
counters, leaks, duplicate instruction counters, and equality/overflow of each
ceiling. Deliberately lowering the end-to-end allocation ceiling to 1 failed
with `82 > 1`. Separately lowering only the instruction ceiling to 1 failed
with `18811602 > 1`. A successful no-op substituted for the normal compiler
also fails because it does not publish a fresh C file.

## Separate lexer cleanup experiment

Hypothesis: reused token/diagnostic constructors and byte-run scanning can make
the lexer easier to read without new per-step wrapper allocations. The lexer
still owns only tokens and spans; grammar and semantic checks stay in their
phases. The final indentation and ordinary-scanning paths are mutually exclusive.

Before implementation, the coordinator chose ceilings of **219 formatted lexer
production lines**, **1,512,000 managed allocations**, and **1,461,121,464 minimum
retired instructions**. These were no production growth and at most 5% cost
growth from the initial samples, not user-specified universal limits. Necessary
unit-test growth is separate from production source growth.

The fixed probe runs five prepared inputs 5,000 times each: **25,000 lexer calls**.
Two inputs are valid; three reject noncanonical zero, invalid indentation, or
CRLF. Allocation counting encloses the loop and result observation, excluding
input preparation and reporting. Instructions cover the complete probe process,
including startup and result observation. Its checksum consumes token kinds,
spellings' lengths, all spans, and diagnostic lengths. Exact unit traces and the
31-case frontend matrix independently protect correctness; the checksum alone
is not a complete correctness oracle.

| Metric | Original lexer | Final clean lexer | Change |
| --- | ---: | ---: | ---: |
| Formatted production lines in `lex.brp` | 219 | 202 | -17 |
| Managed allocations across 25,000 calls | 1,440,000 | 1,390,000 | -3.47% |
| Retired instructions, minimum of three processes | 1,391,792,817 | 1,359,819,291 | -2.30% |
| Result checksum | 6,270,000 | 6,270,000 | equal |
| Objects leaked at process exit | 0 | 0 | equal |

Both variants meet the predeclared ceilings. Both strict diagnostic probe runs
exited 0 with allocations/releases equal. Their whole-process totals are
1,440,010 and 1,390,010 respectively; the ten setup/reporting allocations are
outside the loop allocation interval reported in the table.

| Variant/sample | Retired instructions | Maximum RSS, bytes | Peak footprint, bytes |
| --- | ---: | ---: | ---: |
| Original 1 | 1,394,167,845 | 1,867,776 | 1,196,344 |
| Original 2 | 1,391,792,817 | 1,851,392 | 1,179,960 |
| Original 3 | 1,391,982,538 | 1,851,392 | 1,179,960 |
| Final 1 | 1,361,632,109 | 1,851,392 | 1,179,960 |
| Final 2 | 1,360,161,264 | 1,851,392 | 1,179,960 |
| Final 3 | 1,359,819,291 | 1,867,776 | 1,196,344 |

An intermediate 203-line implementation was rejected: generated C retained a
one-byte slice across the indentation guard and missed a release on its early
`break`/`continue` exits. Unit leak checks found one 34-byte object per affected
scan. Its earlier minimum of 1,351,299,754 instructions and 2,408,760-byte peak
footprint are not accepted evidence for the final implementation. Making the
two scanning paths exclusive removed the extra retained lifetime; the existing
leak-sensitive tests now pass. This exposed a host compiler ownership-lowering
rough edge; existing compiler production was not changed in the pilot.

The final source keeps the original six compiler modules, totaling 568 formatted
production lines. Readability cleanup removed 17 production lines. Test suites,
helpers, and the two-line example fixture total 1,416 formatted lines; tests grew
to provide direct coverage of all six modules and the cost-report reader.
There is no self-compilation workload yet,
and these small probes do not establish a general latency or memory improvement.

## Lexer probe reproduction and provenance

Local artifacts are in `blorp_2/build/lex_refactor/`:
`baseline_src/lex.brp`, `baseline.c`, `baseline`, `baseline-diagnostic`, `clean.c`,
`clean`, `clean-diagnostic`, `measure.brp`, and the allocation/leak/time/output logs.
`baseline-final-time-{1,2,3}.txt` and `clean-time-{1,2,3}.txt` hold the table above.
This directory is ignored. The original lexer was an uncommitted pilot snapshot;
its historical source and binaries require those local artifacts. The retained
numbers and hashes below survive removal of that directory. The current probe
can be reproduced by saving the Blorp code below as
`blorp_2/build/lex_refactor/measure.brp`.

The original C was generated while the original lexer occupied `src/lex.brp`;
`baseline_src/` records that input, without rewriting any other compiler source.
The final C was generated from the current lexer. Commands from the repository
root, with `variant` set to `baseline` or `clean`, were:

```sh
bin/blorp compile --no-format blorp_2/build/lex_refactor/measure.brp \
  -o "blorp_2/build/lex_refactor/$variant.c"
clang -O2 -DBLORP_MEMORY_DIAGNOSTICS=0 "blorp_2/build/lex_refactor/$variant.c" \
  -o "blorp_2/build/lex_refactor/$variant" -lm -lpthread
clang -O2 -DBLORP_MEMORY_DIAGNOSTICS=1 "blorp_2/build/lex_refactor/$variant.c" \
  -o "blorp_2/build/lex_refactor/$variant-diagnostic" -lm -lpthread
BLORP_MEMORY_STATS=1 "blorp_2/build/lex_refactor/$variant-diagnostic"
BLORP_LEAK_CHECK=strict "blorp_2/build/lex_refactor/$variant-diagnostic"
/usr/bin/time -l "blorp_2/build/lex_refactor/$variant"
```

The original normal build omitted the explicit diagnostic define; its generated
runtime defaults to 0, so both normal builds used diagnostics disabled. Compiled
probes ran serially. The host remained FRESH at repository base
`98983aa8f512`; pilot sources were untracked. Toolchain: Apple Clang 21.0.0
(`clang-2100.3.34.2`), arm64, macOS 26.7.1 (`25G241`).

SHA-256 provenance:

| Artifact | SHA-256 |
| --- | --- |
| Host `bin/blorp` | `01c8076eef05460432b9c01771915fdfc09b29876f2849fb85b724aa2f0efada` |
| Pilot `src/check.brp` | `43ea4855539ef67962ac692430b57acf5df6938af8f684afc96933c2cb4044a9` |
| Pilot `src/emit.brp` | `b00cc7bdf478607d51e5eb68700047214b3c3275356c5b4893414198d64a7ea4` |
| Pilot `src/main.brp` | `71471fe157b183347549c04ce63b4c09946b4ff9340ec0ba24fe9e6059f5823d` |
| Pilot `src/parse.brp` | `f366a1e869198dba4a2d790f2ce65e4d1fe7b30f4b9f12a5fa9644e63d7aaee2` |
| Pilot `src/syntax.brp` | `a01ce04cc4d2e24b1482880df222aaeab5091fa787c98d2080c6eba3c58164e8` |
| Return-zero input | `51f11cef22e25bf44d65a974bd75b598e845fedf7209838c97a8c863746092e9` |
| End-to-end TestSuite source at baseline, before fixture move | `f9ee7d54330e0f93d53adcc8d5c58d7559c464b4caeea04efdef4a9336915207` |
| Original `lex.brp` | `f409371713dee91cb0a525552ef2e2fc0f5fd9388db872f3f26e38b3e95dd0f2` |
| Final `lex.brp` | `c507a193379e06ad43bbba034c713b8041e3e0964cd1f4dfb876208eb35595c6` |
| Probe source | `26d2e98add92c2da0bbe21267250c560c6937fe1acdfbc2f8f1231abee82f714` |
| Original generated C | `ed57fa6279d13c325b3c3aae818ad43fa6439ec9cc1e09bfbd9f36fd6d54b35e` |
| Final generated C | `b7b83cbc28acf41286efbce75e5b9274596fe373b526ff2f2c4684d6e7209835` |
| Original normal binary | `f23d8ae3d1e595953da854c3058158027a1a56d0df0b6c28ca1f8975d4adb887` |
| Original diagnostic binary | `e07decb27625e7108a9925708a895e22183d7d8854fbf7991f03170709572c70` |
| Final normal binary | `addb927cffda223d5c252d9ae848135832f985ec5b2df65c489f25627b975881` |
| Final diagnostic binary | `10eea81b428567d89c07595469ae15b36f245b08a4baed10793ebbf033a53d48` |

Probe source (a measurement executable, separate from the `TestSuite` tests):

```blorp
import:
	../../src/lex: lex
	../../src/syntax:
		Diagnostic,
		LexedProgram,
		Symbol(FunctionKeyword, LeftParen, RightParen, Arrow, Colon, Newline, Indent),
		TokenKind(IdentifierToken, SymbolToken, ZeroLiteral),
	memory: MemoryCounter(ManagedAllocations, MemoryStatsActive), read_memory_counter


pure func observe(result: Result[LexedProgram, Diagnostic]) -> Int:
	match result:
		Err(diagnostic):
			diagnostic.span.start + diagnostic.span.end + diagnostic.message.length() + diagnostic.help.length()
		Ok(program):
			var checksum: Int = program.end.start + program.end.end

			for token in program.tokens:
				weight: Int = match token.kind:
					IdentifierToken(name):
						name.length()
					ZeroLiteral:
					8
					SymbolToken(symbol):
						match symbol:
							FunctionKeyword:
							1
							LeftParen:
							2
							RightParen:
							3
							Arrow:
							4
							Colon:
							5
							Newline:
							6
							Indent:
							7

				checksum += weight + token.span.start + token.span.end

			checksum


func main(args: List[String]) -> Int:
	sources: List[String] = [
		"func main() -> Int:\n\t0\n",
		"func main ( ) -> Int : \n    0",
		"func main() -> Int:\n\t00\n",
		"func main() -> Int:\n     0\n",
		"func main() -> Int:\n\t0\r\n",
	]
	active: Int = read_memory_counter(MemoryStatsActive)
	before: Int = read_memory_counter(ManagedAllocations)
	var checksum: Int = 0

	for iteration in 0..5000:
		for source in sources:
			checksum += observe(lex(source))

	after: Int = read_memory_counter(ManagedAllocations)
	print("checksum=" + "".append_int(checksum))
	print("counter_active=" + "".append_int(active))
	print("allocations=" + "".append_int(after - before))
	0
```
