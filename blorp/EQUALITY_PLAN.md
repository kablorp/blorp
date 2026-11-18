# Equality derivation plan

Status: landings 1 (opaque types) and 2 (tuples) landed on 2026-11-17; landing 3
waits for a seed rotation.

## Decision

Keith, 2026-11-16: "opaque types and tuple types can derive their own equality
if their constituents implement Equatable". The rule is the one records
already follow: every constituent Equatable gives `==` with no declaration, and
a written `implements Equatable` replaces it. Hashable stays never derived.
The cost, stated in the README: a derived opaque `==` compares representations,
so a type whose distinct representations mean one value writes its own
implementation. This supersedes the pilot's opt-in recommendation (a bodiless
`implements`).

## Cost decision

Keith accepted the +0.53% fixed-input instruction cost of derived opaque
equality on 2026-11-17, on the measurements under Measurements below: the
increase is real from -O1 up, about half of it the opaque candidates, and
landing 3 does not give it back at -O2. Landing 2's increment (+0.07% fixed-input
instructions, below) lands under the same decision: Keith's "Also land equality"
(2026-11-17) approved both landings.

## Landing 1: opaque types

Design. An opaque type is a third kind of derived-equality owner next to
records and unions (`EqualityOwner` in `check/model.brp`). It takes part in the
same availability fixpoint (`complete_equality_availability`), so inferred
bounds, declared bounds, rejection at the unavailable member and the
supertrait diagnostics need no second rule. Its accepted implementation row
has `RepresentationBody(OpaqueId, TypeRef)` for each abstract member: the
representation written over the opaque declaration's own parameters.
`method_body` substitutes the receiver's arguments and answers with the
representation's member, so specialization is untouched. Opaque types are
erased there, which makes the opaque and its representation one function, and
the generated C calls the representation's function directly, without the
wrapper a hand-written identity needed.

Substitution. `substitute_type` moved to where `model.brp` can use it:
`substitute_parameters` now lives in `model.brp`, beside `TypeRef` and
`TypeParameterId`, which it only reads, and returns `Err(parameter)` for a
parameter with no value. `declarations.substitute_type` is a wrapper that
turns that into its `InvalidParameterDeclaration` error with a span. One
authority, no import cycle (`errors` imports `model`).

Rules checked. Orphan and overlap: an automatic row exists only for an opaque
type with no written implementation, as for records, and the orphan rule
already confines written ones to the opaque's module or the trait's, so no
module can write a competing one. Resource types (`resource_type`) never
derive. Instantiation growth: the representation's member is added to the
dependency graph as a template body's calls would be, and a receiver
parameter links to the opaque's own parameters, so growth through an opaque
hop is still seen.

Tests. `test/test_compile/fixtures/equality/opaque_derived.brp` (Int, String,
opaque of opaque, opaque List, generic at Int, bounded generic, nested generic,
explicit override, record field, `T: Equatable` use);
`reject_opaque_argument.brp` (generic opaque at an argument without equality:
exact message, help, span and note); `test_substitute_parameters.brp` (unit).

## Landing 2: tuples

Status: landed on 2026-11-17, after landing 1.

Design. The coordinator kept the namespace `TypeHead` unchanged, because no written name
denotes a tuple. `AcceptedImplementation.receiver_head` is a check-local
`ImplementationHead`: `NamedHead(TypeHead)` or `TupleHead(arity)`. Checking adds
one canonical-trait row per arity two to four (the parser's limits, now shared
as `TUPLE_MINIMUM_ELEMENTS` and `TUPLE_MAXIMUM_ELEMENTS` in `syntax.brp`), each
bounding every element by the trait. The table indexes named rows as before and
keeps the three tuple rows apart (`family_for` for a named head,
`family_for_receiver` for a type), so a named lookup builds no wrapper. A record
or union with a tuple member reads the same bounds during its availability
round, so it qualifies.

The row carries a recipe, not a template: specialization builds the arity's
template (`equality.tuple_equality_template`, the record rule over
`ReadTupleElement`, parameters owned by the new `TupleDeclaration(arity)`) when
a body is requested, so a program that never compares a tuple pays nothing for
it. The growth analysis sees a tuple row as its template would show it: each
element position is a call of the member at that element's parameter.

Tests. `equality/tuple_derived.brp` (`(Int, String)`, nested tuples, tuples of
a record, a union, a List and an opaque type, arity four, a record with a tuple
field, a union with tuple payloads, a `T: Equatable` use) and
`equality/reject_tuple_element.brp` (an element without equality, exact
message, help, span and note); `test_each_tuple_arity_has_its_own_equality_family`.

Cost. Tuple rows exist in the table always (the three rows cost about 110
allocations), but the growth analysis reads the traits without them first and
widens to them only when a dependency touches a tuple: a tuple type pushes or
pops a `TupleElement` slot, and a tuple equality targets a `TupleDeclaration`
parameter. Programs with no tuple pay nothing for the analysis, which had been
about 1,000 allocations and 2 to 3 million instructions per compile (17 to 19%
of the smallest e2e programs). Growth through a tuple is still rejected
(`equality/reject_tuple_growth.brp`). Against landing 1 the smallest compile
(`derived_accepted_generic_head`) is 4,649 allocations against 4,619, and the
self-compile fixed input was +0.14% instructions and +0.02% allocations
before the lazy widening. Re-measured at the tip against landing 1
(`cost_final_tuples.log`): fixed input +0.07% instructions and +0.001%
allocations, own source +0.60%.

Ceilings: every e2e ceiling passes at the landing base (main `11e0d2c8c`), and
none was changed. The two derived_accepted_* programs that had exceeded
theirs on older bases came back under after library-cost (b).

## Landing 3: delete the 28 hand-written identity implementations

Waits for a seed rotation, because the seed compiles the compiler source.
After landing 1 a seed pin that contains it, delete the 28 blocks
(`ids.brp`, `model.brp`, `inference.brp`, `specialize.brp`, `list.brp`,
`own.brp`, `lower.brp`, `source.brp`, `names.brp`). The pilot measured the
conversion: -84/+28 production lines, the converted compiler compiles itself
to identical C and runs -0.36% instructions on the same input.

## Measurements

Landing 1, `self-compile-cost 4d8b381f0 <branch>` at -O2 (macOS arm64; medians
of 11; raw samples under `build/pilots/2026-11-12/equality/data/cost_*`). The
fixed-input C is identical in every run.

| Candidate | Fixed-input instructions | Fixed-input allocations |
|---|---|---|
| first version | +0.41% (base `4d350add0`) | +0.29% |
| candidate head cached (`fd48f6763`) | +0.54% | +0.29% |
| `method_body` loops (`652149750`) | +0.53% | +0.29% |

Re-measurement (rebased on `f95a8204d`, 15 paired rounds alternating base and
candidate, `self-compile-cost`): fixed-input instructions +0.533% (base
12,776,153,106, candidate 12,844,301,441), allocations +0.291%, fixed-input C
identical. A separate paired run of the same two C files built at each level
(9 alternating rounds, spread 0.1 to 0.24%): -O1 +0.556%, -O2 +0.541%, -O3
+0.510%, and -O0 -0.05%. So the increase is real, repeatable and not noise; it
exists from -O1 up, which is why an -O0 call-count profile (the candidate runs
fewer calls and 0.8% fewer basic blocks) did not show it.

Where it goes. The first version paid 3.98M extra calls of the `equality_head()`
wrapper in the candidate scan; caching the head removed them (at -O2 the
wrapper was inlined, so it moved nothing there). Bisecting at -O2 (7 paired
rounds): ignoring `RepresentationBody` in `method_body` changes nothing
(+0.486% either way), neither does restoring the original `substitute_type` or
turning the recursive `method_body` into a loop, but deriving no opaque
candidates at all drops it to +0.228%. About half (0.26%) is therefore the
opaque candidates and their rows in the availability fixpoint and the growth
analysis; the other 0.23% remains (the `EqualityOwner` generalization and the
other edits) and I did not isolate it to a function. I could not run
the library-cost `--pilot-stop` probe: it edits `check.brp` and
`compile_command.brp` around the same lines this change touches.

The cost is inherent to deriving opaque equality in the compiler's own source,
which has about twenty opaque types to derive. Landing 3 does not give it back:
built at -O2 from source with the 28 identity implementations deleted (so those
types derive as well), the compiler retires 12.8356G against 12.8395G, a 0.03%
difference inside the spread, with identical output. The pilot's -0.36% was
measured at -O0 against an opt-in design that added no candidates.

The reviewer's reading, that every opaque pays a lookup per round, is not
supported: removing the candidates accounts for half of it.

Production source +277/-96 before the review fixes, of which about 90 added and
51 removed lines are `substitute_parameters` moving to `model.brp`.
