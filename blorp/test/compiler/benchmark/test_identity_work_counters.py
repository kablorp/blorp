"""Static contract for opt-in identity work markers."""

from pathlib import Path
import re
import runpy
import unittest


ROOT = Path(__file__).resolve().parents[4]
COUNTERS = ROOT / "blorp/src/compiler/identity_work_counters.brp"
MARKERS = (
    "identity_work_core_var_equal",
    "identity_work_local_scope_lookup",
    "identity_work_observed_core_var_constructor_helper_calls",
    "identity_work_observed_display_lookup",
)
PARSER = runpy.run_path(str(ROOT / "benchmarks/compiler_identity_work_counters"))
WORKER_HELPER = runpy.run_path(str(ROOT / "benchmarks/compiler_benchmark_worker.py"))
EXPECTED_FULL_FIELD_SITES = {
    "stage_08_core_lower/entrypoint.brp": 2,
    "stage_08_core_lower/lower.brp": 1,
    "stage_09_core/clone.brp": 1,
    "stage_09_core/closure.brp": 2,
    "stage_09_core/collection_pipeline.brp": 1,
    "stage_09_core/consume_specialize.brp": 2,
    "stage_09_core/ir.brp": 1,
    "stage_09_core/match_lowering.brp": 1,
    "stage_09_core/match_projection.brp": 2,
    "stage_09_core/mono_option.brp": 1,
    "stage_09_core/parallel_tensor_pipeline.brp": 1,
    "stage_09_core/perceus/balance.brp": 2,
    "stage_09_core/perceus/borrowed.brp": 1,
    "stage_09_core/perceus/mutable.brp": 1,
    "stage_09_core/perceus/results_and_loops.brp": 4,
    "stage_09_core/record_update.brp": 1,
    "stage_09_core/resolve.brp": 10,
    "stage_09_core/specialize.brp": 1,
    "stage_09_core/specialize_collection.brp": 1,
    "stage_09_core/ssa.brp": 1,
    "stage_09_core/std_inline.brp": 1,
    "stage_09_core/string_pipeline.brp": 1,
    "stage_09_core/synth_fixed.brp": 1,
    "stage_09_core/synth_nodes.brp": 1,
    "stage_09_core/tailrec.brp": 1,
    "stage_09_core/tensor_specialize.brp": 2,
    "stage_09_core/trait_resolve.brp": 2,
    "stage_09_core/tuple_sroa.brp": 1,
}


class IdentityWorkCounterTests(unittest.TestCase):
    def test_replay_profile_selectors_are_explicit_and_default_is_unchanged(self) -> None:
        compiler_command = WORKER_HELPER["_compiler_command"]
        args = (Path("bin/blorp"), Path("worker.c"), Path("worker.brp"))
        self.assertEqual(
            compiler_command(*args),
            ["bin/blorp", "compile", "--no-format", "-o", "worker.c", "worker.brp"],
        )
        self.assertEqual(
            compiler_command(*args, debug_profile=True),
            [
                "bin/blorp", "compile", "--no-format", "--debug", "--profile",
                "-o", "worker.c", "worker.brp",
            ],
        )
        selectors = (
            "blorp/src/compiler/identity_work_counters::identity_work_core_var_equal",
            "blorp/src/compiler/identity_work_counters::register_identity_work_counters",
        )
        selected = compiler_command(*args, debug_profile=True, profile_functions=selectors)
        self.assertEqual(selected.count("--profile-function"), 2)
        self.assertEqual(selected[5:9], ["--profile-function", selectors[0], "--profile-function", selectors[1]])
        with self.assertRaises(ValueError):
            compiler_command(*args, profile_functions=selectors)
        calls = compiler_command(
            *args, debug_profile=True, profile_functions=selectors, profile_mode="calls"
        )
        self.assertEqual(calls[3:6], ["--debug", "--profile-mode", "calls"])
        self.assertEqual(calls.count("--profile-function"), 2)
        with self.assertRaises(ValueError):
            compiler_command(*args, profile_mode="calls")
        with self.assertRaises(ValueError):
            compiler_command(*args, debug_profile=True, profile_mode="sampled")

    def test_replay_link_source_is_explicit_and_default_is_unchanged(self) -> None:
        link = WORKER_HELPER["_link_command"]
        args = (["cc"], ROOT, Path("worker.o"), Path("wrapper.c"), Path("worker"))
        default = link(*args)
        self.assertEqual(default.count(str(ROOT / "blorp/src/lsp/server/native_runtime.c")), 0)
        with_hook = link(
            *args, (Path("blorp/src/lsp/server/native_runtime.c"),)
        )
        hook = str((ROOT / "blorp/src/lsp/server/native_runtime.c").resolve())
        self.assertEqual(with_hook.count(hook), 1)
        self.assertEqual([part for part in with_hook if part != hook], default)

    def test_profile_parser_rejects_loss_and_corruption(self) -> None:
        row = "{name} brp_1 0.001 0.001 0.0% {calls} 1.000"
        prefix = "blorp_src_compiler_identity_work_counters__"
        table = "\n".join(
            [row.format(name=prefix + "register_identity_work_counters", calls=1)]
            + [row.format(name=prefix + name, calls=1) for name in MARKERS]
        )
        diagnostics = (
            "PROFILE_DIAGNOSTICS profile_mode=exact functions_observed=5 calls_observed=0 calls_completed=5 "
            + " ".join(f"{name}=0" for name in PARSER["LOSS_DIAGNOSTICS"])
        )
        parse = PARSER["parse_profile"]
        self.assertEqual(parse(table + "\n" + diagnostics), {name: 0 for name in MARKERS})
        for name in PARSER["LOSS_DIAGNOSTICS"]:
            with self.subTest(name=name), self.assertRaises(ValueError):
                parse(table + "\n" + diagnostics.replace(f"{name}=0", f"{name}=1"))
        with self.assertRaises(ValueError):
            parse(table)
        with self.assertRaises(ValueError):
            parse(table + "\n" + diagnostics.replace("profile_mode=exact", "profile_mode=calls"))

        calls_table = "\n".join(
            [f"{prefix}register_identity_work_counters brp_1 1"]
            + [f"{prefix}{name} brp_1 1" for name in MARKERS]
        )
        calls_diagnostics = (
            "PROFILE_DIAGNOSTICS profile_mode=calls functions_selected=5 functions_observed=5 "
            "calls_observed=5 calls_completed=0 abandoned_frames=0 "
            "window_abandoned_frames=0 stack_growths=0 "
            + " ".join(f"{name}=0" for name in PARSER["LOSS_DIAGNOSTICS"])
        )
        self.assertEqual(
            parse(calls_table + "\n" + calls_diagnostics, expected_mode="calls"),
            {name: 0 for name in MARKERS},
        )
        for name in PARSER["LOSS_DIAGNOSTICS"]:
            with self.subTest(mode="calls", name=name), self.assertRaises(ValueError):
                parse(
                    calls_table + "\n" + calls_diagnostics.replace(f"{name}=0", f"{name}=1"),
                    expected_mode="calls",
                )
        with self.assertRaises(ValueError):
            parse(calls_table + "\n" + calls_diagnostics.replace("calls_observed=5", "calls_observed=4"), expected_mode="calls")
        # An extra selected function may have zero calls, leaving all marker
        # rows and call totals unchanged. Selection must still be exact.
        for value in (4, 6):
            with self.subTest(functions_selected=value), self.assertRaises(ValueError):
                parse(
                    calls_table + "\n" + calls_diagnostics.replace(
                        "functions_selected=5", f"functions_selected={value}"
                    ),
                    expected_mode="calls",
                )
            with self.subTest(functions_observed=value), self.assertRaises(ValueError):
                parse(
                    calls_table + "\n" + calls_diagnostics.replace(
                        "functions_observed=5", f"functions_observed={value}"
                    ),
                    expected_mode="calls",
                )
        with self.assertRaises(ValueError):
            parse(
                calls_table + "\n" + calls_diagnostics.replace("functions_selected=5 ", ""),
                expected_mode="calls",
            )

    def test_observed_constructor_coverage_is_explicit(self) -> None:
        source_root = ROOT / "blorp/src/compiler"
        literal = re.compile(
            r"(?m)^\s*name\s*=.*\n\s*id\s*=.*\n\s*def_id\s*="
        )
        sites = {}
        for stage in ("stage_08_core_lower", "stage_09_core"):
            for path in (source_root / stage).rglob("*.brp"):
                count = len(literal.findall(path.read_text()))
                if count:
                    sites[str(path.relative_to(source_root))] = count
        self.assertEqual(sites, EXPECTED_FULL_FIELD_SITES)
        self.assertEqual(sum(sites.values()), 47)

        lower = (source_root / "stage_08_core_lower/lower.brp").read_text()
        helper = lower.split("private pure func core_var_impl(", 1)[1].split("\n\n", 1)[0]
        self.assertIn("identity_work_observed_core_var_constructor_helper_calls()", helper)
        self.assertEqual(
            sum(
                path.read_text().count(
                    "identity_work_observed_core_var_constructor_helper_calls()"
                )
                for stage in ("stage_08_core_lower", "stage_09_core")
                for path in (source_root / stage).rglob("*.brp")
            ),
            1,
        )

    def test_registered_schema_is_complete(self) -> None:
        source = COUNTERS.read_text()
        registered = source.split("pure func register_identity_work_counters()", 1)[1]
        for marker in MARKERS:
            self.assertRegex(source, rf"@debug_only pure func {marker}\(\) -> Int:")
            self.assertEqual(registered.count(f"{marker}()"), 1)
        self.assertEqual(
            set(re.findall(r"@debug_only pure func (identity_work_\w+)\(\)", source)),
            set(MARKERS),
        )

    def test_equality_and_scope_lookup_are_marked_before_work(self) -> None:
        ir = (ROOT / "blorp/src/compiler/stage_09_core/ir.brp").read_text()
        env = (ROOT / "blorp/src/compiler/stage_06_typecheck/type_system/env.brp").read_text()
        self.assertRegex(
            ir,
            r"pure func core_var_equal\([^\n]+\n\s*debug:\n\s*identity_work_core_var_equal\(\)\n\s*left\.name ==",
        )
        self.assertRegex(
            env,
            r"private pure func scope_lookup\([^\n]+\n\s*debug:\n\s*identity_work_local_scope_lookup\(\)\n\s*match scope\.symbols_by_name\.get",
        )


if __name__ == "__main__":
    unittest.main()
