# Blorp 2 namespace: one scope per module

The first sections retain the original namespace-stack measurements. The
[completion measurements](#completion-measurements) below use fresh matched
builds. The historical large-program generators are no longer retained, so
their results are historical evidence rather than reproducible new gates.

Measured 2026-10-15 at the commit that gives each module one scope, against
main `bd8b39775`. Both pilots are built by `make -C blorp_2 test-compiler`
(`clang -O0 -DBLORP_MEMORY_DIAGNOSTICS=1`) with the same host `bin/blorp`.
Instructions are the minimum of three `/usr/bin/time -l` runs; allocations come
from one `BLORP_LEAK_CHECK=strict` run. Runs were serial on an Apple M4. The
inputs are proxies, because Blorp 2 cannot compile itself yet; every accepted
input produces the same C as main.

| Input | Main instructions | Scopes instructions | Main allocations | Scopes allocations |
|---|---|---|---|---|
| generated, 1,024 functions | 15.282 G | 13.782 G (−9.8%) | 10,114,500 | 10,072,439 |
| generated, 2,048 functions | 31.430 G | 25.374 G (−19.3%) | 18,793,628 | 18,709,631 |
| generated, 256 functions | 3.627 G | 3.557 G | 2,622,189 | 2,611,648 |
| direct chain, 256 modules | 4.518 G | 0.683 G | 324,079 | 293,521 |
| flat, 256 modules | 3.752 G | 0.488 G | 115,135 | 85,300 |
| forwarding chain, 256 modules | 110.061 G | 0.290 G (now rejected) | 681,104 | 39,710 |
| `return/zero` | 35.2 M | 34.0 M | 8,471 | 8,398 |
| e2e corpus, 426 files | 17.521 G | 16.943 G (−3.3%) | — | — |

The generators are `gen.py 1024 24 16`, `gen.py 2048 0 0`, `gen.py 256 8 16`,
`gen_direct_chain.py 256` and `gen_forward.py chain|flat 256` from the plan's
scratch scripts. The e2e test "module chains stay within their cost ceiling"
generates the 64-module direct chain and flat programs; under its strict leak
check they measure 248 M and 132 M instructions, against main's 528 M and
375 M.

Unit and grammar tests change by −2,100 lines in this commit (+639, −2,739):
six suites that pinned the program-wide tables are deleted and
`test_namespace/test_namespace.brp` (442 lines, 28 tests) replaces them.

## Choices the measurements decided

- **Record updates in place.** The host updates a consume-specialized
  function's record in place only when every path returns the parameter or a
  record update of it (`record_update.brp`, `prepare_owned_parameter_result`).
  A first cut whose `enter` returned `keep_first(built, ...)` on one path copied
  the scope's map on every entry: 755 namespace allocations on `return/zero`
  against 369 once every path is a record update.
- **IntMap slots stay `Int` with a named empty value.** `slots: List[Option[Int]]`
  boxes every recorded position: 9,724 allocations on `return/zero` against
  8,452.
- **One `Entity` for both spaces.** Typed per-space entries were drafted. The
  data and rule alone shrink by 10 lines, but the source-ordered declaration
  list needs a tagged entry per name and each space needs its own copy of
  `enter`. The projected total is about 37 more lines. A proxy that adds one tag
  per declared name and two more maps per module measured 8,529 allocations on
  `return/zero`, over the 8,514 ceiling.
- **The type query returns the head only.** A `{ head, origin }` result cost
  62 allocations on `return/zero`; the origin lands with the private-type rule
  that reads it.

## CF-028 reproduction

In the scopes commit's `namespace.brp`, add this record before `select_methods`:

```blorp
private fixed record SiteProbe {
	path: ModulePath,
	selection: ImportSelection
}
```

bind it at the top of `select_methods`' loop body:

```blorp
		site: SiteProbe = { path = request.path, selection = selection }
```

and replace the `ReceiverNotVisible` arm's `fail(next, request, selection,
ReceiverNotVisible)` with:

```blorp
							{ next | problem = first_problem(next.problem, SelectionFailure(site.path, site.selection, ReceiverNotVisible)) }
```

`blorp_2/test/e2e/fixtures/return/zero.brp` then leaks 8 objects (448 bytes:
4 `List`, 4 `ModulePath`) under `BLORP_LEAK_CHECK=strict`.

## Mutation checks

Each mutant ran alone against `test_namespace/test_namespace.brp`; 24 of 25
fail at least one test. The survivor, a declaration that merges with an equal
entity, is equivalent: two declarations share an entity only as a repeated
builtin head, which `check_builtin_types` rejects before the namespace is
built. Seven of nine IntMap mutants fail `test_int_map`; the other two change
only an unreachable `get` default and the presized slot count.

## Completion measurements

The completion integrates the six-commit namespace stack ending at
`bbb3da2f9` into `05ac9c9ce`, then replaces the seal walk's sentinel and
parallel state, simplifies selection help, repairs constructor diagnostic
projection, and strengthens the behavior tests. `05ac9c9ce` differs from the
stack's `bd8b39775` baseline only in documentation.

These are input-program proxies, not self-compilation measurements. The pilot
cannot yet compile its own source. They measure its complete source-to-C
invocation on the owned fixtures; they do not establish whole self-compile
cost or reproduce the missing historical large-program generators.

### Provenance and method

- Same `make`-built host for every pilot: bootstrap `dev-0e1598ed616e`, host
  CLI `-O0`, runtime `-O2`, Apple Clang 21.0.0. Host binary SHA-256:
  `899e0a92cfe1bc91f992bd3ccdd0755448903eb91d91780ac4870bd13d8cfa17`.
- Main baseline source: `05ac9c9ce080dd2f89baa2b3a733ec5d6d9c0658`;
  reviewed-stack source: `bbb3da2f9e73515df3c79234ed54a77a37e3e952`.
  Both were frozen before the completion edits. Source snapshots stay under
  ignored `blorp_2/build/quality-namespace/`; no other checkout was changed.
- Every pilot was linked with `clang -O0 -DBLORP_MEMORY_DIAGNOSTICS=1`,
  `-lm -lpthread`. Compilations, gates and measurements were serialized.
  Retired instructions are the minimum of three `/usr/bin/time -l` runs;
  allocations are identical across the three runs, with strict zero leaks.
- Final source-tree SHA-256, computed by sorting the paths under
  `blorp_2/src`, hashing each `.brp`, then hashing that manifest:
  `28a26ff86a9960cebcf3d9260a9d6e32aa75579fd811dcbe0b4327c0d064fe6c`.
  Final emitted host C SHA-256:
  `7d1f8df891d4c9398b7d4c32e2a86355e3468600cd9991e62dcee2df070687b1`.
- Raw logs, generated C, binary hashes and mutation snapshots stay under
  ignored `blorp_2/build/quality-namespace/`. The repository-owned generators
  are `write_direct_chain` and `write_flat` in `test/e2e/test_imports.brp`.
  Each native fixture runs its real entrypoint through the unchanged C with
  ASan and UBSan, using the existing e2e harness.

### Results against the reviewed stack

| Workload | Stack allocations | Final allocations | Stack instructions | Final instructions |
| --- | ---: | ---: | ---: | ---: |
| `return/zero` | 8,412 | 8,428 | 42,346,891 | 42,380,966 |
| 64-module direct chain | 79,780 | 80,240 | 243,045,444 | 244,031,243 |
| 64-module flat program | 27,521 | 27,739 | 128,192,303 | 128,671,731 |

The completion's pre-set stress ceilings were at most +1% allocations and
instructions against the reviewed stack. The direct chain changes by +0.58%
allocations / +0.41% instructions; flat changes by +0.79% / +0.37%. Both pass.
`return/zero` remains below fresh main's 8,485 allocations and 44,097,233
instructions, with byte-identical C.

Two rejected graph prototypes explain the accepted representation. Managed
row-bearing frames plus a `follow_edge` boundary cost 81,191 / 28,506
allocations on direct / flat inputs. Generated C retained the walk around
the non-consuming helper call. One transition function and a three-state
visit vector reduced this to 80,512 / 27,948. Replacing managed row-bearing
frames with inline `ModuleId + cursor` frames produced the accepted counts.
A direct representation probe shows two scalar C fields with no object
header or frame allocator. The module rows remain authoritative.

### CI allocation oracles

Direct and flat are separate named e2e tests, so failure of the first cannot
skip the second. Their ceilings are 83,000 and 31,000 allocations, retaining
300,000,000 and 160,000,000 instruction ceilings. With
`BLORP_2_INSTRUCTION_CHECK=disabled`, fresh main fails both allocation tests:
87,480 > 83,000 and 35,064 > 31,000. The final compiler passes both.

The owned path is reproducible without scratch generators:

```bash
make
make -C blorp_2 test-compiler
BLORP2_COMPILER=blorp_2/build/compiler bin/blorp test --suite --timeout 0 \
  --repeat 3 blorp_2/test/e2e/test_end_to_end.brp
```

Run the same fixture suite against separately frozen main and stack pilots
from the exact revisions above for matched comparisons. Main deliberately
fails the new namespace rejection expectations and allocation ceilings; that
negative result is the oracle, not a passing baseline gate.

### Regression evidence and limits

- Historical C1's `scan.declared` → `scan.types` mutation rejects the new
  `namespace/declared_function_imported_type/main.brp` fixture as ambiguous.
  The original C1 and final design accept it; native output is exactly `42`.
  Original C1's compile reported 10,991 balanced allocations and zero leaks.
- `replace_moves_to_end` and `growth_reverses_order` each fail only the new
  insertion-order/association test, while the other nine map tests pass.
- Wrong implicit closing spans fail 1/20 assembly tests; wrong written-edge
  spans fail 3/20; reversed dependency publication fails 2/20. Healthy assembly
  tests exercise exact diamond order and 3,000-module cycles and valid chains.
- Experimental recursive drivers also pass the 3,000-module tests on this
  host. The stress tests are not an independent constant-stack oracle. The
  production walk's explicit iteration and C inspection establish its shape;
  these tests protect graph semantics at size, not all compiler recursion.
- Four additional real-main probes return exactly `42` under sanitizers:
  a public function beside a private type, a public type beside a private
  function, identical explicit/prelude constructor imports, and a methods-only
  selection before its type selection. Private-method and forwarded-constructor
  probes also produce their exact expected diagnostics.
- Source reviews independently approve correctness and design conformance.
  Full-gate and corpus-comparison results are recorded below.

### Size and acceptance

Against main: production **+1,302 / −1,497 = −195 lines**; tests and fixtures
**+1,232 / −3,590 = −2,358 lines**. These are physical lines with ordinary
formatting. Removed representation-pinning suites were reviewed against
remaining semantic, identity and phase coverage.

C3 is −2, meeting its `<0` ceiling. The graph completion (+18) and constructor
diagnostic completion (+11) put C4 at −263, exceeding its original `≤−280`
ceiling. Keith accepted this documented variance when authorizing the completed
change to be committed, squash-merged to main and pushed. The revised C4 ceiling
is `≤−263`; allocation and instruction ceilings are unchanged. The overall
rewrite meets `≤−180`.

### Independent validation

The separate test-runner rebuilt with `make` and confirmed `FRESH`, then ran
`make -C blorp_2 test`: **2,712 unit/runtime/grammar tests and 430 e2e cases
passed**, with default required instruction counters. The regenerated pilot
C is byte-identical to the frozen measured candidate. No source inputs
changed during the gates.

`scripts/blorp2-fixpoint --frontier` reports **32/34**, stopping on the known
Char-literal and function-type parser gaps. This is a parse-frontier
measurement, not a successful bootstrap or fixpoint proof.

A serial shell loop using the fixture comparison protocol in
`scripts/blorp2-fixpoint` compiled every discovered fixture under strict leak
checking, for both compilers. All **429/429** invocations per compiler produced
one balanced zero-leak report. Final compilation accepts 349 and rejects 80;
main accepts 348 and rejects 81. **426/429** fixture results are identical in
status, stdout, diagnostics and emitted C after removing only the allocator
summary line. All 348 previously successful outputs have byte-identical C;
all stdout agrees. The three expected differences are:

1. `import/forwarding/facade.brp`: the illegal forwarded type is diagnosed
   before checking for a missing main, with a note at the original declaration.
2. `namespace/alias_conflict.brp`: the later selection is diagnosed against the
   earlier alias, with their locations assigned to error and note respectively.
3. `namespace/declared_function_imported_type/main.brp`: former ambiguous
   selection rejection becomes acceptance; its real main prints `42`.

Exact per-fixture outputs, hashes and comparison commands are retained under
`blorp_2/build/quality-namespace/gates/`, including
`fixture-results.tsv`, `fixture-commands.tsv` and
`identity-diagnostics.diff`. No unexpected differences or leak exceptions
were accepted. The C4 line-budget decision is recorded above.
