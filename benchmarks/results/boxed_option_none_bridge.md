# Boxed Option runtime None bridge

This prerequisite repairs the emitted ABI singleton initialization, independently
of declared inline unions. Base: `f42a5fbcd3b39a1151c95006e175801f9c37d7fd`.

## Reproduction and repair

The retained source `/tmp/blorp-boxed-option-none.WhFZaQ/stream_nested_option_miss.brp`
calls `stream.find` on `List[Option[Int]]` with a false predicate and matches the
boxed outer `None`. The exact f42 compiler compiles it and clang links it, but
the executable exits 139: `blorp_stream_find` calls `blorp_option_none`, whose
`__blorp_none_singleton_ptr` remains NULL. The emitted Option declaration and
immortal empty singleton are present; this is not a missing DCE declaration.

```sh
/tmp/blorp-declared-union-baseline.lZx0pY/blorp compile --no-format \
  -o /tmp/blorp-boxed-option-none.WhFZaQ/red.c \
  /tmp/blorp-boxed-option-none.WhFZaQ/stream_nested_option_miss.brp
clang -O2 /tmp/blorp-boxed-option-none.WhFZaQ/red.c \
  -o /tmp/blorp-boxed-option-none.WhFZaQ/red.exe -lm -lpthread
/tmp/blorp-boxed-option-none.WhFZaQ/red.exe
```

The shared emitter helper binds the pointer to the existing issued singleton
only for `DeclaredAbiOption`, in existing zero-field initializer branches.
Runtime projection validates the ABI template. Single emission and split TU0
both bind it; the shared header and other TUs do not. No runtime fallback,
layout admission, ownership or DCE policy changes are introduced.

The registered backend suite checks one binding, placement, and negative
concrete user `Option`/`None` and ABI `Result` declarations. The existing stream
suite retains its two Int controls and adds only an empty typed
`List[Option[Int]]` stream miss. This still selects boxed outer Option but
cannot pull an inline slot or invoke the element callback; it isolates runtime
None initialization from the separately broken stream element transport.
Independent owner/broad gates and fixpoint are reported by the test runner,
not inferred from the fresh O2 build. This repair intentionally changes ABI
Option C; downstream raw-C controls must use the repaired baseline without
normalization. No performance claim is made.

## Provenance

Artifacts and logs: `/tmp/blorp-boxed-option-none.WhFZaQ/REPORT.md`.
SHA256:

- f42 compiler: `22d779ce446793e536394550f14eef0b44437c2165b7a7b752fac569c8bbdf67`
- red C: `de10e19160c8071d0e4f54d84e6284ff9211b31d6427213e58e65f435f449c97`
- repaired compiler: `3c600e565ee902ba9f59f4da7f36d44bcf70cf764f0f6b561a5926150850053f`

## Deferred preexisting stream transport bug

Independent isolated nested empty/zero hit probes abort 134 with
`blorp: non-exhaustive match` under both f42 and the repaired compiler. The
empty-hit C differs only by the singleton binding. Sources, Core, C and run
metadata remain in `/tmp/blorp-boxed-option-none-independent.SdxUzd/`, with
`nested_empty_hit.brp`, `nested_zero_hit.brp`, and `base-*`/`repair-*` artifacts.
Compile commands are recorded in their `*-compile/metadata.json` files.

The existing inline `Option[Int]` list uses raw struct slots. Runtime
`stream_list_pull` returns the raw slot pointer through `blorp_list_get`, and
`blorp_stream_find` wraps that pointer directly in outer `Some`. The nested
matcher expects a StructBox and skips `sizeof(blorp_Object)`, so producer and
consumer disagree. Fixing that physical/ownership boundary is separate work;
inline-struct stream hit transport is **not validated or declared safe** by
this prerequisite. No test workaround or runtime policy change hides it.

The initial nonempty miss passes normally after the bridge but also fails
ASan: eager callback argument unboxing applies the object-header offset to a
raw inline slot even when the predicate ignores its argument. Its independent
logs are `miss-normal/` and `miss-sanitize/` in the same packet. Nonempty miss
transport is therefore also **not validated or declared safe**. The accepted
fixture uses an empty typed stream to exercise only the singleton contract;
the runner owns exact f42 red confirmation and repaired normal/sanitized gates.

Retained empty-hit C SHA256:

- f42: `e6c072c9490c47b1fc136769d49e8dba50f6a378011329799ba3996523c52d0a`
- repair: `db558f42f92e94df2e1daa2d162c5a64f3f8faa1b0578b176efa4a296ef4d249`
