# Independent preparation review

Verdict: **APPROVE**, 0 blockers, 0 should-fix, 0 nits for exact proposal
`1e54bd0b1f891dd988763a807c5cce473fd6a405201de0474e8bc719808ff15e`.
After-emitter snapshot: `5fe71603571ab2614b80fc6d6b22b168fb056bb7039e5d78e19a28a497dd9e9b`.
All PROPOSAL_PINS hashes agree; read-only `git apply --check` passes; repository
emitter production remains unchanged. No native command or repository edit.

The private union admits exactly the same twelve symbols, with closed ranks and
no unshaped float ABI variant. Rank/index-offset arithmetic is equivalent to the
old rank/shape tables. There is one checked-parts constructor, retaining only
representation plus existing tensor/indices/dimensions. Renderers/prelude retain
those original fields and strings. Scalar unbox remains governed by
CoreUnboxKind, and struct unbox by resolved C type. Both suffix readers remain
unchanged in this intermediate preparation.

HANDOFF correctly qualifies standalone BuiltinCall body/simple renderer tests
versus production DirectRuntimeCall emission. The production DirectRuntimeCall
struct-unbox route still reaches checked parts. It does not claim production
scalar inlining, new receiver/result coherence checks, or broader identity work.

An earlier review found unsupported typed tuple destructuring in proposal b245;
current proposal uses ordinary inferred tuple destructuring as required by
GRAMMAR:907–908 and language_parser:6400–6444. The payload union correction and
incidental blank-line repair are also present. These findings are resolved.

Cost remains unverified: payload ABI/Option admission, temporary rank/representation
tuple and repeated is_some guards can add construction and ARC compared with the
old Option[Int] admission. Ordinary tuple emission uses TupleConstructWithRc
(emit.brp:7608–7623); exact optimized cost requires generated-C/resource evidence.
No allocation-free, cheaper, speed or native-test claim. Final representation
matching/reader deletion needs separate final-diff review, gates, C identity and
matched stage-2 total-allocation/min-instruction +0.5% evidence.
