# Ownership shape probes

Probe programs for [`docs/VALUE_TUPLES_AND_STATE_HANDOFF.md`](../../docs/VALUE_TUPLES_AND_STATE_HANDOFF.md)
(appendix A). Each tuple or hand-off shape is paired with a control that does
the same work without the tuple or the second reference, so a measurement
reads as the shape's cost over its control.

| Probe | What it runs |
| --- | --- |
| `value_tuple_probe.brp <mode> <count>` | One shape per mode: `empty`, `pair_inline`, `pair_call`, `record_alone`, `record_pair`, `mint_control`, `mint_kept`, `descent`, `builder_alone`, `builder_pair`, `two_owned`, `two_owned_record`, and the increment 1 `match` subject `subject_or` with its control `subject_control` |
| `intern_probe.brp` | Spelling interning (section 4.5): the given two-result shape, the no-tuple shape called both ways, and its variants, at 1,000 and 10,000 calls |
| `nested_update_probe.brp` | Nested record updates three levels deep, directly and through local bindings |
| `pair_probe.brp` | A list or a scalar two levels down in a record pair |
| `last_use_probe.brp` | An alias read once, then the owner updated |

Every probe except `value_tuple_probe` prints its own allocation counts and
takes no arguments.

## Commands

From the repository root, with a `FRESH` `bin/blorp` (or a stage-2 compiler,
for the compiler's own code):

```bash
S=/tmp/ownership-shapes
mkdir -p "$S"
bin/blorp compile --no-format -o "$S/probe.c" benchmarks/ownership_shapes/value_tuple_probe.brp
clang -x c "$S/probe.c" -O2 -fwrapv -w -lm -lpthread -o "$S/probe"
clang -x c "$S/probe.c" -O2 -fwrapv -w -DBLORP_MEMORY_DIAGNOSTICS=1 -lm -lpthread -o "$S/probe_diag"
BLORP_MEMORY_STATS=1 "$S/probe_diag" <mode> 100000    # allocations, exact
/usr/bin/time -l "$S/probe" <mode> 100000              # instructions retired
```

Instructions per call are a mode's retired instructions minus the `empty`
mode's, divided by the call count; take the median of three runs. Run one
binary at a time.
