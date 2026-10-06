"""Contract for the identity work-counter benchmark scripts and their compiler worker helper."""

from pathlib import Path
import runpy
import sys
import unittest


ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / "benchmarks"))
PARSER = runpy.run_path(str(ROOT / "benchmarks/compiler_identity_work_counters"))
REPLAY = runpy.run_path(str(ROOT / "benchmarks/compiler_identity_work_replay"))
WORKER_HELPER = runpy.run_path(str(ROOT / "benchmarks/compiler_benchmark_worker.py"))
FUNCTIONS = PARSER["FUNCTIONS"]


def diagnostics(mode: str, selected: int, observed: int, calls: int) -> str:
    return (
        f"PROFILE_DIAGNOSTICS profile_mode={mode} functions_selected={selected} "
        f"functions_observed={observed} calls_observed={calls} "
        f"calls_completed={0 if mode == 'calls' else calls} "
        "abandoned_frames=0 window_abandoned_frames=0 stack_growths=0 "
        + " ".join(f"{name}=0" for name in PARSER["LOSS_DIAGNOSTICS"])
    )


class IdentityWorkCounterTests(unittest.TestCase):
    def test_compiler_command_builds_the_profile_flags_and_rejects_bad_combinations(self) -> None:
        selectors = REPLAY["PROFILE_FUNCTIONS"]
        compiler_command = WORKER_HELPER["_compiler_command"]
        args = (Path("bin/blorp"), Path("worker.c"), Path("worker.brp"))
        self.assertEqual(
            compiler_command(*args),
            ["bin/blorp", "compile", "--no-format", "-o", "worker.c", "worker.brp"],
        )
        self.assertEqual(
            compiler_command(*args, debug_profile=True),
            ["bin/blorp", "compile", "--no-format", "--debug", "--profile", "-o", "worker.c", "worker.brp"],
        )
        selected = compiler_command(*args, debug_profile=True, profile_functions=selectors, profile_mode="calls")
        self.assertEqual(selected[3:6], ["--debug", "--profile-mode", "calls"])
        self.assertEqual(selected.count("--profile-function"), len(selectors))
        for selector in selectors:
            self.assertIn(selector, selected)
        with self.assertRaises(ValueError):
            compiler_command(*args, profile_functions=selectors)
        with self.assertRaises(ValueError):
            compiler_command(*args, profile_mode="calls")
        with self.assertRaises(ValueError):
            compiler_command(*args, debug_profile=True, profile_mode="sampled")

    def test_link_command_adds_the_replay_source_only_when_asked(self) -> None:
        link = WORKER_HELPER["_link_command"]
        args = (["cc"], ROOT, Path("worker.o"), Path("wrapper.c"), Path("worker"))
        default = link(*args)
        hook = str((ROOT / "blorp/src/lsp/server/native_runtime.c").resolve())
        self.assertNotIn(hook, default)
        with_hook = link(*args, (Path("blorp/src/lsp/server/native_runtime.c"),))
        self.assertEqual(with_hook.count(hook), 1)
        self.assertEqual([part for part in with_hook if part != hook], default)

    def test_profile_parser_rejects_loss_and_selector_drift(self) -> None:
        calls_table = "\n".join(f"{name} brp_1 1" for name in FUNCTIONS)
        calls_diag = diagnostics("calls", 3, 3, 3)
        parse = PARSER["parse_profile"]
        self.assertEqual(
            parse(calls_table + "\n" + calls_diag, expected_mode="calls"),
            {short: 1 for short in FUNCTIONS.values()},
        )
        for name in PARSER["LOSS_DIAGNOSTICS"]:
            with self.subTest(loss=name), self.assertRaises(ValueError):
                parse(
                    calls_table + "\n" + calls_diag.replace(f"{name}=0", f"{name}=1"),
                    expected_mode="calls",
                )
        # An extra selected function may have zero calls, so row totals still
        # agree; the selection contract must reject it separately.
        for value in (2, 4):
            with self.subTest(selected=value), self.assertRaises(ValueError):
                parse(calls_table + "\n" + calls_diag.replace("functions_selected=3", f"functions_selected={value}"), expected_mode="calls")
            with self.subTest(observed=value), self.assertRaises(ValueError):
                parse(calls_table + "\n" + calls_diag.replace("functions_observed=3", f"functions_observed={value}"), expected_mode="calls")
        with self.assertRaises(ValueError):
            parse(calls_table + "\n" + calls_diag.replace("functions_selected=3 ", ""), expected_mode="calls")
        with self.assertRaises(ValueError):
            parse(calls_table + "\n" + calls_diag.replace("calls_observed=3", "calls_observed=4"), expected_mode="calls")
        with self.assertRaises(ValueError):
            parse(calls_table + "\n" + calls_diag.replace("profile_mode=calls", "profile_mode=exact"), expected_mode="calls")
        with self.assertRaises(ValueError):
            parse(calls_table)
        with self.assertRaises(ValueError):
            parse(calls_table + "\n" + calls_diag, expected_mode="exact")

    def test_exact_toy_profile_requires_both_live_paths(self) -> None:
        toy_names = {full: short for full, short in FUNCTIONS.items() if short in PARSER["TOY_FUNCTIONS"]}
        rows = "\n".join(f"{name} brp_1 0.001 0.001 0.0% 2 1.000" for name in toy_names)
        profile = rows + "\n" + diagnostics("exact", 100, 100, 4)
        self.assertEqual(PARSER["parse_profile"](profile), {"core_var_equal": 2, "scope_lookup": 2})
        with self.assertRaises(ValueError):
            PARSER["parse_profile"](rows.splitlines()[0] + "\n" + diagnostics("exact", 100, 100, 4))

    def test_replay_resource_row_is_required(self) -> None:
        parse = PARSER["replay_resources"]
        self.assertEqual(
            parse("       39.43 real        37.93 user\n          8399011840  maximum resident set size"),
            {"elapsed_seconds": 39.43, "max_rss_bytes": 8399011840},
        )
        with self.assertRaises(ValueError):
            parse("       39.43 real        37.93 user")


if __name__ == "__main__":
    unittest.main()
