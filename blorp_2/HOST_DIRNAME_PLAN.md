# Host dirname preserves the approved lexical parent contract

## Verified status — 2026-10-16

Implementation and validation were subsequently authorized. The approved body
and owning module docs are applied; plan-only commit is
`0d357dd1691a8ee2ccc5c4ecc61e570fcf3aa7ad`. The original design/recipe below
records the plan stage; its permission and timing statements are historical.

| Evidence | Verified outcome |
| --- | --- |
| Own-FRESH baseline | 41 passed / 7 failed; all 40 existing callbacks passed |
| Candidate / missing-first-trim mutant / restored | 48/0 → 42/6 → 48/0; named trailing-run failure |
| Final own-host build | FRESH before and after gates; CLI-O0/runtime-O2 |
| Final broader gates | 91 std modules; 4,840 runtime tests; 1,067 doctests; zero failures |
| Publication checks | Hygiene, artifact scan, diff whitespace and local links passed |

Physical changes: production/module docs +41/-16, net +25; tests +70/-0;
fixtures zero. No performance claim. Complete commands, source/test/binary
hashes, exact failure names and raw logs are retained under ignored
`build/host-dirname/{baseline,narrow-loop,final-validation}/`.
`final-validation/SHA256SUMS` pins its complete retained artifacts except itself.
Compiled lane is released; implementation is ready for final doc review. Root owns
current-main integration; no main publication or implementation commit is claimed.

## Problem and authority

Base `0424983629beeae222337216cbea8d89276a38e8`; branch `codex/host-dirname`.
This is the supporting host library, not the target compiler or temporary library.
[M6's Parent contract](ROADMAP.md#m6-library-and-shell) already specifies the
behavior. At plan stage, only the plan and baseline regression tests were
authorized; production and compiled calls required separate grants and review.

In the base at `standard_library/src/path.brp:69–86`, dirname strips one trailing
slash and returns the prefix before the last remaining slash. Plan-stage inspection
predicted
`dirname("/a///") == "/a/"` and `dirname("a//b//") == "a//b"`; expected values
are "/" and "a". Those values were source predictions; executed baseline
callback outcomes are recorded above.

## Planned solution and literal code

Keep the existing pure String API. Move one counted byte boundary backwards:
ignore every trailing '/', skip the final component, then skip its preceding
separator run. Return root or "." at boundary zero, otherwise extract once.
String length/get use byte indices (`standard_library/src/string.brp:237,459`).
ASCII '/' cannot occur inside a UTF-8 multibyte encoding, so each final extraction
boundary preserves the complete prefix. NUL is an ordinary byte here; native
operations retain their separate NUL rejection. No Unicode decoder is needed.

Before, verbatim in the base at `standard_library/src/path.brp:69`:

```blorp
pure func dirname(path: String) -> String:
	p: String = if path.length() > 1:
		if path.ends_with("/"):
			path.take_left(path.length() - 1)
		else:
			path
	else:
		path

	idx: Int = last_index_of_char(p, '/')

	if idx < 0:
		"."
	else if idx == 0:
		"/"
	else:
		p.take_left(idx)
```

Planned replacement, subsequently applied unchanged:

```blorp
pure func dirname(path: String) -> String:
	var end: Int = path.length()

	while end > 0:
		match path.get(end - 1):
			Some('/'):
				end -= 1
			_:
				break

	while end > 0:
		match path.get(end - 1):
			Some('/'):
				break
			_:
				end -= 1

	while end > 0:
		match path.get(end - 1):
			Some('/'):
				end -= 1
			_:
				break

	if end == 0:
		if path.starts_with("/"):
			"/"
		else:
			"."
	else:
		path.take_left(end)
```

The three loops traverse disjoint suffix regions; they allocate no growing
String or substring per step. There is at most one final `take_left`. No speedup
claim or compiler data-model change is involved. Keep `last_index_of_char` for
its existing basename/extension callers.

The planned owning-module doc update at baseline `path.brp:53–68` was to state
that all trailing separators and the preceding separator run are
removed, root and valid UTF-8/NUL are preserved, and interior `..`/separators are
not normalized. Retain existing examples; add `/a///`, `a//b//` and `a/..`.

## Independent edge oracle and tests

Expected outputs below follow the lexical contract directly, not another path
implementation or a transformation of the candidate's output. Each table group
has a named callback in the existing `blorp/test/test_runtime/test_sys/test_path.brp`
TestSuite; existing dirname and other path callbacks remain unchanged.

| Group | Input → expected |
| --- | --- |
| Trailing runs | `/a///` → `/`; `a//b//` → `a` |
| Preceding runs | `a///b` → `a`; `/a///b` → `/a` |
| Roots | `/`, `//`, `///`, `////` → `/` |
| Empty/basename | empty → `.`; `name` → `.`; `name///` → `.` |
| Interior runs | `a//b/c` → `a//b`; `///a//b///` → `///a` |
| Lexical parents | `a/..` → `a`; `a/../b` → `a/..`; `../x` → `..` |
| UTF-8 | `é/树/leaf///` → `é/树`; `🙂//é` → `🙂`; `é///` → `.` |
| Counted NUL | `a\0b/c` → `a\0b`; `a\0b//c//` → `a\0b`; `\0/leaf` → `\0` |

NUL notation is the Blorp `\0` escape, not a file name passed to an OS call.
The pre-existing `/foo/bar/` example also retains single-trailing-slash coverage.
Before implementation, require the added trailing-run callback to fail with the
unchanged library; record actual failing names/counts rather than claiming an
unrun baseline. The lexical-parent callback is a control against normalization.

After the fix, temporarily omit only the first trailing-run loop. The trailing-run
callback must fail (for example `/a///` would retain `a`); restore the exact
candidate bytes and rerun green. This is an ordinary TestSuite mutation, with no
alternate entrypoint, generated-C edit, scanner or non-Blorp assertion program.

## Scope, budget and validation

Allowed files: this plan, dirname implementation/doc only in
`standard_library/src/path.brp`, and the existing path TestSuite. Do not change
basename/join/normalize, other helpers, target compiler/temp library, frozen host
epochs, roadmap, public names, Path types, caches, controllers or fixtures.
Hard physical limits: production 60 added/+35 net including module docs; tests
100 added/+95 net; fixtures zero. Report an inadequate budget rather than
compressing code or deleting coverage. Initial plan/test preparation changed zero
production lines and added eight callbacks; implemented counts are recorded above.

Original serial baseline recipe, subsequently executed in the new worktree:

```bash
cd /Users/keithphilpott/.codex/worktrees/host-dirname/blorp
make
scripts/compiler-build-status  # require FRESH before direct tests
bin/blorp test --suite --timeout 180 \
  --std-dir /Users/keithphilpott/.codex/worktrees/host-dirname/blorp/standard_library/src \
  blorp/test/test_runtime/test_sys/test_path.brp
```

No separately installed release, copied binary or frozen measurement host was
substituted. Root expressly approved borrowing the FRESH main host for the narrow
green/mutant/restored loop, keeping its SHA unchanged and selecting the own
candidate/mutant std with the same explicit `--std-dir`. This pure library body
uses unchanged native primitives; the main host/std were untouched. That bounded
exception did not claim own-host freshness. The final own-host rebuild then
reported FRESH before and after serial broader gates. All commands, hashes,
statuses and failure text are retained under ignored `build/host-dirname/`.
No compiled calls ran during the initial plan/test preparation.

Final current-base integration is root-owned and serialized. Run the focused
suite and `scripts/test --serial std-check runtime doctest` with the intended
FRESH candidate; apply compiler/test review before commit. No pre-approval
production edit or broad gate is implied by this plan. A host/compiler defect,
unexpected baseline, scope growth or budget breach stops for root's decision.

## Acceptance and handback

- [x] Baseline witnesses the new trailing-run regression through the normal suite.
- [x] Candidate passes all existing and eight added path callbacks and module docs.
- [x] Missing-trailing-run mutation fails its named callback; restored bytes pass.
- [x] Focused and broader gates pass with intended std selection and final own-host
  FRESH build; no frozen experiment is altered.
- [x] Return branch/worktree, distinct full-file/patch hashes, physical counts,
  baseline/green/mutation receipts and limitations.
- [x] Root and independent final patch/evidence reviews approved with zero findings.
- [ ] Final status-doc review and root's current-main integration.

Plan/test review, production grant and final patch/evidence review are complete.
Status-doc review precedes an implementation commit; root owns integration and
publication.
