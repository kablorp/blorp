# Perceus Tranche 4A — Function Result Normalization

This report compares the Tranche 4A candidate with its immediate uncommitted
Tranche 3 parent using separately compiled production and debug/profile backend
workers. Seven measured pairs alternated parent/candidate order. The focused
matrix measures direct Perceus over decoded ownership-ready Core; worker
startup and JSON transport are outside the reported inner window.

## Change

Function-parameter result normalization now traverses each closed result path
once for the complete ordered borrowed-owner catalog. Lexical shadowing and an
existing `DupExpr` satisfying a result owner are represented separately, so a
retain for one owner cannot hide another owner in the same branch.

The result-carrier whitelist is unchanged. Conditions, scrutinees,
initializers, assignment values, resource acquisition and cleanup, and
loop/task children remain outside function-result position. Direct variables
and transparent projections use the owner candidate index; complex aliases
retain the exact scalar predicate at an explicitly counted fallback boundary.

## Fixture

Each of two uncalled functions has an exact 256-node body. Its result is a
balanced tree of 32 terminal aliases of owner zero. A single outer sequence
places a 159-node traversable padding subtree outside result position. Extra
parameters therefore grow only the owner catalog.

```text
globals=1
functions=2
body_leaves=256
body_shape=borrowed_return
parameter_type=String
result_alias_terminals_per_function=32
params_per_function=1,8,32
samples=7
warmup=true
measurement_window=perceus-direct
```

## Paired results

| Owners per function | Parent visits | Candidate visits | Visit reduction | Paired inner-time ratio | Allocation ratio | Release ratio |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 130 | 130 | 0.0% | 1.035 | 0.997 | 0.997 |
| 8 | 1,488 | 130 | 91.3% | 0.928 | 0.932 | 0.930 |
| 32 | 6,144 | 130 | 97.9% | 0.725 | 0.764 | 0.758 |

At 32 owners, the paired direct-Perceus median improved by 27.5%, allocations
fell from 25,662 to 19,596 (23.6%), and releases fell from 25,072 to 19,006
(24.2%). At one owner, deterministic allocations and releases both improved by
roughly 0.3%; the timing variation was 3.5%, with no one-owner timing gate.

Candidate result counters were identical at all three points:

```text
borrowed_result_node_visits=130
borrowed_result_owner_candidate_visits=64
borrowed_result_alias_fallback_requests=0
borrowed_result_rewrite_actions=64
borrowed_origin_member_visits=64
borrowed_origin_storage_slots=0
```

## Correctness

Parent and candidate post-Perceus Core artifacts were byte-identical at every
matrix point. Their artifact sizes and SHA-256 hashes were:

| Owners | Bytes | SHA-256 |
| ---: | ---: | --- |
| 1 | 70,282 | `fccc16e88fb52b2fc8dd305a06f88d5f090cc027f8e299b7c532554d1de9c7b4` |
| 8 | 72,396 | `2bc89b9863fecdc1fe9186ac6c983a807090cdb1abe2a938e7781c519c59f4c6` |
| 32 | 79,644 | `156677723440309ba40a6b91064e17707f770879cdc7cf5a1f83c55a55296590` |

A separate rooted backend-emission comparison produced byte-identical C at
every owner-count point:

| Owners | C bytes | C SHA-256 |
| ---: | ---: | --- |
| 1 | 17,847 | `8a8724d4a88f9e4b7b196445c813b5ee3c0c55d74c62defbbc8915972c1436fb` |
| 8 | 27,325 | `f26eab423ea1a28146f4878beb1be91754ff153b431c18b103ab4284dd8e551e` |
| 32 | 73,697 | `70fbd8f81402d8e2cafe791cdfac3694114a42e3f7008ed6bea5e705dfa5ea99` |

The 32-owner full backend was neutral at a 0.992 paired inner-window ratio and
identical 72,850 allocation and 72,846 release counts.

The focused Perceus suite passed 319/319 tests, including new multi-owner
compiled-match, computed-terminal, exact-shadowing, closed-whitelist, and
owner-specific `DupExpr` regressions. The benchmark contract suite passed
39/39 tests.

## Reproduction details

The candidate timing and counter-worker SHA-256 hashes were
`b71f1343e043e508375b22fad7821c94cd90ee7c755a70431009147cf942a529`
and
`6570699fa1257bd88035988b64d7888f4929c408390762d88be01e1f781310ab`.
The immediate-parent timing and counter-worker hashes were
`bf551106ccc7967c743307b44ec68afec0d36197863839a24b2e81a9c65a9169`
and
`f5ea6b8daf477534e4628342603176977c9babc6ae7b3de057f95a4199284f14`.
The final harness SHA-256 was
`0b819f7922b78a7ccf0685b009e601da161135d131bd9c153782e81f11576103`.

## Production self-compilation smoke

One uncontended alternating candidate/parent smoke compiled the same current
compiler source through Perceus and produced byte-identical 317,889,953-byte
Core with SHA-256
`d7d600819134e43ea1a564e4af9e287ce85ad631b4f81224889e27a950bd1b08`.
Candidate wall time was 73.72 seconds versus 74.40 seconds for the parent
(-0.9%), and retired instructions fell from 1,162,106,473,084 to
1,154,859,600,288 (-0.62%). Maximum RSS was 6,175,866,880 versus
6,160,695,296 bytes (+0.25%). This single smoke is diagnostic rather than a
landing gate; the tranche-wide multi-pair self-compilation reprofile remains at
the 4D fusion checkpoint.
