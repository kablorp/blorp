# Blorp 2 explicit base imports, prelude shape and import cycle ban

Branch `blorp2/imports-prelude-cycles`. The change makes `_base` an explicit
import (library modules no longer see base types implicitly), takes the
prelude's types from `_base` with `methods_only` operation selections, rejects
import cycles after loading, and rejects library modules that import user
modules. User programs are unchanged, and so is their generated C. This report
records what the change costs per compilation and where that cost comes from.

## Summary

For return/zero, the same user program now costs **1,216 more allocations
(+13.1%) and 4.4M more retired instructions (+7.5%)** than before the change.
Before the fixes below it cost 1,639 more allocations (+17.7%) and 5.5M more
instructions.

The remaining 1,216 allocations break down by phase as:
- 869 from lexing the import rows and comments the library now contains;
- 314 from parsing them;
- 116 from building the namespace, once, during checking;
- 83 fewer than the baseline in the rest of loading, which now includes the
  cycle walk and the library-to-user check.

These sum to 1,216, the end-to-end difference, so no part of it is
unattributed.

The lexer and parser costs come from how `lex.brp` and `parse.brp` work today,
not from the import design. The namespace still does more work per selected
name than the old implicit copy did.

## Per-phase allocations (return/zero)

A probe reads the host's managed-allocation counter around each phase of one
compilation: `load_program` (each loaded module re-lexed and re-parsed
separately to split out lexing and parsing), a standalone `build_namespace`,
checking, and the rest of the pipeline. Both runs used detached worktrees at
the same path depth. The probe is
`blorp_2/build/imports_prelude_cycles/phase_probe.brp`. "Before fixes" is
`aba70ab87`, the explicit imports and prelude without the cycle walk; "final"
is the source of the commit that adds this report.

| Phase | Baseline `eccf3aa99` | Before fixes | Final |
| --- | --- | --- | --- |
| Lexing every loaded module | 5,475 | 6,344 | 6,344 |
| Parsing every loaded module | 1,730 | 2,044 | 2,044 |
| Rest of loading (paths, resolution, cycle walk) | 334 | 545 | 251 |
| Namespace (standalone build) | 238 | 444 | 354 |
| Checking, including its namespace build | 1,595 | 1,801 | 1,711 |

A compilation builds the namespace exactly once, inside checking
(`src/check.brp:4666`). The standalone build in the table is an extra copy the
probe makes to measure it. Checking grows by exactly the namespace's growth
(+206 before the fixes, +116 after), so the rest of checking allocates the
same as at the baseline. Specialization, lowering, ownership, verification and
emission are unchanged.

The "before fixes" probe is `aba70ab87`, which has no cycle walk. Its phases
sum to +1,600 against +1,639 end to end for `2d16f8a88`. The 39 between them is
what `2d16f8a88` adds over `aba70ab87`, chiefly the cycle walk and the
library-to-user check. It was not attributed further at that commit; the walk
alone measures 42 on return/zero in the final code, whose walk is structured
differently.

Namespace stages, from an instrumented copy (baseline, then before fixes, then
final):
- `import_module`: 45, 248, 158;
- forwarding fixpoint (`complete_types`): 80, 108, 108;
- prelude copy to user modules (`implicit_types`): 76, 19, 19;
- request collection: 5, 26, 26;
- sealing: 7, 18, 18.

Method requests went from 8 to 38.

## Causes and changes

1. **Fixed: redundant path normalization.** `import_path` called
   `Path.normalize` on every resolved import (`src/load.brp`, formerly the last
   line of `import_path`). The importer path and library root are already
   normalized, and the parser admits only identifier path components, so the
   result was already normal. `Path.normalize` splits the path into
   components and rebuilds it. That is about 37 allocations per import at this
   checkout's depth, and it grows with path depth. Removing it also removes
   that cost from the imports that existed before this change, which is why
   loading now costs less than at the baseline.
2. **Fixed: the import scan was rebuilt twice per selected type.**
   `import_receiver` (`src/namespace.brp`) built the scan record once to add
   the method request and again to add the bound type. `ImportScan` holds
   lists, so it is a managed record and each rebuild allocates. One record
   update per selection removes 90 allocations here.
3. **Not changed, outside this branch's files: the lexer allocates per byte.**
   `src/lex.brp:347` takes `source.substring(cursor, 1)` on every loop
   iteration, `run_end` (`src/lex.brp:264`) takes one per byte it scans, and
   comment bytes go through `src/lex.brp:424`. Each allocates a one-byte
   String. The loaded library grew by 369 code bytes and 157 comment bytes,
   and lexing grew by 869 allocations: about 1.9 per code byte and 1 per
   comment byte. Lexing is about 60% of the whole compile's allocations at
   the baseline too. Comparing bytes without allocating, for example through
   the host String `get_or` that returns a `Char`, would remove most of it;
   whether `Char` belongs in Blorp 2's source subset is the layout branch's
   decision.
4. **Not changed, outside this branch's files: parsing costs about 4
   allocations per token.** The 314 extra parse allocations cover about 90
   added tokens. It was not investigated further.
5. **Remaining in the namespace: +116.** Each explicit selection still costs
   about 4 allocations in `import_module`: an `ImportSite` record (managed,
   because `ImportSelection` holds a list), the candidate list built by
   `selected_type`, the boxed result and one scan update. The forwarding
   fixpoint re-resolves every request in every round. The planned removal of
   type forwarding (held until the checker split lands) makes resolution a
   single pass over declarations and deletes the fixpoint. The old implicit
   path copied about 112 base rows for about 2 allocations each, so explicit
   selections still cost more per name than that copy did.

## Matched end-to-end results

Allocations are identical across samples; instructions are medians of five.

| Fixture | Baseline | Before fixes (`2d16f8a88`) | Final (this commit) |
| --- | --- | --- | --- |
| return/zero | 9,263 / 58.47M | 10,902 / 64.01M | 10,479 / 62.87M |
| import/method_modules | 12,748 / 70.82M | 14,392 / 76.86M | 13,707 / 75.05M |
| import/prelude_helper | 10,567 / 62.77M | 12,215 / 68.69M | 11,742 / 67.38M |
| calculator/integer | 38,340 / 146.95M | 40,128 / 152.75M | 39,512 / 151.11M |
| calculator/float | 38,350 / 147.94M | 40,138 / 153.54M | 39,522 / 151.80M |

The cycle walk alone, measured against the final code with the walk given no
rows (`nowalk.patch`), costs 42 to 60 allocations and at most 0.24M
instructions. Generated C is byte-identical across all variants.

## Provenance

- Host: FRESH `bin/blorp`, SHA256
  `474243d4b908fb52e49a93305997255cb21e084f5a33fa74c2c623ba1d1dfa81`, Apple
  clang 21.0.0.
- Each pilot variant was compiled with `bin/blorp compile --no-format` and
  linked with `clang -O0 -DBLORP_MEMORY_DIAGNOSTICS=1`. Binary SHA256s:
  - baseline `d414c0196e78003ae8acae8ddf6166f2d6ecda8e98c97ab433886f7d379b189d`;
  - before fixes `1b40e27e6fc1b2fe05f97267390f0ed92922eb2907be253119ecd022e0b11048`;
  - final `09e8d53163cb2081b49d90d1e56ecfae0a8d914894fe6912fd87e2ec554c4ab6`;
  - final without the walk `2e1e604edbc54883e98b982246f3c0a593a245b1c83611f72f8de5e6dc508bb5`.
- Each variant compiled the fixtures from its own detached source tree and
  target library, at the same path depth. Runs were serial and interleaved.
- Allocations come from the strict leak report, and every run had zero leaks.
  Instructions come from macOS `/usr/bin/time -l` and include process startup.
- Raw samples, the scripts, the probe and the patches are in the ignored
  `blorp_2/build/imports_prelude_cycles/` directory.

## Limitations

- Absolute counts depend on the checkout path, because paths are inputs. The
  normalization fix in particular saves more in deeper checkouts. Compare
  variants only within one matched set.
- These are small-fixture compilation proxies. They do not measure
  self-compilation, and they include process startup and library loading.
- The per-phase probe re-lexes and re-parses each module outside
  `load_program`, against a fresh name table, so its lexing and parsing figures
  approximate the work inside loading rather than reproduce it exactly.
