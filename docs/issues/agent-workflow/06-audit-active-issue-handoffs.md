# Audit Active Issue Handoffs Against Current Code

**Status:** Proposed

**Owner:** `docs/issues/README.md`, active issue index, and a read-only audit

**Current state:** Issue retention and a current-state card are documented;
there is no mechanical audit or completed human pilot of one issue cluster.
**Next action:** Test a read-only link/index/shape audit, then review only the
named pilot directories against current code and measurements.
**Read first:** `docs/issues/README.md`, the two late-Core latency handoffs,
and their retained result in `benchmarks/results/`.
**Fast loop:** The proposed `test_audit_issue_handoffs.py` on tiny Markdown
fixtures, then one pilot-directory audit.
**Decision:** Accept mechanical findings plus human dispositions; reject
automatic deletion or semantic conclusions from status words.

## Objective

Keep `docs/issues/` a trustworthy list of *next executable work*, not a second
history archive. Add a small read-only audit for mechanical drift and pilot a
human review of one issue cluster. Apply the existing retention rules; do not
automatically delete documents based on a status word.

## Why

`docs/issues/README.md` already says to delete handoffs that are implemented,
rejected, or superseded after moving current contracts to reference docs and
reusable measurements to `benchmarks/results/`. Yet issue documents can retain
present-tense descriptions of pre-change code or a checklist whose criteria
were never met. An agent following such a handoff may repeat a failed
experiment or mistake an accepted partial slice for a finished issue.

The September 2026 preparation-index and consume-index issues are useful pilot
examples: one needs a revised admission experiment after a negative latency
result; the other has an accepted initial implementation but unmet allocation
and stress gates. Preserve those distinctions rather than filing both under
"done."

## Proposed Audit Behavior

Use a read-only command such as `scripts/audit-issue-handoffs`. This example
defines intended UX, not a current command:

```bash
scripts/audit-issue-handoffs --scope docs/issues/agent-workflow
scripts/audit-issue-handoffs --scope docs/issues/late-core-latency --json
```

Mechanical findings can include:

```text
docs/issues/late-core-latency/03-index-consume-specialization-candidates.md
  indexed in docs/issues/README.md: yes
  status: initial implementation; full acceptance open
  lines: 400 (above ~300-line guideline; review, not automatic failure)
  local links: valid
  action: human review of remaining acceptance boundary
```

The command may report missing/broken index links, missing `Status` or
`Objective`, orphaned index entries, and long documents. It must label
semantic staleness as "needs human review" unless corroborated by an explicit
source-of-truth check. A filename number, checked box, or phrase "implemented"
is not authority to delete a document.

### Human disposition examples

```text
Case A: Whole issue implemented, all acceptance gates met.
Move current behavior to ARCHITECTURE/GUIDE if needed; keep raw measurements in
benchmarks/results; remove the issue file and active index link in one change.

Case B: Initial slice landed, later stress gate remains.
Rewrite the handoff around the remaining experiment, current production code,
and the precise unmet gate. Do not retain the old implementation plan as
present-tense instructions.

Case C: Prototype rejected on actual latency.
Record the result in benchmarks/results and either remove the issue or state a
new admission gate and next experiment. Do not leave the rejected plan marked
ready to implement.
```

## Pilot Scope And Sequence

1. Start with `docs/issues/agent-workflow/` and
   `docs/issues/late-core-latency/`, not all issue documents at once. Record
   the baseline audit findings.
2. Add a parser/link/index test for the audit command using small temporary
   Markdown fixtures. Confirm read-only behavior.
3. Run the mechanical audit on the two pilot directories. Have a human/agent
   reviewer inspect current implementation, focused tests, and benchmark
   results for each substantive disposition.
4. Update only the pilot handoffs and active index. Move still-current
   contracts/evidence before deleting any resolved file.
5. Report counts of retained, narrowed, removed, and review-needed items and
   propose the next bounded cluster; do not silently expand to all issue files.

## Fast Feedback Loop

```bash
python3 blorp/test/build/test_audit_issue_handoffs.py
scripts/audit-issue-handoffs --scope docs/issues/late-core-latency
git diff --check
```

The test and audit commands above are proposed. For docs edits, also validate
local Markdown links and each shown executable command. Do not run a full
compiler gate merely for status-word edits; run the focused behavior check only
when a moved current-contract claim needs verification. Get documentation
review and a test-evidence review before commit.

## Acceptance / Rejection

- [ ] Mechanical audit is read-only and deterministic on a clean checkout.
- [ ] Broken links/orphaned index entries and missing core handoff fields are
      found without guessing whether code is implemented.
- [ ] Long documents are guidance warnings, not automatic deletion failures.
- [ ] Pilot dispositions cite implementation/tests or measured evidence; no
      current contract or reusable raw result disappears.
- [ ] Active index links only to actionable, current handoffs in the pilot.
- [ ] A new agent can identify the *next action* in each retained pilot issue
      without treating historical text as current instructions.
- [ ] If the proposed audit becomes a complex Markdown parser or unreliable
      semantic classifier, reject that part and keep a small link/index audit
      plus explicit human review.

## Non-Goals

- Auto-closing issues or deleting files based on checkboxes/status text.
- Rewriting every document under `docs/issues/` in one change.
- Maintaining an archive directory under `docs/issues/`.
- Replacing Git history, GitHub issue discussion, or benchmark results.
