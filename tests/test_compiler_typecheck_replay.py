#!/usr/bin/env python3
"""Contract tests for benchmarks/compiler_typecheck_replay."""

from __future__ import annotations

import hashlib
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "benchmarks" / "compiler_typecheck_replay"
RETENTION_SLICE_MODULES = [
    "std/string",
    "std/parser",
    "std/float",
    "std/json",
    "compiler/blorp/src/stage_09_core/compiler_core_json",
    "compiler/blorp/src/stage_09_core/compiler_core_c_type_layout",
    "compiler_core_closure",
]


def load_replay_module():
    loader = importlib.machinery.SourceFileLoader(
        "compiler_typecheck_replay_benchmark",
        str(SCRIPT),
    )
    spec = importlib.util.spec_from_loader(loader.name, loader)
    if spec is None:
        raise RuntimeError("could not create replay module spec")
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def request_json(action: str = "typecheck_graph") -> dict[str, object]:
    module = {
        "path": "dep.brp",
        "module": "dep",
        "module_path": "dep",
        "text": "pure func answer() -> Int: 41\n",
        "origin": {"kind": "user"},
    }
    target = {
        "path": "main.brp",
        "module": "main",
        "module_path": "main",
        "text": "func main(args: List[String]) -> Int: 0\n",
        "origin": {"kind": "user"},
    }
    return {
        "schema": 1,
        "domain": "compiler",
        "action": action,
        "payload": {
            "target": target,
            "modules": [module],
            "module_targets": ["dep"],
            "include_comments": False,
            "allow_debug_only_calls": False,
        },
    }


def fake_bridge_source() -> str:
    return textwrap.dedent(
        """\
        #!/usr/bin/env python3
        import json
        import os
        import sys
        import time

        delay = float(os.environ.get("BLORP_FAKE_TYPECHECK_DELAY", "0"))
        if delay:
            time.sleep(delay)
        forced_exit = int(os.environ.get("BLORP_FAKE_TYPECHECK_EXIT", "0"))
        if forced_exit:
            os._exit(forced_exit)
        allocation_mb = int(os.environ.get("BLORP_FAKE_TYPECHECK_ALLOCATE_MB", "0"))
        if allocation_mb:
            allocation = bytearray(allocation_mb * 1024 * 1024)
            allocation[0] = 1
            time.sleep(2)

        with open(sys.argv[1], encoding="utf-8") as request_file:
            request = json.load(request_file)

        payload = request["payload"]
        modules = {
            item["module_path"]: item
            for item in payload["modules"]
        }
        selected = [modules[name] for name in payload["module_targets"]]
        selected.append(payload["target"])
        inventory_enabled = "BLORP_COMPILER_TYPECHECK_INVENTORY" in os.environ
        allocator_stats_enabled = "BLORP_ALLOCATOR_STATS" in os.environ
        allocator_stats_unavailable = (
            "BLORP_FAKE_ALLOCATOR_STATS_UNAVAILABLE" in os.environ
        )
        start_bytes = -1 if allocator_stats_unavailable else 4096
        complete_bytes = -1 if allocator_stats_unavailable else 8192
        start_stats = (
            "total_allocations=0 total_releases=0 current_objects=0 "
            if allocator_stats_enabled
            else "total_allocations=10 total_releases=3 current_objects=7 "
        )
        complete_stats = (
            "total_allocations=0 total_releases=0 current_objects=0 "
            if allocator_stats_enabled
            else "total_allocations=20 total_releases=15 current_objects=5 "
        )

        for item in selected:
            reused = 1 if item["module_path"] == "dep" else 0
            typed_expr_nodes = 2 if reused else 0
            print(
                f"[typecheck-phase] phase=typecheck_start module={item['module_path']} "
                f"{start_stats}bytes_allocated={start_bytes}",
                file=sys.stderr,
                flush=True,
            )
            time.sleep(0.04)
            print(json.dumps({
                "schema": 1,
                "ok": True,
                "artifact": {
                    "path": item["path"],
                    "module": item["module"],
                    "ast_phase": "typecheck_source",
                    "typed_program": {
                        "kind": "typed_program",
                        "source": {},
                        "decls": [],
                        "diagnostics": [],
                    },
                    "ctfe_status": "not_run",
                    "type_errors": [],
                    "import_bindings": [],
                    "module_surface": {},
                },
            }), flush=True)
            print(
                f"[typecheck-phase] phase=typed_artifact_scope_complete module={item['module_path']} "
                f"{complete_stats}bytes_allocated={complete_bytes}",
                file=sys.stderr,
                flush=True,
            )
            if inventory_enabled:
                print(
                    f"[typecheck-inventory] kind=artifact module={item['module_path']} "
                    f"source_bytes=32 typed_decls=1 typed_expr_nodes={typed_expr_nodes} "
                    f"duplicates_retained_ctfe=0 reuses_retained_ctfe={reused}",
                    file=sys.stderr,
                    flush=True,
                )
                if not reused:
                    print(
                        f"[typecheck-inventory] kind=artifact_ownership "
                        f"module={item['module_path']} after_typecheck_unique=True "
                        "after_ctfe_unique=True after_module_construction_unique=True "
                        "before_artifact_release_unique=True",
                        file=sys.stderr,
                        flush=True,
                    )

        if inventory_enabled:
            print(
                "[typecheck-inventory] kind=graph module=main modules=1 "
                "selected_modules=1 parsed_source_bytes=72 parsed_decls=2 "
                "importable_decls=1 ctfe_dependencies=1 ctfe_selected_overlap=1",
                file=sys.stderr,
                flush=True,
            )
            print(
                "[typecheck-inventory] kind=ctfe_dependency module=dep "
                "source_bytes=32 typed_decls=1 typed_expr_nodes=2 import_bindings=0 "
                "reusable_artifact=1",
                file=sys.stderr,
                flush=True,
            )
        os.write(
            2,
            b"[typecheck-phase] phase=fast_checkpoint module=graph\\n",
        )
        os._exit(0)
        """
    )


class CompilerTypecheckReplayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.replay = load_replay_module()

    def run_replay(
        self,
        request_path: Path,
        bridge_path: Path,
        *extra_args: str,
        env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                str(SCRIPT),
                str(request_path),
                "--bridge",
                str(bridge_path),
                "--json",
                *extra_args,
            ],
            cwd=ROOT,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_replay_validates_lines_and_reports_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            request_path = temp_dir / "request.json"
            bridge_path = temp_dir / "typecheck-bridge"
            request_bytes = json.dumps(
                request_json(),
                separators=(",", ":"),
            ).encode()
            bridge_source = fake_bridge_source()
            request_path.write_bytes(request_bytes)
            bridge_path.write_text(bridge_source, encoding="utf-8")
            bridge_path.chmod(0o755)

            completed = self.run_replay(request_path, bridge_path)
            result = json.loads(completed.stdout)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertTrue(result["verified"])
        self.assertFalse(result["memstats_enabled"])
        self.assertEqual(result["artifacts"], 2)
        self.assertEqual(result["last_module"], "main")
        self.assertEqual(
            result["request_sha256"],
            hashlib.sha256(request_bytes).hexdigest(),
        )
        self.assertEqual(
            result["bridge_sha256"],
            hashlib.sha256(bridge_source.encode()).hexdigest(),
        )
        self.assertIn("typecheck_start", result["phase_sampled_peak_rss_bytes"])
        self.assertIn("dep", result["module_sampled_peak_rss_bytes"])
        self.assertIn("main", result["module_sampled_peak_rss_bytes"])
        self.assertGreater(
            result["module_phase_sampled_peak_rss_bytes"]["main"]["typecheck_start"],
            0,
        )
        self.assertEqual(
            result["rss_phase_attribution"],
            "latest marker observed before each RSS sample",
        )
        self.assertEqual(
            result["phase_memstats_max"]["typecheck_start"]["total_allocations"],
            10,
        )
        self.assertEqual(
            result["module_memstats_max"]["main"]["bytes_allocated"],
            8192,
        )
        self.assertEqual(
            [
                (item["phase"], item["module"], item.get("current_objects"))
                for item in result["phase_timeline"][:4]
            ],
            [
                ("typecheck_start", "dep", 7),
                ("typed_artifact_scope_complete", "dep", 5),
                ("typecheck_start", "main", 7),
                ("typed_artifact_scope_complete", "main", 5),
            ],
        )
        self.assertEqual(result["inventory"]["graph"]["ctfe_dependencies"], 1)
        self.assertEqual(
            result["inventory"]["ctfe_dependencies"]["dep"]["typed_expr_nodes"],
            2,
        )
        self.assertEqual(
            result["inventory"]["artifacts"]["dep"]["duplicates_retained_ctfe"],
            0,
        )
        self.assertEqual(
            result["inventory"]["artifacts"]["dep"]["reuses_retained_ctfe"],
            1,
        )
        self.assertEqual(
            result["inventory"]["artifact_ownership"]["main"],
            {
                "module": "main",
                "after_typecheck_unique": True,
                "after_ctfe_unique": True,
                "after_module_construction_unique": True,
                "before_artifact_release_unique": True,
            },
        )
        self.assertEqual(
            result["inventory"]["summary"]["retained_ctfe_typed_expr_nodes"],
            2,
        )
        self.assertEqual(
            result["inventory"]["summary"]["duplicated_artifact_typed_expr_nodes"],
            0,
        )
        self.assertEqual(
            result["inventory"]["summary"]["reused_artifact_typed_expr_nodes"],
            2,
        )
        self.assertEqual(
            result["inventory"]["summary"][
                "largest_observed_simultaneous_typed_expr_nodes"
            ],
            4,
        )
        self.assertTrue(result["inventory_enabled"])
        self.assertTrue(result["inventory_available"])
        self.assertNotIn("fast_checkpoint", result["phase_sampled_peak_rss_bytes"])
        self.assertGreater(result["response_bytes"], 0)

    def test_replay_can_select_one_module(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            request_path = temp_dir / "request.json"
            bridge_path = temp_dir / "typecheck-bridge"
            request_path.write_text(json.dumps(request_json()), encoding="utf-8")
            bridge_path.write_text(fake_bridge_source(), encoding="utf-8")
            bridge_path.chmod(0o755)

            completed = self.run_replay(
                request_path,
                bridge_path,
                "--module",
                "dep",
            )
            result = json.loads(completed.stdout)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertTrue(result["request_was_sliced"])
        self.assertEqual(result["module_targets"], ["dep"])
        self.assertEqual(result["artifacts"], 2)

    def test_replay_can_select_a_small_module_set(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            request_path = temp_dir / "request.json"
            bridge_path = temp_dir / "typecheck-bridge"
            request = request_json()
            payload = request["payload"]
            assert isinstance(payload, dict)
            modules = payload["modules"]
            assert isinstance(modules, list)
            modules.append(
                {
                    "path": "other.brp",
                    "module": "other",
                    "module_path": "other",
                    "text": "pure func other() -> Int: 0\n",
                    "origin": {"kind": "user"},
                }
            )
            payload["module_targets"] = ["dep", "other"]
            request_path.write_text(json.dumps(request), encoding="utf-8")
            bridge_path.write_text(fake_bridge_source(), encoding="utf-8")
            bridge_path.chmod(0o755)

            completed = self.run_replay(
                request_path,
                bridge_path,
                "--module",
                "other",
                "--module",
                "dep",
            )
            result = json.loads(completed.stdout)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertTrue(result["request_was_sliced"])
        self.assertEqual(result["module_targets"], ["other", "dep"])
        self.assertEqual(result["artifacts"], 3)

    def test_replay_deduplicates_repeated_module_selection(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            request_path = temp_dir / "request.json"
            bridge_path = temp_dir / "typecheck-bridge"
            request_path.write_text(json.dumps(request_json()), encoding="utf-8")
            bridge_path.write_text(fake_bridge_source(), encoding="utf-8")
            bridge_path.chmod(0o755)

            completed = self.run_replay(
                request_path,
                bridge_path,
                "--module",
                "dep",
                "--module",
                "dep",
            )
            result = json.loads(completed.stdout)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertTrue(result["request_was_sliced"])
        self.assertEqual(result["module_targets"], ["dep"])
        self.assertEqual(result["artifacts"], 2)

    def test_replay_retention_slice_selects_only_the_known_overlap(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            request_path = temp_dir / "request.json"
            bridge_path = temp_dir / "typecheck-bridge"
            request = request_json()
            payload = request["payload"]
            assert isinstance(payload, dict)
            payload["modules"] = [
                {
                    "path": f"{name}.brp",
                    "module": name,
                    "module_path": name,
                    "text": "pure func value() -> Int: 0\n",
                    "origin": {"kind": "user"},
                }
                for name in RETENTION_SLICE_MODULES
            ]
            payload["module_targets"] = [*RETENTION_SLICE_MODULES, "unselected"]
            modules = payload["modules"]
            assert isinstance(modules, list)
            modules.append(
                {
                    "path": "unselected.brp",
                    "module": "unselected",
                    "module_path": "unselected",
                    "text": "pure func value() -> Int: 0\n",
                    "origin": {"kind": "user"},
                }
            )
            request_path.write_text(json.dumps(request), encoding="utf-8")
            bridge_path.write_text(fake_bridge_source(), encoding="utf-8")
            bridge_path.chmod(0o755)

            completed = self.run_replay(
                request_path,
                bridge_path,
                "--retention-slice",
            )
            result = json.loads(completed.stdout)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(result["module_targets"], RETENTION_SLICE_MODULES)
        self.assertEqual(result["artifacts"], len(RETENTION_SLICE_MODULES) + 1)

    def test_replay_can_select_only_the_target(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            request_path = temp_dir / "request.json"
            bridge_path = temp_dir / "typecheck-bridge"
            request_path.write_text(json.dumps(request_json()), encoding="utf-8")
            bridge_path.write_text(fake_bridge_source(), encoding="utf-8")
            bridge_path.chmod(0o755)

            completed = self.run_replay(
                request_path,
                bridge_path,
                "--target-only",
            )
            result = json.loads(completed.stdout)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertTrue(result["request_was_sliced"])
        self.assertEqual(result["module_targets"], [])
        self.assertEqual(result["artifacts"], 1)
        self.assertEqual(result["last_module"], "main")

    def test_replay_timeout_is_bounded(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            request_path = temp_dir / "request.json"
            bridge_path = temp_dir / "typecheck-bridge"
            request_path.write_text(json.dumps(request_json()), encoding="utf-8")
            bridge_path.write_text(fake_bridge_source(), encoding="utf-8")
            bridge_path.chmod(0o755)
            environment = dict(os.environ)
            environment["BLORP_FAKE_TYPECHECK_DELAY"] = "2"

            completed = self.run_replay(
                request_path,
                bridge_path,
                "--timeout",
                "0.05",
                env=environment,
            )
            result = json.loads(completed.stdout)

        self.assertEqual(completed.returncode, 124)
        self.assertTrue(result["timed_out"])
        self.assertFalse(result["verified"])

    def test_replay_accepts_memory_limit(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            request_path = temp_dir / "request.json"
            bridge_path = temp_dir / "typecheck-bridge"
            request_path.write_text(json.dumps(request_json()), encoding="utf-8")
            bridge_path.write_text(fake_bridge_source(), encoding="utf-8")
            bridge_path.chmod(0o755)

            completed = self.run_replay(
                request_path,
                bridge_path,
                "--memory-limit",
                "4G",
                "--memstats",
            )
            result = json.loads(completed.stdout)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertTrue(result["verified"])
        self.assertTrue(result["memstats_enabled"])
        self.assertEqual(result["memory_limit_bytes"], 4 * 1024**3)
        self.assertIn(
            result["memory_limit_kind"],
            ("address_space", "sampled_rss"),
        )

    def test_replay_can_report_lightweight_allocator_stats(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            request_path = temp_dir / "request.json"
            bridge_path = temp_dir / "typecheck-bridge"
            request_path.write_text(json.dumps(request_json()), encoding="utf-8")
            bridge_path.write_text(fake_bridge_source(), encoding="utf-8")
            bridge_path.chmod(0o755)

            completed = self.run_replay(
                request_path,
                bridge_path,
                "--allocator-stats",
            )
            result = json.loads(completed.stdout)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertTrue(result["verified"])
        self.assertTrue(result["allocator_stats_enabled"])
        self.assertTrue(result["allocator_stats_available"])
        self.assertFalse(result["memstats_enabled"])
        self.assertEqual(
            result["module_memstats_max"]["main"]["bytes_allocated"],
            8192,
        )

    def test_replay_rejects_bridge_without_allocator_stats_support(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            request_path = temp_dir / "request.json"
            bridge_path = temp_dir / "typecheck-bridge"
            request_path.write_text(json.dumps(request_json()), encoding="utf-8")
            bridge_path.write_text(
                fake_bridge_source().replace(
                    "BLORP_ALLOCATOR_STATS",
                    "BLORP_UNSUPPORTED_ALLOCATOR_STATS",
                ),
                encoding="utf-8",
            )
            bridge_path.chmod(0o755)

            completed = self.run_replay(
                request_path,
                bridge_path,
                "--allocator-stats",
            )
            result = json.loads(completed.stdout)

        self.assertNotEqual(completed.returncode, 0)
        self.assertFalse(result["verified"])
        self.assertIn("current runtime", result["error"])

    def test_replay_rejects_unavailable_allocator_stats(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            request_path = temp_dir / "request.json"
            bridge_path = temp_dir / "typecheck-bridge"
            request_path.write_text(json.dumps(request_json()), encoding="utf-8")
            bridge_path.write_text(fake_bridge_source(), encoding="utf-8")
            bridge_path.chmod(0o755)
            environment = dict(os.environ)
            environment["BLORP_FAKE_ALLOCATOR_STATS_UNAVAILABLE"] = "1"

            completed = self.run_replay(
                request_path,
                bridge_path,
                "--allocator-stats",
                env=environment,
            )
            result = json.loads(completed.stdout)

        self.assertNotEqual(completed.returncode, 0)
        self.assertFalse(result["verified"])
        self.assertFalse(result["allocator_stats_available"])
        self.assertIn("unavailable", result["error"])

    def test_replay_can_disable_structural_inventory_for_a_control_run(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            request_path = temp_dir / "request.json"
            bridge_path = temp_dir / "typecheck-bridge"
            request_path.write_text(json.dumps(request_json()), encoding="utf-8")
            bridge_path.write_text(fake_bridge_source(), encoding="utf-8")
            bridge_path.chmod(0o755)

            completed = self.run_replay(
                request_path,
                bridge_path,
                "--no-inventory",
            )
            result = json.loads(completed.stdout)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertFalse(result["inventory_enabled"])
        self.assertFalse(result["inventory_available"])
        self.assertEqual(result["inventory"], {})

    def test_replay_rejects_success_without_requested_inventory(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            request_path = temp_dir / "request.json"
            bridge_path = temp_dir / "typecheck-bridge"
            request_path.write_text(json.dumps(request_json()), encoding="utf-8")
            bridge_source = fake_bridge_source().replace(
                'inventory_enabled = "BLORP_COMPILER_TYPECHECK_INVENTORY" in os.environ',
                "inventory_enabled = False",
            )
            bridge_path.write_text(bridge_source, encoding="utf-8")
            bridge_path.chmod(0o755)

            completed = self.run_replay(request_path, bridge_path)
            result = json.loads(completed.stdout)

        self.assertEqual(completed.returncode, 1)
        self.assertFalse(result["verified"])
        self.assertIn("inventory", result["error"])

    def test_replay_rejects_missing_fresh_artifact_ownership(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            request_path = temp_dir / "request.json"
            bridge_path = temp_dir / "typecheck-bridge"
            request_path.write_text(json.dumps(request_json()), encoding="utf-8")
            bridge_source = fake_bridge_source().replace(
                "if not reused:",
                "if False and not reused:",
                1,
            )
            bridge_path.write_text(bridge_source, encoding="utf-8")
            bridge_path.chmod(0o755)

            completed = self.run_replay(request_path, bridge_path)
            result = json.loads(completed.stdout)

        self.assertNotEqual(completed.returncode, 0)
        self.assertFalse(result["verified"])
        self.assertIn("ownership", result["error"])

    def test_replay_rejects_incomplete_fresh_artifact_ownership(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            request_path = temp_dir / "request.json"
            bridge_path = temp_dir / "typecheck-bridge"
            request_path.write_text(json.dumps(request_json()), encoding="utf-8")
            bridge_source = fake_bridge_source().replace(
                '"after_ctfe_unique=True after_module_construction_unique=True "',
                '"after_ctfe_unique=True "',
                1,
            )
            bridge_path.write_text(bridge_source, encoding="utf-8")
            bridge_path.chmod(0o755)

            completed = self.run_replay(request_path, bridge_path)
            result = json.loads(completed.stdout)

        self.assertNotEqual(completed.returncode, 0)
        self.assertFalse(result["verified"])
        self.assertIn("ownership", result["error"])
        self.assertIn("after_module_construction_unique", result["error"])

    def test_inventory_distinguishes_failed_programs_and_decodes_module_paths(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            stderr_path = Path(temp_name) / "bridge.stderr"
            stderr_path.write_text(
                "\n".join(
                    (
                        "[typecheck-inventory] kind=graph module=main%20module "
                        "ctfe_dependencies=2",
                        "[typecheck-inventory] kind=ctfe_dependency "
                        "module=retained%20module typed_decls=3 typed_expr_nodes=5",
                        "[typecheck-inventory] kind=ctfe_dependency "
                        "module=failed%20module typed_decls=0 typed_expr_nodes=0 "
                        "typecheck_failed=1",
                        "[typecheck-inventory] kind=artifact module=main%20module "
                        "typed_decls=1 typed_expr_nodes=2 "
                        "duplicates_retained_ctfe=0",
                    )
                )
                + "\n",
                encoding="utf-8",
            )

            inventory = self.replay.read_inventory(stderr_path)

        self.assertIn("retained module", inventory["ctfe_dependencies"])
        self.assertIn("failed module", inventory["ctfe_dependencies"])
        self.assertEqual(inventory["summary"]["planned_ctfe_dependencies"], 2)
        self.assertEqual(inventory["summary"]["retained_ctfe_programs"], 1)
        self.assertEqual(inventory["summary"]["failed_ctfe_dependencies"], 1)
        self.assertEqual(
            inventory["summary"]["retained_ctfe_typed_expr_nodes"],
            5,
        )

    def test_checkpoint_timing_uses_same_module_trace_intervals(self) -> None:
        markers = [
            (
                "typecheck_start",
                "main",
                {"timestamp_microseconds": 100},
            ),
            (
                "typecheck_import_decls_complete",
                "main",
                {"timestamp_microseconds": 160},
            ),
            (
                "typecheck_bodies_complete",
                "main",
                {"timestamp_microseconds": 250},
            ),
        ]

        timeline, checkpoint_totals, module_checkpoint_totals = (
            self.replay.checkpoint_interval_summary(markers)
        )

        self.assertNotIn("elapsed_since_previous_checkpoint_microseconds", timeline[0])
        self.assertEqual(
            timeline[1]["elapsed_since_previous_checkpoint_microseconds"], 60
        )
        self.assertEqual(
            timeline[2]["elapsed_since_previous_checkpoint_microseconds"], 90
        )
        self.assertEqual(
            checkpoint_totals,
            {
                "typecheck_import_decls_complete": 60,
                "typecheck_bodies_complete": 90,
            },
        )
        self.assertEqual(
            module_checkpoint_totals["main"],
            checkpoint_totals,
        )
        phase_counts, module_phase_counts = self.replay.phase_marker_counts(markers)
        self.assertEqual(
            phase_counts,
            {
                "typecheck_start": 1,
                "typecheck_import_decls_complete": 1,
                "typecheck_bodies_complete": 1,
            },
        )
        self.assertEqual(module_phase_counts["main"], phase_counts)

    def test_checkpoint_timing_does_not_cross_module_boundaries(self) -> None:
        markers = [
            ("typecheck_complete", "dep", {"timestamp_microseconds": 100}),
            ("typecheck_start", "main", {"timestamp_microseconds": 500}),
            ("typecheck_prelude_complete", "main", {"timestamp_microseconds": 560}),
        ]

        timeline, checkpoint_totals, module_checkpoint_totals = (
            self.replay.checkpoint_interval_summary(markers)
        )

        self.assertNotIn(
            "elapsed_since_previous_checkpoint_microseconds",
            timeline[1],
        )
        self.assertEqual(
            timeline[2]["elapsed_since_previous_checkpoint_microseconds"],
            60,
        )
        self.assertEqual(checkpoint_totals, {"typecheck_prelude_complete": 60})
        self.assertEqual(
            module_checkpoint_totals,
            {"main": {"typecheck_prelude_complete": 60}},
        )

    def test_address_space_limit_failure_is_reported_as_indeterminate(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            request_path = temp_dir / "request.json"
            bridge_path = temp_dir / "typecheck-bridge"
            request_path.write_text(json.dumps(request_json()), encoding="utf-8")
            bridge_path.write_text(fake_bridge_source(), encoding="utf-8")
            bridge_path.chmod(0o755)
            environment = dict(os.environ)
            environment["BLORP_FAKE_TYPECHECK_EXIT"] = "7"

            completed = self.run_replay(
                request_path,
                bridge_path,
                "--memory-limit",
                "4G",
                env=environment,
            )
            result = json.loads(completed.stdout)

        self.assertEqual(completed.returncode, 1)
        expected = result["memory_limit_kind"] == "address_space"
        self.assertEqual(result["memory_limit_failure_possible"], expected)
        if expected:
            self.assertIn("address-space limit was active", result["error"])

    def test_replay_enforces_a_crossed_memory_limit(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            request_path = temp_dir / "request.json"
            bridge_path = temp_dir / "typecheck-bridge"
            request_path.write_text(json.dumps(request_json()), encoding="utf-8")
            bridge_path.write_text(fake_bridge_source(), encoding="utf-8")
            bridge_path.chmod(0o755)
            environment = dict(os.environ)
            environment["BLORP_FAKE_TYPECHECK_ALLOCATE_MB"] = "128"

            completed = self.run_replay(
                request_path,
                bridge_path,
                "--memory-limit",
                "48M",
                "--timeout",
                "5",
                env=environment,
            )
            result = json.loads(completed.stdout)

        self.assertFalse(result["verified"])
        if result["memory_limit_kind"] == "sampled_rss":
            self.assertEqual(completed.returncode, 125)
            self.assertTrue(result["memory_limited"])
        else:
            self.assertEqual(completed.returncode, 1)
            self.assertTrue(result["memory_limit_failure_possible"])

    def test_replay_rejects_non_typecheck_request(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            request_path = temp_dir / "request.json"
            bridge_path = temp_dir / "typecheck-bridge"
            request_path.write_text(
                json.dumps(request_json("emit_core_c")),
                encoding="utf-8",
            )
            bridge_path.write_text(fake_bridge_source(), encoding="utf-8")
            bridge_path.chmod(0o755)

            completed = self.run_replay(request_path, bridge_path)

        self.assertEqual(completed.returncode, 1)
        self.assertIn("typecheck_graph", completed.stderr)


if __name__ == "__main__":
    unittest.main()
