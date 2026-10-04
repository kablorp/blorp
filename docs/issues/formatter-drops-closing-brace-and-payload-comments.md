# Formatter drops comments after a closing brace and inside variant payloads

Status: open.

Comments inside record, fixed record, union and enum bodies are kept, but two
neighbouring places still lose or move them. Both behave the same before and
after member comments were kept, so neither is a regression from that change.

```blorp
record Q { -- header Q
	a: Int
} -- after Q


record P { a: Int, b: Int } -- after P


union U:
	A(
		Int, -- payload eol
		String,
	)
	B
```

formats to

```blorp
record Q { -- header Q
	a: Int
}


record P { -- after P
	a: Int,
	b: Int
}


union U:
	A(Int, String)
	B
```

- **After the closing `}`.** `-- after Q` is deleted. On a one-line record,
  `-- after P` moves into the header, where it reads as a note on the header.
- **Inside a variant payload.** A comment between the parts of a multi-line
  payload is deleted when the payload is joined onto one line.

## Where to look

- `blorp/src/format/projection.brp`: the record header comment path (how the
  comment on the `{` line is chosen), `project_type_variant` and
  `project_type_expr`, which build `TypeExpression` values without comments.
- `blorp/src/format/engine/declaration_documents.brp`:
  `record_declaration_document`, and the type documents in
  `blorp/src/format/engine/type_documents.brp`.
- Member comments use `collection_item_comments` and
  `commented_member_document`; a trailing comment after `}` is a
  `LineSuffix` on the closing brace.

## Acceptance

- A should_pass fixture with each shape above is a fixpoint and keeps every
  comment where it was written (after `}` stays after `}`; a payload comment
  keeps the payload on several lines).
