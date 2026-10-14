# Local ownership-use builders

Status: source, focused tests, generated-host-C proof, quiet matched costs and
full strict/e2e gates pass. Two independent compiler experts approve the final
source and evidence with zero P0–P3 findings. This accepted increment is bounded
preparation after multiple union fields, not a new language feature.
No commits, pushes or conflict resolution had occurred at validation time.

## Behavior and authority

Only `blorp_2/src/own.brp` and its direct unit suite change. Last-use positions,
ValueIds, ownership obligations, acquisition/drop scheduling, diagnostics and
target C remain unchanged. The private validator returns a checked optional
local slot rather than a modified vector. Prefix reads return None; valid local
reads return Some(index). Definition and terminal loops update local vectors,
then publish the complete result. The operand visitor explicitly handles all
eleven ValueOperation variants, including six leaves with no reads.

The obsolete `record_use` and `record_argument_uses` vector-returning helpers
are removed. The unused `uses`/`position` parameters and call arguments of
`build_definition` are removed; its actual ownership decisions and surrounding
last-use/drop scheduling remain. No public fact, phase, cache, index, host
compiler, ABI, verifier or ownership-placement policy changes.

## Physical proof and scope

Ignored evidence is under `build/roadmap/ownership-builders/`, with
`HANDBACK.md`, `C-ownership.md`, recorder packets and frozen review artifacts.
Core identities, translated using the existing C-symbol projection authority,
establish the actual roots and setters; the claim is not inferred from source
style or C spelling.

Definition writes directly consume the local use-vector root. Terminal writes
use a builder introduced after successful terminal-span validation. Its
initializer can share the outer snapshot, causing one initial O(V) copy of V
slots. Subsequent setters directly consume its evolving root; they retain no
old updated root per operand. Final publication occurs outside the loop.
Prefix-only and empty terminals perform no setter.

This eliminates the old O(F*V) copying mechanism for F local/terminal reads.
It does not prove global linearity or zero copies. Operand maps/singleton lists,
host scalar boxing, lowering definition-prefix copying, nominal-instance scans
and duplicate-name scans remain distinct costs. The deferred lowering cleanup
and Lists are later work; this round stops at the validated milestone.

Two unsuccessful physical probes remain separate evidence. The first fixed
definition updates but retained the terminal root per write. An early error gate
in the second still left sharing across span propagation; that probe was never
linked or benchmarked. The independently reviewed local terminal builder is the
settled solution. No failed binary/C pairing is used for acceptance.

## Tests and oracles

Ten named direct callbacks were added while all 25 existing own callbacks remain.
They cover a valid normally lowered three-argument call with repeated/prefix/local
reads, a normally lowered repeated-child constructor, empty prefix return,
self/forward reads, tail-recur repeats/offsets/empty operands/explicit spans,
definition identity before operand errors, and first-error ordering. Successful
cases compare full vectors; failures check exact message/help/source/span and
absent notes. The corrected test-first baseline passes 87 checks across three
suites before production changes. An earlier malformed positive call setup was
replaced before implementation and is not used as acceptance evidence.

Duplicate same-position writes are idempotent: these tests observe duplicate
input IDs and the final last-use slot, not the number of writes. Independent
storage-obligation tests still protect two acquisitions for Pair(x,x). Negative
opaque IDs and a private short vector cannot be constructed through approved
public APIs; their original guards remain without unchecked factories or a
test-only seam.

Settled-source mutations prove the observers: returning the wrong local slot
gives 19 passes/16 failures; shifting terminal position gives 24/11. Exact
restoration returns 35/35, then the full focused 113 checks across four suites.
One earlier unchanged-source green setup control is explicitly excluded from
mutation proof.

Final combined validation:

- Sanitized unit/runtime/grammar: 1,985 printed checks across 124 summaries,
  exit 0, zero failures, no source drift, 31.922 seconds. The strict launcher
  reports three balanced allocations/releases and zero leaked bytes; that
  counter does not count all compiled child processes.
- Normal e2e wrapper: 321 cases, 762 printed checks across 309 summaries,
  exit 0, no timeout/source drift, 178.834 seconds, exactly one pilot generation
  and link. Target fixture C remains unmodified and executes its real main.

Native ASan/UBSan, compiler counters and separate allocation-occurrence runtime
tests remain different evidence. Native LeakSanitizer is unavailable. The
existing host nested List/Option pattern issue remains unresolved.

## Provenance, costs and size

Branch `codex/blorp-2-aggregate-roadmap`, HEAD `79deebd`. FRESH host SHA
`286a1720a36a75599f910e1b8ab838df642a3983409cd30ed3a6ef3dcf16ba79`,
Apple Clang 21 arm64, host CLI O0/runtime O2; pilot O0 with allocation diagnostics.
The immutable accepted multiple-field baseline compiler is `218ab776…`, source
`29af2e74…`, C `aaa53302…`.

The settled `review-final/sha256.txt` identifies:

- Source archive: `09fb0555bae201b109bc62a666aeebbb74e33786a5df0df6c1e53ce5f0c13431`.
- 503-input manifest: `2d7d736de69a73220129e2c117fe93fe9a3e8a2ed8788815f8a06e2aebeddc3c`.
- Native/cost executable: `b7d405f206157f9eff889976be170fab28a6e261434bb547cf64839ca7dc427e`.
- Generated host C: `bc77045d51f9500dfbde1b711c13424e8fb9f77c1fec21c63d7301edb954c17b`.
- Final wrapper executable: `24958ebd601a8a5725f231680b4869eec9cccb63e6a56552b7896d208919e6b0`.

The final wrapper emits that identical host C with its separately linked tested
executable retained. The ordinary host link produces 59 inherited warnings, the
same category counts as baseline: three discarded qualifiers, 41 extraneous
parentheses and 15 pointer/integer comparisons. This is not a warning-clean host
gate; exact logs are retained, and target fixture gates are separate.

Primary cost evidence is `cost-quiet-2-packet/`, `cost-quiet-2-results.json` and
`.md`: 20 fixed controls and 16 supported feature points, three paired samples
each, 216 strict-balanced runs and 108 identical baseline/candidate target-C
pairs. All 43 frozen workload/library files match. Allocation counts are stable;
instructions use minimum-of-three. All unchanged +3% control ceilings pass.
Maximum control allocation change is -0.0232%; maximum instruction increase is
+0.0134% for controls and +0.0766% for feature points. At scalar width128,
allocations fall 28,377 to 28,117 and instructions 114,725,097 to 114,100,192.
These are supported-input proxies, not self-compilation or a broad speed claim.

Sampled before/mid/after inventories in this primary epoch show no named
compiler process. Samples cannot exclude unrelated activity between observations.
The initial numerically passing epoch overlapped external compiler jobs and is
retained as contended, superseded for quiet performance acceptance. A separate
before/after-only rerun is also supplementary; primary midpoint is captured
inside the direct recipe between control and feature groups.

Production shrinks 17 physical /19 nonblank-noncomment lines; direct tests grow
274/252. Explicit leaf coverage, bounds checks, normal spacing and lifetime
comments remain; no coverage or formatting was removed to inflate reduction.
