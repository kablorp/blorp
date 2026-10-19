# Ordinary List take and checked remove

Plan only. Implementation and compiled validation await a finite START.
Fixed baseline: `a656f5ce1de963c8e9c162460e181d696b39c1d5`.

## Need and contract
Four compiler calls need these missing target-library exports:
`src/lex/lex.brp:1224` and `src/parse/assemble.brp:235` call `take`;
`src/check/declarations.brp:1074` and `src/specialize/specialize.brp:1219`
call `remove`. All four pop a stack tail; paths are under `blorp_2/`.
Match the host: `take(List[T], Int) -> List[T]` clamps count to [0,length].
`remove(List[T], Int) -> Option[List[T]]` returns None outside [0,length),
otherwise removes exactly that element and shifts the suffix left.
Host witnesses: `standard_library/src/list.brp:212,786` and
`blorp/src/compiler/stage_09_core/synth_list.brp:295,610,981` at fixed B.
Preserve order, generic T, managed children, independent owners and aliases;
valid singleton removal yields Some(empty), including T=Void.

## Direct implementation
Change only `standard_library/list.brp` beneath `blorp_2/`: import
`_base: Bool(True, False)` alongside its existing types and `int as IntOps`.
The existing prelude List method selection exposes the two public APIs.

```blorp
private pure func copy_range[T](values: List[T], start: Int, end: Int) -> List[T]:
    match IntOps.equals(start, end):
        True: []
        False:
            match IntOps.equals(IntOps.subtract(end, start), 1):
                True:
                    match get(values, start):
                        Some(value): [value]
                        None: []
                False:
                    middle = IntOps.add(start, IntOps.divide(IntOps.subtract(end, start), 2))
                    concat(copy_range(values, start, middle), copy_range(values, middle, end))

pure func take[T](values: List[T], count: Int) -> List[T]:
    copy_range(values, 0, IntOps.min(IntOps.max(count, 0), length(values)))

pure func remove[T](values: List[T], index: Int) -> Option[List[T]]:
    match IntOps.less_than(index, 0):
        True: None
        False:
            size = length(values)
            match IntOps.less_than(index, size):
                False: None
                True:
                    Some(concat(copy_range(values, 0, index), copy_range(values, IntOps.add(index, 1), size)))
```
Private callers establish 0<=start<=end<=length. Singleton get cannot fail;
its None branch keeps checked access total. Validated bounds make midpoint
and index+1 safe even when public inputs are INT_MIN or INT_MAX.
Same-T recursion reuses existing specialization identities. Ordinary get,
literal and concat ownership acquires stored children and drops temporaries.

Temporary cost: O(k log k) copying, O(log k) stack and O(k) peak live result
storage per returned length k, plus borrowed input. Repeated stack pops can
cost O(n^2 log n). Replace this helper after an accepted capacity-aware
builder/range-copy facility provides O(k) construction with the same contract.
No growing accumulator, callbacks, M3 work, runtime primitive or framework.

## Acceptance and bounded execution

First reproduce each missing export independently: `import: list: take`
(or remove, with normal multiline layout), then a tiny normal main call.
Fixed B must exit 1 at 2:11, stdout empty, no created/overwritten C:
`module list declares no public function or type take` (or remove), help
`select a public function or type that list declares`. Derivation is from
`src/check/render.brp:485`; execute before treating it as confirmed.
Candidate versions must compile; native main observes exact values/presence.

Use at most six real-main fixtures: Int bounds/order (empty, singleton,
first/middle/last, odd/even, INT_MIN/MAX); mortal UTF-8/NUL String children
in repeated/aliased records and nested Lists escaping local inputs; Void
Some(void)/Some(empty)/None; repeat(7,256) with prefix/interior/tail removal.
Check every small result element and original aliases, not length/sum alone.
Inspect emitted C for fixed nesting and logarithmic runtime recursion.
Checker tests preserve rigid T and named/UFCS calls; Specialize reuses each
same-T helper instance; Lower/Own/Verify check ordinary managed List result
transfer/drop through both concat operands and Some(empty). Reuse observers.

Finite validation: exact B failures; focused phase and real-main C11/O0
ASan/UBSan tests; wrong split/order and wrong remove-bound mutations with
named value witnesses, exact restoration and restored green; full component,
runtime, grammar and native gates. Compiler reports require balanced zero
leaks; retired instructions are required. Both independent code-reviewer and
test-runner must accept contracts, oracle sensitivity and resource evidence.
Growth ceilings: production 40 gross additions/2 deletions (preview 31/1),
tests+fixtures 400 gross additions; API/parity docs 55 gross; this plan 100 lines.
Existing caps remain unchanged. New fixture maxima: 150,000 allocations and
600,000,000 instructions each; measure and tighten before adoption.
Matched fixed-B controls: list checked_set, concat_entries, literal_empty,
and existing 64-module direct-import chain. Each must stay within +5%
allocations and +5% min-of-three retired instructions, with unchanged output.
Bind sources, libraries, producer/toolchain and serial raw samples; reuse a
producer only after exact input review. New APIs have no successful B cost
ratio. Owned-input costs remain proxies until self-compilation.
Stop on cap/setup/pin/semantic failure or scope growth; no retry or cap lift.
Keep Query/HOF/Contains/Append work separate. Coordinator owns integration.
