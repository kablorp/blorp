# ID census scaling

The census (`blorp/src/compiler_new/stage_01_discovery/syntax/id_census.brp`) was
quadratic in the size of a module, which stalled M4's full-tree corpus run at
about the 50th module. It is linear now.

## Cause

Two copies, neither of which allocates a managed object, so the allocation
counters stay linear while the time is not:

1. `by_family.get_or(slot, no_ids).append(id)` appended to a list that
   `by_family` still held, so each id copied its family's whole list so far.
   Removed: the census now makes one pass over the held ids per family.
2. The walk threaded a bare `List[HeldId]` through about sixty helpers. The
   consuming-clone pass only hands on records (`docs/OWNERSHIP_MODEL.md`,
   "Only record parameters are candidates"), so every helper that appended to
   its list parameter copied it. The walk now threads a record, `HeldIds`,
   updated in place.

The clean shape has no compiler limit left to record: a record threaded
through helpers is the pattern the discovery builders already use.

## Measurement

`bin/blorp test` of `probe_census_scaling.brp` (this directory; see "Re-running it"), `-O0` CLI, `-O2` runtime, `6af65febc` plus this change.
Microseconds for one `id_census` call; `before.log` and `after.log` have the
raw output. `managed_allocs` is the managed allocation counter around the call.
The `libc_malloc` column is not a reset interval and is not used.

| Shape | Items | Before us | After us | Before allocs | After allocs |
| --- | ---: | ---: | ---: | ---: | ---: |
| globals | 1,000 | 41,000 | 1,029 | 10,023 | 4,023 |
| globals | 2,000 | 217,629 | 2,032 | 20,024 | 8,024 |
| globals | 4,000 | 960,165 | 4,002 | 40,025 | 16,025 |
| statements in one block | 4,000 | 180,858 | 1,928 | 20,030 | 8,031 |
| elements of one list | 4,000 | 96,406 | 954 | 12,018 | 4,025 |

Each doubling of globals multiplied the old time by about 4 to 5 and the new
time by 2. The allocation counts were linear before and after: the copied
buffers are not managed objects, so a managed-allocation budget cannot catch
this class of regression.

## Re-running it

The probe is the retained benchmark; there is no timing test, because a
wall-clock ratio can flake under gate load. Copy it to a file under
`blorp/test/compiler_new/stage_01_discovery/syntax/` (its imports are
relative), run `bin/blorp test --timeout 300 <that file>`, and delete the
copy. Linear cost doubles when the item count doubles; a copy per item
quadruples it. Do not read `managed_allocs` as a guard: it was linear before
the fix.
