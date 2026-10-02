# Stream and resource carriers in declarations are unchecked

Status: open.

The Guide (`with` Resource Scopes) says one-shot streams, resource sources and
resource handles cannot be hidden in ordinary carriers: not in type aliases,
record fields, union payloads, globals, or ordinary function signatures such as
`Option[Stream[T]]` or `Result[FallibleStream[...], E]`, and function values
cannot hide them behind `() -> Option[...]`. The checker enforces these rules
only for local bindings and value construction (`check_*_ordinary_binding` and
the `cannot be stored in` checks in `stage_06_typecheck/infer.brp`) and, for
resource handles alone, for direct function parameters and returns
(`validate_resource_signature_boundary` in `stage_06_typecheck/decl.brp`).
Type alias, record, union and global declarations are never checked, and
signatures only for direct resource handles, so all of these are accepted:

```
import:
	stream: Stream, ResourceSource

type alias MaybeStream = Option[Stream[Int]]
record Holder {stream: Stream[Int]}
union Box:
	HasStream(Stream[Int])

func consume(maybe: Option[Stream[Int]]) -> Int:
	0

func make_source() -> Option[ResourceSource[Int, String]]:
	None

S: Option[Stream[Int]] = None
```

Generic wrappers are not judged after substitution either
(`type alias HiddenStream = Box[Stream[Int]]` with `type alias Box[T] = Option[T]`).

Where a body also misuses the value, the program is rejected only for the
incidental body error. For example
`func bad(path: String) -> Result[FallibleStream[Bytes, IOError], IOError]`
reports ``scoped resource-derived value cannot be passed to ordinary call `Ok` ``
instead of the signature error, and `S: Stream[Int] = from_list([1, 2, 3])`
reports `compile-time constant evaluation does not support impure function calls
yet` instead of rejecting a global stream.

## Where to look

- `validate_resource_signature_boundary` (`stage_06_typecheck/decl.brp`): the
  signature check covers resource handles only; extend it to the stream and
  resource-source shapes the binding checks already use
  (`type_contains_resource_capability`, `OneShotStreamShape`,
  `ResourceSourceShape`).
- Type alias, record, union and global declaration checking: no carrier check
  runs there today.

## Fixtures

Unmarked should_fail fixtures under
`blorp/test/compiler/stage_06_typecheck/fixtures/typecheck/should_fail/` that
this gap leaves failing (47):

- accepted outright (38): `fallible_stream_option_function_generic_record_type_alias`,
  `fallible_stream_option_function_generic_union_type_alias`,
  `fallible_stream_option_function_param`, `fallible_stream_record_field_type`,
  `file_resource_channel_type_alias`, `file_resource_function_record_field`,
  `file_resource_function_type_alias`, `file_resource_function_union_payload`,
  `file_resource_option_type_alias`, `file_resource_record_field`,
  `file_resource_union_payload`, `resource_source_direct_alias_option_type_alias`,
  `resource_source_function_param`, `resource_source_function_return`,
  `resource_source_generic_alias_carrier_type_alias`,
  `resource_source_option_callback_param`,
  `resource_source_option_function_generic_record_type_alias`,
  `resource_source_option_function_generic_union_type_alias`,
  `resource_source_option_function_record_field`,
  `resource_source_option_function_type_alias`,
  `resource_source_option_function_union_payload`,
  `resource_source_option_type_alias`, `resource_source_record_field`,
  `resource_source_union_payload`, `stream_generic_alias_carrier_function_param`,
  `stream_generic_alias_carrier_function_return`,
  `stream_generic_alias_carrier_type_alias`, `stream_option_callback_param`,
  `stream_option_function_generic_record_type_alias`,
  `stream_option_function_generic_union_type_alias`,
  `stream_option_function_param`, `stream_option_function_record_field`,
  `stream_option_function_return`, `stream_option_function_type_alias`,
  `stream_option_function_union_payload`, `stream_option_type_alias`,
  `stream_record_field_type`, `stream_union_payload_type`;
- rejected only for an incidental body error (9): `file_resource_chunks_escape`,
  `file_resource_chunks_local_escape`, `tcp_chunks_stream_escape`,
  `tls_chunks_stream_escape`, `udp_datagrams_stream_escape`,
  `stream_generic_record_field_storage`, `stream_record_update_storage`,
  `stream_tuple_concurrent_capture`, `stream_global_binding`.

## Acceptance

Each fixture above passes `blorp/test/lib/run_blorp_check_fixtures.py` with the
diagnostic it pins (or an updated, equally specific one with a help line) and
carries `-- RUN-BLORP-CHECK`; `expected_blorp_check_fixture_count` in
`scripts/test` is raised to match.
