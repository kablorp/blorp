# Ordinary target dirname preserves lexical parents

## Status and contract

Plan plus unrun TDD source on `codex/target-path-dirname`, base
`f1a27fcb2cfc1b951dd27e4ffa0e10e9e1e226b3`. This is a planning source anchor,
not a FEATURE baseline freeze. Root and the independent target_memory reviewer
approved the complete static plan/TDD packet with zero remaining findings after
closing review, including the proved-boundary explicit-match adjustment. This
commit contains only the plan; the 122 test additions remain local, uncommitted
and unrun. No compiler calls, RED/green/mutation results, cost acceptance or
production implementation are claimed.

The [seven shell/path contracts](ROADMAP.md#seven-shell-and-path-functions) own
`dirname(String) -> String`. Ignore all trailing '/', remove the final component
and its preceding separator run, retain root, and return "." for empty/basename.
Interior separators/parents, valid UTF-8 spelling and counted NUL remain lexical.
The host body/oracle in `standard_library/src/path.brp:80` and
`blorp/test/test_runtime/test_sys/test_path.brp:26-100` already implement this.

The accepted target module `standard_library_temp/path.brp` contains only join
and its private separator predicate; retain those exact bytes. Its SHA256 is
`f720e2c42660528340dac3c783b13a851a1c5c039b422ea40bcf52167facca81`.
[Loader source integration](LOADER_SHELL_INTEGRATION_PLAN.md) owns later callers;
normalize remains a separate component-stack slice. This increment changes neither.

## Scope and caps before production code

Only add dirname/imports/bounded module docs to `standard_library_temp/path.brp`
when its prerequisites are accepted. No compiler/runtime/native change, Char,
Bytes, take_left copy, path builtin, proof type, failure primitive or new controller.
No host/source migration and no Option get_or dependency. The literal None arm
below completes the exhaustive match; this narrowly reviewed choice does not
change the general checked Slice API or authorize arbitrary recovery defaults.

Hard proposed physical ceilings remain production90 added/+90 net, tests200
added/+200 net including registry, one fixture/50 lines total, and public/API
docs15 added/+15 net outside this plan. No numerical waiver is requested.
The single fixture uses argv for25 individually named cases and no argv for the
three counted-NUL cases plus four lifetime observations. No NUL enters OS argv.
Per-new-fixture prospective limits remain205,000 compiler allocations and600M
normal retired instructions; they are unmeasured, with all tighter guards binding.

## Concrete proposed body and proof

Reuse the module's existing `is_separator`, TextOps and IntOps aliases. The three
scans traverse disjoint suffix regions with one decreasing Int; the input stays
borrowed and unchanged. There is at most one successful materialized extraction.
No String is updated on a loop back edge. The following body is review text only;
it is deliberately not installed into the join module while M3 is unavailable.

```blorp
pure func dirname(path: String) -> String:
    var end = TextOps.length(path)

    while IntOps.greater_than(end, 0):
        match is_separator(path, IntOps.subtract(end, 1)):
            True: end = IntOps.subtract(end, 1)
            False: break

    while IntOps.greater_than(end, 0):
        match is_separator(path, IntOps.subtract(end, 1)):
            True: break
            False: end = IntOps.subtract(end, 1)

    while IntOps.greater_than(end, 0):
        match is_separator(path, IntOps.subtract(end, 1)):
            True: end = IntOps.subtract(end, 1)
            False: break

    match IntOps.equals(end, 0):
        True:
            match is_separator(path, 0):
                True: "/"
                False: "."
        False:
            -- end starts at byte length and decreases only while positive.
            -- Here 0 < end <= length and end precedes an ASCII '/' byte.
            -- Valid UTF-8 makes 0/end scalar boundaries; None is unreachable.
            match TextOps.slice(path, 0, end):
                Some(parent): parent
                None: "."
```

Let n be the input's byte length. Initially end=n. Every decrement is guarded by
end>0, hence 0<=end<=n throughout; end-1 is formed only under that guard. After
the trailing run and final component are removed, the third scan removes their
preceding slash run. If end remains positive, byte[end] is the first slash of
that run. ASCII 0x2f cannot occur inside a multibyte UTF-8 encoding, so end is a
scalar boundary; 0 is also a boundary. Thus slice(path,0,end) must return Some
under the valid String/checked Slice contracts. The explicit None arm returns
"." only on violation of that proved invariant. It is not an alternate scan,
and it neither hides an unchecked operation nor eagerly constructs a default.
If the scan is defective and reaches an invalid boundary, the None result is
observable as wrong output; the Unicode mutation oracle below requires that.
An incorrect but scalar-aligned cut is independently caught by the ASCII oracle.

## Real prerequisites

Consume separately accepted checked [String Slice](STRING_SLICE_PLAN.md) and the
full current target library; current functional evidence alone is not acceptance.
Ordinary scalar while/break support still rejects at this base and follows
[M3](M3_LOOP_PLAN.md). The proposed signed guard uses the existing owner's
[greater_than leaf](INT_COMPARISON_PLAN.md), absent at this source anchor; consume
its separately accepted implementation, without arithmetic approximation or an
Int feature port here. No managed String loop carrier, Boolean operator feature,
get_or, panic or extra helper is required. Stop on missing prerequisite rather
than installing a body that cannot check. Normalized source loading and original
SOURCE R0 cost acceptance remain separate and held.

## TDD sources and literal oracles

The new `test/unit/test_library/test_path_dirname.brp` loads/checks the actual
single target fixture: its pure wrapper, String result, named and UFCS calls,
counted inputs and escaping parents must all check. It must currently fail at
missing dirname export; record exact actual diagnostic/help/span and status when
root grants RED. On either load or check failure, the test uses the matching source
inventory and production render_diagnostics, with singleton_diagnostic or the
complete render_failure result. After all rendered messages/help/notes, it prints
each primary [start,end) byte span in the same diagnostic order; no error is
collapsed to its first message. This expected failure has not been executed.

`test/e2e/test_path_dirname.brp` registers25 named argv cases:23 from the independent
host edge oracle plus `é/leaf -> é` and `ab/leaf -> ab`. The remaining three host
NUL cases use the same fixture with no arguments, followed by source/result alias
reads and a parent escaping a temporary source. One Example contains all26
states, including that final no-argv native_case, under one callback/directory and
one verify_all call: the fixture compiles/links once. Expected bytes are literal
in the suite. The existing end-to-end registry adds this group; no harness change.

After implementation, the native contract is exit0, empty stderr and exact stdout
for each of the26 normal-main states. Retain unchanged emitted C and use strict
C11/O0/Werror/ASan/UBSan links. Preserve existing join behavior and unchanged-input
C/diagnostics under the integration gates. No gate is reported green in this plan.

Three valid-source runtime mutations are required, each restored byte-exact with
a fresh affected green: omit the trailing-run scan (`/a///`, `a//b//` fail), omit
the preceding-run scan (`a///b` fails), and replace only final slice end with
`IntOps.subtract(end,1)`. The last must compile and fail both `é/leaf -> é`
(mutant None returns ".") and `ab/leaf -> ab` (mutant Some returns "a"). A compiler
or setup error is not a mutation kill. None must not mask the boundary fault.

## Proposed serial test commands; no execution grant

Use root's preserved functional c04 host and explicit matching std91 for these
TestSuite/pilot roles, never for SOURCE construction measurements. In this tree:

```sh
dirname_host=/Users/keithphilpott/Documents/Codex/2026-10-18/blorp-functional-c04-std91/bin/blorp
dirname_host_std=/Users/keithphilpott/Documents/Codex/2026-10-18/blorp-functional-c04-std91/standard_library/src
env -u BLORP_CC -u BLORP_LEAK_CHECK -u BLORP_MEMORY_STATS -u BLORP2_COMPILER -u BLORP_2_INSTRUCTION_CHECK \
  "$dirname_host" test --suite --std-dir "$dirname_host_std" --timeout 180 \
  blorp_2/test/unit/test_library/test_path_dirname.brp
```

After dependencies/body review, root names one source-matched dirname_pilot and
approves its generation/link separately. The narrow actual-main witnesses use
its ordinary CLI, retaining C unmodified:

```sh
"$dirname_pilot" --library-root blorp_2/standard_library_temp \
  blorp_2/test/e2e/fixtures/path_dirname/edges.brp build/target-dirname/edges.c
clang -std=c11 -Wall -Wextra -Werror -pedantic -O0 -fsanitize=address,undefined \
  -fno-sanitize-recover=all build/target-dirname/edges.c -lm -o build/target-dirname/edges
build/target-dirname/edges 'é/leaf'
build/target-dirname/edges 'ab/leaf'
build/target-dirname/edges
```

The first two stdout oracles are respectively UTF-8 `é`+LF and `ab`+LF; no-argv
stdout is the suite's literal counted-NUL/lifetime sequence. Every process in the
reviewed runnable packet explicitly unsets the same five controls; these concise
CLI examples are not that frozen packet. Then run the existing full component and
end-to-end owners with the named pilot and normal harness, including mutations.
No new measurement controller or campaign follows from these command sketches.
Root names an accepted B/full C/library/corpus and the existing metric contract
before any cost setup. No baseline, sample, waiver or source-cost verdict is chosen.

## Review and handback

Root and target_memory completed closing static review with zero remaining
findings. This plan is committed separately; keep the reviewed 122 test additions
local and unrun until a separate grant.
Return exact patch/file hashes and physical counts, actual later
RED/green/mutant/restored receipts and limitations. Stop for a cap, prerequisite,
identity, ownership or oracle failure. Root owns jobs, integration and publication.
