# Ordinary target List[String].join

Status: source 22 ADD/1 DEL; components 3652 and native 1155 all PASS.
Original/current FAILs remain; the resource amendment was approved on 2026-10-20.
Fixed B: a656f5ce1de963c8e9c162460e181d696b39c1d5 (accepted Numeric main).
Original isolated measurements and current combined-library proof stay distinct.

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
host/prelude/M3/M7/callback machinery or new builtin. Original 23/1 is current 22/1.

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

Fixed cost roles are Numeric02ec/ef936/commonC9ab; Query2bc/892 never substitute.
Current native uses CWD9b22+host498/STD91, unmodified C11/O0/ASan+UBSan/real main.
All credited 64-byte native/phase8/fault GREEN and historical FAILs remain.

Four unchanged controls are return/zero, string_operations/concat,
generic/managed/basic and list/empty_string. Fixed B and same physical paths,
02ec/ef936 producers/env, positive counters, strictzero and exact C stay fixed.
Original 5% targets/10% hard limits and every historical FAIL remain recorded.
The human approved these current-composition hard caps on 2026-10-20:
allocations min(floor(1.58*B), B+8400); normalmin3 min(floor(1.25*B), B+11000000).
These cover Contains/AppendInt/Join together; they do not attribute 57% to Join.
Empty String control-only absolutes become 27300 allocations/91M instructions;
all other control absolutes and C-only fixture 150k/600M remain unchanged.
Only 49 native allocation fields change to the frozen values derived once as
max(currentcap,round_up(maximum_shared_observed+100,100)); 62 users are bound.
Native instruction caps and all unlisted fields stay unchanged; never stack
old allowances. Exact integers/headroom and evidence are in the [report](../benchmarks/results/blorp_2_list_join_2026-10-20.md).
No compiler model/HOST rebuild; independent HOST/SOURCE/otherFEATURE caps stay.

## Bounds, stop and integration

Prospective hard: production 40 ADD/+40, tests 345 ADD, fixture 60 lines, API docs 25 ADD.
Feature tests remain 293 ADD; 49 numeric replacements give 342 ADD/49 DEL total.
There are no extra callbacks, compressed formatting or lost predicates; plan 100 lines.
Original 32 shared and 4 fixture samples, 20 functional/fault calls and current 16
samples stay credited. No old B/sample replay, resampling or baseline roll.
Old native timeout/441 PASS 57 FAIL and current 448 PASS 60 FAIL remain retained.
Final accepted Option+Join native 449 PASS 60 FAIL/418 rows is allocation-only FAIL.
Final approved-cap whole-native --timeout0 passed all 1155 markers/418 cost rows,
509 outer/645 semantic-child/one umbrella, with strictzero and required counters.
Components passed 3652; identity passed 505 pairs/1010 calls; all guards closed;
explicitly bind new export/frontier differences. No selfcompile proof is claimed.
Stop on every semantic/status/strict/counter/C/provenance or unapproved cost failure.
No additional measurements/builds/cap edits follow implicitly from this amendment.
Root composes List hunks; two final independent reviews and GREEN final gates
are required before commit. All original/current FAIL evidence stays immutable.
