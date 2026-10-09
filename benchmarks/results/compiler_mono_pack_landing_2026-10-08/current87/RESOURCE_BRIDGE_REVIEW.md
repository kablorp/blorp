# Independent actual resource bridge review

Verdict: **APPROVE — 0 blockers, 0 should-fix, 0 nits**, restricted to retaining historical paired5e resource acceptance across the upstream bootstrap rotation. Current87 host/Docker completion and final guards remain pending.

Reviewed actual `BOOTSTRAP_RESOURCE_BRIDGE.json` SHA256 `f128a5c9d0f1c772f66a9c46c0872ec3b4f19baa4d69afa9c99246cfcf69243f`, controller `95407d47b5df0f10cd368f004f9bf43d478c861b84a8110075ec3a1ab1712103`, GO inputs and recorded C-only command.

- Independently hashed the actual new bootstrap executable: `f0ddd748f51b2f449a46d5bfcf30aeb9c2f2f07468d761514dd408b40ca3ee91`, matching the current manifest. Preserved version log SHA256 `0db65de947924da827d847d17960d9bac01d5b9a2c531044e999d703f9ee0d7a` identifies immutable dev0e / full commit0e / dirtyfalse. Its release-builder clang17 and compiled_by old tag describe that generator; they are not substituted into the original clang21 measurement records.
- Rehashed all 3,914 sealed baseline-copy entries with zero differences. Copy receipt SHA256 `62da9b264a9e926a454b303ea2ef169107c6a86f5e611f508fed532e0d84f4d5`; original Mono remains `460626f3f4372df869bf8fe8c23a8e34134f08cd5e0bd4e19aeccb2ea2c94a16`.
- Recorded baseline C-only command uses the verified new generator, sealed-copy cwd and exact Make flags. It exited0, waited its children and left the installed compiler unchanged. Log SHA256 `a6cb83655999a26640a9819a1cda624e58d1a5b9b6af0bdeb638ccc956c2b43a`.
- Independently compared all 82,234,569 baseline C bytes with retained original baseline stage2 C: exact equality and SHA256 `4523c2344651b2873d67ed77f3a105c98390afe58c15c17164ebffac0c3eed1f`.
- Candidate half remains the already independently accepted fresh-Make emission: 82,234,545 bytes, exact whole equality with retained candidate C `60cdcdd8dbe425e6a42bc012a4764967d1893882e2ee5014557ef83e6c7d2319`; receipt `CANDIDATE_BRIDGE_REVIEW.md` SHA256 `c2edd371c2b471b4ed123ec613be80f7d81144d63a9b288bfa2c16b6267649bf`. The active host clean/rebuild temporarily removed its mutable Make output; this review relies on the preserved accepted candidate-half receipt and unchanged retained C, without polling or treating ignored-output cleanup as source drift.
- Rehashed current 523 paying/generated sources and10 headers: no differences. The19 auxiliary records differ only at bootstrap.env, whose new SHA256 is `ccf4a77ab353a03e81e2868e0635facfb8967877e0974497a79d9d96607bb616`. This is a qualified exception, not unchanged19-record equivalence.

Both complete compiler-body emissions therefore agree across the new generator. Original frozen input5e, raw measurements, samples, timestamps, versions and exact0.5% ceilings remain historical and unchanged. This establishes neither new87 executable resource measurements nor identical machine-code/link layout or Linux cost. No overall landing PASS is inferred; final current87 FRESH/host/Docker and post-gate source/input authority remain required.

No native process, source/index/ref mutation or original-evidence edit by reviewer. Only this new scratch receipt was written.
