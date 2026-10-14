# Ordinary types in unary union payloads

Status: implementation, two independent compiler-expert reviews, granular tests,
runtime/native checks, final integration and quiet matched costs pass. This
completes the direct unary annotation slice of the
[roadmap](../../blorp_2/ROADMAP.md). Multiple constructor fields, general Lists,
updates and recursive data remain separate increments. No commit or push made.

## Behavior and authoritative facts

Union payloads now use ordinary type syntax, including String, Float, Void,
records, nested nominal applications and the currently supported List[String].
For example, `Text(String)` and `Item(Box[Option[T]])` no longer require encoding
their concrete types through an otherwise unnecessary generic wrapper.

ParsedVariant carries Option[TypeSyntax]; the ordinary type parser/resolver owns
nested syntax, module visibility, declaration-owned rigid parameters and arity.
Checking publishes the same complete TypeUse consumed by existing specialization.
The Int/type-parameter whitelist, its separate error policy, renderer branches
and unused primitive helper are removed. Namespace, lowering, ownership insertion,
independent verification and emission are unchanged.

The existing finite-declaration visitor now also starts from every union,
including unused declarations. Record roots retain their previous priority,
followed by union roots in declaration order. Recursive declarations still
reject at the closing edge's written annotation, not a synthetic traversal span.
Structural specialization errors use the written payload span, including
Items(List[T]) instantiated at Int through a producer with no Items construction.
Direct List[Int] retains its ordinary element-annotation error.

Bare Empty remains nullary; Unit(Void) has one real payload constructed as
Unit(void). Empty declaration parentheses and multiple payload fields still
reject with specific teaching help. Ordinary annotation errors keep their typed
identities, source spans and head-arity-before-child ordering.

## Tests and independent oracles

Ignored evidence lives under repository-root `build/roadmap/union-payloads/`.
`HANDBACK_IMPLEMENTED.md`, `coverage.md`, `native/results.md`, `cost/results.md`
and the recorder packets identify each purpose and its exact inputs.

| Boundary | Evidence |
| --- | --- |
| Actual first red | Two exact old-rejection controls pass; two desired parse/check cases fail. |
| New granular suite | 40 named callbacks: AST spans, ordinary errors, module/rigid owners, finite-cycle guards, complete concrete layouts and direct producer ownership facts. |
| Final owning test delta | 62 checks across two suites pass; 12 old/new program builders have identical bytes after conversion to aligned multiline literals. |
| Final sanitized unit/runtime/grammar | 1,917 printed PASS checks across 120 suite summaries, exit 0, zero compiler leaks, no source drift. |
| Final normal e2e wrapper | 310 cases; 744 printed PASS checks across 301 summaries, exit 0, no timeout or source drift, one pilot build. |
| New native group | Eight real-main programs, 11 group callbacks and six exact rejection commands pass. |
| Runtime catalogs | Three catalog callbacks and 60 unchanged per-object C cases pass. |
| Generated C inspection | Five explicitly authorized additional real-main replays pass; unmodified C/binaries retained and inspected. |

Existing independent managed-union, nested-payload and owned-scrutinee raw suites
remain unchanged. They test malformed nominal children, field/parent identities,
transfer and liveness independently of insertion. New lower/own tests establish
that direct String and managed-record annotations produce those same contracts;
direct/generic layout pairs separately assert complete fields and representation.
No duplicated full ownership matrix or new test framework was added.

Four narrow source mutations have intended failures/controls: restored whitelist
26/14, omitted union roots 5/35, wrong module 1/39 and wrong rigid owner 3/37.
Each preserves its mutant source and recorder packet. Final source restoration
matches all five reviewed production hashes exactly.

The runtime addition is one explicit direct catalog using the existing production
fragments, complete nine-record/three-union guard and all 20 unchanged real
allocation/free assertions. Nongeneric, generic and direct fragments are identical:
7,630 bytes, SHA `365a57126eeab53e058d8566f159447100533a89d762aee270bf4e22eeb9722a`.
An approved ignored exporter retains these actual strings; it rewrites no C and
calls no generated language functions. Its initial host early-return setup error
is retained separately; the repaired Result-based exporter passes.

Native programs observe String/record/nested escape, Float output, old aliases
after reassignment and distinct Void/nullary tags through real main. C inspection
confirms each child acquisition precedes parent retirement. Both literal String
objects and to_string results are heap allocated here; static literal bytes do
not imply an immortal String. The strengthened to_string fixture and earlier
literal-fixture red are distinguished by their input hashes.

All native C is strict C11/O0 under ASan/UBSan. Native LeakSanitizer is unavailable
on this Apple toolchain; exact runtime-helper allocation observations are separate
from compiler leak counters and native lifetime/output tests.

## Provenance, costs and scope

Branch `codex/blorp-2-aggregate-roadmap`, HEAD `79deebd`. FRESH host SHA
`286a1720a36a75599f910e1b8ab838df642a3983409cd30ed3a6ef3dcf16ba79`,
Apple Clang 21 arm64, host CLI O0/runtime O2. The reviewed pilot uses O0 and
allocation diagnostics. `review-final/sha256.txt` identifies the complete snapshot:

- Checker: `724349ac96c43cf9231467ca29c710779330e1839158b6cc5b0a5c769a3569b2`.
- Specializer: `00309b74dc1e3a119391c60b5be064c35c78081c9fb9cc5c03e0229bc1ce0c9a`.
- Source archive: `01f455ed3a4b64b635d86bb805a93a285a04afd875ce0b9202fafa48a44e3d3e`.
- Frozen executable: `0ebc82ccfae396561ab47410ecda48c1ee5725934db50c96f15f696382f95be2`.
- Generated host C: `2fcf16cd3184a71f42c14696d0853104feebe4070a43c1cd78b0f0cb237ba051`.

The isolated native group links executable `77abe309…`; root's final full wrapper
links `c6f23484c67cac79e584939dfbdbca2ed836b5e5597edd0bcbc3ef39a118613f`.
Both independently produce the exact frozen C. Each tested executable and its C
are retained by purpose; a new link is not assumed byte-identical to an earlier
executable. All final source/test/library fingerprints match their recorded runs.

Twenty unchanged controls use frozen accepted-generic baseline `14b2d3b8…` and
final `0ebc82cc…`, the same inputs/library paths and three matched samples each.
All 120 invocations balance strict accounting; all 60 target-C pairs are identical.
The largest allocation increase is +0.3031% (wide16); the largest minimum retired
instruction increase is +0.1881% (constructors16). Both fixed 3% ceilings pass.
Independent review verifies raw samples, hashes and before/mid/after quiet
inventories. Snapshots cannot exclude unrelated work between observations.

Eight feature points vary distinct shapes and nested Box depth at 16/32/64/128.
Three samples each compare accepted generic, final generic and final direct
programs separately; 72 invocations balance and 48 C comparisons are identical.
At depth128, allocations are 164,781 /164,822 /160,788 and minimum instructions
874,007,209 /874,215,170 /848,467,900 respectively. The baseline does not accept
direct syntax. These are equivalent-program compilation proxies, not baseline
direct support, self-compilation or global linearity. Existing nominal-instance
and preparation scaling remains visible; the new path adds no second resolver,
cache, repeated inventory walk or growing shared-state carrier.

Production shrinks 48 physical lines (46 nonblank/noncomment) across five modules.
Implementer unit/grammar tests grow 723/613 lines; native/runtime tests grow
280/266; root adds two registration lines. Documentation grows 12/10 before this
report/status update. These figures compare against the accepted generic snapshot
and exclude ignored artifacts. Existing native fixture ceilings remain 140,000
allocations and 500,000,000 instructions; observed maxima are 15,835 /77,570,021.
