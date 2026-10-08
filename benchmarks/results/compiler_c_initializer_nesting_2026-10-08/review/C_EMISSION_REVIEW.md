# Public emitted C review

Verdict: **APPROVE** this emitted-C delta. Blockers: **0**; should-fix: **0**; nits: **0**. This does not close pending Linux, ownership, fixpoint or resource gates.

Reviewed baseline `public-host-v5/public.c` (SHA256 `558745780ebc041b6c9758c0bf379144dc2fe4bea03261cf8b63c5c0f987c1af`) against `candidate-short/public.c` (SHA256 `687fa9dfddfc157ddf3f7516f9abcc5e65a4b759689bbea5f38538b09d56ab25`). Both final Core files have SHA256 `f863a6e92c476a204e7e981dc1b2f41c07096316aa8d427de7008bea64cf2d08`. The candidate production emitter remains the approved `6a3046d175525881ab34939d3f7e1e548ec2f2aedff8ac594a4bedec43b83e76`.

All bytes before and after `__blorp_init_globals` are identical. The separate outer blocks for FIRST_ITEM, SECOND_ITEM, THIRD_ITEM and ITEMS remain. The record constructors and existing Dup statement expressions remain lexical. Only the linear DropTemp result spine becomes successive list-pointer assignments in the ITEMS block: the innermost list constructor retains its own expression scope, and its result flows through the same 300 distinct derived binders before the final ITEMS assignment.

Read-only inspection and a bounded lexical scan find 600 distinct introduced local declarations on each side, with no duplicate output identifier. Minted/derived names do not capture FIRST_ITEM/SECOND_ITEM/THIRD_ITEM, the `brp_ty1` typedef/constructor, static literal symbols, runtime helpers or the lexical `__lst` temporary. The initializer's maximum lexical brace depth, excluding strings/comments, falls from 302 to 3; this is a source-level count, not a macro-expanded Clang depth assertion.

The ordered 902 retain/allocation/list-release-hook/append/release calls are identical: 300 retains, 300 appends and 300 element releases, with list construction before the reverse-order local releases. The prior-global initialization order, final global assignment and registration of global cleanup are unchanged.

The supplied short logs report all eight Core controls passing, including the seven lexical-fallback output assertions, and all three runtime cases passing; the public host run reports success. Those assertions were reviewed against the applied suite, but separate full C dumps for every fallback were not supplied. The test runner owns final process/reap receipts. No native command or repository mutation was performed by this reviewer.
