# Lowered call anchor boundary — 2026-10-19

Status: **accepted for landing**. The separately reviewed
[plan](../../blorp_2/PHASE_BOUNDARY_CLEANUPS_PLAN.md) is commit `e89eb0cd4`.
Fixed B is main `eb7b9fe1bd5dec40a8a2dd8acfae27fd02b53e6e`.

## Change and scope

Lower chooses a call definition's callee anchor once and stores the existing
`CallTarget` plus arguments in the operation. Own forwards those facts. Verify
receives the target and enclosing definition span while retaining independent
target, argument, result, layout, ownership and backedge checks. Emit uses the
target directly. `ConcreteCall` and its distinction from the whole expression
remain intact before Lower. No new type, registry or general span removal.

Four production modules: **22 ADD / 22 DEL, net 0**. Test owners:
**191 ADD / 310 DEL, net −119**; README: **4 ADD / 1 DEL**. No fixtures.
The separately committed plan is documentation. The simplification removes a
duplicated authority and obsolete test wrappers; it is not a production-LOC win.
Production patch SHA256:
`9873db23bd446e9e2c57fb9db904ce194d6c0ebaf50ebcea36edcfaea8ee3aca`.

## Correctness and identity

Baseline-compatible tests strengthen absolute Own anchors and add an
authority-issued unknown-user-target rejection with exact message, help, note,
source and byte bounds. The five focused suites pass **59/59** before and after
the migration. This is a representation cleanup, not a semantic bug with RED.

Two deliberate mistakes reach ordinary assertions: Lower using the whole
expression span gives **54 PASS / 5 FAIL**; shifting Verify's call-signature
anchor gives **50 PASS / 9 FAIL**, including unknown-user-target and malformed
runtime-contract checks. Each byte-exact restoration gives **59/59 PASS**,
empty stderr and all original workspace pins restored.

The first full component run found **3,507 PASS / 10 FAIL**, confined to raw
List-contract verifier tests. Four old test constructors deliberately supplied
nested call anchor `20..21` and enclosing definition anchor `30..31`. Removing
the nested carrier left ten assertions expecting its old location. That
contradictory raw state has no equivalent in the new representation. Only those
ten expectations change to the sole definition anchor `30..31`; messages, help,
notes, source checks, exact bounds and type/argument/constructor priority remain
checked. Source-program diagnostics are unaffected.

`WORKSPACE_AMENDMENT.json` records the one test-file hash change against the
immutable original source freeze. All compiler sources, artifacts, libraries,
fixtures and cost inputs remain identical. Original failed logs are retained.
The expanded six-suite loop, now including List membership, passes **106/106**,
with empty stderr and all **1,009** before/after pins unchanged.

All **496 frozen fixture roots / 992 normal CLI calls** match exactly on status,
stdout, stderr, C presence and successful C bytes: **400 successful outputs and
96 diagnostic failures** per producer. Support modules are also tested as roots;
this is CLI identity, not a claim that every root is executable.

Final components pass **3,517/0**, tooling **7/0**, and native **1,095/0**
(494 fixture/group callbacks, 600 nested checks and one umbrella). Every gate
exits zero with empty stderr and all **1,009** before/after pins unchanged. All
**402** native compiler-cost rows have positive required counters within
unchanged caps and strict zero accounting; C11/O0 ASan/UBSan settings remain.
Final attempt-02 receipt SHA256:
`20a83b36daf1fea161449332bcd0ac5cc6370910bea840c0d7e6fe5def168ba4`.
Focused and mutation counts overlap full gates and must not be added as unique
test coverage.

## Matched costs

One diagnostic and three serial normal samples per producer/input use fixed
source, library and output paths. Normal order is B1,C1,C2,B2,B3,C3. All original
samples are retained. Allocation is the unique schema-1 cumulative
`artifact_construction_complete` checkpoint for the host construction proxy;
target diagnostic samples have positive balanced strict totals and zero live
objects/bytes. Instructions are original normal min3; RSS is normal median3.

| Input | Allocations B → C | Instructions B → C | Median RSS change |
| --- | ---: | ---: | ---: |
| proxy | 25,518,067 → 25,515,123 (-0.012%) | 46,695,884,567 → 46,658,748,377 (-0.080%) | +851,968 B (+0.341%) |
| call/one.brp | 10,687 → 10,687 (0.000%) | 38,176,511 → 38,152,900 (-0.062%) | +16,384 B (+0.311%) |
| ufcs/chain_64.brp | 21,372 → 21,372 (0.000%) | 52,916,324 → 52,843,489 (-0.138%) | -49,152 B (-0.836%) |
| generic/named/managed.brp | 24,231 → 24,231 (0.000%) | 56,174,966 → 56,171,309 (-0.007%) | +16,384 B (+0.291%) |
| option_input/parse_int.brp | 12,229 → 12,229 (0.000%) | 40,319,949 → 40,312,510 (-0.018%) | 0 B (0.000%) |
| file_read/ownership.brp | 16,733 → 16,733 (0.000%) | 47,206,931 → 47,232,395 (+0.054%) | -49,152 B (-0.882%) |
| file_write/ownership.brp | 22,502 → 22,502 (0.000%) | 55,947,392 → 55,893,377 (-0.097%) | 0 B (0.000%) |

The proxy saves **2,944 allocations (0.012%)** and **37,136,190 min3 instructions
(0.080%)**, with median RSS **832 KiB higher (0.341%)**. Target allocations are
flat; instruction/RSS movements are mixed. All comparisons remain below the
prospective attention/hard thresholds. No additional batch or exception is
needed under the user's overall-direction policy.

At the single instrumented construction checkpoint, current objects are
1,432,527 → 1,432,366 and allocator bytes 120,431,872 → 120,420,368. Those are
construction observations, separate from normal RSS. The host proxy omits
linking, target self-compilation and unavailable target lifetime measurements.
Earlier physical retirement is not established: pre-Lower wrappers and existing
outer phase roots can remain alive. No elapsed-speedup claim is made.

## Provenance, C inspection and review

All 41 B source hashes match the accepted F2 candidate and initial main, allowing
reuse of its normal/diagnostic pair after artifact checks: `405899c2` /
`e0c27424`, C SHA `9dbcc103`. All measurements in this report are fresh.
The FRESH borrowed repository host is `97479b34`; paired construction hosts are
`6852e1c6` / `a362b0df`. The host library and current target library are frozen.

Candidate normal `674260e1` / diagnostic `99d874b2` each link once from unchanged
C SHA `d97b3f2f`, at O0, diagnostics=0/1, `-lm -lpthread`, Apple clang21. Each
link retains 90 inherited warnings in the same three classes. Within each role,
normal and diagnostic samples emit identical fixture/compiler-source C.

Generated compiler C changes call payload casts from the `ConcreteCall` record
to the existing `CallTarget` union; the emitter no longer loads the record's
target field. The pre-Lower record still exists. Fixture C is byte-identical.
Saved C excerpts and hashes support this inspection without claiming physical
retirement from logical erasure.

Raw evidence is under ignored `build/lowered-call-anchor-2026-10-19/`: baseline
and source freezes, separate test amendment, all commands/raw samples, COSTS,
IDENTITY, mutations/restorations, original RED and subsequent gate attempts,
compiler artifacts and independent review receipts. Preserve this complete
packet in the primary checkout before archival or borrowing its images.

Independent code-reviewer and test-runner reviews approve the implementation,
test amendment and overall resource direction. Final report checks precede
publication; no cost exception is required.
