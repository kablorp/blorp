#!/usr/bin/env python3
"""Guard Stage 06 declaration ownership and phase boundaries."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[5]
DECL = ROOT / "blorp/src/compiler/stage_06_typecheck/decl.brp"
INFER = ROOT / "blorp/src/compiler/stage_06_typecheck/infer.brp"
ENV = ROOT / "blorp/src/compiler/stage_06_typecheck/type_system/env.brp"
FRONTEND_PROFILE_FIXTURE = (
    ROOT / "blorp/benchmark/compiler/compiler_frontend_declaration_catalog_profile_fixture.brp"
)
ALIAS_GRAPH = (
    ROOT / "blorp/src/compiler/stage_06_typecheck/headers/accepted_alias_graph.brp"
)
ALIAS_AUTHORITY = (
    ROOT / "blorp/src/compiler/stage_06_typecheck/type_system/accepted_alias_authority.brp"
)
RECORD_GRAPH = (
    ROOT / "blorp/src/compiler/stage_06_typecheck/headers/accepted_record_graph.brp"
)
UNION_GRAPH = (
    ROOT / "blorp/src/compiler/stage_06_typecheck/headers/accepted_union_graph.brp"
)
TYPE_HEADER_INSTALL = (
    ROOT / "blorp/src/compiler/stage_06_typecheck/headers/type_header_install.brp"
)
TYPE_HEADER_GRAPH = (
    ROOT / "blorp/src/compiler/stage_06_typecheck/headers/type_header_graph.brp"
)
HEADER_TYPE_RESOLUTION = (
    ROOT / "blorp/src/compiler/stage_06_typecheck/headers/type_resolution.brp"
)
GLOBAL_HEADER_COMPLETION = (
    ROOT
    / "blorp/src/compiler/stage_06_typecheck/headers/global_header_completion.brp"
)
DECLARATION_SKELETON = (
    ROOT / "blorp/src/compiler/stage_06_typecheck/headers/declaration_skeleton.brp"
)
IMPLEMENTATION_HEADERS = (
    ROOT / "blorp/src/compiler/stage_06_typecheck/headers/implementation_headers.brp"
)
DEFINITION_IDENTITY = (
    ROOT / "blorp/src/compiler/stage_06_typecheck/graph/definition_identity.brp"
)
DEFINITION_INDEX = (
    ROOT / "blorp/src/compiler/stage_06_typecheck/graph/definition_index.brp"
)
DEFINITION_TABLE_STORAGE = (
    ROOT / "blorp/src/compiler/stage_06_typecheck/graph/definition_table_storage.brp"
)
TYPE_IDENTITY = (
    ROOT / "blorp/src/compiler/stage_06_typecheck/graph/type_identity.brp"
)
RECORD_AUTHORITY = (
    ROOT
    / "blorp/src/compiler/stage_06_typecheck/type_system/accepted_record_authority.brp"
)
UNION_AUTHORITY = (
    ROOT
    / "blorp/src/compiler/stage_06_typecheck/type_system/accepted_union_authority.brp"
)
SEMANTIC_OCCURRENCE = (
    ROOT / "blorp/src/compiler/stage_06_typecheck/graph/semantic_occurrence.brp"
)
GLOBAL_AUTHORITY = (
    ROOT
    / "blorp/src/compiler/stage_06_typecheck/type_system/accepted_global_authority.brp"
)
CALLABLE_AUTHORITY = (
    ROOT
    / "blorp/src/compiler/stage_06_typecheck/type_system/accepted_callable_authority.brp"
)
TRAIT_IMPLEMENTATION_AUTHORITY = (
    ROOT
    / "blorp/src/compiler/stage_06_typecheck/type_system/accepted_trait_implementation_authority.brp"
)
IMPORT_BINDING = (
    ROOT / "blorp/src/compiler/stage_06_typecheck/modules/import_binding.brp"
)
MODULE_VIEW = (
    ROOT / "blorp/src/compiler/stage_06_typecheck/modules/module_view.brp"
)
MODULE_BINDING = (
    ROOT / "blorp/src/compiler/stage_06_typecheck/modules/module_binding.brp"
)
TYPECHECK_STATE = ROOT / "blorp/src/compiler/stage_06_typecheck/state.brp"
TYPE_RESOLUTION = (
    ROOT / "blorp/src/compiler/stage_06_typecheck/type_system/type_resolution.brp"
)
SOURCE_NAME_TABLE = (
    ROOT / "blorp/src/compiler/stage_06_typecheck/graph/source_name_table.brp"
)
SEMANTIC_CATALOG = (
    ROOT
    / "blorp/src/compiler/stage_06_typecheck/type_system/accepted_semantic_catalog.brp"
)
META_IDENTITY = ROOT / "blorp/src/compiler/stage_06_typecheck/type_system/meta_identity.brp"


def unchecked_meta_session_sources(source_root: Path, allowed_owners: set[Path]) -> list[str]:
    """Keep raw-index mappers and token mint behind checked table owners."""
    unchecked: list[str] = []
    for path in source_root.rglob("*.brp"):
        if path in allowed_owners:
            continue
        source = path.read_text(encoding="utf-8")
        code = re.sub(r"(?m)--[^\n]*", "", source)
        if re.search(
            r"\b(?:meta_body_session_from_validated_key|meta_body_session|"
            r"meta_global_session|meta_module_session|new_compilation_run_token)\s*\(",
            code,
        ):
            unchecked.append(str(path.relative_to(ROOT)))
    return sorted(unchecked)


class DeclarationBoundaryTests(unittest.TestCase):

    def test_meta_identity_does_not_depend_on_semantic_graph_index(self) -> None:
        source = META_IDENTITY.read_text(encoding="utf-8")
        imports = source.split("private record", 1)[0]
        self.assertNotIn("graph/definition_index", imports)

        storage = DEFINITION_TABLE_STORAGE.read_text(encoding="utf-8")
        storage_imports = storage.split("enum DefinitionRowKind", 1)[0]
        self.assertNotIn("type_system", storage_imports)

    def test_definition_table_storage_mutation_is_index_owned(self) -> None:
        constructor = re.compile(
            r"\b(?:definition_table_from_rows|definition_table_append_row|"
            r"definition_table_with_module_table)\s*\("
        )
        allowed = {DEFINITION_TABLE_STORAGE, DEFINITION_INDEX}
        callers = []
        for path in (ROOT / "blorp/src").rglob("*.brp"):
            if path in allowed:
                continue
            source = re.sub(r"(?m)--[^\n]*", "", path.read_text(encoding="utf-8"))
            if constructor.search(source):
                callers.append(str(path.relative_to(ROOT)))
        self.assertEqual(callers, [])


    def test_raw_meta_session_issuance_has_checked_production_owner(self) -> None:
        decl_source = DECL.read_text(encoding="utf-8")
        decl_code = re.sub(r"(?m)--[^\n]*", "", decl_source)
        bound_run = re.search(
            r"func new_definition_meta_run\(.*?(?=\n\n(?:private )?(?:(?:pure )?func|record|union|enum)\b)",
            decl_code,
            re.DOTALL,
        )
        checked_body = re.search(
            r"pure func body_check_context_meta_session\(.*?(?=\n\n(?:private )?(?:(?:pure )?func|record|union|enum)\b)",
            decl_code,
            re.DOTALL,
        )
        body_projection = re.search(
            r"private pure func checked_body_meta_session\(.*?(?=\n\n(?:private )?(?:(?:pure )?func|record|union|enum)\b)",
            decl_code,
            re.DOTALL,
        )
        issued_body = re.search(
            r"pure func body_check_context_issued_meta_session\(.*?(?=\n\n(?:private )?(?:(?:pure )?func|record|union|enum)\b)",
            decl_code,
            re.DOTALL,
        )
        checked_module = re.search(
            r"pure func prepared_module_scope_meta_session\(.*?(?=\n\n(?:private )?(?:(?:pure )?func|record|union|enum)\b)",
            decl_code,
            re.DOTALL,
        )
        checked_global = re.search(
            r"pure func global_header_completion_plan_meta_session_at\(.*?(?=\n\n(?:private )?(?:(?:pure )?func|record|union|enum)\b)",
            decl_code,
            re.DOTALL,
        )
        self.assertIsNotNone(bound_run)
        self.assertIsNotNone(checked_body)
        self.assertIsNotNone(body_projection)
        self.assertIsNotNone(issued_body)
        self.assertIsNotNone(checked_module)
        self.assertIsNotNone(checked_global)
        self.assertEqual(len(re.findall(r"\bnew_compilation_run_token\s*\(", decl_code)), 1)
        self.assertEqual(len(re.findall(r"\bmeta_body_session\s*\(", decl_code)), 1)
        self.assertEqual(
            len(re.findall(r"\bmeta_body_session_from_validated_key\s*\(", decl_code)),
            1,
        )
        self.assertEqual(len(re.findall(r"\bmeta_module_session\s*\(", decl_code)), 1)
        self.assertEqual(len(re.findall(r"\bmeta_global_session\s*\(", decl_code)), 1)
        self.assertIn("new_compilation_run_token()", bound_run.group(0))
        self.assertIn("checked_body_meta_session(", checked_body.group(0))
        self.assertIn("definition_tables_share_provenance(", body_projection.group(0))
        self.assertIn("meta_body_session(", body_projection.group(0))
        self.assertIn("meta_body_session_from_validated_key(", issued_body.group(0))
        self.assertIn("definition_tables_share_provenance(", checked_module.group(0))
        self.assertIn("meta_module_session(", checked_module.group(0))
        self.assertIn("definition_tables_share_provenance(", checked_global.group(0))
        self.assertIn("global_header_completion_plan_header_at(", checked_global.group(0))
        self.assertIn("meta_global_session(", checked_global.group(0))
        self.assertEqual(
            unchecked_meta_session_sources(ROOT / "blorp/src", {DECL, META_IDENTITY}),
            [],
        )

    def test_import_decl_selection_streams_explicit_ordered_decisions(self) -> None:
        source = MODULE_BINDING.read_text(encoding="utf-8")
        self.assertIn("private union ImportDeclDecision:", source)
        self.assertNotIn("private record OrderedImportDeclDecision {", source)
        self.assertNotIn("private pure func plan_program_import_decisions(", source)
        for outcome in (
            "ImportDeclMissing",
            "ImportDeclAmbiguous(List[String])",
            "ImportDeclForbiddenPackage",
            "ImportDeclDuplicateModule",
            "ImportDeclSelected(ImportableModuleSurface)",
        ):
            self.assertIn(outcome, source)
        self.assertIn("private pure func decide_import_decl(", source)
        self.assertIn("current = apply_import_decl_decision(current, import_decl, decision)", source)

    def test_graph_imports_publish_after_scope_local_admission(self) -> None:
        module_view = MODULE_VIEW.read_text(encoding="utf-8")
        state = TYPECHECK_STATE.read_text(encoding="utf-8")
        module_binding = MODULE_BINDING.read_text(encoding="utf-8")
        self.assertIn("opaque type GraphImportAdmission", module_view)
        self.assertIn("graph_import_admission_finish(", module_view)
        self.assertIn("typecheck_state_begin_graph_import_admission(", state)
        self.assertIn("typecheck_state_finish_graph_import_admission(", state)
        self.assertIn("typecheck_state_begin_graph_import_admission(current)", module_binding)

    def test_graph_selective_names_have_one_ordered_binding_owner(self) -> None:
        source = MODULE_VIEW.read_text(encoding="utf-8")
        self.assertIn("private pure func graph_imported_names_from_bindings(", source)
        self.assertIn("GraphSelectiveDefinitionBinding(local_name, _, _)", source)
        self.assertIn("GraphSelectiveTraitMethodBinding(local_name, _, _, _)", source)
        self.assertIn("private union BoundImportRequest:", source)
        self.assertIn("candidate_accepted_imports: List[BoundImportRequest]", source)
        self.assertIn("standalone_import_bindings: List[ImportBinding]", source)
        self.assertNotIn("\n\timport_bindings: List[ImportBinding]", source)
        self.assertNotIn(
            "imported_names = representation.imported_names.append(binding),\n"
            "\t\t\t\timport_bindings = representation.import_bindings.append(import_binding)",
            source,
        )

    def test_accepted_nominal_imports_join_exact_candidate_ids(self) -> None:
        alias_source = ALIAS_GRAPH.read_text(encoding="utf-8")
        union_source = UNION_GRAPH.read_text(encoding="utf-8")
        selected_constructor = re.search(
            r"private pure func selected_constructor_binding\(.*?\n\tresult",
            union_source,
            re.DOTALL,
        )

        self.assertNotIn("imported_bindings_by_module", alias_source)
        self.assertNotIn("imported_local_names_by_original_name", alias_source)
        self.assertIn("definition_id_runtime_value(definition_id)", alias_source)
        self.assertIn("module_ids_equal(owner, candidate.module_id)", alias_source)

        self.assertNotIn("bound_module_graph_find_canonical_path", union_source)
        self.assertNotIn("find_public_union_header", union_source)
        self.assertIn("definition_id_runtime_value(definition_id)", union_source)
        self.assertIn("module_ids_equal(owner, candidate.module_id)", union_source)
        self.assertIsNotNone(selected_constructor)
        self.assertIn(
            "type_header_graph_find_union_for_constructor",
            selected_constructor.group(0),
        )
        self.assertNotIn("for variant in", selected_constructor.group(0))

    def test_imported_type_alias_installation_does_not_rebuild_graph_bindings(self) -> None:
        resolution_source = HEADER_TYPE_RESOLUTION.read_text(encoding="utf-8")
        install_source = TYPE_HEADER_INSTALL.read_text(encoding="utf-8")

        self.assertNotIn("module_view_import_bindings", resolution_source)
        self.assertIn(
            "module_view_standalone_imported_type_alias_names",
            resolution_source,
        )
        self.assertIn("module_view_accepted_alias_authority", install_source)

    def test_annotation_import_lookup_uses_keyed_graph_view(self) -> None:
        source = (ROOT / "blorp/src/compiler/stage_06_typecheck/headers/type_resolution.brp").read_text(
            encoding="utf-8"
        )
        self.assertIn("module_view_find_imported_name(view, name)", source)
        self.assertIn("resolve_imported_type_aliases_from_view(", source)
        self.assertNotIn("module_view_imported_names(", source)
        annotation = source.split("pure func canonical_annotation_type(", 1)[1].split(
            "pure func canonical_function_annotation_type(", 1
        )[0]
        self.assertNotIn("module_view_imported_names(state.module_view)", annotation)

    def test_graph_module_view_has_one_scope_issued_occupancy_relation(self) -> None:
        view_source = MODULE_VIEW.read_text(encoding="utf-8")
        name_source = SOURCE_NAME_TABLE.read_text(encoding="utf-8")
        resolution_source = TYPE_RESOLUTION.read_text(encoding="utf-8")

        self.assertIn("opaque type GraphSourceNameTable", name_source)
        self.assertIn(
            "graph_source_name_table_from_source_names(module_table, source_name_table(candidates))",
            name_source,
        )
        self.assertIn("opaque type GraphModuleNameScope", name_source)
        self.assertIn("issuer: GraphModuleNameScope", view_source)
        self.assertIn(
            "rows_by_source_name_index: Dict[Int, BoundNameOccupancy]",
            view_source,
        )
        self.assertNotIn("rows: List[BoundNameRow]", view_source)
        self.assertNotIn("row_index_by_source_name: Dict[Int, Int]", view_source)
        self.assertNotIn("module_aliases: List[ModuleAliasBinding]", view_source)
        self.assertNotIn("module_aliases = next.module_aliases.append(", view_source)
        self.assertNotIn("module_view_module_aliases", view_source)
        self.assertIn(
            "GraphModuleAliasLookup(Option[ModuleTable], ModuleView)",
            resolution_source,
        )
        self.assertIn("graph_alias_view_matches_owner", resolution_source)
        self.assertIn(
            "BoundAliasAndSelectiveName(BoundCandidateRowId, ModuleId, BoundCandidateRowId, ModuleId, Int)",
            view_source,
        )
        self.assertNotIn(
            "BoundAliasAndSelectiveName(BoundCandidateRowId, ModuleId, BoundCandidateRowId, BoundImportedNamePayload)",
            view_source,
        )
        for displaced_map in (
            "graph_module_aliases_by_source_name_id",
            "graph_imported_names_by_source_name_id",
            "graph_local_names_by_source_name_id",
        ):
            self.assertNotIn(displaced_map, view_source)

    def test_graph_trait_method_binding_retains_overlapping_definition_ids(self) -> None:
        source = IMPORT_BINDING.read_text(encoding="utf-8")
        callable_authority = (
            ROOT
            / "blorp/src/compiler/stage_06_typecheck/type_system/accepted_callable_authority.brp"
        ).read_text(encoding="utf-8")
        global_authority = (
            ROOT
            / "blorp/src/compiler/stage_06_typecheck/type_system/accepted_global_authority.brp"
        ).read_text(encoding="utf-8")
        ctfe_context = (
            ROOT / "blorp/src/compiler/stage_07_ctfe/context.brp"
        ).read_text(encoding="utf-8")
        compiler_pipeline = (
            ROOT / "blorp/src/compiler/pipeline.brp"
        ).read_text(encoding="utf-8")

        self.assertIn(
            "GraphSelectiveTraitMethodBinding(String, ModuleId, String, List[DefinitionId])",
            source,
        )
        for consumer in (
            callable_authority,
            global_authority,
            ctfe_context,
            compiler_pipeline,
        ):
            self.assertRegex(
                consumer,
                r"GraphSelectiveTraitMethodBinding\(local_name, module_id, "
                r"(?:_|source_name), definition_ids\)",
            )

    def test_only_accepted_graph_contains_semantic_catalog(self) -> None:
        source = DECL.read_text(encoding="utf-8")
        accepted = re.search(
            r"private record AcceptedTypecheckGraphRep \{.*?\n\}",
            source,
            re.DOTALL,
        )
        recoverable = re.search(
            r"private record RecoverableTypecheckGraphRep \{.*?\n\}",
            source,
            re.DOTALL,
        )

        self.assertIsNotNone(accepted)
        self.assertIsNotNone(recoverable)
        self.assertIn("semantic_catalog: AcceptedSemanticCatalog", accepted.group(0))
        self.assertNotIn("AcceptedSemanticCatalog", recoverable.group(0))

    def test_catalog_is_opaque_and_requires_completed_globals(self) -> None:
        source = SEMANTIC_CATALOG.read_text(encoding="utf-8")

        self.assertIn("private record AcceptedSemanticCatalogRep", source)
        self.assertIn(
            "opaque type AcceptedSemanticCatalog = AcceptedSemanticCatalogRep",
            source,
        )
        self.assertIn("and accepted_global_table_is_complete(input.globals)", source)

    def test_catalog_requires_zero_cost_sealed_category_build_proofs(self) -> None:
        catalog_source = SEMANTIC_CATALOG.read_text(encoding="utf-8")
        catalog_input = re.search(
            r"record AcceptedSemanticCatalogInput \{.*?\n\}",
            catalog_source,
            re.DOTALL,
        )
        self.assertIsNotNone(catalog_input)

        for carrier, table, field, path in (
            ("AcceptedAliasGraph", "AcceptedAliasTable", "aliases", ALIAS_GRAPH),
            ("AcceptedRecordGraph", "AcceptedRecordTable", "records", RECORD_GRAPH),
            ("AcceptedUnionGraph", "AcceptedUnionTable", "unions", UNION_GRAPH),
        ):
            with self.subTest(carrier=carrier):
                source = path.read_text(encoding="utf-8")
                self.assertIn(f"opaque type {carrier} = {table}", source)
                self.assertNotIn(f"private record {carrier}Rep", source)
                self.assertIn(f"{field}: {carrier}", catalog_input.group(0))

        self.assertNotIn("aliases: AcceptedAliasTable", catalog_input.group(0))
        self.assertNotIn("records: AcceptedRecordTable", catalog_input.group(0))
        self.assertNotIn("unions: AcceptedUnionTable", catalog_input.group(0))

    def test_nominal_type_ids_are_definition_backed_scalars(self) -> None:
        identity_source = TYPE_IDENTITY.read_text(encoding="utf-8")
        header_source = TYPE_HEADER_GRAPH.read_text(encoding="utf-8")

        self.assertIn("opaque type TypeId = DefinitionId", identity_source)
        self.assertNotIn("TypeIdRep", identity_source)
        self.assertNotIn("func type_id_storage_key(", identity_source)
        self.assertIn(
            "header_index_by_definition_id: Dict[Int, Int]", header_source
        )

    def test_global_ids_are_definition_backed_scalars(self) -> None:
        skeleton_source = DECLARATION_SKELETON.read_text(encoding="utf-8")
        authority_source = GLOBAL_AUTHORITY.read_text(encoding="utf-8")

        self.assertIn("opaque type GlobalId = DefinitionId", skeleton_source)
        self.assertNotIn(
            "opaque type GlobalId = StructuralDeclarationIdRep", skeleton_source
        )
        self.assertIn(
            "index_by_global_definition_id: Dict[Int, Int]", authority_source
        )

        binding = re.search(
            r"record AcceptedGlobalBinding \{.*?\n\}",
            authority_source,
            re.DOTALL,
        )
        self.assertIsNotNone(binding)
        self.assertNotIn("definition_id:", binding.group(0))

    def test_nominal_type_tables_do_not_retain_parallel_owner_paths(self) -> None:
        sources = {
            "alias": ALIAS_AUTHORITY.read_text(encoding="utf-8"),
            "record": RECORD_AUTHORITY.read_text(encoding="utf-8"),
            "union": UNION_AUTHORITY.read_text(encoding="utf-8"),
        }

        for category, source in sources.items():
            with self.subTest(category=category):
                table = re.search(
                    rf"private record Accepted{category.title()}TableRep \{{.*?\n\}}",
                    source,
                    re.DOTALL,
                )
                self.assertIsNotNone(table)
                self.assertNotIn("owner_module_path", table.group(0))

        union_table = re.search(
            r"private record AcceptedUnionTableRep \{.*?\n\}",
            sources["union"],
            re.DOTALL,
        )
        self.assertIsNotNone(union_table)
        self.assertIn(
            "graph_union_indices_by_definition_id: Dict[Int, Int]",
            union_table.group(0),
        )
        self.assertIn(
            "builtin_union_indices_by_name: Dict[String, Int]",
            union_table.group(0),
        )

    def test_constructor_ids_are_scalar_definition_foreign_keys(self) -> None:
        source = DECLARATION_SKELETON.read_text(encoding="utf-8")

        self.assertIn("opaque type ConstructorId = Int", source)
        self.assertNotIn("opaque type ConstructorId = RuntimeDeclarationIdRep", source)
        self.assertNotRegex(
            source,
            r"from_opaque ConstructorId\([^)]*\)\.structural",
        )

    def test_trait_and_implementation_ids_are_compact_definition_keys(self) -> None:
        source = DECLARATION_SKELETON.read_text(encoding="utf-8")

        self.assertIn("opaque type ImplId = DefinitionId", source)
        self.assertIn("opaque type TraitId = Int", source)
        self.assertNotIn("StructuralDeclarationIdRep", source)
        self.assertNotIn("RuntimeDeclarationIdRep", source)

        method_id = re.search(
            r"private struct TraitMethodIdRep \{.*?\n\}",
            source,
            re.DOTALL,
        )
        self.assertIsNotNone(method_id)
        self.assertIn("owner: TraitId", method_id.group(0))
        self.assertIn("index: Int", method_id.group(0))
        self.assertNotIn("String", method_id.group(0))
        self.assertNotIn("SourceSpan", method_id.group(0))

    def test_internal_definition_keys_store_only_module_foreign_keys(self) -> None:
        source = DEFINITION_IDENTITY.read_text(encoding="utf-8")

        for representation_name in ("FuncCallableKeyRep", "SourceDefinitionKeyRep"):
            with self.subTest(representation_name=representation_name):
                representation = re.search(
                    rf"private record {representation_name} \{{.*?\n\}}",
                    source,
                    re.DOTALL,
                )
                self.assertIsNotNone(representation)
                body = representation.group(0)
                self.assertIn("module_id: ModuleId", body)
                self.assertNotIn("ModuleIdentity", body)
                self.assertNotIn("ModuleTable", body)

        exported_key = re.search(
            r"private record ExportedSymbolKeyRep \{.*?\n\}",
            source,
            re.DOTALL,
        )
        self.assertIsNotNone(exported_key)
        self.assertIn("module_identity: ModuleIdentity", exported_key.group(0))

    def test_definition_index_owns_canonical_table_and_id_only_name_buckets(self) -> None:
        source = DEFINITION_INDEX.read_text(encoding="utf-8")
        representation = re.search(
            r"private record DefinitionIndexRep \{.*?\n\}",
            source,
            re.DOTALL,
        )

        self.assertIsNotNone(representation)
        body = representation.group(0)
        self.assertIn("definition_table: DefinitionTable", body)
        self.assertIn("func_callable_ids_by_module_and_name: List[", body)
        self.assertIn("source_definition_ids_by_module_and_name: List[", body)
        self.assertNotIn("Dict[String, FuncCallableNameBuckets]", body)
        self.assertNotIn("Dict[String, SourceDefinitionNameBuckets]", body)
        self.assertIn(
            "private type alias FuncCallableNameBuckets = "
            "Dict[String, List[DefinitionId]]",
            source,
        )
        self.assertIn(
            "private type alias SourceDefinitionNameBuckets = "
            "Dict[String, List[DefinitionId]]",
            source,
        )
        self.assertNotIn("FuncCallableIdEntry", source)
        self.assertNotIn("SourceDefinitionIdEntry", source)

    def test_migration_only_zero_metrics_are_not_production_fields(self) -> None:
        production_sources = "\n".join(
            path.read_text(encoding="utf-8")
            for path in (
                ALIAS_GRAPH,
                RECORD_GRAPH,
                UNION_GRAPH,
                GLOBAL_AUTHORITY,
                CALLABLE_AUTHORITY,
                TRAIT_IMPLEMENTATION_AUTHORITY,
            )
        )

        for obsolete_metric in (
            "legacy_alias_graph_symbol_installs",
            "legacy_record_graph_symbol_installs",
            "legacy_union_graph_symbol_installs",
            "legacy_graph_global_installs",
            "global_exact_query_graph_scans",
            "legacy_graph_callable_env_installs",
            "legacy_graph_overload_installs",
            "module_view_callable_full_record_copies",
            "exact_callable_query_graph_scans",
            "module_view_coherence_overlap_checks",
            "legacy_graph_trait_env_installs",
            "legacy_graph_implementation_env_installs",
            "module_view_full_record_copies",
            "exact_query_graph_scans",
        ):
            with self.subTest(obsolete_metric=obsolete_metric):
                self.assertNotIn(obsolete_metric, production_sources)

    def test_frontend_profile_does_not_model_legacy_env_publication(self) -> None:
        decl_source = DECL.read_text(encoding="utf-8")
        fixture_source = FRONTEND_PROFILE_FIXTURE.read_text(encoding="utf-8")

        for obsolete_observation in (
            "imported_type_header_installations",
            "imported_constructor_installations",
            "imported_callable_header_installations",
            "imported_global_header_installations",
            "imported_trait_header_installations",
            "imported_implementation_header_installations",
            "local_header_installations",
            "scope_symbol_insertions",
            "scope_batch_insertions",
            "environment_publications",
            "total_graph_declaration_installations",
            "duplicate_installation_factor_millis",
            "ordinary_body_environment_rebuilds",
            "body_checks_started",
        ):
            with self.subTest(obsolete_observation=obsolete_observation):
                self.assertNotIn(obsolete_observation, decl_source)
                self.assertNotIn(obsolete_observation, fixture_source)

        self.assertNotIn(
            "CompilerFrontendDeclarationRepresentationModel", fixture_source
        )
        self.assertNotIn(
            "compiler_frontend_declaration_catalog_profile_representation_model",
            fixture_source,
        )

    def test_unreachable_declaration_adapters_are_absent(self) -> None:
        sources_by_obsolete_helper = {
            "local_record_header_fields": TYPE_HEADER_INSTALL,
            "local_union_header_variants": TYPE_HEADER_INSTALL,
            "accepted_implementation_find_exact": TRAIT_IMPLEMENTATION_AUTHORITY,
        }

        for obsolete_helper, source_path in sources_by_obsolete_helper.items():
            with self.subTest(obsolete_helper=obsolete_helper):
                self.assertNotIn(
                    f"func {obsolete_helper}(",
                    source_path.read_text(encoding="utf-8"),
                )

    def test_accepted_alias_projection_skips_provisional_payload_conversion(self) -> None:
        # Alias header installation was folded into the per-section builder
        # (`typecheck_install_module_header_section`) instead of a standalone
        # `install_alias_header` function; the invariant now lives in that
        # function's `for facts in section.aliases:` loop.
        source = TYPE_HEADER_INSTALL.read_text(encoding="utf-8")
        function = re.search(
            r"for facts in section\.aliases:.*?"
            r"(?=\n\n\t-- Publish the fact tables)",
            source,
            re.DOTALL,
        )

        self.assertIsNotNone(function)
        body = function.group(0)
        authority_branch = body.index("match alias_authority:")
        provisional_conversion = body.index("semantic_type_from_resolved_shape(")
        self.assertLess(authority_branch, provisional_conversion)
        self.assertIn("accepted_alias_contains(authority, facts.type_name)", body)

    def test_accepted_alias_membership_does_not_materialize_payload(self) -> None:
        source = ALIAS_AUTHORITY.read_text(encoding="utf-8")
        function = re.search(
            r"pure func accepted_alias_contains\(.*?(?=\n\nprivate pure func)",
            source,
            re.DOTALL,
        )

        self.assertIsNotNone(function)
        body = function.group(0)
        self.assertNotIn("accepted_alias_find_transparent", body)
        self.assertNotIn("accepted_alias_find_opaque", body)
        self.assertNotIn("local_transparent_alias_value", body)
        self.assertNotIn("local_opaque_alias_value", body)
        self.assertNotIn(".get(binding.payload_index)", body)
        self.assertNotIn(".get(binding.canonical_redirect_index)", body)

    def test_accepted_graph_globals_do_not_use_legacy_env_publication(self) -> None:
        self.assertTrue(GLOBAL_AUTHORITY.is_file())

        decl_source = DECL.read_text(encoding="utf-8")
        infer_source = INFER.read_text(encoding="utf-8")
        env_source = ENV.read_text(encoding="utf-8")

        for forbidden_name in (
            "register_global_header_for_source",
            "register_local_global_headers",
            "install_completed_globals_for_initializer",
            "completed_global_header_for_decl",
        ):
            with self.subTest(forbidden_name=forbidden_name):
                self.assertNotIn(forbidden_name, decl_source)

        self.assertNotIn("env_get_module_var_symbol", infer_source)
        self.assertNotIn("env_get_module_var_symbol", env_source)

    def test_global_table_does_not_recover_an_already_claimed_definition_id(self) -> None:
        decl_source = DECL.read_text(encoding="utf-8")
        function = re.search(
            r"private pure func accepted_global_declared_binding\(.*?"
            r"(?=\n\nprivate pure func)",
            decl_source,
            re.DOTALL,
        )

        self.assertIsNotNone(function)
        body = function.group(0)
        self.assertNotIn("definition_index_find_source_definition_id", body)
        self.assertNotIn("typecheck_state_for_prepared_module_scope", body)

    def test_request_scope_is_validated_before_dense_environment_lookup(self) -> None:
        decl_source = DECL.read_text(encoding="utf-8")
        function = re.search(
            r"private pure func graph_facts_typecheck_module\(.*?"
            r"(?=\n\npure func accepted_graph_typecheck_module)",
            decl_source,
            re.DOTALL,
        )

        self.assertIsNotNone(function)
        body = function.group(0)
        self.assertIn("prepared_module_environment_find_for_scope", body)
        self.assertNotIn("prepared_module_scope_id(request_scope)", body)

    def test_callable_authority_does_not_duplicate_module_identity_indexes(self) -> None:
        source = CALLABLE_AUTHORITY.read_text(encoding="utf-8")
        table = re.search(
            r"private record AcceptedCallableTableRep \{.*?\n\}",
            source,
            re.DOTALL,
        )
        authority = re.search(
            r"private record AcceptedCallableAuthorityRep \{.*?\n\}",
            source,
            re.DOTALL,
        )

        self.assertIsNotNone(table)
        self.assertIsNotNone(authority)
        self.assertIn(
            "indices_by_definition_id: Dict[Int, List[Int]]", table.group(0)
        )
        self.assertIn("module_table: ModuleTable", table.group(0))
        self.assertIn(
            "slot_range_by_module: List[AcceptedCallableModuleRange]",
            table.group(0),
        )
        self.assertNotIn("indices_by_module_and_name", table.group(0))
        self.assertNotIn("indices_by_module_path_and_name", table.group(0))
        self.assertIn("owner_module_id: Option[ModuleId]", authority.group(0))
        self.assertNotIn("owner_module_path", authority.group(0))
        self.assertNotIn("ModuleIdentity", source)
        self.assertNotIn("identity_keys_by_module_path", table.group(0))

    def test_callable_selective_visibility_uses_exact_targets(self) -> None:
        source = CALLABLE_AUTHORITY.read_text(encoding="utf-8")
        binding = re.search(
            r"private record AcceptedVisibleCallableBindingRep \{.*?\n\}",
            source,
            re.DOTALL,
        )
        authority = re.search(
            r"pure func accepted_callable_authority\(.*?"
            r"(?=\n\npure func accepted_callable_authority_without_visible_names)",
            source,
            re.DOTALL,
        )
        decl_source = DECL.read_text(encoding="utf-8")
        adapter = re.search(
            r"private pure func accepted_callable_authority_for_module\(.*?"
            r"(?=\n\nprivate pure func accepted_trait_implementation_authority_for_module)",
            decl_source,
            re.DOTALL,
        )

        self.assertIsNotNone(binding)
        self.assertIn("targets: List[CallableId]", binding.group(0))
        self.assertNotIn("owner_module_path", binding.group(0))
        self.assertNotIn("original_name", binding.group(0))
        self.assertIsNotNone(authority)
        self.assertIn("table_indices_for_ids", authority.group(0))
        self.assertNotIn("binding.owner_module_path", authority.group(0))
        self.assertNotIn("binding.original_name", authority.group(0))
        self.assertIsNotNone(adapter)
        self.assertIn("accepted_visible_callable_bindings", adapter.group(0))
        self.assertIn("module_view_import_bindings", adapter.group(0))
        self.assertNotIn("module_view_imported_names", adapter.group(0))

    def test_callable_visibility_uses_source_name_ids(self) -> None:
        source = CALLABLE_AUTHORITY.read_text(encoding="utf-8")
        table_input = re.search(
            r"record AcceptedCallableTableInput \{.*?\n\}",
            source,
            re.DOTALL,
        )
        table = re.search(
            r"private record AcceptedCallableTableRep \{.*?\n\}",
            source,
            re.DOTALL,
        )
        binding = re.search(
            r"private record AcceptedVisibleCallableBindingRep \{.*?\n\}",
            source,
            re.DOTALL,
        )

        self.assertIsNotNone(table_input)
        self.assertIsNotNone(table)
        self.assertIsNotNone(binding)
        self.assertIn("scope: PreparedModuleScope", table_input.group(0))
        self.assertNotIn("module_table: ModuleTable", table_input.group(0))
        self.assertNotIn("definition_table: DefinitionTable", table_input.group(0))
        self.assertNotIn("source_name_table: SourceNameTable", table_input.group(0))
        self.assertIn("source_name_table: SourceNameTable", table.group(0))
        self.assertIn("source_name_id: SourceNameId", binding.group(0))
        self.assertNotIn("source_name: String", binding.group(0))

    def test_callable_module_membership_uses_compact_ranges(self) -> None:
        source = CALLABLE_AUTHORITY.read_text(encoding="utf-8")
        slot = re.search(
            r"private record AcceptedCallableSlot \{.*?\n\}",
            source,
            re.DOTALL,
        )
        table = re.search(
            r"private record AcceptedCallableTableRep \{.*?\n\}",
            source,
            re.DOTALL,
        )
        record = re.search(
            r"record AcceptedCallableTableRecord \{.*?\n\}",
            source,
            re.DOTALL,
        )

        self.assertIsNotNone(slot)
        self.assertIsNotNone(table)
        self.assertIsNotNone(record)
        self.assertIn("source_name_id: SourceNameId", record.group(0))
        self.assertNotIn("source_name: String", record.group(0))
        self.assertIn("source_name_id: SourceNameId", slot.group(0))
        self.assertNotIn("source_name: String", slot.group(0))
        self.assertIn(
            "slot_range_by_module: List[AcceptedCallableModuleRange]",
            table.group(0),
        )
        self.assertNotIn("name_ranges", table.group(0))
        self.assertNotIn("indices_by_module_and_name", table.group(0))

    def test_callable_authority_retains_exact_visibility_inputs(self) -> None:
        source = CALLABLE_AUTHORITY.read_text(encoding="utf-8")
        constructor = re.search(
            r"pure func accepted_callable_authority\(.*?\) -> Option\[AcceptedCallableAuthority\]:",
            source,
            re.DOTALL,
        )
        authority = re.search(
            r"private record AcceptedCallableAuthorityRep \{.*?\n\}",
            source,
            re.DOTALL,
        )
        name_access = re.search(
            r"private record AcceptedCallableNameAccess \{.*?\n\}",
            source,
            re.DOTALL,
        )

        self.assertIsNotNone(constructor)
        self.assertIsNotNone(authority)
        self.assertIsNotNone(name_access)
        self.assertIn("owner_scope: Option[PreparedModuleScope]", constructor.group(0))
        self.assertIn(
            "direct_module_scopes: List[PreparedModuleScope]",
            constructor.group(0),
        )
        self.assertNotIn("owner_module_path", constructor.group(0))
        self.assertNotIn("direct_module_paths", constructor.group(0))
        self.assertIn(
            "owner_module_id: Option[ModuleId]",
            authority.group(0),
        )
        self.assertIn(
            "name_access: Option[AcceptedCallableNameAccess]",
            authority.group(0),
        )
        self.assertIn(
            "visible_bindings: List[AcceptedVisibleCallableBinding]",
            name_access.group(0),
        )
        self.assertIn("direct_module_ids: List[ModuleId]", name_access.group(0))
        self.assertNotIn("owner_module_path", authority.group(0))
        self.assertNotIn("Dict[String, List[Int]]", authority.group(0))
        self.assertNotIn("Dict[Int, List[Int]]", authority.group(0))
        self.assertNotIn("AcceptedCallableNameRow", authority.group(0))

    def test_global_authority_locality_uses_the_existing_module_path_index(self) -> None:
        source = GLOBAL_AUTHORITY.read_text(encoding="utf-8")
        authority = re.search(
            r"private record AcceptedGlobalAuthorityRep \{.*?\n\}",
            source,
            re.DOTALL,
        )

        self.assertIsNotNone(authority)
        self.assertIn("owner_module_path: String", authority.group(0))
        self.assertNotIn("owner: ModuleIdentity", authority.group(0))
        self.assertNotIn("module_identities_equal", source)

    def test_global_authority_uses_one_exact_per_module_slot_relation(self) -> None:
        source = GLOBAL_AUTHORITY.read_text(encoding="utf-8")
        table = re.search(
            r"private record AcceptedGlobalTableRep \{.*?\n\}",
            source,
            re.DOTALL,
        )

        self.assertIsNotNone(table)
        self.assertIn(
            "slot_indices_by_module_and_source_name_id: List[Dict[Int, Int]]",
            table.group(0),
        )
        self.assertNotIn("indices_by_module_and_name", table.group(0))
        self.assertNotIn("Dict[String", table.group(0))

    def test_trait_implementation_authority_uses_dense_module_indices(self) -> None:
        source = (
            ROOT
            / "blorp/src/compiler/stage_06_typecheck/type_system/accepted_trait_implementation_authority.brp"
        ).read_text(encoding="utf-8")
        table = re.search(
            r"private record AcceptedTraitImplementationTableRep \{.*?\n\}",
            source,
            re.DOTALL,
        )
        authority = re.search(
            r"private record AcceptedTraitImplementationAuthorityRep \{.*?\n\}",
            source,
            re.DOTALL,
        )

        self.assertIsNotNone(table)
        self.assertIsNotNone(authority)
        self.assertIn("module_table: ModuleTable", table.group(0))
        self.assertIn("definition_table: DefinitionTable", table.group(0))
        self.assertIn("trait_index_by_definition_id: Dict[Int, Int]", table.group(0))
        self.assertIn(
            "implementation_index_by_definition_id: Dict[Int, Int]",
            table.group(0),
        )
        self.assertIn(
            "trait_index_by_compiler_identity: Dict[Int, Int]", table.group(0)
        )
        self.assertIn("trait_indices_by_module: List[List[Int]]", table.group(0))
        self.assertIn("implementation_indices_by_module: List[List[Int]]", table.group(0))
        self.assertNotIn("trait_indices_by_module_and_definition_id", table.group(0))
        self.assertNotIn(
            "implementation_indices_by_module_and_definition_id", table.group(0)
        )
        self.assertNotIn("trait_indices_by_module_path", table.group(0))
        self.assertNotIn("implementation_indices_by_module_path", table.group(0))
        self.assertNotIn("by_module_identity", table.group(0))
        self.assertIn("owner_module_path: String", authority.group(0))
        self.assertNotIn("owner: ModuleIdentity", authority.group(0))

        implementation_headers = IMPLEMENTATION_HEADERS.read_text(encoding="utf-8")
        implementation_graph = re.search(
            r"private record ImplementationHeaderGraphRep \{.*?\n\}",
            implementation_headers,
            re.DOTALL,
        )
        self.assertIsNotNone(implementation_graph)
        self.assertNotIn(
            "header_index_by_definition_id", implementation_graph.group(0)
        )
        self.assertNotIn("index_by_trait_identity", implementation_graph.group(0))

    def test_semantic_occurrences_store_module_owner_once(self) -> None:
        source = SEMANTIC_OCCURRENCE.read_text(encoding="utf-8")
        definition = re.search(
            r"record SemanticDefinitionOccurrence \{.*?\n\}", source, re.DOTALL
        )
        reference = re.search(
            r"record SemanticReferenceOccurrence \{.*?\n\}", source, re.DOTALL
        )
        module = re.search(
            r"record ModuleSemanticOccurrences \{.*?\n\}", source, re.DOTALL
        )
        reference_walk = source[source.index("private pure func expr_reference(") :]

        self.assertIsNotNone(definition)
        self.assertIsNotNone(reference)
        self.assertIsNotNone(module)
        self.assertNotIn("module_identity:", definition.group(0))
        self.assertNotIn("module_identity:", reference.group(0))
        self.assertIn("module_identity: ModuleIdentity", module.group(0))
        self.assertNotIn("module_identity: ModuleIdentity", reference_walk)

    def test_type_header_local_queries_require_prepared_scope(self) -> None:
        source = TYPE_HEADER_GRAPH.read_text(encoding="utf-8")

        self.assertNotIn("private pure func type_header_graph_scope(", source)
        for category in ("builtin", "record", "union", "alias"):
            with self.subTest(category=category):
                self.assertNotIn(
                    f"pure func type_header_graph_local_{category}_headers(\n",
                    source,
                )

    def test_body_outcome_table_does_not_retain_module_identity(self) -> None:
        source = DECL.read_text(encoding="utf-8")
        representation = re.search(
            r"private record BodyOutcomeTableRep \{.*?\n\}", source, re.DOTALL
        )
        constructor = re.search(
            r"private pure func body_outcome_table_for_base\(.*?"
            r"(?=\n\nprivate record CtfeSubsetDeclMaterialization)",
            source,
            re.DOTALL,
        )
        lookup = re.search(
            r"private pure func body_outcome_table_find\(.*?"
            r"(?=\n\nprivate pure func body_outcome_table_find_definition_id)",
            source,
            re.DOTALL,
        )

        self.assertIsNotNone(representation)
        self.assertIsNotNone(constructor)
        self.assertIsNotNone(lookup)
        self.assertNotIn("owner: ModuleIdentity", representation.group(0))
        self.assertIn("owner_scope = bound_module_scope", constructor.group(0))
        self.assertIn("callable_ids_equal", lookup.group(0))

    def test_seeded_body_materialization_does_not_rebuild_outcome_table(self) -> None:
        source = DECL.read_text(encoding="utf-8")
        seeded = re.search(
            r"pure func body_check_registry_materialize_complete_with_seed\(.*?"
            r"(?=\n\npure func typecheck_program_with_type_header_module_in_body_order)",
            source,
            re.DOTALL,
        )

        self.assertIsNotNone(seeded)
        success_path = seeded.group(0).split("BodyOutcomeTableAccepted(seed_table):", 1)[1]
        self.assertNotIn("outcomes = outcomes.append", success_path)
        self.assertNotIn("materialize_program_from_body_outcomes(", success_path)
        self.assertIn("materialize_complete_from_validated_seed(", success_path)
        completion = source.split("private pure func materialize_complete_from_validated_seed(", 1)[1]
        completion = completion.split("\n\npure func body_check_registry_materialize_complete_with_seed_table(", 1)[0]
        self.assertNotIn("complete_body_outcome_table_for_contexts(", completion)
        self.assertIn("complete_body_outcome_table_from_source_order(", completion)
        self.assertIn("materialize_program_from_complete_body_table(", completion)

    def test_complete_body_outcome_table_is_required_for_full_materialization(self) -> None:
        source = DECL.read_text(encoding="utf-8")
        representation = re.search(
            r"private record CompleteBodyOutcomeTableRep \{.*?\n\}",
            source,
            re.DOTALL,
        )
        complete_materializer = re.search(
            r"private pure func materialize_program_from_complete_body_table\(.*?"
            r"(?=\n\nprivate pure func rejected_body_table_result)",
            source,
            re.DOTALL,
        )
        direct_checker = re.search(
            r"private pure func check_complete_body_table_in_order\(.*?"
            r"(?=\n\nprivate pure func body_context_failure_label)",
            source,
            re.DOTALL,
        )

        self.assertIsNotNone(representation)
        self.assertIsNotNone(complete_materializer)
        self.assertIsNotNone(direct_checker)
        self.assertIn("table: BodyOutcomeTable", representation.group(0))
        self.assertIn("source_order: List[CallableId]", representation.group(0))
        self.assertIn(
            "complete_table: CompleteBodyOutcomeTable",
            complete_materializer.group(0),
        )
        self.assertIn("ReuseCompleteFunctionBodies(", complete_materializer.group(0))
        self.assertNotIn("ReuseSelectedFunctionBodies(", complete_materializer.group(0))
        self.assertIn("var rows: Dict[Int, BodyCheckOutcome]", direct_checker.group(0))
        self.assertNotIn("List[BodyCheckOutcome]", direct_checker.group(0))
        self.assertNotIn("materialize_program_from_body_table(", source)

    def test_ctfe_typed_functions_follow_checked_row_order(self) -> None:
        declaration = DECL.read_text(encoding="utf-8")
        bridge = (ROOT / "blorp/src/compiler/stage_06_typecheck/bridge.brp").read_text(
            encoding="utf-8"
        )
        projection = bridge.split(
            "private pure func ctfe_checked_body_groups_typed_functions(", 1
        )[1].split("\n\n-- An empty chain", 1)[0]
        selective = bridge.split(
            "private pure func prepare_selective_ctfe_dependencies_for_roots(", 1
        )[1].split("\n\nprivate pure func prepare_selective_ctfe_dependencies(", 1)[0]

        self.assertNotIn("body_outcome_table_typed_functions", declaration)
        self.assertNotIn("body_outcome_table_typed_functions", bridge)
        self.assertIn("representation.next_row_index.get(index)", projection)
        self.assertIn("ctfe_checked_body_groups_typed_functions(", selective)

    def test_selective_ctfe_body_outcomes_have_one_module_grouped_carrier(self) -> None:
        bridge = (ROOT / "blorp/src/compiler/stage_06_typecheck/bridge.brp").read_text(
            encoding="utf-8"
        )
        selective = bridge.split(
            "private pure func prepare_selective_ctfe_dependencies_for_roots(", 1
        )[1].split("\n\nprivate pure func prepare_selective_ctfe_dependencies(", 1)[0]

        self.assertIn("SelectiveCtfeProgram(CtfeImportedProgram)", bridge)
        self.assertIn("ctfe_checked_body_groups(checked)", selective)
        self.assertNotRegex(selective, r"checked\s*\.filter\(")
        self.assertNotIn("target_ctfe_body_outcomes:", bridge)
        self.assertNotIn("target_body_outcomes:", bridge)

    def test_ctfe_subset_and_seed_consume_one_validated_body_table(self) -> None:
        declaration = DECL.read_text(encoding="utf-8")
        bridge = (ROOT / "blorp/src/compiler/stage_06_typecheck/bridge.brp").read_text(
            encoding="utf-8"
        )
        selective = bridge.split(
            "private pure func prepare_selective_ctfe_dependencies_for_roots(", 1
        )[1].split("\n\nprivate pure func prepare_selective_ctfe_dependencies(", 1)[0]
        validation = bridge.split("private pure func ctfe_validated_body_table_for_registration(", 1)[1]
        validation = validation.split("\n\n-- Validated module tables", 1)[0]

        self.assertIn("plan_provenance: BodyPlanProvenance", declaration.split(
            "private record BodyOutcomeTableRep {", 1
        )[1].split("\n}", 1)[0])
        self.assertIn("body_check_registry_outcome_table_from_indexed_rows(", validation)
        self.assertIn("body_check_registry_materialize_subset_from_table(", selective)
        self.assertIn("CtfeValidatedBodyTables", bridge)
        self.assertIn("body_check_registry_materialize_complete_with_seed_table(", bridge)
        self.assertNotIn("checked_body_groups: Option[CtfeCheckedBodyGroups]", bridge)

    def test_ctfe_module_tables_admit_linked_rows_without_outcome_lists(self) -> None:
        bridge = (ROOT / "blorp/src/compiler/stage_06_typecheck/bridge.brp").read_text(
            encoding="utf-8"
        )

        self.assertIn("CtfeCheckedBodyGroups", bridge)
        self.assertFalse("ctfe_checked_body_groups_outcomes(" in bridge)
        self.assertFalse("outcomes = outcomes.append(body.outcome)" in bridge)
        self.assertIn("body_check_registry_outcome_table_from_indexed_rows(", bridge)

    def test_ctfe_accepted_body_uses_validated_product(self) -> None:
        declaration = DECL.read_text(encoding="utf-8")
        worklist = (
            ROOT / "blorp/src/compiler/stage_07_ctfe/body_worklist.brp"
        ).read_text(encoding="utf-8")
        accepted = declaration.split("private record CheckedBodyArtifactRep {", 1)[1].split("\n}", 1)[0]
        self.assertIn("validated: ValidatedBody", accepted)
        self.assertNotIn("typed: TypedFunctionInfo", accepted)
        self.assertIn("opaque type InferredBody", declaration)
        self.assertIn("opaque type SolvedBody", declaration)
        self.assertIn("opaque type ValidatedBody", declaration)
        self.assertIn("validate_inferred_body(", declaration)
        self.assertRegex(worklist, r"checked_body_artifact_validated_body\(\s*artifact")
        self.assertNotIn("body_check_outcome_typed_function(outcome)", worklist)

    def test_inferred_body_handoff_owns_only_typed_body_and_issues(self) -> None:
        declaration = DECL.read_text(encoding="utf-8")
        self.assertTrue("private record InferredBodyRep {" in declaration)
        inferred = declaration.split("private record InferredBodyRep {", 1)[1].split("\n}", 1)[0]
        self.assertTrue("typed: TypedFunctionInfo" in inferred)
        self.assertTrue("issues: BodyValidationIssues" in inferred)
        self.assertFalse("state: TypecheckState" in inferred)
        self.assertTrue("inferred_body_from_materialized(" in declaration)

    def test_accepted_reuse_carries_body_proof_into_final_validation(self) -> None:
        declaration = DECL.read_text(encoding="utf-8")
        self.assertIn("ReusedValidatedBody(ValidatedBody)", declaration)
        self.assertIn("MaterializedFunctionDecl(MaterializedFunctionBody)", declaration)
        self.assertIn("MaterializedUncheckedDecl(TypedDecl)", declaration)
        validation = declaration.split(
            "private pure func typecheck_validate_materialized_function_body(", 1
        )[1].split("\n\n", 1)[0]
        self.assertIn("ReusedValidatedBody(_):", validation)
        self.assertIn("UnvalidatedFunctionBody(typed):", validation)
        self.assertIn("typecheck_validate_typed_function_info(state, label, typed)", validation)
        self.assertIn("MaterializedUncheckedDecl(decl):", declaration)
        self.assertIn("typecheck_validate_typed_decl(state, decl)", declaration)
        self.assertIn("typecheck_validate_materialized_typed_program(", declaration)
        self.assertIn("decl = MaterializedPrivateDecl(result.decl)", declaration)
        self.assertIn("decl = MaterializedImplDecl(result.body)", declaration)
        self.assertIsNotNone(
            re.search(
                r"BodyCheckRejected\(artifact\):.{0,300}?"
                r"body = UnvalidatedFunctionBody\(\s*"
                r"from_opaque RecoveredBodyArtifact\(artifact\)\.typed",
                declaration,
                re.DOTALL,
            ),
            "rejected recovery must remain unvalidated",
        )

    def test_implementation_methods_keep_individual_validation_proofs(self) -> None:
        declaration = DECL.read_text(encoding="utf-8")
        self.assertIn("MaterializedImplDecl(MaterializedImplInfo)", declaration)
        self.assertIn("methods: List[MaterializedFunctionBody]", declaration)
        self.assertIn("materialized_methods.append(method_result.body)", declaration)
        self.assertIn("typecheck_validate_materialized_impl_info(", declaration)
        self.assertIn("materialized_function_body_typed_info(method)", declaration)
        self.assertNotIn(
            "MaterializedUncheckedDecl(TypedImplDecl(result.typed))",
            declaration,
        )

    def test_owned_type_resolution_reuses_prepared_module_scope(self) -> None:
        source = TYPE_HEADER_GRAPH.read_text(encoding="utf-8")
        preparation = re.search(
            r"private pure func prepare_owned_type_resolution_context\(.*?"
            r"(?=\n\nprivate pure func resolve_prepared_type_shape)",
            source,
            re.DOTALL,
        )

        self.assertIsNotNone(preparation)
        self.assertIn("owner_scope: PreparedModuleScope", preparation.group(0))
        self.assertIn("bound_module_graph_find_for_scope", preparation.group(0))
        self.assertNotIn("owner_module_identity: ModuleIdentity", preparation.group(0))
        self.assertNotIn("bound_module_graph_find(bound_graph", preparation.group(0))

    def test_accepted_table_fallbacks_expose_only_canonically_visible_names(self) -> None:
        """The canonical-name fallback (no local module bindings) must still
        expose only public declarations. `accepted_*_table_canonical_authority`
        takes no scope: it builds its authority from the table's own
        `*_by_canonical_name` maps via an empty module view, and those maps
        are populated only for entries whose source table marked
        `canonical_visible = True` (see `accepted_*_table` in the matching
        `type_system/accepted_*_authority.brp`). That gate — not a
        `PreparedModuleScope` argument — is what keeps the fallback
        public-only."""
        for category, graph_path, authority_path in (
            ("alias", ALIAS_GRAPH, ALIAS_AUTHORITY),
            ("record", RECORD_GRAPH, RECORD_AUTHORITY),
            ("union", UNION_GRAPH, UNION_AUTHORITY),
        ):
            with self.subTest(category=category):
                graph_source = graph_path.read_text(encoding="utf-8")
                fallback = re.search(
                    rf"pure func accepted_{category}_table_canonical_authority\(.*?"
                    rf"(?=\n\npure func|\Z)",
                    graph_source,
                    re.DOTALL,
                )

                self.assertIsNotNone(fallback)
                self.assertNotIn("owner_scope: PreparedModuleScope", fallback.group(0))
                self.assertNotIn("owner: ModuleIdentity", fallback.group(0))
                self.assertIn(f"accepted_{category}_empty_module_view()", fallback.group(0))

                authority_source = authority_path.read_text(encoding="utf-8")
                builder = re.search(
                    rf"pure func accepted_{category}_table\(.*?"
                    rf"(?=\n\npure func|\Z)",
                    authority_source,
                    re.DOTALL,
                )

                self.assertIsNotNone(builder)
                gated_name_index = re.search(
                    r"if [A-Za-z_.]*canonical_visible:\s*\n\s*[A-Za-z_]*(?:by_canonical_name|_by_name) = ",
                    builder.group(0),
                )
                self.assertIsNotNone(
                    gated_name_index,
                    "canonical-name index must only be populated when "
                    "canonical_visible is True",
                )

    def test_global_header_owner_index_uses_compilation_module_ids(self) -> None:
        source = GLOBAL_HEADER_COMPLETION.read_text(encoding="utf-8")
        header_index = re.search(
            r"private pure func global_header_index\(.*?"
            r"(?=\n\nprivate pure func)",
            source,
            re.DOTALL,
        )
        header_lookup = re.search(
            r"private pure func global_header_row_for_module_and_name\(.*?"
            r"(?=\n\nprivate pure func)",
            source,
            re.DOTALL,
        )

        self.assertIn(
            "rows_by_module_and_name: List[Dict[String, Int]]",
            source,
        )
        self.assertIn("module_indexes_by_header_row: List[Int]", source)
        self.assertIsNotNone(header_index)
        self.assertIsNotNone(header_lookup)
        self.assertIn("module_id_table_index", header_index.group(0))
        self.assertIn("module_id_table_index", header_lookup.group(0))
        self.assertNotIn("module_identity_storage_key", header_index.group(0))
        self.assertNotIn("module_identity_storage_key", header_lookup.group(0))

    def test_declaration_skeleton_lookup_is_module_table_indexed(self) -> None:
        source = DECLARATION_SKELETON.read_text(encoding="utf-8")
        representation = re.search(
            r"private record DeclarationSkeletonGraphRep \{.*?\n\}",
            source,
            re.DOTALL,
        )
        type_lookup = re.search(
            r"pure func declaration_skeleton_graph_find_type\(.*?"
            r"(?=\n\npure func)",
            source,
            re.DOTALL,
        )
        bucket_lookup = re.search(
            r"private pure func declaration_skeleton_graph_find_module_name_kind\(.*?"
            r"(?=\n\npure func)",
            source,
            re.DOTALL,
        )

        self.assertIsNotNone(representation)
        self.assertIsNotNone(type_lookup)
        self.assertIsNotNone(bucket_lookup)
        self.assertIn("module_ids_by_skeleton", representation.group(0))
        self.assertIn("latest_skeleton_index_by_name", representation.group(0))
        self.assertIn("previous_same_name_index_by_skeleton", representation.group(0))
        self.assertNotIn("Dict[String, List[Int]]", representation.group(0))
        self.assertNotIn("skeletons_by_name", representation.group(0))
        self.assertIn("module_scope: PreparedModuleScope", type_lookup.group(0))
        self.assertIn("bound_module_graph_find_for_scope", bucket_lookup.group(0))
        self.assertIn("latest_skeleton_index_by_name", bucket_lookup.group(0))
        self.assertIn("previous_same_name_index_by_skeleton", bucket_lookup.group(0))
        self.assertIn("module_ids_equal", bucket_lookup.group(0))
        self.assertNotIn("prepared_module_ids_equal", bucket_lookup.group(0))
        self.assertNotIn("module_identities_equal", bucket_lookup.group(0))
        self.assertNotIn("TypeNamespaceKey(ModuleIdentity", source)
        self.assertNotIn("TraitNamespaceKey(ModuleIdentity", source)

    def test_accepted_type_views_do_not_retain_materialized_module_owners(self) -> None:
        authority_sources = {
            "alias": ALIAS_AUTHORITY.read_text(encoding="utf-8"),
            "record": (
                ROOT
                / "blorp/src/compiler/stage_06_typecheck/type_system/accepted_record_authority.brp"
            ).read_text(encoding="utf-8"),
            "union": (
                ROOT
                / "blorp/src/compiler/stage_06_typecheck/type_system/accepted_union_authority.brp"
            ).read_text(encoding="utf-8"),
        }

        for category, source in authority_sources.items():
            with self.subTest(category=category):
                view = re.search(
                    rf"private record Accepted{category.title()}ModuleViewRep \{{.*?\n\}}",
                    source,
                    re.DOTALL,
                )
                self.assertIsNotNone(view)
                self.assertNotIn("owner: ModuleIdentity", view.group(0))

        alias_authority = re.search(
            r"record AcceptedAliasAuthority \{.*?\n\}",
            authority_sources["alias"],
            re.DOTALL,
        )
        record_authority = re.search(
            r"private record AcceptedRecordAuthorityRep \{.*?\n\}",
            authority_sources["record"],
            re.DOTALL,
        )
        self.assertIsNotNone(alias_authority)
        self.assertIsNotNone(record_authority)
        self.assertNotIn("owner: ModuleIdentity", alias_authority.group(0))
        self.assertNotIn("owner: ModuleIdentity", record_authority.group(0))
        self.assertIn(
            "private type alias AcceptedRecordLocator = Int",
            authority_sources["record"],
        )
        self.assertNotIn("struct AcceptedRecordLocator", authority_sources["record"])
        self.assertIn("accepted_record_locator_owner_local", authority_sources["record"])

        for source in authority_sources.values():
            self.assertNotIn("_empty_module_view(owner", source)

    def test_recoverable_completion_failures_store_graph_module_ids(self) -> None:
        source = DECL.read_text(encoding="utf-8")
        failure = re.search(
            r"private record GlobalHeaderCompletionFailure \{.*?\n\}",
            source,
            re.DOTALL,
        )
        failed_lookup = re.search(
            r"private pure func completion_failed_for_module\(.*?"
            r"(?=\n\npure func recoverable_graph_typecheck_module)",
            source,
            re.DOTALL,
        )

        self.assertIsNotNone(failure)
        self.assertIsNotNone(failed_lookup)
        self.assertIn("module_id: Option[ModuleId]", failure.group(0))
        self.assertNotIn("module_identity", failure.group(0))
        self.assertIn("module_id: ModuleId", failed_lookup.group(0))
        self.assertIn("module_ids_equal", failed_lookup.group(0))
        self.assertNotIn("PreparedModuleId", failed_lookup.group(0))
        self.assertNotIn("module_identities_equal", failed_lookup.group(0))
        self.assertIn("failure_owner_missing", source)
        self.assertIn("global header completion failure owner is absent from ", source)
        self.assertIn('+ "the module table"', source)

    def test_global_table_completion_failure_is_not_silently_discarded(self) -> None:
        decl_source = DECL.read_text(encoding="utf-8")

        self.assertIn(
            "accepted_global_table: Option[AcceptedGlobalTable]", decl_source
        )
        self.assertNotIn(
            ").get_or(initial_global_table)", decl_source
        )
        self.assertIn(
            '"internal typecheck error: completed globals did not match the accepted global "',
            decl_source,
        )
        self.assertIn('+ "table"', decl_source)

    def test_resolved_calls_do_not_require_an_exact_env_function_index(self) -> None:
        infer_source = INFER.read_text(encoding="utf-8")
        env_source = ENV.read_text(encoding="utf-8")

        self.assertIn("bound_type_params: List[BoundTypeParam]", infer_source)
        self.assertIn("debug_only: Bool", infer_source)

        for removed_name in (
            "function_indexes_by_callable_id",
            "scope_find_func_by_def_id",
            "env_find_func_by_def_id",
        ):
            with self.subTest(removed_name=removed_name):
                self.assertNotIn(removed_name, env_source)

    def test_accepted_graph_callables_do_not_use_legacy_env_publication(self) -> None:
        self.assertTrue(CALLABLE_AUTHORITY.is_file())

        decl_source = DECL.read_text(encoding="utf-8")
        infer_source = INFER.read_text(encoding="utf-8")
        env_source = ENV.read_text(encoding="utf-8")

        for removed_name in (
            "env_get_module_func_symbol",
            "env_find_func_named_by_def_id",
            "env_add_overload",
            "env_get_overloads",
            "env_resolve_overload",
        ):
            with self.subTest(removed_name=removed_name):
                self.assertNotIn(removed_name, env_source)
                self.assertNotIn(removed_name, infer_source)

        self.assertNotIn("overloads: List[OverloadSet]", env_source)
        self.assertNotIn("ufcs_methods: List[OverloadSet]", env_source)
        self.assertNotIn("env_add_ufcs_method", env_source)
        self.assertNotIn("env_lookup_module_ufcs_methods", env_source)
        self.assertNotIn("infer_bare_overload_callee", infer_source)
        self.assertNotIn("missing_bare_overload_call_result", infer_source)
        self.assertIn("accepted_callable_table", decl_source)
        self.assertIn("module_view_with_accepted_callable_authority", decl_source)

        preparation = re.search(
            r"private pure func prepare_accepted_callable_header\(.*?"
            r"(?=\n\nprivate pure func)",
            decl_source,
            re.DOTALL,
        )
        self.assertIsNotNone(preparation)
        self.assertNotIn("env_add_func_with_info", preparation.group(0))
        self.assertNotIn("env_extract_graph_callables", decl_source)

        body_signature = re.search(
            r"private pure func body_signature_from_accepted_header\(.*?"
            r"(?=\n\nprivate pure func)",
            decl_source,
            re.DOTALL,
        )
        self.assertIsNotNone(body_signature)
        self.assertIn("accepted_callable_find_exact", body_signature.group(0))
        self.assertNotIn("callable_header_semantic_type", body_signature.group(0))

        authority_source = CALLABLE_AUTHORITY.read_text(encoding="utf-8")
        self.assertNotIn("owner_entry:", authority_source)
        self.assertNotIn("canonical_entry:", authority_source)

        graph_preparation = re.search(
            r"private pure func prepared_module_environments\(.*?"
            r"(?=\n\nprivate pure func)",
            decl_source,
            re.DOTALL,
        )
        self.assertIsNotNone(graph_preparation)
        self.assertEqual(
            graph_preparation.group(0).count(
                "for header in callable_header_graph_callables(callable_headers):"
            ),
            1,
        )
        self.assertIn("base_positions_by_module_id", graph_preparation.group(0))
        self.assertNotIn("base_indices_by_module", graph_preparation.group(0))

    def test_direct_accepted_callable_resolution_preserves_exact_identity(self) -> None:
        authority_source = CALLABLE_AUTHORITY.read_text(encoding="utf-8")
        infer_source = INFER.read_text(encoding="utf-8")

        binding = re.search(
            r"record AcceptedCallableBinding \{.*?\n\}",
            authority_source,
            re.DOTALL,
        )
        self.assertIsNotNone(binding)
        self.assertIn("id: CallableId", binding.group(0))
        self.assertIn("source_name: String", binding.group(0))
        self.assertIn("entry: OverloadEntry", binding.group(0))

        for function_name in (
            "accepted_callable_find",
            "accepted_callable_find_qualified",
        ):
            with self.subTest(function_name=function_name):
                query = re.search(
                    rf"pure func {function_name}\(.*?(?=\n\npure func)",
                    authority_source,
                    re.DOTALL,
                )
                self.assertIsNotNone(query)
                self.assertIn("Option[AcceptedCallableBinding]", query.group(0))

        graph_resolution = re.search(
            r"private pure func resolved_call_from_graph_overload_entry\(.*?"
            r"(?=\n\nprivate pure func)",
            infer_source,
            re.DOTALL,
        )
        self.assertIsNotNone(graph_resolution)
        self.assertIn("id: CallableId", graph_resolution.group(0))
        self.assertRegex(
            graph_resolution.group(0),
            r"ResolvedGraphCallableCall\(\s*id,",
        )
        self.assertNotIn("entry.module_path", graph_resolution.group(0))
        self.assertNotIn("callable_id_from_reserved_graph_definition", graph_resolution.group(0))

        accepted_name = re.search(
            r"Some\(BareAcceptedCallable\(binding\)\):.*?"
            r"(?=\n\t\tSome\(BareAcceptedGlobal)",
            infer_source,
            re.DOTALL,
        )
        self.assertIsNotNone(accepted_name)
        self.assertIn("binding.source_name", accepted_name.group(0))
        self.assertIn("binding.id", accepted_name.group(0))
        self.assertNotIn("module_path", accepted_name.group(0))

    def test_qualified_accepted_ufcs_preserves_exact_identity(self) -> None:
        authority_source = CALLABLE_AUTHORITY.read_text(encoding="utf-8")
        infer_source = INFER.read_text(encoding="utf-8")

        lookup = re.search(
            r"pure func accepted_callable_lookup_qualified_ufcs\(.*?"
            r"(?=\n\npure func)",
            authority_source,
            re.DOTALL,
        )
        self.assertIsNotNone(lookup)
        self.assertIn("List[AcceptedCallableBinding]", lookup.group(0))
        self.assertIn("binding_from_slot", lookup.group(0))

        selection = re.search(
            r"pure func accepted_callable_select_ufcs_method\(.*?"
            r"(?=\n\npure func)",
            authority_source,
            re.DOTALL,
        )
        self.assertIsNotNone(selection)
        self.assertIn("Option[AcceptedCallableBinding]", selection.group(0))
        self.assertIn("overload_entry_ufcs_selection_score", selection.group(0))

        accepted_inference = re.search(
            r"private pure func infer_accepted_ufcs_call_with_receiver_result\(.*?"
            r"(?=\n\nprivate pure func)",
            infer_source,
            re.DOTALL,
        )
        self.assertIsNotNone(accepted_inference)
        self.assertIn("binding: AcceptedCallableBinding", accepted_inference.group(0))
        self.assertIn("binding.id", accepted_inference.group(0))
        self.assertIn("binding.source_name", accepted_inference.group(0))
        self.assertNotIn("module_path", accepted_inference.group(0))
        self.assertNotIn(
            "callable_id_from_reserved_graph_definition",
            accepted_inference.group(0),
        )

        qualified_inference = re.search(
            r"private pure func infer_qualified_module_ufcs_call_expr\(.*?"
            r"(?=\n\nprivate pure func)",
            infer_source,
            re.DOTALL,
        )
        self.assertIsNotNone(qualified_inference)
        self.assertIn("accepted_callable_select_ufcs_method", qualified_inference.group(0))
        self.assertIn(
            "infer_accepted_ufcs_call_with_receiver_result",
            qualified_inference.group(0),
        )
        self.assertNotIn("env_select_ufcs_method", qualified_inference.group(0))
        self.assertIn("accepted_callable_lookup_qualified_ufcs", qualified_inference.group(0))

    def test_unqualified_accepted_ufcs_preserves_exact_identity(self) -> None:
        authority_source = CALLABLE_AUTHORITY.read_text(encoding="utf-8")
        infer_source = INFER.read_text(encoding="utf-8")

        lookup = re.search(
            r"pure func accepted_callable_lookup_ufcs\(.*?"
            r"(?=\n\npure func)",
            authority_source,
            re.DOTALL,
        )
        self.assertIsNotNone(lookup)
        self.assertIn("List[AcceptedCallableBinding]", lookup.group(0))
        self.assertNotIn("List[OverloadEntry]", lookup.group(0))

        origin = re.search(
            r"pure func accepted_callable_ufcs_origin\(.*?"
            r"(?=\n\npure func)",
            authority_source,
            re.DOTALL,
        )
        self.assertIsNotNone(origin)
        self.assertIn("Option[AcceptedCallableUfcsOrigin]", origin.group(0))
        self.assertIn("slot.source_name_id", origin.group(0))
        self.assertIn("callable_ids_equal(target, binding.id)", origin.group(0))
        self.assertNotIn("module_path", origin.group(0))

        resolved = re.search(
            r"private pure func resolve_visible_ufcs_method\(.*?"
            r"(?=\n\nprivate pure func)",
            infer_source,
            re.DOTALL,
        )
        self.assertIsNotNone(resolved)
        self.assertIn("Option[VisibleUfcsMethod]", resolved.group(0))

        selection = re.search(
            r"private pure func select_visible_ufcs_candidates\(.*?"
            r"(?=\n\nprivate pure func)",
            infer_source,
            re.DOTALL,
        )
        self.assertIsNotNone(selection)
        self.assertIn("AcceptedVisibleUfcsMethod", selection.group(0))
        self.assertIn("CompatibilityVisibleUfcsMethod", selection.group(0))

        retry = re.search(
            r"private pure func retry_ufcs_call_candidates\(.*?"
            r"(?=\n\nprivate pure func)",
            infer_source,
            re.DOTALL,
        )
        self.assertIsNotNone(retry)
        self.assertIn("selected: VisibleUfcsMethod", retry.group(0))
        self.assertIn("infer_accepted_ufcs_call_with_receiver_result", retry.group(0))
        self.assertIn("accepted_callable_ufcs_bindings_share_owner", retry.group(0))
        accepted_retry = retry.group(0).split("CompatibilityVisibleUfcsMethod", 1)[0]
        self.assertNotIn("module_path", accepted_retry)
        self.assertNotIn("callable_id_from_reserved_graph_definition", accepted_retry)

    def test_accepted_trait_method_lookup_preserves_exact_identity(self) -> None:
        authority_source = TRAIT_IMPLEMENTATION_AUTHORITY.read_text(encoding="utf-8")
        infer_source = INFER.read_text(encoding="utf-8")

        authority_rep = re.search(
            r"private record AcceptedTraitImplementationAuthorityRep \{.*?\n\}",
            authority_source,
            re.DOTALL,
        )
        self.assertIsNotNone(authority_rep)
        self.assertIn(
            "visible_trait_methods: List[AcceptedVisibleTraitMethodRow]",
            authority_rep.group(0),
        )
        self.assertNotIn("trait_method_id_by_name", authority_rep.group(0))
        self.assertNotIn("trait_name_by_method_name", authority_rep.group(0))

        visibility_row = re.search(
            r"private record AcceptedVisibleTraitMethodRow \{.*?\n\}",
            authority_source,
            re.DOTALL,
        )
        self.assertIsNotNone(visibility_row)
        self.assertIn("source_name_id: SourceNameId", visibility_row.group(0))
        self.assertIn("method_id: TraitMethodId", visibility_row.group(0))
        self.assertNotIn("String", visibility_row.group(0))

        visibility_binding = re.search(
            r"private union AcceptedVisibleTraitBinding:.*?"
            r"(?=\n\nprivate record)",
            authority_source,
            re.DOTALL,
        )
        self.assertIsNotNone(visibility_binding)
        self.assertIn(
            "AcceptedVisibleTraitMethodBinding(SourceNameId, TraitMethodId)",
            visibility_binding.group(0),
        )
        self.assertNotIn(
            "AcceptedVisibleTraitMethodBinding(String, ModuleId, String)",
            visibility_binding.group(0),
        )

        lookup = re.search(
            r"pure func accepted_trait_find_function_method\(.*?"
            r"(?=\n\npure func)",
            authority_source,
            re.DOTALL,
        )
        self.assertIsNotNone(lookup)
        self.assertIn("Option[AcceptedTraitMethodBinding]", lookup.group(0))
        self.assertIn("source_name_table_find_id", lookup.group(0))
        self.assertIn("visible_trait_method_for_source_name", lookup.group(0))
        self.assertIn("table_find_trait_method_by_id", lookup.group(0))
        self.assertIn("into_opaque AcceptedTraitMethodBinding", lookup.group(0))
        self.assertNotIn(
            "pure func accepted_trait_find_method_by_id",
            authority_source,
        )

        exact_lookup = re.search(
            r"private pure func infer_find_function_trait_method\(.*?"
            r"(?=\n\nprivate pure func)",
            infer_source,
            re.DOTALL,
        )
        self.assertIsNotNone(exact_lookup)
        self.assertIn("accepted_trait_find_function_method", exact_lookup.group(0))
        self.assertNotIn("accepted_trait_find_method_by_id", exact_lookup.group(0))
        self.assertNotIn("accepted_trait_function_trait", infer_source)

    def test_accepted_trait_definition_visibility_uses_exact_rows(self) -> None:
        authority_source = TRAIT_IMPLEMENTATION_AUTHORITY.read_text(encoding="utf-8")

        authority_rep = re.search(
            r"private record AcceptedTraitImplementationAuthorityRep \{.*?\n\}",
            authority_source,
            re.DOTALL,
        )
        self.assertIsNotNone(authority_rep)
        self.assertIn(
            "visible_traits: List[AcceptedVisibleTraitRow]",
            authority_rep.group(0),
        )
        self.assertNotIn("visible_trait_indices_by_name", authority_rep.group(0))
        self.assertIn(
            "trait_indices_by_semantic_name: Dict[String, Int]",
            authority_rep.group(0),
        )

        visibility_row = re.search(
            r"private record AcceptedVisibleTraitRow \{.*?\n\}",
            authority_source,
            re.DOTALL,
        )
        self.assertIsNotNone(visibility_row)
        self.assertIn("source_name_id: SourceNameId", visibility_row.group(0))
        self.assertIn("trait_id: TraitId", visibility_row.group(0))
        self.assertNotIn("String", visibility_row.group(0))

        visibility_binding = re.search(
            r"private union AcceptedVisibleTraitBinding:.*?"
            r"(?=\n\nprivate record)",
            authority_source,
            re.DOTALL,
        )
        self.assertIsNotNone(visibility_binding)
        self.assertIn(
            "AcceptedVisibleTraitDefinitionBinding(SourceNameId, TraitId)",
            visibility_binding.group(0),
        )
        self.assertNotIn(
            "AcceptedVisibleTraitDefinitionBinding(String, TraitId)",
            visibility_binding.group(0),
        )

        lookup = re.search(
            r"private pure func visible_trait_index_for_name\(.*?"
            r"(?=\n\npure func)",
            authority_source,
            re.DOTALL,
        )
        self.assertIsNotNone(lookup)
        self.assertIn("source_name_table_find_id", lookup.group(0))
        self.assertIn("visible_trait_for_source_name", lookup.group(0))
        self.assertIn("table_find_trait_index", lookup.group(0))

    def test_selected_accepted_trait_call_preserves_exact_identity(self) -> None:
        infer_source = INFER.read_text(encoding="utf-8")

        target = re.search(
            r"union ResolvedCallTarget:.*?(?=\n\nenum ResolvedLoopProducer)",
            infer_source,
            re.DOTALL,
        )
        self.assertIsNotNone(target)
        self.assertIn(
            "ResolvedAcceptedTraitMethodCall(TraitId, CallableId)",
            target.group(0),
        )

        callee_identity = re.search(
            r"private union TraitMethodCalleeIdentity:.*?"
            r"(?=\n\nprivate record TraitMethodCallee)",
            infer_source,
            re.DOTALL,
        )
        self.assertIsNotNone(callee_identity)
        self.assertIn(
            "AcceptedTraitMethodCalleeIdentity(TraitId)",
            callee_identity.group(0),
        )
        self.assertIn(
            "CompatibilityTraitMethodCalleeIdentity",
            callee_identity.group(0),
        )

        resolution = re.search(
            r"private pure func resolved_call_from_trait_method_callee\(.*?"
            r"(?=\n\nprivate pure func)",
            infer_source,
            re.DOTALL,
        )
        self.assertIsNotNone(resolution)
        self.assertIn("ResolvedAcceptedTraitMethodCall", resolution.group(0))
        self.assertIn("AcceptedTraitMethodCalleeIdentity", resolution.group(0))
        self.assertIn("trait_method_id_owner", infer_source)

    def test_selected_accepted_trait_call_validates_both_ids_at_phase_boundaries(self) -> None:
        declaration_skeleton = (
            ROOT
            / "blorp/src/compiler/stage_06_typecheck/headers/declaration_skeleton.brp"
        ).read_text(encoding="utf-8")
        typed_ast_json = (
            ROOT / "blorp/src/compiler/stage_06_typecheck/typed_ast_json.brp"
        ).read_text(encoding="utf-8")
        ctfe_ir = (
            ROOT / "blorp/src/compiler/stage_07_ctfe/ir.brp"
        ).read_text(encoding="utf-8")
        core_lower = (
            ROOT / "blorp/src/compiler/stage_08_core_lower/lower.brp"
        ).read_text(encoding="utf-8")

        self.assertIn("pure func trait_id_is_valid(", declaration_skeleton)
        for consumer in (typed_ast_json, ctfe_ir, core_lower):
            self.assertIn("trait_id_is_valid", consumer)

    def test_qualified_accepted_trait_selection_preserves_exact_identity(self) -> None:
        authority_source = (
            ROOT
            / "blorp/src/compiler/stage_06_typecheck/type_system/accepted_trait_implementation_authority.brp"
        ).read_text(encoding="utf-8")
        infer_source = INFER.read_text(encoding="utf-8")

        qualified_info = re.search(
            r"private record AcceptedQualifiedTraitMethodInfoRep \{.*?\n\}",
            authority_source,
            re.DOTALL,
        )
        self.assertIsNotNone(qualified_info)
        self.assertIn("trait_id: TraitId", qualified_info.group(0))
        self.assertIn("trait_identity: BoundTraitIdentity", qualified_info.group(0))
        self.assertNotIn("Option[BoundTraitIdentity]", qualified_info.group(0))
        self.assertIn(
            "opaque type AcceptedQualifiedTraitMethodInfo = AcceptedQualifiedTraitMethodInfoRep",
            authority_source,
        )
        for projection in (
            "accepted_qualified_trait_method_id",
            "accepted_qualified_trait_method_identity",
            "accepted_qualified_trait_method_signature",
            "accepted_qualified_trait_implementation_method",
        ):
            self.assertIn(f"pure func {projection}(", authority_source)

        selection = re.search(
            r"private union QualifiedTraitMethodSelection:.*?"
            r"(?=\n\nprivate pure func infer_find_qualified_trait_method_selection)",
            infer_source,
            re.DOTALL,
        )
        self.assertIsNotNone(selection)
        self.assertIn("AcceptedQualifiedTraitMethodSelection", selection.group(0))
        self.assertIn("CompatibilityQualifiedTraitMethodSelection", selection.group(0))

        qualified_resolution = re.search(
            r"private pure func infer_qualified_module_trait_call_expr\(.*?"
            r"(?=\n\nprivate enum VisibleUfcsOrigin)",
            infer_source,
            re.DOTALL,
        )
        self.assertIsNotNone(qualified_resolution)
        self.assertRegex(
            qualified_resolution.group(0),
            r"AcceptedTraitMethodCalleeIdentity\(\s*accepted_qualified_trait_method_id\(",
        )

    def test_accepted_trait_policies_consume_exact_identity(self) -> None:
        authority_source = TRAIT_IMPLEMENTATION_AUTHORITY.read_text(encoding="utf-8")
        infer_source = INFER.read_text(encoding="utf-8")

        for query in (
            "accepted_trait_matches_compiler_identity",
            "accepted_resolve_trait_id_obligation",
            "accepted_find_impl_method_info_by_trait_id",
        ):
            self.assertIn(f"pure func {query}(", authority_source)
            self.assertIn(query, infer_source)

            exact_query = re.search(
                rf"pure func {query}\(.*?(?=\n\n(?:private )?pure func)",
                authority_source,
                re.DOTALL,
            )
            self.assertIsNotNone(exact_query)
            self.assertIn("issuing_table: DefinitionTable", exact_query.group(0))

        identity_lookup = re.search(
            r"private pure func table_find_trait_identity_index\(.*?"
            r"(?=\n\nprivate pure func)",
            authority_source,
            re.DOTALL,
        )
        self.assertIsNotNone(identity_lookup)
        self.assertIn("issuing_table: DefinitionTable", identity_lookup.group(0))
        self.assertIn("definition_tables_share_provenance", identity_lookup.group(0))

        self.assertNotIn("infer_facts_accepted_trait_method_name", infer_source)

        elementwise = re.search(
            r"private pure func resolved_call_supports_elementwise_tensor_call\(.*?"
            r"(?=\n\nprivate pure func)",
            infer_source,
            re.DOTALL,
        )
        self.assertIsNotNone(elementwise)
        accepted_elementwise = elementwise.group(0).split(
            "ResolvedAcceptedTraitMethodCall", 1
        )[1]
        self.assertIn(
            "accepted_trait_method_supports_elementwise_tensor_call",
            accepted_elementwise,
        )
        accepted_elementwise_policy = re.search(
            r"private pure func accepted_trait_method_supports_elementwise_tensor_call\(.*?"
            r"(?=\n\nprivate pure func)",
            infer_source,
            re.DOTALL,
        )
        self.assertIsNotNone(accepted_elementwise_policy)
        self.assertIn(
            "accepted_trait_matches_compiler_identity",
            accepted_elementwise_policy.group(0),
        )
        self.assertNotIn("trait_id_name", accepted_elementwise_policy.group(0))

        self_bound = re.search(
            r"private pure func check_trait_method_self_bound\(.*?"
            r"(?=\n\nprivate pure func)",
            infer_source,
            re.DOTALL,
        )
        self.assertIsNotNone(self_bound)
        accepted_self_bound = self_bound.group(0).split(
            "ResolvedAcceptedTraitMethodCall", 1
        )[1].split("ResolvedSelectedTraitMethodCall", 1)[0]
        self.assertIn("accepted_resolve_trait_id_obligation", accepted_self_bound)
        self.assertNotIn("trait_obligation(obligation_type", accepted_self_bound)

        self_resolution = re.search(
            r"private pure func resolve_trait_self_call\(.*?"
            r"(?=\n\nprivate pure func)",
            infer_source,
            re.DOTALL,
        )
        self.assertIsNotNone(self_resolution)
        resource_policy_match = re.search(
            r"resource_args = match updated_resolved_call:.*?"
            r"(?=\n\n\t\t\t\tfinal_resolved_call)",
            self_resolution.group(0),
            re.DOTALL,
        )
        self.assertIsNotNone(resource_policy_match)
        accepted_resource_policy = resource_policy_match.group(0).split(
            "ResolvedAcceptedTraitMethodCall", 1
        )[1].split("ResolvedSelectedTraitMethodCall", 1)[0]
        self.assertIn(
            "accepted_trait_method_resource_args_for_type",
            accepted_resource_policy,
        )
        self.assertNotRegex(
            accepted_resource_policy,
            r"(?<!accepted_)trait_method_resource_args_for_type\(",
        )
        accepted_resource_query = re.search(
            r"private pure func accepted_trait_method_resource_args_for_type\(.*?"
            r"(?=\n\nprivate pure func)",
            infer_source,
            re.DOTALL,
        )
        self.assertIsNotNone(accepted_resource_query)
        self.assertIn(
            "accepted_find_impl_method_info_by_trait_id",
            accepted_resource_query.group(0),
        )
        self.assertNotIn("trait_id_name", accepted_resource_query.group(0))

    def test_unresolved_accepted_trait_call_preserves_exact_identity(self) -> None:
        infer_source = INFER.read_text(encoding="utf-8")
        typed_ast_json = (
            ROOT / "blorp/src/compiler/stage_06_typecheck/typed_ast_json.brp"
        ).read_text(encoding="utf-8")
        ctfe_ir = (
            ROOT / "blorp/src/compiler/stage_07_ctfe/ir.brp"
        ).read_text(encoding="utf-8")
        core_lower = (
            ROOT / "blorp/src/compiler/stage_08_core_lower/lower.brp"
        ).read_text(encoding="utf-8")

        target = re.search(
            r"union ResolvedCallTarget:.*?(?=\n\nenum ResolvedLoopProducer)",
            infer_source,
            re.DOTALL,
        )
        self.assertIsNotNone(target)
        self.assertIn(
            "ResolvedAcceptedUnresolvedTraitMethodCall(TraitId)",
            target.group(0),
        )

        resolution = re.search(
            r"private pure func resolved_call_from_trait_method_callee\(.*?"
            r"(?=\n\nprivate pure func)",
            infer_source,
            re.DOTALL,
        )
        self.assertIsNotNone(resolution)
        unresolved = resolution.group(0).split("None:", 1)[1]
        self.assertIn("AcceptedTraitMethodCalleeIdentity", unresolved)
        self.assertIn("ResolvedAcceptedUnresolvedTraitMethodCall", unresolved)
        self.assertIn("ResolvedUnresolvedTraitMethodCall", unresolved)

        for consumer in (typed_ast_json, ctfe_ir, core_lower):
            self.assertIn("ResolvedAcceptedUnresolvedTraitMethodCall", consumer)
            self.assertIn("trait_id_is_valid", consumer)

if __name__ == "__main__":
    unittest.main()
