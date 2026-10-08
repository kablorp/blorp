# Inline tagged emitter identity census reconciliation

The integration gate found one exact-site rename introduced by
`e4da3cd2c6109b812b66444b8a355077ff988079` (Share inline tagged-value plans).
`emit_stack_option_none` became `emit_inline_tagged_empty`; both receive the
same `type_symbol_lookup: Dict[String, String]` parameter and pass it to the
resolved C type projection. The lexical context fingerprint remains
`ef9ea6ecabe56030`; only the enclosing function name changes.

The reviewed baseline change replaces that one exact key. Budgets, baseline
revision, coverage, allowed boundaries and unsupported capabilities remain
unchanged. The census is a source-shape ratchet, not proof of complete semantic
identity migration. No additional spelling lookup or identity authority is
introduced by this reconciliation.

Before: `scripts/compiler-identity-census --check` fails with exactly one added
and one removed string-collection key. After: it passes. The census harness
and full Docker premerge gate validate the integrated tree before publication.
