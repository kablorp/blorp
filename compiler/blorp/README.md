# blorp self-hosting compiler code

This directory contains Blorp modules that are part of the compiler
implementation. These files should be written as library code with focused
TestSuite coverage under `compiler/blorp/tests`.

As the compiler migration progresses, prefer contiguous Blorp-owned pipeline
slices with one OCaml transfer point at the boundary. Avoid adding standalone
wrapper programs or parallel tool directories unless the production compiler
actually needs that interface.

Renderer argument bundles currently use records because they carry C snippet
strings, template enums, and other managed/compiler values. Do not mechanically
convert these to structs unless struct fields can represent those types; current
struct fields are limited to primitive values and other structs.
