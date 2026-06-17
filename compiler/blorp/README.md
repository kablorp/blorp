# blorp self-hosting compiler code

This directory contains Blorp modules that are part of the compiler
implementation. These files should be written as library code with focused
TestSuite coverage under `compiler/blorp/tests`.

As the compiler migration progresses, prefer contiguous Blorp-owned pipeline
slices with one OCaml transfer point at the boundary. Avoid adding standalone
wrapper programs or parallel tool directories unless the production compiler
actually needs that interface.
