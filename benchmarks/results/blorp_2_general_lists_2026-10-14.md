# General finite Lists: typed facts and ownership

The pilot now accepts `repeat`, generic `length` and owned `get` for every
currently supported finite element type. This removes the former String-only
admission summaries without relaxing finite-type, pure-Void, simultaneous
substitution or main-argument rules. Recursive data and functional updates
remain subsequent increments in [the roadmap](../../blorp_2/ROADMAP.md).

## Producer and consumer boundary

Checking publishes List operations with their real element TypeRef and resolved
constructor roles. Source calls remain ordinary function wrappers. Specialization
prepares nested layouts and translates the element and roles once. Ownership
classification remains a specialization fact; raw verification separately checks
nested catalogue membership even for unused signatures and definitions.

Runtime roots have concrete typed slots. Repeat clamps nonpositive counts before
unsigned conversion, checks allocation sizing and acquires every initialized
stored occurrence. Get returns presence separately from an acquired element.
Nonfinal release touches only the root; final release destroys each initialized
occurrence. Unmanaged elements need no child ownership operations. Literal
String bytes and conversion-produced Strings both have allocated roots today.

Emission derives a disposable complete key from List depth and the typed
primitive/record-instance/union-instance terminal. It gathers suffixes once,
stably sorts existing host-library keys and deduplicates adjacent complete keys.
This is neither another semantic catalogue nor a bootstrap-readiness claim.
The same production aggregate fragment supplies direct helper tests and normal
compilation; argv uses the concrete String specialization.

## Tests and independent review

The initial restricted List phase suite had 26 passing and 3 failing callbacks
before implementation. The new raw-membership matrix had a genuine 9-pass/7-fail
red after its seed was corrected; earlier invalid seeds were setup failures.
Five migrated frontend suites retain all 177 callbacks and their embedded source
bytes. Former bans now assert complete identities, arguments, substitutions and
layouts; existing real rejection guards remain.

The direct native matrix has 24 cases, driven by Blorp TestSuite callbacks through
the existing actual allocator-occurrence observer. It covers primitive and Void
presence, inline records/unions, Strings, managed records, active/inactive union
children, nested Lists, escaped values, repeated pointers and counts 16–128.
Strict C11/O0/Wall/Wextra/Werror/pedantic/ASan/UBSan runs pass.

Six source mutations reached native failures: missing repeat acquisition (14
cases), missing get acquisition (5), dropping only the first occurrence (12), a
payload-zero presence sentinel (5), an uninitialized advertised slot (24), and
inactive-payload destruction (exactly its one case). Disabling raw List descent
fails nine membership callbacks; disabling global List-field scheduling fails
five. A wrong generic-substitution position fails exactly the strengthened remap
callback. All source bytes were restored after each mutation.

Independent compiler-expert reviewers approved source and narrow oracles. Review
found and corrected a runtime-role diagnostic-priority regression, incomplete
remap/retirement/structured-element assertions, new tuple matches, stale help,
and accidentally removed unrelated README paragraphs. Existing unknown-role
diagnostics retain their original oracle. Setup failures also exposed a host
alias-plus-named-import limitation, unsupported builtin constant evaluation and
illegal C fields for a host `RuntimeOperation[Int, Void]` instantiation. Scalar
contract tests use their actual metadata domain, `Concrete.TypeRef`; pilot Void
values continue to use `Concrete.VoidType` and pass native tests.

The final required-instruction gate, `env BLORP_2_INSTRUCTION_CHECK=required
make -C blorp_2 test`, exits zero with empty stderr: **2,209 unit/runtime/grammar
callbacks and 331 normal-main e2e cases pass**, with no failures. The test harness
builds the pilot once and runs the fixture groups. Its nested `[PASS]` lines are
not additional e2e cases. Two independent compiler experts approve the final
source, test oracles and evidence, with zero open P0/P1/P2/P3 findings. One
reviewer excluded the five frontend test files they authored; the other reviewed
them independently. This increment is accepted.

## Frozen whole-CLI comparison

The baseline is the validated fresh-main pilot before this feature, with its
source archive frozen at `e6696dd50`. Both binaries use the same FRESH host
`c2991129d1bbfc344b90ee466e37517bd41ef2d3f35801b6283e157ec24e13fe`,
Apple clang 21 and `-O0 -DBLORP_MEMORY_DIAGNOSTICS=1 -lm -lpthread`.

| Artifact | SHA256 |
| --- | --- |
| Baseline pilot | `e4800c0928c39e2201ebccf6da83ea84d9fc9ec571f864540e2026f8ef11fad3` |
| Candidate pilot | `10373703e1f057bbee3c1e7c960b0b5e93ef5ec85e329c4e92ae232cf52b261c` |
| Candidate generated host C | `a0080d95533641fccb7d22e6246e12ca6c2fe3bfecaaff461c9479e4ee1bf48d` |
| Full-gate rebuilt pilot | `d5463fb23a9a08380c31212c40d31553420a5df1d2618d2d45e133feeb18f77d` |

The full-gate rebuild emits byte-identical host C with the same compiler flags;
its native binary hash differs from the frozen measurement binary. Both actual
artifact hashes are retained rather than claiming native binary identity.

Three alternating pairs for each of 36 frozen shared inputs produce 216 samples.
Every process has stable allocation counts, balanced releases and no reported
leaked objects/bytes. Generated target C is identical on all shared inputs.
Worst allocations increase **0.752924%** (`captures-128`); worst minimum retired
instructions increase **1.893557%** (`fields-string-16`). Both satisfy the 5%
working target and 10% per-input hard ceiling. These are compiler-input proxies,
not self-compilation measurements. Existing e2e ceilings are unchanged.

Local provenance, samples and recipes are retained under
`build/next-increments-20261014/list/` and
`build/authority-fixes/general-list-final-20261014/`.

## Emission scaling and the host-library tradeoff

Generated-C inspection caught two new loops repeatedly copying the growing
String prefix. Their bounded eight-line repair gathers completed local fragments
and uses existing `List[String].join` once. Both local vectors move their uniquely
owned roots into capacity expansion without retaining the previous roots; join
moves its unique String accumulator
into expansion. Before/after fragments are byte-identical for all 18 workloads;
the six normal-main List fixtures also emit identical C and run identically.

Preparation and one complete identity output are outside the measured interval.
The interval covers aggregate emission, length access and output destruction.
Three alternating R0/R16 pairs use the same input/runner/output paths, with
minimum R0-subtracted retired instructions. All process/interval counts balance.
This does not isolate destruction or measure runtime slot construction.

| Shape | Size | Before instructions | After instructions | Change |
| --- | ---: | ---: | ---: | ---: |
| List depth | 16 | 3,497,341 | 4,433,516 | +26.77% |
| List depth | 128 | 32,561,877 | 36,804,322 | +13.03% |
| List depth | 512 | 195,257,726 | 149,541,303 | −23.41% |
| Distinct element types | 16 | 5,703,916 | 6,866,469 | +20.38% |
| Distinct element types | 128 | 78,167,136 | 82,314,353 | +5.31% |
| Distinct element types | 512 | 730,180,461 | 674,418,076 | −7.64% |

The host join copies each byte with a cooperative checkpoint, while the old
concat uses bulk copying. Consequently the linear builder costs more at smaller
sizes; this is not a universal speedup. At 256 and 512 the removed prefix-copy
cost outweighs that constant overhead. Depth now scales close to twice the work
per doubling. Repeated same-element sites keep helper output at 1,314 bytes through
512 sites. Distinct-type scaling still contains **inherited aggregate-emission
prefix threading**, so the whole emitter is not claimed linear. That debt and the
host per-byte checkpoint deserve separate bounded follow-ups.

All 18 production helper fragments compile with strict C11/default clang nesting
limits. Maximum emitted brace depth is two, including 512 layers/types. These are
compile-only stress inputs; their deliberately recursive provider mains are never
executed and are not e2e substitutes.

## Size and remaining scope

Before this report, the complete slice adds **51 production lines**, **2,585 test
lines** and **64 documentation/grammar lines**, counted separately including new
files. Necessary test growth preserves old source programs and expands granular
contracts rather than compressing assertions or deleting coverage.

Lists remain immutable. Record/List updates, recursive nominal types and general
bounded-stack destruction are not implemented by this slice. Runtime count
coverage proves one root and n applications of the element ownership contract;
it does not imply n physical retains for unmanaged or multi-child elements.
