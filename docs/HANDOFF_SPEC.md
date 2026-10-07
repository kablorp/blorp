# Handoff Spec

Every issue file in [`issues/`](issues/) and every brief handed to an agent
follows this spec. It exists so that whoever picks up the work, a person or an
agent, can start without rereading the conversation that produced it, and
knows what done looks like, what not to touch, and when to stop and ask.

Write for the reader who has the repository and nothing else.

## Length

The prose stays under 3,000 words; code blocks do not count, so the limit
never argues against an example. Most briefs need well under 1,000. A
handoff that needs more is usually two handoffs, or a design that belongs in
its own document first.

## Sections

Four sections are core: every handoff has them, and Code whenever the change
touches code. Include each other section when its heuristic applies; a
substantial issue usually uses most of them. Leave out a section that does
not apply rather than filling it.

1. **Problem** *(core).* What is wrong or missing, as the user or the
   compiler sees it, with a reproduction: the exact input and command, the
   actual output, and the expected output.
2. **Background.** *Include when* the reader needs context the problem does
   not carry: the owning source and the one reference document for it (not
   every guide), decisions already taken and by whom, related issues.
3. **Proposed solution** *(core).* The approach and why it is right, the
   alternatives rejected and why, and the phase that owns the change
   (`AGENTS.md`, rule 8).
4. **Code** *(core whenever code changes).* Literate code examples, as many
   as the change needs. Quote the real code at the change site with its
   `file:line`, show the code after the change, and explain why each part
   changes. Read examples from the current source, never from memory. For a
   bug, show the reproduction and its output; for syntax, the source and the
   diagnostic text; for a compiler pass, the Core or C before and after. See
   the example below.
5. **Scope and non-goals.** *Include when* other work is nearby or the
   change could sprawl: the files and areas it may touch, the ones it must
   not, and concurrent work it could collide with. Adjacent problems found
   along the way are reported, not fixed.
6. **Risks and unknowns.** *Include when* the approach is uncertain or there
   is a known trap. For an uncertain approach, describe a spike: the question
   it answers, where the throwaway code lives (a scratch directory or a
   branch that never lands), how long to spend, and the result that decides
   between continuing and reporting back. For traps, name them: language or
   bootstrap gotchas, pass ordering, flaky or slow gates, checks that fail
   late (such as `make artifact-scan` for new files under test roots).
7. **Dependencies.** *Include when* something must land or be decided first:
   another issue, a bootstrap rotation, an owner decision.
8. **Testing.** *Include when* the change needs new or changed tests, which
   is almost always for code. Name the tests and where they live (`AGENTS.md`
   names the owner of each kind), starting with one that fails before the
   change and covering edge cases and error paths, with diagnostic text
   checked. Say how a broken implementation would be caught, for example by
   temporarily breaking one case and confirming only its test fails. Then
   give the commands: the narrowest repeatable loop first, the focused checks
   next, the final gate last, with the worktree setup. Tests check behaviour;
   they never pin source text, hand-kept counts or manifest sets.
9. **Acceptance criteria** *(core).* Checks that can be run, each with its
   expected result: a test that fails before and passes after, byte-identical
   output, a measurement with a threshold, a gate verdict. "Works correctly"
   is not a criterion.
10. **Release strategy.** *Include when* landing is more than one squashed
    commit after the premerge gate: increments that must each be green, an
    order relative to other work, a bootstrap rotation, or a breaking change.
    Blorp keeps no compatibility shims (`AGENTS.md`, rule 14), so a breaking
    change updates every call site, test, example and document in the same
    landing. Say how to back it out if it misbehaves on main.
11. **Handback.** *Include in every agent brief, and in an issue when the
    work will be delegated.* What to return and how briefly: the branch and
    commits, evidence for each acceptance criterion, measurements, and what
    was found but not done. Then when to stop and ask instead of working
    around a problem: a premise turns out wrong, the change must grow past
    its scope, a decision belongs to the owner, or a result looks like a
    compiler bug. The question states what was tried, the evidence, and the
    options with a recommendation, addressed to the coordinating session or,
    for a design decision, the owner.

## Code example

A literate example quotes the current code with its location, shows the
change, and explains it. This one is from the leak gate's timeout loop in
`scripts/test`.

Current code (`scripts/test`, `run_with_timeout_seconds`):

```bash
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$timeout_seconds" ]; then
            ...
        fi
        sleep 1
        waited=$((waited + 1))
    done
```

The loop sleeps a whole second before it notices that the process has
exited, so a case that finishes at once still costs one second; the gate runs
30 such cases.

After the change:

```bash
    local timeout_polls=$((timeout_seconds * TERMINATION_POLLS_PER_SECOND))
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited_polls" -ge "$timeout_polls" ]; then
            ...
        fi
        sleep "$TERMINATION_POLL_SECONDS"
        waited_polls=$((waited_polls + 1))
    done
```

Polling at the existing 0.1 s termination interval makes an instant case cost
a tenth of a second. Bash has only integer arithmetic, so the budget is
counted in polls rather than seconds, and `TERMINATION_POLLS_PER_SECOND` is a
named constant kept equal to `1 / TERMINATION_POLL_SECONDS`.

## Template

Copy this into a new issue file or brief. Keep the core sections, add the
others whose heuristic applies, and delete the italic hints.

```markdown
# <Symptom, stated as what is wrong>

Status: open

## Problem
_What is wrong or missing: input, command, actual output, expected output._

## Background
_Owning source, the one reference document, decisions taken, related issues._

## Proposed solution
_The approach, why it is right, alternatives rejected, the owning phase._

## Code
_Current code at `file:line`, the code after the change, why each part changes._

## Scope and non-goals
_What may be touched, what must not be, concurrent work nearby._

## Risks and unknowns
_A spike for an uncertain approach; known traps._

## Dependencies
_What must land or be decided first._

## Testing
_Tests to add and where; how a broken change is caught; commands from the
narrowest loop to the final gate._

## Acceptance criteria
- [ ] _A runnable check and its expected result._

## Release strategy
_Increments, ordering, rotation, breaking-change updates, how to back out._

## Handback
_What to return and how briefly; when to stop and ask, and whom._
```
