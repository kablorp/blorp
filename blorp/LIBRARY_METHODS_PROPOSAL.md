# Option, Result and Bool methods in library modules

A proposal for Keith, 2026-11-22. **Keith chose design 2 on 2026-11-22**
("Design 2"). [Spike](#spike) records its measured size.

## Problem

User modules now receive Option's, Result's and Bool's methods from the
prelude. Library modules receive no prelude, so 27 rows in 19 of them remain:
13 `result: Result methods` (mostly `io/files/*`), 7 `option: Option methods`
and 7 `bool: Bool methods`. The prelude's own three rows define it and stay.
Giving library modules the prelude as it is would create load cycles, because
the prelude imports `dict`, `list`, `string` and the rest.

## Designs

Two measured rates give the costs below:

- a written row costs about 31 allocations: removing 86 rows saved 2,698;
- an implicit selection costs about 3 per receiving module: the Bool row
  cost +234 across the compiler's 73 modules.

**1. Keep the rows.** This is the simplest direct option: no mechanism,
nothing to validate, and no change in cost. A library author writes an import
that a user never needs.

**2. A methods set for library modules.** A second foundation module,
`standard_library/_methods.brp`, holds the three rows and has its own role.
Every library module receives it, the way a user module receives the
prelude, except the modules it imports: `option`, `result` and `bool`.

- **Why no cycle:** those three import only `_base`. If one of them later
  imports another library module, the existing cycle check in `seal_program`
  rejects it there.
- **Example:** `io/files/write.brp` drops `result: Result methods` and still
  writes `.map_err(...)`.
- **Scope:** `assemble.brp` adds an edge as `PreludeEdge` does, `namespace.brp`
  passes on the selections as `provided` does, and the loader assigns the
  role. The rule lives in one data file.
- **Cost:** estimated here at +40 to +70 production lines (the spike measured
  +130), minus the 27 rows. A
  small compile pays about +100 to +200 allocations (0.2% to 0.3%), and
  self-compile saves.
- **Validation:**
  - library fixtures that call each method without an import;
  - a fixture showing the set's own members do not receive it;
  - a rejected cycle;
  - cost against ceilings set beforehand.
- **Landing:** two steps with a seed rotation. The pinned seed compiles the
  library and does not know the new role, so the rows go only after a seed
  that does is pinned.

**3. Methods found through the receiver's type.** A method call on an Option,
Result or Bool also searches that type's operation module, in every module.
That removes the prelude's rows too.

- **Pairs:** each type-to-module pair must be declared explicitly, never
  inferred from file names.
- **Scope:** this changes method resolution for the commonest receivers, and
  user types would ask for the same, which makes it a language decision.
- **Cost:** an estimated +100 to +200 production lines, new syntax or a
  builtin table, grammar and README changes, and the same rotation.
  Compile cost is close to design 2's.

## Recommendation

**Design 2,** since you want these rows "unneeded and removed". It reuses the
prelude's edge model, adds one role and one data file, and lists the
library's implicit dependencies in one place, at a cost within noise.

Choose design 1 if 27 explicit library rows are acceptable. Design 3 goes
beyond this goal.

Design 2 is an implicit input, so per `blorp/AGENTS.md` it needs your
approval. A spike would set its production-line ceiling from compiled code.

## Spike

Commit `0b6f13dda`, local branch `spike/library-methods`, on `f893dd5f0`,
built from the pinned seed with the 27 rows in place. It adds:

- a `FoundationMethodsModule` role and ordinal 3;
- `_methods.brp`, which the loader reads as a designated input;
- the per-module implicit source, published at sealing;
- that source read in `namespace` and in receiver-clash admission;
- the LSP's role matches.

What it showed:

- It compiles the compiler, and that compiler reproduces its own C
  (`70e6a4f5edf4f69f`).
- `io/files/write.brp` without its `Result methods` row compiles. The base
  compiler reports `unknown function`.
- `option.brp`, a set member, calling `.not()` is rejected with "no method not
  for Bool is in scope".
- `option.brp` importing `order` is rejected as the cycle
  `_methods -> option -> order -> _methods`.

Formatted, it is +201 −71, net +130 production lines, against the +40 to
+70 estimated above:

| File | Net |
| --- | --- |
| `assemble.brp` | +53 |
| `load.brp` | +27 |
| `namespace.brp` | +13 |
| the two LSP files | +14 |
| `_methods.brp` | +9 |
| `source.brp` | +7 |
| `receiver_clashes.brp` | +6 |
| `check.brp` | +1 |

About 20 of those lines are `ModuleKind` import lists that the formatter
now wraps, and about 20 are comments.

## Landing 1: the mechanism

Keith accepted the spike's size on 2026-11-22 ("Proceed at +130"). This
landing is the spike with the 27 library rows still in place: redundant rows
are accepted and enter once.

Review made the design tighter than the spike:

- **The implicit source is a closed type.** Sealing publishes each module's
  source as `fixed union ImplicitSource` (`NoSource`, `PreludeSource`,
  `MethodsSource`), not an `Option[ModuleId]` that could name any module.
  Namespace matches on it once. Receiver admission keeps one table for the
  prelude and one for the methods module.
- **One helper finds every foundation row.** `seal_program` filters each
  foundation role with `foundation_row`, replacing three role lists and a
  loop.

**Tests**

- **Loader:** `test_load/test_foundation_methods.brp`.
  - An explicit `_methods` import is rejected, with exact message, help and
    span.
  - `_methods` cannot be an application root.
  - A member that imports `order` is rejected as the cycle
    `_methods -> option -> order -> _methods`, reported at the end of
    `order`.
- **Check:** `test_check/test_library_methods.brp`.
  - An unsaved library probe calls every Option, Result and Bool method with
    no import; there is one case per module.
  - A minimal `option.brp` calling `.not()` is rejected with "no method not
    for Bool is in scope".
  - A library `get_or` on `Option[Int]` overlaps the received one.
  - Two written `Box methods` imports overlap after the received prefix.
- **Role:** `test_embedded_library` checks the role of `_methods.brp`.
- **Test support:**
  - Bundles that tests build by hand gain an empty methods module.
  - The reduced test libraries gain a `_methods.brp` that selects nothing.
  - Suites that named a loader row's number now take it from
    `test/support/loader_rows.brp`, which also holds the shared `absolute` and
    `module_of`.

**Mutations**, each run against the two new suites:

| Mutation | Cases that failed |
| --- | --- |
| allow importing `_methods` | the explicit import |
| accept `_methods` as a root | the root |
| library modules receive nothing | the cycle, all three probes and the `get_or` overlap |
| receivers get no methods | the three probes and both overlaps |
| drop the `option` row | the Option probe and the `get_or` overlap; also the member and cycle cases, since `option` stops being a member |
| drop the `result` row | the Result probe |
| drop the `bool` row | the Bool probe |
| admission skips the written method edges | both overlaps |

Admission needs only one introduced edge of an overlapping pair. So skipping
two edges too many is not caught, because the probe's own type-selection
edges come first; skipping past every written edge is.

Letting members receive the set closes a cycle in every program, so no
member can receive it.

**Ceilings,** set before measuring, against main `f893dd5f0`:

- production lines: net +130;
- self-compile fixed input: +0.1% instructions, +0.01% allocations and
  +0.1% peak heap.

The small-compile allocations are reported against the +100 to +200
estimated above.

### Final measurement

This measures commit `fed00123d` against `f893dd5f0`, on the same host and
recipe as the spike.

| Measure | Ceiling | Final |
| --- | --- | --- |
| production lines | net +130 | +218 −103, net +115 |
| self-compile fixed input: allocations | +0.01% | +0.0060% |
| self-compile fixed input: peak heap | +0.1% | +0.0019% |
| self-compile fixed input: instructions | +0.1% | −0.0061%, median of 5 |

**The fixed-input row is measured by hand.** `self-compile-cost` cannot run
it here: that row compiles the base's library, which has no `_methods.brp`,
and the candidate requires one. So both `-O2` compilers compile the base's
`src/main.brp` with the base's library plus the candidate's `_methods.brp`,
which the base compiler never loads. The emitted C is identical. The own-source
row was not measured.

**A small compile costs more than estimated.** For `return/zero` at `-O2`:

- +607 allocations (+1.05%), against the +100 to +200 estimated;
- +24,371 bytes of peak heap (+1.90%);
- +1.09% instructions, beyond the run-to-run spread of about 0.4%.

A diff of allocation sites between matched `-O0` builds names the causes:

| Source | Allocations |
| --- | --- |
| receiver lookups for the 12 received functions, in each of the 13 receiving library modules | about 112 |
| lexing, parsing and loading `_methods.brp` | about 130 |
| sealing's new edges and source list | about 40 |
| many small sites | the rest |

The estimate missed the per-module receiver lookups.

**Test code** is +689 −110, net +579:

- the two new suites;
- the receiver-clash cases;
- methods modules in the hand-built bundles;
- the shared `loader_rows` helpers;
- derived row numbers where suites had literals.

**Gates on `fed00123d`:**

- `make -C blorp test`: exit 0, 3,360 PASS, 0 FAIL;
- `make -C blorp test-e2e INSTRUCTION_CHECK=on`: exit 0, 1,167 PASS, 0 FAIL.
  No e2e ceiling was exceeded, so none moved.

Logs are in `blorp/build/foundation-methods/final2/`.

## The seed rotation

`blorp/bootstrap.env` pins `blorp-seed-8eb8e16546b3`, which main's CI built
from landing 1 (`8eb8e1654`). Every target emitted identical compiler C. This
seed knows the foundation methods role, so the library can rely on it and the
27 rows can go.

**Gates on the pin:**

- `make -C blorp test`: exit 0, 3,360 PASS, 0 FAIL;
- `make -C blorp test-e2e INSTRUCTION_CHECK=on`: exit 0, 1,167 PASS, 0 FAIL.
  No e2e ceiling moved;
- `scripts/blorp-fixpoint --prove`: exit 0;
- `bash blorp/test/test_bootstrap/test_bootstrap.sh`: exit 0, 38 PASS.

Logs are in `blorp/build/seed-rotation/`.
