# Formatter moves comments out of import blocks

Status: open.

`blorp format` takes every `--` comment written inside an `import:` block,
whether after a symbol, after a wrapped constructor list or between
constructors, and prints it after the whole block, above the first
declaration. The output is stable on later passes, so `format --check`
accepts the moved comments and nothing reports the loss of placement.

```blorp
import:
	stage_04_modules/frontend_graph_service:
		FrontendDiscoveryError(
			FrontendDiscoveryGraphFailed,
			FrontendDiscoveryIdentityConflict, -- inside the constructor list
			FrontendDiscoveryImportCaseMismatch,
		), -- after the constructor list
		FrontendSourceCandidate,
		frontend_source_location, -- after a plain symbol
		validated_frontend_graph_for_modules,


func main(args: List[String]) -> Int:
	0
```

formats to

```blorp
import:
	stage_04_modules/frontend_graph_service:
		FrontendDiscoveryError(
			FrontendDiscoveryGraphFailed, FrontendDiscoveryIdentityConflict,
			FrontendDiscoveryImportCaseMismatch,
		),
		FrontendSourceCandidate,
		frontend_source_location,
		validated_frontend_graph_for_modules,


-- inside the constructor list
-- after the constructor list
-- after a plain symbol
func main(args: List[String]) -> Int:
	0
```

The same happens to a short import that the formatter joins onto one line
(`json: JsonValue(JsonNull, JsonBool), as_bool, ...`), and it happened before
import constructor lists were packed: the formatter at 55af98331 produces the
same relocation with one constructor per line.

## Where to look

- Import symbols are projected without comments:
  `project_import_symbol` and `project_import_item` in
  `blorp/src/format/projection.brp` (around line 2702) carry names, aliases
  and constructors only, so the comments fall through to the next member's
  leading comments.
- `import_symbol_document` and `import_item_document` in
  `blorp/src/format/engine/declaration_documents.brp` would need to place a
  trailing comment as a `LineSuffix` on its symbol. The layout `Fill` that
  packs constructor lists already ends a line after an item with a pending
  line suffix (`render_fill` in `document_layout.brp`), so a comment on a
  constructor can stay beside it.
- Symbols are sorted by name before rendering, so a comment has to travel
  with its symbol, not with its source position.

## Acceptance

- A should_pass fixture with comments after a plain symbol, after a wrapped
  constructor list and after a constructor inside one is a fixpoint, with each
  comment beside the symbol it followed.
- Formatting a file whose import block has comments keeps them inside the
  block.
