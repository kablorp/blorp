# Library cost

Plan revision 1, 2026-11-12, from the `library-cost` pilot, written against
origin/main `73f73dfe6` (pilot measurements against `95f37e437`).

A compile's cost follows the size of the standard library, not the program.
Hello's compile is about 99% library work. Checking also grew superlinearly
in the number of bounded generic functions.

**Status:** Keith approved option (a) on 2026-11-12, as two landings that
remove both superlinear algorithms (see "Option (a) results"). Option (b),
elaborating library bodies only when they are reached, is a proposal; it
waits on the four decisions below. Options (c), (d) and (e) are not
recommended.

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

## Option (b): elaborate library bodies when reached

A proposal; it waits on Keith's decisions below.

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

**Decisions for Keith.**

1. Approve (b): library bodies elaborated only when reachable, the whole
   library checked by `make test`, and the README promise above.
2. Whether `--library-root` compiles follow the same rule (recommended), or
   check every library body. Tests, the build and the language server all use
   library directories, so a rule keyed on where the library came from would
   leave the shipped path unmeasured.
3. Whether `Path` joins the prelude after (b), at +10 M instructions and
   +13,880 allocations per compile.
4. Whether the language server may omit references from unreached library
   bodies. User files keep full checking, and library diagnostics are never
   published.

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
