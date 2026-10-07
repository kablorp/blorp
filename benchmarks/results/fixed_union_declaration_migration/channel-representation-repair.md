# Scalar channel-send status emission prerequisite

This retained author snapshot ends at the rebuilt-host handoff. Its pending-runner
wording describes that epoch; [final validation](final-validation.md) records the
subsequent independent GREEN gates and separate hygiene closure.

Migration-related minimal RED: channel-attempt-minimal.brp calls
try_send_attempt[String]. The f271 host emits a backend #error and native run
exits 1 before execution. The pinned 8999 host, using the same current Std sources,
emits supported C and native run exits 0. The exact current Core declaration is
EnumDecl(channel__SendAttempt), and the return/call result is EnumType of that
name. Baseline Core instead uses UnionDecl with four empty-field variants and
UnionType. Both retain actual variant IDs 177 through 180. This is a physical
layout admission gap, not a changed native channel-status protocol.

The narrow String failed-send suite independently reproduces the setup failure
in send_timeout_attempt[String], with zero assertions executed. Its failure log
is channel-narrow.stderr. Full runtime STOP evidence remains in the runner's
original /tmp/blorp-migration-finalhost.V0Y0HB packet.

One production owner changed: emit.brp. The channel return-type selector now
matches explicit physical UnionType versus EnumType. The former delegates to
the unchanged managed constructor/release-mask helper. The latter selects the
exact EnumDecl and real variant IDs through the existing constructor-symbol
projection, publishes the four native API send-status constructor values, and
has no receive constructors or payload release mask. Required constructors
remain validated by existing downstream gates. No integer tag guesses, source
spelling predicates, fabricated union rows, native status edits, or ownership
policy changes were introduced.

Tracked owning regression RED: 364/365, exactly the new scalar status emitter
case failed. Source-owner GREEN: 366/366, including actual issued constructor
symbol selection for try-send and timeout-send, existing boxed-value releases,
missing variant rejection, scalar receive rejection, and all existing managed
send/receive cases. Raw files: channel-emitter-red.*, channel-emitter-green2.*,
and channel-emitter-final-source.*. An implementation syntax setup stop is
separate in channel-emitter-green.* (discard question-bind was invalid; corrected
to an explicit Some/None match); that epoch executed zero assertions.

Both inert source spellings are retained as channel-ordinary.fixture.txt and
channel-fixed.fixture.txt. Each directly declares its own four-status type and
try-send/timeout-send native hooks, and checks accepted, would-block, timeout and
sealed outcomes with dynamically constructed String values. Both current f271
Core/C probes emit scalar layouts and the two unsupported hook bodies. A scratch
parser setup stop (inline else) is separately retained as channel-ordinary-red.*;
corrected actual ordinary evidence is channel-ordinary-red2.*, fixed evidence is
channel-fixed-red.*. They are not live test-discovery fixtures.

Retained sources are inert evidence. Materialize the chosen spelling at a unique
scratch .brp path before rerunning it (from the migrated checkout):

```sh
channel_probe_dir=$(mktemp -d /tmp/blorp-channel-replay.XXXXXX)
cp benchmarks/results/fixed_union_declaration_migration/channel-ordinary.fixture.txt "$channel_probe_dir/probe.brp"
bin/blorp compile --no-format --std-dir standard_library/src --dump-core --dump-core-file="$channel_probe_dir/probe.core.json" -o "$channel_probe_dir/probe.c" "$channel_probe_dir/probe.brp"
bin/blorp run --no-format --leak-check --std-dir standard_library/src "$channel_probe_dir/probe.brp"
```

Choose channel-fixed.fixture.txt instead for the other spelling. This recipe
applies after these inert files are retained in the repository report directory.

Real String ownership controls remain the existing failed-send and
receive-string leak baseline owners. Final runtime/broad/stage-2/fixpoint
verification belongs to the independent runner after the O2 rebuild, not to
these source-owner results. Independent A and B reviews approved with zero
findings. No commit/pin/release or frozen staging-tree mutation was performed.

Frozen source SHA256: 73ef0feee8f2fb621b86d0d8303c7f4cad7b4576f87b0c950b899e2c9f103a0d
Frozen test SHA256: 49779b7981834f0fd632636956b2f7760a86b59e188edf0bf8e4f608c7375a5a
Complete two-owner patch SHA256: a8eaedae8fc35552d0d17e2ed41a07537d2e2648e0428202e08e2b7558680af0

## Rebuilt host handoff

Explicit frozen-bridge O2 make exited 0. Matching-environment build status is
FRESH. Binary SHA256:
2f44843a7237816c10cdcb5269ada8b0e19152f7119027e90f31343edeafaa6e.
Generated CLI C SHA256:
40a1005cb4dd150ca672edf69085a050bb548b6e7359d4211f42fc7e4cf20e2c.
Compiler/Std source manifest before and after matches:
422dcb4ac1c86d23969fdc7829fcf72721a941b2a4b26621c609be1507d3cf22.
Test/probe manifest before and after matches:
0f340cd2dcf44f158d3132cf17801531ab075ef928da534c483661523b07fb6e.
Frozen staging binary and immutable bootstrap manifest hashes are unchanged.
Raw channel-build-make.* and channel-build-status.txt retain the build.
All compiled children ended and the token was released immediately. No
post-rebuild compile/runtime test was launched by this worker; independent
runner verification is pending and source-host 366/366 is not relabeled as
fresh-host runtime evidence.
