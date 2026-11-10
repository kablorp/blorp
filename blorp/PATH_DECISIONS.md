# `Path` decisions

**Status: proposed, awaiting Keith's decisions.** Drafted 2026-11-10, written against origin/main `73b4787ca` and for
the `io/` layout of MODULES_AND_STRINGABLE_PLAN.md decision 6 (`io/fs`,
`io/error`, `io/environment`, `io/process`). Decision 8 of that plan fixes the
frame: a String-backed opaque `Path` that carries the filesystem operations as
methods, `Path` and `IOError` in the prelude, and no `File` handle. These
decisions settle the details. Once approved they amend `FILESYSTEM_DECISIONS.md`:
R4 ("Paths stay `String`"), D8, D13, and R3 a second time. Its line
citations point at the layout before the `io/` move: `standard_library/fs.brp`
is now `io/fs.brp`, `io.brp` is `io/console.brp` and `io/error.brp`, and
`_io_errors.brp` is `io/_codes.brp`.

## Problem

A path is a `String`, so nothing tells a path apart from the text it names,
and every caller rebuilds path logic by hand.

- **Swapped arguments type-check.** `write_text(path: String, text: String)`
  (`standard_library/fs.brp:207`), `rename(source, destination)` (`:305`) and
  `with_temporary_directory(parent, prefix, …)` (`:329`) all accept their
  Strings in either order.
- **Paths are concatenated by hand.** There are 97 `+ "/" +` or `"${dir}/…"`
  sites in `test/`, 61 of them in `test/e2e/self_hosted_cli.brp`. For example,
  `write_text(directory + "/" + name + "_runtime.c", fragment)` appears at
  `test/runtime/system_suite.brp:47` and `test/runtime/fs_suite.brp:61`.
- **Path logic is duplicated.**
  - The separator byte 47 is declared three times: `path.brp:9`,
    `src/cli.brp:63` and `src/syntax/source.brp:98`.
  - The last component is parsed twice: `file_name` (`src/cli.brp:163`) and
    `module_stem` (`src/syntax/source.brp:106`).
  - "Under this directory" is written three ways:
    - `is_at_or_below` (`src/source_walk.brp:42`);
    - `prefix = Path.join(root, "")`, then `starts_with`
      (`src/compile/load/load.brp:138`, `:174`);
    - `path.starts_with(directory + "/")`
      (`test/unit/test_format/test_dependencies.brp:38`).
- **Invariants live in comments:** "every key is NUL-free, normalized and
  unique" (`load.brp:85`), "Already normal" (`load.brp:288`), "`roots` and
  `excluded` are normalized" (`src/cli.brp:33`).
- **The module name is everyone's local name.** `load.brp:9` imports
  `path as Path` because `path` is the natural name for a binding.

## Precedent

- **Rust.**
  - `OsStr` is exact but makes `to_str()` an `Option` everywhere.
  - `AsRef<Path>` lets every operation take `&str`, which is convenient but
    gives back the argument-swap hole above.
  - `join` with an absolute child replaces the base, a known traversal
    footgun.
  - Equality compares components, so `a//b == a/b`.
  - Blorp's value semantics need no `Path`/`PathBuf` split.
- **Python `pathlib`.**
  - `/` reads well, but works only because `__truediv__` accepts a `str`.
  - `os.PathLike` means `str` paths never went away.
  - `surrogateescape` makes non-UTF-8 paths round-trip at the cost of
    strings that are not text.
- **Go.** No path type: `filepath.Join` also cleans its result, which
  surprises callers who meant `x/`.
- **Swift `FilePath`.** Accepts a string literal (`ExpressibleByStringLiteral`)
  and normalizes separators on construction (unverified for current versions).
- **Zig.** Byte slices, plus directory handles for `openat`-style relative
  operations. Handles are ruled out here, since Blorp has no open or close.

## Decisions for Keith

**P1. Construction.**
- (a) A prelude function `path("a/b")`.
- (b) A String method `"a/b".to_path()`, as `to_string` and B1's `to_bytes`.
- (c) A String literal typed by its expected type (`config: Path = "a.toml"`),
  as Swift does. This is a new checker rule.

*Recommended: (b).* (a) is unusable. A local or parameter may not reuse a
visible function's name, so a prelude `path` would reject every binding named
`path` in every program. Probed: a local `join` beside `path: join` gives
"`join` is already a function in this module". `to_path` has no such cost.
Program arguments and environment values arrive as Strings and convert the
same way. (c) can come later as its own language decision, and would make P4's
`/` possible.

```blorp
-- before
text ?= read_text(args.get_or(1, "settings.conf"))
-- after
text ?= args.get_or(1, "settings.conf").to_path().read_text()
```

**P2. Validation.**
- (a) Construction is total, and NUL stays `PathContainsNul` at the call (R4).
- (b) `to_path` returns `Option[Path]` and rejects NUL and the empty path.

*Recommended: (a).* Every operation already returns a `Result` for reasons no
constructor can check (`NotFound`, `PermissionDenied`). A fallible constructor
would add an `Option` to every literal and argument without removing one
failure path, which goes against principle 10. Rust, Python and Go all report
NUL at the system call. The loader's own check before normalizing stays
(`load.brp:677`).

**P3. Normalization.**
- (a) Never at construction; `normalize()` stays an explicit, lexical method.
- (b) Full lexical normalization at construction.
- (c) Collapse separators and drop a trailing `/` at construction (Swift).

*Recommended: (a).* The spelling carries meaning. D18 gives a trailing `/` its
behaviour in `write_text`, D20 and D21 define a final `/`, `.` and `..`, and D14
requires an error to show the path the caller passed. Lexical `..` resolution
is also wrong through symlinks (`a/link/..`).

**P4. Joining.**
- (a) `join(base: Path, child: String) -> Path`.
- (b) `/` through `Divisible`.
- (c) Both.

*Recommended: (a).* `Divisible` is `Self / Self -> Self`, so `dir / "x"` does
not type-check, and `dir / "x".to_path()` is worse than `join`. Implementing
`Divisible` would also let `[T: Divisible]` arithmetic accept paths. Revisit
`/` only if P1(c) lands. An absolute child replaces the base, as today and as
in Rust and Python, and this is documented.

```blorp
-- before
executable = directory + "/" + name + "_test"
-- after
executable = directory.join("${name}_test")
```

**P5. Traits.** *Recommended:*
- `Stringable`: `to_string` returns the spelling, so `"${config}"` works.
- `Equatable` and `Hashable`: byte equality of the spelling, so `a//b != a/b`.
  Compare `normalize()`d paths when lexical sameness is meant, as
  `src/cli.brp:255` does. Opaque types get no automatic equality, so these
  are written by hand.
- No `Orderable`, because `String` has none. It follows `String` when that is
  decided.

Rust's component equality was the alternative. It makes `Hashable` hash
components, and makes equality disagree with the stored text.

**P6. String operands.**
- (a) Operations take only `Path`.
- (b) Generic over a trait, as in `read_text[P: ToPath](path: P)` (Rust's
  `AsRef`).
- (c) Keep String functions beside the Path methods, under other names.

*Recommended: (a).* (b) brings the swapped-argument hole back, and
specialization makes two copies of each operation. (c) gives every fact two
APIs, and rule 14 says to delete the old form.

**P7. `IOError`.** *Recommended:*
- `path: Path` and `destination: Option[Path]`; D14 and D34 are unchanged.
- `IOError`'s `to_string` text stays byte for byte the same.
- `io/error` imports `path`. `path` is pure and imports nothing from `io`, so
  there is no cycle.

**P8. Other path-shaped values.** *Recommended:*
- `get_current_directory` returns `Result[Path, String]`; its String error is
  a separate question.
- `Entry.name` stays a String, because it is one component, not a path.
  Callers write `directory.join(entry.name)`.
- In the process API, `Command.directory` becomes `Option[Path]` and
  `find_program` returns `Path`. `Command.program`, and `ProcessError.program`
  (which holds a name for `find_program` and a path otherwise), are decided in
  process L2.
- `main(args: List[String])` is unchanged.

**P9. Non-UTF-8 paths.** *Recommended:* still refused until `Bytes`. D8 is
reworded to "until `Path` is byte-backed". Because `Path` is opaque, as `Bytes`
is, a later byte-backed representation changes no signature. Only `to_string`
would then become lossy, as Rust's `display()` is, and an exact
`to_text() -> Option[String]` would come with it.

**P10. `path.brp`.** *Recommended:* `path.brp` becomes `Path`'s module
(decision 2) and its String functions are deleted.

| Today | `Path` method |
| --- | --- |
| `join` | `join(Path, String) -> Path` |
| `dirname` | `parent(Path) -> Path`, total: `"a"` is `.` and `/` is `/` |
| `normalize` | `normalize(Path) -> Path` |
| `cli.file_name` | `name(Path) -> Option[String]`, which is `None` for `/` and `..` |
| `source.module_stem` | `stem(Path)` and `extension(Path) -> Option[String]`, with `module_stem`'s dot rules |
| `prefix + ".c"` | `with_extension(Path, String) -> Path` |
| three containment checks | `is_within(Path, Path) -> Bool`, lexical and by component |

Methods selected as `Path methods` do not block local names: a local `dirname`
beside `path: String methods` compiles (probed).

**P11. Migration.** All counts are from a grep and are approximate.

- **The compiler:** 29 call sites in `src/cli.brp`, `src/main.brp`,
  `src/source_walk.brp` and `src/compile/load/load.brp`, plus the two private
  parsers above.
- **The scripts:** 4 sites in `scripts/embed_library.brp`.
- **The tests:** about 184 operation calls and 34 `join` calls in about 40
  files, plus the 97 concatenations.

The compiler must migrate in the same landing, because it imports `fs`. No
native changes, so no seed rotation is needed: `fs` unwraps `Path` before each
native. Seed-built code writes `path.to_string()` until landing 6's rotation
allows `"${path}"`.

*Recommended:* migrate only at the filesystem boundary. `SourceFile.path`,
`SourceOverrides` and `LibraryContents` stay String. They are display
identities (`"<standard library>"` is not a path) and need their own
normalized-path type, as a separate data-model refactor with its own ceilings.

**P12. Prelude cost.** These figures come from a scratch `-O0` diagnostic
compiler built from the main checkout's `blorp/build/blorp.c` at about
`ce8753b6f`. They give compile allocations and retired instructions for an
empty `main`.

| Import set | Allocations | Instructions |
| --- | --- | --- |
| Nothing (89,222 allocations, 333.6 M instructions) | — | — |
| `io` | +5,027 | +4.4% |
| Today's `path.brp` | +13,222 | +10.7% |
| A minimal `Path` module (type, `to_path`, `to_string`, equality, hash, `join`) | +3,624 | +3.5% |
| `fs` (with `io`, `_io_errors`, `option`, `result`, `bool`) | +38,806 | +39% |
| `fs` and `path` | +52,011 | +50% |

Cost follows the source that is checked, because every loaded module is
checked in full; a module's fixed cost is about 370 allocations.

- (a) The prelude takes `path: Path, to_path`, `io/error: IOError` and
  `io/fs: Path methods`, as decision 8 says. A small compile costs about
  +50%. Every small-program e2e ceiling rises, which is a coordinator
  correction. Self-compile is about unchanged, because the compiler already
  loads these modules.
- (b) The prelude takes only `Path` and `IOError` (about +9,000), and fs
  methods stay an `io/fs` import. This narrows decision 8's "file I/O needs
  no import".
- (c) (a), followed by a loader change that checks a prelude module only when
  a program names one of its declarations.

*Recommended: (c).* Decision 8 stands as worded, and the cost is recorded so
compiler work can remove it. Keep `path.brp` small regardless; put heavy pure
operations behind it only if they are measured. Constructors (`NotFound`,
`File`) stay explicit imports, so the prelude claims no common constructor
names.

```blorp
-- before
import:
    io/fs: read_text
func main() -> Int:
    match read_text("settings.conf"):
        Ok(text): text.length()
        Err(error): 1
-- after: no import
func main() -> Int:
    match "settings.conf".to_path().read_text():
        Ok(text): text.length()
        Err(error): 1
```

## Landings

1. **`Path` in `path.brp`, alongside the String functions.**
   - Contents: P5, P10 and unit tests. No compiler change.
   - Ceilings: production lines at most +130. Self-compile allocations and
     instructions each at most +0.3%, because the compiler loads `path.brp`.
2. **Signatures move to `Path`.**
   - Contents: `io/fs`, `io/error`, `io/environment` and `io/process`
     (P6 to P8). The String functions in `path.brp`, `cli.file_name` and
     `module_stem` are deleted. Every caller, both READMEs and
     `FILESYSTEM_DECISIONS.md` are updated.
   - Ceilings: production lines at most +40 net. Self-compile allocations and
     instructions each at most +0.3%. Test growth is reported separately.
3. **The prelude (P12).**
   - Ceilings: the empty-program compile costs at most +55,000 allocations
     and +55% instructions, and self-compile at most +0.1%. E2e ceilings are
     reset with their existing margins and recorded.
4. **Optional:** the loader change of P12(c), under its own plan.

## Out of scope

- Globbing.
- Symlink operations (reading or creating links, canonicalization).
- Windows, drive letters and `\`.
- Byte-backed paths (P9).
- A normalized-path type inside the compiler (P11).
- `Orderable`.
- Literal paths (P1(c)) and `/`.
- `copy_file`, permissions and timestamps.

## Not verified

- Swift's construction-time normalization.
- That `args.get(1).map(to_path)` works with a prelude-selected `to_path`.
  `options.paths.map(normalize)` (`src/cli.brp:381`) is the precedent.
- The landing line estimates.
- The cost figures on an `-O2` production build.
