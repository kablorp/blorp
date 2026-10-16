# Blorp 2 shared record-field admission

This preparation extracts structural record admission into one helper over a
complete CheckedRecord. It returns the existing ResolvedLiteralField rows in
written order; declarations own FieldIds and types. Body planning retains nominal
hints, arity, child scheduling and updates. No new carrier, module, solver, index
or runtime path. M5a.2 can reuse admission without manufacturing a function context.

Production: **42 added / 35 deleted / +7 net**, within 96 added / +24 net.
Tests: 247 added, none deleted; fixtures: unchanged. Root and an independent
compiler expert approve the source; an independent runner validates the gates.
Combined M5a uses 393 added / +266 net, leaving 357 added / +334 net against
750 / +600. Formatting and existing coverage remain intact.

Nine pre-move characterization/constructor callbacks pass. Candidate focused
checks pass 154 callbacks across eight suites. Five temporary faults produce six
exact semantic failures: reversed ordinary/generic rows, duplicate acceptance,
last-missing selection, arity before structural admission and wrong duplicate
NameId. All 40 restored callbacks pass. The NameId fault preserves rendered text,
proving the typed identity assertion matters. An initial unsupported list-spread
fault fails before callbacks; its setup evidence is retained and excluded from
semantic proof. A supported two-field fault replaces it without assertion edits.

Matched measurements use accepted-main `5770a9a4b` source (Git `d24d04af7` has
identical source, library and fixture bytes) and existing M5 pilot `45571a51`,
C `ca8248dd`. Candidate `4fb3afdb`, C `c9d9d458`, is built once with frozen host
`899e0a92`, an O0 diagnostic link, and Apple Clang 21 on macOS arm64. All 452
fixture files and eight library files are immutable Git copies at one physical
input path. The 356 accepted full C outputs and 96 rejected full diagnostics and
outcomes match. Strict 904 calls balance allocations/releases with zero leaked
objects/bytes; normal 2,712 calls use three alternating B/C pairs per input,
with memory variables unset outside time.

|Scope|B allocations|C allocations|B sum of per-input min3 instructions|C sum|
|---|---:|---:|---:|---:|
|356 accepted|4,721,763|4,719,800|15,107,464,568|15,077,496,429|
|96 rejected|725,955|725,939|3,146,648,824|3,139,379,288|

Every per-input 3% ceiling passes. Largest allocation growth: 0%. Largest normal
instruction growth: 0.140518% (`string_literal/escapes.brp`). Total allocations
fall 1,979; instruction sums change −0.203996%. These small effects establish
bounded cost, not a general speedup claim.

Eight canonical-path frozen-host source-to-C calls give 43,634,015,247 →
43,631,991,863 normal min3 instructions and 23,666,191 → 23,645,837 cumulative
`artifact_construction_complete` allocations. Both 3% caps pass. These are
host-build proxies, **not self-compilation**. Target strict/normal C and host
normal/diagnostic C agree at their respective boundaries. Source, input,
toolchain, binary and raw/semantic index endpoints match; the host remains
FRESH. Link warnings remain 83 in the prior three categories.

Actual-main `make -C blorp_2 test` passes 2,902 component checks (2,736 host
callbacks and 166 nested C checks) and all 452 e2e cases, with 358 native links
and 529 runs. Frontier remains 36/38 at the unchanged Char/function-type stops.
Destination compiler C matches `c9d9d458`; its O0 binary is `e6a742ca`.
The runner preserves both gates and endpoint evidence under the primary
checkout's `blorp_2/build/record-admission-landing/`. Host/version capture formats
initially differed; matching-format checks confirm unchanged binaries/toolchain.
Input behavior is unchanged; record constants and initializer references remain unsupported.
Existing field/name scans make wide-record admission quadratic. A declaration-local
field index and a local NameId-to-first-span map could replace those scans when
measured widths justify them; this preparation adds neither.

Raw evidence remains in the `roadmap-record-admission/blorp` worktree under
`blorp_2/build/record-admission-prep/`: `name-identity-review/BASELINE_REPORT.md`,
`sensitivity-a-repair/RUN_REPORT.md` and `cost/` (recipes, 3,624 samples, manifests
and runner receipt). Root independently recomputes all pairs/minima and C identities
in its integration worktree's `blorp_2/build/record-admission-landing/root-independent-cost-audit.json`.
No sampling retry, changed cap, rewritten input/C or hidden fallback occurred.
