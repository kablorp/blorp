# Ordinary target List[String].join

Status: reviewed implementation contract; implementation and measurements pending.
Fixed B: a656f5ce1de963c8e9c162460e181d696b39c1d5 (accepted Numeric main).
Query/Contains/HOF candidates and all their failed samples remain separate.

## Public contract and existing authorities

Add only pure `join(values: List[String], separator: String) -> String` to target
list.brp. Host list.brp1351 has this same naturally String-specific signature.
Empty input returns empty String; a singleton preserves its content; separators
occur exactly between elements, including empty elements. Element order, UTF-8
and embedded NUL bytes are preserved. Inputs remain usable; returned managed
content survives temporary input-list and separator lifetimes. No List mutation.

Literal examples: `join([], ",")` is empty; `["a", "", "c"].join("::")` is
`"a::::c"`; `["", "", ""].join("/")` is `"//"`. Named imports enable UFCS.
There are13 resolved compiler List.join calls (emit10/load1/main1/parse1), per
STANDARD_LIBRARY_GAPS and the retained resolved census; Path.join is separate.
Host join uses capacity-aware list.string_append (runtime.c7465), so it is not
naive repeated concat. Target String.add currently allocates/copies both inputs
(runtime/string_concat.brp5–16); List.append also copies. Do not use a growing
String accumulator or a growing fragment list to disguise quadratic copying.

## Smallest ordinary implementation

SOURCE_PREVIEW.patch is23ADD/1DEL/+22: merge base String/Bool constructors,
IntOps/StringOps aliases, one private join_range and public join. No other API,
compiler/runtime/host/prelude edit, M3/M7/callback dependency or new builtin.
Preview is generated from exact B, not any held List checkout.

Public join calls join_range(values,0,length(values),separator). Match Bool from
less_than(count,1): empty returns "". Otherwise match equals(count,1): get the
leaf via existing get/Some; None is total empty fallback. For count>=2, split at
floor(count/2), evaluate left range then right range, and add(add(left,sep),right).
No integer patterns, if, propagation, unsafe indexing or growing accumulation.
The public invariant is 0<=start and start+count<=length; positive splitting keeps
both child counts smaller, intervals disjoint/ordered, and arithmetic in bounds.
get owns its leaf independently; ordinary ARC manages both intermediate Strings.

Temporary complexity is O(n+B*log(n+1)) work/copies and O(log(n+1)) stack, where B
is final byte length; n visits remain even when all bytes/separators are empty.
This is not host builder cost parity or a speedup claim. Replace this temporary
ordinary implementation only after a separately reviewed linear String-builder
facility and matched evidence are accepted; no hidden native builder in this slice.

## Tests first and precise acceptance

Preview one27-line normal-main fixture, expected64-byte stdout/exit0/stderr0:
empty, singleton, empty pieces/separator, odd3-way order, non-ASCII/NUL, shared
managed element/separator surviving join, returned temporary pieces, and1024
repeated fragments yielding exact2047-byte length (logarithmic recursion depth).
First baseline ordinary CLI must reject import join at2:11, bytes18..22:
`module list declares no public function or type join`; help
`select a public function or type that list declares`; exit1/stdout0/no C.
No setup failure earns RED; no fabricated successful B for this new API.

Nonfixture forecast220ADD: Check actual loaded public signature/purity/private
range authority60; concrete ordinary calls/finite recursion20; separate Own and
Verify exact leaf acquire/intermediate release/temporary-parent escape70; typed
bad List[Int]/Int separator diagnostics (exact typed facts/source/span/help/note)
30; native registration7; imports/layout contingency33. No copied library body,
new runner or fixture alternate main. Use existing temporary-module phase helpers.
After GREEN, independently mutate singleton payload->empty, right start->start,
and omit separator. Each must fail real-main exact output, restore bytes/modes
before classification and pass restored control; no setup-error kill credit.

Commands follow existing owners: ROOT/bin/blorp test --std-dir ROOT/standard_library/src
--timeout180 blorp_2/test/unit/test_check/test_list_join.brp; changed Spec/Own
owners next. A source-matched accepted Numeric normal/diagnostic pair must be
named and pinned before RED/setup; old query2bc/892 are not Numeric producers.
One ordinary CLI emits C, C11/O0/ASan+UBSan links unmodified C, real main checks
all64 bytes. Then first unchanged return/zero eight costs before expensive gates.

Freeze unchanged controls return/zero, string_operations/concat,
generic/managed/basic, list/empty_string from exact B. Use same physical full12
library/input/output/CWD, normal B1,C1,B2,C2,B3,C3 then strict B,C per input.
Each allocation/normalmin3 independently retains5% target/10%hard plus old tighter
absolute caps; require positive counters, strict balancedzero and exact all8 C.
No compiler data-model change or HOST rebuild/campaign; independent HOST3% stays
fixed. New fixture only C strict+3normal under existing generic150k/600M.
Full components/native REQUIREDinstructions/strictzero/sanitizers/oldcaps plus
full unchanged corpus/state identity remain; explicitly name new export/frontier
changes. These controls are not the13 compiler source calls' selfcompile proof.

## Bounds, stop and integration

Prospective hard: production40ADD/+40, tests295ADD, one fixture60lines, API docs25ADD,
plan100lines. Stop on first10%/absolute breach, semantic/accounting/provenance/
identity failure or prospective LOC overflow. Retain5%misses; no cap edits,
resampling, B roll, benchmark omission or acceptance from identical C alone.
Prior Query +22.15% allocation failure is preserved; join may incur declaration
checking overhead too, so its first cost result is a real stop, not assumed headroom.
Root semantically composes List import/function hunks; no whole-file replacement.
Two independent reviews/full gates and resource acceptance precede root commit.
No source write, compiler call, commit or implementation dispatch is authorized here.
