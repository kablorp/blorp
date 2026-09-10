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
GLOBAL_HEADER_COMPLETION = (
    ROOT
    / "blorp/src/compiler/stage_06_typecheck/headers/global_header_completion.brp"
)
DECLARATION_SKELETON = (
    ROOT / "blorp/src/compiler/stage_06_typecheck/headers/declaration_skeleton.brp"
)
DEFINITION_IDENTITY = (
    ROOT / "blorp/src/compiler/stage_06_typecheck/graph/definition_identity.brp"
)
DEFINITION_INDEX = (
    ROOT / "blorp/src/compiler/stage_06_typecheck/graph/definition_index.brp"
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
class DeclarationBoundaryTests(unittest.TestCase):
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

    def test_graph_declaration_ids_store_only_module_foreign_keys(self) -> None:
        source = DECLARATION_SKELETON.read_text(encoding="utf-8")
        structural_id = re.search(
            r"private record StructuralDeclarationIdRep \{.*?\n\}",
            source,
            re.DOTALL,
        )

        self.assertIsNotNone(structural_id)
        body = structural_id.group(0)
        self.assertIn("module_id: ModuleId", body)
        self.assertNotIn("ModuleIdentity", body)
        self.assertNotIn("ModuleTable", body)
        self.assertNotIn("PreparedModuleScope", body)

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
            "accepted_record_graph_table": RECORD_GRAPH,
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
        source = TYPE_HEADER_INSTALL.read_text(encoding="utf-8")
        function = re.search(
            r"private pure func install_alias_header\(.*?"
            r"(?=\n\npure func typecheck_install_local_builtin_headers)",
            source,
            re.DOTALL,
        )

        self.assertIsNotNone(function)
        body = function.group(0)
        authority_branch = body.index(
            "match module_view_accepted_alias_authority(state.module_view)"
        )
        provisional_conversion = body.index("semantic_type_from_resolved_shape(")
        self.assertLess(authority_branch, provisional_conversion)
        self.assertIn("accepted_alias_contains(authority, type_name)", body)

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
            "indices_by_module_and_name: List[Dict[String, List[Int]]]",
            table.group(0),
        )
        self.assertNotIn("indices_by_module_path_and_name", table.group(0))
        self.assertIn("owner_module_path: Option[String]", authority.group(0))
        self.assertNotIn("ModuleIdentity", source)
        self.assertNotIn("identity_keys_by_module_path", table.group(0))

    def test_global_authority_locality_uses_the_existing_module_path_index(self) -> None:
        source = (
            ROOT
            / "blorp/src/compiler/stage_06_typecheck/type_system/accepted_global_authority.brp"
        ).read_text(encoding="utf-8")
        authority = re.search(
            r"private record AcceptedGlobalAuthorityRep \{.*?\n\}",
            source,
            re.DOTALL,
        )

        self.assertIsNotNone(authority)
        self.assertIn("owner_module_path: String", authority.group(0))
        self.assertNotIn("owner: ModuleIdentity", authority.group(0))
        self.assertNotIn("module_identities_equal", source)

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
        self.assertIn("trait_indices_by_module: List[List[Int]]", table.group(0))
        self.assertIn("implementation_indices_by_module: List[List[Int]]", table.group(0))
        self.assertNotIn("trait_indices_by_module_path", table.group(0))
        self.assertNotIn("implementation_indices_by_module_path", table.group(0))
        self.assertNotIn("by_module_identity", table.group(0))
        self.assertIn("owner_module_path: String", authority.group(0))
        self.assertNotIn("owner: ModuleIdentity", authority.group(0))

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

    def test_body_outcome_index_does_not_retain_module_identity(self) -> None:
        source = DECL.read_text(encoding="utf-8")
        representation = re.search(
            r"private record BodyOutcomeIndexRep \{.*?\n\}", source, re.DOTALL
        )
        constructor = re.search(
            r"private pure func body_outcome_index\(.*?"
            r"(?=\n\nprivate pure func body_outcome_index_for_base)",
            source,
            re.DOTALL,
        )
        lookup = re.search(
            r"private pure func body_outcome_index_find\(.*?"
            r"(?=\n\nprivate pure func body_outcome_index_find_definition_id)",
            source,
            re.DOTALL,
        )

        self.assertIsNotNone(representation)
        self.assertIsNotNone(constructor)
        self.assertIsNotNone(lookup)
        self.assertNotIn("owner: ModuleIdentity", representation.group(0))
        self.assertIn("owner_scope: PreparedModuleScope", constructor.group(0))
        self.assertIn("callable_ids_equal", lookup.group(0))

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

    def test_accepted_graph_fallbacks_require_prepared_scope(self) -> None:
        for category, path in (
            ("alias", ALIAS_GRAPH),
            ("record", RECORD_GRAPH),
            ("union", UNION_GRAPH),
        ):
            with self.subTest(category=category):
                source = path.read_text(encoding="utf-8")
                fallback = re.search(
                    rf"pure func accepted_{category}_graph_canonical_authority\(.*?"
                    rf"(?=\n\npure func)",
                    source,
                    re.DOTALL,
                )

                self.assertIsNotNone(fallback)
                self.assertIn("owner_scope: PreparedModuleScope", fallback.group(0))
                self.assertNotIn("owner: ModuleIdentity", fallback.group(0))

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

if __name__ == "__main__":
    unittest.main()
