#!/usr/bin/env python3
"""Native contract checks for the final-release path.

Collection destructors release their elements through the collection's
release function, and unboxing a boxed Result hands its payload reference to
the stack value. These checks pin the observable contract of both: every
heap element is released exactly once, a custom release function still runs
for every element, a shared element keeps its other owners' references, and
unboxing a unique or a shared box leaves the payload's count exact and the
program leak-clean.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]

# Shared C prelude: a counted element type whose destructor records each run,
# and a live-object check built on the lightweight allocator statistics.
PRELUDE = textwrap.dedent(
    """\
    #define MINICORO_IMPL
    #include "minicoro.h"
    #include "runtime.c"

    static int element_destructor_runs;
    static void counted_element_destroy(void* obj) {
        (void)obj;
        element_destructor_runs++;
    }
    static void* new_counted_element(void) {
        void* obj = blorp_alloc(sizeof(blorp_Object) + sizeof(long));
        BLORP_SET_DESTRUCTOR(obj, counted_element_destroy);
        return obj;
    }
    static long refcount_of(void* obj) {
        return (long)atomic_load(&((blorp_Object*)obj)->refcount);
    }
    static long live_objects(void) {
        return (long)blorp_get_mem_stats().current_objects;
    }
    """
)


class RuntimeReleasePathTests(unittest.TestCase):
    def _run(self, body: str) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as temp_name:
            executable = Path(temp_name) / "release-path"
            compiled = subprocess.run(
                [
                    os.environ.get("CC", "cc"),
                    "-O0",
                    "-w",
                    "-DBLORP_MEMORY_DIAGNOSTICS=1",
                    f"-I{ROOT / 'blorp' / 'src' / 'lib' / 'runtime' / 'native'}",
                    "-x",
                    "c",
                    "-",
                    "-lm",
                    "-lpthread",
                    "-o",
                    str(executable),
                ],
                cwd=ROOT,
                input=PRELUDE + textwrap.dedent(body),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            environment = dict(os.environ)
            environment["BLORP_ALLOCATOR_STATS"] = "1"
            return subprocess.run(
                [str(executable)],
                cwd=ROOT,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )

    def _assert_passes(self, body: str) -> None:
        completed = self._run(body)
        self.assertEqual(
            completed.returncode, 0,
            f"exit {completed.returncode}\n{completed.stdout}{completed.stderr}")

    def test_list_of_heap_values_releases_each_element_once(self) -> None:
        self._assert_passes(
            """\
            int main(void) {
                long before = live_objects();
                void* shared = new_counted_element();
                blorp_List* list = blorp_list_new(4);
                blorp_list_init_elem_release(list, blorp_elem_release_fn);
                for (int i = 0; i < 3; i++)
                    list = blorp_list_append_owned(list, new_counted_element());
                list = blorp_list_append(list, shared);
                if (refcount_of(shared) != 2) return 1;
                blorp_release(list);
                if (element_destructor_runs != 3) return 2;
                if (refcount_of(shared) != 1) return 3;
                blorp_release(shared);
                if (element_destructor_runs != 4) return 4;
                if (live_objects() != before) return 5;
                return 0;
            }
            """
        )

    def test_list_of_lists_releases_nested_elements_once(self) -> None:
        self._assert_passes(
            """\
            int main(void) {
                long before = live_objects();
                blorp_List* outer = blorp_list_new(4);
                blorp_list_init_elem_release(outer, blorp_elem_release_fn);
                for (int i = 0; i < 3; i++) {
                    blorp_List* inner = blorp_list_new(4);
                    blorp_list_init_elem_release(inner, blorp_elem_release_fn);
                    for (int j = 0; j < 2; j++)
                        inner = blorp_list_append_owned(inner, new_counted_element());
                    outer = blorp_list_append_owned(outer, inner);
                }
                blorp_release(outer);
                if (element_destructor_runs != 6) return 1;
                if (live_objects() != before) return 2;
                return 0;
            }
            """
        )

    def test_list_custom_elem_release_runs_for_every_element(self) -> None:
        self._assert_passes(
            """\
            static int custom_release_calls;
            static void custom_release(void* value) {
                custom_release_calls++;
                blorp_release(value);
            }
            int main(void) {
                long before = live_objects();
                blorp_List* list = blorp_list_new(4);
                blorp_list_init_elem_release(list, custom_release);
                for (int i = 0; i < 5; i++)
                    list = blorp_list_append_owned(list, new_counted_element());
                blorp_release(list);
                if (custom_release_calls != 5) return 1;
                if (element_destructor_runs != 5) return 2;
                if (live_objects() != before) return 3;
                return 0;
            }
            """
        )

    def test_vector_of_heap_values_releases_each_element_once(self) -> None:
        self._assert_passes(
            """\
            static int custom_release_calls;
            static void custom_release(void* value) {
                custom_release_calls++;
                blorp_release(value);
            }
            int main(void) {
                long before = live_objects();
                void* shared = new_counted_element();
                blorp_Vector* vector = blorp_vector_new(3);
                vector->data[0] = new_counted_element();
                vector->data[1] = new_counted_element();
                vector->data[2] = blorp_retain(shared);
                blorp_vector_init_elem_release(vector, blorp_elem_release_fn);
                blorp_release(vector);
                if (element_destructor_runs != 2) return 1;
                if (refcount_of(shared) != 1) return 2;

                blorp_Vector* custom = blorp_vector_new(2);
                custom->data[0] = new_counted_element();
                custom->data[1] = shared;
                blorp_vector_init_elem_release(custom, custom_release);
                blorp_release(custom);
                if (custom_release_calls != 2) return 3;
                if (element_destructor_runs != 4) return 4;
                if (live_objects() != before) return 5;
                return 0;
            }
            """
        )

    def test_dict_and_set_of_heap_values_release_each_entry_once(self) -> None:
        self._assert_passes(
            """\
            static int custom_release_calls;
            static void custom_release(void* value) {
                custom_release_calls++;
                blorp_release(value);
            }
            int main(void) {
                long before = live_objects();
                void* shared = new_counted_element();
                blorp_Dict* dict = blorp_dict_new_custom(
                    blorp_dict_hash_int, blorp_dict_key_eq_int, blorp_elem_release_fn);
                blorp_dict_set_value_release(dict, blorp_elem_release_fn);
                for (int i = 0; i < 3; i++) {
                    void* key = new_counted_element();
                    void* value = new_counted_element();
                    dict = blorp_dict_insert(dict, key, value);
                    blorp_release(key);
                    blorp_release(value);
                }
                dict = blorp_dict_insert(dict, shared, shared);
                if (element_destructor_runs != 0) return 1;
                if (refcount_of(shared) != 3) return 2;
                blorp_release(dict);
                if (element_destructor_runs != 6) return 3;
                if (refcount_of(shared) != 1) return 4;

                blorp_Dict* custom_dict = blorp_dict_new_custom(
                    blorp_dict_hash_int, blorp_dict_key_eq_int, custom_release);
                blorp_dict_set_value_release(custom_dict, custom_release);
                custom_dict = blorp_dict_insert(custom_dict, shared, shared);
                blorp_release(custom_dict);
                if (custom_release_calls != 2) return 5;
                if (refcount_of(shared) != 1) return 6;

                blorp_Set* set = blorp_set_new_custom(
                    blorp_dict_hash_int, blorp_dict_key_eq_int, blorp_elem_release_fn);
                for (int i = 0; i < 3; i++) {
                    void* key = new_counted_element();
                    set = blorp_set_add(set, key);
                    blorp_release(key);
                }
                set = blorp_set_add(set, shared);
                blorp_release(set);
                if (element_destructor_runs != 9) return 7;
                if (refcount_of(shared) != 1) return 8;

                blorp_Set* custom_set = blorp_set_new_custom(
                    blorp_dict_hash_int, blorp_dict_key_eq_int, custom_release);
                custom_set = blorp_set_add(custom_set, shared);
                blorp_release(custom_set);
                if (custom_release_calls != 3) return 9;

                blorp_release(shared);
                if (element_destructor_runs != 10) return 10;
                if (live_objects() != before) return 11;
                return 0;
            }
            """
        )

    def test_unboxing_unique_result_moves_payload_reference(self) -> None:
        self._assert_passes(
            """\
            int main(void) {
                long before = live_objects();
                void* payload = new_counted_element();
                blorp_Result* ok = blorp_result_ok_with_release_mask(payload, true);
                blorp_StackResult unboxed = blorp_stack_result_from_boxed(ok);
                if (unboxed.tag != BLORP_TAG_OK) return 1;
                if (unboxed.release_mask != 1UL) return 2;
                if (unboxed.data.Ok.field0 != payload) return 3;
                if (refcount_of(payload) != 1) return 4;
                if (element_destructor_runs != 0) return 5;
                blorp_stack_result_release(unboxed);
                if (element_destructor_runs != 1) return 6;

                void* error = new_counted_element();
                blorp_Result* err = blorp_result_err_owned(error);
                blorp_StackResult unboxed_err = blorp_stack_result_from_boxed(err);
                if (unboxed_err.tag != BLORP_TAG_ERR) return 7;
                if (unboxed_err.data.Err.field0 != error) return 8;
                if (refcount_of(error) != 1) return 9;
                blorp_stack_result_release(unboxed_err);
                if (element_destructor_runs != 2) return 10;

                // A borrowed payload (release bit clear) is not owned by the
                // box, so unboxing must neither retain nor release it.
                void* borrowed = new_counted_element();
                blorp_Result* borrowed_ok = blorp_result_ok(borrowed);
                blorp_StackResult unboxed_borrowed = blorp_stack_result_from_boxed(borrowed_ok);
                if (unboxed_borrowed.release_mask != 0UL) return 11;
                if (refcount_of(borrowed) != 1) return 12;
                blorp_release(borrowed);
                if (element_destructor_runs != 3) return 13;

                // A box made by blorp_box_stack_result carries the same
                // payload ownership contract.
                void* boxed_payload = new_counted_element();
                blorp_StackResult source = {
                    .tag = BLORP_TAG_OK, .release_mask = 1UL,
                    .data.Ok.field0 = boxed_payload };
                void* box = blorp_box_stack_result(source);
                blorp_StackResult from_box = blorp_stack_result_from_boxed((blorp_Result*)box);
                if (from_box.data.Ok.field0 != boxed_payload) return 14;
                if (refcount_of(boxed_payload) != 1) return 15;
                blorp_stack_result_release(from_box);
                if (element_destructor_runs != 4) return 16;

                if (blorp_stack_result_from_boxed(NULL).tag != BLORP_TAG_ERR) return 17;
                if (live_objects() != before) return 18;
                return 0;
            }
            """
        )

    def test_unboxing_shared_result_leaves_box_owning_its_payload(self) -> None:
        self._assert_passes(
            """\
            int main(void) {
                long before = live_objects();
                void* payload = new_counted_element();
                blorp_Result* ok = blorp_result_ok_with_release_mask(payload, true);
                blorp_retain(ok);
                blorp_StackResult unboxed = blorp_stack_result_from_boxed(ok);
                if (refcount_of((void*)ok) != 1) return 1;
                if (refcount_of(payload) != 2) return 2;
                if (unboxed.data.Ok.field0 != payload) return 3;
                blorp_release(ok);
                if (refcount_of(payload) != 1) return 4;
                if (element_destructor_runs != 0) return 5;
                blorp_stack_result_release(unboxed);
                if (element_destructor_runs != 1) return 6;
                if (live_objects() != before) return 7;
                return 0;
            }
            """
        )


if __name__ == "__main__":
    unittest.main()
