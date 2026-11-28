# Making Blorp ready for games

Status: revision 7, 2026-11-27.
- **Revisions 1 to 6:** two rounds of soundness and ergonomics review, then
  focused soundness reviews of each FFI change.
- **Revision 7** reframes the plan, at Keith's word:
  - It makes Blorp ready for games in general. It builds no particular game,
    and favours no type of game.
  - The prototype that found these needs is evidence, not a goal.
  - Its code is reference, not a deliverable.

Keith decides the items marked **G**. The rest are recommendations.

## Goal

Blorp should be a good language for writing games of any kind: real-time or
turn-based, in a terminal or a window, simple or simulation-heavy. This plan
lists the capabilities that takes, as general language, library and tooling
work. Each one is useful outside games too.

**What "ready for games" means here:**
1. **Numbers and math:** Float functions, conversions, bit operations, and
   32-bit numbers.
2. **Randomness:** a pure, seeded, reproducible generator, and a way to get
   a seed.
3. **Time:** durations, a monotonic clock, and sleeping to a deadline.
4. **The terminal:** raw input with a timeout, the window size, and a
   full-screen mode that restores the terminal on every exit the runtime
   controls.
5. **A window:** open one, present a frame, read keyboard and mouse events.
6. **Drawing in Blorp:** frames, shapes, text and images, as libraries.
7. **Parallel work** that pays off at the sizes games use.
8. **C libraries,** called safely, through an FFI.
9. **Everyday ergonomics:** library conveniences, and the language and
   tooling friction that slows writing such programs.

**The principle** (Keith, 2026-11-27): as much as possible in Blorp. The OS
appears only behind small C adapters.

**Not in scope yet:**
- audio;
- networking;
- GPU rendering;
- asset pipelines;
- engines;
- gamepads and touch input;
- any particular game.

Saving and loading is already covered by `io/files`. Images are decoded and
encoded in W9; asset pipelines are not.

Int32, Float32 and the FFI prepare the ground for audio and the GPU.

## Evidence

A prototype found these needs. It was a real-time 2D simulation played in a
terminal, written against an unmerged branch. It exercised capabilities 1 to
4 and 7, and logged every rough edge it met. This plan uses its findings,
not its code.

**What it measured,** on an Apple M4 with 4 performance and 6 efficiency
cores, at `-O2`:

| What | Figure |
| --- | --- |
| 1,024 bodies, 20 steps of direct gravity, 1 thread | 0.0192 s, 1.09× C with libm |
| The same on 4 threads | 0.0072 s |
| A per-frame update of about 250 bodies, 16 `parallel_map`s a frame | 0.13 ms on 1 thread, 0.29 ms on 4, 2.8 ms at the default 10; 8.1 s of system CPU in a 1.7 s run |
| One `parallel_map` of 4,096 elements of about 8 square roots each | 31 µs on 1 thread, 14.9 µs on 2, 27.7 µs on 4, 329 µs on 10 |
| `map` of the same | 61 µs, twice `parallel_map` on one thread |
| Its tests | 0.6 s on 1 thread, 14 s at the default thread count |
| One frame at 160×48 terminal cells | update 4.6 ms, drawing 0.43 ms, output 0.09 ms and 6.8 KB; 29.7 fps |
| Determinism | the same state hash at 1, 2, 4 and 10 threads |
| Compiling it | `blorp compile` 0.23 s; clang `-O2` 0.80 s for 984 KB of C |

**What worked, and should stay:**
- fixed records and unions held inline;
- determinism with no effort;
- `concurrent:` reading naturally;
- updates in place through a private-variant wrapper;
- help lines that were mostly right.

**Where the evidence lives:** only on Keith's machine, in ignored files:
- the friction log,
  `.claude/worktrees/gravity/scratch/gravity/game/FRICTION.md`;
- its review notes, `.claude/worktrees/gravity/scratch/gravity/REVIEW.md`;
- the measurements, in `build/gravity-evidence/`.

This plan quotes what an implementer needs.

**Reference code:**
- Branch `gravity/prototype` (13 commits on `94b463fda`, unpushed) has a
  reviewed implementation of most of W0: math, bits, random, a clock, and
  terminal input.
- A W0 landing may borrow from it, but nothing here depends on it.
- Main has moved since: union destructuring is gone, and a new seed is
  pinned.

## Decisions so far

**Keith, 2026-11-27:**
- **Randomness:** pure functions, given one seed from IO.
- **Graphics:** as much as possible in Blorp. A terminal view came first, as
  a proof of concept.
- **Math:** the math functions are wanted.
- **A window needs an FFI,** and the FFI goes in this plan.
- **Order:** this work comes first, in other sessions.
- **Int32 and Float32** land before the FFI (G13).
- **The FFI:** minimal and safe (G3 to G11).
- **Revision 7:** the plan is game-agnostic.

**Earlier decisions this plan must respect:**
- **2026-10-02, reconfirmed 2026-10-15** ("let's enforce it"): no
  shadowing. G15 asks whether to relax it.
- **2026-10-15:** "`?=` should not be valid in `if` expressions, `match`
  expressions, loops, or while conditions." This plan does not reopen it.
- **2026-11-02:** the legacy second standard library is gone, and only
  `blorp/standard_library` is maintained.
- **The compiler's source keeps to the bootstrap subset,** which has no FFI
  (`blorp/AGENTS.md`, "Scope").

## The workstreams

Each names its owning document, where one already exists.

| # | Workstream | Capability | Size | Depends on | Owner decisions |
| --- | --- | --- | --- | --- | --- |
| W0 | Core libraries: math, bits, randomness, time, terminal input | 1 to 4 | medium, several landings | none | G1, G2 |
| W1 | Spike W: a window in plain C | 5 | small | none | none |
| W2 | The FFI, in its own plan | 8 | large | W1, W5; W0's `bits` and W6's `float_from_bits` for its decoding toolkit; F3 after `RUN_AND_TEST_PLAN.md`'s CLI landing | G3 to G11 |
| W3 | The window library | 5 | medium | W1, W2 | none |
| W4 | The pool on small maps, and `map`'s cost | 7 | medium | `CONCURRENCY_PLAN.md`; W0's clock for an in-process probe | none |
| W5 | Int32 and Float32, in their own plan, before W2 | 1 | medium, with a seed rotation | `UINT8_BYTES_PLAN.md`'s pattern | G12, G13 |
| W6 | Library gaps | 9 | small, several landings | W0, for rows that extend its modules | G14 |
| W7 | Language friction | 9 | one landing per item | the items | G15 to G21 |
| W8 | Tooling friction | 9 | small | none | G22 |
| W9 | Drawing in Blorp | 6 | medium | W0; W3 for windows | none |

**The order of the large pieces:**
1. W0;
2. W5 and W1, beside each other;
3. W2;
4. W3;
5. W9, whose terminal half can start after W0.

Int32 and Float32 come before the FFI, so that the FFI's first version
carries them (Keith, 2026-11-27).

**What can run beside what:**
- W7, W8, and W6's rows that need nothing from W0, beside everything.
- W4 once W0's clock has landed, or earlier if its probe times whole runs
  from outside.
- W5 and W1 beside each other.

## Handing this plan to an implementer

The decisions are settled (see "Decisions"). Do not reopen them. Do not add
a mechanism the plan does not name: root `AGENTS.md` requires Keith's
approval for that.

Every landing still gets a brief within `docs/HANDOFF_SPEC.md`, with its
tests, exact messages and cost ceilings. A coordinator writes the brief from
this plan. Landings then fall into two groups.

**Ready to brief and implement now.** Each has a settled design, and its
work is mostly mechanical:
- **W0,** one landing per area, against the requirements below.
- **W6:**
  - `zip`, `enumerate`, `fold` and `sum`;
  - `Int.abs`, `UInt8.to_float`, `to_bits` and `float_from_bits`;
  - `print_inline` and `print_error_inline`.

  Each goes in a module chosen under W0's placement rule, since the seed
  reads `int`, `uint8`, `float` and the console modules.
- **G12, as it applies to UInt8:** `wrapped_to_uint8` and
  `clamped_to_uint8`.
- **The help lines:** G15 (a) and G17.
- **G16** (a) and (b).
- **G21,** `?=` on an Option.
- **W8:** `blorp check`, and the test-outcome migration.

**Needing a design or measurement step first:**
- **W1,** which is a spike.
- **W2,** the FFI. Its own plan settles the syntax's spelling with parser
  input.
- **W3,** after W2.
- **W4,** which is an investigation, in the concurrency plan.
- **W5,** in its own plan.
- **W9:** its module and type names need ergonomics input.
- **G18, G19 and G20,** each a small design with parser or ergonomics input.
- **G22:** measure the corpus diff first.
- **W0's `with_alternate_screen`,** whose restore on a signal needs a
  design: leaving and re-entering the alternate screen and the cursor on
  SIGTSTP and SIGCONT, not only raw mode.
- **W6's infallible system-call form for `fault`.**

## W0: core libraries

Capabilities 1 to 4, each a small landing with its own tests. This section
states what each must provide, not how. The requirements include what
review of a prototype implementation found.

**Placement.** The pinned seed reads every module the compiler imports,
including `float`, `int`, `bytes` and the prelude, and it rejects a builtin
label it does not know. So:
- new natives go in modules the compiler does not import;
- or they wait for a seed rotation.

**Math (`math`).**
- **Functions:** `PI`, `sqrt`, `floor`, `ceil`, `round` (half away from
  zero), `trunc`, `sin`, `cos`, `tan`, `atan2`, `exp`, `log` and `pow`.
- **`to_int(Float) -> Int`:** truncates, saturates at Int's limits, and
  gives 0 for NaN.
- **`to_float(Int) -> Float`.**
- **Docs:** they state which functions are exact on every platform (`sqrt`,
  the rounding functions, the conversions), and which come from libm and may
  differ in the last bit (G14).

**G1. The math functions' home.**
- **They cannot go in `float.brp`,** which the prelude imports and so the
  seed reads.
- **Moving them there after a rotation is not free:** modules do not
  re-export, so every call site's import would change.
- **Recommended:** a `math` module. After the next rotation, the prelude
  selects `math: Float methods` (README, "`module: Shape methods`"), so
  `x.sqrt()` needs no import.

**Bits (`bits`).** `bit_and`, `bit_or`, `bit_xor`, `bit_not`, `shift_left`
and `shift_right`. Shifts are logical, a count outside 0 to 63 gives 0, and
nothing reaches C's undefined behaviour. A sign-preserving shift waits for a
need.

**Randomness (`random` and `io/random`).**
- **The generator:** `Random`, a union with a private variant, so only its
  module builds or reads one. Every draw returns the value and the next
  generator:
  - `seeded(Int)`;
  - `next_int`;
  - `next_below(bound)`, unbiased, by rejection. A bound of 0 or less gives
    0 and the generator unchanged, so the function is total;
  - `next_float`, in [0, 1) from 53 random bits;
  - `split`, giving two separate streams for separate work, such as
    parallel tasks.
- **The algorithm:** a small, fast, published non-cryptographic generator,
  written in Blorp, so that a seed gives the same stream on every platform.
  - Tests check a published test vector.
  - `split` must give streams that do not overlap in practice. SplitMix64
    with a gamma derived per split, as Java's `SplittableRandom` does, meets
    that. A fixed gamma does not, since its streams are offsets on one
    cycle, and the prototype's implementation used one.
- **IO:** `random_seed() -> Int` from the OS, plus the conveniences
  `random_generator()`, `random_below(bound)` and `random_float()`. They are
  named like the pure forms, with `random_` for "uses the OS". After the
  seed, everything is pure.
- **Reading a draw:**

  ```blorp
  var generator = seeded(42)

  for turn in 0..3:
      (roll, advanced) = generator.next_below(6)
      generator = advanced
      print("rolled ${roll + 1}")
  ```

**Time (`time`, and a clock).**
- `Duration`: never negative, with saturating arithmetic, and the
  constructors `nanoseconds`, `milliseconds` and `seconds`.
- A monotonic clock reading, `elapsed() -> Duration`, counted from program
  start, as the concurrency plan's `elapsed()` is, so that replacing it
  later keeps behaviour.
- A `sleep`, and a `sleep_until(deadline: Duration)`, whose deadline is a
  `Duration` on that clock. A frame loop writes `deadline = deadline +
  frame`, then sleeps until it.

**G2. Where the clock lives.**
- **The concurrency plan defines `sleep` and `elapsed` in `concurrency`.**
  - There, `sleep` parks the fiber.
  - `elapsed()` is "the time since the runtime started", virtual under
    `simulate`.
- **A blocking `sleep` would stall a carrier** once fibers run, and real
  time inside `simulate` would break determinism.
- **Options:**
  - (a) Land `io/clock` now as the pre-fiber form, documented as such.
    Concurrency landing 5 replaces it with `concurrency.sleep` and
    `concurrency.elapsed`, and deletes `io/clock`.
  - (b) Wait for landing 5.
- **Recommended: (a).** Real-time programs need a clock before landing 5.
  Record the move in the concurrency plan.

**Terminal input (`io/terminal`).**
- **The interface:**
  - `with_raw_mode[T, E](body, on_error)`, the scoped primitive, after
    `with_reader`;
  - `with_alternate_screen[T, E](body, on_error)`: raw mode, the alternate
    screen and a hidden cursor, all restored together;
  - the manual `enter_raw_mode` and `leave_raw_mode`, which the scopes are
    built on, are private;
  - `read_input(timeout)`, whose result is a union of four cases:
    - input;
    - nothing yet;
    - resumed: the program was stopped and continued, so the screen must be
      redrawn;
    - end of input.
  - `terminal_size() -> Option[TerminalSize]`, a record of `columns` and
    `rows`.
- **What review of the prototype's implementation found:**
  - **Restoring.** Raw mode is restored at exit, and on SIGINT, SIGQUIT,
    SIGTERM, SIGHUP and SIGABRT:
    - in async-signal-safe handlers;
    - installed only over a default disposition;
    - with an interrupted restore retried.
  - **Re-raising.** After restoring, a handler re-raises the signal, so the
    program still ends as that signal would end it, which the exit statuses
    of `RUN_AND_TEST_PLAN.md` R5 rely on.
  - **`exit_interrupted`** restores raw mode before it re-raises.
  - **Arming the handlers.** They are installed on every entry, not once.
    While a `process.run` holds its counted signal swap, the handler goes
    into the swap's saved dispositions, so the run cannot lose it.
  - **Ctrl-Z and Ctrl-S:**
    - SIGTSTP restores the terminal before stopping: raw mode, and in
      `with_alternate_screen` also the main screen and the cursor.
    - SIGCONT re-enters them all, and the next `read_input` reports
      "resumed". Re-entering the alternate screen clears it on common
      terminals, so whatever was drawn is gone;
    - IXON is turned off, so Ctrl-S does not pause output.
  - **Documenting the limits:**
    - the timeout's cap;
    - that leaving raw mode discards typed-ahead input;
    - that a `process.run` inside raw mode would hand its child the raw
      terminal, so the scope is left first.
  - **Tests:** every one of those paths has a pty test, and each test fails
    when its fix is reverted.

**Every W0 landing:**
- runs the full gate;
- dispatches Seed CI, since this adds natives;
- is reviewed;
- measures runtime-fragment changes with stage-2 compilers, since
  `self-compile-cost` runs the seed's runtime.

**Landed:**
- **Landing 1, `math`:** `db6f29133`, 2026-11-28.
  - **The change:** the Float functions, `PI`, a saturating `to_int` and
    `to_float`, as `FloatUnary`, `FloatBinary`, `FloatToInt` and
    `IntToFloat`. It was ported unchanged from the prototype branch's
    `33209039a`.
  - **Cost:** self-compile against `1b0ee4565`, fixed input, allocations
    +0.0000% and instructions -0.02%. The fixed-input C differs only by the
    10 lines of the two conversions in `FLOAT_RUNTIME`.
  - **Lines:** production +185 net, library +95, tests about +390.
  - **The `math/functions` fixture:** measured on main at 75,031 allocations
    and 507 M instructions, with ceilings of 75,040 and 583 M (+15%).
  - **Gates:**
    - the full gate passes;
    - Seed CI run 46124309012 is green on all targets;
    - code review: 0 blockers.
  - **Oracle:** removing `to_int`'s saturation passes `test_math` on arm64,
    whose conversion saturates in hardware. The `math/functions` fixture
    catches it on any clang host, under the e2e harness's UBSan: "inf is
    outside the range of representable values". On x86-64, `test_math`
    catches it too.
  - **Follow-up:** fold `FloatCopySign` into `FloatBinary`, which is
    reported, not done.
  - **Evidence:** `build/games/w0-math/` in the main checkout.

## W1: Spike W, a window in plain C

**Question:** what does the platform layer cost and need, before the FFI
plan is designed around it?

**The spike:** one C file with its own `main`, outside `blorp/`.
1. Open an AppKit window through the Objective-C runtime (`objc_msgSend`,
   with no Objective-C source).
2. Present an RGBA buffer each frame.
3. Poll keyboard and mouse events.
4. Close cleanly.

**Measurements:**
- the cost of a present at 640×360 and at 1280×720, both scaled to the
  window;
- frame pacing at 60 fps;
- which calls must run on the process's main thread;
- whether any call blocks;
- the exact link flags.

**Output:**
- the minimal set of calls and their C signatures, which is the window
  library's foreign surface;
- what C must hand back to Blorp: events, sizes and errors.

## W2: the FFI

W2 gets its own plan, reviewed for soundness and ergonomics, before F1. This
section sets that plan's direction and decisions. Its syntax takes parser and
ergonomics input before implementation (root `AGENTS.md`).

### The design

**Keith, 2026-11-27: minimize complexity and maximize safety.** Revision 5
cut every mechanism that existed only to make copies optional or results
cheaper. The FFI is eight rules:
1. **Declarations.**
   - A module declares its foreign functions with `private foreign func`,
     each naming its C symbol.
   - One module stanza holds the C sources and link flags, keyed by
     platform (G3, G8).
2. **Every foreign function is impure** (G5).
   - None runs on a pool thread. While impure code runs on one carrier
     thread, as it will until the concurrency plan's M:N landing (landing
     7), foreign calls are serialized, so C need not be thread-safe.
   - Purity cannot be faked.
   - CTFE never reaches one, since constant initializers are pure
     (`CTFE_PLAN.md` L3).
3. **One type set, the same in both directions** (G6):
   - Int, Float, Int32, Float32, Bool and UInt8;
   - Lists of Int, Float, Int32, Float32 and UInt8.

   W5 lands Int32 and Float32 first.
4. **Every List is copied, in both directions, always** (G4).
   - C never sees Blorp's memory, and Blorp never keeps C's.
   - There is no opt-out.
5. **One way to bind.**
   - Every foreign function is defined in a C source the module declares.
   - Anything else (a C library, C++ through `extern "C"`, Rust) is linked,
     and called from those adapters.
6. **Handles** are an `Int` that only the declaring module sees, wrapped in
   a `resource union` and lent through a `with_` function (G7).
7. **Everything else crosses as bytes:** String, Bytes, unions and records.
   It is encoded and decoded in Blorp with a small toolkit, whose decoders
   cover only the supported types.
8. **A short contract** for the C side, listed below.

**What revision 5 removed,** and why each removal is also safer:

| Removed | Why |
| --- | --- |
| `@no_copy`, `const` prototypes, and diagnostics hashing of arguments | Without an opt-out, nothing C does to its copy can reach a Blorp value |
| The ownership pass's per-argument moved-or-borrowed fact, the run-time uniqueness test, and their verifier rules | No behaviour depends on whether a copy happens |
| Result view structs, their header, and the rules on thread-local or long-lived result memory | C returns a buffer it got from `malloc`, and Blorp frees it. There is no shared result memory left to race on. A mistake, such as returning static memory, is undefined behaviour that `blorp test`'s sanitizer build reports |
| `unchecked pure` | Rule 2 |
| A separate C++ landing, and a check file for prebuilt libraries | Rule 5. The adapter's own compile checks its calls against the library's header |
| Diagnostics checks of the FP environment and signal state | They stay in the contract, and come back only if a real module needs them |

**The cost:**
- **One copy of each List,** each way.
- **A 640×360 frame** is about 0.9 MB, roughly 0.05 to 0.1 ms to copy, by
  estimate. A 1280×720 one is about 0.3 ms. Both are small against a 16 ms
  frame.
- **Skipping a copy later is not a language change.** It is safe exactly
  where no Blorp code could see C's writes: a unique List passed as its last
  use. That is an optimization the compiler may add later, with no syntax
  and nothing for a user to get wrong. It waits for a measured need.

**The legacy FFI** (`docs/GUIDE.md` section 15, in `e1cae3971^`) had:
- `foreign(include:, link:)` blocks;
- a copy by default, with `@no_copy`;
- `pure`;
- an opaque `Ptr`;
- automatic String and `char *` conversion;
- unions passed as raw tags.

This design keeps the restricted link flags and the default copy. It drops
the rest:
- `Ptr`, which is manual memory management against principle 12;
- the automatic String conversion, which is cut short at a NUL and never
  checks UTF-8 on the way back;
- raw union tags, which make an out-of-range value undefined behaviour,
  against principle 1;
- `pure` and `@no_copy`.

### Types and copies

| Blorp | C argument | C result |
| --- | --- | --- |
| `Int` | `int64_t` | `int64_t` |
| `Float` | `double` | `double` |
| `Bool` | `uint8_t`, 0 or 1 | `uint8_t`; nonzero is `True`, a total conversion. `binary`'s `bool_at` is strict instead, since a byte layout is a format to check |
| `UInt8` | `uint8_t` | `uint8_t` |
| `List[Int]` | `int64_t *data, int64_t length`: a fresh copy | returns the length, and sets an `int64_t **data` out-parameter, the function's last parameter |
| `List[Float]` | `double *data, int64_t length` | the same, with `double **data` |
| `List[UInt8]` | `uint8_t *data, int64_t length` | the same, with `uint8_t **data` |
| `Int32` | `int32_t` | `int32_t` |
| `Float32` | `float` | `float` |
| `List[Int32]` | `int32_t *data, int64_t length` | the same, with `int32_t **data` |
| `List[Float32]` | `float *data, int64_t length` | the same, with `float **data` |
| `Void` | — | `void` |

**A List argument** is a fresh copy, which C may use as scratch during the
call. Blorp frees it when the call returns, so C must not keep a pointer to
it. With a length of 0, the pointer is unspecified, and C must not read it.

**A List result:**
- **Blorp sets `*data` to NULL before the call.**
- **C** allocates the elements with the C library's `malloc`, sets `*data`,
  and returns the count. With a count of 0 it may leave `*data` NULL.
  - A buffer from another allocator, such as a Rust `Vec` or C++ `new[]`, is
    copied into `malloc` memory by the adapter first.
- **Blorp** copies the elements into a fresh List with `memcpy`, then calls
  `free` on `*data`, then frees the argument copies. C keeps no pointer to
  the result.
- **Checks before the copy,** each aborting with a message naming the
  function:
  - a negative count;
  - a NULL with a count, which includes C never setting `*data`;
  - a result that points into one of the call's argument copies, such as a
    scratch copy sorted and handed back. Without this check, normal and
    diagnostics builds would fail in different ways, with a double free or
    an interior `free`. The check is a few pointer comparisons.
- **A count whose size in bytes would overflow** aborts in the List
  allocation's existing size guard.
- **What only a sanitizer build sees,** in `blorp test`:
  - memory that did not come from `malloc`, such as static or stack memory,
    whose `free` is undefined behaviour and may corrupt rather than crash;
  - a `malloc` buffer that C keeps and returns again on a later call, which
    is used after Blorp freed it.

**Float is sound.** NaN payloads cannot be observed today, and a signalling
NaN goes quiet with no trap, as long as C leaves the FP environment alone
(the contract).

**Bytes and String are not in the set.**
- `check` knows Bool, Option, Result, the numbers and List as facts
  (`namespace/builtins.brp`). `Bytes` and String are library types, and
  admitting them by name would be the spelling heuristic principle 4 rules
  out.
- So the module converts:
  - `Bytes` crosses as its `List[UInt8]`, through `from_list` and `to_list`,
    which do not copy (`bytes.brp`);
  - a String goes out as `text.to_bytes().to_list()`, and comes back through
    `from_list(...).to_text()`, which checks the UTF-8.

### Binding through adapters

- **The adapters.** Each foreign function is defined in a C source the module
  declares. The CLI compiles it:
  - with Blorp's generated prototypes forced in (`-include`);
  - with `-Werror=incompatible-pointer-types`.

  A definition whose signature differs from Blorp's declaration is then a
  "conflicting types" error, as probed with Apple clang 21 on 2026-11-27.
  Without the forced header it would compile and link silently, because a
  source file is its own translation unit.
- **Showing a C author the expected signature.** A List result's C form
  differs from its Blorp form: it adds an out-parameter, and returns a
  count. So:
  - the CLI writes the prototypes header beside the sources;
  - a "conflicting types" error is followed by a note naming Blorp's
    declaration and the expected C prototype.
- **The symbol check.** Before linking, the CLI checks that each declared
  symbol is defined by the declared sources' objects. So no foreign function
  can bind a library symbol unchecked.
- **Other libraries** are linked through the stanza's flags, and called from
  an adapter through their own header, so the C compiler checks those calls
  as ordinary C:
  - **A C library:** include its header.
  - **C++:** a library with an `extern "C"` header. Link it with the C++
    library (`-lc++` on macOS, `-lstdc++` with GNU). Its functions must not
    let an exception escape: they are `noexcept`, and catch everything.
  - **Rust:**
    - a `staticlib` crate built with cargo, whose `#[no_mangle] pub extern
      "C"` functions get a header from cbindgen;
    - its native dependencies, from `cargo rustc -- --print
      native-static-libs`, go in the link flags;
    - its profile must not set `panic = "abort"`, and each function catches
      panics with `std::panic::catch_unwind`, returning an error code;
    - the Blorp CLI does not run cargo.
- **Cost of the rule:** a library function needs a one-line adapter. In
  return there is one checking mechanism, the C compiler's, and no
  Blorp-specific header format.

### Declarations, platforms and threads

**G3. The declaration form.**
- **Principles 13 and 16 say "`foreign func` is one declaration".** Keep
  that, with one module stanza for sources and flags.
- **The FFI plan settles the spelling,** with parser and ergonomics input.
  The stanza is its own small grammar, not a call with named arguments.
  Platform names are a closed set, and the parser's error lists them.
- **`= "symbol"` is required,** so the Blorp name never depends on the C
  name.
- **Foreign declarations are `private`.** A public one is rejected, with
  help that shows the wrapper pattern. By convention they are named
  `native_…`, as `io/files/read.brp`'s natives are today.

A sketch for the FFI plan's reviewers, not a settled spelling:

```blorp
foreign:
    source macos "window_macos.c"
    source linux "window_x11.c"
    link macos "-framework AppKit" "-framework CoreGraphics"
    link linux "-lX11"

private foreign func native_open(
    width: Int,
    height: Int,
    title: List[UInt8]
) -> Int = "blorp_window_open"
private foreign func native_present(
    window: Int,
    pixels: List[UInt8],
    width: Int,
    height: Int
) -> Int = "blorp_window_present"
private foreign func native_poll(window: Int) -> List[UInt8] = "blorp_window_poll"
private foreign func native_close(window: Int) -> Int = "blorp_window_close"
```

**G8. Platforms.**
- **Sources and flags are keyed by platform.**
- **A platform with no entry** is reported by `blorp run` before it calls
  the C compiler, naming the module and the platform.
- **It is reported only for a module whose foreign functions the program can
  reach.** Otherwise `RUN_AND_TEST_PLAN.md` R5 would map the C compiler's
  failure to exit 4, "a fault in blorp".

**G9. Who may declare foreign functions.**
- **User modules and the standard library may.** The compiler's own source
  may not: the bootstrap subset has no FFI (`blorp/AGENTS.md`).
- **The embedder** (`scripts/embed_library.brp`) embeds a library module's
  declared C sources beside its `.brp` files.
- **`load`** publishes them in the source inventory, and the CLI writes them
  out to compile them.
- **Not in scope:** turning the compiler's built-in natives into foreign
  declarations.

**G10. Where a foreign call runs.**
- **Inline, on the calling carrier,** never on a helper or pool thread.
- **The carrier that runs `main` is the process's main thread,** which
  AppKit needs. Fibers stay on their first thread (`CONCURRENCY_PLAN.md`,
  landing 4b results).
- **Promptness:** a foreign call is expected to return promptly, since a
  blocking one stalls every fiber on its carrier. The FFI plan decides
  whether a `blocking` mark is needed, once Spike W says whether the window
  layer blocks.
- **More than one carrier.** The concurrency plan's landing 7 (M:N) would let
  fibers on different carriers call the same C function at once, and call it
  off the main thread, which AppKit forbids. Landing 7 must then do one of:
  - keep every foreign call on `main`'s carrier;
  - bring a `main_thread` mark, with foreign functions declared thread-safe
    or not.

  Record that in `CONCURRENCY_PLAN.md`.
- **Record this in `CONCURRENCY_PLAN.md`** before landing 4c.

**G11. Linking through the CLI.**
- **`RUN_AND_TEST_PLAN.md` puts foreign link flags out of scope** (R5), so
  F3 adds CLI scope:
  - `blorp run` and `blorp test` compile the declared sources and pass the
    declared flags;
  - `blorp compile` writes the C, the prototypes header and the sources, and
    prints the arguments a user needs.
- **Sources and flags are published once,** for the CLI and the test driver
  both.

### Encoding and decoding

**The toolkit, in a new `binary` module.**
- **Why not `bytes.brp`:** the compiler imports `bytes`
  (`src/lsp/lsp_command.brp`), so the seed reads `bytes.brp`, and it would
  reject the `bits` and `float_from_bits` labels the toolkit needs. That is
  G1's `float.brp` problem again.
- **What it has:** decoders and encoders for the supported types only, plus
  one function for runs of fixed-size records.
There is nothing for String, records or unions: modules build those from
these pieces.

```blorp
-- What can go wrong reading a value out of bytes.
union DecodeError:
    TooShort(Int, Int)          -- the offset read, and the length there is
    NotABool(Int, UInt8)        -- the offset, and its byte, neither 0 nor 1
    UnevenLength(Int, Int)      -- the length, and the record size it is not a multiple of
    UnknownTag(Int)             -- a tag the module's decoder does not know


-- Each reads one value at a byte offset, little-endian: an Int or a Float
-- as 8 bytes, an Int32 or a Float32 as 4, a UInt8 or a Bool as one.
pure func int_at(data: Bytes, offset: Int) -> Result[Int, DecodeError]
pure func float_at(data: Bytes, offset: Int) -> Result[Float, DecodeError]
pure func int32_at(data: Bytes, offset: Int) -> Result[Int32, DecodeError]
pure func float32_at(data: Bytes, offset: Int) -> Result[Float32, DecodeError]
pure func uint8_at(data: Bytes, offset: Int) -> Result[UInt8, DecodeError]
pure func bool_at(data: Bytes, offset: Int) -> Result[Bool, DecodeError]

-- Each appends one value in the same layout.
pure func append_int(data: Bytes, value: Int) -> Bytes
pure func append_float(data: Bytes, value: Float) -> Bytes
pure func append_int32(data: Bytes, value: Int32) -> Bytes
pure func append_float32(data: Bytes, value: Float32) -> Bytes
pure func append_uint8(data: Bytes, value: UInt8) -> Bytes
pure func append_bool(data: Bytes, value: Bool) -> Bytes

-- Splits data into records of `size` bytes and decodes each, stopping at
-- the first error. `?=` cannot run inside a loop, so a module needs this to
-- decode a list of records.
pure func decode_records[T](
    data: Bytes,
    size: Int,
    decode: pure (Bytes) -> Result[T, DecodeError]
) -> Result[List[T], DecodeError]
```

**Its rules:**
- **Total.** A decoder returns a `Result`, so `?=` composes it. A bad value
  from C is an error result, never a fault.
- **On Blorp's copy,** which C can no longer change.
- **The layout is C's native one.** C writes each field with `memcpy` of an
  `int64_t`, a `double` or a `uint8_t`, at an explicit offset, never by
  casting a struct, so padding never matters.
  - That native layout is little-endian on every supported target, x86-64
    and arm64. A big-endian target would be its own decision.
  - `bool_at` is strict: only 0 and 1 are Bools. A direct `Bool` result
    from C is total, as the table says, because a bytes layout is a format
    to check, and a C `uint8_t` is not.
- **Needs W0's `bits` and W6's `float_from_bits`.** The toolkit lands with
  F2.

**The C side of a List result,** in `window_macos.c`. The forced prototypes
make its signature match `native_poll(window: Int) -> List[UInt8]`:

```c
#include <stdlib.h>
#include <string.h>

/* Each event is 32 bytes: kind and key code as int64_t, then x and y as
 * double. memcpy at explicit offsets, so no struct padding is involved. */
enum { EVENT_SIZE = 32 };

static void put_event(uint8_t *at, int64_t kind, int64_t code, double x, double y) {
    memcpy(at, &kind, 8);
    memcpy(at + 8, &code, 8);
    memcpy(at + 16, &x, 8);
    memcpy(at + 24, &y, 8);
}

int64_t blorp_window_poll(int64_t window, uint8_t **data) {
    struct pending events = drained_events(window); /* the platform code */
    if (events.count == 0) {
        *data = NULL;
        return 0;
    }
    uint8_t *out = malloc((size_t)events.count * EVENT_SIZE);
    if (out == NULL) abort();
    for (int64_t index = 0; index < events.count; index++) {
        put_event(out + index * EVENT_SIZE, events.kind[index], events.code[index],
                  events.x[index], events.y[index]);
    }
    *data = out; /* Blorp copies it, then frees it */
    return events.count * EVENT_SIZE; /* a count of elements: bytes, for a List[UInt8] */
}
```

**The Blorp side,** in `window.brp`:

```blorp
import:
    binary: DecodeError(UnknownTag), int_at, float_at, decode_records
    bytes: Bytes, from_list

-- Must match window_macos.c's layout.
EVENT_SIZE: Int = 32
KIND_AT: Int = 0
CODE_AT: Int = 8
X_AT: Int = 16
Y_AT: Int = 24


private pure func decoded_event(record: Bytes) -> Result[WindowEvent, DecodeError]:
    kind ?= record.int_at(KIND_AT)
    code ?= record.int_at(CODE_AT)
    x ?= record.float_at(X_AT)
    y ?= record.float_at(Y_AT)

    match kind:
        1: Ok(CloseRequested)
        -- key_of is total: a code it does not know is Key.Other(code)
        2: Ok(KeyDown(key_of(code)))
        3: Ok(KeyUp(key_of(code)))
        4: Ok(MouseMoved(x, y))
        _: Err(UnknownTag(kind))


-- A named function, because a variant constructor is not a function value
-- (W7 lists it as friction).
private pure func malformed_events(error: DecodeError) -> WindowError:
    MalformedEvents(error)


func poll_events(window: Window) -> Result[List[WindowEvent], WindowError]:
    match window:
        Underlying(handle):
            from_list(native_poll(handle))
                .decode_records(EVENT_SIZE, decoded_event)
                .map_err(malformed_events)
```

**The other directions:**

```blorp
-- A typed List needs no decoding: every value C can return is valid.
private foreign func native_histogram(
    data: List[Float],
    buckets: Int
) -> List[Float] = "blorp_stats_histogram"

-- Text comes back as bytes, and String's own constructor checks the UTF-8.
private foreign func native_clipboard(window: Int) -> List[UInt8] = "blorp_window_clipboard"

func clipboard_text(window: Window) -> Option[String]:
    match window:
        Underlying(handle): from_list(native_clipboard(handle)).to_text()


-- A record going out is encoded with the same layout rules.
private pure func encoded_rectangle(data: Bytes, area: Rectangle) -> Bytes:
    data
        .append_float(area.x)
        .append_float(area.y)
        .append_float(area.width)
        .append_float(area.height)
```

**Not planned:**
- records or unions crossing directly;
- generated decoders;
- `pure` foreign functions;
- `@no_copy`.

Each would bring back the machinery revision 5 removed. Revisit one only with
a measured need.

### The contract for C

A foreign function, and anything it calls:
- **Keeps no pointer to an argument,** frees none, and writes or reads none
  past its length.
- **Returns a List result in fresh memory from the C library's `malloc`.**
  - It keeps no pointer to it, and never returns the same buffer twice.
  - It never returns an argument copy, or a pointer into one.
- **Leaves the process as it found it:**
  - the FP environment's control state: rounding, traps, flush-to-zero;
  - the signal mask and handlers;
  - file descriptors it was not given.

  It never calls `exit` or `fork`.
- **Lets nothing unwind or jump across the boundary:** no exception, no
  panic, and no `longjmp`.
- **Returns promptly** (G10).

### Risks the FFI leaves

These are the risks of any FFI, and none can be removed by design.
- **Memory errors inside C,** such as writing past a length or using memory
  after it is freed.
  - **Limited by:**
    - `blorp test` builds the declared adapters with AddressSanitizer and
      UndefinedBehaviorSanitizer on macOS and Linux, and with LeakSanitizer
      where the platform has it;
    - the copies, which keep every such error away from Blorp's values.
  - **What it misses:** linked libraries are not instrumented.
- **Crashes, hangs and blocking.** One bad function can stop the process,
  since nothing isolates it.
- **Process-wide state, leaks inside C, and escaping control flow:** the
  contract.
- **Trust in a linked library and its header:** the user's choice, limited by
  the restricted link flags.

**What contains them:**
- Only modules with a `foreign` stanza can do any of this.
- Their declarations are private.
- `foreign` is greppable.

### Phases

| Phase | Work |
| --- | --- |
| `lex`, `parse` | The stanza and `foreign func`. `foreign` is reserved already. Teaching messages: `extern "C"`; a nested `foreign func` ("foreign declarations go at the top of a module"; today it reports "expected a return expression"); `Ptr` or `void*`, naming the Int handle and `resource union` pattern; `pure foreign func`, which says foreign functions are impure and their results are decoded by pure functions. |
| `load` | Resolve sources beside the declaring module. Publish them in the source inventory. |
| `check` | The one type set (G6). A `String`, `Bytes`, union or record parameter or result gets help naming its encoding: "pass `text.to_bytes().to_list()`", or "return `List[UInt8]` and decode it". `private` and `= "symbol"` are required. |
| `lower` | A foreign call target, beside `RuntimeFunction` in `own.brp`'s call targets. |
| `own`, `verify` | Arguments are borrowed, as runtime calls' are. The result is owned. No new fact: the copies are emit's. |
| `emit` | The prototypes header. The copy of each List argument. `*data` set to NULL. The call. The checks on a List result, its copy, and `free`. Then freeing the argument copies. |
| CLI | G11. |

### Tests and costs

**Tests:**
- **Unit tests at each phase boundary,** as `blorp/AGENTS.md` requires.
- **An e2e fixture with a small C adapter,** covering:
  - every type, in both directions;
  - a C function that writes into its argument copy, with the caller's
    value unchanged;
  - a List result, copied and freed, with leak checks clean;
  - a negative count, a NULL with a count, a result pointing into an
    argument copy, and a `*data` never set with a count, each aborting with
    the function's name;
  - a `*data` never set with a count of 0, which is an empty List;
  - a definition whose signature differs, rejected by the forced
    prototypes;
  - a symbol not defined in a declared source, rejected before linking;
  - a handle lent through `with_`;
  - a String parameter or result, and a `pure foreign func`, each rejected
    with exact message, help and span;
  - an adapter calling a small C library through its header.
- **Decoder tests** against malformed input: too short, an uneven length,
  a bad Bool, an unknown tag.

**Costs:**
- **A program without foreign calls pays nothing.** The self-compile
  fixed-input row keeps the same allocations, and instructions within
  +0.05%.
- **Each copy** costs one allocation and one `memcpy`, counted by the
  fixture's ceilings.

### Landings

- **F1:** the stanza, `foreign func`, the checks and the teaching messages,
  with no emission.
- **F2:**
  - lowering, emission, the prototypes header and the copies;
  - the bytes toolkit;
  - the e2e fixture, built through the one publication.
- **F3:** the CLI (G11), after `RUN_AND_TEST_PLAN.md`'s CLI landing brings
  `blorp run` and `blorp test`. Neither exists yet.
- **README and grammar updates** in each landing, per root `AGENTS.md` rule
  13.

**Not planned:** exporting Blorp functions to Rust or C++ programs. It needs
exported functions, a way to start Blorp's runtime from a host's `main`, and
usually callbacks, so it is its own later decision.

## W3: the window library

**Its foreign surface** comes from Spike W: open, present, poll, close and
size. macOS first.

**In Blorp:**
- `with_window[T, E](title, width, height, body, on_error)`, following
  `with_reader` and `with_atomic_writer`: a `scoped (Window) ->
  Result[T, E]` body and an `on_error` mapper from `WindowError`;
- a `Window` resource;
- a `WindowEvent` union, decoded from `native_poll`'s bytes as W2's
  example shows;
- a `Key` union, whose `key_of` is total, with `Other(Int)` for a code it
  does not know;
- `present(window, pixels: List[UInt8], width, height) ->
  Result[Void, WindowError]`, as `native_present` takes it, with the pixels
  copied like any List. W9 adds a frame-level wrapper, so W3 does not
  depend on W9.
- **Design questions for W3's landing,** not settled by the example below:
  - whether `with_window` also gets a one-type form, so that a program whose
    errors are all `WindowError` needs no identity mapper;
  - whether a lost window should arrive as an event, so that `present` can
    return `Void` and the loop loses its error plumbing.

**How `with_window` works.** The same way `with_reader` works in
`io/files/read.brp`:
1. The library opens the window through a private foreign function.
2. It wraps the handle in the resource.
3. It lends the resource to the caller's body.
4. It closes the window whatever the body returned.

Blorp has no `return` or exceptions, and the body cannot run this
function's `?=`, so nothing can leave between the open and the close. The
caller never sees the `Int`.

```blorp
-- In window.brp. Only this module builds or reads a Window.
resource union Window:
    private Underlying(Int)


private foreign func native_open(
    width: Int,
    height: Int,
    title: List[UInt8]
) -> Int = "blorp_window_open"
private foreign func native_close(window: Int) -> Int = "blorp_window_close"


-- A negative Int is an error code; decoding it is ordinary Blorp.
private pure func opened(code: Int) -> Result[Int, WindowError]:
    if code < 0:
        Err(decode_window_error(code))
    else:
        Ok(code)


func with_window[T, E](
    title: String,
    width: Int,
    height: Int,
    body: scoped (Window) -> Result[T, E],
    on_error: pure (WindowError) -> E
) -> Result[T, E]:
    handle ?= native_open(width, height, title.to_bytes().to_list())
        .opened()
        .map_err(on_error)

    outcome = body(Window.Underlying(handle))
    -- Bound because only a Void call can stand alone as a statement.
    closed = native_close(handle)
    outcome
```

Each public function, such as W2's `poll_events`, reads the handle with
`match`, since union destructuring is gone from main.

A program's side: any real-time loop, here with the program's own `State`,
`handled`, `advanced` and `drawn`. `unchanged` is a one-line identity
mapper, `pure func unchanged(error: WindowError) -> WindowError: error`:

```blorp
import:
    io/console/output: print_error
    window: Window, WindowError, WindowEvent(CloseRequested), with_window, present, poll_events

-- `?=` may not appear inside a loop (Keith, 2026-10-15), so a failure
-- ends the loop and becomes the result.
func run(window: Window) -> Result[Void, WindowError]:
    var state = initial_state()
    var running: Bool = True
    var outcome: Result[Void, WindowError] = Ok(void)

    while running:
        match window.poll_events():
            Ok(events):
                for event in events:
                    match event:
                        CloseRequested: running = False
                        _: state = state.handled(event)
            Err(error):
                outcome = Err(error)
                running = False

        state = state.advanced()

        match window.present(state.drawn(), WIDTH, HEIGHT):
            Ok(_): void
            Err(error):
                outcome = Err(error)
                running = False

    outcome


func main() -> Int:
    match with_window("example", 1280, 720, run, unchanged):
        Ok(_): 0
        Err(error):
            print_error(error.to_string())
            1
```

**After macOS: an X11 backend for Linux.**
- **CI runs on GitHub's runners** (the `blorp.yml` and `blorp-seed.yml`
  matrices), not in the local Docker images. So X11 and Xvfb need packages
  on the Linux runners, and in the local images used to reproduce CI.
- **The macOS-15 runner** may not be able to open a window. Spike W checks.
- **The C layer** gets tests that stub the OS calls, as the terminal's do.

Drawing what is presented is W9's.

## W4: the pool on small maps, and `map`'s cost

**Owning document:** `CONCURRENCY_PLAN.md`. These findings go there as
evidence. Its Spike P results already note two things:
- "Waking idle workers. A tiny map pays this on every call; it was not
  isolated."
- The serial `map` "retires 2.25× the instructions of a loop into a List
  sized up front".

**The prototype shows both costs in a real program:**
- **The pool on small maps.**
  - A `parallel_map` of 4,096 elements is ten times slower on the default
    ten threads than on one, with 13.7 s of system CPU in a 3.1 s run.
  - No list size in its per-frame update gains from more than two threads.
  - Even 2,000 light elements take 1.0 ms on 1 thread and 5.1 ms on 10.
- **`map` itself:** it is half the speed of `parallel_map` on one thread.

**Recommended:**
1. **Measure where the system time goes:** idle workers spinning, waking,
   or sleeping in the kernel. Use a probe that times one `parallel_map`
   against `map` per list size and thread count. The prototype's version is
   `.claude/worktrees/gravity/build/gravity/measure/parallel_map_cost.brp`,
   for reference only.
2. **Split on demand, not by a fixed minimum.**
   - Spike P found that a nested map needs pieces of one element, so a fixed
     minimum piece size is wrong.
   - Rayon's `with_min_len` is a setting per call, which Blorp would rather
     not expose.
   - Instead: split only when another worker is idle to steal the piece,
     and otherwise run in place.
   - Measure it on a small-map, per-frame workload like the prototype's,
     and on Spike P's nested map.
3. **Choose a default thread count that suits mixed cores,** such as the
   performance cores from `hw.perflevel0.physicalcpu` on macOS, until the
   pool handles mixed cores well.
4. **Build `map`'s result at its known size,** as `parallel_map` does.

## W5: Int32 and Float32

W5 gets its own plan, following `UINT8_BYTES_PLAN.md`, which established:
- literals typed by context;
- no implicit conversion;
- the arithmetic and comparison traits;
- a declaration in `_base`, with a seed rotation.

**Cost precedent:** UInt8 L1 cost +0.100% instructions on the binding
fixed-input row. Its production lines, +850 net, overran their ceiling of
+700, which Keith raised to about +870.

**What they give:**
- **The GPU and audio:** a `List[Float32]` is a C `float` array, so vertex
  and sample buffers cross with no conversion.
- **C APIs** that take `int32_t` and `float` need only one-line adapters,
  with no conversion loops.
- **Large arrays** take half the memory bandwidth, and fit twice the SIMD
  lanes (principle 13).

**G12. One conversion family for every fixed-width number.** UInt8 got a gap
by naming only the conversion that was needed first.

| Form | Example | Meaning |
| --- | --- | --- |
| Checked | `to_int32()` | an `Option` |
| Wrapping | `wrapped_to_int32()` | modulo 2^32 |
| Saturating | `clamped_to_int32()` | to the nearest end |
| Widening | `to_int()`, `to_float()` | total |
| Narrowing a Float | `to_float32()` | total, rounding to nearest; an overflow gives infinity |

- **UInt8 gets the same family:** add `wrapped_to_uint8` and
  `clamped_to_uint8`.
- **On a Float, every conversion to an integer width is total.**
  `x.to_int32()` and `x.to_uint8()` truncate and saturate, with NaN giving
  0, as `to_int` does. That fits principle 1.
- **The checked and wrapping forms exist only on integer receivers,** where
  a value can be out of range without being a rounding question.
- **Recommended.**

**G13. Literals and order.**
- **Literals:**
  - `x: Float32 = 0.1` is accepted, and rounds.
  - A literal that would overflow to infinity is rejected, as `300` is for
    UInt8.
  - An unconstrained literal takes its type from context, as UInt8's do, so
    `a32 * 0.5` is Float32.
- **The math functions** compute in Float and round back, until a need is
  measured.
- **`UInt32`** waits. Four `UInt8`s in a List cover pixels.
- **Order: before the FFI** (Keith, 2026-11-27).
  - The FFI's first version then carries `Int32`, `Float32` and their
    Lists, both ways.
  - The binary toolkit reads and writes them.
  - W2 waits for W5's seed rotation, since W5 declares the types in
    `_base`.

## W6: library gaps

Each is a small landing, in Blorp unless noted. A row that extends a W0
module waits for W0.

| Gap | Evidence | Proposal |
| --- | --- | --- |
| `zip`, `enumerate`, `fold`, `sum` | the prototype counts indexes by hand 5 times and sums by hand 7 times | `zip` stops at the shorter list, as in Rust and Python. `fold(values, initial, step)` puts the initial value first, like `fold_lines`. `sum` takes `List[Int]` or `List[Float]`, and after W5 `List[Int32]` and `List[Float32]`. It adds left to right, so a Float sum is deterministic, and an integer sum wraps. Measure the List of pairs that `zip` and `enumerate` build; if `for (index, value) in values.enumerate():` is hot, give that loop a form that builds nothing. |
| `Int.abs` | the prototype writes `difference.max(-difference)` | add it, wrapping at INT_MIN as negation does |
| `UInt8.to_float` | `channel.to_int().to_float()` | add it |
| Float bits | a state hash spells every Float as text, about 40 KB per hash | `to_bits(Float) -> Int` and `float_from_bits(Int) -> Float`, natives. A name of its own avoids a clash with a later `float32_from_bits`, since both take an Int. A negative Float gives a negative Int. NaN's sign differs between x86-64 and arm64 (`CTFE_PLAN.md`), so the bits are exact but not the same everywhere for NaN. |
| Text to stdout without a newline | a frame goes through `write(to_bytes(text))`, a copy | `print_inline(text)` and `print_error_inline(text)` in `io/console/output`, which pair with `print` and `print_error` and do not read like `io/files`' `write_text(path, text)` |
| An alternate-screen scope's restore | Ctrl-C leaves a full-screen program's alternate screen and hidden cursor behind, and the prototype needed a shell wrapper | W0 names `with_alternate_screen`. Its restore on a signal or an abort runs in the same handler that restores raw mode, which writes the escapes with `write(2)`, an async-signal-safe call. It is best-effort until a pty test proves each path. |
| `fault` | lives in `io/_launch` and prints "process runtime defect" | an infallible system-call form, so `elapsed`, `sleep` and `random_seed` lose the error arms they can never take |
| Portable transcendental functions | libm's `sin`, `cos`, `exp`, `log` and `pow` may differ in the last bit between macOS and glibc | G14 |

**Dropped from revision 1: `cycled(values, index)`.**
- It has no answer for an empty list. An `Option` saves nothing over
  `get_or`, and anything else breaks principle 1.
- Blorp's `%` follows the dividend's sign, so it would also need a
  Euclidean modulo.
- Range types (principle 14), or a non-empty list type, are the real
  answer. Until then, `get_or` with its default states the assumption
  honestly.

**G14. Cross-platform determinism.**
- (a) Keep libm, and document the caveat. This is today's choice.
- (b) Ship portable implementations in Blorp, so a replay matches on every
  platform.

**Recommended: (a) now.** A program that needs replays to match across
platforms can keep its simulation to exact operations meanwhile:
arithmetic, `sqrt` and the conversions.

## W7: language friction

Each item is its own design and landing. An item that adds syntax gets
parser and ergonomics input first, and documenter review after.

**G15. Shadowing.**
- **The evidence:** in the prototype, seven names a program wanted for a
  value collided with a function it also defined or imported. One was
  `length`.
- **What is already possible:** the `length` collision can be avoided
  today. Selecting `vector: Vector methods` gives UFCS access without
  importing the name `length` (README, "`module: Shape methods`").
- **Keith decided no shadowing on 2026-10-02, and reconfirmed it on
  2026-10-15.** The options:
  - (a) Keep the rule. Document the `methods` selection in the help for a
    collision with an import.
  - (b) A local or parameter may shadow a module function or an import
    within its scope. It is an error to call the shadowed function later in
    that scope, which is where the confusion arises.
  - (c) Shadowing of functions and imports is allowed outright.
- **In every option:**
  - constructors, constants and module aliases stay unshadowable, which G18
    needs;
  - a pattern capture never shadows a constructor;
  - UFCS never resolves a method call to a local, so after `length = 3`,
    `v.length()` still calls the function.
- **Recommended: (a) now,** with the better help. Revisit (b) with evidence
  from more programs.

**G16. Bare constructors and `==`.** Revision 1 bundled three changes. Split:
- (a) The prelude's `True`, `False`, `Some`, `None`, `Ok` and `Err` need no
  expected type.
  - They are unambiguous today, and this is the largest win: the prototype needed
    17 annotations, most of them here.
  - `x = None` still cannot infer its `T`. Its help says to annotate the
    binding.
- (b) `==` and `!=` check the untyped side against the typed side's type,
  whichever side that is. So `pending == [27]` and `[27] == pending` both
  work.
- (c) Revision 1's "any variant unique in scope" is dropped. An unrelated
  import could then turn working code into an error.
- **`fault[T]` in a match arm** needs its own inference rule. That is a
  separate item.
- **Recommended:** (a) and (b).

**G17. `and`, `or` and `not`.** Revision 1's "operators at boolean
precedence" was not decidable. Operators need:
- **Short-circuiting.** Today's functions "evaluate every argument"
  (README). Python, Rust and Go programmers read `and` as short-circuiting.
  - That cannot be an ordinary trait-member operator ("every operator calls
    a trait member").
  - It needs a special form in `check` and `lower`, as Rust's `&&` has.
  - Changing when an impure operand runs is a safety matter.
- **A precedence table.** Python's: `not` below comparisons and above
  `and`, and `and` above `or`. And whether `a and b or c` is accepted
  without parentheses.
- **Line breaks.** Whether a line may end or begin with `and`, since today a
  line break after an operator outside brackets ends the expression.
- **Keywords.**
  - The words become reserved. `bool.brp` declares functions of those
    names, and `.and(` appears throughout programs, the library and the
    compiler.
  - So either a method name after `.` may be a keyword, or the functions
    are renamed.
- **The compiler's source.** It calls the `bool` functions (`blorp/AGENTS.md`,
  "Scope"). Using the operators there needs a seed that knows them.

**Decided, Keith 2026-11-27: no operators.**
- The language stays smaller.
- Lazy evaluation is already available by nesting `if`.
- What operators would have cost:
  - every point above;
  - a seed rotation;
  - migrating about 2,545 call sites on main (474 in `src/`, 31 in the
    library, 2,040 in tests), or keeping two ways to write the same thing.
- **What lands:** a help line when `and`, `or` or `not` fails on a non-Bool
  receiver that is a comparison's right operand: "a method call binds
  tighter than `<=`; write `(gap <= tolerance).and(...)`".
- **The five-line `.not()` layout** is G22's to fix.

**G18. Constant patterns.**
- **Constants stay `UPPER_SNAKE_CASE`.** The naming rule does not change,
  and `[ESCAPE, ...rest]` reads as a user expects.
- **What changes is how the compiler tells a constant from a variant.**
  - It decides by what the name resolves to, not by its spelling.
  - The spelling cannot decide, because the README's naming rule lets
    consecutive capitals name a type or variant: "A single capital word such
    as `MAX` or `T` fits both the first two forms".
  - So `MAX` in a pattern could be a variant named `MAX` or a constant named
    `MAX`.
  - Root `AGENTS.md` principle 4 ("never in spellings") also rules out
    reading meaning from case.
- **Resolution decides:**
  - A pattern name that resolves to a module constant, or to
    `alias.CONSTANT`, is a constant pattern. Today that is an error, because
    constants cannot be shadowed.
  - `check` types the arm: the constant's type must be the scrutinee's,
    and `Equatable`. It is limited to the scalar and String types that
    literal patterns accept.
  - `lower` turns it into an equality test on a read of the constant.
  - It does not rely on the constant's value at `check`, which CTFE L3
    removes: computed constants are evaluated after `check`
    (`CTFE_PLAN.md`).
  - A constant arm never makes a match exhaustive, and no duplicate-arm
    check is made for it.
  - This depends on constants staying unshadowable (G15).
- **Byte literals are dropped.** ESC and most key codes are not printable,
  so `b'a'` does not solve the problem, and a Python reader takes it for a
  bytes string. Constant patterns do solve it: `ESCAPE: UInt8 = 27`, then
  `[ESCAPE, ...rest]`.
- **Recommended.**

**G19. UTF-8 in comments.**
- **Allow valid UTF-8 in comments.**
- **Still reject:** bidirectional controls, other format characters such as
  zero-width joiners, U+2028, U+2029, U+0085, and C1 controls.
- **Columns:** say what unit formatter width, error columns and LSP
  positions count. Code points match the formatter's width; today errors
  count bytes.
- **The grammar's `comment_byte` changes.**
- **Recommended.**

**G20. One-line `if`.**
- **Two forms:**
  - an expression, `x: UInt8 = if c: 1 else: f(c)`;
  - a statement, `if c: continue`. The statement is what Python and Rust
    programmers try first, and both fail today.
- **Rules:**
  - each branch is a single expression or a single simple statement;
  - no nested control forms;
  - `else if` is decided by the parser input;
  - the formatter breaks a long one back into a block.
- **Precedent:** `match` arms are already `Pattern: value` on one line.
- **Recommended,** with parser input.

**G21. `?=` on an Option.**
- **The change:** in a function returning `Option`, `?=` on an `Option`
  propagates `None`.
- **Help for a mismatch,** in both directions:
  - a Result function given an Option;
  - an Option function given a Result.
- **The help cannot suggest a conversion yet,** since there is no `ok_or`.
- **`?=` inside `if`, `match` and loops stays rejected,** as Keith decided
  on 2026-10-15.
- **Recommended.**

**Other items:**

| Friction | Proposal |
| --- | --- |
| Constants cannot be computed from constants (`HALF_STEP: Float = TIME_STEP * 0.5`) | already planned: `CTFE_PLAN.md` L3, computed constants |
| A tuple destructuring cannot be annotated | `(kind, events): (Kind, List[Event]) = …`, or less need once G16 lands |
| `from: Vector = …` reports "expected a return expression" | the typed binding's parse path reports the reserved word, as `from = 3` already does; consider unreserving `from` |
| Positional arguments only: a call that takes two Floats in a row lets a caller swap them silently | later; named arguments are a larger design |
| A variant constructor is not a function value: `result.map_err(Wrapped)` reports "variant does not belong to the expected type", which does not say why | allow a constructor as a function value, or at least say so in the help |

## W8: tooling friction

**G22. The formatter's chain rule.**
- **Today a chain of two or more method calls always breaks** (README,
  "always breaks").
- **Two results follow:**
  - `while xs.is_empty().not():` becomes five lines;
  - in arithmetic, each operand's chain breaks into one column, so
    `a.to_int().to_float() * share.max(0.0).min(1.0)` reads as if it clamped
    the product.
- **Options:**
  - (a) Break a chain only when it does not fit the width, or has three or
    more calls. This reformats much of the corpus, so measure the diff
    first.
  - (b) Keep the rule. When an operand's chain must break, break at the
    operators first, and indent the chain under its operand.
- **Exempting `.not()` would be a special case.** With no operators (G17),
  the chain rule is the fix.
- **Recommended: (a),** if the measured diff is acceptable. Otherwise (b).

**Test failures:**
- **Today a failing test prints only its name.** A callback is a pure
  `() -> Bool`, so it cannot print anything.
- **The fix changes the callback's result type,** to `Result[Void, String]`
  or to a named `TestOutcome` union (`Passed` or `Failed(String)`), with an
  `expect_equal(actual, expected)` that builds one.
- **Every suite migrates in the same change.** There is no parallel Bool
  path.

**`blorp check FILE`:** it type-checks a module that has no `main`, with
`blorp compile`'s exit codes. The language server's analysis does this
already.

## W9: drawing in Blorp

Capability 6. Everything here is Blorp, with no foreign code, and serves
any program that draws: a window through W3, or a terminal.

- **A frame:**
  - an RGBA image held as a `List[UInt8]`, with its width and height;
  - plotting, filling and blending:
    - fading darkens every pixel by a share, which leaves trails;
    - additive blending adds colours, saturating, which makes glows;
  - all updating in place when the frame is uniquely owned.
- **Shapes:** lines, rectangles, circles and discs, clipped silently at the
  frame's edges.
- **Text:** a bitmap font, and drawing a String in it. A first-time user
  needs no font files.
  - The font is constant data. Until CTFE L2, each read of an aggregate
    constant rebuilds it, so read it once per frame.
- **Images:** decoders and encoders for simple formats, such as BMP, which
  is uncompressed, and QOI, which is small and simple.
- **Terminal presentation:**
  - encode a frame as half-block cells, two pixels to a character, in
    24-bit colour;
  - send only the cells that differ, within a tolerance, from what the
    terminal shows. Comparing with the previous frame instead would let a
    slow fade that stays within the tolerance never appear;
  - resend every cell after a "resumed" input or a change of
    `terminal_size()`, which a program reads each frame. Either one leaves
    the screen no longer matching what the encoder believes it shows.

  The prototype measured this at about 0.4 ms and 7 KB a frame for 160×48
  cells.
- **Window presentation:** a wrapper that passes the frame's pixels, width
  and height to W3's `present`.

**Its first landing** needs ergonomics input first. It brings a 10-line
sketch of a reading such as `frame.fill(BLACK).disc(x, y, radius, color)`,
settling:
- the module and type names;
- the coordinate origin and direction;
- the colour type, a fixed record of four `UInt8`s or the raw bytes;
- whether a frame is a record or a union with a private variant.

On the last question: today, updating a field of a record rebuilds the
record, which takes every other field (`RECORDS_PLAN.md`). So a record-based
frame would copy its whole pixel List on each plot until `own`'s field moves
land. The prototype's in-place updates used a union read by destructuring,
which main has since removed.

**Measuring,** on current main, against a bare `List[UInt8]`:
- the per-frame cost of a fade and a few thousand plots at 640×360;
- encoding at 160×48 cells.

**References only:** the prototype's view module and its tests are one way
to do the terminal half, under the ignored
`.claude/worktrees/gravity/scratch/gravity/game/`.

## Process

**Briefs and plans:**
- **Briefs:** every landing gets a brief within `docs/HANDOFF_SPEC.md`.
- **Own plans:** W2 and W5 each get one, reviewed for soundness and
  ergonomics.
- **Syntax:** every W7 item that adds syntax takes parser and ergonomics
  input first, and documenter review after.

**Costs** follow root `AGENTS.md`:
- **Ceilings** are set before implementation, from a spike where one
  exists.
- **W2's self-compile row** is set above.
- **Runtime-fragment changes** are measured with stage-2 compilers.

**Tracking:** `NEXT.md` gets one entry pointing here. Each workstream records
its landings in this file, or in its own plan once it has one.

**Review:**
- **Revisions 1 to 3:** two rounds, as root `AGENTS.md` allows.
- **Revision 4's FFI changes:** one focused soundness review. It found 1
  blocker (a view shared between threads) and 5 should-fixes. All were
  taken, and checked by the coordinator.
- **Revision 5:** a quick soundness check of the minimal FFI found 0
  blockers and 5 should-fixes. All were taken, and checked by the
  coordinator.
- **Revision 7:** the game-agnostic reframing, signed off by a soundness
  reviewer and an ergonomics reviewer.

## Decisions

**Keith, 2026-11-27:**
- "Otherwise sounds good": the recommendations below are accepted.
- G17 is decided as no operators.
- G18 is clarified: constants keep `UPPER_SNAKE_CASE`.
- After revision 3: one type set both ways, copies, and everything else as
  bytes. Rust and C++ are to be covered.
- After revision 4: "minimize complexity and maximize safety". Revision 5's
  W2 follows:
  - G4: always copy, with C returning List results from `malloc`;
  - G5: no pure foreign functions;
  - Rust and C++ only through C adapters;
  - decoders only for the supported types.
- After revision 5: Int32 and Float32 move before the FFI (G13), so the
  FFI's first version carries them.
- After revision 6: the plan makes Blorp ready for games in general. It
  builds no particular game, and the prototype's branch is reference only
  (revision 7).


| # | Decision | Accepted |
| --- | --- | --- |
| G1 | The math functions live in a `math` module; the prelude selects their methods after the next rotation | yes |
| G2 | A clock lands as `io/clock`, the pre-fiber form; concurrency landing 5 replaces it | (a) yes |
| G3 | `foreign func`, one declaration each, plus one module stanza for sources and flags; `= "symbol"` and `private` required | yes; spelling in the FFI plan |
| G4 | Every List copied in both directions, with no opt-out; C returns List results in memory from `malloc`, which Blorp copies and frees | decided |
| G5 | Every foreign function is impure | decided |
| G6 | One type set in both directions: Int, Float, Int32, Float32, Bool, UInt8, and Lists of Int, Float, Int32, Float32 and UInt8; everything else as bytes or an Int | decided |
| G7 | Handles as an `Int` in a `resource union`, behind private declarations; no `Ptr` | yes |
| G8 | Sources and flags keyed by platform; a missing platform reported before cc | yes |
| G9 | User modules and the standard library may declare foreign functions; the compiler may not; declared C is embedded and published by `load` | yes |
| G10 | Foreign calls run inline on their carrier, never on a pool or helper thread; `main`'s carrier is the main thread; a blocking mark decided in the FFI plan | yes |
| G11 | `blorp run` and `blorp test` build declared sources; `blorp compile` writes them and prints the flags | yes |
| G12 | One conversion family (checked, `wrapped_to_`, `clamped_to_`) for every fixed-width number, UInt8 included | yes |
| G13 | Float32 literals round, overflow rejected, context typing; Int32 and Float32 before the FFI | decided: before |
| G14 | libm now, portable functions later | (a) yes |
| G15 | Shadowing: keep the rule with better help, or relax it for functions and imports | (a) keep, for now |
| G16 | Prelude constructors need no expected type; `==` types its untyped side | (a) and (b) yes |
| G17 | No `and`/`or`/`not` operators; a help line for the precedence trap | decided |
| G18 | Constant patterns by resolution; no byte literals | yes |
| G19 | UTF-8 in comments, with the listed exclusions | yes |
| G20 | One-line `if`, as an expression and as a statement | yes, with parser input |
| G21 | `?=` on an Option; still not inside `if`, `match` or loops | yes |
| G22 | The chain rule: break only when needed, if the diff is acceptable | (a) yes |
