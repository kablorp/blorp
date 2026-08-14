# Definition-index exact-name sub-index

Date: 2026-08-14

## Change

The definition index now stores callable and source-definition entries in
module-display-name and declaration-name buckets. Both levels are search
accelerators only. Exact typed key equality still determines identity, so the
index preserves overloads, source-definition kind and owner distinctions, and
direct modules whose display names collide.

Bulk graph construction uses a private module build state. It extracts a
module's two name maps once, reserves all declarations against those local maps,
and commits the maps, counts, and next-definition frontier together. This
avoids reconstructing the outer persistent dictionaries for every declaration.
Public insert operations retain their conflict-checking behavior, and all
binding projections remain sorted by definition ID.

Two alternatives were measured and rejected:

- Updating the nested persistent dictionaries for every declaration improved
  lookup cost but regressed optimized end-to-end phase time through repeated
  copy-on-write updates.
- A global integer hash-bucket index increased high-cardinality persistent-map
  work and regressed the optimized workloads. It also introduced more identity
  machinery than the exact-name partition required.

## Method

The accepted design and the parent revision were built through the benchmark
runner's plain mode, which compiles generated C with `-O2`. Each sample repeated
the selected phase 100 times over eight modules, 32 type shapes per module, 64
callable probes per module, and import fan-out four. Old/new samples were
interleaved, alternating execution order to reduce machine-drift bias.

The parent executable was cached under source key
`3d08e8250dfa898b9cb7bc4f2b7b6b717c8e7dcb822da2dd94b9ea26dfcf3358`.
The initial accepted executable used source key
`d48faad0c1a857560cdb56e7fae26414c2ae841279e7e34d5e009eb11d06e060`.
After review moved the module bucket into the private builder and added the
bulk-path regression, the final indexed-graph executable used source key
`5d767c55a3e76bc000a913e07590bc3b4ac1eca8832e819cc6ffc06a8fcf1316`.

Function instrumentation remains useful for locating work, but its `-O0`
generated C does not faithfully price persistent collection updates. Optimized
plain-mode phase time is therefore the acceptance metric for this change.

## Results

The final hardened source was remeasured for five indexed-graph samples:

| Phase | Parent median | Final median | Improvement |
| --- | ---: | ---: | ---: |
| indexed graph | 237.489 ms | 171.012 ms | 28.0% |

The initial seven-sample comparison also measured the downstream phase windows,
whose inputs retain the same accepted index representation:

| Phase | Parent median | Accepted median | Improvement |
| --- | ---: | ---: | ---: |
| declaration skeletons | 1,322.110 ms | 1,277.778 ms | 3.4% |
| type headers | 324.623 ms | 308.622 ms | 4.9% |

Final indexed-graph fixture setup improved by 3.4%. The initial skeleton and
header fixture setup improved by 2.3% and 4.3%, respectively. Every old/new run
produced matching output counts and structural checksums:

- indexed graph: `4670244483574288338`
- declaration skeletons: `6872614984571147590`
- type headers: `-3934367748944683623`

The checksums are equivalence guards, not substitutes for the focused identity,
phase-contract, and sanitizer suites.

## Rough Edge

Generated C identifiers can inherit an absolute workspace path. A temporary
worktree whose path contained hyphens produced invalid C identifiers during this
comparison; using an underscore-only temporary path avoided the unrelated
failure. Compiler symbol sanitization should eventually make generated output
independent of workspace punctuation.

While adding the bulk-builder regression, equality between two apparently
equivalent `List[Option[String]]` values evaluated false even though each
unwrapped owner matched. The test now compares unwrapped strings, but nested
generic structural equality should be characterized separately.
