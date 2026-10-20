# Ordinary target List[String].join

Status: source23ADD/1DEL, eight phase callbacks and64-byte native main pass.
Return/zero fails +13.023436% instructions/+30.230796% allocations; held.
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

Only list.brp changes: public join and private join_range; no compiler/runtime/
host/prelude/M3/M7/callback machinery or new builtin. Source remains23ADD/1DEL.

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

Nonfixture tests293ADD retain actual public/private FunctionIds, concrete
ordinary calls, exact negative kind/help/span/no-note, and independent Own/Verify
leaf acquisition, intermediate retirement and escaped-result identity. No copied
library body, new runner or fixture alternate main.
After GREEN, independently mutate singleton payload->empty, right start->start,
and omit separator. Each must fail real-main exact output, restore bytes/modes
before classification and pass restored control; no setup-error kill credit.

Retained actual Numeric02ec/ef936/commonC9ab roles own the native/cost epoch;
old Query2bc/892 are not substitutes. Native C11/O0/ASan+UBSan uses unmodified C
and real main. Existing native64B and phase8GREEN remain credited, not replayed.

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
The original eight return/zero calls are complete and must never repeat.
Attribution measured Load+1782/Check+2606 allocations; all five later phases were
unchanged. These are diagnostic intervals, not instruction or acceptance proof.
Completed24 control and3 fixture normal samples stay credited; all failures bind.
The original native180s timeout and corrected441PASS/57FAIL remain retained.
Current27b+Join599e7703 is a distinct composition, not a baseline replacement.
After two reviews/publication/START, only16 current-C samples (four controls,
three normal+one strict each) use original02ec/ef936 paths/env and credited old B.
One current whole-native --timeout0 is also permitted:17 characterization calls.
All original5%/10%/absolute misses stay FAIL; no benchmark or B replay.
Only numerical misses may continue in these17; other20 functional/fault calls
must match exact oracles. Any nonbudget failure STOPs unused calls.
Map actual current limits/shared users/max; never add old allowances twice.
No cap/B/HOST/acceptance/merge waiver. Root semantically composes List hunks;
two independent final reviews/full gates/resource acceptance precede commit.
