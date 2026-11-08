# Diagnostic kind (CLI P1): self-compile cost

`Diagnostic` gains `kind: DiagnosticKind` (`ProgramProblem | PathProblem |
CompilerFault`, a fixed union), replacing the exit-status guess from
`compiler_span` and `LoadFailure.unreadable_input`.

Baseline: the compiler built from `c00e1e421` (`blorp/build/compiler.c`).
Candidate: the compiler built from this change. Both are linked at `-O0` with
`-DBLORP_MEMORY_DIAGNOSTICS=1` and compile the same input,
`blorp/src/main.brp` of this change, with `BLORP_LEAK_CHECK=strict` under
`/usr/bin/time -l`. Three serial runs each, one machine (macOS, clang).

| | allocations (3 runs) | retired instructions (3 runs) | median |
| --- | --- | --- | --- |
| baseline | 13519507, 13519506, 13519506 | 41253092423, 41217887648, 41216191624 | 41217887648 |
| candidate | 13519571, 13519570, 13519570 | 41232070642, 41211100013, 41207869100 | 41211100013 |

Allocations: +64 (+0.0005%). Retired instructions: -0.02% at the median. The
emitted C of the two compilers for this input is byte-identical (`cmp`).

Lines against `c00e1e421`: production `.brp` +846 -105 (of which the two new
modules, `cli.brp` and `source_walk.brp`, are +650; the kind change itself,
in `syntax`, `load`, `builtins`, `render` and `verify`, is +40 -17); test
`.brp` +1582 -325; test shell +9 -6.
