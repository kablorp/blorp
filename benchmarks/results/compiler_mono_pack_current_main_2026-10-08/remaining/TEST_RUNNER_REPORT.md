# Independent test-runner: combined fix and Mono landing

**APPROVE.** Remaining-only continuation passed; nine foreground commands exited 0, all children were waited, session 57957 was consumed exit0, the shared slot was released, and the exact owned remote container is absent. No further compiled gate is required for these frozen inputs.

## Build and authority

Host CLI is FRESH/O2, SHA 94fe3cf1bb5c0d5b93ff8af6f79ee3de059450082e63a0141a630af1a4a9d478; stamp c0b7ba1f899a-dirty, dev-0e1598ed616e, Apple Clang 21, split 8, memory mode 0. HEADc0b7ba1f899a8373255065409e1e7fbff18479f6 and staged 98 tree 5520411c62e5e04900cc1b3d0c8c90beefba26ca remain frozen.

The metadata bridge permits exactly sixteen reviewed ancestor reports plus one new projection manifest. Original staged 81 blobs and all compiler/test bytes are unchanged from the closed host attempt. Final paying 529/generated sources, 10 headers, 178 auxiliary pins, installed issuer, 3952 frozen input paths, retained cost/pairs, original 6052-file source inventory outside these exceptions, and both architecture drafts all match their closed authority. The current inventory is 6053 files. The separate metadata projection manifest is 5c006f691d9e55ca7db18d9b8e293678b73e596b7a154fb1d615137176a0ae8c.

## Actual results

| Boundary | Passed | Failed | Qualification |
| --- | ---: | ---: | --- |
| Mono owning suite |39|0|Guarded cost batch, unchanged source/tests|
| Host Core ASan |2642|0|Original closed host attempt|
| Host benchmark tooling |206|0|Preserved 989 benchmark change selected|
| Host full test aggregate |19662|0|Ten completed components reused|
| Host generated-C audit |238|0|One worker, original attempt|
| Host runtime UBSan |5581|0|PASS labels and equal suite-summary sum|
| Remaining canonical security/drift |PASS|0|Unchanged function bodies; no skip/regex weakening|
| Metadata hygiene/artifact checks |PASS|0|Census 3528; magic 502 and 0 stale|
| Required Linux full test aggregate |19662|0|Actual full CI gate|
| Required Linux generated-C audit |238|0|Default gate settings|
| Linux smoke/examples/security/drift |PASS|0|Actual final step records|

Linux components: compiler 7297, compiler-tools 260, std-check 1, runtime 4831, leak 1254, doctests 1057, CLI-deep 189, LSP 36, compiler-new 1064, parity 3673; each failed 0. All 281 compiler TestSuites passed 6,434 cases plus 863 production fixtures. The exact complete compiler child log was captured before cleanup (SHA bab55590f82b5c73d488455701cfc3fa555b7bddc15618a573256e2a321ec1b1). Counts overlap and are not summed into a unique-test total.

Docker used the configured **SSH blorp-gate** route, Linuxamd64, immutable image b88ff4627daebb6e897a5e6691e25764868a836d23bc03459eecfb62ce183ae2, source snapshot 0d74f0a13dfa2cdcf366b7f53ee344e9e46f5969 (tree 552041…, parent c0b7…). Its standard clean build reports Ubuntu Clang 18.1.3, dev-0e1598ed616e, CLI/runtime O2, split 8/mode 0/dirty false; construction split jobs 2. No nesting-depth override was requested: the standard default-Clang combined 281 corpus that previously failed now passed. This does not claim every nested fixture internally uses the same C driver.

Host general timeout was explicitly 60 from its first invocation (compiler 360); Docker retained actual defaults general 30/runtime 60/leak 60/compiler 360. Host timeout/audit settings were removed before Docker. Docker intentionally used `--no-sanitize`; current host CoreASan/UBSan and prior standalone fix Linux ASan/zero-leak evidence are separate. Nested Docker was skipped inside the container; the required outer Docker gate actually ran and passed. One documented tooling unittest skip remains reflected in the raw log. Linux premerge completed 2,837s, including its rebuilt-CLI smoke control; normal cleanup was observed.

## Preserved failure and composite acceptance

| Attempt | Actual outcome | First failure and classification |
| --- | --- | --- |
| Original host 58994 |FAIL security; compiled components 19,662/0|35 machine-local-path citations in 15 ancestor reports, all byte-equal clean 5b; no secret/compiler failure. Docker and final drift had not run.|
| Remaining 57957 |PASS composite; zero current failures|Exact 17 metadata path-only/owner-label repair, canonical security/drift/static completion and required full Linux gate.|

The original FAIL, commands, full host log, source/index snapshots, STOP and release are immutable in `../mono-integration-gates-attempt1/`. This is **component/composite acceptance**, not a relabelled original full-host PASS. No passing compiled host gate was repeated.

The independently approved Mono comparison preserves frozen 5b/raw baseline authority and exact c0b7 stamp exception: self allocations +1/min instructions +0.04005711468%, small allocations +1/min instructions −0.07770600110%; both whole C outputs identical and exact 0.5% integer ceilings pass. The prior standalone global-spine fix 1% cost/intentional C delta and retained stage2→3 equivalent fixpoint remain separately qualified historical 5b evidence. No new combined fixpoint or performance gain is claimed.

## Exact receipts

- [Commands](commands.json), [composite result](FINAL_RESULT.json), [post-gate paying authority](POST_GATE_AUTHORITY.json), [native release](NATIVE_RELEASE.json).
- [Required Docker raw log](docker-ci.log), [FRESH](fresh-final.log), [version](version-final.log), [canonical extraction](CANONICAL_EXTRACTION.json).
- [Original host report](../mono-integration-gates/TEST_RUNNER_REPORT.md), [ancestry proof](../mono-security-path-ancestry.json), [cost result](../mono-integration/comparison.json).

Composite FINAL SHA3aaebefeb4172cdb146a758060ed3569e5f51910fccf5e8002e643b238a38d53; post-gate authority SHA36e11f44abcae1f888562a580e8da656c8e9fab610fa844bde04bda4b611bdef; Docker raw log SHA2b8f6e5d57763781c25884ccaa0de2974620b156b338957ad35e81c4ba6eaceb; release SHA0ad50a5358aab93c6f50f972f8e8488a3781496032048f7bf52e9058bbc69a16. Huge C/binary/source inventories remain private and pinned. Repository publication/Git actions are root-owned and were not performed by this runner.
