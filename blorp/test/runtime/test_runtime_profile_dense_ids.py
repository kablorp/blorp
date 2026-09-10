#!/usr/bin/env python3
"""Runtime and generated-artifact contracts for dense function profile IDs."""

from __future__ import annotations

import os
import re
import signal
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
RUNTIME_NATIVE = ROOT / "blorp" / "src" / "lib" / "runtime" / "native"


class RuntimeDenseProfileIdTests(unittest.TestCase):
    def test_generated_exact_profile_selects_imported_function_identity(self) -> None:
        helper_program = textwrap.dedent(
            """\
            pure func selected(value: Int) -> Int:
                if value <= 0:
                    0
                else:
                    selected(value - 1) + 1

            pure func other() -> Int: 9
            """
        )
        main_program = textwrap.dedent(
            """\
            import:
                helper: selected

            func main(args: List[String]) -> Int:
                selected(7)
            """
        )
        with tempfile.TemporaryDirectory(dir=ROOT) as temp_name:
            temp = Path(temp_name)
            helper = temp / "helper.brp"
            source = temp / "main.brp"
            generated_c = temp / "selected-profile.c"
            helper.write_text(helper_program)
            source.write_text(main_program)
            helper_module = helper.with_suffix("").relative_to(ROOT).as_posix()

            compiled = subprocess.run(
                [
                    str(ROOT / "bin" / "blorp"),
                    "compile",
                    "--profile-mode",
                    "exact",
                    "--profile-function",
                    f"{helper_module}::selected",
                    "--no-format",
                    "-o",
                    str(generated_c),
                    str(source),
                ],
                cwd=ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )

            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            artifact_c = generated_c.read_text().split(
                "/* Blorp final Core C artifact */", 1
            )[1]

        profile_plan = re.search(
            r"BLORP_PROFILE mode=exact functions_described=(\d+) functions_selected=1",
            artifact_c,
        )
        self.assertIsNotNone(profile_plan, artifact_c)
        assert profile_plan is not None
        self.assertGreater(int(profile_plan.group(1)), 1)
        profiled_name = helper_module.replace("/", "_") + "__selected"
        unselected_name = helper_module.replace("/", "_") + "__other"
        self.assertIn(f'"{profiled_name}"', artifact_c)
        self.assertNotIn(f'"{unselected_name}"', artifact_c)
        self.assertEqual(len(re.findall(r"blorp_profile_start_id\(\d+\)", artifact_c)), 1)
        self.assertGreaterEqual(len(re.findall(r"blorp_profile_end_id\(\d+\)", artifact_c)), 1)

    def test_generated_calls_profile_uses_count_only_probes(self) -> None:
        program = textwrap.dedent(
            """\
            pure func answer() -> Int: 21

            func main(args: List[String]) -> Int:
                answer() + answer()
            """
        )
        with tempfile.TemporaryDirectory() as temp_name:
            temp = Path(temp_name)
            source = temp / "calls-profile.brp"
            generated_c = temp / "calls-profile.c"
            executable = temp / "calls-profile"
            source.write_text(program)

            compiled = subprocess.run(
                [
                    str(ROOT / "bin" / "blorp"),
                    "compile",
                    "--profile-mode",
                    "calls",
                    "--no-format",
                    "-o",
                    str(generated_c),
                    str(source),
                ],
                cwd=ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            generated = generated_c.read_text()
            artifact_c = generated.split("/* Blorp final Core C artifact */", 1)[1]
            self.assertIn("BLORP_PROFILE mode=calls", artifact_c)
            self.assertIn("blorp_profile_count_id(", artifact_c)
            self.assertNotIn("blorp_profile_start_id(", artifact_c)
            self.assertNotIn("blorp_profile_end_id(", artifact_c)

            c_compiled = subprocess.run(
                [
                    os.environ.get("CC", "cc"),
                    "-O0",
                    "-w",
                    str(generated_c),
                    "-lm",
                    "-lpthread",
                    "-o",
                    str(executable),
                ],
                cwd=ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
            self.assertEqual(c_compiled.returncode, 0, c_compiled.stderr)
            completed = subprocess.run(
                [str(executable)],
                cwd=ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )

        self.assertEqual(completed.returncode, 42, completed.stderr)
        self.assertIn("=== Function Calls ===", completed.stderr)
        self.assertNotIn("Time (ms)", completed.stderr)
        diagnostics = re.search(
            r"PROFILE_DIAGNOSTICS profile_mode=calls functions_described=(\d+) "
            r"functions_selected=(\d+) functions_observed=(\d+) .*"
            r"calls_observed=(\d+) calls_completed=0",
            completed.stderr,
        )
        self.assertIsNotNone(diagnostics, completed.stderr)
        assert diagnostics is not None
        described, selected, observed, observed_calls = map(int, diagnostics.groups())
        self.assertEqual(selected, described)
        self.assertGreater(observed, 0)
        self.assertGreaterEqual(observed_calls, observed)

    def test_calls_mode_counts_without_timing_or_stack_work(self) -> None:
        source = textwrap.dedent(
            """\
            #define MINICORO_IMPL
            #include "minicoro.h"
            #include "runtime.c"

            static const blorp_ProfileFunctionMetadata functions[] = {
                {"counted", "brp_counted", "fixture", 1, BLORP_PROFILE_METADATA_HAS_MODULE},
                {"never_called", "brp_never_called", "fixture", 2, BLORP_PROFILE_METADATA_HAS_MODULE},
            };

            static void counted_recurse(long depth) {
                blorp_profile_count_id(0);
                if (depth > 0) counted_recurse(depth - 1);
            }

            static void* count_worker(void* unused) {
                (void)unused;
                counted_recurse(0);
                return NULL;
            }

            int main(void) {
                if (blorp_profile_enable(BLORP_PROFILE_MODE_CALLS, functions, 2, 4) != 0) return 2;
                blorp_profile_window_begin();
                counted_recurse(1);
                pthread_t worker;
                if (pthread_create(&worker, NULL, count_worker, NULL) != 0) return 3;
                if (pthread_join(worker, NULL) != 0) return 4;
                blorp_profile_window_end();
                if (profile_stack_depth != 0) return 5;
                if (atomic_load(&profile_entries[0].total_ns) != 0) return 6;
                if (atomic_load(&profile_entries[0].call_count) != 3) return 7;
                if (atomic_load(&profile_entries[1].call_count) != 0) return 8;
                blorp_profile_report();
                return 0;
            }
            """
        )
        with tempfile.TemporaryDirectory() as temp_name:
            executable = Path(temp_name) / "calls-profile"
            compiled = subprocess.run(
                [
                    os.environ.get("CC", "cc"),
                    "-O1",
                    "-g",
                    "-fsanitize=address,undefined",
                    "-fno-omit-frame-pointer",
                    "-w",
                    f"-I{RUNTIME_NATIVE}",
                    "-x",
                    "c",
                    "-",
                    "-lm",
                    "-lpthread",
                    "-o",
                    str(executable),
                ],
                cwd=ROOT,
                input=source,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)

            environment = dict(os.environ)
            environment["ASAN_OPTIONS"] = "detect_leaks=0:halt_on_error=1"
            completed = subprocess.run(
                [str(executable)],
                cwd=ROOT,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("=== Function Calls ===", completed.stderr)
        self.assertNotIn("Time (ms)", completed.stderr)
        self.assertRegex(
            completed.stderr,
            r"PROFILE_DIAGNOSTICS profile_mode=calls functions_described=4 "
            r"functions_selected=2 functions_observed=1 .*"
            r"calls_observed=3 calls_completed=0",
        )
        self.assertNotIn("never_called", completed.stderr)

    def test_calls_mode_polls_deferred_termination_signals(self) -> None:
        source = textwrap.dedent(
            """\
            #define MINICORO_IMPL
            #include "minicoro.h"
            #include "runtime.c"

            static const blorp_ProfileFunctionMetadata functions[] = {
                {"loop", "brp_loop", NULL, 1, 0u},
            };

            int main(void) {
                if (blorp_profile_enable(BLORP_PROFILE_MODE_CALLS, functions, 1, 1) != 0) return 2;
                blorp_profile_window_begin();
                fprintf(stdout, "ready\\n");
                fflush(stdout);
                for (;;) blorp_profile_count_id(0);
            }
            """
        )
        with tempfile.TemporaryDirectory() as temp_name:
            executable = Path(temp_name) / "calls-profile-signal"
            compiled = subprocess.run(
                [
                    os.environ.get("CC", "cc"),
                    "-O1",
                    "-w",
                    f"-I{RUNTIME_NATIVE}",
                    "-x",
                    "c",
                    "-",
                    "-lm",
                    "-lpthread",
                    "-o",
                    str(executable),
                ],
                cwd=ROOT,
                input=source,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)

            for termination_signal in (signal.SIGINT, signal.SIGTERM):
                process = subprocess.Popen(
                    [str(executable)],
                    cwd=ROOT,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                try:
                    assert process.stdout is not None
                    self.assertEqual(process.stdout.readline(), "ready\n")
                    process.send_signal(termination_signal)
                    _, stderr = process.communicate(timeout=10)
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait()

                self.assertEqual(process.returncode, -termination_signal, stderr)
                self.assertIn("profile_mode=calls", stderr)

    def test_invalid_operations_are_sanitizer_clean_and_reported(self) -> None:
        source = textwrap.dedent(
            """\
            #define MINICORO_IMPL
            #include "minicoro.h"
            #include "runtime.c"

            static const blorp_ProfileFunctionMetadata functions[] = {
                {"duplicate", "brp_10", "fixture/first", 10, BLORP_PROFILE_METADATA_HAS_MODULE},
                {"duplicate", "brp_11", "fixture/second", 11, BLORP_PROFILE_METADATA_HAS_MODULE},
            };

            int main(void) {
                if (blorp_profile_enable(BLORP_PROFILE_MODE_EXACT, NULL, 1, 1) == 0) return 2;
                if (blorp_profile_enable(BLORP_PROFILE_MODE_EXACT, functions, 2, 2) != 0) return 3;

                blorp_profile_start_id(0);
                blorp_profile_window_begin();
                blorp_profile_start_id(1);
                blorp_profile_end_id(1);
                blorp_profile_end_id(0);

                blorp_profile_start_id(0);
                blorp_profile_start_id(0);
                blorp_profile_end_id(0);
                blorp_profile_end_id(0);
                blorp_profile_start_id(1);
                blorp_profile_end_id(1);
                blorp_profile_start_id(0);
                blorp_profile_start_id(1);
                blorp_profile_end_id(0);
                blorp_profile_end_id(1);

                blorp_profile_start_id(2);
                blorp_profile_end_id(2);
                blorp_profile_end_id(0);

                for (size_t index = 0; index <= BLORP_PROFILE_MAX_STACK; index++) {
                    blorp_profile_start_id(0);
                }
                for (size_t index = 0; index < BLORP_PROFILE_MAX_STACK; index++) {
                    blorp_profile_end_id(0);
                }

                blorp_profile_window_end();
                blorp_profile_report();
                return 0;
            }
            """
        )
        with tempfile.TemporaryDirectory() as temp_name:
            executable = Path(temp_name) / "dense-profile-ids"
            compiled = subprocess.run(
                [
                    os.environ.get("CC", "cc"),
                    "-O1",
                    "-g",
                    "-fsanitize=address,undefined",
                    "-fno-omit-frame-pointer",
                    "-w",
                    f"-I{RUNTIME_NATIVE}",
                    "-x",
                    "c",
                    "-",
                    "-lm",
                    "-lpthread",
                    "-o",
                    str(executable),
                ],
                cwd=ROOT,
                input=source,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)

            environment = dict(os.environ)
            environment["ASAN_OPTIONS"] = "detect_leaks=0:halt_on_error=1"
            completed = subprocess.run(
                [str(executable)],
                cwd=ROOT,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("PROFILE_INITIALIZATION_FAILURE", completed.stderr)
        self.assertRegex(
            completed.stderr,
            r"PROFILE_DIAGNOSTICS profile_mode=exact functions_described=2 "
            r"functions_selected=2 functions_observed=2 "
            r"invalid_start_ids=1 invalid_end_ids=1 unmatched_ends=1 "
            r"out_of_order_ends=1 "
            r"metadata_initialization_failures=1 stack_overflows=1",
        )

    def test_cleanup_waits_for_active_profile_updates(self) -> None:
        source = textwrap.dedent(
            """\
            #define MINICORO_IMPL
            #include "minicoro.h"
            #include "runtime.c"

            static const blorp_ProfileFunctionMetadata functions[] = {
                {"worker", "brp_worker", NULL, 1, 0u},
            };
            static atomic_int worker_started = 0;

            static void* profile_worker(void* unused) {
                (void)unused;
                atomic_fetch_add(&profile_active_update_operations, 1);
                blorp_ProfileEntry* entry = &profile_entries[0];
                atomic_store(&worker_started, 1);
                struct timespec delay = {.tv_sec = 0, .tv_nsec = 50000000};
                nanosleep(&delay, NULL);
                atomic_fetch_add(&entry->call_count, 1);
                atomic_fetch_sub(&profile_active_update_operations, 1);
                return NULL;
            }

            int main(void) {
                if (blorp_profile_enable(BLORP_PROFILE_MODE_EXACT, functions, 1, 1) != 0) return 2;
                pthread_t worker;
                if (pthread_create(&worker, NULL, profile_worker, NULL) != 0) return 3;
                while (!atomic_load(&worker_started)) sched_yield();
                blorp_profile_cleanup();
                if (pthread_join(worker, NULL) != 0) return 4;
                if (profile_entries != NULL || atomic_load(&profiling_enabled)) return 5;
                return 0;
            }
            """
        )
        with tempfile.TemporaryDirectory() as temp_name:
            executable = Path(temp_name) / "dense-profile-cleanup"
            compiled = subprocess.run(
                [
                    os.environ.get("CC", "cc"),
                    "-O1",
                    "-g",
                    "-fsanitize=address,undefined",
                    "-fno-omit-frame-pointer",
                    "-w",
                    f"-I{RUNTIME_NATIVE}",
                    "-x",
                    "c",
                    "-",
                    "-lm",
                    "-lpthread",
                    "-o",
                    str(executable),
                ],
                cwd=ROOT,
                input=source,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)

            environment = dict(os.environ)
            environment["ASAN_OPTIONS"] = "detect_leaks=0:halt_on_error=1"
            completed = subprocess.run(
                [str(executable)],
                cwd=ROOT,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )

        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_start_between_windows_is_discarded_without_loss(self) -> None:
        source = textwrap.dedent(
            """\
            #define MINICORO_IMPL
            #include "minicoro.h"
            #include "runtime.c"

            static const blorp_ProfileFunctionMetadata functions[] = {
                {"crossing", "brp_crossing", NULL, 1, 0u},
                {"measured", "brp_measured", NULL, 2, 0u},
            };

            int main(void) {
                if (blorp_profile_enable(BLORP_PROFILE_MODE_EXACT, functions, 2, 2) != 0) return 2;
                blorp_profile_window_begin();
                blorp_profile_window_end();
                blorp_profile_start_id(0);
                if (profile_stack_depth != 1) return 3;
                if (profile_stack[0].epoch != BLORP_PROFILE_SUPPRESSED_EPOCH) return 4;
                blorp_profile_window_begin();
                blorp_profile_push_suppressed_frame(0);
                if (profile_stack_depth != 2) return 5;
                if (profile_stack[1].epoch != BLORP_PROFILE_SUPPRESSED_EPOCH) return 6;
                blorp_profile_end_id(0);
                blorp_profile_end_id(0);
                blorp_profile_start_id(1);
                blorp_profile_end_id(1);
                blorp_profile_window_end();
                blorp_profile_report();
                return 0;
            }
            """
        )
        with tempfile.TemporaryDirectory() as temp_name:
            executable = Path(temp_name) / "dense-profile-repeated-window"
            compiled = subprocess.run(
                [
                    os.environ.get("CC", "cc"),
                    "-O1",
                    "-g",
                    "-fsanitize=address,undefined",
                    "-fno-omit-frame-pointer",
                    "-w",
                    f"-I{RUNTIME_NATIVE}",
                    "-x",
                    "c",
                    "-",
                    "-lm",
                    "-lpthread",
                    "-o",
                    str(executable),
                ],
                cwd=ROOT,
                input=source,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)

            environment = dict(os.environ)
            environment["ASAN_OPTIONS"] = "detect_leaks=0:halt_on_error=1"
            completed = subprocess.run(
                [str(executable)],
                cwd=ROOT,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertRegex(
            completed.stderr,
            r"PROFILE_DIAGNOSTICS profile_mode=exact functions_described=2 "
            r"functions_selected=2 functions_observed=1 "
            r"invalid_start_ids=0 invalid_end_ids=0 unmatched_ends=0 "
            r"out_of_order_ends=0 metadata_initialization_failures=0 "
            r"stack_overflows=0 calls_observed=0 calls_completed=1",
        )

    def test_generated_profile_observes_more_than_old_registry_limit(self) -> None:
        function_count = 4096
        group_size = 64
        group_count = function_count // group_size
        fixture_function_count = function_count + group_count + 1
        # The production pipeline adds six support bodies; three run for this
        # program. Pin both counts so a profiler loss cannot look like DCE.
        generated_support_function_count = 6
        called_generated_support_function_count = 3
        functions = "\n".join(
            f"pure func profile_{index}() -> Int: {index}"
            for index in range(function_count)
        )
        groups = "\n\n".join(
            "\n".join(
                [
                    f"pure func profile_group_{group_index}() -> Int:",
                    "\tvar total: Int = 0",
                    *[
                        f"\ttotal += profile_{index}()"
                        for index in range(
                            group_index * group_size,
                            (group_index + 1) * group_size,
                        )
                    ],
                    "\ttotal",
                ]
            )
            for group_index in range(group_count)
        )
        calls = "\n".join(
            f"\ttotal += profile_group_{group_index}()"
            for group_index in range(group_count)
        )
        program = (
            f"{functions}\n\n{groups}\n\n"
            "func main(args: List[String]) -> Int:\n"
            "\tvar total: Int = 0\n"
            f"{calls}\n"
            "\ttotal\n"
        )

        with tempfile.TemporaryDirectory() as temp_name:
            temp = Path(temp_name)
            source = temp / "dense-profile-integration.brp"
            generated_c = temp / "dense-profile-integration.c"
            executable = temp / "dense-profile-integration"
            source.write_text(program)

            compiled = subprocess.run(
                [
                    str(ROOT / "bin" / "blorp"),
                    "compile",
                    "--profile",
                    "--no-format",
                    "-o",
                    str(generated_c),
                    str(source),
                ],
                cwd=ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=240,
                check=False,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            generated = generated_c.read_text()
            metadata_table = re.search(
                r"static const blorp_ProfileFunctionMetadata __blorp_profile_functions\[(\d+)\] "
                r"= \{\n(?P<rows>.*?)\n\};",
                generated,
                re.DOTALL,
            )
            self.assertIsNotNone(metadata_table)
            assert metadata_table is not None
            described_count = int(metadata_table.group(1))
            self.assertEqual(
                metadata_table.group("rows").count("\n") + 1,
                described_count,
            )
            start_ids = tuple(
                map(int, re.findall(r"blorp_profile_start_id\((\d+)\)", generated))
            )
            end_ids = tuple(
                map(int, re.findall(r"blorp_profile_end_id\((\d+)\)", generated))
            )
            self.assertEqual(start_ids, tuple(range(described_count)))
            self.assertEqual(set(end_ids), set(range(described_count)))
            self.assertNotIn("blorp_profile_start(\"", generated)

            c_compiled = subprocess.run(
                [
                    os.environ.get("CC", "cc"),
                    "-O0",
                    "-w",
                    str(generated_c),
                    "-lm",
                    "-lpthread",
                    "-o",
                    str(executable),
                ],
                cwd=ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=240,
                check=False,
            )
            self.assertEqual(c_compiled.returncode, 0, c_compiled.stderr)

            completed = subprocess.run(
                [str(executable)],
                cwd=ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=60,
                check=False,
            )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        diagnostics = re.search(
            r"PROFILE_DIAGNOSTICS profile_mode=exact functions_described=(\d+) "
            r"functions_selected=(\d+) functions_observed=(\d+) "
            r"invalid_start_ids=(\d+) invalid_end_ids=(\d+) unmatched_ends=(\d+) "
            r"out_of_order_ends=(\d+) "
            r"metadata_initialization_failures=(\d+) stack_overflows=(\d+) "
            r"calls_observed=(\d+) calls_completed=(\d+)",
            completed.stderr,
        )
        self.assertIsNotNone(diagnostics, completed.stderr)
        assert diagnostics is not None
        self.assertEqual(
            tuple(map(int, diagnostics.groups())),
            (
                fixture_function_count + generated_support_function_count,
                fixture_function_count + generated_support_function_count,
                fixture_function_count + called_generated_support_function_count,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                fixture_function_count + called_generated_support_function_count,
            ),
        )


if __name__ == "__main__":
    unittest.main()
