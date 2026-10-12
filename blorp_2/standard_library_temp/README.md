# Temporary input library

These modules are compiled by Blorp 2 for input programs. They are separate
from the host library that builds the pilot compiler.

`int.brp` retains a commented copy of `standard_library/src/int.brp`, with its
revision and SHA256 recorded in the file. Concrete `add`, `subtract`, `multiply`,
`divide`, `remainder` and `to_string` are active, lifted from trait implementations
where needed. The Float adapter exposes those same concrete names for Float64.
`Int` and `Float` remain declared once in `src/prelude_temp.brp`. Other
declarations are enabled only as their features enter the supported subset.
One plus/minus glyph in an upstream comment is
transliterated to `+/-` because pilot comment text is currently ASCII.

Pass this directory explicitly with `--library-root
blorp_2/standard_library_temp`. Bare `int: add` imports resolve here; relative
imports still resolve beside their importer. There is no host-library fallback.

`io.brp` retains the upstream `standard_library/src/io.brp` revision and SHA256
beside its commented source. Its active `print(String) -> Void` is concrete and
impure, mapped to the closed `string.print` operation. It borrows the String,
writes every byte and appends LF. `read_line() -> Option[String]` is impure,
removes one LF and preserves other bytes, returning an owned String on success.
Other IO declarations remain commented out. `Void` is declared once in the
target prelude.

The io adapter also transliterates the upstream em dash in a comment to ASCII;
the recorded upstream SHA256 still identifies the unmodified original.

`option.brp` and `bool.brp` provide ordinary fixed unions. Select constructors
explicitly with `Option(Some, None)` or `Bool(True, False)`. The String adapter
exposes strict counted-byte `parse_int`, `parse_float` and `equals` operations.
Their builtin bodies explicitly bind the ordinary result constructors; names
and declaration order have no hidden runtime meaning. Copied upstream source
remains commented, with provenance beside each adapter. Traits and FFI remain
inactive.

The [calculator plan](../CALCULATOR_COMPLETION_PLAN.md) and
[Float design](../FLOAT_PLAN.md) define deliberate conversion and arithmetic
adaptations. The copied host implementation is a reference, not an implicit
source of semantics or runtime dependencies.
