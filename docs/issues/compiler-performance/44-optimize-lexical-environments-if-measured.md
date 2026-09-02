# Optimize Lexical Environments Only If Still Measured

**Status:** Conditional on Issue 43 profile evidence

**Dependencies:** Issue 43 and a measured remaining lexical-environment
bottleneck

**Parallel work:** None specified until the profile identifies an isolated
target.

## Objective

Optimize the lexical-only environment after graph declaration materialization
has been removed, but only if the controlled final profile shows that local
scope construction, copying, lookup, or destruction remains material.

This issue is a decision gate, not authorization to redesign `Scope` in
advance.

## Entry Criteria

Do not begin implementation unless Issue 43 reports all of the following:

1. the measured hot work is owned by lexical/session scopes rather than stale
   graph publication;
2. exact call counts or logical counters identify a repeated operation;
3. a production-shaped fixture can reproduce it independently;
4. the expected benefit is meaningful relative to Phase 01-06 latency; and
5. the optimization can preserve current lexical ordering and diagnostics.

If these criteria are not satisfied, close this issue as not currently
warranted.

## Candidate Directions

Choose exactly one measured direction for a concrete follow-up implementation:

- batch parameters, pattern bindings, or local declarations at an existing
  scope-entry boundary;
- separate exact local callable-ID lookup from source-name lexical lookup;
- replace a persistent structure whose actual lifetime is one body session;
- make uniquely owned lexical-scope update/move behavior explicit; or
- reduce repeated destruction of unchanged lexical scope structure.

Do not combine candidates. Turn the selected direction into a new focused issue
with before/after counters and leave this decision document as the roadmap
terminus.

## Constraints

- Preserve lexical shadowing and deterministic diagnostic order.
- Do not reintroduce graph declarations into `Env`.
- Do not add a heuristic unique-ownership assumption; represent ownership
  explicitly or rely on existing language guarantees.
- Do not trade latency for lower retained memory without explicit evidence that
  the trade is desirable.
- Do not add more production code than the measured simplification warrants.

## Acceptance Criteria

This issue is complete in either of two states:

1. **No action:** evidence shows no material lexical bottleneck, the decision
   and profile are recorded, and no code changes are made; or
2. **Follow-up opened:** one isolated optimization issue records the exact hot
   operation, production fixture, failing logical assertion, expected benefit,
   semantic risks, and validation commands.

Any implementation belongs in that focused follow-up and requires before/after
Phase 01-06 evidence plus the relevant lexical-scope tests.
