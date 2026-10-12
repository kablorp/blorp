# Temporary input library

These modules are compiled by Blorp 2 for input programs. They are separate
from the host library that builds the pilot compiler.

`int.brp` retains a commented copy of `standard_library/src/int.brp`, with its
revision and SHA256 recorded in the file. Only the concrete `add` function is
active, lifted from the `Addable` implementation. `Int` remains declared once in
`src/prelude_temp.brp`. Other declarations are enabled only as their features
enter the supported subset. One plus/minus glyph in an upstream comment is
transliterated to `+/-` because pilot source is currently ASCII.

Pass this directory explicitly with `--library-root
blorp_2/standard_library_temp`. Bare `int: add` imports resolve here; relative
imports still resolve beside their importer. There is no host-library fallback.
