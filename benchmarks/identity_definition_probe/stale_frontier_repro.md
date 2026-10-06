# Exploratory stale frontier reproduction

This contextual source was removed from the owning Core suite while the checked
publication boundary was being investigated. It is not a request for a Stage 8
row-maximum guard. Native execution has not yet been performed. The raw-frontier
probe illustrates the current editable graph view; the future publication slice
needs tests that reject certifying an edited view and supplying an independent
frontier to Core.

```blorp
private func core_graph_rejects_frontier_before_admitted_definition(
	module_table: ModuleTable,
	target_id: ModuleId,
) -> Option[Bool]:
	initial = definition_index_empty(definition_index_initial_seed(ENV_EMPTY), module_table)
	inserted ?= insert_core_test_callable(initial, module_table, target_id, "answer")
	definitions = definition_index_definition_table(inserted[0])
	admitted_id = inserted[1]
	function_info: TypedFunctionInfo = {
		decl = parsed_function_decl(),
		callable_id = Some(admitted_id),
		effective_type_params = [],
		param_types = [int_type()],
		source_return_type = Some(int_type()),
		semantic_return_type = int_type(),
		body = Some(int_expr("2"))
	}
	program: TypedProgram = {
		source = fixture_source_file(),
		decls = [TypedFunctionDecl(function_info)],
		diagnostics = [],
		type_definitions = [],
		type_references = []
	}

	-- The graph/table is valid; only the independently supplied raw frontier is
	-- stale. Passing the already-admitted ID as the next ID must fail here,
	-- before lowering creates a program with an allocator collision.
	match prepare_core_graph(
		definitions,
		target_id,
		program,
		core_graph_modules(definitions, [], None),
		admitted_id,
	):
		Err(CoreGraphModuleTableError(message)):
			Some(message == "Core graph definition allocation frontier does not follow its source rows")
		_:
			Some(False)


func test_core_graph_rejects_frontier_before_admitted_definition() -> Bool:
	match core_graph_test_module_domain(["target"]):
		Some((module_table, [target_id])):
			core_graph_rejects_frontier_before_admitted_definition(module_table, target_id).get_or(False)
		_:
			False


```
