# Library cost

Plan revision 2, 2026-11-16. Revision 1 (2026-11-12) came from the
`library-cost` pilot, written against origin/main `73f73dfe6` (pilot
measurements against `95f37e437`).

A compile's cost follows the size of the standard library, not the program.
Hello's compile is about 99% library work. Checking also grew superlinearly
in the number of bounded generic functions.

**Status:** option (a) landed as `081fa6570` and `01f27c350`, removing both
superlinear algorithms (see "Option (a) results"). Keith approved option (b),
elaborating library bodies only when they are reached, on 2026-11-16 with
all four recommendations (see "Decisions"); its landing is in review (see
"Option (b) results"). Options (c), (d) and (e) are not recommended.

## Findings

### Where a compile goes

Measured with a measurement-only `--pilot-stop N` option that ends the
compile after step N without rendering anything (the pilot's
`data/reach-and-phase-probe.patch`). Each row is one stop minus the previous,
so it includes releasing that step's product. Lexing and parsing were
separated by compilers that lex, or parse, every module twice; process start
is `blorp help` (`/usr/bin/true` retires 9.2 M on this host).

Hello (`effects/hello.brp`), base `95f37e437`:

| Step | -O0 instr | -O0 allocs | -O2 instr |
|---|---:|---:|---:|
| process start | 13.3 M | – | 13.0 M |
| lex library text (42,942 bytes, 13 modules) | ≈100 M | | ≈10.8 M |
| parse | ≈52 M | | ≈16.0 M |
| read, assemble, release | ≈6 M | | ≈12 M |
| load total | 171.4 M | 46,146 | 51.8 M |
| check up to constants (receivers alone 15.6 M) | 31.8 M | 11,112 | 9.6 M |
| check bodies | 101.9 M | 49,094 | 36.6 M |
| check recursive instantiation | 107.9 M | 5,592 | 11.2 M |
| specialize to write | 4.4 M | 497 | ≈4.6 M |
| total | 417.4 M | 112,489 | 113.8 M |

The prelude reaches 13 modules (`standard_library/prelude.brp`), and all 139
of their function bodies are elaborated, although hello calls one (`print`).
The program's own work, specialize through write, is about 1%.

Self-compile, `-O2`, one run (the pilot worktree's source, within 0.6% of
base, so for shares only):

| Step | instr | share | allocs |
|---|---:|---:|---:|
| load (lex ≈686 M, parse ≈1,026 M) | 1,897 M | 15% | 2.40 M |
| check up to constants | 400 M | 3% | 0.33 M |
| check bodies | 2,546 M | 20% | 3.27 M |
| recursive instantiation through entry | 229 M | 2% | 0.20 M |
| specialize | 1,865 M | 15% | 2.49 M |
| lower | 633 M | 5% | 1.02 M |
| own | 1,742 M | 14% | 1.98 M |
| verify | 983 M | 8% | 1.24 M |
| emit | 2,185 M | 17% | 1.27 M |
| total | 12,539 M | | 14.21 M |

### Bounded generic functions

N copies of `pure func f[E: Equatable](a: E, b: E) -> Bool: a != b` (or
`==`, or an unbounded `True`) beside hello, `-O0`, millions of instructions:

| program | `95f37e437` | closure fix only | both fixes |
|---|---:|---:|---:|
| hello | 412 | 348 | 330 |
| `!=` × 10 / 20 / 40 / 80 | 669 / 1,096 / 2,445 / 7,146 | – / – / – / 580 | 346 / 362 / 399 / 480 |
| `==` × 10 / 20 / 40 / 80 | 462 / – / 659 / 1,029 | – / – / – / 813 | 344 / 359 / 392 / 468 |
| unbounded × 40 / 80 | 433 / 454 | – / – / – / 390 | 351 / 371 |

From 40 to 80 functions, each added `!=` function cost 117.5 M before and
2.0 M after; `==` 9.2 M and 1.9 M; an unbounded one 0.5 M either way. With
both fixes the marginal cost still rises about 10% per doubling; the likely
cause is `dependency_graph`'s linear membership scans, not isolated.

**Why `!=` cost 8 to 11 times `==`.** `!=` calls `not_equals`, which every
implementation inherits as a trait default. For a call on a type parameter,
`append_method_dependencies` adds one dependency per implementation and
type-parameter position, and a default's word is `[pop, push]`, whose inner
position gets its own control in `dependency_graph`. Hello's library has
eight generic Equatable positions (List 1, Dict 2, Option 1, Result 2,
DictContents 2), so each `!=` adds eight controls; `==`'s words are a single
pop and add none. The base closure cost grows with the square of the
control count or faster.

### Root causes

Growth needs a cycle, but the recursion analysis had no representation of
the dependency graph's cycles, and answered both cycle questions with
whole-graph work.

1. **The closure spanned every control.** `bound_instantiation_paths` sized
   each relation as a dense count × count table, built three times, and
   `close_paths` visited every control for every pair it found, over the
   graph of every checked body in every loaded module. Only controls in one
   strongly connected component can pump, and every derivation of a pair
   inside a component stays inside it.
2. **The growth guard did not guard.** `validate_base_dependencies` wrote
   `trait_derived.not().and(operations.is_empty().not().and(target.parameter_reaches(source, dependencies)))`.
   `and` is an ordinary function (`standard_library/bool.brp`), so the
   breadth-first search over every dependency ran for every dependency, not
   only ordinary growing ones.

## Option (a): decide cycles from components

Approved 2026-11-12. Checking only; no README change, no seed rotation.

1. Component closure: `strong_components` (iterative Tarjan over
   compressed successor rows) runs once; the closure runs only over
   transitions whose ends share a component, with controls renumbered in
   their original order and marks mapped back to original positions, so the
   result, including the order of marks, is what the whole graph gives.
2. Growth by components: an ordinary dependency grows without bound
   exactly when its pushing edges' ends share a component of the ordinary
   graph (the dependency graph without trait-derived edges). The same
   component computation answers it, and `parameter_reaches` and
   `contains_parameter_id` are deleted.

### Option (a) results

Host: Apple M4, 10 cores, 32 GB, macOS 26.6, Apple clang; other sessions
ran gates throughout, and every run waited for the shared busy check.
Compilers were built from each revision with the Makefile's recipes. Raw
samples, scripts and logs are in the main checkout's ignored
`build/pilots/2026-11-12/library-cost/data/` (`landing/` for these).

**E2e cost fixture** (`generic/many_bounded/inequality`, hello beside forty
bounded `!=` functions), compiled as the harness compiles it: the `-O0` test
compiler, `BLORP_LEAK_CHECK=strict`, `/usr/bin/time -l`, three runs each
(`data/landing/fixture-cost.tsv`). The ceiling is the larger run plus 15%.

| landing 1 | `73f73dfe6` | landing 1 | ceiling |
|---|---:|---:|---:|
| `inequality`, instructions | 2,496.6 M | 500.1 M | 575.2 M |
| `inequality`, allocations | 127,366 | 123,841 | 142,418 |
| `effects/hello`, instructions | 448.9 M | 384.2 M | 504.2 M, unchanged |
| `effects/hello`, allocations | 109,194 | 108,830 | 120,598, unchanged |

The fixture exceeds its instruction ceiling on the base, 2,497 M against
575 M. Existing ceilings are not reset.

**Gates, landing 1**, against `73f73dfe6`, run before review added unit
tests and comments: `make -C blorp test INSTRUCTION_CHECK=on`,
`scripts/blorp-fixpoint --prove` and `git diff --check` pass. Output identity: 725 inputs (every fixture that
declares `main`, every `trait_inputs` module compiled directly, and
`blorp/src/main.brp`; 128 of them rejections) give byte-identical C, stdout,
stderr and status (`data/landing/g1/identity/`). Mapping marks to their
closure positions instead of their original ones fails exactly the two
position tests, and dropping the low-link update from a finished control to
its parent fails eight, among them the three-control cycle, the nested back
edge and the 100,000-control cycle. Production lines +152; tests +158 unit
and +178 e2e (a 166-line fixture).
`blorp/scripts/self-compile-cost 73f73dfe6 <landing 1> --rounds 5`:

| self-compile | base | landing 1 | change |
|---|---:|---:|---:|
| fixed input allocations | 14,011,893 | 14,011,833 | -0.0004% |
| fixed input instructions, median of 5 | 12,323,222,493 | 12,319,009,285 | -0.034% |
| own source allocations | 14,011,893 | 14,056,995 | +0.32% |
| own source instructions, median of 5 | 12,329,387,385 | 12,358,439,629 | +0.24% |

The fixed-input C is identical; the own-source rows grow with the source.

Landing 2 adds `generic/many_bounded/equality`, forty bounded `==`
functions, measured the same way against landing 1:

| landing 2 | landing 1 | landing 2 | ceiling |
|---|---:|---:|---:|
| `equality`, instructions | 569.0 M | 431.4 M | 496.1 M |
| `equality`, allocations | 123,201 | 122,408 | 140,770 |
| `inequality`, instructions | 500.1 M | 448.5 M | 575.2 M, unchanged |
| `effects/hello`, instructions | 384.2 M | 364.2 M | 504.2 M, unchanged |

The new fixture exceeds its instruction ceiling on landing 1, 569 M
against 496 M.

**Gates, landing 2**, against landing 1, run before review simplified the
growth loop: `make -C blorp test INSTRUCTION_CHECK=on`,
`scripts/blorp-fixpoint --prove` and `git diff --check` pass. Output
identity: 726 inputs, 128 of them rejections, byte-identical, including both
growth rejections (`growth_hidden_in_constructor_child`,
`reject_growing_unused`) with identical messages (`data/landing/g2/identity/`).
The broken-mapping check still fails exactly landing 1's two position
tests. Production lines -50; tests +178 e2e. Together the two landings add
102 production lines. `blorp/scripts/self-compile-cost <landing 1>
<landing 2> --rounds 5`:

| self-compile | landing 1 | landing 2 | change |
|---|---:|---:|---:|
| fixed input allocations | 14,056,995 | 14,056,623 | -0.0026% |
| fixed input instructions, median of 5 | 12,320,980,324 | 12,332,502,022 | +0.094% |
| own source allocations | 14,056,995 | 14,054,474 | -0.018% |
| own source instructions, median of 5 | 12,327,409,484 | 12,321,789,094 | -0.046% |

The fixed-input C is identical; the instruction changes are within the
noise of five runs on a shared machine.

## Option (b): elaborate library bodies when reached

Approved by Keith on 2026-11-16.

**Design.** Checking still accepts every declaration and signature, and
elaborates every body of a user module (`ModuleKind`, a typed role). A
library function's body is elaborated when an elaborated body, a constant or
a structural-equality template reaches it: through a call target, a function
used as a value, or a trait call. A trait call on a type parameter reaches
every implementation's member, so the rule covers anything specialize can
later select. The checked function table gets a typed row for "declared, body
not elaborated"; specialize's existing missing-body error is the loud failure
for the case the rule excludes. An index from trait member to implementation
bodies is derived once from the implementation table and read-only. A
`make -C blorp test` suite elaborates every library body.

**What changes.** README's "Every loaded module is checked, including unused
declarations" becomes: every user declaration is checked; a library body is
checked when the program can reach it; the test suite checks the whole
library. A library error in an unreached body appears only in `make test`.

**Pilot prototype** (on the unlanded `pilot/library-cost` branch, with a marker body
instead of a typed row), on top of option (a):

| measure | option (a) | (a) + (b) |
|---|---:|---:|
| hello, -O0 instructions | 330 M | 238 M |
| hello, -O0 allocations | 111,798 | 71,663 |
| hello, -O2 instructions | 106 M | 74 M |
| hello's bodies step, -O0 | ≈100 M | 24 M |
| self-compile, -O2 (probe, one run) | 12,436 M | 12,592 M (+1.2%) |
| self-compile allocations | 14,258,506 | 14,421,731 (+1.1%) |
| Path in the prelude, hello -O2 | +22 M, +30,208 allocs | +10 M, +13,880 allocs |

Output was identical on 725 inputs. The self-compile reaches most of the
library, and the prototype builds a list per call and scans every
implementation per trait call; the member index removes that scan.

**Ceilings** for a landing: self-compile instructions and allocations within
+0.1%; at most +280 production lines; hello at -O0 at least 25% below
option (a).

**Budget correction (coordinator, 2026-11-17):** production-line ceiling +280 → +295. The review added a required correctness fix (every inherited default a user implementation brings in is checked, +5) and two quality fixes (a module-role invariant replacing a silent fallback, +4; one shared member lookup in place of a duplicated chain, +3), plus a docstring (+2). Growth audit: `bodies.brp` +248 (imports 21, index and reach helpers 134, queue in `resolve_functions` 93), model +21, check +14, name_uses +11, specialize +11, recursion −14. Nothing else can be cut without losing function.

**Decisions** (Keith, 2026-11-16, each as recommended).

1. (b) is approved: every signature and every user body is checked, a
   library body only when checked code can reach it, and `make test` checks
   the whole library. README's promise changes accordingly.
2. `--library-root` compiles follow the same rule. Tests, the build and the
   language server all use library directories, so a rule keyed on where the
   library came from would leave the shipped path unmeasured.
3. The language server may omit references from unreached library bodies.
   User files keep full checking, and library diagnostics are never
   published.
4. `Path` stays out of the prelude, as Keith decided for PATH_PLAN's L8. With
   (b) it would cost +10 M instructions and +13,880 allocations per compile.

### Option (b) results

The landing, `check/library-bodies-when-reached` against origin/main
`4d8b381f0`, with the host and recipes of option (a). Raw samples, scripts and
logs are in the main checkout's ignored
`build/pilots/2026-11-12/library-cost/data/option-b-4d8b381f0/`, with the
`make -C blorp test INSTRUCTION_CHECK=on` log of `0a334431e` (3,054 passed,
0 failed) as `make-test-0a334431e.log`.

- `CheckedFunction.elaboration` is `ElaboratedBody(CheckedFunctionBody)` or
  `BodyNotReached`; specialize reports a body it reaches unelaborated as a
  missing body.
- `bodies.brp` queues every user body, every default a resource type
  inherits and the targets of every constant and structural-equality
  template, then adds each elaborated body's and lambda's call targets and
  created callables. An inherited default is walked again with Self as the
  resource, and that walk reports the implementation's own error, so it is
  checked whether or not a call reaches it. A trait call on a type
  parameter reaches every implementation of its member through
  `member_bodies`, an index built once from the implementation table.
- Each elaborated body, lambda and template is walked once, and the walks
  (`BodyCalls`) go to the recursion check, which used to walk every body
  itself. Without that sharing the self-compile cost +1.7% instructions and
  +1.1% allocations.
- `analyze_whole_library` elaborates every body;
  `test_standard_library/test_whole_library.brp` runs it on a program that
  imports every library module and prints a failure with its location.

Hello (`effects/hello.brp`), base and candidate built from the same tree
with the Makefile's recipes; median of 3 alternating runs (`/usr/bin/time
-l`), allocations from the `-O0` diagnostic build under strict leak check:

| hello | `4d8b381f0` | candidate | change |
|---|---:|---:|---:|
| -O0 instructions | 337.1 M | 240.3 M | -28.7% |
| -O2 instructions | 106.5 M | 73.8 M | -30.8% |
| allocations | 109,983 | 69,550 | -36.8% |

`blorp/scripts/self-compile-cost 4d8b381f0 <landing> --rounds 5`, fixed
input (the base's own source): allocations 14,315,638 to 14,304,002
(-0.081%), instructions 12,782,668,705 to 12,778,267,265 (-0.034%), peak
heap unchanged, C identical. The own-source rows (+0.28% allocations,
+0.38% instructions) include compiling the landing's added source.

Output identity: 748 inputs (every e2e fixture that declares `main`, every
`trait_inputs` module compiled directly, and `blorp/src/main.brp`; 132 of them
rejections) give byte-identical C, stdout, stderr and status. Seeding every
body fails all four `test_library_bodies.brp` tests, and a trait call on a type
parameter that reaches no implementation fails its two trait tests, one of
them an impure trait implemented by a resource type and by Int. Existing e2e
ceilings are unchanged; hello-sized compiles now measure about 29% under
them at `-O0`.

The measurements above are of `0a334431e`. Code review then found that a
user's resource type inheriting a library default was checked only when a
call reached the default (`trait_inputs/resource_defaults`, now an e2e
rejection), and asked for the reach routes to be pinned. The fixes seed
inherited defaults, add a test per route (function and method values, a
lambda in a library body, an unused constant, an equality template, a default
reached through the member index, and an inherited resource default), report
a module a function's body names but the program lacks as a checker
invariant, and share the member lookup between building and reading the
index. Production lines are +291 (+277 before the fixes; see the budget
correction above), tests +548.

The fixed commit, `c4a04e833` against origin/main `f95a8204d` (raw data in
`data/option-b-f95a8204d/`): `make -C blorp test INSTRUCTION_CHECK=on`
3,063 passed, 0 failed (`make-test-c4a04e833.log`); output identity on 752
inputs, 136 of them rejections, 0 differences; fixed-input self-compile
allocations 14,338,845 to 14,327,233 (-0.081%), instructions 12,789,220,891
to 12,785,726,615 (-0.027%), peak heap unchanged, C identical; hello -O0
336.6 M to 240.1 M (-28.7%), -O2 106.3 M to 73.7 M (-30.7%), allocations
109,983 to 69,549 (-36.8%).

## Options not recommended

- **(c) Treat the embedded library as checked, check `--library-root` fully.**
  Checking is elaboration, so this is (b) with the policy keyed on where the
  library's bytes came from.
- **(d) A persisted, checked library interface.** Specialization needs
  generic bodies in it, not only types (as Rust's crate metadata and Swift's
  serialized SIL carry). It needs identities stable across compilations, a
  codec for the checked model, versioning and a second path into checked
  data: an estimated 2,000+ lines, and adjacent to the incremental
  compilation Keith deferred.
- **(e) Lazy lexing and parsing.** The prelude reaches every module hello
  loads, the lexer must read every byte for layout, and deferring body
  parsing would have check call the parser. The gain is at most 16 M at
  -O2.

## Adjacent problems

- `and` and `or` are eager functions; compiler source has 282 `.and(` and
  `.or(` calls, and any with an expensive right operand always pays for it.
- `dependency_graph` finds parameters by linear scan, the likely remaining
  growth term.
- Lexing costs about 250 instructions per byte and parsing about 370 at
  -O2 (2,300 and 1,200 at -O0).
- `admit_receivers` is 3.7% of hello at -O0, and
  `prepare_equality_availability` 177 M of the self-compile.
- The shared busy check is a race: sessions waiting on it start in the same
  gap, so several e2e runs often overlap. `self-compile-cost` checks only
  `compiler|fixpoint`, not `blorp/build/blorp`.
- A per-phase stop option would be a cheap, deterministic cost table; keeping
  it is a new mechanism and needs approval.
