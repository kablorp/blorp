#!/usr/bin/env python3
"""Contract tests for benchmarks/compiler_typecheck_replay."""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "benchmarks" / "compiler_typecheck_replay"


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

        for item in selected:
            print(
                f"[typecheck-phase] phase=typecheck_start module={item['module_path']} "
                "total_allocations=10 total_releases=3 current_objects=7 "
                "bytes_allocated=4096",
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
                "total_allocations=20 total_releases=15 current_objects=5 "
                "bytes_allocated=8192",
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
        self.assertIn("typecheck_start", result["phase_peak_rss_bytes"])
        self.assertIn("dep", result["module_peak_rss_bytes"])
        self.assertIn("main", result["module_peak_rss_bytes"])
        self.assertEqual(
            result["phase_memstats_max"]["typecheck_start"]["total_allocations"],
            10,
        )
        self.assertEqual(
            result["module_memstats_max"]["main"]["bytes_allocated"],
            8192,
        )
        self.assertNotIn("fast_checkpoint", result["phase_peak_rss_bytes"])
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
