# Readable embedded test programs with identical bytes

209 long program literals in 37 test files now use aligned multiline strings.
Their contents, terminal newlines, assertions, diagnostic spans and TestSuite
registrations are preserved. Production, temporary-library and fixture files
are unchanged; this does not add syntax to the pilot input language.

Physical test growth is **1,659 added / 209 removed, +1,450 net**. The literals
belong to 133 test functions, 16 helpers and one constant. Malformed whitespace,
CRLF, token traces, expected C/diagnostics/stdout and useful short fragments
keep quoted escapes where those express their bytes clearly.

For example, the final empty pipe retains the original terminal LF:

```blorp
valid: String =
    |func void_value() -> Void:
    |    void
    |func main() -> Int:
    |    0
    |
```

## Review and observed tests

Root and a separate compiler expert reviewed the conversions and their exact
original/candidate pairs. The integrated worker base is `703f30626`; its
production, library and pre-conversion test bytes match published main
`c4ec843d622b3c9a60d86cf559494faced565438`. Publication documentation is not
substituted for a source or behavioral comparison.

An ordinary ignored Blorp TestSuite passes **209/209** original-quoted versus
actual-multiline comparisons. Removing one representative terminal LF causes
exactly one failed comparison; removing a literal tab does likewise. The
restored representative passes. Each companion executes its one comparison
with empty stderr; these are assertion failures, not parsing failures.

The first aggregate owning run stopped before callbacks: a newly extracted
String binding named `declarations` collided with the existing parsed-inventory
binding in `test_visibility.brp`. That is a test-source defect, not a change
in compiler acceptance. The two-reference correction names the input
`declaration_source`; the inventory and every assertion stay unchanged. A
separate audit of introduced bindings, including parameter/lambda/loop/pattern
positions, found no sibling collision.

The corrected **37 owning suites pass 576/576 callbacks**, exit 0 in 5.31
seconds with empty stderr. All 209 literal payloads remain byte-identical
after the binding rename; the byte and mutation oracles were not rerun and
are not described as new executions. The frozen normal host stays FRESH:
SHA256 `899e0a92cfe1bc91f992bd3ccdd0755448903eb91d91780ac4870bd13d8cfa17`,
CLI-O0/runtime-O2/split8, bootstrap dev-0e1598ed616e, Apple Clang 21/macOS arm64.

## Exact artifacts and destination gate

| Artifact | SHA256 |
| --- | --- |
| Corrected complete feature patch | `aba0cee414ee065ace71667e4994f58cdeaac862066453e0e21ec5b000001c57` |
| Corrected actual source-pair packet | `adca5039feb75c12e126b71e02174b435ca906686de6a84faf39e108c09df0d1` |
| Unchanged 209-callback byte oracle | `25287d7ee8ae95c72d13d233c578499f7dffd08f6f7cc33b8de11f3fcd32a11f` |

The original `eb9f6d…` patch, byte/mutation results and owning setup failure
remain under `quality-multiline-integrated/blorp/build/quality-multiline-integrated/gates/`.
The correction and matching pair metadata are under `binding-correction/`;
the independent green receipt is `owning-binding-corrected-20261016/REPORT.md`.
Its 4,629 input paths, HEAD, index, patch, host and 114 prior evidence files
remain unchanged through the rerun.

The actual-main literal `make -C blorp_2 test` passes, exit 0 in 250.11 seconds:
2,814 component checks (2,648 host and 166 nested runtime-C checks), 445 e2e
checks and no failures. The run checks 351 positive strict cost rows against
their existing limits; native execution uses 351 links and 522 runs of
unmodified emitted C with the existing ASan/UBSan settings. The generated pilot
C remains SHA256
`7a88e4c053afc592c9bdcb8f56a65d7fb2103e3eb760ecd4891f931bb63368b8`.

The dynamic frontier also passes, exit 0 in 20.05 seconds: 34/36 source modules
parse. The remaining gaps are unchanged: Char syntax at lex offset 7,438 and
the function-type `pure` at specialize offset 11,650. This is not a
self-compilation result. The frozen destination host remains FRESH, SHA256
`390bdd0dd10d2f916c2d795462a278ed6bfa88b4c47928f9807ede748d331c7a`.
All 4,629 input paths, HEAD, index and prior 47 emitter receipt files remain
stable through both gates. The destination receipt is
`blorp_2/build/multiline-landing/REPORT.md` in the main checkout.

There is no production data-model change or new matched performance claim;
gate wall times are bookkeeping. No compiler cache, fixture adapter, alternate
main, emitted-C rewrite or counter/timeout change was added.
