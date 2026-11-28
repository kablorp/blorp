# Graphics and games plan

Status: revision 3, 2026-11-27, after two rounds of soundness and
ergonomics review.
- **Round 1:** 5 blockers and 32 should-fixes, all taken in revision 2.
- **Round 2:** blockers only. All 5 were resolved, with none new. It also
  found 5 soundness should-fixes, taken here, with their C behaviour
  probed.

Where a finding changed a recommendation, the section says so.

This plan turns what the gravity prototype taught into the work Blorp needs
before the game comes back:
- an FFI, then a window;
- 32-bit numbers;
- the pool's cost on small maps;
- the library gaps;
- the language and tooling friction the game logged.

Keith decides the items marked **G**. The rest are recommendations.

## Problem

Keith asked for a game written in Blorp, to hone decisions about graphics,
concurrency and efficiency. It is a gravity simulation in which players
launch comets to seed or sterilize worlds, while black holes and quasars
form. A prototype exists:
- **The library it needed:** branch `gravity/prototype`, 13 commits on
  `94b463fda` up to `daddbed48`, gated and reviewed, not pushed. It adds
  Float math, bit operations, a pure generator with OS seeds, a clock, and
  terminal raw mode and input.
- **The game:** 1,770 lines of Blorp and 668 of tests, in
  `.claude/worktrees/gravity/scratch/gravity/game/`. Its review notes are
  `.claude/worktrees/gravity/scratch/gravity/REVIEW.md`, and every rough edge it met is in
  `.claude/worktrees/gravity/scratch/gravity/game/FRICTION.md`.
- **Those files exist only on Keith's machine.** They are ignored by git, in
  the worktree of the `gravity/prototype` branch, and so is the evidence in
  `build/gravity-evidence/` in the main checkout. This plan quotes what an
  implementer needs from them.

The game plays at 30 frames a second in a terminal, with half-block
characters as pixels. That was always a proof of concept. Keith wants the
game in its own window, with as much of the graphics in Blorp as possible.
That needs:
- **An FFI,** to call the OS's window system.
- **Cheaper parallel work:** the pool made the game's step slower, not
  faster.
- **Fixes for the friction** that cost the game's author the most time.

### What the prototype measured

On an Apple M4 with 4 performance and 6 efficiency cores, at `-O2`.

| What | Figure | Source |
| --- | --- | --- |
| 1,024 bodies, 20 steps of direct gravity, 1 thread | 0.0192 s, 1.09× C with libm | `build/gravity-evidence/probe/timing-final.txt` |
| The same on 4 threads | 0.0072 s | the same |
| The game's step per frame (about 250 bodies, 6 attractors, 16 maps a frame) | 0.13 ms on 1 thread, 0.29 ms on 4, 2.8 ms at the default 10; 8.1 s of system CPU in a 1.7 s run | FRICTION, "Slow" |
| One `parallel_map` of 4,096 elements of about 8 square roots each | 31 µs on 1 thread, 14.9 µs on 2, 27.7 µs on 4, 329 µs on 10 | the same |
| `map` of the same | 61 µs, twice `parallel_map` on one thread | the same |
| The game's tests | 0.6 s on 1 thread, 14 s at the default thread count | the same |
| One frame at 160×48 cells | step and path 4.6 ms, drawing 0.43 ms, output 0.09 ms and 6.8 KB; 29.7 fps | the game's HUD, in a pty |
| Determinism | the same world hash at 1, 2, 4 and 10 threads | `--headless 600` |
| Compiling the game | `blorp compile` 0.23 s; clang `-O2` 0.80 s for 984 KB of C | the game's measurements |

What worked is in FRICTION's last section:
- fixed records and unions inline;
- determinism with no effort;
- `concurrent:` reading naturally;
- updates in place through a private-variant wrapper;
- help lines that were mostly right.

This plan keeps all of those.

## Decisions so far

**Keith, 2026-11-27:**
- **Randomness:** pure functions, given one seed from IO. Done on the branch.
- **Graphics:** as much as possible in Blorp, starting with a terminal
  view. That view is a proof of concept.
- **Math:** the math functions are wanted. Done on the branch.
- **The four terminal fixes** from review are wanted. Done on the branch.
- **A window needs an FFI,** and the FFI goes in this plan.
- **Order:** the needs and friction here are worked first, in other
  sessions. Then the game resumes.
- **Int32 and Float32** are to be considered.
- **What C returns:** C could return only bytes, which Blorp validates into
  the shape it wants. G6 below generalizes this.

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

They are in the recommended order. Each names its owning document, where
one already exists.

| # | Workstream | Size | Depends on | Owner decisions |
| --- | --- | --- | --- | --- |
| W0 | Land the gravity library on main | medium: main moved | Seed CI | G1, G2 |
| W1 | Spike W: a window in plain C | small | none | none |
| W2 | The FFI, in its own plan | large | W1; F3 after `RUN_AND_TEST_PLAN.md`'s CLI landing | G3 to G11 |
| W3 | The window library | medium | W1, W2 | none |
| W4 | The pool on small maps, and `map`'s cost | medium | W0, for the probe's imports; `CONCURRENCY_PLAN.md` | none |
| W5 | Int32 and Float32, in their own plan | medium, with a seed rotation | `UINT8_BYTES_PLAN.md`'s pattern | G12, G13 |
| W6 | Library gaps | small, several landings | W0, for the rows that edit branch code | G14 |
| W7 | Language friction | one landing per item | the items | G15 to G21 |
| W8 | Tooling friction | small | none | G22 |
| W9 | The game, back in a window | game code | W0, W3 | none |

**What can run beside what:**
- W7, W8 and W6's rows on code main already has can run beside everything.
- W4 needs W0 first, because its probe imports `io/clock`, `math` and
  `time`.

## Handing this plan to an implementer

The decisions are settled (see "Decisions"). Do not reopen them. Do not add
a mechanism the plan does not name: root `AGENTS.md` requires Keith's
approval for that.

Every landing still gets a brief within `docs/HANDOFF_SPEC.md`, with its
tests, exact messages and cost ceilings. A coordinator writes the brief from
this plan. Landings then fall into two groups.

**Ready to brief and implement now.** Each has a settled design, and its
work is mostly mechanical:
- **W0,** the library replay and landing.
- **W6:**
  - `zip`, `enumerate`, `fold` and `sum`;
  - `Int.abs`, `UInt8.to_float`, `to_bits` and `float_from_bits`;
  - `print_inline` and `print_error_inline`;
  - the `read_input` union;
  - the review nits;
  - the terminal's SIGTSTP, SIGCONT and IXON.
- **G12, as it applies to UInt8:** `wrapped_to_uint8` and
  `clamped_to_uint8`.
- **The help lines:** G15 (a) and G17.
- **G16** (a) and (b).
- **G21,** `?=` on an Option.
- **W8:** `blorp check`, and the test-outcome migration.

**Needing a design or measurement step first:**
- **W1,** which is a spike.
- **W2,** the FFI. Its own plan settles the syntax's spelling with parser
  input, and the `blorp_ffi.h` interface.
- **W3,** after W2.
- **F5 and F6,** Rust and C++ through the C ABI, after F3, in the FFI plan.
- **W4,** which is an investigation, in the concurrency plan.
- **W5,** in its own plan.
- **G18, G19 and G20,** each a small design with parser or ergonomics input.
- **G22:** measure the corpus diff first.
- **W6's rows that depend on G2 or the system-call interface:**
  - `sleep_until`;
  - `elapsed`'s origin;
  - `with_alternate_screen`, whose signal handling needs a design;
  - the infallible system-call form for `fault`.

## W0: land the gravity library

**What lands:** the branch's `blorp/` changes, against `94b463fda`:

| Change | Lines |
| --- | --- |
| Source | +682 / −15 |
| Library | +597 / −6 |
| Tests | +2,663 / −12 |
| README | +132 |

**Review:** two rounds, ending with 0 open blockers and 0 should-fixes. Four
nits stay open; they move to W6 and W8.

**Main has moved since the branch was cut.** The replay is real work:
1. **The seed is new.** `96b2cbaac` pinned a seed built from `94b463fda`.
2. **Union destructuring is gone.**
   - Main deleted it in `2c906685b` (`UNION_DESTRUCTURING_REMOVAL_PLAN.md`),
     and the branch uses it, as in `random.brp`'s `Init(state) = generator`
     and in `time.brp`.
   - Migrate every such read to `match`.
3. **One ceiling no longer exists.** `variants/alias_destructure`, whose
   allocation ceiling the branch raised, is gone from main. That raise
   drops.
4. **Concurrency landing 4b has landed:** `217ecff10` and `d6b3cdbe1`.

So redo the cost rows on the replayed commits:
- **Self-compile, with stage-2 compilers.** `self-compile-cost` runs the
  seed's runtime, so it misses runtime-fragment changes, and the branch
  changes several.
- **Every ceiling.**
- **The full gate.**
- **A dispatched `blorp.yml` run for Seed CI.** Nothing was compiled on
  Linux.

**The math functions are in a new `math.brp`.** The prelude imports
`float`, so the seed reads `float.brp` and rejects new labels there.

**G1. The math functions' home.**
- **Moving them into `float.brp` later is not free.** Modules do not
  re-export, so every call site's import would change.
- **Recommended:** keep `math.brp` as their home. After the next rotation,
  the prelude selects `math: Float methods` (README, "`module: Shape
  methods`"), so `x.sqrt()` needs no import. Call sites keep working.

**G2. Where the clock lives.**
- **The branch adds `io/clock`.** Its `elapsed()` counts from its first
  call, and its `sleep(Duration)` blocks the thread.
- **The concurrency plan defines both in `concurrency`.**
  - `sleep` parks the fiber.
  - `elapsed()` is "the time since the runtime started", virtual under
    `simulate`.
- **Once fibers run, a blocking `sleep` stalls its carrier, and real time
  inside `simulate` breaks determinism.**
- **Options:**
  - (a) Land `io/clock` now as the pre-fiber form, documented as such.
    Concurrency landing 5 then replaces it with `concurrency.sleep` and
    `concurrency.elapsed`, and deletes `io/clock`.
  - (b) Hold the clock out of W0, and land it with landing 5.
- **Recommended: (a).** The game needs a clock now. The concurrency plan
  then owns the move. W0 records it there.

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

### The earlier design

The legacy compiler had an FFI. `docs/GUIDE.md` section 15 describes it,
and it was removed with that compiler in `e1cae3971`.
- **Blocks:** `foreign(include:, link:)` blocks, with link flags limited to
  `-l`, `-L`, `-I`, `-framework` and `-pthread`.
- **Declarations:** `func name(...) -> T`, with an optional `= "c_symbol"`.
- **Three modes:**
  - the default copies String and Bytes arguments;
  - `pure` copies nothing, and pure code may call it;
  - `@no_copy` is impure, and copies nothing.
- **Types:**
  - an opaque `Ptr`;
  - String converted to and from `char*` automatically;
  - fixed arrays expanded to a pointer and a length;
  - payload-free unions passed as a C `long` tag.
- **The standard library** could not declare foreign functions.

### What to keep, and what to change

**Keep:**
- **Restricted link flags.**
- **A list passes as a pointer and a length.**
- **No callbacks:** C never calls into Blorp.
- **A pure foreign function,** as an explicit promise the compiler cannot
  check (G5).

**Change:**
1. **Arguments are borrowed, read-only, and never copied** (G4).
   - The copy did protect one thing: an in-bounds write into a shared or
     static value, such as a `static const` empty list (`list.brp`) or a
     CTFE static literal.
   - It protected nothing against the other dangerous failures: keeping a
     pointer after the call, writing past the end, or freeing Blorp memory.
   - It costs a framebuffer copy per frame.
   - **The write protection is kept another way.**
     - `blorp` generates a header of every foreign function's prototype,
       with every pointer `const`.
     - Each declared C source is compiled with that header forced in
       (`-include`).
     - So a definition that takes a non-`const` pointer, or that disagrees
       with the declaration in any type, is a "conflicting types" error.
       Without the forced header it would compile and link silently, because
       a source file is its own translation unit.
     - Declared sources are also compiled with
       `-Werror=incompatible-pointer-types` and, on clang,
       `-Werror=incompatible-pointer-types-discards-qualifiers` (gcc:
       `-Werror=discarded-qualifiers`). Without those flags, both mistakes
       are only warnings. Probed with Apple clang 21 on 2026-11-27:
       - a definition that drops `const` is an error by default;
       - assigning a `const` pointer to a plain one, or returning the wrong
         List type (a `List[UInt8]` for a `List[Int]`, which Blorp would then
         read eight times past the end), is a warning by default and an
         error with the flags;
       - an explicit cast passes either way.
     - **Every foreign function binds a symbol defined in a declared
       source.** Only those sources are compiled with the prototypes forced
       in. A symbol taken straight from a linked library, such as
       `= "read"`, would get no check: `read` writes into its buffer, which
       here is a borrowed and possibly shared value.
       - The CLI checks, before it links, that each declared symbol is
         defined by the declared sources' objects.
       - F6 adds a second way: a symbol is also bound if a declared
         library's declared header declares it, checked as F6 describes.
         Until F6, a one-line adapter in the module's source binds a
         library function.
       - F6's check would reject `= "read"` itself: `unistd.h` declares
         `read`'s buffer `void *`, not `const`, and its count as a `size_t`.
   - **What `const` cannot catch** is C's contract, written in the FFI
     plan:
     - a cast that drops `const`;
     - keeping a pointer;
     - writing past the end;
     - changing ambient state, which item 6 covers.
   - `@no_copy` then has nothing to say, and goes. `@tail_recursive` stays
     the language's attribute.
2. **There is no `Ptr` type** (G7).
   - A C handle crosses as an `Int`.
   - Foreign declarations are module-private by rule.
   - The module wraps the handle in a `resource union`, and lends it through
     a `with_` function. That is how `with_reader` lends a `Reader` today,
     through `body(Reader.Init(opened))` in `io/files/read.brp`.
   - Resources are never copied or returned, and are closed by their owner
     (README, "Resources and private declarations").
   - Because no other module can reach the `Int`-taking functions, no one
     can forge a handle or close one twice.
   - The legacy advice, "call the wrapper's free function when done", is
     manual memory management, which principle 12 rules out.
3. **Strings go out borrowed, as a pointer and a length.**
   - A String is already C-compatible.
     - Its runtime layout is `struct blorp_string { references; int64_t
       length; int64_t code_points; capacity; char bytes[]; }`
       (`runtime/string.brp`).
     - The bytes are contiguous UTF-8, and the length is in bytes, without
       the trailing NUL.
     - So passing `s->bytes` and `s->length` copies nothing.
   - That has neither legacy problem: no truncation at an embedded NUL, and
     a String is already valid UTF-8.
   - **The trailing NUL.** The runtime writes one after the bytes. The FFI
     plan decides whether to promise it to C. If it does, an adapter can hand
     the bytes to a `char *` API with no copy. A String may contain U+0000,
     so such an API sees only the part before the first NUL. Where that
     matters, as for a path, the adapter must reject an interior NUL.
   - Strings do not come back. C bytes would need UTF-8 validation, so C
     returns bytes and Blorp validates them (G6).
4. **No union travels as a raw tag.** The legacy contract said that "any
   other value violates the contract". That is undefined behaviour, against
   principle 1. Return an `Int` and decode it in Blorp.
5. **One declaration per function.**
   - Each function is declared once, with sources and link flags keyed by
     platform (G8).
   - The emitted C is then the same on every platform, and `check` has
     nothing to compare between platforms.
6. **C must return the ambient state as it found it.**
   - **It must leave unchanged:** the floating-point environment (rounding,
     traps, flush-to-zero), the signal mask, and the signal handlers.
   - **Why:**
     - Each persists per thread or fiber. Landing 4b saves FPCR and MXCSR.
     - A changed one breaks principle 1, and the determinism CTFE relies on.
     - Signal handlers also interact with landing 4a's counted swap.
   - **Checking it:** a diagnostics build can assert the FP environment
     after each call.

### Types at the boundary

**The rule:** a type crosses only if the compiler already knows it as a fact,
not by its name. `check` designates Bool, Option and Result
(`namespace/builtins.brp`), and knows the numbers and List. It has no notion
of `Bytes`, which is a library type. Admitting it by name would be the
spelling heuristic principle 4 rules out. Admitting every private-variant
union would let C build any encapsulated type. So `Bytes` crosses as its
`List[UInt8]`, and the declaring module wraps it with `from_list` and
`to_list`, neither of which copies (`bytes.brp`).

**Arguments,** all borrowed for the call:

| Blorp | C |
| --- | --- |
| `Int` | `int64_t` |
| `Float` | `double` |
| `Bool` | `uint8_t`, 0 or 1 |
| `UInt8` | `uint8_t` |
| `String` | `const uint8_t *data, int64_t length`, UTF-8 and not NUL-terminated |
| `List[Int]` | `const int64_t *data, int64_t length` |
| `List[Float]` | `const double *data, int64_t length` |
| `List[UInt8]` | `const uint8_t *data, int64_t length` |
| After W5 | `Int32`, `Float32` and their Lists |

A Blorp List is one array: `struct { references; int64_t length; capacity;
T values[]; }`, with the struct's name fixed by its element type
(`blorp_l_0_i`, `blorp_l_0_f`, `blorp_l_0_b`, in `runtime/list.brp`). So
none of these is copied.

**G6. Results: a type C cannot build wrongly.** Every value of the declared C
type maps to exactly one Blorp value, with no validation.
- **Admitted:**
  - `Int`, `Float`, `UInt8` and `Void`;
  - `Bool`, from any `uint8_t`, nonzero being `True`, a total conversion;
  - `List[Int]`, `List[Float]` and `List[UInt8]`;
  - after W5, `Int32`, `Float32` and their Lists.
- **Float is sound.** NaN payloads cannot be observed today, and a
  signalling NaN goes quiet with no trap, as long as C left the FP
  environment alone (item 6).
- **Everything else comes back as an Int or a `List[UInt8]`** and is decoded
  in Blorp, usually into a `Result`:
  - String, which needs UTF-8 validation;
  - unions;
  - records;
  - `Bytes`.

This is Keith's "only bytes back, then validate", generalized:
- C can never build an invalid Blorp value;
- every invariant is established in Blorp, where it is tested;
- it is how the terminal natives' decoders already work.

It is not bytes only, for two reasons:
- a scalar result, such as `sin(x)`, a handle or a status, coming back as
  bytes would be absurd;
- a float array would need a decoding pass per element.

**Result Lists: C fills what Blorp allocates.**
- The CLI writes `blorp_ffi.h` beside the generated prototypes. It is
  outside the program's translation unit, and declares:
  - `blorp_ffi_new_list_int(capacity)`, with its Float and UInt8
    counterparts;
  - a data accessor;
  - `blorp_ffi_set_length(list, length)`, checked against the capacity, for
    results whose length C learns as it goes, such as `poll_events`.
- **Allocation:** zero-filled, through Blorp's allocator, so diagnostics
  builds and leak checks count it.
- **The result contract.** A result List is one that a `blorp_ffi_new_…`
  helper allocated during this call, and C keeps no pointer to it.
  - C receives only data pointers, never List headers, so it cannot return
    an argument. The mistake it can make is returning a List it built in an
    earlier call and kept, which would silently underflow the reference
    count.
  - **The check:** the helpers record each allocation in a set kept per
    call and per thread. The call site checks that the result is in it.
  - That one check catches a `NULL`, stale or foreign result. Each aborts
    with a message naming the function: a contract fault, as a broken
    native contract is today.
  - A List allocated and not returned is reported by the leak check.

### Declaring foreign functions

**G3. The declaration form.**
- **Principles 13 and 16 say "`foreign func` is one declaration".** Keep
  that, and add one module-level stanza for the sources and flags a module's
  declarations share.
- **The FFI plan settles the spelling** with parser and ergonomics input.
- **It is the language's first named metadata,** so it is its own small
  grammar, not a call with named arguments. Platform names are a closed set
  checked by the parser, whose error lists the valid names.
- **`= "symbol"` is required,** so the Blorp name never depends on the C
  name.
- **Foreign declarations are `private`.** A public one is rejected, with
  help that shows the wrapper pattern. By convention they are named
  `native_…`, as `io/files/read.brp`'s natives are today.

A sketch for the FFI plan's reviewers, not a settled spelling:

```blorp
-- The module's C, per platform. The CLI compiles the matching source with
-- the generated prototypes forced in, and links with the matching flags.
foreign:
    source macos "window_macos.c"
    source linux "window_x11.c"
    link macos "-framework AppKit" "-framework CoreGraphics"
    link linux "-lX11"

private foreign func native_open(width: Int, height: Int, title: String) -> Int = "blorp_window_open"
private foreign func native_present(window: Int, pixels: List[UInt8], width: Int, height: Int) -> Int = "blorp_window_present"
private foreign func native_poll(window: Int) -> List[Int] = "blorp_window_poll"
private foreign func native_close(window: Int) -> Int = "blorp_window_close"
```

**G4. Arguments borrowed, read-only, never copied, with prototypes forced in.**
Recommended.

**G5. How a foreign function is marked pure.**
- It is the one place a user can break purity, since a pure foreign function
  may run on a pool thread inside `parallel_map` or a `concurrent:` block.
- **Define the promise:**
  - no effects, and the same result for the same arguments;
  - safe on any thread;
  - keeps nothing it was given;
  - calls nothing impure.
- **Options:**
  - (a) `pure`, with its documentation stating that the compiler cannot
    check it.
  - (b) `unchecked pure`, which every reader sees, and which grep finds.
- **Recommended: (b).** Rust marks the same trust `unsafe`.
- **Either way,** CTFE rejects a foreign call reached from a constant
  initializer, in its dependency pass (`CTFE_PLAN.md`).

**G6. Results: only types C cannot build wrongly,** as above. Recommended.

**G7. Handles: an `Int` in a `resource union`,** behind private foreign
declarations. No `Ptr`. Recommended.

**G8. Platforms.**
- **One declaration per function,** with sources and flags keyed by
  platform.
- **A platform with no entry** is reported by `blorp run` before it calls
  the C compiler, naming the module and the platform. It is reported only
  for a module whose foreign functions the program can reach. Importing a
  module whose stanza names only macOS does not fail on Linux when nothing
  calls its foreign functions.
- **Why not leave it to the C compiler:** that run would fail inside cc,
  which `RUN_AND_TEST_PLAN.md` R5 maps to exit 4, "a fault in blorp".
- **Recommended.**

**G9. Who may declare foreign functions, and how their C travels.**
- **User modules may,** which is principle 16.
- **So may the standard library,** under the same rules, since a window
  library belongs there.
- **The compiler's own source still may not.** The bootstrap subset has no
  FFI (`blorp/AGENTS.md`).
- **How the C travels:**
  - The embedder embeds only `.brp` files (`scripts/embed_library.brp`), so
    it must also embed the C sources a library module declares.
  - `load` publishes them in the source inventory.
  - The CLI writes them out to compile them.
- **Recommended.**
- **Not in scope:** turning the compiler's built-in system natives into
  foreign declarations. It would conflict with the bootstrap subset, and with
  CTFE's delegation to natives (`CTFE_PLAN.md`, "Floats and natives").

**G10. Where a foreign call runs.**
- **Correction:** the concurrency plan's landing 4b results say the fiber
  runtime is emitted nowhere yet, and landing 5 is its first user. Fibers
  stay on the thread they first ran on. Revision 1's "`main` is the first
  fiber today" was wrong.
- **Recommended:**
  - An impure foreign call runs inline, on the calling carrier. It never
    goes to the pool of helper threads, which runs the built-in blocking
    natives.
  - The carrier that runs `main` is the process's main thread. AppKit needs
    that.
  - A `main_thread` mark waits until there is more than one carrier.
  - A foreign call is expected to return promptly. A long blocking call
    stalls every fiber on its carrier.
  - The FFI plan decides whether a `blocking` mark, which would send the
    call to a helper, is needed. Spike W says whether the window layer
    blocks.
- **Record this in `CONCURRENCY_PLAN.md`** before landing 4c fixes where
  natives run. That plan already says only kernel carriers and pool threads
  run Blorp code.

**G11. Linking through the CLI.**
- **`RUN_AND_TEST_PLAN.md` puts foreign link flags out of scope.** Its R5
  says a program using foreign libraries "gets a link error until a `--link`
  option exists", and no `blorp build` is planned. So F3 adds CLI scope.
- **Recommended:**
  - `blorp run` and `blorp test` compile the declared sources and pass the
    declared flags.
  - `blorp compile` writes the C, the prototypes header, `blorp_ffi.h` and
    the sources. It prints the C compiler and linker arguments a user needs.
- **Sources and flags are published once.** The test driver and the CLI
  both read that publication, so F2 does not link by hand.

### Phases

| Phase | Work |
| --- | --- |
| `lex`, `parse` | The stanza and `foreign func`. `foreign` is reserved already. Teaching messages: `extern "C"`, a nested `foreign func` ("foreign declarations go at the top of a module"; today it reports "expected a return expression"), and `Ptr` or `void*` (names the Int handle and `resource union` pattern). |
| `load` | Resolve sources beside the declaring module. Publish them in the source inventory. |
| `check` | The admitted argument and result types (G6), with help for a String result ("return `List[UInt8]` and decode it"); `private` and `= "symbol"` required; purity, as impure unless marked (G5). |
| `specialize` | The dependency pass rejects a foreign call reached from a constant initializer, transitively (`CTFE_PLAN.md`). |
| `lower` | A foreign call target, beside `RuntimeFunction` in `own.brp`'s call targets. |
| `own`, `verify` | Arguments are borrowed, as runtime calls' are, with no owned or in-place position. A result is owned. The verifier rejects a borrowed argument released by the call. |
| `emit` | The prototypes header; `const` pointers and lengths at call sites; `blorp_ffi.h` and its helpers. |
| CLI | G11. |

### Tests and costs

**Tests:**
- **Unit tests at each phase boundary,** as `blorp/AGENTS.md` requires for
  memory increments. They include malformed ownership IR the verifier must
  reject.
- **An e2e fixture with a small C file beside it,** covering:
  - every admitted argument and result type;
  - an unchecked-pure call from pure code, and from `parallel_map`;
  - a String result rejected, with exact message, help and span;
  - a non-`const` definition, which the forced prototypes reject;
  - a handle lent through `with_`;
  - each contract fault: a `NULL`, a stale and a foreign result;
  - a symbol not defined in a declared source, rejected before linking.
- **Costs:** a program without foreign calls pays nothing. The self-compile
  fixed-input row keeps exactly the same allocations, and instructions
  within +0.05%, since the compiler declares no foreign function.

### Landings

- **F1:** the stanza, `foreign func`, the checks and the teaching messages,
  with no emission.
- **F2:** lowering, ownership, emission, the prototypes header and
  `blorp_ffi.h`, with the e2e fixture built through the one publication.
- **F3:** the CLI (G11), after `RUN_AND_TEST_PLAN.md`'s CLI landing
  brings `blorp run` and `blorp test`. Neither exists yet.
- **F5:** C++ sources, after F3 (see "Other languages through the C ABI").
- **F6:** a prebuilt library checked against its header, after F3. It
  covers Rust, and binding an existing C library with no adapter.
- **README and grammar updates** in each landing, per root `AGENTS.md` rule
  13.

### Other languages through the C ABI

Keith asked on 2026-11-27 for Rust and C++ to be covered. Both reach Blorp
through the C ABI, as they reach every other language.
- **C++** exports to C with `extern "C"` functions. Its classes, templates,
  overloads and exceptions stay behind them.
- **Rust** has no stable ABI except `extern "C"` and `#[repr(C)]`.
- **Binding C++ classes or Rust types directly** is not planned. That is
  the multi-year path Swift and Zig took for C++, and Rust offers nothing
  stable below its C ABI.
- **The legacy FFI** worked this way too (`docs/GUIDE.md` section 15, in
  `e1cae3971^`). The difference now is that handles, borrowing and the
  result rule make the boundary safer.

The Blorp side does not change: the same `foreign func` declarations, types,
borrowing, results, handles and contract. What changes is where the code
comes from, how it is checked against the declarations, and how it links.

**F5: C++ sources.**
- **Declaring them:** a module's stanza may declare a `.cpp` source as it
  declares a `.c` one, keyed by platform.
- **Compiling them:**
  - With the C++ compiler, with the prototypes header forced in.
  - The header wraps its declarations in `#ifdef __cplusplus` / `extern "C"
    {`, so they have C linkage.
- **Checking.** C++ links names differently from C, so the forced header
  catches less than it does for C. Probed with Apple clang 21 on 2026-11-27:
  - **A definition with the declared signature,** inside or outside
    `extern "C"`, keeps C linkage, because the forced declaration fixed it
    first. It is correct.
  - **A definition whose signature differs,** for example one that drops
    `const`, is not an error. C++ makes it a new overload with a mangled
    name (`__Z1fPll` for `long f(long *, long)`).
  - So G4's check that each declared symbol is defined is what catches a
    wrong C++ definition: the C name stays undefined, and the CLI reports it
    before linking.
  - **Inside a body,** C++ is stricter than C: passing a `const` pointer
    where a plain one is expected is an error.
- **Contract: no exception may escape.**
  - Each adapter is `noexcept`, and catches everything, returning an error
    code.
  - An exception that reaches a `noexcept` boundary calls `std::terminate`,
    which is defined behaviour. One that unwinds into C frames is undefined.
- **Headers:** both the prototypes header and `blorp_ffi.h` carry the
  `__cplusplus` guards, and use only types that are valid in C++, with no
  `_Bool` or `restrict`. Rust and C++ both read `blorp_ffi.h`.
- **Linking:** with the C++ driver, `clang++` or `g++`, or with the
  platform's C++ library (`-lc++` on macOS, `-lstdc++` with GNU). The C++
  standard is a stanza field, defaulting to C++17.
- **Tests:**
  - a fixture with a `.cpp` source;
  - a definition whose signature differs, reported by the symbol check;
  - an adapter that catches an exception and returns its code.

**F6: a prebuilt library checked against its header.** This is the "library
plus header" binding that G4 deferred. It also covers Rust, and binding a
plain C library function whose C types match Blorp's exactly, such as
`libm`'s `sqrt`, with no adapter.
- **Declaring it:** a module's stanza declares, per platform:
  - the library, a static `.a` or a system library name;
  - its C header;
  - its link flags.
- **Checking.** The CLI compiles one check-only C file per module, with the
  prototypes header not forced in. For each declared symbol, in this
  order, the file:
  1. Includes the declared header.
  2. Takes the symbol's address, as `(void *)&symbol`. A symbol the header
     does not declare is then "use of undeclared identifier". That was
     probed on 2026-11-27. Without this step, Blorp's own declaration would
     supply the missing one.
  3. Declares Blorp's prototype for the symbol. A declaration that disagrees
     with the header's, in any type or in `const`, is then a "conflicting
     types" error, the rule revision 3's probe showed.
- **What this proves:** that Blorp's declaration matches the header.
- **What it trusts:** that the header matches the library. A hand-written
  header can disagree with its `.a`. So for Rust, generate the header with
  cbindgen rather than writing it.
- **Rust specifically:**
  - The Rust side exports `#[no_mangle] pub extern "C"` functions, with
    `#[repr(C)]` where a struct is involved.
  - Its header is written by hand or generated with cbindgen.
  - The user builds the static library with cargo. The Blorp CLI does not
    run cargo.
  - Its native dependencies, which `cargo rustc -- --print
    native-static-libs` lists, go in the stanza's link flags.
  - A borrowed argument becomes a slice with `std::slice::from_raw_parts`.
  - Results are built through `blorp_ffi.h`, which the Rust side declares as
    `extern "C"`.
- **The crate:**
  - its type is `staticlib`, which `--print native-static-libs` also needs;
  - its profile must not set `panic = "abort"`, under which
    `catch_unwind` catches nothing.
- **Contract: no panic may leave an `extern "C"` function.**
  - Since Rust 1.81, a panic that unwinds out of one aborts the process.
  - To turn a panic into a Blorp `Result` instead, the adapter catches it
    with `std::panic::catch_unwind`, wrapping its closure in
    `AssertUnwindSafe` where needed, and returns an error code.
- **Tests:**
  - a C static library with a header: a matching declaration links, and a
    mismatched one is rejected;
  - a Rust fixture, gated on a Rust toolchain on the CI runners. GitHub's
    images include one; the local Docker images would need it added.

**Not planned: exporting Blorp to other languages.** A Rust or C++ program
calling into Blorp needs:
- Blorp functions exported with a C ABI;
- a way to start Blorp's runtime from a host's `main`;
- usually, callbacks, which this plan excludes.

It is its own later decision.

## W3: the window library

**Its foreign surface** comes from Spike W: open, present, poll, close and
size. macOS first.

**In Blorp:**
- `with_window[T, E](title, width, height, body, on_error)`, following
  `with_reader` and `with_atomic_writer`: a `scoped (Window) ->
  Result[T, E]` body and an `on_error` mapper from `WindowError`;
- a `Window` resource;
- a `WindowEvent` union, decoded from `native_poll`'s `List[Int]`;
- a `Key` union;
- `present(window, frame) -> Result[Void, WindowError]`, borrowing the
  frame.

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
    private Init(Int)


private foreign func native_open(width: Int, height: Int, title: String) -> Int = "blorp_window_open"
private foreign func native_poll(window: Int) -> List[Int] = "blorp_window_poll"
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
    handle ?= native_open(width, height, title)
        .opened()
        .map_err(on_error)

    outcome = body(Window.Init(handle))
    -- Bound because only a Void call can stand alone as a statement.
    closed = native_close(handle)
    outcome


-- Each public function reads the handle with match, since union
-- destructuring is gone from main.
func poll_events(window: Window) -> List[WindowEvent]:
    match window:
        Init(handle): native_poll(handle).decoded_events()
```

The game's side:

```blorp
import:
    io/console/output: print_error
    window: Window, WindowError, WindowEvent(KeyDown, CloseRequested), Key(Space), with_window, present, poll_events

-- `?=` may not appear inside a loop (Keith, 2026-10-15), so a failed
-- present ends the loop and becomes the result.
func play(window: Window) -> Result[Void, WindowError]:
    var world = starting_world()
    var running: Bool = True
    var outcome: Result[Void, WindowError] = Ok(void)

    while running:
        for event in window.poll_events():
            match event:
                CloseRequested: running = False
                KeyDown(Space): world = world.launched()
                _: void

        world = world.stepped()

        match window.present(world.drawn()):
            Ok(_): void
            Err(error):
                outcome = Err(error)
                running = False

    outcome


func main() -> Int:
    match with_window("gravity", 1280, 720, play, pure func(error: WindowError) -> WindowError: error):
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

**Later, all in Blorp:**
- a `graphics` module, which lifts the game's discs, glows and lines out of
  its view;
- a bitmap font, as data;
- image encoders for screenshots, such as BMP and QOI.

## W4: the pool on small maps, and `map`'s cost

**Owning document:** `CONCURRENCY_PLAN.md`. These findings go there as
evidence. Its Spike P results already note two things:
- "Waking idle workers. A tiny map pays this on every call; it was not
  isolated."
- The serial `map` "retires 2.25× the instructions of a loop into a List
  sized up front".

**The game shows both costs in a real program:**
- **The pool on small maps.**
  - A `parallel_map` of 4,096 elements is ten times slower on the default
    ten threads than on one, with 13.7 s of system CPU in a 3.1 s run.
  - No list size in the game gains from more than two threads.
  - Even 2,000 dust motes take 1.0 ms on 1 thread and 5.1 ms on 10.
- **`map` itself:** it is half the speed of `parallel_map` on one thread.

**Recommended:**
1. **Measure where the system time goes:** idle workers spinning, waking,
   or sleeping in the kernel. Use the game's probe,
   `.claude/worktrees/gravity/build/gravity/measure/parallel_map_cost.brp`, after W0.
2. **Split on demand, not by a fixed minimum.**
   - Spike P found that a nested map needs pieces of one element, so a fixed
     minimum piece size is wrong.
   - Rayon's `with_min_len` is a setting per call, which Blorp would rather
     not expose.
   - Instead: split only when another worker is idle to steal the piece,
     and otherwise run in place.
   - Measure it on the game and on Spike P's nested map.
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
- **Float to an integer width saturates,** with NaN giving 0, as `to_int`
  does. That fits principle 1.
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
- **Order:** after the FFI, for the GPU and audio. **Recommended.**

## W6: library gaps

Each is a small landing, in Blorp unless noted. A row that edits branch code
waits for W0.

| Gap | Evidence | Proposal |
| --- | --- | --- |
| `zip`, `enumerate`, `fold`, `sum` | the game counts indexes by hand 5 times and sums by hand 7 times | `zip` stops at the shorter list, as in Rust and Python. `fold(values, initial, step)` puts the initial value first, like `fold_lines`. `sum` takes `List[Int]` or `List[Float]` and adds left to right, so a Float sum is deterministic. Measure the List of pairs that `zip` and `enumerate` build; if `for (index, value) in values.enumerate():` is hot, give that loop a form that builds nothing. |
| `Int.abs` | the game writes `difference.max(-difference)` | add it, wrapping at INT_MIN as negation does |
| `UInt8.to_float` | `channel.to_int().to_float()` | add it |
| Float bits | the world hash spells every Float as text, about 40 KB per hash | `to_bits(Float) -> Int` and `float_from_bits(Int) -> Float`, natives. A name of its own avoids a clash with a later `float32_from_bits`, since both take an Int. A negative Float gives a negative Int. NaN's sign differs between x86-64 and arm64 (`CTFE_PLAN.md`), so the bits are exact but not the same everywhere for NaN. |
| Text to stdout without a newline | a frame goes through `write(to_bytes(text))`, a copy | `print_inline(text)` and `print_error_inline(text)` in `io/console/output`, which pair with `print` and `print_error` and do not read like `io/files`' `write_text(path, text)` |
| A deadline sleep | a loop that sleeps and then compares ran at 28 fps, not 30 | `sleep_until(deadline: Duration)`, on the clock `elapsed()` reads, so a deadline is a `Duration` since that clock's origin; moves with G2 |
| An alternate-screen scope | Ctrl-C leaves the alternate screen and a hidden cursor, and the game's `run` script works around it | `with_alternate_screen[T, E](body, on_error)`: raw mode, the alternate screen and a hidden cursor, restored on return and exit, and on a signal or an abort by the same handler that restores raw mode, which writes the escapes with `write(2)`, an async-signal-safe call. Best-effort until a pty test proves each path. |
| Terminal gaps | Ctrl-Z leaves the terminal raw; IXON pauses output | handle SIGTSTP and SIGCONT; turn IXON off |
| `read_input`'s result | "nothing yet" is `Some` of empty bytes | a three-case union |
| Review nits from W0 | `split`'s "independent" wording; the undocumented INT_MAX-millisecond cap and TCSAFLUSH | fix the docs |
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

**Recommended: (a) now.** The game's step uses only exact operations.

## W7: language friction

Each item is its own design and landing. An item that adds syntax gets
parser and ergonomics input first, and documenter review after.

**G15. Shadowing.**
- **The evidence:** seven renames: `attractors`, `merged`, `camera`,
  `starfield`, `length`, `energy` and `quasars_in_reach`.
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
  - They are unambiguous today, and this is the largest win: the game needed
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
    names, and `.and(` appears 78 times in the game, and throughout the
    library and the compiler.
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
| Positional arguments only: `habitat_lived(…, flux, …, duration)` takes two Floats a caller can swap | later; named arguments are a larger design |

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
- **Exempting `.not()` would be a special case,** and G17's operators would
  make it moot.
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

## W9: the game, back in a window

After W0 and W3, the game's half-block view becomes:
- a framebuffer it presents;
- aiming with the mouse;
- the HUD drawn with a bitmap font;
- an end to a round.

Its terminal view stays, behind W6's alternate-screen scope. The game stays
in `.claude/worktrees/gravity/scratch/gravity/` until Keith decides whether it ships as an
example.

## Process

**Briefs and plans:**
- **Briefs:** every landing gets a brief within `docs/HANDOFF_SPEC.md`.
- **Own plans:** W2 and W5 each get one, reviewed for soundness and
  ergonomics. So does G17's operators plan.
- **Syntax:** every W7 item that adds syntax takes parser and ergonomics
  input first, and documenter review after.

**Costs** follow root `AGENTS.md`:
- **Ceilings** are set before implementation, from a spike where one
  exists.
- **W2's self-compile row** is set above.
- **Runtime-fragment changes** are measured with stage-2 compilers.

**Tracking:** `NEXT.md` gets one entry pointing here. Each workstream records
its landings in this file, or in its own plan once it has one.

**Review:** done. Two rounds, as root `AGENTS.md` allows. The coordinator
checked the round-2 should-fixes taken in revision 3.

## Decisions

**Keith, 2026-11-27, on revision 3:**
- "Otherwise sounds good": the recommendations below are accepted.
- G17 is decided as no operators.
- G18 is clarified: constants keep `UPPER_SNAKE_CASE`.
- Rust and C++ are covered through the C ABI, as F5 and F6 ("Other
  languages through the C ABI").


| # | Decision | Accepted |
| --- | --- | --- |
| G1 | The math functions stay in `math.brp`; the prelude selects their methods after the next rotation | yes |
| G2 | Land `io/clock` now as the pre-fiber form; concurrency landing 5 replaces it | (a) yes |
| G3 | `foreign func`, one declaration each, plus one module stanza for sources and flags; `= "symbol"` and `private` required | yes; spelling in the FFI plan |
| G4 | Arguments borrowed, read-only, never copied; prototypes forced into each C source; `@no_copy` dropped | yes |
| G5 | A pure foreign function is marked `unchecked pure` | (b) yes |
| G6 | Results only of types C cannot build wrongly; String, unions and records come back as Int or `List[UInt8]` | yes |
| G7 | Handles as an `Int` in a `resource union`, behind private declarations; no `Ptr` | yes |
| G8 | Sources and flags keyed by platform; a missing platform reported before cc | yes |
| G9 | User modules and the standard library may declare foreign functions; the compiler may not; declared C is embedded and published by `load` | yes |
| G10 | Foreign calls run inline on their carrier; `main`'s carrier is the main thread; a blocking mark decided in the FFI plan | yes |
| G11 | `blorp run` and `blorp test` build declared sources; `blorp compile` writes them and prints the flags | yes |
| G12 | One conversion family (checked, `wrapped_to_`, `clamped_to_`) for every fixed-width number, UInt8 included | yes |
| G13 | Float32 literals round, overflow rejected, context typing; Int32 and Float32 after the FFI | yes |
| G14 | libm now, portable functions later | (a) yes |
| G15 | Shadowing: keep the rule with better help, or relax it for functions and imports | (a) keep, for now |
| G16 | Prelude constructors need no expected type; `==` types its untyped side | (a) and (b) yes |
| G17 | No `and`/`or`/`not` operators; a help line for the precedence trap | decided |
| G18 | Constant patterns by resolution; no byte literals | yes |
| G19 | UTF-8 in comments, with the listed exclusions | yes |
| G20 | One-line `if`, as an expression and as a statement | yes, with parser input |
| G21 | `?=` on an Option; still not inside `if`, `match` or loops | yes |
| G22 | The chain rule: break only when needed, if the diff is acceptable | (a) yes |
