# Audit quick wins

**Status:** Keith chose these five changes on 2026-11-17, from a read-only
audit of `9aa7ae88d`. They land as one stack: each change is its own reviewed
commit, and the gates run once, on the top of the stack. This file holds each
change's cost ceilings and its measured cost.

## The changes

1. **Delete dead code.** These have no production reader:
   - in own: `last_uses`, `block_last_uses` and `exit_last_uses`; `block_uses`
     then takes a `Span`;
   - in check: `declaration_id`, `record_declaration_id`,
     `union_declaration_id` and `authored_traits`;
   - the `MethodArgumentCounts` error and its render arm, and
     `render_check_errors`;
   - specialize's `slot_union_representation`;
   - `SpecialNames`, and `InitialNames` with `CheckedFoundation.initial`,
     which only tests read;
   - the private copy of `push_at` in `instantiation_paths.brp`.
2. **One table for the native labels.** Adding a primitive touches about
   twelve places, and three of them no exhaustiveness check covers: the
   `PRIMITIVE_LABELS` string, the `_:` arm in `accepted_operation`, and a test
   that pins every label. After this change, the labels come from one table,
   the parsed-to-runtime conversion is one total match, and `system_symbol`
   is derived from the label.
3. **Use the existing `translated_list` and `first_error`** in the hand-written
   first-failure loops that have exactly their shape.
4. **CI.** A push that changes only Markdown no longer runs `blorp.yml`, since
   Markdown under `blorp/` is neither built nor embedded. The audit also
   proposed running `test_bootstrap.sh` in one matrix cell instead of four.
   That was dropped: it takes 2 to 4 seconds per cell (run `44213594608`), and
   it does vary by OS, through `make` and the checksum tools.
5. **`FunctionRole` names its owner:** `ImplementationBody(ImplId)` and
   `TraitDefaultBody(TraitId)`. Four readers then stop recovering the owner
   by scanning every implementation or trait.

## Ceilings

Set before implementation. Change 4 touches neither `blorp/src` nor the
library, so it has no cost ceiling.

- Each compiler change (1, 2, 3, 5) is measured with
  `blorp/scripts/self-compile-cost <parent> <change> --rounds 5`.
- On the fixed-input row, the emitted C must be identical.
- Allocations may rise by at most 0.5%, as may the median retired
  instructions. Peak heap may rise by at most 2%.
- Production lines (`blorp/src`, `blorp/standard_library`) are counted
  separately from test lines:

| Change | Production lines | Test lines |
| --- | --- | --- |
| 1 | at most −80 | only the tests that read deleted code |
| 2 | at most −20 | only what the new checks need |
| 3 | at most −80 | none |
| 5 | at most 0 | only what the new checks need |

A line figure here is an estimate from the audit, not from compiled code. If
a change exceeds it, the change stops for a growth audit.

## Gates

- Each change runs its owning focused suites, and is formatted with
  `blorp format`.
- The top of the stack runs `make -C blorp test INSTRUCTION_CHECK=on` and
  `git diff --check`.
- The top of the stack also runs branch CI (`gh workflow run blorp.yml`),
  whose Seed jobs prove the fixpoint.

## Measurements

**How:**
- **Host:** an Apple M4 running macOS 26.7.1, with Apple clang 21.0.0.
- **Command:** `blorp/scripts/self-compile-cost 31dd58125 <change> --rounds 5`
  (7 rounds for change 3's final commit), at `-O2`, using the pinned seed
  `blorp-seed-4fee244ad96f`.
- **Revisions:** each change was measured on its own branch, against
  `31dd58125`.
- **Samples:** the raw samples and reports are under the main checkout's
  ignored `build/audit-2026-11-17/cost/<change>/`.

The fixed-input row binds; the own-source row is reported. Allocations and
peak heap come from one strict run of the diagnostic binary, which is
deterministic. Instructions are the median of the rounds. The fixed-input C
is identical in every row (`85cbfd8e3e7afde3`). Lines are each commit's
`git diff --numstat` against its parent in the stack.

| Change | Allocations | Instructions | Peak heap | Own-source allocations, instructions | Production lines | Test lines |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1. Dead code | -0.00% | +0.04% | +0.00% | -0.10%, -0.09% | +28, -156 (net -128) | +22, -41 |
