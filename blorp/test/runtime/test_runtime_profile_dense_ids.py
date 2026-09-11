#!/usr/bin/env python3
"""Runtime and generated-artifact contracts for dense function profile IDs."""

from __future__ import annotations

import os
import re
import signal
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
RUNTIME_NATIVE = ROOT / "blorp" / "src" / "lib" / "runtime" / "native"


class RuntimeDenseProfileIdTests(unittest.TestCase):
    def test_exact_profile_accounts_cancelled_fiber_frames(self) -> None:
        program = textwrap.dedent(
            """\
            import:
                test: cancel_after_parked_for_test

            func blocked() -> Int:
                sleep(10000)
                1

            func main(args: List[String]) -> Int:
                if cancel_after_parked_for_test(func(): blocked()):
                    0
                else:
                    1
            """
        )
        with tempfile.TemporaryDirectory() as temp_name:
            temp = Path(temp_name)
            source = temp / "cancelled-fiber-profile.brp"
            generated_c = temp / "cancelled-fiber-profile.c"
            executable = temp / "cancelled-fiber-profile"
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
                check=False,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)

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

            environment = dict(os.environ)
            environment["BLORP_THREADS"] = "1"
            completed = subprocess.run(
                [str(executable)],
                cwd=ROOT,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=30,
                check=False,
            )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        diagnostics = re.search(
            r"unmatched_ends=(\d+) out_of_order_ends=(\d+) .*"
            r"abandoned_frames=(\d+) window_abandoned_frames=(\d+) "
            r"cancellation_abandoned_frames=(\d+) "
            r"dead_or_shutdown_abandoned_frames=(\d+)",
            completed.stderr,
        )
        self.assertIsNotNone(diagnostics, completed.stderr)
        assert diagnostics is not None
        unmatched, out_of_order, abandoned, window, cancellation, dead = map(
            int, diagnostics.groups()
        )
        self.assertEqual((unmatched, out_of_order, window, dead), (0, 0, 0, 0))
        self.assertGreater(cancellation, 0)
        self.assertEqual(abandoned, cancellation)

    def test_exact_profile_excludes_other_fiber_work_from_parked_function(self) -> None:
        program = textwrap.dedent(
            """\
            func parked(ready: Channel[Int], release: Channel[Int]) -> Int:
                _ = send(ready, 500000)
                _ = recv(release)
                1

            pure func busy_work(iterations: Int) -> Int:
                var index: Int = 0
                var total: Int = 0
                while index < iterations:
                    total += index
                    index += 1
                total

            func busy(ready: Channel[Int], release: Channel[Int]) -> Int:
                iterations: Int = match recv(ready):
                    Some(value): value
                    None: 0
                result: Int = busy_work(iterations)
                _ = send(release, 1)
                result

            func main(args: List[String]) -> Int:
                ready: Channel[Int] = channel(1)
                release: Channel[Int] = channel(1)
                concurrent:
                    parked_result = parked(ready, release)
                    busy_result = busy(ready, release)
                0
            """
        )
        with tempfile.TemporaryDirectory(dir=ROOT) as temp_name:
            temp = Path(temp_name)
            source = temp / "fiber-profile.brp"
            generated_c = temp / "fiber-profile.c"
            executable = temp / "fiber-profile"
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
                check=False,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)

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

            environment = dict(os.environ)
            environment["BLORP_THREADS"] = "1"
            completed = subprocess.run(
                [str(executable)],
                cwd=ROOT,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=30,
                check=False,
            )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        rows = {
            match.group(1): (float(match.group(2)), float(match.group(3)))
            for match in re.finditer(
                r"^(parked|busy)\s+\S+\s+([0-9.]+)\s+([0-9.]+)\s+",
                completed.stderr,
                re.MULTILINE,
            )
        }
        self.assertEqual(set(rows), {"parked", "busy"}, completed.stderr)
        parked_inclusive, parked_self = rows["parked"]
        busy_inclusive, busy_self = rows["busy"]
        self.assertLess(parked_inclusive, busy_inclusive)
        self.assertLessEqual(parked_self, parked_inclusive)
        self.assertLessEqual(busy_self, busy_inclusive)
        self.assertRegex(
            completed.stderr,
            r"unmatched_ends=0 out_of_order_ends=0 .*abandoned_frames=0 ",
        )

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
                if (profile_root_execution_state != NULL) return 5;
                if (atomic_load(&profile_entries[0].total_ns) != 0) return 6;
                if (atomic_load(&profile_entries[0].call_count) != 3) return 7;
                if (atomic_load(&profile_entries[1].call_count) != 0) return 8;
                if (atomic_load(&profile_stack_growths) != 0) return 9;
#if BLORP_PROFILE_EXACT_TIMING
                return 10;
#endif
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
            r"stack_growths=0 .*calls_observed=3 calls_completed=0",
        )
        self.assertNotIn("never_called", completed.stderr)

    def test_exact_profile_uses_fiber_execution_states_and_dynamic_stacks(self) -> None:
        source = textwrap.dedent(
            """\
            #define BLORP_PROFILE_EXACT_TIMING 1
            #define MINICORO_IMPL
            #include "minicoro.h"
            #include "runtime.c"

            static const blorp_ProfileFunctionMetadata functions[] = {
                {"parent", "brp_parent", NULL, 1, 0u},
                {"child", "brp_child", NULL, 2, 0u},
            };

            static void unbalanced_fiber(mco_coro* coroutine) {
                (void)coroutine;
                blorp_profile_start_id(1);
            }

            int main(void) {
                blorp_ProfileExecutionState failed_growth = {
                    .depth = SIZE_MAX,
                    .capacity = SIZE_MAX,
                };
                if (blorp_profile_execution_push(
                        &failed_growth,
                        (blorp_ProfileFrame){.id = 0, .epoch = 1})) return 2;
                if (failed_growth.dropped_depth != 1) return 3;
                if (atomic_load(&profile_stack_growth_failures) != 1) return 4;
                failed_growth.depth = 0;
                blorp_profile_execution_destroy(&failed_growth);

                blorp_ProfileExecutionState clock_state = {0};
                blorp_profile_execution_resume(&clock_state, 100);
                if (blorp_profile_execution_active_now(&clock_state, 140) != 40) return 5;
                blorp_profile_execution_suspend(&clock_state, 160);
                blorp_profile_execution_resume(&clock_state, 1000);
                if (blorp_profile_execution_active_now(&clock_state, 1030) != 90) return 6;
                blorp_profile_execution_suspend(&clock_state, 1050);
                if (clock_state.active_elapsed_ns != 110) return 7;

                if (blorp_profile_enable(BLORP_PROFILE_MODE_EXACT, functions, 2, 2) != 0) return 8;

                unsigned long arithmetic_epoch = atomic_load(&profile_epoch);
                blorp_ProfileExecutionState arithmetic = {0};
                if (!blorp_profile_execution_push(
                        &arithmetic,
                        (blorp_ProfileFrame){
                            .id = 0,
                            .start_active_ns = 10,
                            .epoch = arithmetic_epoch,
                        })) return 60;
                if (!blorp_profile_execution_push(
                        &arithmetic,
                        (blorp_ProfileFrame){
                            .id = 1,
                            .start_active_ns = 20,
                            .epoch = arithmetic_epoch,
                        })) return 61;
                blorp_ProfileFrame arithmetic_child = arithmetic.frames[1];
                arithmetic.depth = 1;
                blorp_profile_record_completed_frame(
                    &arithmetic, 1, arithmetic_child, 50, false);
                blorp_ProfileFrame arithmetic_parent = arithmetic.frames[0];
                arithmetic.depth = 0;
                blorp_profile_record_completed_frame(
                    &arithmetic, 0, arithmetic_parent, 100, false);
                if (atomic_load(&profile_entries[0].total_ns) != 90) return 62;
                if (atomic_load(&profile_entries[0].self_ns) != 60) return 63;
                if (atomic_load(&profile_entries[1].total_ns) != 30) return 64;
                if (atomic_load(&profile_entries[1].self_ns) != 30) return 65;
                if (atomic_load(&profile_calls_completed) != 2) return 66;
                blorp_profile_execution_destroy(&arithmetic);
                for (size_t index = 0; index < 2; index++) {
                    atomic_store(&profile_entries[index].total_ns, 0);
                    atomic_store(&profile_entries[index].self_ns, 0);
                    atomic_store(&profile_entries[index].call_count, 0);
                }
                atomic_store(&profile_calls_completed, 0);

                unsigned long cancellation_epoch = atomic_load(&profile_epoch);
                blorp_ProfileExecutionState cancellation_state = {
                    .epoch = cancellation_epoch,
                };
                if (!blorp_profile_execution_push(
                        &cancellation_state,
                        (blorp_ProfileFrame){
                            .id = 0,
                            .epoch = cancellation_epoch,
                        })) return 42;
                if (!blorp_profile_execution_push(
                        &cancellation_state,
                        (blorp_ProfileFrame){
                            .id = 0,
                            .epoch = BLORP_PROFILE_SUPPRESSED_EPOCH,
                        })) return 43;
                if (!blorp_profile_execution_push(
                        &cancellation_state,
                        (blorp_ProfileFrame){
                            .id = 0,
                            .epoch = cancellation_epoch,
                        })) return 44;
                cancellation_state.dropped_depth = 2;
                profile_root_execution_state = &cancellation_state;
                blorp_profile_abandon_current_to_depth(
                    (blorp_ProfileExecutionDepth){.frame_depth = 1});
                profile_root_execution_state = NULL;
                if (cancellation_state.depth != 1) return 45;
                if (cancellation_state.dropped_depth != 0) return 46;
                if (atomic_load(&profile_cancellation_abandoned_frames) != 3)
                    return 47;
                if (atomic_load(&profile_abandoned_frames) != 3) return 48;
                blorp_profile_execution_destroy(&cancellation_state);

                blorp_profile_window_begin();

                unsigned long crossing_epoch = atomic_load(&profile_epoch);
                blorp_ProfileExecutionState crossing_state = {
                    .epoch = crossing_epoch,
                };
                if (!blorp_profile_execution_push(
                        &crossing_state,
                        (blorp_ProfileFrame){
                            .id = 0,
                            .epoch = crossing_epoch,
                        })) return 72;
                blorp_ProfileExecutionDepth crossing_depth = {
                    .frame_depth = crossing_state.depth,
                };
                if (!blorp_profile_execution_push(
                        &crossing_state,
                        (blorp_ProfileFrame){
                            .id = 1,
                            .epoch = crossing_epoch,
                        })) return 73;
                blorp_profile_window_end();
                blorp_profile_window_begin();
                profile_root_execution_state = &crossing_state;
                blorp_profile_abandon_current_to_depth(crossing_depth);
                profile_root_execution_state = NULL;
                if (crossing_state.depth != 1) return 74;
                if (atomic_load(&profile_window_abandoned_frames) != 2)
                    return 75;
                if (atomic_load(&profile_cancellation_abandoned_frames) != 0)
                    return 76;
                if (atomic_load(&profile_abandoned_frames) != 2) return 77;
                blorp_profile_execution_destroy(&crossing_state);

                blorp_profile_window_begin();

                unsigned long debt_epoch = atomic_load(&profile_epoch);
                blorp_ProfileExecutionState debt_state = {
                    .depth = SIZE_MAX,
                    .capacity = SIZE_MAX,
                    .epoch = debt_epoch,
                };
                if (blorp_profile_execution_push(
                        &debt_state,
                        (blorp_ProfileFrame){.id = 0, .epoch = debt_epoch})) return 52;
                debt_state.depth = 0;
                debt_state.capacity = 0;
                blorp_profile_window_end();
                blorp_profile_window_begin();
                unsigned long next_debt_epoch = atomic_load(&profile_epoch);
                blorp_profile_execution_sync_epoch(&debt_state, next_debt_epoch);
                if (debt_state.dropped_depth != 0) return 53;
                if (debt_state.suppressed_dropped_depth != 1) return 54;
                if (atomic_load(&profile_window_abandoned_frames) != 1) return 55;
                if (debt_epoch == next_debt_epoch) return 56;
                blorp_profile_execution_push(
                    &debt_state,
                    (blorp_ProfileFrame){.id = 0, .epoch = next_debt_epoch});
                if (debt_state.dropped_depth != 1) return 57;
                profile_root_execution_state = &debt_state;
                blorp_profile_end_id(0);
                blorp_profile_end_id(0);
                profile_root_execution_state = NULL;
                if (debt_state.dropped_depth != 0) return 58;
                if (debt_state.suppressed_dropped_depth != 0) return 59;
                blorp_profile_execution_destroy(&debt_state);

                blorp_profile_window_begin();

                blorp_profile_start_id(0);
                blorp_profile_start_id(1);
                blorp_profile_end_id(1);
                blorp_profile_end_id(0);
                if (atomic_load(&profile_entries[0].total_ns)
                    < atomic_load(&profile_entries[1].total_ns)) return 49;
                if (atomic_load(&profile_entries[0].self_ns)
                    > atomic_load(&profile_entries[0].total_ns)) return 50;
                if (atomic_load(&profile_entries[1].self_ns)
                    > atomic_load(&profile_entries[1].total_ns)) return 51;

                blorp_Fiber first = {0};
                blorp_Fiber second = {0};
                __blorp_current_fiber = &first;
                blorp_profile_execution_resume(
                    &first.profile_execution_state, blorp_profile_now_ns());
                blorp_profile_start_id(0);
                blorp_profile_execution_suspend(
                    &first.profile_execution_state, blorp_profile_now_ns());

                __blorp_current_fiber = &second;
                blorp_profile_execution_resume(
                    &second.profile_execution_state, blorp_profile_now_ns());
                blorp_profile_start_id(1);
                blorp_profile_end_id(1);
                blorp_profile_execution_suspend(
                    &second.profile_execution_state, blorp_profile_now_ns());

                __blorp_current_fiber = &first;
                blorp_profile_execution_resume(
                    &first.profile_execution_state, blorp_profile_now_ns());
                blorp_profile_end_id(0);
                blorp_profile_execution_suspend(
                    &first.profile_execution_state, blorp_profile_now_ns());
                __blorp_current_fiber = NULL;

                if (first.profile_execution_state.depth != 0) return 9;
                if (second.profile_execution_state.depth != 0) return 10;
                if (atomic_load(&profile_entries[0].call_count) != 2) return 11;
                if (atomic_load(&profile_entries[1].call_count) != 2) return 12;
                if (atomic_load(&profile_out_of_order_ends) != 0) return 13;
                if (atomic_load(&profile_unmatched_ends) != 0) return 14;
                if (atomic_load(&profile_entries[0].self_ns)
                    > atomic_load(&profile_entries[0].total_ns)) return 15;
                if (atomic_load(&profile_entries[1].self_ns)
                    > atomic_load(&profile_entries[1].total_ns)) return 16;

                for (size_t index = 0; index < 5000; index++) {
                    blorp_profile_start_id(0);
                }
                if (profile_root_execution_state == NULL) return 17;
                if (profile_root_execution_state->depth != 5000) return 18;
                if (profile_root_execution_state->capacity < 5000) return 19;
                for (size_t index = 0; index < 5000; index++) {
                    blorp_profile_end_id(0);
                }
                if (atomic_load(&profile_stack_growth_failures) != 0) return 20;
                if (atomic_load(&profile_max_stack_depth) != 5000) return 21;

                blorp_Fiber* abandoned = blorp_fiber_create(unbalanced_fiber, NULL);
                if (!abandoned) return 67;
                __blorp_current_fiber = abandoned;
                blorp_profile_fiber_resume(abandoned);
                if (mco_resume(abandoned->coro) != MCO_SUCCESS) return 68;
                blorp_profile_fiber_suspend(abandoned);
                __blorp_current_fiber = NULL;
                if (mco_status(abandoned->coro) != MCO_DEAD) return 69;
                mco_destroy(abandoned->coro);
                abandoned->coro = NULL;
                blorp_fiber_object_recycle(abandoned);
                if (abandoned->profile_execution_state.frames != NULL) return 70;
                if (atomic_load(&profile_dead_or_shutdown_abandoned_frames) != 1)
                    return 71;

                atomic_store(&profile_entries[0].total_ns, 90000000);
                atomic_store(&profile_entries[0].self_ns, 60000000);
                atomic_store(&profile_entries[0].call_count, 1);
                atomic_store(&profile_entries[1].total_ns, 30000000);
                atomic_store(&profile_entries[1].self_ns, 30000000);
                atomic_store(&profile_entries[1].call_count, 1);

                blorp_profile_execution_destroy(&first.profile_execution_state);
                blorp_profile_execution_destroy(&second.profile_execution_state);
                blorp_profile_execution_destroy(&clock_state);
                blorp_profile_window_end();
                blorp_profile_report();
                return 0;
            }
            """
        )
        with tempfile.TemporaryDirectory() as temp_name:
            executable = Path(temp_name) / "fiber-profile-state"
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
            detect_leaks = "0" if sys.platform == "darwin" else "1"
            environment["ASAN_OPTIONS"] = (
                f"detect_leaks={detect_leaks}:halt_on_error=1"
            )
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
        self.assertIn("Inclusive (ms)", completed.stderr)
        self.assertIn("Self (ms)", completed.stderr)
        self.assertIn("TOTAL SELF", completed.stderr)
        parent_row = re.search(r"^parent\s+brp_parent\s+90\.000\s+60\.000\s+66\.7%", completed.stderr, re.MULTILINE)
        child_row = re.search(r"^child\s+brp_child\s+30\.000\s+30\.000\s+33\.3%", completed.stderr, re.MULTILINE)
        self.assertIsNotNone(parent_row, completed.stderr)
        self.assertIsNotNone(child_row, completed.stderr)
        assert parent_row is not None and child_row is not None
        self.assertLess(parent_row.start(), child_row.start())
        self.assertRegex(
            completed.stderr,
            r"PROFILE_DIAGNOSTICS profile_mode=exact .*"
            r"stack_growth_failures=0 stack_growths=[1-9][0-9]* "
            r"max_stack_depth=5000 .*dead_or_shutdown_abandoned_frames=1 .*"
            r"calls_completed=5004",
        )

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

    def test_exact_signal_report_accounts_parked_fiber_frames(self) -> None:
        source = textwrap.dedent(
            """\
            #define BLORP_PROFILE_EXACT_TIMING 1
            #define MINICORO_IMPL
            #include "minicoro.h"
            #include "runtime.c"

            static const blorp_ProfileFunctionMetadata functions[] = {
                {"root", "brp_root", NULL, 1, 0u},
                {"parked", "brp_parked", NULL, 2, 0u},
            };

            static void suspended_fiber(mco_coro* coroutine) {
                blorp_profile_start_id(1);
                mco_yield(coroutine);
                blorp_profile_end_id(1);
            }

            int main(void) {
                if (blorp_profile_enable(
                        BLORP_PROFILE_MODE_EXACT, functions, 2, 2) != 0) {
                    return 2;
                }
                blorp_profile_window_begin();
                blorp_Fiber* fiber = blorp_fiber_create(suspended_fiber, NULL);
                if (!fiber) return 3;
                __blorp_current_fiber = fiber;
                blorp_profile_fiber_resume(fiber);
                if (mco_resume(fiber->coro) != MCO_SUCCESS) return 4;
                blorp_profile_fiber_suspend(fiber);
                __blorp_current_fiber = NULL;
                if (mco_status(fiber->coro) != MCO_SUSPENDED) return 5;
                fprintf(stdout, "ready\\n");
                fflush(stdout);
                for (;;) {
                    blorp_profile_start_id(0);
                    blorp_profile_end_id(0);
                }
            }
            """
        )
        with tempfile.TemporaryDirectory() as temp_name:
            executable = Path(temp_name) / "exact-profile-signal"
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
                process.send_signal(signal.SIGTERM)
                _, stderr = process.communicate(timeout=10)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()

        self.assertEqual(process.returncode, -signal.SIGTERM, stderr)
        diagnostics = re.search(
            r"abandoned_frames=(\d+) window_abandoned_frames=(\d+) "
            r"cancellation_abandoned_frames=(\d+) "
            r"dead_or_shutdown_abandoned_frames=(\d+) "
            r"signal_abandoned_frames=(\d+) nonlocal_abandoned_frames=(\d+)",
            stderr,
        )
        self.assertIsNotNone(diagnostics, stderr)
        assert diagnostics is not None
        abandoned, window, cancellation, dead, terminated, nonlocal_exit = map(
            int, diagnostics.groups()
        )
        self.assertGreaterEqual(terminated, 1)
        self.assertEqual((window, cancellation, dead, nonlocal_exit), (0, 0, 0, 0))
        self.assertEqual(abandoned, terminated)

    def test_invalid_operations_are_sanitizer_clean_and_reported(self) -> None:
        source = textwrap.dedent(
            """\
            #define BLORP_PROFILE_EXACT_TIMING 1
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

                for (size_t index = 0; index < 5000; index++) {
                    blorp_profile_start_id(0);
                }
                for (size_t index = 0; index < 5000; index++) {
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
            r"invalid_start_ids=1 invalid_end_ids=1 unmatched_ends=2 "
            r"out_of_order_ends=1 "
            r"metadata_initialization_failures=1 stack_growth_failures=0 "
            r"stack_growths=8 max_stack_depth=5000 abandoned_frames=2 "
            r"window_abandoned_frames=1 cancellation_abandoned_frames=0 "
            r"dead_or_shutdown_abandoned_frames=0 signal_abandoned_frames=0 "
            r"nonlocal_abandoned_frames=1 recovered_nonlocal_exits=1 ",
        )

    def test_window_and_cleanup_wait_for_active_profile_operations(self) -> None:
        source = textwrap.dedent(
            """\
            #define BLORP_PROFILE_EXACT_TIMING 1
            #define MINICORO_IMPL
            #include "minicoro.h"
            #include "runtime.c"

            static const blorp_ProfileFunctionMetadata functions[] = {
                {"worker", "brp_worker", NULL, 1, 0u},
            };
            static atomic_int worker_started = 0;
            static atomic_int frame_holder_started = 0;
            static atomic_int frame_holder_release = 0;
            static atomic_int window_completed = 0;
            static atomic_int report_started = 0;
            static atomic_int report_completed = 0;

            static void* hold_frame_operation(void* unused) {
                (void)unused;
                if (!blorp_profile_frame_operation_enter()) return (void*)1;
                atomic_store(&frame_holder_started, 1);
                while (!atomic_load(&frame_holder_release)) sched_yield();
                blorp_profile_frame_operation_leave();
                return NULL;
            }

            static void* begin_profile_window(void* unused) {
                (void)unused;
                blorp_profile_window_begin();
                atomic_store(&window_completed, 1);
                return NULL;
            }

            static void* report_profile(void* unused) {
                (void)unused;
                atomic_store(&report_started, 1);
                blorp_profile_report();
                atomic_store(&report_completed, 1);
                return NULL;
            }

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
                pthread_t frame_holder;
                pthread_t window_worker;
                if (pthread_create(
                        &frame_holder, NULL, hold_frame_operation, NULL) != 0) return 6;
                while (!atomic_load(&frame_holder_started)) sched_yield();
                if (pthread_create(
                        &window_worker, NULL, begin_profile_window, NULL) != 0) return 7;
                while (atomic_load(&profile_frame_operations_enabled)) sched_yield();
                if (atomic_load(&window_completed)) return 8;
                atomic_store(&frame_holder_release, 1);
                void* frame_result = NULL;
                if (pthread_join(frame_holder, &frame_result) != 0) return 9;
                if (frame_result != NULL) return 10;
                if (pthread_join(window_worker, NULL) != 0) return 11;
                if (!atomic_load(&window_completed)) return 12;

                pthread_mutex_lock(&profile_window_mutex);
                pthread_t report_worker;
                if (pthread_create(
                        &report_worker, NULL, report_profile, NULL) != 0) return 13;
                while (!atomic_load(&report_started)) sched_yield();
                struct timespec report_delay = {
                    .tv_sec = 0,
                    .tv_nsec = 50000000,
                };
                nanosleep(&report_delay, NULL);
                if (atomic_load(&report_completed)) return 14;
                pthread_mutex_unlock(&profile_window_mutex);
                if (pthread_join(report_worker, NULL) != 0) return 15;
                if (!atomic_load(&report_completed)) return 16;

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
            #define BLORP_PROFILE_EXACT_TIMING 1
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
                blorp_profile_start_id(0);
                if (profile_root_execution_state == NULL) return 3;
                if (profile_root_execution_state->depth != 1) return 4;
                blorp_profile_window_end();
                blorp_profile_window_begin();
                blorp_profile_start_id(1);
                if (profile_root_execution_state->depth != 2) return 5;
                if (profile_root_execution_state->frames[0].epoch != BLORP_PROFILE_SUPPRESSED_EPOCH) return 6;
                blorp_profile_end_id(1);
                blorp_profile_end_id(0);
                blorp_profile_start_id(1);
                blorp_profile_end_id(1);
                blorp_profile_start_id(0);
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
            r"stack_growth_failures=0 .*abandoned_frames=2 "
            r"window_abandoned_frames=2 cancellation_abandoned_frames=0 "
            r"dead_or_shutdown_abandoned_frames=0 .*"
            r"calls_observed=0 calls_completed=2",
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
            r"metadata_initialization_failures=(\d+) stack_growth_failures=(\d+) .*"
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
