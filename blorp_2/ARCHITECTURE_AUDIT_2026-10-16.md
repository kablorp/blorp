# Architecture audit: ownership, identities and bootstrap boundaries

The architecture is a sound basis for bounded extension. The compiler-expert
audit and two supporting read-only reviews found no confirmed supported
ownership or semantic-layout defect. They did identify a current String
publication gap. No architectural replacement, cache or additional framework
is justified by these findings.

Audited revision: `98f3472feaaf5183ef0fd5fdf3a24cda3fea5f91`.
The source tree is `5bdf015a1eaefcf3c31f6a8de3fe4f5ee6b36e03`, test tree
`128757870fea69fe5af1485e55347fbbac17abb7`. The subsequent legacy-host fix
`0e5a007691a14723057ab3eed76c022c49245bbb` changes neither pilot tree.
The audit mapped the 38-module import graph and traced representative
producer-to-consumer paths and phase/runtime tests; root separately inspected
boundaries and ran the native probes below.
This is source review plus bounded execution evidence, not a proof of all paths.

## Authorities and positive findings

| Published boundary | Authority and lifetime |
| --- | --- |
| Loading and assembly | Complete syntax, shared NameTable, source/module roles, declarations and dependency order; assembly alone seals ParsedProgram. |
| Checking | Resolved declaration/field/variant IDs, signatures, binding definitions, substitutions and complete bodies. Namespace/inference builders do not escape CheckedProgram. |
| Specialization | Reachable instances and complete concrete layouts; keys retain the declaration and complete ordered arguments, including phantom arguments. Pending recursive groups stay local. |
| Lowering | Function-local ValueIds and immutable definitions. The binding-version map is transient; LoweredJoin.reads is published once, consumed by insertion, then discarded. |
| Ownership | OwnerId names one discharge obligation independently of ValueId or pointer identity. Repeated stored occurrences require separate obligations. |
| Verification and emission | Raw ownership operations are untrusted. Verification replays actual operations and seals VerifiedProgram; emission consumes that seal and concrete layouts. |

The pipeline after loading is pure in [main.brp](src/main.brp). A static
relative-import scan found no cycle among production modules. No semantic
spelling recovery was found in specialization, lowering, ownership or verification.

Verifier independence is concrete: [OwnedJoin](src/own/own.brp) retains only
scrutinee, owner and arms, discarding LoweredJoin.reads. Verification walks actual
arm operations and snapshots ([verify](src/verify/verify.brp)); it does not
consume insertion's liveness decisions. Shared value_ownership is upstream
storage authority; raw layout graphs and summaries are validated separately.

Existing negative tests reject duplicate payload transfers, early backing-owner
destruction and invalid branch discharge. Acquired child projections can outlive
their parents. Aggregate runtime tests observe allocation occurrences and final
frees, not just balanced totals. These are strong representative oracles; future
carried mutations, loop edges and propagation still require their planned tests.

## Current defect: String admission is incomplete

The host [read_file](../blorp/src/lib/runtime/native/runtime.c) allocates a
String and publishes arbitrary file bytes without validating UTF-8. Pilot
[loading](src/load/load.brp) accepts it, and the source inventory retains it.
Documentation-block interiors permit malformed bytes even though ordinary
comments reject non-ASCII bytes.

Root executed a normal compiler/program reproduction containing these bytes:

```text
2d 2d 2d 0a ff 0a 2d 2d 2d 0a 66 75 6e 63 20 6d ...
--- LF FF LF --- LF func main() -> Int: LF TAB 0 LF
```

Pilot compilation, strict native C compilation and the program all exit 0.
The invalid byte remains in SourceInputs. This confirms a current boundary
contract violation, not merely an unimplemented future language feature.

This does **not** bypass target String-literal validation. Quoted, pipe and raw
literal paths validate leads, continuations, shortest encodings, surrogate
exclusion and the scalar maximum before parsing preserves their bytes.

A separate current producer is [diagnostic location scanning](src/main.brp):
substring(cursor, 1) can create an invalid temporary host String from valid
multibyte input. It only needs to observe a newline byte.

These are representative producers, not an exhaustive String-validity inventory.
Parser byte classification also uses one-byte substrings in decode_escape and
hex_digits ([parse](src/parse/parse.brp)). The existing unknown-escape test with
valid UTF-8 `\é` reaches the former path. The broader source byte-classification
migration must cover these consumers as well.

Resolve these at their owning boundaries:

1. Validate file bytes before publishing a language String, preserving exact
   valid contents and returning a useful Err for malformed encoding. Reuse an
   existing strict counted validator where sound; preserve cleanup and review
   binary-file consumers. A lexer-only rejection cannot repair earlier publication.
2. Complete the reviewed integer-facing String interfaces, then replace the
   diagnostic and parser classification substrings with byte observation. Keep
   byte-based spans/columns and diagnostic priority.

[Library parity](LIBRARY_PARITY.md) already requires fallible UTF-8 file
admission. These repairs block claiming that every String is valid UTF-8;
they do not require changing the ownership IR or weakening its verifier.

## Native structural-depth evidence

Nested joins emit two C scopes per level plus the function scope. Review initially
predicted default native rejection at depth 128. Actual execution disproved it.
Root generated new programs from the existing [deep fixture](test/e2e/fixtures/join/deep.brp)
family, preserving ordinary main and compiling the untouched emitted C.

| Nested joins | Lexical brace depth | No-argument exit | With x exit | Native result |
| ---: | ---: | ---: | ---: | --- |
| 64 | 129 | 63 | 101 | Pass |
| 128 | 257 | 127 | 101 | Pass |
| 256 | 513 | 255 | 101 | Pass |

Toolchain: Apple Clang 21.0.0 (`clang-2100.3.34.2`), default nesting limits,
`-std=c11 -Wall -Wextra -Werror -pedantic -O0`. No limit override or C rewriting.
This is demonstrated structural growth and bounded native success, **not a
confirmed native compiler failure**. Do not infer a vendor threshold from a
different LLVM version's defaults.

Compiler traversal stack depth and destruction of live compiler products are
different mechanisms. Iterative elaboration still publishes recursive CheckedExpr
chains ([expressions](src/check/expressions.brp)). Actual product-depth and
constrained-stack destruction acceptance in [M4](ROADMAP.md#m4-recursive-types)
remain open. Source indentation is not a substitute. This blocks bootstrap-depth
readiness claims; measure before introducing another release mechanism.

## Existing scaling debt

Generic recursion validation repeats all-edge reachability searches
([recursion](src/check/recursion.brp)); finite acyclic generic chains can cause
cubic dependency tests. Global specialization-instance scans permit quadratic
candidate comparisons. These are already recorded in [QUALITY_ROADMAP](QUALITY_ROADMAP.md);
its measurements are historical, not refreshed by this audit.

A transient SCC analysis could replace repeated reachability, followed by the
original ordered edge scan to preserve diagnostic priority. Instance bucketing
requires its own matched measurement. Growing definition vectors and recursively
returned emitted Strings likewise deserve owning-boundary measurements. Do not
use this inventory to authorize a cache or broad rewrite.

Priorities: repair String publication and byte scanning; retain the native-depth
evidence; prove actual bootstrap-product destruction before M8; then address
measured scan/copy costs in separate bounded changes. Ordinary opaque erasure
still depends on semantic-key preparation; future control-flow features still
depend on their explicit ownership-edge contracts.

## Retained reproduction evidence

Raw inputs, unchanged C, toolchain version, native diagnostics and exit receipts:
`/Users/keithphilpott/CLionProjects/blorp/blorp_2/build/architecture-audit-2026-10-16/`.
The pilot binary used is
`4b9482c7950b0375196949381bf726a434d53fe98275d2ea925e8c5b91a1fb86`;
its generated C is
`535656652858a8f38370f92614e4c439faf6a4c1a89a65a5b2810df49b15dff9`.
The commands ran from `/Users/keithphilpott/CLionProjects/blorp`. To reproduce
the admission result independently of retained files:

```sh
cd /Users/keithphilpott/CLionProjects/blorp
audit_root=$(mktemp -d)
printf '%s\n' '---' > "$audit_root/invalid.brp"
printf '\377\n' >> "$audit_root/invalid.brp"
printf '%s\n' '---' 'func main() -> Int:' '    0' >> "$audit_root/invalid.brp"
blorp_2/build/compiler --library-root blorp_2/standard_library_temp \
    "$audit_root/invalid.brp" "$audit_root/invalid.c"
clang -std=c11 -Wall -Wextra -Werror -pedantic -O0 \
    "$audit_root/invalid.c" -o "$audit_root/invalid"
"$audit_root/invalid"
```

The reviewed source currently exits 0 at every step; repaired admission must
reject the file before C publication. Build the pilot through its normal Makefile
if the recorded binary is unavailable, and record the resulting provenance.

Generate the ordinary nested-join family with this source generator, setting
depth to 64, 128 or 256:

```sh
awk -v depth=128 '
function tabs(n, s, i) { s=""; for(i=0;i<n;i++)s=s "\t"; return s }
BEGIN {
 print "pure func deep(selected: Bool) -> Int:"
 for(i=1;i<=depth;i++) {
  print tabs(2*i-1) "value_" i " = match selected:"
  print tabs(2*i) (i<depth ? "True:" : "True: 0")
 }
 for(i=depth;i>=1;i--) {
  print tabs(2*i) "False: " (100+i)
  if(i>1)print tabs(2*i-1) "value_" i ".add(1)"
 }
 print "\tvalue_1\n\nfunc main(arguments: List[String]) -> Int:"
 print "\tdeep(arguments.length().equals(1))"
}' > "$audit_root/deep.brp"
blorp_2/build/compiler --library-root blorp_2/standard_library_temp \
    "$audit_root/deep.brp" "$audit_root/deep.c"
clang -std=c11 -Wall -Wextra -Werror -pedantic -O0 \
    "$audit_root/deep.c" -o "$audit_root/deep"
```

Run deep normally and with argument x; the expected exit statuses are in the
table. File admission and byte-classification plans require failing tests before
implementation. These reproduction commands add no alternate C entrypoint.
