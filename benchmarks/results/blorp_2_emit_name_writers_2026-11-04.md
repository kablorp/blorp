# Blorp 2 emit writes C names into its output

Base `df06da9aa` (main; neither the interpolation-left-chain branch nor the
lazy-errors branch is in it). Candidate: this branch. Emitted C is unchanged.

## Change

Emit built each C identifier as a fresh String, appended it and dropped it. The
`append_*_name` writers in `blorp_2/src/emit/emit.brp` and
`blorp_2/src/runtime/list.brp` append identifiers straight onto the output:
`append_local_name`, `append_owner_name`, `append_stored_name`,
`append_transfer_name`, `append_field_name`, `append_variant_name`,
`append_type_name` (the Result-returning successor of `c_type`),
`append_local_declaration`, `append_union_value`, `append_union_type_name`,
`append_record_type_name`, `append_boxed_union_struct`,
`append_selection_scope_name`, `append_decision_name`,
`append_selection_arm_name`, `append_loop_transfer_name`,
`append_parameter_name`, `append_payload_member_name`,
`append_payload_field_name`, `append_callable_type_name`,
`append_callable_entry_name`, and in `list.brp` `append_list_suffix`,
`append_callable_suffix`, `append_list_c_type`, `append_list_update_name`.
Call sites are left-to-right chains: UFCS on a private function with a String
receiver compiles on the pinned seed (`output.append_local_name(id)`).

## Result (fixed workload, stage 2, serial)

`measure_fixed_workload.sh base cand out`; raw files under the ignored
`build/` tree of the measuring session.

| | base | candidate | change |
| --- | ---: | ---: | ---: |
| strict allocations | 14,799,381 | 13,305,129 | -10.10% |
| best of 3 -O2 instructions retired | 12,039,950,345 | 11,303,454,748 | -6.12% |
| String shared-fallback copy, calls / bytes | 1,827,653 / 29,056,559 | 734,613 / 18,792,866 | -35% bytes |
| String borrowed-update copy, calls / bytes | 169,268 / 2,898,947 | 34,311 / 1,273,337 | -56% bytes |
| List copies | unchanged | unchanged | 0 |
| peak memory footprint (3 runs, noisy) | 151.4-154.4 M | 152.2-155.1 M | within noise |
| production lines (`git diff --shortstat`) | | +232 / -230 | +2 net |
| test lines | | 0 | no suite called a renamed helper |

Pilot only (`c_value`, `c_owner`, `transfer_value`, one declaration site):
-3.98% allocations, -2.4% instructions, -11 production lines.

Output identity: the stage-2 compiler output and the candidate's output for
`blorp_2/src/main.brp` are byte-identical (`cmp`), and all 672 e2e fixtures
under `blorp_2/test/e2e/fixtures` produce identical C or identical diagnostic
text and status with both compilers. `make -C blorp_2 test` passes
(1,273 `[PASS]` lines, none failing).

## Copied bytes by emit function

`report.py copies` on both sides. Every converted helper's row is gone
(`c_value` 2.74 MB, `c_owner` 1.39 MB, `c_selection_scope` 1.53 MB,
`union_c_type` 1.07 MB, `c_local_declaration` 1.00 MB, `c_variant`,
`c_field`, `c_parameter`, ...). `append_regular_value` and `owner_alias`
borrowed rows are also gone.

Small rises, all in functions whose output a converted writer now writes into
directly (a copy that was previously charged to the helper or to `string.add`
now falls on the caller). Sizes are bytes copied, base to candidate:

| Function | Path | Base | Candidate |
| --- | --- | ---: | ---: |
| `emit.append_union_action` | fallback | 1,838 | 4,734 |
| `emit.append_parse_number` | fallback / borrowed | 0 / 0 | 61 / 45 |
| `emit.append_string_byte_at`, `append_string_slice`, `append_string_from_codepoint` | fallback + borrowed | 0 | 30-60 each |
| `emit.payload_use` | fallback | 0 | 5 |
| `emit.append_loop_exit` (List unique, calls) | | | calls only, 1,621 bytes |
| `string.add` (all callers) | fallback | 58,057 | 374,322 (+5 calls) |

The `string.add` row is the one to watch: five more shared-fallback calls copy
316 KB. The largest candidate sites are not identified by the function-level
table because `string.add` is the shared interpolation primitive. The total
over all String paths still falls by 11.9 MB (31.95 M to 20.07 M bytes).
Recording this as a deviation from the acceptance criterion that no emit
function's copied bytes rise; the rises are under 3 KB per emit function.

## Remaining top emit String allocation sites (candidate, attribution run)

| Function | Allocations | Why it stays |
| --- | ---: | --- |
| `append_storage_operation` | 123,462 | `expression: String` is a pre-rendered parameter (brief: kept) |
| `append_block` | 88,188 | statement fragment assembly, not a name helper; not investigated |
| `append_join` | 49,558 | arm and declaration fragments, not a name helper; not investigated |
| `append_ownership_operations` | 40,847 | per-operation fragments are built from `""` and joined |
| `append_operation` | 29,406 | not a name helper; not investigated |
| `c_variant_test`, `c_pattern_place` | 22,411 | test strings assembled before the branch is written |
| `c_name` | 19,375 | `c_callable` returns `Option[String]` (same shape as `consuming_helper_name`) |
| `c_header` | 8,846 | below the 10 k stop line |

## Kept as fragments

- `append_storage_operation`'s `expression`, `append_optional_value`'s
  `condition` and `payload`, `append_union_value` operands (`List[String]`),
  `list_slot_store` and `list_root_allocation` strings: pre-rendered String
  parameters. Their producers call `"".append_*_name(...)`.
- `consuming_helper_name`, `c_callable`: return `Option[String]`.
- `list_suffix`, `list_c_type`, `callable_suffix`, `list_update_name` stay as
  one-line wrappers over their writers for the runtime-text templates in
  `list.brp`, `emit.brp`'s cold `Some("blorp_list_..._${list_suffix(...)}")`
  names and `test_list.brp`.
- Loop accumulators (`append_input_declarations`, `append_loop`,
  `append_join`, `append_loop_exit`) take the declaration as the fragment
  `append_local_declaration("", ...)`. Passing the live accumulator into a
  Result-returning writer keeps a second reference live on the error path, so
  the append would copy the whole accumulator (the reason `owner_alias`'s
  comment gives).
- Cold per-type definitions (`append_record`, union payload fields, callable
  adapters) use `append_type_name("", ...)`.
- Diagnostics are untouched.

## Findings

- A `?=` cannot sit inside an `if` or `match` arm, so
  `append_local_declaration` computes its const prefix and suffix first and
  then writes the type once.
- `append_type_name("", Int)` allocates where `c_type` returned a literal. The
  sites that still pass `""` are cold; the hot declarations write in place.
