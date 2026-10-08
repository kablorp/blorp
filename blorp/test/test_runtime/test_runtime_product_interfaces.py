#!/usr/bin/env python3
"""Native product interfaces transfer ownership without a generic tuple layout."""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]

HARNESS = r'''
#define _GNU_SOURCE
#define MINICORO_IMPL
#include "minicoro.h"
#include "runtime.c"

/* These stand in for generated record layouts, deliberately using typed fields
   whose offsets differ from the legacy tuple's generic slot array. */
typedef struct { blorp_Object header; long index; blorp_String* text; } IndexedText;
typedef struct { blorp_Object header; blorp_String* key; blorp_String* value; } Entry;
typedef struct { blorp_Object header; long kind; long code; blorp_Bytes* out; blorp_Bytes* err; } CommandOutput;
typedef struct { blorp_Object header; long kind; blorp_String* detail; } CommandError;
typedef struct { blorp_Object header; blorp_String* out; blorp_String* err; long code; } Output;
typedef struct { blorp_Object header; long first; long second; } Numbers;
static long products_destroyed;

static void indexed_destroy(void* object) {
    blorp_release(((IndexedText*)object)->text);
    products_destroyed++;
}
static void entry_destroy(void* object) {
    Entry* entry = object;
    blorp_release(entry->key);
    blorp_release(entry->value);
    products_destroyed++;
}
static void command_output_destroy(void* object) {
    CommandOutput* output = object;
    blorp_release(output->out);
    blorp_release(output->err);
    products_destroyed++;
}
static void command_error_destroy(void* object) {
    blorp_release(((CommandError*)object)->detail);
    products_destroyed++;
}
static void output_destroy(void* object) {
    Output* output = object;
    blorp_release(output->out);
    blorp_release(output->err);
    products_destroyed++;
}
static void* indexed_factory(long index, void* text) {
    IndexedText* product = blorp_alloc(sizeof(*product));
    product->index = index;
    product->text = text;
    blorp_retain(text);
    BLORP_INSTALL_DESTRUCTOR(product, indexed_destroy);
    return product;
}
static void* entry_factory(void* key, void* value) {
    Entry* product = blorp_alloc(sizeof(*product));
    product->key = key;
    product->value = value;
    blorp_retain(key);
    blorp_retain(value);
    BLORP_INSTALL_DESTRUCTOR(product, entry_destroy);
    return product;
}
static void* command_output_factory(long kind, long code, blorp_Bytes* out, blorp_Bytes* err) {
    CommandOutput* product = blorp_alloc(sizeof(*product));
    product->kind = kind;
    product->code = code;
    product->out = out;
    product->err = err;
    BLORP_INSTALL_DESTRUCTOR(product, command_output_destroy);
    return product;
}
static void* command_error_factory(long kind, blorp_String* detail) {
    CommandError* product = blorp_alloc(sizeof(*product));
    product->kind = kind;
    product->detail = detail;
    BLORP_INSTALL_DESTRUCTOR(product, command_error_destroy);
    return product;
}
static void* output_factory(blorp_String* out, blorp_String* err, long code) {
    Output* product = blorp_alloc(sizeof(*product));
    product->out = out;
    product->err = err;
    product->code = code;
    BLORP_INSTALL_DESTRUCTOR(product, output_destroy);
    return product;
}
static long references(void* object) {
    return atomic_load(&((blorp_Object*)object)->refcount);
}

static void numbers_destroy(void* object) {
    (void)object;
    products_destroyed++;
}
static void* vector_factory(const blorp_Vector* first, const blorp_Vector* second, long index) {
    Numbers* product = blorp_alloc(sizeof(*product));
    product->first = blorp_vector_read_i64(first, index);
    product->second = blorp_packed_get(second, index);
    BLORP_INSTALL_DESTRUCTOR(product, numbers_destroy);
    return product;
}
static void test_vector(void) {
    blorp_Vector* first = blorp_vector_new_i64(2);
    blorp_Vector* second = blorp_vector_new_packed(2, -1);
    blorp_vector_write_i64(first, 0, 17);
    blorp_vector_write_i64(first, 1, 29);
    blorp_packed_set(second, 0, 1);
    blorp_packed_set(second, 1, 0);
    blorp_Vector* pairs = blorp_vector_zip_product(first, second, vector_factory);
    Numbers* pair0 = pairs->data[0];
    Numbers* pair1 = pairs->data[1];
    assert(pair0->first == 17 && pair0->second == 1);
    assert(pair1->first == 29 && pair1->second == 0);
    blorp_release(first);
    blorp_release(second);
    blorp_release(pairs);
    assert(products_destroyed == 2);
}

static void test_dict(void) {
    blorp_String* key = blorp_string_create("key");
    blorp_String* value = blorp_string_create("value");
    blorp_Dict* dict = blorp_dict_new_string();
    dict->value_release = blorp_elem_release_fn;
    dict = blorp_dict_insert(dict, key, value);
    blorp_List* entries = blorp_dict_entries_product(dict, entry_factory);
    assert(entries->len == 1);
    Entry* entry = entries->data[0];
    assert(entry->key == key && entry->value == value);
    blorp_release(dict);
    assert(references(key) == 2 && references(value) == 2);
    blorp_release(entries);
    assert(references(key) == 1 && references(value) == 1);
    assert(products_destroyed == 1);
    blorp_release(key);
    blorp_release(value);
}

static bool owned_pull(blorp_Stream* self, void** out) {
    blorp_String* text = self->state;
    if (!text) return false;
    self->state = NULL;
    blorp_retain(text);
    *out = text;
    return true;
}
static void test_enumerate(bool owned) {
    blorp_String* text = blorp_string_create("retained");
    blorp_List* list = blorp_list_new(1);
    list->elem_release = blorp_elem_release_fn;
    list = blorp_list_append(list, text);
    blorp_Stream* input = owned ? blorp_stream_new() : blorp_stream_from_list(list);
    if (owned) {
        input->state = text;
        input->pull = owned_pull;
        input->elem_layout = BLORP_STREAM_ELEM_OWNED_ARC;
    }
    blorp_Stream* stream = blorp_stream_enumerate_product(input, indexed_factory);
    void* value = NULL;
    assert(stream->pull(stream, &value));
    IndexedText* pair = value;
    assert(pair->index == 0 && pair->text == text);
    assert(!stream->pull(stream, &value));
    blorp_release(stream);
    blorp_release(input);
    blorp_release(list);
    assert(references(text) == 2);
    blorp_release(pair);
    assert(references(text) == 1 && products_destroyed == 1);
    blorp_release(text);
}

static long unfold_calls;
static bool unfold_step(blorp_Closure* closure, void* state, void** value, void** next_state) {
    (void)closure;
    if (unfold_calls++) return false;
    /* One state can be both outputs; each returned slot owns a reference. */
    blorp_retain(state);
    blorp_retain(state);
    *value = state;
    *next_state = state;
    return true;
}
static void test_unfold(void) {
    blorp_String* seed = blorp_string_create("seed");
    blorp_Stream* stream = blorp_stream_unfold_product(
        seed, NULL, BLORP_STREAM_ELEM_OWNED_ARC,
        BLORP_STREAM_ELEM_OWNED_ARC, unfold_step);
    void* value = NULL;
    assert(stream->pull(stream, &value));
    assert(value == seed && references(seed) == 3);
    assert(!stream->pull(stream, &value));
    blorp_release(stream);
    assert(references(seed) == 2);
    blorp_release(value);
    assert(references(seed) == 1);
    blorp_release(seed);
}

static blorp_List* shell_args(void) {
    blorp_String* flag = blorp_string_create("-c");
    blorp_String* command = blorp_string_create("printf native");
    blorp_List* args = blorp_list_new(2);
    args->elem_release = blorp_elem_release_fn;
    args = blorp_list_append(args, flag);
    args = blorp_list_append(args, command);
    blorp_release(flag);
    blorp_release(command);
    return args;
}
static void test_process(void) {
    blorp_String* program = blorp_string_create("/bin/sh");
    blorp_List* args = shell_args();
    blorp_ProcessCommandOptions options = {
        .stdin_mode = BLORP_PROCESS_STDIN_NULL,
        .stdout_mode = BLORP_PROCESS_STREAM_CAPTURE,
        .stderr_mode = BLORP_PROCESS_STREAM_CAPTURE,
        .group_mode = BLORP_PROCESS_GROUP_NEW,
        .capture_limit = 4096
    };
    blorp_Result* result = blorp_process_run_command_product(
        program, args, &options, command_output_factory, command_error_factory);
    assert(result->tag == 0);
    CommandOutput* output = result->data.Ok.field0;
    assert(output->kind == BLORP_PROCESS_EXIT_EXITED && output->code == 0);
    assert(output->out->len == 6 && memcmp(output->out->data, "native", 6) == 0);
    assert(output->err->len == 0);
    blorp_release(result);
    blorp_String* empty = blorp_string_create("");
    result = blorp_process_run_command_product(
        empty, args, &options, command_output_factory, command_error_factory);
    assert(result->tag == 1);
    CommandError* error = result->data.Err.field0;
    assert(error->kind == BLORP_PROCESS_ERROR_INVALID_COMMAND);
    assert(error->detail->len > 0);
    blorp_release(result);
    blorp_release(empty);
    result = blorp_process_run_product(program, args, output_factory);
    assert(result->tag == 0);
    Output* legacy_api_output = result->data.Ok.field0;
    assert(legacy_api_output->out->len == 6 && legacy_api_output->code == 0);
    blorp_release(result);
    assert(products_destroyed == 3);
    blorp_release(program);
    blorp_release(args);
}

static long scoped_entry_exit(long mode, blorp_String* key,
                              blorp_String* value, Entry** retained) {
    for (long index = 0; index < 2; index++) {
        Entry* owner = entry_factory(key, value);
        blorp_ArcOwnerScope guard
            __attribute__((cleanup(blorp_arc_owner_scope_exit))) = { owner };
        Entry* borrowed = owner;
        assert(borrowed->key == key && borrowed->value == value);
        assert(references(key) == 2 && references(value) == 2);
        if (mode == 1) break;
        if (mode == 2) continue;
        if (mode == 3) return 7;
        if (mode == 4) {
            blorp_retain(borrowed);
            *retained = borrowed;
            return 9;
        }
    }
    return 5;
}

static void test_entry_scope_exits(void) {
    blorp_String* key = blorp_string_create("owned key");
    blorp_String* value = blorp_string_create("owned value");
    for (long mode = 0; mode < 5; mode++) {
        long destroyed_before = products_destroyed;
        Entry* retained = NULL;
        long score = scoped_entry_exit(mode, key, value, &retained);
        if (mode == 4) {
            assert(score == 9 && retained != NULL);
            assert(products_destroyed == destroyed_before);
            assert(references(key) == 2 && references(value) == 2);
            assert(retained->key == key && retained->value == value);
            blorp_release(retained);
        } else {
            assert(score == (mode == 3 ? 7 : 5));
        }
        long expected_destroyed = mode == 0 || mode == 2 ? 2 : 1;
        assert(products_destroyed == destroyed_before + expected_destroyed);
        assert(references(key) == 1 && references(value) == 1);
    }
    blorp_release(key);
    blorp_release(value);
}

int main(int argc, char** argv) {
    assert(argc == 2);
    blorp_MemStats before = blorp_get_mem_stats();
    assert(before.memory_stats_active == 1);
    if (strcmp(argv[1], "dict") == 0) test_dict();
    else if (strcmp(argv[1], "vector") == 0) test_vector();
    else if (strcmp(argv[1], "borrowed") == 0) test_enumerate(false);
    else if (strcmp(argv[1], "owned") == 0) test_enumerate(true);
    else if (strcmp(argv[1], "unfold") == 0) test_unfold();
    else if (strcmp(argv[1], "process") == 0) test_process();
    else if (strcmp(argv[1], "scope") == 0) test_entry_scope_exits();
    else assert(false);
    blorp_MemStats after = blorp_get_mem_stats();
    assert(after.memory_stats_active == 1);
    assert(after.total_allocations > before.total_allocations);
    if (after.current_objects != before.current_objects ||
        after.total_allocations - before.total_allocations !=
            after.total_releases - before.total_releases) {
        fprintf(stderr, "%s leaked managed objects: live %ld -> %ld, allocated %ld, released %ld\n",
            argv[1], before.current_objects, after.current_objects,
            after.total_allocations - before.total_allocations,
            after.total_releases - before.total_releases);
        return 1;
    }
    return 0;
}
'''


class RuntimeProductInterfaceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.directory = tempfile.TemporaryDirectory()
        cls.executable = Path(cls.directory.name) / "product-interfaces"
        compiled = subprocess.run(
            [os.environ.get("CC", "cc"), "-std=gnu11", "-O1", "-w",
             "-DBLORP_MEMORY_DIAGNOSTICS=1",
             f"-I{ROOT / 'blorp/src/lib/runtime/native'}", "-x", "c", "-",
             "-lm", "-lpthread", "-o", str(cls.executable)],
            cwd=ROOT, input=HARNESS, text=True, capture_output=True, check=False,
        )
        if compiled.returncode:
            cls.directory.cleanup()
            raise AssertionError(compiled.stderr)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.directory.cleanup()

    def check_contract(self, case: str) -> None:
        environment = dict(os.environ)
        environment["BLORP_MEMORY_STATS"] = "1"
        run = subprocess.run([str(self.executable), case], cwd=ROOT,
                             env=environment, text=True,
                             capture_output=True, check=False)
        self.assertEqual(run.returncode, 0, run.stderr)

    def test_dictionary_factory_retains_borrowed_fields(self) -> None:
        self.check_contract("dict")

    def test_vector_factory_reads_actual_input_storage(self) -> None:
        self.check_contract("vector")

    def test_enumeration_retains_borrowed_input(self) -> None:
        self.check_contract("borrowed")

    def test_enumeration_releases_owned_pull_after_factory(self) -> None:
        self.check_contract("owned")

    def test_unfold_transfers_both_owned_outputs(self) -> None:
        self.check_contract("unfold")

    def test_process_factories_consume_owned_payload_fields(self) -> None:
        self.check_contract("process")

    def test_entry_scope_releases_on_normal_and_early_exits(self) -> None:
        self.check_contract("scope")


if __name__ == "__main__":
    unittest.main()
