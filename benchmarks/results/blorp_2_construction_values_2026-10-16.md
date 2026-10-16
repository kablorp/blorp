# Blorp 2 construction functions for bootstrap

Replace 22 ErrorText, three Utf8Form, two Span and one SourceId global with
named pure construction functions. This explicit bootstrap exception avoids
record/opaque constant initialization; it changes no supported input behavior.
SourceId retains its existing reserved identity, both internal-span helpers
read that authority, and Utf8Form values are constructed once locally as needed.
Fresh host Core contains only 71 literal globals: 40 Int and 31 String.

Production: **258 added / 200 deleted / +58 net**, within 300 added / +80 net.
Tests: **70 added / 56 deleted / +14 net**; one new identity callback, no removed
coverage. Ten production modules and 20 test modules change. Fixtures, grammar
and library are unchanged. Root and two independent compiler experts approve
the frozen source patch `8ea0e5dd`; a separate runner audits tests and costs.

Baseline characterization passes 217 callbacks; candidate passes 218. Changed
owners pass 340; accounting for overlap gives 481 distinct callbacks across 31
suites. A temporary changed indentation message causes two named callback
failures, then all 31 callbacks pass after exact restoration. Source identity
tests cover repeated construction, reserved roles and separation from root.
Generated C review confirms inline Utf8Form/Span/SourceId carriers and ordinary
ErrorText construction; no new storage class, identity minting or ownership path.

Matched costs compare source `cd061c77f` with the candidate. Reset `78bc406d6`
has identical source/library/fixture bytes, so local and cumulative bases coincide.
Both pilots are built once using frozen host `899e0a92`, O0 diagnostic links,
and Apple Clang 21 on macOS arm64. All 452 immutable fixtures and eight target
library files use one physical input path. Strict counts and normal instructions
are separate runs; normal samples unset leak/memory variables.

| Boundary | Baseline allocations | Candidate allocations | Baseline instructions | Candidate instructions |
| --- | ---: | ---: | ---: | ---: |
| 452 inputs, summed per-input min3 instructions | 5,445,737 | 5,435,793 | 18,156,271,876 | 18,147,006,338 |
| Frozen-host source-to-C proxy, min3 | 23,636,801 | 23,235,405 | 43,596,663,759 | 42,583,096,595 |

All 904 strict calls balance allocations/releases with zero leaks. Accepted full
C (356 inputs), rejected diagnostics (96), status and stdout match. All 2,712
normal samples match the strict oracles. Every input uses exactly 22 fewer
allocations; the largest instruction increase is **+0.240305%**, below the per-input
3% ceiling. Proxy allocations fall 1.698182%; instructions fall 2.324873%, also
within both caps. This is a host-build proxy, **not self-compilation**. Small
fixture differences establish bounded cost rather than a general speedup claim.

Relative-source pilot C changes `c9d9d458` to `46ee226f`; linked binaries are
`38110751` and `1a914abc`. Canonical-path proxy C is a separate boundary:
`7001e139` and `aba7546a`. Within each variant normal and diagnostic C agree;
no cross-path normalization occurs. Allocation proxy uses diagnostic host
`86ba69ff`. Source, input, toolchain, binaries and raw/semantic Git endpoints
match, with frozen host FRESH throughout. Independent root and runner audits
recompute all minima/ratios and verify complete artifact hashes.

Actual-main `make -C blorp_2 test`, with instruction checks required, exits 0:
**2,903 component checks** (2,737 host callbacks and 166 nested runtime C checks)
and all **452 e2e cases** across 39 groups pass. Its separate FRESH host is `390bdd0d`
(CLI O0/runtime O2, eight TUs); it produces the exact measured candidate C
`46ee226ff8f4b4061d0f417143256bf489b20584970e71c4967a414b32422ea4`.
The actual-main O0 pilot binary is `632ac33d`. The source-tree frontier remains
36/38 at unchanged Char and function-type stops; this is not bootstrap proof.

Host-generated C link warnings rise 83 to 84: one additional redundant equality
parentheses warning, with qualifiers and pointer/integer categories unchanged.
Both links succeed; this source slice does not repair the existing host emitter.
No retry, excluded sample, changed cap, rewritten input/C, cache or copied host.

Raw source/focused/mutation evidence is retained in worktree `78ef/blorp` under
`blorp_2/build/construction-values/`; `cost/` holds recipes, all 3,624 calls,
manifests and receipts. Root's independent recomputation is under its integration
worktree's `blorp_2/build/construction-values/root-independent-cost-audit.json`.
Actual-main gate logs, exit receipt and host/pilot/source endpoints are under
the primary checkout's `blorp_2/build/bootstrap-construction-acceptance/`.
