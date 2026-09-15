# Core Match Binding Accumulation

Issue 112 replaces recursive child-list concatenation in Core match binding
collection with one private reverse binding sequence and one final list
materialization. The production `compile_match_cases` boundary, not a model or
the private collector, is the measured operation.

## Decision

Accept the reverse-sequence candidate. The wide/deep recursive workload cut
median allocations by 16.8% and elapsed time by 47.2%. The profiled production
binding-list `concat` count fell by 96.5%, from 28,300 to 1,000 calls. The
two-binding control changed by -1.7% in elapsed time, inside the 3% guardrail.

Reject the initial threaded `List` accumulator. Generated C retained the
accumulator across recursive calls, so `ensure_capacity` copied a still-owned
list. On the prefix fixture this produced 240,500 copied list entries and moved
the cost into COW growth rather than removing it. A `flat_map` alternative was
also rejected because it was slower and increased allocations by about 5%.

The accepted candidate intentionally leaves the leaf-arm
`arm.bindings.concat(...)` in place. The early/late prefix fixtures are
different semantic shapes and are compared only against their own baselines;
their allocation deltas distinguish recursive collection from retained-prefix
work without claiming that the two fixtures are interchangeable.

## Workloads and results

Ten measured pairs followed one warmup pair and alternated execution order.
Fixture construction, warmup, and semantic observation were outside the timed
window. All values below are medians.

| Workload | Arguments | Baseline time | Candidate time | Time change | Baseline allocations | Candidate allocations | Allocation change |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| recursive wide/deep | `recursive 100 128 8 1` | 12,959 us | 6,842 us | -47.2% | 155,501 | 129,401 | -16.8% |
| prefix early | `prefix-early 100 128 0 16` | 9,386 us | 6,216 us | -33.8% | 117,701 | 102,301 | -13.1% |
| prefix late | `prefix-late 100 128 0 16` | 8,681 us | 5,680 us | -34.6% | 117,701 | 102,301 | -13.1% |
| two-binding control | `recursive 1000 2 0 1` | 2,970 us | 2,920 us | -1.7% | 57,001 | 54,001 | -5.3% |

Releases fell by the same absolute amount as allocations for every workload.
Retained objects and retained allocator bytes were identical baseline versus
candidate: 399 objects / 26,512 bytes for recursive, 512 / 33,864 for each
prefix fixture, and 13 / 800 for the control.

Exact-profile observations further isolate the mechanism:

| Profile workload | Binding-list concat calls | List copies | Entries copied |
| --- | ---: | ---: | ---: |
| recursive baseline | 28,300 | 1,100 | 800 |
| recursive candidate | 1,000 | 2,300 | 25,600 |
| prefix-early baseline | 19,300 | 6,500 | 25,600 |
| prefix-early candidate | 1,800 | 8,600 | 38,000 |

The candidate's extra collection-copy entries are geometric capacity growth
while materializing the one uniquely owned final list; generated C contains no
retain before that list's `ensure_capacity`. They are aggregate-linear and are
not the recursive/prefix COW explosion seen in the rejected accumulator.

Width scaling at 32/64/128/256 bindings changed from
2,321/5,033/11,985/33,861 us to 1,733/3,072/6,260/13,193 us. Depth scaling at
0/2/8/16 around width 64 changed from 4,971/5,189/5,786/6,528 us to
3,026/3,676/4,067/4,149 us.

Raw paired samples are retained in
`compiler_core_match_binding_accumulation_2026-09-15.tsv`. The complete JSON
pair records and profile logs used for this decision are under
`/tmp/blorp-issue112/provenance-*`; their SHA-256 values are:

- recursive pairs: `14bd9277d460a2bbe90e3f548661b6977275ac86e8a523b7fa1f5723ad5d1339`;
- prefix-early pairs: `7e82aba6b62b97675157a0ad1dbd9546060f1391283438a4206942545b32a4c5`;
- prefix-late pairs: `105c56e50a9dfb809c52d081985d9e4dc09c9060d828055279a7077772673165`;
- control pairs: `fbdd78e3354c07cf71c0dcad1749644561eb4ed1e6dedfffe8f12554404e80cd`.

## Output identity and ownership

The comparison driver rejected any pair whose ordered
name/accessor/binding-mode checksum or complete serialized semantic match-tree
checksum differed. Every recursive sample reported semantic checksum
`8076480812249410447`, JSON checksum `1779002203049179179`, and 71,996 JSON
bytes. The prefix shapes and control likewise matched their same-shape
baselines exactly. All rows reported `workload_valid=True`.

The all-pattern regression preserves the existing traversal result, including
qualified constructors, tuple/list nesting, spread position, accessors, and
binding modes. The observed composite order is `first`, `third`, `fourth`,
`rest`, `second`: the selected constructor payload is appended after outer
bindings. Only `rest` uses `MatchOwnBindingMode`.

Generated implementation C was inspected rather than compared for byte
identity, because changing the compiler collector necessarily changes the
benchmark compiler's implementation. The retained files are
`/tmp/blorp-issue112/final-baseline.c` and
`/tmp/blorp-issue112/final-candidate.c`. The candidate contains the private
`PatternBindingSequence` traversal and the one-time flatten loop; its final
list stays uniquely owned through growth.

Downstream output identity was checked separately by compiling the same
absolute `examples/at_a_glance.brp` input with both compilers. Final Core dumps
at `/tmp/blorp-issue112/semantic-core-{baseline,candidate}.txt` are byte
identical with SHA-256
`ec6b392c953fb32250bac6174ff52f0c13a9b76eaddae1a58782c1a1c7a37501`.
Generated C at
`/tmp/blorp-issue112/semantic-generated-{baseline,candidate}.c` is also byte
identical with SHA-256
`4be553ea3f6dd20748dc3c3f6ae57343a8c7e76102175063ae1e99e272ffce75`.
This complements the benchmark's complete serialized semantic match-tree
equality. The benchmark does not expose a production profiling API.

The four profile diagnostics had no invalid IDs, unmatched or out-of-order
ends, stack-growth failures, initialization failures, or nonlocal exits. Each
reported five expected measurement-window abandoned frames at the boundary.

## Provenance and reproduction

Both sources derive from revision
`f6af78c039d1b9b362aa5f6f4e334c938e9254f7`. The baseline
`match_lowering.brp` SHA-256 is
`93a82da0a21ecb9d77f0b2933762309041d122296a10a91a03583d6957ee403c`;
the candidate is
`f2e3bd590e2c31847d9d8779d596558da5b0261707519df68f2847581e5bfb71`.
Both builds used the same benchmark source
(`e51b2571f7605271342bb91b74d014d24cf3f46ded6ee4e611456e65519c4a73`)
and fixture
(`e1bdaa620e61ac43909815f33e102641c1b475a09ee9ac4a1451a4b105e09565`).

The measured plain binaries are `/tmp/blorp-issue112/final-baseline`
(`e4f26acfa0d4b3ebd24bf9d2f0eecf206bed7753e5f7bd17b579bac07dad7e37`)
and `/tmp/blorp-issue112/final-candidate`
(`1a74284ec4482e103e0fa2518c32555a065e0759180e21541a88a88a0a27404a`).
Profile binaries are `final-baseline-profile`
(`998159a64305373a631270b3ff477ffe82b2ee4d7f4128fda15620ea7963e47d`)
and `final-candidate-profile`
(`e1c7e2b8075766518bc3b0fc7b61fce43f836987b8862d6ab296268d7861b8cf`).
Measurements ran on Darwin 25.6.0 arm64 with Apple clang 21.0.0.

The baseline was built in a detached worktree and received symlinks to the
byte-identical benchmark files. These commands reproduce the binaries:

```bash
issue112_root=/tmp/blorp-issue112
git worktree add --detach "$issue112_root/base" \
  f6af78c039d1b9b362aa5f6f4e334c938e9254f7
mkdir -p "$issue112_root/base/blorp/benchmark/compiler"
ln -s "$PWD/blorp/benchmark/compiler/compiler_core_match_binding_profile.brp" \
  "$issue112_root/base/blorp/benchmark/compiler/compiler_core_match_binding_profile.brp"
ln -s "$PWD/blorp/benchmark/compiler/compiler_core_match_binding_profile_fixture.brp" \
  "$issue112_root/base/blorp/benchmark/compiler/compiler_core_match_binding_profile_fixture.brp"
make -C "$issue112_root/base"
make

unset BLORP_STD
for variant in baseline candidate; do
  if [ "$variant" = baseline ]; then
    tree="$issue112_root/base"
  else
    tree="$PWD"
  fi
  "$tree/bin/blorp" compile --no-format \
    -o "$issue112_root/final-$variant.c" \
    "$tree/blorp/benchmark/compiler/compiler_core_match_binding_profile.brp"
  cc -O2 -fwrapv -pipe -w \
    -I"$tree/blorp/src/compiler/stage_04_modules" \
    -I"$tree/blorp/src/compiler/stage_06_typecheck/graph" \
    "$issue112_root/final-$variant.c" -lm -lpthread \
    -o "$issue112_root/final-$variant"
done
```

The recursive paired command was:

```bash
benchmarks/compiler_pass_compare \
  --label issue112-provenance-recursive \
  --baseline-bin /tmp/blorp-issue112/final-baseline \
  --candidate-bin /tmp/blorp-issue112/final-candidate \
  --baseline-source-root /tmp/blorp-issue112/base \
  --candidate-source-root "$PWD" --allow-dirty-source \
  --fixture "$PWD/blorp/benchmark/compiler/compiler_core_match_binding_profile.brp" \
  --fixture "$PWD/blorp/benchmark/compiler/compiler_core_match_binding_profile_fixture.brp" \
  --prefix CORE_MATCH_BINDING_PROFILE \
  --time-field elapsed_microseconds \
  --checksum-field semantic_checksum \
  --checksum-field semantic_json_checksum \
  --stable-field semantic_json_bytes --stable-field shape \
  --stable-field iterations --stable-field binding_width \
  --stable-field nesting_depth --stable-field constructor_columns \
  --stable-field input_bindings --stable-field output_bindings \
  --stable-field leaf_count --stable-field owned_spread_bindings \
  --stable-field modeled_recursive_concat_elements \
  --stable-field modeled_arm_prefix_concat_elements \
  --stable-field workload_valid \
  --metric-field allocations --metric-field releases \
  --metric-field retained_objects --metric-field allocator_bytes \
  --pairs 10 --warmup-pairs 1 \
  --results /tmp/blorp-issue112/provenance-recursive-pairs.json \
  --json -- recursive 100 128 8 1
```

Repeat with the three other argument vectors and result paths from the table.
The exact-profile binaries and logs used to count the remaining binding-list
`concat` calls and collection copies are reproduced with:

```bash
for variant in baseline candidate; do
  if [ "$variant" = baseline ]; then
    tree="$issue112_root/base"
  else
    tree="$PWD"
  fi
  "$tree/bin/blorp" compile --profile --no-format \
    -o "$issue112_root/final-$variant-profile.c" \
    "$tree/blorp/benchmark/compiler/compiler_core_match_binding_profile.brp"
  cc -O0 -fwrapv -pipe -w \
    -I"$tree/blorp/src/compiler/stage_04_modules" \
    -I"$tree/blorp/src/compiler/stage_06_typecheck/graph" \
    "$issue112_root/final-$variant-profile.c" -lm -lpthread \
    -o "$issue112_root/final-$variant-profile"

  for shape in recursive prefix-early; do
    if [ "$shape" = recursive ]; then
      args="100 128 8 1"
    else
      args="100 128 0 16"
    fi
    "$issue112_root/final-$variant-profile" "$shape" $args \
      >"$issue112_root/provenance-$variant-profile-$shape.stdout" \
      2>"$issue112_root/provenance-$variant-profile-$shape.stderr"
  done
done

for log in "$issue112_root"/provenance-*-profile-*.stderr; do
  printf '%s\n' "$log"
  rg '^list__concat__mono_.*CoreSemanticMatchBinding' "$log" || true
  rg '^COLLECTION_COPY_PROFILE_COUNTERS' "$log"
done
```

To inspect the accepted flatten loop in generated implementation C, locate the
only function that accepts the private sequence directly. In its body,
`bindings` flows into `ensure_capacity` without a preceding retain of that
list:

```bash
candidate_c="$issue112_root/final-candidate.c"
flatten_line=$(rg -n \
  '^static blorp_List\* .*PatternBindingSequence\* sequence\) \{' \
  "$candidate_c" | cut -d: -f1)
sed -n "${flatten_line},$((flatten_line + 90))p" "$candidate_c"
```

Finally, these commands reproduce downstream Core and generated-C identity.
The absolute input path keeps serialized source locations identical:

```bash
input="$PWD/examples/at_a_glance.brp"
for variant in baseline candidate; do
  if [ "$variant" = baseline ]; then
    tree="$issue112_root/base"
  else
    tree="$PWD"
  fi
  "$tree/bin/blorp" compile --no-format --dump-core \
    --dump-core-file="$issue112_root/semantic-core-$variant.txt" \
    -o "$issue112_root/semantic-generated-$variant.c" "$input"
done

cmp "$issue112_root/semantic-core-baseline.txt" \
  "$issue112_root/semantic-core-candidate.txt"
cmp "$issue112_root/semantic-generated-baseline.c" \
  "$issue112_root/semantic-generated-candidate.c"
shasum -a 256 "$issue112_root"/semantic-core-*.txt \
  "$issue112_root"/semantic-generated-*.c
```

## Validation

- `bin/blorp check --no-format blorp/benchmark/compiler/compiler_core_match_binding_profile.brp`: passed;
- `bin/blorp test --timeout 180 blorp/test/compiler/stage_09_core/test_core_match.brp`: 32/32;
- `bin/blorp test --timeout 180 blorp/test/compiler/stage_09_core/test_core_match_projection.brp`: 31/31;
- `scripts/compiler-check --changed`: passed one selected source, one owning suite, and `compiler-core-sanitize` in 131.57 seconds;
- `scripts/test compiler-core-sanitize leak`: 2,833/2,833;
- `scripts/test compiler-blorp`: 4,576/4,576;
- `git diff --check`: passed;
- `scripts/compiler-build-status`: `FRESH` after the final broad gates.
