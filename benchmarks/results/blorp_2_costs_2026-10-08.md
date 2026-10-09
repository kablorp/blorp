# Blorp 2 cost limits and measured increments

These measurements run native code for the new compiler, built by the existing
repository compiler. Building that code is outside the measured boundary.
They describe the current host compiler's code generation and runtime; they
do not predict the future self-hosted compiler's cost.

The sections retain each increment's measurements and predeclared ceilings.

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

## Int parameter and nested-call increment: preimplementation guardrails

The next accepted example adds a single declared `Int` parameter, parameter
lookup and nested zero/one-argument calls. Bodies remain one expression;
`main` remains parameterless. Literal spelling stays restricted to 0 and 1.
Recursion, multiple arguments, grouped expressions, bindings, imports and
operators remain outside this increment.

Before implementation, ceilings are **1,450 formatted compiler-source lines**
(current 1,087) and **2,850 suite/support lines** (current 2,302); raw input
fixture lines are reported separately. The new nested-call fixture and a
distinguishable-wrapper ordering fixture each have initial ceilings of
**500 managed allocations** and **40,000,000 retired instructions**. The
existing fixture limits remain 120/22M, 230/26M and 360/32M. Tests cannot raise
them automatically; any excess must be investigated or the increment rescoped.

The proposed boundary represents this unary expression grammar as a typed
base plus call wrappers in inner-to-outer order, without recursive nodes or
a general expression arena. Parsing owns names/spans; checking resolves
parameter scope, signatures and every call's arity/purity before publishing
an opaque checked program. Cycle validation must read all base/wrapper call
edges rather than relying on one outgoing edge per function. The existing
compiler confirms lexical parameter shadowing: an Int parameter can shadow
a global function, and attempting to call that parameter is rejected.

Matched baseline command on the unchanged FRESH host and cached pilot binaries:

```sh
make -C blorp_2 test-compiler
bin/blorp test --suite --timeout 180 \
  blorp_2/test/e2e/test_return_zero.brp \
  blorp_2/test/e2e/test_call_one.brp \
  blorp_2/test/e2e/test_pure_calls.brp
```

All eight callbacks passed. Managed allocations and instruction minima were
108 / 18,984,092; 206 / 19,120,457; 330 / 19,187,041 respectively. Setup reused
the compiler binaries. The host/binary provenance matches the preceding final
artifact table. Raw evidence is retained locally in
`blorp_2/build/guardrails/nested-calls-baseline.log`. The completed increment
and final validation follow.

## Int parameters and nested calls: final validation

The compiler now accepts zero or one explicitly typed `Int` parameter, a
reference to the containing function's parameter, and nested zero/one-argument
calls. `main` remains parameterless. The parsed body is a typed base plus unary
wrappers in inner-to-outer order; the checked body retains resolved identities,
call spans and a parameter slot without spelling-based backend decisions.
All calls use the containing function's scope and purity. Local topological
elimination checks every base and wrapper edge before opaque publication.

Final formatted production source is **1,429 lines**, up **342** from 1,087,
within the 1,450 ceiling. Suite/support source is **2,819 lines**, up **517**
from 2,302, within 2,850. Raw fixtures total **24 lines**, up 12; the separate
fixture boundary prevents treating input programs as test infrastructure.
No ceiling was raised. All compiler functions after source input remain pure;
the source operator scan found no trait-dispatched arithmetic or equality.

Tests-first validation ran the three affected checker/grammar/new-native suites
against unchanged production code: **16 new callbacks failed and 34 existing
callbacks passed**. The finished independent runs each passed **98/98 callbacks
across 14 suites**, normally and with UBSan/leak checking:

```sh
scripts/compiler-build-status
make -C blorp_2 test-compiler
make -C blorp_2 test
bin/blorp test --suite --sanitize=undefined --leak-check --timeout 180 \
  blorp_2/test/unit blorp_2/test/e2e blorp_2/test/test_grammar
```

| Fixture | Baseline allocations | Final allocations / ceiling | Normal instructions / ceiling | UBSan-suite instruction run | Native exit |
| --- | ---: | ---: | ---: | ---: | ---: |
| `return_zero` | 108 | 116 / 120 | 19,028,931 / 22,000,000 | 18,909,522 | 0 |
| `call_one` | 206 | 225 / 230 | 19,165,613 / 26,000,000 | 19,059,011 | 1 |
| `pure_calls` | 330 | 360 / 360 | 19,277,271 / 32,000,000 | 19,173,870 | 1 |
| `nested_calls` | — | 411 / 500 | 19,343,049 / 40,000,000 | 19,280,201 | 1 |
| `nested_order` | — | 447 / 500 | 19,387,484 / 40,000,000 | 19,254,385 | 0 |

The representation and complete-edge validation increase allocations by 8,
19 and 30 on the existing examples; the purity fixture meets its ceiling
exactly, leaving no allocation headroom. Instruction counts remain within
their unchanged limits. No elapsed-time or instruction-speed improvement is
claimed. Each number measures the pilot compiler process, not compilation by
the host or execution of the emitted program. All native programs passed
strict C11/O2 warnings and produced empty stdout/stderr. The three earlier C
outputs remain byte-identical. The retained new C shows the resolved parameter
and wrapper order; ignored parameters receive an explicit `(void)` cast.

All three normal instruction samples, in execution order:

- `return_zero`: 19,138,444; 19,028,931; 19,039,883.
- `call_one`: 20,469,744; 19,165,613; 19,265,117.
- `pure_calls`: 19,374,925; 19,277,271; 19,304,187.
- `nested_calls`: 19,446,559; 19,343,049; 19,365,608.
- `nested_order`: 19,477,163; 19,387,484; 19,462,583.

Samples during the UBSan/leak TestSuite run:

- `return_zero`: 19,095,223; 18,914,864; 18,909,522.
- `call_one`: 19,059,011; 19,079,903; 19,126,716.
- `pure_calls`: 19,386,622; 19,173,870; 19,206,851.
- `nested_calls`: 19,481,570; 19,280,201; 19,299,763.
- `nested_order`: 19,423,054; 19,254,385; 19,338,256.

UBSan instruments TestSuite code and imported pilot modules. Both sets of
instruction samples still use the cached normal `-O2` compiler; the cached
allocation-diagnostic compiler requires zero leaks and has no extra native
UBSan flags. The independent logs and emitted C are retained locally under
`blorp_2/build/guardrails/nested-independent-pgZOn7/`, with scratch evidence in
`/tmp/blorp-2-nested-validation.pgZOn7/`.

Six deliberate source mutations proved detection by Blorp tests:

| Mutation | Failed callbacks |
| --- | ---: |
| Bypass declared purity validation | 6 |
| Bypass call arity validation | 3 |
| Allow parameter calls to resolve to a same-named global | 1 |
| Omit the base call dependency | 4 |
| Stop wrapper dependency checking after the first wrapper | 1 |
| Reverse emitted unary wrappers | 2 of 4 native-suite callbacks |

The last mutation also produced a strictly compiled native program exiting 1
where the ordering fixture requires 0. Checker/emitter sources were restored
byte-for-byte after every mutation; all 32 checker callbacks then passed.
Logs are `nested-mutation-*.log`, with restored evidence in
`nested-mutations-check-restored.log`, under `blorp_2/build/guardrails/`.

One host-compiler obstacle appeared during preparation: a nested `Result`
match in parser construction emitted an assignment from boxed `blorp_Result*`
to `blorp_StackResult`, rejected by Clang. Selecting one typed `Diagnostic`
in the inner match and wrapping it in one `Err` kept the parser logic intact
and compiled correctly. The existing compiler was not modified or rebuilt.
This observation is a bounded follow-up for host Result representation.

The host remained FRESH before and after validation. Source/test/grammar/
Makefile fingerprints were unchanged throughout both final runs. Explicit
setup and both final gates generated **zero compiler C files and zero links**;
cached C, both binaries and manifest retained their hashes, timestamps, sizes
and inodes. Mutation probes and source development occurred before those
final runs and rebuilt the pilot cache when necessary. Code-reviewer and
documenter review approved the final code/tests/docs without outstanding
findings; the test-runner independently verified the gates and cache reuse.

| Final artifact | SHA-256 |
| --- | --- |
| Host `bin/blorp` | `c67d5bb315a67999ec5d608eaa41aab83f8d75e6220b44b936ea2a4849b7ba0a` |
| Shared compiler C | `d668bb653e63d9008bd8114e10d12613a873ba1aca2f40f8b737bebb39926f36` |
| Normal pilot compiler | `6a2ce338c223993aa1399fde7303fa6f0f0417c5ca0695a70f35f780694d642f` |
| Diagnostic pilot compiler | `0d15a15c3417c23bade1a2a7687d3d80ea06dde20fbf12c3981a65e40567cde4` |
| Cache input manifest | `ba60ca39fdcdd469e0f5ec7d7507a4cabfaeff138de7dc9c32f199172f2925be` |

## UFCS increment: preimplementation guardrails

The next increment adds single-line `receiver.function()` calls and chains.
The receiver is any existing expression; it supplies the sole argument.
Explicit method arguments, field access, imports and method-only import
registries remain outside scope. Existing compiler checks establish a current
lookup distinction: `identity.identity()` accepts a local parameter named
`identity` as receiver and resolves the global function as method, while
ordinary `identity(identity)` rejects the shadowed, non-callable parameter.
Parsed unary calls therefore retain explicit direct/receiver notation until
checking. The checked representation and emitter need no syntax distinction.

Before implementation, ceilings are **1,650 formatted compiler-source lines**
(current 1,429) and **3,200 suite/support lines** (current 2,819), with raw
fixtures reported separately. The UFCS and distinguishable-order chain
fixtures each have initial ceilings of **550 managed allocations** and
**40,000,000 retired instructions**. All five existing fixture limits remain
unchanged, including the purity fixture's exact 360-allocation ceiling.
Any excess must be investigated or the implementation rescoped; tests do not
raise limits automatically.

The unchanged FRESH host and warm cached compiler passed all 12 existing
native-suite callbacks before implementation:

| Fixture | Baseline allocations | Instruction samples | Minimum |
| --- | ---: | --- | ---: |
| `return_zero` | 116 | 19,075,429; 18,975,487; 18,939,097 | 18,939,097 |
| `call_one` | 225 | 19,197,741; 19,047,848; 19,045,918 | 19,045,918 |
| `pure_calls` | 360 | 19,326,597; 19,245,999; 19,234,764 | 19,234,764 |
| `nested_calls` | 411 | 19,409,287; 19,273,396; 19,207,368 | 19,207,368 |
| `nested_order` | 447 | 19,420,277; 19,274,187; 19,306,690 | 19,274,187 |

Commands were `make -C blorp_2 test-compiler`, followed by `bin/blorp test
--suite --timeout 180` on the four existing native suite files. Warm preparation
produced no generation or link output. The source/binary provenance matches
the preceding final artifact table. Raw evidence is in
`blorp_2/build/guardrails/ufcs-baseline.log`; the existing-compiler lookup probes
and logs are `ufcs-shadow-probe` and `direct-shadow-probe` under the same ignored
directory.

## UFCS increment: final evidence

UFCS calls, chains and mixed direct/receiver calls are implemented. The parser
retains `DirectCall` or `ReceiverCall` with each unary callee until checking
resolves names; the checked-call representation and emitter remain unchanged.
Receiver names use the caller's scope. UFCS callee names select declared
functions, even when a local parameter shadows the same name; direct calls
continue to reject that non-callable parameter. Imports and UFCS-only import
visibility are deferred.

Formatted compiler source is **1,521 lines** (+92; ceiling 1,650), suite/support
code is **3,147 lines** (+328; ceiling 3,200), and raw fixtures are **36 lines**
(+12). No predeclared ceiling was raised. Tests-first validation observed 15
expected failing callbacks before implementation, including lexical/parser
rejection of dots, semantic UFCS examples and new native-suite callbacks.

Independent final validation passed **114/114 callbacks across 15 TestSuites**
normally, then **114/114** with UBSan and leak checking. Commands were:

```bash
make -C blorp_2 test-compiler
make -C blorp_2 test
bin/blorp test --suite --sanitize=undefined --leak-check --timeout 180 \
  blorp_2/test/unit blorp_2/test/e2e blorp_2/test/test_grammar
```

The runner also verified formatting for all 24 maintained Blorp files,
whitespace, actual emitted C and silent native exit statuses. The seven
fixtures below exit 0, 1, 1, 1, 0, 1 and 0 respectively. All five previous
fixtures' emitted C remains byte-identical to the preceding independent
artifacts. `ufcs_calls` produces the same 299-byte C as `nested_calls`;
`ufcs_chain` produces 368 bytes with `zero(one(1))` in the declared function
identities. Exact-C tests also protect mixed prefix/postfix order and a single
evaluation of each receiver.

| Fixture | Allocations / ceiling | Change from baseline | Minimum retired instructions / ceiling |
| --- | ---: | ---: | ---: |
| `return_zero` | 116 / 120 | 0 | 18,960,906 / 22,000,000 |
| `call_one` | 225 / 230 | 0 | 19,098,986 / 26,000,000 |
| `pure_calls` | 360 / 360 | 0 | 19,274,362 / 32,000,000 |
| `nested_calls` | 414 / 500 | +3 | 19,336,864 / 40,000,000 |
| `nested_order` | 452 / 500 | +5 | 19,396,215 / 40,000,000 |
| `ufcs_calls` | 418 / 550 | new | 19,380,911 / 40,000,000 |
| `ufcs_chain` | 460 / 550 | new | 19,382,338 / 40,000,000 |

The existing purity fixture remains exactly at its allocation ceiling.
The nested-call increases accompany the notation-preserving representation;
no separate phase-allocation attribution was performed.
These costs measure the new compiler processing each input, including CLI
setup, rather than building the host compiler or running the emitted program.

All three normal instruction samples, in execution order:

- `return_zero`: 19,120,573; 19,062,645; 18,960,906.
- `call_one`: 20,387,105; 19,235,497; 19,098,986.
- `pure_calls`: 19,462,775; 19,274,362; 19,289,450.
- `nested_calls`: 19,545,653; 19,336,864; 19,448,431.
- `nested_order`: 19,540,563; 19,458,117; 19,396,215.
- `ufcs_calls`: 19,453,042; 19,474,068; 19,380,911.
- `ufcs_chain`: 21,211,504; 19,398,560; 19,382,338.

Samples during the UBSan/leak TestSuite run:

- `return_zero`: 19,109,012; 19,005,339; 18,972,175.
- `call_one`: 19,148,460; 19,100,029; 19,128,813.
- `pure_calls`: 19,338,973; 19,260,245; 19,244,605.
- `nested_calls`: 19,396,702; 19,299,303; 19,264,361.
- `nested_order`: 19,481,259; 19,361,418; 19,307,744.
- `ufcs_calls`: 19,447,995; 19,281,137; 19,291,985.
- `ufcs_chain`: 19,469,717; 19,335,700; 19,350,964.

UBSan instruments TestSuite code and imported pilot modules. Native cost
samples use the shared normal `-O2` compiler; the allocation-diagnostic
compiler checks for zero leaks without extra native UBSan flags. No elapsed
speed improvement is claimed.

Seven deliberate source mutations demonstrated negative detection:

| Mutation | Failed callbacks |
| --- | ---: |
| Replace receiver notation with direct-call notation | 2 |
| Consume a UFCS suffix but omit its parsed call | 2 |
| Apply direct-call local shadowing to a UFCS target | 1 |
| Bypass caller purity validation | 7 |
| Bypass call arity validation | 4 |
| Check dependencies only for the first unary wrapper | 2 |
| Reverse emitted unary wrappers | 3 of 5 UFCS-suite callbacks |

Reversed emission also changed the strictly compiled chain program's native
exit from the required 0 to 1, with empty stdout/stderr. Sources were restored
byte-for-byte after every probe. The restored parser/grammar tests passed
33/33, checker tests passed 38/38, and the normal cache was rebuilt before
independent final validation. Logs are `ufcs-mutation-*.log` and restoration
logs under `blorp_2/build/guardrails/`.

The unchanged host remained FRESH. Source/test/grammar/Makefile fingerprints
were unchanged throughout independent validation. Warm setup and both final
gates generated **zero compiler C files and zero links**; cached C, both
binaries and the input manifest retained hashes, timestamps, sizes and inodes.
Final logs and actual emitted C are retained locally under
`blorp_2/build/guardrails/ufcs-independent-KqL8kq/`, with fingerprints under
`/tmp/blorp-2-ufcs-validation.KqL8kq/`. Code-reviewer/documenter review approved
source, tests and documentation with no outstanding findings.

| Final artifact | SHA-256 |
| --- | --- |
| Host `bin/blorp` | `c67d5bb315a67999ec5d608eaa41aab83f8d75e6220b44b936ea2a4849b7ba0a` |
| Shared compiler C | `a2cb2fe730346d7bb48b311b97f1f807b5dde81cabd73cba6a35b9e42cf73b06` |
| Normal pilot compiler | `728ba0ca6a9f219893fe33f93df78449f1cd73dcef9cae44cd85d3c4b0b8869c` |
| Diagnostic pilot compiler | `7d32e18ce9a77a66ee46d671463c3c3b2d1ae425933b323b16cd86ccbc625209` |
| Cache input manifest | `518942b682a6c7710ad02453854bede8220647c13b4d7612c78ea74d93bf823c` |
| UFCS chain emitted C | `e18d17a7a48232508b3d657f70f8ec37c8089134714032b518157c563952dc63` |

## Name identity increment: preimplementation guardrails

The authorized increment removes name spellings from published parsed syntax.
One compilation owns one immutable name table. Names carry a nominal `NameId`
and occurrence span; declaration identity remains the separate `FunctionId`.
Semantic checks compare IDs, including parameter names and canonical `main`
and `Int` names. Strings remain available through the owning table for
diagnostics. Source syntax, generated C and diagnostic messages must remain
unchanged. Imports, new language features and a general symbol framework are
outside scope.

Before implementation, formatted source is **1,521 lines**, suite/support is
**3,147**, and raw fixtures are **36**. Ceilings are **1,700 source lines** and
**3,500 suite/support lines**, with fixtures reported separately. Aim to keep
source growth below 100 lines. All seven existing e2e allocation/instruction
limits stay unchanged, and matched allocation counts must not exceed the
fresh baseline counts. A matched candidate's minimum retired instructions
must also remain within **2%** of each fresh baseline minimum below; any
repeatable excess must be investigated or the implementation rescoped.

Independent baseline validation passed **17/17 native-suite callbacks** using
the unchanged FRESH host and both warm cached `-O2` compiler modes. All seven
native exit/silence checks and exact C/CLI diagnostic oracles passed. No source,
test or limit changed. The 34-file source/test/docs/build snapshot is retained
under `blorp_2/build/guardrails/name-ids-baseline/`, including the four compiler
cache artifacts. Baseline report, all samples, hashes and metadata are under
`blorp_2/build/guardrails/name-ids-baseline-validation/`.

| Fixture | Allocations | Three instruction samples | Minimum | Additional 2% instruction ceiling |
| --- | ---: | --- | ---: | ---: |
| `return_zero` | 116 | 19,011,301; 18,938,643; 19,288,819 | 18,938,643 | 19,317,415 |
| `call_one` | 225 | 19,217,979; 19,061,521; 19,439,435 | 19,061,521 | 19,442,751 |
| `pure_calls` | 360 | 19,351,458; 19,240,289; 19,230,034 | 19,230,034 | 19,614,634 |
| `nested_calls` | 414 | 19,469,900; 19,329,696; 19,300,319 | 19,300,319 | 19,686,325 |
| `nested_order` | 452 | 19,436,857; 19,273,314; 19,312,448 | 19,273,314 | 19,658,780 |
| `ufcs_calls` | 418 | 19,451,298; 19,351,427; 19,326,483 | 19,326,483 | 19,713,012 |
| `ufcs_chain` | 460 | 20,388,143; 19,292,626; 19,341,207 | 19,292,626 | 19,678,478 |

The host and baseline cache hashes match the preceding UFCS final artifact
table. Warm preparation and the baseline gates produced zero compiler C
generations or links. Reproduction is `make -C blorp_2 test-compiler`, followed
by `bin/blorp test --suite --timeout 180` on `test_return_zero.brp`,
`test_call_one.brp`, `test_pure_calls.brp`, `test_nested_calls.brp` and
`test_ufcs.brp` under `blorp_2/test/e2e/`.

The pilot cannot self-compile its current implementation, whose imports,
types and helpers exceed its supported input grammar. These seven fixed
inputs measure its owned compilation boundary as a proxy; they do not verify
self-compilation costs. No broader existing-host self-compilation measurement
would establish the pilot refactor's cost. Final candidate evidence follows.

### Rejected parser-local result-pair experiment

The initial implementation compiled and passed the three name-table API
callbacks after simplifying a nested diagnostic expression rejected by the
host compiler. New API tests had first failed compilation because the names
module did not exist; this was a structural API red check, not a behavioral
failure. Raw evidence is `name-ids-red.log` and `name-ids-names-initial.log`.

The first full native cost run passed 15 of 17 callbacks; call-one and purity
failed their existing allocation ceilings. All seven matched allocation
counts grew, so the model was rejected without changing any ceiling.

| Fixture | Rejected allocations | Increase | Three instruction samples | Minimum |
| --- | ---: | ---: | --- | ---: |
| `return_zero` | 118 | +2 | 20,168,814; 18,982,892; 18,938,679 | 18,938,679 |
| `call_one` | 231 | +6 | 19,237,609; 19,102,094; 19,103,482 | 19,102,094 |
| `pure_calls` | 370 | +10 | 19,359,213; 19,198,130; 19,320,163 | 19,198,130 |
| `nested_calls` | 428 | +14 | 19,427,169; 19,276,939; 19,355,572 | 19,276,939 |
| `nested_order` | 464 | +12 | 19,420,009; 19,407,591; 19,322,101 | 19,322,101 |
| `ufcs_calls` | 430 | +12 | 19,384,763; 19,291,153; 19,292,760 | 19,291,153 |
| `ufcs_chain` | 468 | +8 | 19,463,422; 19,283,547; 19,310,204 | 19,283,547 |

Generated C confirms that `InternedName` allocates on both the existing-name
and new-name branches, and `NameContents` is another managed record. This
establishes those mechanisms but does not attribute the entire process delta.
The rejected source/C/cost log is retained under
`blorp_2/build/guardrails/name-ids-rejected-parser-pair/`; the full gate log is
`blorp_2/build/guardrails/name-ids-early-costs.log`.

Before the next implementation, the bounded hypothesis is to remove both
wrappers: make `NameTable` an opaque spelling list, produce canonical IDs
once in `InitialNames`, update the table alone, and perform a fallible ID
lookup before parser publication. The parser retains the canonical IDs as
inline data and publishes them alongside its table. This removes redundant
managed containers while retaining one spelling authority. The extra frontend
scan must satisfy the same allocation and instruction limits; an impossible
lookup miss must report an explicit internal diagnostic. No token/AST
projection pass, lexical interning or new language feature is introduced.

### Final name-ID evidence

The accepted representation has one opaque `NameTable` backed by the spelling
list. `InitialNames` supplies the table and its canonical IDs once; parser
construction retains those identities as inline data. Interning updates the
table alone, and ID lookup occurs before publication. Only parsing can
construct opaque `ParsedProgram`, which binds names, canonical identities,
functions and the end span together. Written names contain only `NameId` and
occurrence span. `find_function`, parameter matching, and `main`/`Int` checks
use IDs. The sole spelling lookup in checking renders UFCS arity help and
reports an explicit internal diagnostic if it fails. Checked data, emission,
lexer and command shell remain unchanged.

Formatted source is **1,662 lines** (+141; ceiling 1,700), suite/support code
is **3,439** (+292; ceiling 3,500), and raw fixtures remain **36**. The goal of
source growth below 100 lines was missed; the hard ceiling held. The new name
authority, sealed publication and explicit lookup-failure handling account
for the required source boundary. This change does not claim a production
line reduction. Grammar and all seven raw inputs are unchanged.

Independent final validation passed **120/120 callbacks across 16 TestSuites**
normally, then **120/120** with UBSan and leak checking: 76 unit, 26 grammar
and 18 end-to-end callbacks per run. All previous 114 callbacks remain, with
four name-identity tests and two checking regressions added. Commands were:

```bash
make -C blorp_2 test-compiler
make -C blorp_2 test
bin/blorp test --suite --sanitize=undefined --leak-check --timeout 180 \
  blorp_2/test/unit blorp_2/test/e2e blorp_2/test/test_grammar
```

All seven actual C files compare byte-identical to the matched pre-refactor
baseline. Strict C11/O2 native linking, exit statuses 0/1/1/1/0/1/0, empty
stdout/stderr, exact rejected CLI diagnostics and output preservation passed.
Formatting passed for all 26 maintained Blorp files; raw fixtures and ignored
build files were excluded. Whitespace checks passed.

| Fixture | Final allocations | Change | Normal minimum instructions | Additional ceiling |
| --- | ---: | ---: | ---: | ---: |
| `return_zero` | 116 | 0 | 19,067,153 | 19,317,415 |
| `call_one` | 225 | 0 | 19,148,340 | 19,442,751 |
| `pure_calls` | 360 | 0 | 19,262,967 | 19,614,634 |
| `nested_calls` | 414 | 0 | 19,343,058 | 19,686,325 |
| `nested_order` | 449 | -3 | 19,338,957 | 19,658,780 |
| `ufcs_calls` | 416 | -2 | 19,340,184 | 19,713,012 |
| `ufcs_chain` | 453 | -7 | 19,403,790 | 19,678,478 |

No allocation count exceeds its matched baseline, and all existing e2e
ceilings remain unchanged. Normal minimum instruction increases range from
0.07% to 0.68%, within the predeclared 2% allowance. The purity fixture still
uses its exact 360-allocation ceiling. No elapsed-speed or self-compilation
improvement is claimed.

All three normal instruction samples, in execution order:

- `return_zero`: 19,149,045; 19,073,695; 19,067,153.
- `call_one`: 19,174,861; 19,148,340; 19,183,991.
- `pure_calls`: 19,480,155; 19,293,752; 19,262,967.
- `nested_calls`: 19,487,779; 19,358,595; 19,343,058.
- `nested_order`: 19,521,917; 19,382,283; 19,338,957.
- `ufcs_calls`: 19,498,856; 19,340,184; 19,347,767.
- `ufcs_chain`: 19,564,870; 19,406,023; 19,403,790.

Samples during the UBSan/leak TestSuite run:

- `return_zero`: 19,100,472; 18,959,120; 18,981,345.
- `call_one`: 19,054,557; 19,027,036; 19,075,056.
- `pure_calls`: 19,353,038; 19,570,693; 19,228,413.
- `nested_calls`: 19,406,857; 19,245,498; 19,324,898.
- `nested_order`: 19,440,251; 19,332,632; 19,349,931.
- `ufcs_calls`: 19,395,899; 19,327,245; 19,306,211.
- `ufcs_chain`: 19,417,678; 19,347,056; 19,298,263.

UBSan instruments TestSuite code and imported pilot modules. Both runs
measure retired instructions using the cached normal `-O2` compiler. The
allocation child uses its diagnostic counterpart, which checks for zero leaks
without extra native UBSan flags. These
remain seven-input compilation-proxy measurements; genuine pilot
self-compilation is unsupported.

Tests preserve canonical reuse, case/prefix distinctions, independent table
values, exact occurrence spans, names used in different roles, unknown names,
declaration-order FunctionIds and direct/UFCS shadowing. Four deliberate
name-module faults established negative detection:

| Mutation | Failed callbacks |
| --- | ---: |
| Alias all name IDs | 37 (1 names, 36 checking) |
| Append duplicate spellings | 1 |
| Use the main ID as canonical Int | 2 |
| Lose spelling lookup | 4 (3 names, 1 checking) |

The lost-spelling probe also passed an exact internal-diagnostic assertion
at span 46:50, with the prescribed input-report help, rather than producing
C or default text. Source was restored byte-for-byte after every mutation;
all 44 name/check callbacks passed after restoration. Ignored Blorp
compile-negative probes confirmed `NameId` cannot replace `FunctionId` and
outsiders cannot use opaque `ParsedProgram` conversions. IDs remain ordinals
meaningful only within their owning parse/table; equality and lookup do not
runtime-brand table ownership. Sealed construction is the integrity boundary.

Mutation/rejection logs are `name-ids-mutation-*.log`,
`name-ids-missing-internal-diagnostic.log`, `name-ids-nominal-rejection.log`,
`name-ids-seal-rejection.log` and `name-ids-restored-tests.log` under
`blorp_2/build/guardrails/`. The accepted early cost checkpoint is
`name-ids-rescoped-costs.log`; final independent logs, actual C, fingerprints
and report are under `name-ids-independent-38JDEg/`, with scratch evidence in
`/tmp/blorp-2-name-ids-validation.38JDEg/`.

The unchanged host remained FRESH. Frozen source/test/grammar/Makefile/README
fingerprints and all cache hashes, timestamps, sizes and inodes remained
unchanged throughout warm setup and both final runs. Those runs generated
**zero compiler C files and zero compiler links**. Candidate cache rebuilding
occurred only during development, before final validation. Code-reviewer and
documenter review approved the source/tests/README with no outstanding
findings; the independent test-runner verified the gates and comparisons.

| Final artifact | SHA-256 |
| --- | --- |
| Host `bin/blorp` | `c67d5bb315a67999ec5d608eaa41aab83f8d75e6220b44b936ea2a4849b7ba0a` |
| Shared compiler C | `7a2e261f9eeccf544ddbfedcd31a0725fc9ddf9b7bf848d7bc588435fa81760e` |
| Normal pilot compiler | `b32a9aa14766d4b1e685fe34a32f83f70371de2cf059de6ac8e51bc98ab71e46` |
| Diagnostic pilot compiler | `37ab2096c3ac3be4fd01ecf9a0859c3a5322132d8bf8af025358ce66b9232a20` |
| Cache input manifest | `05526b05766bb07755c8d840887b39ddafaba5f05376bc97a795510c0994314d` |

## Signed integer increment: preimplementation guardrails

This increment starts at `e4fd57d54`. It replaces the `Zero`/`One` value
union with signed 64-bit decimal literal values. The lexer owns spelling and
token boundaries; parsing converts and validates the range before publishing
an `Int`; checking and emission consume that value. Arithmetic operators,
other numeric types and unary negation of expressions are outside this slice.

Before implementation, the production source ceiling is **1,780 lines**
(baseline 1,662), and the suite/support ceiling is **3,900 lines** (baseline
3,439). Raw fixtures are counted separately (baseline 36 lines).
All seven existing e2e allocation and instruction ceilings remain unchanged.
The additional matched allocation ceiling is each fixture's freshly measured
baseline; the additional retired-instruction ceiling is its three-run minimum
plus 2%, rounded down. A repeatable failure requires investigation and a
bounded rescope; limits are not raised during implementation.

A new `return_42` fixture returning 42 has initial limits of **230
managed allocations** and **26,000,000 retired instructions**. Native endpoint
checks must compare full `int64_t` values against independently specified C
constants, rather than depending on the narrowing process-exit conversion.
All previous fixture C must remain byte-identical, and diagnostics must check
message, help and the complete literal's source span. Tests are Blorp
`TestSuite` callbacks, including the native C-harness orchestration.

These are owned-input whole-process compiler measurements. The pilot still
cannot compile its own source; this increment does not present the proxy as
self-compilation or measure a newly built host compiler. Matched baseline
artifacts, samples and cache provenance are captured before compiler edits in
`blorp_2/build/guardrails/int-literals-baseline/`.

Independent baseline validation passed **17/17 callbacks** across five native
suites. All seven C outputs and native exit/silence checks passed. The host
was FRESH with the same SHA-256 as the preceding increment, and warm setup
performed zero C generations and zero links. The snapshot contains 36
source/test/document/build-input files and all four cached compiler artifacts.
Baseline logs and the report are in `int-literals-baseline-validation/` under
the ignored guardrails directory; scratch artifacts are in
`/tmp/blorp-2-int-literals-baseline.nNFQNf/`.

| Fixture | Baseline allocations / additional ceiling | Three-run minimum | Additional instruction ceiling |
| --- | ---: | ---: | ---: |
| `return_zero` | 116 | 18,959,135 | 19,338,317 |
| `call_one` | 225 | 19,050,621 | 19,431,633 |
| `pure_calls` | 360 | 19,223,086 | 19,607,547 |
| `nested_calls` | 414 | 19,301,461 | 19,687,490 |
| `nested_order` | 449 | 19,323,208 | 19,709,672 |
| `ufcs_calls` | 416 | 19,249,908 | 19,634,906 |
| `ufcs_chain` | 453 | 19,278,467 | 19,664,036 |

All three baseline instruction samples, in execution order:

- `return_zero`: 19,043,557; 18,959,135; 18,984,905.
- `call_one`: 19,223,530; 19,053,775; 19,050,621.
- `pure_calls`: 19,329,808; 19,248,028; 19,223,086.
- `nested_calls`: 19,461,659; 19,301,461; 19,305,779.
- `nested_order`: 19,448,651; 20,250,304; 19,323,208.
- `ufcs_calls`: 19,595,986; 19,249,908; 19,307,306.
- `ufcs_chain`: 19,492,749; 19,278,467; 19,310,560.

During design, the user requested `src/prelude_temp.brp` as the temporary
input-program prelude boundary. This same increment may move the currently
needed target `Int` spelling and range constants into that module, with one
authority and a module test. Name IDs remain owned by the names module;
the parser still owns conversion and range rejection. This is a compiler-side
contract, not a claim that target imports, prelude loading or union declarations
are implemented. `Bool` is planned as an ordinary union. The host standard
library remains a temporary compiler dependency. Numerical ceilings above
stay unchanged.

### Rejected initial integer-literal candidate

The behavioral test returning 42 failed before implementation (one new
failure, four existing passes); its log is `int64-literals-red.log` under the
ignored guardrails directory. A structural red test for the new temporary
prelude also ran before that module existed. The first formatted source
checkpoint was 1,788 lines, eight over the ceiling. A duplicate `text` import
also prevented the cached build. Consolidating the import and sharing the
range-failure branch brought production to 1,778 lines. Generated C confirmed
short-circuiting before the guarded multiplication.

The first native gate passed **17/18 callbacks**, but the candidate was rejected:
`pure_calls` used 364 allocations, exceeding its unchanged 360 limit.
All seven existing C outputs and native results were correct. Costs also
exceeded every additional matched allocation ceiling by four allocations per
written literal. Generic integer formatting, a digit substring and eager
construction of an invalid-literal diagnostic were visible in generated C;
the observed count change aligned with these sites. This is mechanism evidence,
not an isolated allocation attribution experiment.

| Fixture | Initial candidate allocations | Initial candidate minimum instructions |
| --- | ---: | ---: |
| `return_zero` | 120 | 18,997,966 |
| `call_one` | 229 | 19,079,332 |
| `pure_calls` | 364 | 19,205,061 |
| `nested_calls` | 418 | 19,239,664 |
| `nested_order` | 461 | 19,283,516 |
| `ufcs_calls` | 420 | 19,257,061 |
| `ufcs_chain` | 465 | 19,338,557 |
| new `return_42` | 123 | 18,940,498 |

Instruction samples, in execution order:

- `return_zero`: 20,227,259; 19,015,593; 18,997,966.
- `call_one`: 19,235,790; 19,079,332; 19,147,679.
- `pure_calls`: 19,365,008; 19,230,845; 19,205,061.
- `nested_calls`: 19,404,720; 19,239,664; 19,833,435.
- `nested_order`: 19,393,222; 19,283,516; 19,320,611.
- `ufcs_calls`: 19,437,367; 19,275,500; 19,257,061.
- `ufcs_chain`: 19,464,365; 19,338,557; 19,343,889.
- `return_42`: 19,168,825; 18,947,941; 18,940,498.

Candidate source, C and logs were preserved before a bounded rescope: construct
diagnostics only on errors and emit directly into the local output builder,
instead of making intermediate integer/body strings. This does not introduce
0/1 fast paths or preserve original spellings after parsing. All numerical
ceilings remain unchanged.

### Revised allocation policy

After reviewing the initial experiment, the user instructed us not to be
strict about small allocation changes: the priorities are doing less work
and keeping code clean and clear. This supersedes the additional
matched-baseline allocation rejection rule above. Matched allocation deltas
remain evidence, not an acceptance ceiling. Existing e2e ceilings serve as
broad regression checks; if necessary, the `pure_calls` allocation ceiling
may deliberately move from 360 to 400, with the actual change recorded here.
Other fixture allocation ceilings and all instruction thresholds are
unchanged. No ceiling changes happen automatically.

Lazy diagnostic construction and direct emission still remove unnecessary
work; they are not justification for allocation-specific literal fast paths
or less readable source. Minimum-value emission uses the standard C
`INT64_MIN` macro rather than constructing an intermediate magnitude.

The next checkpoint had **1,779 production lines**. Exact C and native
results again passed for all eight measured inputs. Its cost suite reported
17/18 passes only because it still used the old 360-allocation purity limit;
that test now deliberately uses **400**, consistent with the user's revised
policy. No other allocation limit changed. All additional instruction
thresholds held. This checkpoint is accepted for correctness-test expansion;
independent final validation follows after the source/tests/documents freeze.

| Fixture | Allocations | Matched change | Minimum instructions |
| --- | ---: | ---: | ---: |
| `return_zero` | 119 | +3 | 18,972,636 |
| `call_one` | 228 | +3 | 19,092,396 |
| `pure_calls` | 363 | +3 | 19,223,450 |
| `nested_calls` | 417 | +3 | 19,261,626 |
| `nested_order` | 459 | +10 | 19,301,623 |
| `ufcs_calls` | 419 | +3 | 19,338,959 |
| `ufcs_chain` | 463 | +10 | 19,328,810 |
| `return_42` | 122 | new | 18,966,031 |

Checkpoint samples (`int64-builder-costs.log`), in execution order:

- `return_zero`: 20,240,439; 19,033,888; 18,972,636.
- `call_one`: 19,196,061; 19,092,396; 19,120,417.
- `pure_calls`: 19,354,231; 19,223,450; 19,295,750.
- `nested_calls`: 19,428,305; 19,261,626; 19,315,331.
- `nested_order`: 19,502,894; 19,301,623; 19,601,230.
- `ufcs_calls`: 19,435,785; 19,400,814; 19,338,959.
- `ufcs_chain`: 19,493,518; 19,750,292; 19,328,810.
- `return_42`: 19,050,330; 18,966,031; 18,970,966.

The user then replaced the temporary string-based type-name export with the
ordinary declaration `type Int = builtin` in `prelude_temp.brp`.
`INT_TYPE_NAME` is removed. Parsing still seeds the known `Int` name before
publication, as it did at the baseline; parsing/resolving target prelude
declarations is a future increment. The proposed correction kept shared
range bounds in the temporary module; host compatibility had not yet been
validated. The pilot still did not read the target declaration. Source and
tests needed to be re-frozen after this correction.

The host then rejected that local builtin declaration: `'type Int = builtin'
can only be used in the standard library` (`int64-prelude-declaration-test.log`).
It also produced ambiguous/nominal `Int` errors when the staged module was
imported by the compiler implementation. No host compiler change or new
contract framework was introduced. The bounded resolution leaves
`src/prelude_temp.brp` as the requested target-source declaration only, and
does not import it into the host-built compiler. Parsing and emission use
the existing host `int` module's range constants, consistent with the pilot's
already documented temporary standard-library dependency.

The staged declaration is not yet an implementation module and cannot be
exercised by a host module-import unit test. Its failed import test was
retained as evidence, not turned into a source-text assertion. Numeric bounds,
name identity and full-width emitted values remain covered by their owning
unit/native tests. Parsing/resolving/loading this target prelude is explicitly
deferred rather than implied to work.

### Final signed-integer evidence

The frozen normal `make -C blorp_2 test` run passed **131/131 callbacks across
17 TestSuites**: 85 unit, 26 grammar and 20 end-to-end callbacks. The final
source directory contains **1,773 lines (+111)**, including the staged target
prelude; suite/support code is **3,764 (+325)** and raw fixtures are **44 (+8)**.
All predeclared line ceilings held. All eight host-compiled implementation
modules retain unit suites; the target-only prelude declaration is explicitly
uncompiled and deferred.

Tests cover signed decimal values, negative zero, both endpoints, adjacent
overflow on each side, long digit runs, malformed independently constructed
tokens, leading zeros, sign adjacency and UFCS/direct argument composition.
Error assertions include message, help and complete token spans. The CLI
overflow test requires exit 1 and exact diagnostic output, and verifies that
failure neither creates C nor overwrites an existing output file.

The Blorp TestSuite in `test/e2e/test_integer_literals.brp` compiles an
independent strict C11/O2 driver using `-fsanitize=undefined` and
`-fno-sanitize-recover=all`. It renames the emitted C entry wrapper and compares
helper returns directly against `INT64_MIN` and `INT64_MAX`, without narrowing
them to process status. The valid driver exits 0 silently. A checked mutation
replaces the actual emitted minimum with zero; the same driver must exit 1
silently. Retained driver/program C is under the ignored guardrails directory
as `int64-endpoint-driver.c`, `int64-endpoint-wrong-driver.c` and
`int64-endpoints.c`. This fault proof is part of the maintained TestSuite.

Normal costs (`int64-full-final.log`):

| Fixture | Allocations | Change | Minimum instructions |
| --- | ---: | ---: | ---: |
| `return_zero` | 119 | +3 | 18,957,287 |
| `call_one` | 228 | +3 | 19,115,564 |
| `pure_calls` | 363 | +3 | 19,281,737 |
| `nested_calls` | 417 | +3 | 19,355,281 |
| `nested_order` | 459 | +10 | 19,360,344 |
| `ufcs_calls` | 419 | +3 | 19,396,972 |
| `ufcs_chain` | 463 | +10 | 19,352,293 |
| `return_42` | 122 | new | 18,986,211 |

All eight broad allocation/instruction ceilings held, including the revised
400-allocation purity limit. All seven additional matched instruction
thresholds held. Allocation deltas are reported under the revised policy;
they are not a rejection threshold. The normal run reused the warm compiler
cache with zero C generations or links.

All three normal instruction samples, in execution order:

- `return_zero`: 19,171,226; 18,957,287; 19,014,534.
- `call_one`: 21,097,729; 19,316,182; 19,115,564.
- `pure_calls`: 19,449,524; 19,281,737; 19,347,083.
- `nested_calls`: 19,528,171; 19,355,281; 19,410,009.
- `nested_order`: 19,540,119; 19,360,344; 19,425,747.
- `ufcs_calls`: 19,464,065; 19,416,594; 19,396,972.
- `ufcs_chain`: 19,482,152; 19,352,293; 19,410,903.
- `return_42`: 19,200,466; 18,986,211; 19,005,599.

Independent final validation audited that frozen normal run and then executed
the complete three-root UBSan/leak suite: **131/131 callbacks across 17 suites**
passed again, with no sanitizer or leak errors. The runner did not redundantly
rerun the already green normal suite. The additional instruction thresholds
and all broad e2e caps held in both runs; allocations were identical between
them. All seven retained existing-fixture C files compare byte-identical to
the frozen baseline, and the retained endpoint C matches its driver input.

Commands for the final worker/independent gates were:

```bash
make -C blorp_2 test
scripts/compiler-build-status
make -C blorp_2 test-compiler
bin/blorp test --suite --sanitize=undefined --leak-check --timeout 180 \
  blorp_2/test/unit blorp_2/test/e2e blorp_2/test/test_grammar
```

All three instruction samples during independent sanitizer validation:

- `return_zero`: 19,127,185; 18,950,927; 18,988,841.
- `call_one`: 19,209,847; 19,127,843; 19,154,411.
- `pure_calls`: 19,385,156; 19,246,331; 19,243,724.
- `nested_calls`: 19,458,254; 19,369,724; 19,331,388.
- `nested_order`: 19,529,706; 19,821,308; 19,318,651.
- `ufcs_calls`: 19,458,517; 19,327,963; 19,335,698.
- `ufcs_chain`: 19,522,585; 19,352,097; 19,349,611.
- `return_42`: 19,160,797; 18,995,914; 19,016,590.

UBSan instruments the host-built TestSuites and imported pilot implementation
modules. The endpoint driver also independently instruments actual emitted C.
The cached native compiler used for instruction children is the normal `-O2`
build; allocation children use its diagnostic counterpart with strict
zero-leak checks, without extra native UBSan flags. The target-only staged
prelude is not compiled or loaded. These remain owned-input compilation
proxies, not pilot self-compilation or elapsed-speed claims.

The host remains FRESH and unchanged. Before/after source, test, README,
grammar and Makefile fingerprints match. All four cached artifacts' SHA-256,
timestamps, sizes and inodes are unchanged across independent warm setup and
sanitizer execution: **zero C generations and zero compiler links**. Formatting
passed for 28 maintained Blorp files, with raw fixtures/build files excluded;
whitespace and diff checks passed. The obsolete-constructor scan found only
the intentionally case-distinct user function `One` in an existing regression.

Code review approved source, tests, README and grammar with zero findings.
The full independent report, hashes, retained C and 48 final instruction
samples are under `blorp_2/build/guardrails/int64-independent-hUuKdf/` and
`/tmp/blorp-2-int64-validation.hUuKdf/`.

| Final artifact | SHA-256 |
| --- | --- |
| Host `bin/blorp` | `c67d5bb315a67999ec5d608eaa41aab83f8d75e6220b44b936ea2a4849b7ba0a` |
| Shared compiler C | `acd5665ff9cd95cc1ef1af7d6e3c084d276b46558d465ce37e1857d583b99513` |
| Normal pilot compiler | `ae4f6c5364a14305fb80caa33da3212d25c7f2d5ba8176b4833f2e86fb7d4b29` |
| Diagnostic pilot compiler | `cebef194dc44c8d880f0aaea78302122bf1c62f273392647f4ee2b20d94a249b` |
| Cache input manifest | `344f814a984c63b4be6eb6f72043eb07aa79493ae25be97672ba807bb2f23d44` |
