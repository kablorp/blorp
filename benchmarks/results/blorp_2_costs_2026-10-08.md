# Blorp 2 cost limits and measured increments

These measurements run native code for the new compiler, built by the existing
repository compiler. Building that code is outside the measured boundary.
They describe the current host compiler's code generation and runtime; they
do not predict the future self-hosted compiler's cost.

The final section records the purity increment with its predeclared ceilings.
Earlier sections retain the initial and function-call measurements.

## Initial end-to-end return-zero example

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

## Function-call increment and deliberate ceiling update

The sections above record the original return-zero increment. Its constant C
string and 90-allocation ceiling are historical. The current compiler supports
multiple zero-argument functions, the literals 0 and 1, and resolved acyclic
calls. All functions return 64-bit values; a separate C entrypoint wrapper
converts the checked main result into the process exit status. Prototypes and
symbols come from compilation-local function identities, not written names.
Compiler source also now calls concrete operations directly instead of using
trait-dispatched operators.

The same whole-process boundary and normal/diagnostic build separation remain.
Two reviewed allocation ceilings replace the initial estimates; instruction
ceilings remain unchanged. Measured samples from the first valid fixture run:

| Fixture | Managed allocations | Allocation ceiling | Retired instructions, minimum of three | Instruction ceiling |
| --- | ---: | ---: | ---: | ---: |
| return_zero | 107 | 120 | 18,938,270 | 22,000,000 |
| call_one | 204 | 230 | 19,002,845 | 26,000,000 |

Return-zero instruction samples: **20,304,272; 18,938,270; 18,948,831**.
Call-one instruction samples: **20,420,810; 19,106,600; 19,002,845**.
The original estimates (90 and 180 allocations) failed before being changed.
Both diagnostic compiler processes had equal allocations/releases and no leaks.
A cost excess still fails the test after native behavior and rejected-output
preservation are verified; missing/malformed measurements fail immediately.

A separate Blorp `TestSuite` probe brackets the four unchanged stage APIs with
`read_memory_counter(ManagedAllocations)`. Scalar counter reads allocate no
report records. Reporting happens after the final stage read. The old sources
are exact copies from commit `8bfd6a13f78d4b443ed95c86f222ea01056e0de3`, compiled
with the same current host compiler as the candidate. Its input is the same
23-byte return-zero source. The candidate is also probed on the call fixture.

| Compiler/input | Lex | Parse | Check | Emit | Pipeline total | Generated C bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Original/zero | 57 | 17 | 0 | 0 | 74 | 26 |
| Candidate/zero | 59 | 22 | 4 | 14 | 99 | 128 |
| Candidate/call | 121 | 44 | 5 | 26 | 196 | 196 |

The zero pipeline's **25 additional allocations** account exactly for the
whole-process increase from 82 to 107; both retain eight shell/startup/I/O
allocations outside the stage interval. Lexing adds two allocations after
introducing the closed integer-literal payload and constructing the combined
identifier character set locally (the host CTFE cannot evaluate its concrete
concatenation call as a global initializer). Parsing publishes a function list,
function/body results and complete program rather than one function's fields,
adding five. Checking builds four objects for the validated collection and
resolved integer meaning, replacing its old immediate zero variant. Emission
now constructs prototypes, function bodies and the entrypoint wrapper, adding
14 rather than returning one static string. This is a representation and
working-example expansion, not an allocation optimization. The reviewed
ceilings provide about 12% headroom around those observed costs. There is no
return-zero special case in the parser, checker or emitter.

Reproduction from the repository root:

```sh
bin/blorp test --suite --timeout 180 blorp_2/test/e2e/test_return_zero.brp
bin/blorp test --suite --timeout 180 blorp_2/test/e2e/test_call_one.brp
bin/blorp test --suite --leak-check --timeout 180 \
  blorp_2/build/guardrails/test_phase_allocations.brp
```

The last probe and old-source copies are local ignored artifacts; retain them
when reproducing exact phase attribution. Raw output is in
`blorp_2/build/guardrails/phase-allocations.log` and
`blorp_2/build/guardrails/function-calls-e2e.log`. The e2e suites and their shared
harness are retained source. Format suite files, not raw fixtures: the host
formatter inserts blank lines between declarations, outside this increment's
explicit grammar.

Provenance: arm64 macOS, Apple Clang 21.0.0, repository HEAD `8bfd6a13f78d4`,
with the working function-call/trait-free sources. All compiled commands ran
serially. The FRESH host executable also contains the independent coverage
feasibility changes; the stage probe's baseline and candidate use that same
executable. SHA-256:

| Artifact | SHA-256 |
| --- | --- |
| Host `bin/blorp` | `33f0a827dea39ac77b48d081393582966f2263114faa95fa9158782c9cbe9957` |
| Phase probe | `33c130658846799d5e6b95190d18ae934dafaa034f5b10a90e4ef9587dd38041` |
| Return-zero input | `51f11cef22e25bf44d65a974bd75b598e845fedf7209838c97a8c863746092e9` |
| Call-one input | `3628492b67f2f6224cb09ada608b9763b8f64aad999d3ea70c2fb8a93b4efd31` |
| Candidate `check.brp` | `db42f837535841821ae67d2f9c30a65619b389774c3c693c8b0f4e0640408578` |
| Candidate `emit.brp` | `fde7a813f0ebb9750eb155ee0c627a327115b655a680677aa10ef5e457d17a50` |
| Candidate `lex.brp` | `3af0a2263226d0dc45dd6d50fd06e677524d30bb0448938d02e92a401bbbcbe3` |
| Candidate `main.brp` | `fc84573a765ec7ef31740f449bc0bc6ab0605bb1d4839433c8aa083cb1560657` |
| Candidate `parse.brp` | `d8a3b4e477b317f8c1cd12291573ed569787ba6f311789829e1fced8b7b00f4b` |
| Candidate `syntax.brp` | `40bacff05cf22c228d2b868fe05cadcabbd9aa88a7d46a597918df53d15120de` |
| Candidate `text.brp` | `866aaa837a5b6ea81785f3efaeb6b8c0e2d8c354e0ae20003cb0424f9ceebd89` |

The function-call checkpoint totals **1,009 formatted production lines**, up 441 from the
original six-module compiler. This includes the required concrete-operation
foundation, typed declaration/call boundaries, signature/cycle validation, C
symbol projection and entrypoint wrapper. Its accepted ceiling was deliberately
respecified to 1,020 after the explicit no-traits requirement and host loop
propagation constraint were accounted for; no compressed formatting was used.

## Pure-function increment

The next fixture is the 91-byte `blorp_2/test/e2e/fixtures/pure_calls.brp`:

```blorp
pure func one() -> Int:
	1
pure func answer() -> Int:
	one()
func main() -> Int:
	answer()
```

Purity is declared, not inferred: an unannotated function is impure. Each
published checked function retains its validated purity beside its resolved
body. Checking rejects a pure-to-impure call at the callee name, including
edges in unreachable helpers. Checking every edge also protects transitive
pure chains. A pure main is accepted; emission uses the same C ABI and adds no
purity attributes or semantic checks.

The fixture's ceilings were declared before implementation: 360 managed
allocations and 32,000,000 retired instructions. Existing ceilings stay at
120/22,000,000 for return-zero and 230/26,000,000 for call-one.
The first complete run, `make -C blorp_2 test`, passed **71 of 71 tests**:

| Fixture | Managed allocations | Allocation ceiling | Retired instructions, minimum of three | Instruction ceiling |
| --- | ---: | ---: | ---: | ---: |
| return_zero | 108 | 120 | 18,848,149 | 22,000,000 |
| call_one | 206 | 230 | 19,001,936 | 26,000,000 |
| pure_calls | 330 | 360 | 19,146,615 | 32,000,000 |

Pure-call instruction samples: **20,393,773; 19,146,615; 19,160,868**.
The normal and diagnostic native compiler builds use the same generated C;
diagnostic processes require equal allocations/releases and zero leaks. Native
execution of the emitted pure-call C returned 1 with empty stdout/stderr.
The shared harness checked the exact compact C, compiled it as strict C11,
and verified rejected-input output preservation before enforcing the budgets.
These are whole-process costs at the same boundary as the preceding increments;
there was no new phase-attribution probe or optimization claim.

Final formatted source totals **1,087 production lines**, a net addition of
78 to the function-call checkpoint, below the predeclared ceiling of 1,129.
Test suite/support source totals **2,302 lines**, excluding 12 input-fixture
lines (2,314 total test `.brp` lines), a net addition of 158, below 2,324. The
production addition covers declared purity, parser handling, retained checked
function data and edge validation. The tests cover reserved/maximal identifiers,
malformed qualifiers, default impurity, checked purity publication, direct,
transitive and unreachable violations, pure main, and native/cost behavior.

The first complete run was recorded in the integration tool transcript, not a
saved log. After that run, review caught the host formatter splitting long
diagnostic help into trait-dispatched string `+` operations. The final source
uses a small concrete `concat` helper with the same diagnostic bytes. The final
source was formatted and scanned for excluded operators, then independently
passed 71/71 normal and 71/71 UBSan/leak tests. After separating coverage onto
its own branch and rebuilding the existing compiler, another final pair passed
71/71 with the shared compiler preparation below. Retained logs are
`blorp_2/build/guardrails/pilot-branch-final-test.log` and
`blorp_2/build/guardrails/pilot-branch-final-sanitize.log`. The older
`pilot-complete-test.log` records the prior 61-test increment and must not be
used as purity evidence.

Reproduction after building a FRESH repository compiler:

```sh
bin/blorp test --suite --timeout 180 blorp_2/test/e2e/test_pure_calls.brp
make -C blorp_2 test
```

First-run provenance: arm64 macOS, Apple Clang 21.0.0, repository HEAD
`8bfd6a13f78d4b443ed95c86f222ea01056e0de3` with uncommitted pilot and independent
host coverage changes. The host was FRESH for the 71-test run; all compiled
commands were serialized. SHA-256 distinguishes the measured parser from its
equivalent final diagnostic correction:

| Artifact | SHA-256 |
| --- | --- |
| Host `bin/blorp` at measured run | `85ee8dbb179dbb8b793eae090bb506777eae4b545d16434208e2decfbada95f3` |
| `check.brp` | `713a6e937d0f39e65984c3d38c6afb4438ea1a41041485fa4f76f1429d6d718a` |
| `emit.brp` | `c25ddf7e81370a216cfe29d8e9ca7d3cd27a110ad4ddce7fc89f29e937568011` |
| `lex.brp` | `f944d2573fec942af7d229a92fd8a5da26b5b804189e9b69d541daa7a5eaf1ef` |
| `main.brp` | `fc84573a765ec7ef31740f449bc0bc6ab0605bb1d4839433c8aa083cb1560657` |
| `parse.brp` at measured run | `103b5ce48b3e77c4b2272cd925f587de6d0fddd155e3f31274c713665e35f8b4` |
| Final `parse.brp` | `8c2bc7f0f52e0208a32019af4fa3b6606accdea5c910080919305c2d9913d743` |
| `syntax.brp` | `fb1982f4a9453577118614b9de071838dfa359720036300754d0917b53acbb00` |
| `text.brp` | `866aaa837a5b6ea81785f3efaeb6b8c0e2d8c354e0ae20003cb0424f9ceebd89` |
| Grammar | `af6d3af40b6d523eb9c620a70228703d70f8ec453738d31b78bf012f03b4d424` |
| Pure-call input | `d02ec1eb550e4d87cb2d0f3ac65ea6f264755f5acb22197809449028d896e9d4` |
| Pure-call suite | `22f5cf52ad852fd5eeb90ba756dfdb1a298b7482bef6d4830bc237a88ca3ffa7` |

## Shared end-to-end compiler preparation and final validation

The native harness previously regenerated and linked the same pilot compiler
for each of the three fixtures. `make -C blorp_2 test-compiler` now owns one
generated C file and normal/diagnostic binaries under the ignored build
directory. Its manifest includes source and host-executable hashes, the
Makefile, the resolved C compiler path/version and both modes' flags. Each
fixture obtains immutable binary paths through the cached target and retains
its own temporary C, native execution, allocation check and three instruction
samples. The formatted harness shrank from 260 to 244 lines; the Makefile
grew by 40 lines for cache configuration/preparation, outside the compiler-source
count.

The cold target generated C once and linked the two modes once. The warm target
produced no output and left C, binaries and manifest timestamps unchanged.
Source and flag changes separately forced regeneration and both links.
Review found that a failed second link could leave an old manifest beside a
new normal binary; restoring the original source then falsely reused that
binary. The actual failure probe disabled purity checking, forced the second
link to fail, restored the source and demonstrated acceptance of an invalid
pure call. The corrected refresh removes the previous manifest before any
artifact replacement. Repeating the probe left no manifest, forced both links
after source restoration, and rejected the invalid call with its exact purity
diagnostic. All temporary source changes were restored byte-for-byte.

Independently validated final runs on the `blorp-2` branch, with coverage
changes excluded:

| Fixture | Managed allocations / ceiling | Normal instructions, minimum / ceiling | UBSan/leak-run instructions, minimum | Native exit |
| --- | ---: | ---: | ---: | ---: |
| return_zero | 108 / 120 | 18,957,348 / 22,000,000 | 18,936,354 | 0 |
| call_one | 206 / 230 | 19,144,165 / 26,000,000 | 19,066,760 | 1 |
| pure_calls | 330 / 360 | 19,204,477 / 32,000,000 | 19,200,943 | 1 |

Normal samples, in fixture order: return-zero 19,144,063; 18,957,348;
19,023,368. Call-one 19,171,780; 19,169,059; 19,144,165. Pure-calls
19,447,387; 19,204,477; 19,287,294. Both runs passed **71/71 callbacks across
13 suites**, with no UBSan failures or leaked objects. The native fixture
checks retained exact compact C, strict C11/O2 compilation, expected exits,
empty stdout/stderr and rejected-output preservation. Neither run generated
or linked the shared compiler; all four cached artifacts retained their
hashes, timestamps, sizes and inodes. No elapsed-time improvement is claimed.
UBSan covers the TestSuite executables and their imported pilot code; the
shared native pilot binaries retain their normal `-O2` and allocation-diagnostic
build modes, with strict leak checks rather than additional native UBSan flags.

The explicit purity-edge mutation also removed validation, causing exactly the
direct, transitive and unreachable-call negative tests to fail; byte-exact
restoration passed all 15 checker tests. The retained logs are
`purity-edge-mutation.log` and `purity-edge-restored.log` under
`blorp_2/build/guardrails`.

Final host provenance: FRESH before/after, arm64 macOS, Apple Clang 21.0.0,
bootstrap `dev-0e1598ed616e`, CLI `-O0`/runtime `-O2`, eight-way split.
Pilot binaries use `-O2` with explicit memory-diagnostic modes 0 and 1.
Source/test/grammar/Makefile fingerprints stayed unchanged throughout both
final runs. Code-reviewer and test-runner reviews completed before commit.

| Final artifact | SHA-256 |
| --- | --- |
| Host `bin/blorp` | `c67d5bb315a67999ec5d608eaa41aab83f8d75e6220b44b936ea2a4849b7ba0a` |
| Shared compiler C | `cf9f2be568e7f6cb830d75fc4ddc04bf12a7932d3de6bfc760bae26308a23a77` |
| Normal pilot compiler | `113d08555da7d2902e5a86735a0de313a5c36f8f218ac5db0ed17d158422b6db` |
| Diagnostic pilot compiler | `8f87b1dc32fe203ff51a7e2100f5372114c1bdf0d083499f4a13befd6833a334` |
