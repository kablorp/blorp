# Index Call-Signature Name Allocation

**Status:** Proposed, measurement-gated

**Current state:** `call_signature` builds growing `used_names` and calls
`fresh_callee_type_param_name`, which repeatedly scans both `outer_names` and
`used_names` for the original name and numbered candidates. It ran 86,692
times in the retained self-compile.
**Next action:** Measure bound-parameter width and collision retries, then test
one private occupied-name index.
**Read first:** `blorp/src/compiler/stage_06_typecheck/infer.brp`,
`blorp/test/compiler/stage_06_typecheck/test_infer.brp`, generic inference
fixtures, and the
[call-count screen](../../../benchmarks/results/compiler_complexity_call_counts_2026-09-14.md).
**Fast loop:** `bin/blorp test blorp/test/compiler/stage_06_typecheck/test_infer.brp` plus a proposed collision-width probe.
**Decision:** Preserve generated fresh names exactly; do not change public name
syntax, substitution, or environment representation.

## Objective

Make fresh call-signature name allocation scale with names and collisions while
preserving exact generated spelling and substitution order.

## Why and candidate

```blorp
for param in bound_params:
	scoped_name = fresh_callee_type_param_name(outer_names, used_names, param.name)
	used_names = used_names.append(scoped_name)

while outer_names.contains(candidate) or used_names.contains(candidate):
	index += 1
	candidate = prefix + index.to_string() + "_" + base_name
```

Build one private membership set containing outer names, then add every chosen
scoped name. The output still comes from ordered `scoped_params` and `renames`;
never iterate the set. Keep separate lists only if another consumer needs their
order.

The focused fixture should vary outer-name count, bound-parameter count,
ordinary versus dimension names, collision depth, duplicate source names, and
no-collision calls. Report membership queries/probes, candidate strings built,
collision retries, set/list allocations, substitutions produced, and exact
signature/name checksums.

## Invariants and tests

- The first available name and numeric suffix are byte-identical.
- `#` dimension prefixes and `__callee_` spelling are unchanged.
- `scoped_params`, substitutions, parameter types, and return type retain order.
- Repeated input names remain handled as today.
- Empty and one-parameter calls remain cheap.

## Acceptance and rejection

Admit implementation only if collisions or list comparisons are material in
compiler/package profiles. Accept if collision-heavy work becomes near-linear,
focused instructions or allocations improve by at least 10%, no-collision
cases remain within 2%, and every name/signature checksum matches. Run focused
inference tests, `scripts/compiler-check --stage typecheck`, and self-compile
output identity.

Reject if set construction costs more than saved scans at observed widths, if
fresh spelling changes, or if the solution introduces a second global naming
authority.
