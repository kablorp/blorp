# Resource acquisitions are accepted as ordinary values

Status: open.

The Guide (`?=` Bindings and `with` Resource Scopes) says a fallible
acquisition that contains a resource, such as `Result[FileReader, IOError]`, is
not an ordinary value: it must be consumed by `with name ?= ...:` so cleanup is
installed before the handle is exposed. Direct `?=` cannot unwrap it, and a
resource source must not be discarded. The checker accepts all of these:

```
import:
	fs: IOError, open_read, read_text

func bad(path: String) -> Result[Int, IOError]:
	result = open_read(path)              -- bound to an ordinary variable
	_ = open_read(path)                   -- discarded
	opener = open_read                    -- function value returning a resource
	reader_op = read_text                 -- function value taking a resource
	match open_read(path):                -- matched outside `with`
		Ok(_): Ok(1)
		Err(err): Err(err)
```

```
import:
	fs: IOError, open_read

func bad(path: String) -> Result[Int, IOError]:
	reader ?= open_read(path)             -- direct ?= exposes the handle with no cleanup
	Ok(1)
```

The same holds for `net/tcp` and `net/udp` acquisitions, for
`Channel[FileReader]` locals, and for discarding
`Tcp.connections_stop_on_error(listener)` either as a statement or through
`_ =`. Each lets a resource handle outlive or bypass the cleanup edge the `with`
scope exists to install.

## Where to look

`check_stream_ordinary_binding` and `check_resource_source_ordinary_binding` in
`stage_06_typecheck/infer.brp` already reject streams and resource sources in
ordinary bindings and function values. There is no equivalent for resource
handles inside acquisition carriers, for discards (`infer_discard_assign_expr`
and expression statements), for `match` scrutinees, or for direct `?=`.

## Fixtures (14)

Under `blorp/test/compiler/stage_06_typecheck/fixtures/typecheck/should_fail/`:
`file_resource_acquisition_annotated_local_binding`,
`file_resource_acquisition_discard`,
`file_resource_acquisition_function_local_binding`,
`file_resource_acquisition_local_binding`, `file_resource_channel_local_binding`,
`file_resource_lambda_return_binding`, `file_resource_match_acquisition_result`,
`file_resource_operation_function_local_binding`,
`tcp_resource_match_acquisition_result`, `udp_resource_acquisition_discard`,
`resource_source_discard_assignment`, `resource_source_discard_statement`.
Under `blorp/test/compiler/stage_06_typecheck/infer_fixtures/infer/should_fail/`:
`file_resource_direct_question_bind`, `udp_resource_direct_question_bind`.

## Acceptance

Each fixture is rejected at typecheck with the diagnostic it pins (or an equally
specific one with a help line pointing at `with name ?= ...:`), passes
`run_blorp_check_fixtures.py`, and is marked `-- RUN-BLORP-CHECK`.
