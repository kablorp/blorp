# Applied source review

Verdict: **APPROVE**. Blockers: **0**; should-fix: **0**; nits: **0**.

Reviewed the actual three-file boundary in `<compiler-checkout>` against HEAD `5b4b9467b11061ea1d77c76045ceb5f61f074398`. The applied emitter is byte-identical to the approved proposal:

- Emitter SHA256: `6a3046d175525881ab34939d3f7e1e548ec2f2aedff8ac594a4bedec43b83e76`.
- Core suite SHA256: `3c843c0edc419c84ded6939d6e5d6d157f623c13185e9be7a0bd9b3498e36b7b`.
- Runtime fixture SHA256: `be1fd1ee444da274550b8d0999229cec98530446c3a6665ee5fe208e8ed4673f`.
- Approved production proposal SHA256: `063f3d4807472657806e2b475db81540920f46ecaaf22728188b91ad4b547849`.

The emitter alone changes production: 182 added / 9 removed lines, net 173. `git diff --check` is clean. Untracked build products are separate from this source boundary.

Admission at `emit.brp:23272–23408` requires immutable counter-issued locals, exact cached Derived spelling, unique emitted identifiers, lexical reference identity, and `None` for bound references. Dup/Drop operands and closure captures/static symbols are examined explicitly. Raw struct boxing/list names require an exact selected type key or fixed StackResult spelling. Calls, control/resource exits and unsupported forms retain lexical scopes. No Core schema, frontend rule or public configuration changes.

Global-only issuance at `emit.brp:26951` leaves ordinary function contexts in `PreserveLexicalRhsScopes`. The sequential branch at `emit.brp:23436` prefixes only admitted DropTemp RHS statements, threads the existing temporary cursor, and passes the original Core RHS to the unchanged binding helper. Evaluation, moved-owner cleanup, cancellation protection and explicit drops keep their original order.

Actual fail-before evidence is appropriately separate: focused eight controls report 7 pass / 1 intended fail (`RESULT.json` SHA256 `6d62cccb9e404fcbc6e6abd7dbd526e907d79a32d67747225a3dccd37f16cebc`). The source-backed Linux fixture fails default Clang18 at bracket depth 256 (`PUBLIC_FAIL_BEFORE.md` SHA256 `877fe48ebdbc87e372cc38c0c063a05437a9dab5158ee28fff0d52ffe56bb089`). Live kind authority derives from typed producers; the Core JSON omission is qualified (`PUBLIC_CORE_ADMISSION.md` SHA256 `93c9d79aefce98a676be10aeccc58d8ce7f5bdd887997404141fb2041545b903`).

Limitations: this is source/test-design approval. Candidate build, pass-after, emitted C, default Linux compilation, runtime ownership/sanitizers, fixpoint and the matched 1% resource budget remain pending. The extracted-record assertions retain the global container; they establish copy/COW behavior, not independently a destroyed-container lifetime. No native commands or repository mutations were performed by this reviewer.
