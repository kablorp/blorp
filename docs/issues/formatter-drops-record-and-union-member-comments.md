# Formatter deletes comments inside record and union bodies

Status: open.

`blorp format` deletes every `--` comment written between the members of a
`record` body or a `union` body: before the first member, between members and
before the last. `---` docstrings on the declaration itself survive. Nothing
reports the loss, and the output is a fixpoint, so `format --check` passes on
the stripped file.

```blorp
record A {
	-- before the first field
	first: Int,
	-- before a middle field
	middle: Int,
	-- before the last field
	last: Int
}


union U:
	-- before the first variant
	One
	-- before a later variant
	Two(Int)
```

formats to

```blorp
record A {
	first: Int,
	middle: Int,
	last: Int
}


union U:
	One
	Two(Int)
```

## Impact

The bulk reformat that followed the packed import constructor lists left out
19 files under `blorp/src` and `standard_library/src` because formatting them
would have deleted comments of this kind, for example the comments on the
`DiscoveryNames` variants in `blorp/src/compiler/pipeline.brp`, on
`FreshHoistedName.ordinal` in `stage_09_core/closure.brp` and on the
`compact_c` field in `blorp/src/lib/build_artifact.brp`. Those files keep their
old formatting until this is fixed. They are the files under those two trees
for which `bin/blorp format` changes the text of a `--` comment line;
`backend_helper_kind_mapping.brp` was left out for the import-block comment
issue (`formatter-moves-import-comments.md`) instead.

## Where to look

- Record field and union variant projection in
  `blorp/src/format/projection.brp`: `plain_record_field` and
  `located_record_fields` (around line 1223) already take member comments
  for some record shapes, so find why these reach the document without them;
  the union path builds `TypeVariant` values, which carry no comments.
- `type_variant_document` and the record body rendering in
  `blorp/src/format/engine/declaration_documents.brp`.
- Expression comments were kept by 9320b8ef9 through member comment
  locations; declaration bodies need the same.

## Acceptance

- A should_pass fixture with comments before the first, a middle and the last
  member of a record, a struct and a union is a fixpoint and keeps every
  comment beside its member.
- Formatting the 19 left-out files changes no `--` comment text, and they can
  then be reformatted.
