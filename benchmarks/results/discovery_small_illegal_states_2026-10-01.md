# Discovery: Smaller Illegal States Removed — Cost, 2026-10-01

Cost ledger for the sixteen small cleanups on `compiler-new/small-illegal-states`
(loop context and module as parameters, `SourceId` spans, `NameId` seeds, one path
per module, derived import text and concurrency counts, `NO_SOURCE`, fewer `-1`
sentinels, linked recovery nodes, typed parameter binders, `ImplRow`, table-derived
ordinals, per-class member/body/type appenders, enums for boolean choices, table
enum for lookups).

## Provenance

- Base: origin/main `77212b780`; head: the branch tip
- Host: Apple Silicon, Darwin 25.6.0; `/usr/bin/time -l` counters
- C compiler: Apple clang 21.0.0, `-O2 -fwrapv`
- Input: a copy of the base's `blorp/src`, `standard_library` and `pkg`
  (`blorp/src/main.brp` as the root; 446 modules); both binaries read the same copy
- Tool: `blorp/test/compiler/tools/discovery_adapter_cost.brp`, one binary per
  revision, without and with `-DBLORP_MEMORY_DIAGNOSTICS=1`; `discovery_dump counts`
  for the stage alone
- No gate ran during the measurement; three rounds, base and head back to back

## Rebase note

Measured by the coordinator on the branch rebased onto origin/main `620293a4f`,
against that main, both built by the same compiler. The table below replaces the
earlier pre-rebase measurement.

## Results

| | Change vs main |
| --- | ---: |
| Allocations, cost tool `tables` | -5,415 |
| Allocations, cost tool `graph` | +4,205 |
| Instructions, `tables` | +0.31% |
| Instructions, `graph` | +0.70% |

Output identity: the `tables` dump differs from the base only in its count line
(`paths` 1209 to 448: import request texts are no longer interned; `names` +1 for
the seeded `<impl>`; a new `impls` count; `concurrency_counts` gone). Every other
line is byte-identical. `scripts/test compiler-new-parity` passes 3,343 of 3,343.

## Reading

- The stage allocates 4,797 fewer objects: not interning the 761 import request
  texts saves about 9,100; the interpolation scan frames add about 4,000; 600
  `ImplRow`s add about 600.
- The adapter (`graph`) allocates 4,823 more: it builds each import request's text
  once per import row into its reader (it built it per use before), and the texts
  are new strings the old front end read from the source.
- `tables` instructions are flat; `graph` rises 0.8%. The sources are the freeze
  checks that remain (impl, recovery diagnostic, name span rows) and the derived
  import text in the adapter. Not chased.

## Shapes found while measuring

- A struct payload in a union variant (`BoundSink(OwnedRows)`) allocated once per
  bound or supertrait on extraction; the variant now carries the two integers it
  needs, as opaque start types. Likewise a three-field struct argument for a bound.
- A function that returns `if`/`match` of a builder call in the tail position
  (`out.parse_impl_method_function(...)` under an `else` that reassigns `out`)
  copied tables: nine allocations per impl on this corpus. Assigning the call to
  `out` and ending with `out` is flat.
- A two-field record update in one expression (`{ builder | definitions = ..., members = ... }`)
  and a record update after a bound call result both copied; two single-field
  private appenders chained from the parameter are flat.
- `get_or` of a struct row from a table allocated per call (138,000 on this input
  when ordinals were read from the previous row); ordinals now come from
  table-length differences against a start taken at the owner's opening.
- A chained call on a parameter (`builder.f().g()`) as the tail of the import item
  parse copied a table per import (rule 2); the bound-then-hand-on shape is flat.
