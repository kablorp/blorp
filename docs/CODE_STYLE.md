# Code Shape

How compiler code should be shaped: what a function takes, when a function or
binding earns its place, and how long names should be. These rules apply to
new code and to reviews. The discovery stage gets a cleanup pass against them
once its redesign (`DISCOVERY_REDESIGN.md`) lands.

## 1. Narrowest parameters

A function takes what its task reads, not the container that happens to hold
it. If it needs a span, it takes a `Span`, not the builder or the module.
Passing a whole record to read one field hides what the function depends on
and ties it to that record's shape.

## 2. A function must earn its existence

A function earns its place when it does at least one of these:

- names a concept that is used in more than one place;
- is a recursion boundary or a unit you test directly;
- hides a representation behind an opaque type;
- is part of a module's public interface.

If its name tells the reader no more than a comment would, delete it. Write
the comment above one line in the caller instead.

```
-- before
private pure func in_loop_body(context: LoopContext) -> Bool:
	context == InLoopBody
...
if in_loop_body(context):

-- after
if context == InLoopBody:
```

## 3. Single-use functions are suspect

A function called from one place is inlined unless it meets a reason in
rule 2. Splitting a long function into named steps is fine when each step is
a real concept. It is not fine when the pieces only make sense together.

## 4. Excess bindings are suspect

Do not bind a value that is used once on the next line, unless the name
explains something the expression does not. Do not bind a value only to
return it. Keep a binding when it names an intermediate the reader needs, or
when it is read more than once.

## 5. Do not over-engineer

No generic helpers, traits or configuration for a single caller, and no
layers that only forward. Add the abstraction when the second or third use
appears, not before. Prefer a plain `match` to a dispatch table, and a plain
loop to a visitor.

## 6. Names are descriptive, not long

A name states the concept or the result, not how it is computed. Scope sets
the length: a two-line loop can use `i`, a module export needs a full name,
and nothing needs a sentence. If a name needs a sentence, the function is
probably doing two things. See also "Naming" in `AGENTS.md`.

## Where these rules do not apply

- Accessors and constructors of opaque types: they exist to hold the boundary.
- Test helpers.
- A stage's public interface.
