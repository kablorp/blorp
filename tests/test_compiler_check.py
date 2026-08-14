import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
COMPILER_CHECK = REPOSITORY_ROOT / "scripts" / "compiler-check"


class CompilerCheckFixture:
    def __init__(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.events = self.root / "events.jsonl"
        (self.root / "scripts").mkdir()
        (self.root / "compiler/blorp/src/stage_06_typecheck").mkdir(parents=True)
        (self.root / "compiler/blorp/tests").mkdir(parents=True)
        (self.root / "bin").mkdir()
        shutil.copy2(COMPILER_CHECK, self.root / "scripts/compiler-check")
        self.write("compiler/blorp/src/stage_06_typecheck/alpha.brp", "-- alpha\n")
        self.write("compiler/blorp/tests/test_alpha.brp", "-- suite alpha\n")
        (self.root / "checks").mkdir()
        self._write_stub(self.root / "checks/audit.sh", "checks/audit.sh")
        self._write_stub(self.root / "bin/make", "make")
        self._write_stub(self.root / "blorp", "blorp")
        self._write_stub(self.root / "scripts/test", "scripts/test")
        self.write_manifest()
        self.git("init", "-q")
        self.git("config", "user.name", "Compiler Check Tests")
        self.git("config", "user.email", "compiler-check@example.invalid")
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")

    def cleanup(self):
        self.temporary_directory.cleanup()

    def write(self, relative_path, content, executable=False):
        path = self.root / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        if executable:
            path.chmod(0o755)
        return path

    def _write_stub(self, path, name):
        path.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, pathlib, sys\n"
            "event = {'program': " + repr(name) + ", 'args': sys.argv[1:]}\n"
            "with pathlib.Path(os.environ['STUB_EVENTS']).open('a', encoding='utf-8') as stream:\n"
            "    stream.write(json.dumps(event) + '\\n')\n"
            "print('stub ' + " + repr(name) + ")\n"
            "sys.exit(int(os.environ.get('STUB_EXIT_' + " + repr(name.upper().replace('/', '_').replace('.', '_')) + ", '0')))\n",
            encoding="utf-8",
        )
        path.chmod(0o755)

    def manifest(self):
        return {
            "schema_version": 1,
            "stages": ["typecheck", "core"],
            "suites": [
                {"id": "alpha", "path": "compiler/blorp/tests/test_alpha.brp"}
            ],
            "checks": [
                {
                    "id": "audit",
                    "path": "checks/audit.sh",
                    "command": ["checks/audit.sh"],
                }
            ],
            "broad_gates": [
                {
                    "id": "compiler-blorp",
                    "path": "scripts/test",
                    "gate": "compiler-blorp",
                }
            ],
            "modules": [
                {
                    "path": "compiler/blorp/src/stage_06_typecheck/alpha.brp",
                    "stage": "typecheck",
                    "suites": ["alpha"],
                    "checks": [],
                    "broad_gate": "compiler-blorp",
                }
            ],
        }

    def write_manifest(self, manifest=None, raw=None):
        path = self.root / "compiler/blorp/tests/compiler_test_ownership.json"
        if raw is not None:
            path.write_text(raw, encoding="utf-8")
        else:
            path.write_text(json.dumps(manifest or self.manifest(), indent=2) + "\n", encoding="utf-8")

    def git(self, *args):
        return subprocess.run(
            ["git", *args], cwd=self.root, text=True, capture_output=True, check=True
        )

    def run(self, *args, extra_environment=None):
        environment = os.environ.copy()
        environment["PATH"] = str(self.root / "bin") + os.pathsep + environment["PATH"]
        environment["STUB_EVENTS"] = str(self.events)
        if extra_environment:
            environment.update(extra_environment)
        return subprocess.run(
            [sys.executable, str(self.root / "scripts/compiler-check"), *args],
            cwd=self.root,
            text=True,
            capture_output=True,
            env=environment,
        )

    def recorded_events(self):
        if not self.events.exists():
            return []
        return [json.loads(line) for line in self.events.read_text(encoding="utf-8").splitlines()]


class CompilerCheckTestCase(unittest.TestCase):
    def setUp(self):
        self.fixture = CompilerCheckFixture()

    def tearDown(self):
        self.fixture.cleanup()

    def assert_invalid(self, expected_message):
        result = self.fixture.run("--validate-manifest")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(expected_message, result.stderr)

    def test_valid_complete_inventory(self):
        result = self.fixture.run("--validate-manifest")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("1 production modules", result.stdout)

    def test_missing_production_source_is_rejected(self):
        self.fixture.write("compiler/blorp/src/unowned.brp", "-- unowned\n")
        self.assert_invalid("unowned production compiler module")

    def test_duplicate_module_is_rejected(self):
        manifest = self.fixture.manifest()
        manifest["modules"].append(dict(manifest["modules"][0]))
        self.fixture.write_manifest(manifest)
        self.assert_invalid("duplicate module path")

    def test_duplicate_suite_and_check_ids_are_rejected(self):
        manifest = self.fixture.manifest()
        manifest["suites"].append(dict(manifest["suites"][0]))
        manifest["checks"].append(dict(manifest["checks"][0]))
        manifest["checks"].append(
            {"id": "alpha", "path": "checks/audit.sh", "command": ["checks/audit.sh"]}
        )
        self.fixture.write_manifest(manifest)
        result = self.fixture.run("--validate-manifest")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("duplicate suite id", result.stderr)
        self.assertIn("duplicate check id", result.stderr)
        self.assertIn("duplicate suite/check id", result.stderr)

    def test_nonexistent_source_suite_and_check_paths_are_rejected(self):
        manifest = self.fixture.manifest()
        manifest["modules"][0]["path"] = "compiler/blorp/src/stage_06_typecheck/missing.brp"
        manifest["suites"][0]["path"] = "compiler/blorp/tests/missing.brp"
        manifest["checks"][0]["path"] = "checks/missing.sh"
        self.fixture.write_manifest(manifest)
        result = self.fixture.run("--validate-manifest")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("source path does not exist", result.stderr)
        self.assertIn("suite path does not exist", result.stderr)
        self.assertIn("check path does not exist", result.stderr)

    def test_unknown_stage_and_broad_gate_are_rejected(self):
        manifest = self.fixture.manifest()
        manifest["modules"][0]["stage"] = "guesswork"
        manifest["modules"][0]["broad_gate"] = "unknown"
        self.fixture.write_manifest(manifest)
        result = self.fixture.run("--validate-manifest")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown stage", result.stderr)
        self.assertIn("unknown broad gate", result.stderr)

    def test_empty_focused_suite_set_is_rejected(self):
        manifest = self.fixture.manifest()
        manifest["modules"][0]["suites"] = []
        self.fixture.write_manifest(manifest)
        self.assert_invalid("must reference at least one focused suite")

    def test_malformed_unknown_field_and_unsupported_schema_are_rejected(self):
        self.fixture.write_manifest(raw="{broken")
        self.assert_invalid("malformed JSON")
        manifest = self.fixture.manifest()
        manifest["surprise"] = True
        self.fixture.write_manifest(manifest)
        self.assert_invalid("unknown field")
        manifest = self.fixture.manifest()
        manifest["schema_version"] = 99
        self.fixture.write_manifest(manifest)
        self.assert_invalid("unsupported schema version")
        for invalid_version in (True, 1.0):
            manifest = self.fixture.manifest()
            manifest["schema_version"] = invalid_version
            self.fixture.write_manifest(manifest)
            self.assert_invalid("unsupported schema version")

    def test_direct_suite_selection_runs_exact_registered_suite(self):
        result = self.fixture.run("compiler/blorp/tests/test_alpha.brp")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        events = self.fixture.recorded_events()
        self.assertEqual([event["program"] for event in events], ["make", "blorp"])
        self.assertEqual(events[1]["args"][-1], "compiler/blorp/tests/test_alpha.brp")

    def test_exact_stage_selection_is_deduplicated_and_deterministic(self):
        self.fixture.write("compiler/blorp/src/stage_06_typecheck/beta.brp", "-- beta\n")
        self.fixture.write("compiler/blorp/tests/test_beta.brp", "-- suite beta\n")
        manifest = self.fixture.manifest()
        manifest["suites"].append({"id": "beta", "path": "compiler/blorp/tests/test_beta.brp"})
        manifest["modules"].append(
            {
                "path": "compiler/blorp/src/stage_06_typecheck/beta.brp",
                "stage": "typecheck",
                "suites": ["beta", "alpha"],
                "checks": ["audit"],
                "broad_gate": "compiler-blorp",
            }
        )
        manifest["modules"][0]["checks"] = ["audit"]
        self.fixture.write_manifest(manifest)
        result = self.fixture.run("--stage", "typecheck")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        events = self.fixture.recorded_events()
        self.assertEqual(events[1]["args"][-2:], [
            "compiler/blorp/tests/test_alpha.brp",
            "compiler/blorp/tests/test_beta.brp",
        ])
        self.assertEqual(sum(event["program"] == "checks/audit.sh" for event in events), 1)
        self.assertLess(result.stdout.index("alpha.brp"), result.stdout.index("beta.brp"))

    def test_changed_includes_staged_unstaged_and_untracked_paths(self):
        for name in ("staged", "unstaged", "untracked"):
            self.fixture.write(f"compiler/blorp/src/stage_06_typecheck/{name}.brp", f"-- {name}\n")
        manifest = self.fixture.manifest()
        manifest["modules"].extend(
            {
                "path": f"compiler/blorp/src/stage_06_typecheck/{name}.brp",
                "stage": "typecheck",
                "suites": ["alpha"],
                "checks": [],
                "broad_gate": "compiler-blorp",
            }
            for name in ("staged", "unstaged", "untracked")
        )
        self.fixture.write_manifest(manifest)
        self.fixture.git("add", ".")
        self.fixture.git("commit", "-qm", "add change fixtures")
        self.fixture.write("compiler/blorp/src/stage_06_typecheck/staged.brp", "-- staged changed\n")
        self.fixture.git("add", "compiler/blorp/src/stage_06_typecheck/staged.brp")
        self.fixture.write("compiler/blorp/src/stage_06_typecheck/unstaged.brp", "-- unstaged changed\n")
        self.fixture.write("compiler/blorp/src/stage_06_typecheck/untracked.brp", "-- replaced then untracked\n")
        self.fixture.git("rm", "--cached", "compiler/blorp/src/stage_06_typecheck/untracked.brp")
        result = self.fixture.run("--changed")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for name in ("staged", "unstaged", "untracked"):
            self.assertIn(f"{name}.brp", result.stdout)

    def test_base_includes_committed_changes_from_merge_base(self):
        self.fixture.git("tag", "compiler-check-base")
        self.fixture.write("compiler/blorp/src/stage_06_typecheck/alpha.brp", "-- committed change\n")
        self.fixture.git("add", ".")
        self.fixture.git("commit", "-qm", "committed change")
        result = self.fixture.run("--changed", "--base", "compiler-check-base")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("compiler/blorp/src/stage_06_typecheck/alpha.brp", result.stdout)

    def test_unowned_changed_source_is_rejected(self):
        self.fixture.write("compiler/blorp/src/stage_06_typecheck/unowned.brp", "-- unowned\n")
        result = self.fixture.run("--changed")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unowned production compiler module", result.stderr)

    def test_unknown_stage_suite_and_incompatible_modes_show_usage(self):
        for arguments, message in (
            (("--stage", "unknown"), "unknown stage"),
            (("compiler/blorp/tests/missing.brp",), "unknown suite"),
            (("--stage", "typecheck", "--changed"), "not allowed with argument"),
            (("--base", "HEAD"), "--base requires --changed"),
        ):
            result = self.fixture.run(*arguments)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(message, result.stderr)
            self.assertIn("usage:", result.stderr.lower())

    def test_compiler_preparation_occurs_once_and_special_gate_uses_no_build(self):
        manifest = self.fixture.manifest()
        manifest["checks"] = [
            {"id": "sanitize", "path": "scripts/test", "gate": "compiler-core-sanitize"}
        ]
        manifest["modules"][0]["checks"] = ["sanitize"]
        self.fixture.write_manifest(manifest)
        result = self.fixture.run("--stage", "typecheck")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        events = self.fixture.recorded_events()
        self.assertEqual(sum(event["program"] == "make" for event in events), 1)
        test_event = next(event for event in events if event["program"] == "scripts/test")
        self.assertIn("--no-build", test_event["args"])
        self.assertIn("--log-dir", test_event["args"])

    def test_failure_status_rerun_and_log_retention(self):
        result = self.fixture.run(
            "compiler/blorp/tests/test_alpha.brp",
            extra_environment={"STUB_EXIT_BLORP": "7"},
        )
        self.assertEqual(result.returncode, 7)
        self.assertIn("Rerun: scripts/compiler-check compiler/blorp/tests/test_alpha.brp", result.stderr)
        retained = list((self.fixture.root / "logs").glob("compiler-check-*"))
        self.assertEqual(len(retained), 1)
        self.assertTrue((retained[0] / "suites.log").exists())

    def test_success_cleans_temporary_logs(self):
        result = self.fixture.run("compiler/blorp/tests/test_alpha.brp")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        retained = list((self.fixture.root / "logs").glob("compiler-check-*"))
        self.assertEqual(retained, [])

    def test_paths_containing_spaces_remain_single_arguments(self):
        self.fixture.write("compiler/blorp/src/stage_06_typecheck/with space.brp", "-- source\n")
        self.fixture.write("compiler/blorp/tests/test with space.brp", "-- suite\n")
        manifest = self.fixture.manifest()
        manifest["suites"].append(
            {"id": "space", "path": "compiler/blorp/tests/test with space.brp"}
        )
        manifest["modules"].append(
            {
                "path": "compiler/blorp/src/stage_06_typecheck/with space.brp",
                "stage": "typecheck",
                "suites": ["space"],
                "checks": [],
                "broad_gate": "compiler-blorp",
            }
        )
        self.fixture.write_manifest(manifest)
        result = self.fixture.run("compiler/blorp/tests/test with space.brp")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        blorp_event = next(event for event in self.fixture.recorded_events() if event["program"] == "blorp")
        self.assertEqual(blorp_event["args"][-1], "compiler/blorp/tests/test with space.brp")


if __name__ == "__main__":
    unittest.main()
