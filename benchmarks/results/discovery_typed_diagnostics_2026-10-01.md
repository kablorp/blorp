# Discovery: Typed Diagnostics and a Separate Output Record: Cost, 2026-10-01

Two changes to the discovery stage, measured against `origin/main`:
a diagnostic row holds the union of its own table instead of a code and a
block of integers, and `freeze` moves the output lists into a `DiscoveryTables`
record instead of wrapping the builder.

## Provenance

- Base: `origin/main` (`e594ca835`); candidate: the head of `compiler-new/typed-diagnostics-output`
- Host: Apple Silicon, Darwin 25.6.0; `/usr/bin/time -l` counters
- C compiler: Apple clang 21.0.0, `-O2 -fwrapv`
- Fixed input: a `git archive` of `9e270d350` (older than the base binary; the input is only a workload) (`blorp/src/main.brp` with its
  standard library and `pkg`, 443 modules, prelude and tuple implicit modules).
  Both binaries ran from that directory, so the input is identical.
- Tool: `blorp/test/compiler/tools/discovery_adapter_cost.brp`, built from each
  tree; one binary without and one with `-DBLORP_MEMORY_DIAGNOSTICS=1`.
- Three rounds, the two builds back to back in each round, no gate running.

## Results

Final head (per-table diagnostic unions, per-code construct enums), against
`origin/main` at `e594ca835`; both binaries ran the same fixed input.

| | Base | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations, stage to tables | 576,612 | 576,612 | 0 |
| Allocations, stage plus legacy graph | 7,640,505 | 7,640,505 | 0 |
| Instructions, `tables` (median of 3) | 4.248 G | 4.215 G | -0.77% |
| Instructions, `graph` (median of 3) | 9.241 G | 9.230 G | -0.12% (inside the 0.3% spread between rounds) |
| Peak RSS, `tables` (median) | 132.3 MB | 131.8 MB | -0.5 MB |
| Peak RSS, `graph` (median) | 326.1 MB | 324.5 MB | -1.6 MB |

Per round, retired instructions (base, candidate):

| round | `tables` | `graph` |
| ---: | --- | --- |
| 1 | 4,247,723,731 / 4,219,174,096 | 9,257,416,355 / 9,271,964,617 |
| 2 | 4,258,088,828 / 4,215,046,733 | 9,240,755,618 / 9,229,614,898 |
| 3 | 4,240,545,638 / 4,209,494,778 | 9,236,787,636 / 9,206,580,739 |

`discovery_dump counts` (the discovery phase's own counters): 576,606
allocations on both; releases 528,328 on the base and 528,332 on the candidate.
The `tables` dump of the whole compiler is identical except for the removed
`diagnostic_arguments=0` count in the last line and the four extra releases.
(An earlier head, with one diagnostic union and the construct as a free field,
measured 4.257 G to 4.204 G on `tables` and 9.283 G to 9.243 G on `graph`
against `9e270d350`: the same allocations.)

## Reading

- The self-compile has no diagnostics, so the diagnostic rows cost nothing
  there. A diagnostic is now a `record` row holding a union (a struct field
  cannot hold a union): one allocation per diagnostic, on a path a compiling
  program never takes. The four removed instructions-per-row checks (argument
  count, range, kind, construct decode) were a loop over every diagnostic and
  are gone.
- `freeze` no longer clears the transient fields with a record update before
  checking. It moves the 54 output lists into `DiscoveryTables` (one record
  allocation, replacing the one the clear made) and drops the builder with its
  parse state and four intern indexes. Allocations are unchanged; the
  instruction saving is the removed clear and argument check, not a changed
  hot path.
- The intern indexes (`name_slots`, `path_ids_by_text`, `module_ids_by_path`,
  `literal_slots`) were frozen output with no reader; they are dropped now. The
  peak RSS difference on `tables` is within the spread between rounds.
