# Ranked getter preparation status

Preparation-only production edit applied after root GO. The original handoff,
proposal, snapshots and test-runner evidence remain retained; this note updates
status without changing their pinned bytes.

The first two control attempts stopped before cases ran: v1 used an invalid
inline conditional in a record field; v2 left multiline Boolean assignments
unparenthesized. v3 parsed but passed 369/372 emitter tests: all 365 old tests
and four new controls passed. The three new failures were inaccurate output
premises. An unchanged-compiler public-emitter probe retained actual C: receiver
declaration and assignment are separate; an unknown f16 getter produces the
precise unsupported-body error; plain synthetic struct getters use the existing
cast/runtime/unbox fallback, while explicitly shaped getters inline a guarded
struct load. No production defect or behavior fix is claimed.

Corrected v4 baseline passed 372/372 emitter tests, 36/36 tensor tests and
14/14 plus 5/5 contextual runtime tests. The scratch production oracle compiled
and returned 0. Its 39,058-byte C artifact SHA is
`6d6faf6b39697b83663601ccb585c959b67728f2395436886dc4a1f2c0bd8ac7`.
It demonstrates rank3/4/5 production fixed-record loads, typed f64/f32 shape
runtime calls and erased Float16 calls with explicit unboxing. The independent
runner retained baseline provenance and released its native slot.

Applied preparation emitter SHA:
`5fe71603571ab2614b80fc6d6b22b168fb056bb7039e5d78e19a28a497dd9e9b`.
The source matches approved proposal
`1e54bd0b1f891dd988763a807c5cce473fd6a405201de0474e8bc719808ff15e`.
It replaces the two rank/shape name tables with one exact ABI admission, retains
closed representation in checked parts, and leaves both width suffix readers
and their allowlist rows intact. Diff hygiene passed; native preparation
qualification is runner-owned and pending at this note.

The next renderer patch is **unapplied**, pending preparation qualification and
root GO. `renderer.final.proposal.patch` SHA
`23c7f33b0bc0762ef49311f7a866d22f678d78d58365fd413cf04de842e3ab68`
matches the three representations with unchanged rendering arguments/strings.
Anticipated final emitter SHA:
`24b9bf114c3db06ba8277bccff6e1559d147ad112adc99a33df6991984bebc31`.
Root owns later deletion of exactly two allowlist rows, integration and docs.

No native commands, commits or broader edits were performed by this worker.
Final correctness, whole-C identity and matched allocation/instruction +0.5%
ceilings remain required; baseline control success is not final acceptance.
