# Derived record equality: self-compile cost

Date: 2026-10-06. Branch `traits/derived-record-equality`.

Question: what does compiling the compiler cost once the compiler derives
`Equatable` for every record whose fields are all Equatable? This is the cost a
compiler with derivation pays on the compiler's own source (the fixpoint today,
every build after the next bootstrap rotation). A program compiled by the
bootstrap-built compiler pays it only for its own and the standard library's
records.

## Method

Both compilers built at `cli=-O2 runtime=-O2` on aarch64-apple-darwin, clang 21:

- baseline: `dfe13e0ab` (the base branch before derivation);
- candidate: this branch at `dfac352ae` (records and tuples derived; rebased since as `26f420e75`).

Input: the same checkout of `blorp/src/main.brp` for both. Each compiler ran
`compile --no-format blorp/src/main.brp -o <file>.c` three times, alternating,
under `/usr/bin/time -l`. Other agents were using the machine, so wall time is
noisy; retired instructions are the signal.

## Result

| | Run 1 | Run 2 | Run 3 | Median |
| --- | ---: | ---: | ---: | ---: |
| Baseline instructions | 229.52 G | 229.70 G | 229.47 G | 229.52 G |
| Candidate instructions | 233.99 G | 233.03 G | 234.04 G | 233.99 G |

The candidate retires 1.95% more instructions. One `--time-phases` run each
puts the difference before dead-code elimination: early Core +381 ms (mono
+175 ms, trait resolution +55 ms, resolve +35 ms), Core lowering +83 ms, typed
frontend +78 ms. Late Core is unchanged within noise.

The derived impls exist for every derivable record from lowering until DCE
removes the ones nothing calls; the compiler calls none of them, because the
bootstrap compiler that builds it has no derivation.

## Output identity

The generated C differs only in numbering: with symbol names and numbers
normalized and lines sorted, the two files differ in five comment lines naming
bodyless `dict.get` mono instances. Both have 86,561 function definitions. No
compiler code changes behaviour.

## Follow-up

The early prune cannot drop them as Core stands: `dce.brp` roots every impl
method, and `apply_trait_references` makes every Equatable impl a candidate.
Removing most of the 1.95% needs four steps, as a change of its own:

1. record on `CoreImplDecl` that the impl is derived;
2. keep derived impls out of the root sets;
3. have `mono_impl.brp` materialise a derived impl only when a concrete
   operator or bound requests it;
4. let `prune_after_trait_resolve` drop the rest.
