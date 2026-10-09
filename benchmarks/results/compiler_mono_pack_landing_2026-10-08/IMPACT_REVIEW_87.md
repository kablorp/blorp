# Bootstrap-pin integration impact review

Verdict: APPROVE the bounded bridge design and fresh integration validation, conditional on their actual results. No current-87 gate/resource acceptance is claimed. No native execution, repository/index/ref edit or asset installation occurred.

## Exact upstream change

`87e312047b4efa1eb320fff4fe22144ac575e66d` is a direct child of `0e1598ed616ed48d03b20bb5a7fe39c61ade6a18`. Its sole changed path is `blorp/build/bootstrap.env`: tag/version move from `dev-dbc23276a2a6` to `dev-0e1598ed616e`, with three replacement target digests. Manifest SHA256 changes from `c6b547476c41e318feef16545b75866e407b9f45360aaca6b9200db9502d47af` to `ccf4a77ab353a03e81e2868e0635facfb8967877e0974497a79d9d96607bb616`. Compiler, runtime, standard-library, test and recipe source bytes do not change in this commit.

The public [release](https://github.com/kablorp/blorp/releases/tag/dev-0e1598ed616e), published `2026-10-08T14:33:42Z`, identifies commit 0e. Read-only GitHub release API metadata advertises matching digests for all supported targets:

- aarch64-apple-darwin: `f0ddd748f51b2f449a46d5bfcf30aeb9c2f2f07468d761514dd408b40ca3ee91`.
- x86_64-unknown-linux-gnu: `55e7cada4017e03ac4225e3f1e69ee79b6da0fceefb5bfa841672fe41b055b8b`.
- aarch64-unknown-linux-gnu: `f379fad3f446032f09a69153c501bd30516e0b10254dca63cb6a94089cc9d907`.

These are verified advertised digests, not an independent download-byte or executable-version check. The normal bootstrap resolver validates actual downloaded bytes against the pin (`scripts/blorp-compiler-bootstrap:191–254`).

## Authority boundary and bridge

The previous 523-source/10-header/19-record equivalence does not extend unchanged to 87: the bootstrap record differs. `scripts/compiler-build-status:509–535` hashes the resolved generator executable; lines 617–628 explicitly reject a stale `compiled_by` bootstrap tag. Unchanged compiler-language sources alone cannot establish identical generated body or cost.

The retained baseline/candidate stage-2 proof remains valid historical matched evidence under its original 5e input and toolchain. To establish generator equivalence without new resource runs, compile BOTH sealed original baseline and candidate compiler payloads, including their exact generated inputs, with the verified new bootstrap. Require whole emitted C byte comparison with retained `baseline-stage2.c` SHA256 `4523c2344651b2873d67ed77f3a105c98390afe58c15c17164ebffac0c3eed1f` and `candidate-stage2.c` SHA256 `60cdcdd8dbe425e6a42bc012a4764967d1893882e2ee5014557ef83e6c7d2319`. Recheck runtime, headers, O2 recipes, harness, frozen self input and small workload authority. Preserve all original raw versions, hashes, timestamps and metrics; add a separate bridge receipt.

Exact C identity on both sides is sufficient to retain the bounded historical compiler-body acceptance with an explicit bootstrap-provenance qualification. It does not prove a new 87 binary's allocations/instructions, machine-code/link-layout identity, Linux cost or latest-tree workload performance. Stop reuse on any C mismatch; do not strip stamps, normalize C or compare only one side. If current-87 resource acceptance is required or the bridge fails, use new matched baseline/candidate pairs under the same new pin and existing three-sample, allocation/minimum-instruction +0.5% ceilings.

## Fresh landing gates

After all old owned jobs/children close, integrate the pin and run verified new-pin O2 `make`, FRESH status, build configuration and release-toolchain checks, package gate, the owning Mono/selected Core checks, and full current host premerge plus required Linux/amd64 Docker. Preserve explicit host timeout60 and documented Docker `--no-sanitize`/default budgets; do not convert old 0e results into 87 results. AGENTS' bootstrap row requires make/build checks/package; WORKER_CHECKLIST:73–75 requires final Docker and :124 requires matched toolchains.

Old interrupted Docker receipts remain STOP history. The new bootstrap can alter compilation despite unchanged paying sources, so fresh integrated correctness is required independently of a passing C bridge.
