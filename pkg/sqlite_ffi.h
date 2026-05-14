// sqlite_ffi.h - SQLite3 wrapper for blorp FFI
// Provides: open, close, execute, query
// Requires: -lsqlite3
// Note: String params auto-convert to char* by blorp FFI codegen.

#ifndef BLORP_SQLITE_FFI_H
#define BLORP_SQLITE_FFI_H

#include <sqlite3.h>
#include <string.h>
#include <stdlib.h>

// Forward declarations from blorp runtime
extern blorp_Result* blorp_result_ok(void* value);
extern blorp_Result* blorp_result_err(void* value);
extern blorp_String* blorp_string_create(const char* cstr);
extern blorp_List* blorp_list_new(long initial_capacity);
extern blorp_List* blorp_list_append(blorp_List* list, void* element);
extern void blorp_list_init_elem_release(blorp_List* list, void (*release_fn)(void*));
extern void blorp_elem_release_fn(void* p);
extern void* blorp_retain(void* obj);
extern void blorp_release(void* obj);

// Helper: create a Result with release_mask set for RC inner values
static inline blorp_Result* sqlite_result_ok(void* value) {
    blorp_Result* r = blorp_result_ok(value);
    r->release_mask = 1UL;
    return r;
}

static inline blorp_Result* sqlite_result_err(const char* msg) {
    blorp_Result* r = blorp_result_err((void*)blorp_string_create(msg));
    r->release_mask = 1UL;
    return r;
}

// open(path) -> Result[Ptr, String]
// Note: path is char* (auto-converted from String by FFI codegen)
static inline blorp_Result* blorp_sqlite_open(const char* path) {
    sqlite3* db = NULL;
    int rc = sqlite3_open(path, &db);
    if (rc != SQLITE_OK) {
        const char* err = sqlite3_errmsg(db);
        blorp_Result* result = sqlite_result_err(err);
        sqlite3_close(db);
        return result;
    }
    // Return raw pointer (not RC-managed)
    blorp_Result* result = blorp_result_ok((void*)db);
    // Don't set release_mask — Ptr is not RC
    return result;
}

// close(db) -> Void
static inline void blorp_sqlite_close(void* db) {
    if (db) sqlite3_close((sqlite3*)db);
}

// execute(db, sql) -> Result[Void, String]
static inline blorp_Result* blorp_sqlite_exec(void* db, const char* sql) {
    char* err_msg = NULL;
    int rc = sqlite3_exec((sqlite3*)db, sql, NULL, NULL, &err_msg);
    if (rc != SQLITE_OK) {
        blorp_Result* result = sqlite_result_err(err_msg ? err_msg : "SQL error");
        if (err_msg) sqlite3_free(err_msg);
        return result;
    }
    return blorp_result_ok(NULL);
}

// query(db, sql) -> Result[List[List[String]], String]
static inline blorp_Result* blorp_sqlite_query(void* db, const char* sql) {
    sqlite3_stmt* stmt = NULL;
    int rc = sqlite3_prepare_v2((sqlite3*)db, sql, -1, &stmt, NULL);
    if (rc != SQLITE_OK) {
        return sqlite_result_err(sqlite3_errmsg((sqlite3*)db));
    }

    int ncols = sqlite3_column_count(stmt);
    blorp_List* rows = blorp_list_new(16);
    blorp_list_init_elem_release(rows, blorp_elem_release_fn);

    while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
        blorp_List* row = blorp_list_new(ncols);
        blorp_list_init_elem_release(row, blorp_elem_release_fn);
        for (int i = 0; i < ncols; i++) {
            const char* val = (const char*)sqlite3_column_text(stmt, i);
            blorp_String* s = blorp_string_create(val ? val : "");
            row = blorp_list_append(row, s);
            blorp_release(s);  // list_append retains
        }
        rows = blorp_list_append(rows, row);
        blorp_release(row);  // list_append retains
    }

    sqlite3_finalize(stmt);

    if (rc != SQLITE_DONE) {
        blorp_release(rows);
        return sqlite_result_err(sqlite3_errmsg((sqlite3*)db));
    }

    return sqlite_result_ok((void*)rows);
}

// query_columns(db, sql) -> Result[List[String], String]
static inline blorp_Result* blorp_sqlite_columns(void* db, const char* sql) {
    sqlite3_stmt* stmt = NULL;
    int rc = sqlite3_prepare_v2((sqlite3*)db, sql, -1, &stmt, NULL);
    if (rc != SQLITE_OK) {
        return sqlite_result_err(sqlite3_errmsg((sqlite3*)db));
    }

    int ncols = sqlite3_column_count(stmt);
    blorp_List* names = blorp_list_new(ncols);
    blorp_list_init_elem_release(names, blorp_elem_release_fn);
    for (int i = 0; i < ncols; i++) {
        const char* name = sqlite3_column_name(stmt, i);
        blorp_String* s = blorp_string_create(name ? name : "");
        names = blorp_list_append(names, s);
        blorp_release(s);
    }

    sqlite3_finalize(stmt);
    return sqlite_result_ok((void*)names);
}

// execute_params(db, sql, params) -> Result[Void, String]
// Note: params is blorp_List* (not auto-converted by FFI codegen)
static inline blorp_Result* blorp_sqlite_exec_params(void* db, const char* sql, blorp_List* params) {
    sqlite3_stmt* stmt = NULL;
    int rc = sqlite3_prepare_v2((sqlite3*)db, sql, -1, &stmt, NULL);
    if (rc != SQLITE_OK) {
        return sqlite_result_err(sqlite3_errmsg((sqlite3*)db));
    }

    // Bind parameters (1-indexed in SQLite)
    for (long i = 0; i < params->len; i++) {
        blorp_String* val = (blorp_String*)params->data[i];
        rc = sqlite3_bind_text(stmt, (int)(i + 1), val->data, (int)val->len, SQLITE_TRANSIENT);
        if (rc != SQLITE_OK) {
            sqlite3_finalize(stmt);
            return sqlite_result_err(sqlite3_errmsg((sqlite3*)db));
        }
    }

    rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);

    if (rc != SQLITE_DONE && rc != SQLITE_ROW) {
        return sqlite_result_err(sqlite3_errmsg((sqlite3*)db));
    }

    return blorp_result_ok(NULL);
}

// query_params(db, sql, params) -> Result[List[List[String]], String]
static inline blorp_Result* blorp_sqlite_query_params(void* db, const char* sql, blorp_List* params) {
    sqlite3_stmt* stmt = NULL;
    int rc = sqlite3_prepare_v2((sqlite3*)db, sql, -1, &stmt, NULL);
    if (rc != SQLITE_OK) {
        return sqlite_result_err(sqlite3_errmsg((sqlite3*)db));
    }

    // Bind parameters
    for (long i = 0; i < params->len; i++) {
        blorp_String* val = (blorp_String*)params->data[i];
        rc = sqlite3_bind_text(stmt, (int)(i + 1), val->data, (int)val->len, SQLITE_TRANSIENT);
        if (rc != SQLITE_OK) {
            sqlite3_finalize(stmt);
            return sqlite_result_err(sqlite3_errmsg((sqlite3*)db));
        }
    }

    int ncols = sqlite3_column_count(stmt);
    blorp_List* rows = blorp_list_new(16);
    blorp_list_init_elem_release(rows, blorp_elem_release_fn);

    while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
        blorp_List* row = blorp_list_new(ncols);
        blorp_list_init_elem_release(row, blorp_elem_release_fn);
        for (int i = 0; i < ncols; i++) {
            const char* val = (const char*)sqlite3_column_text(stmt, i);
            blorp_String* s = blorp_string_create(val ? val : "");
            row = blorp_list_append(row, s);
            blorp_release(s);
        }
        rows = blorp_list_append(rows, row);
        blorp_release(row);
    }

    sqlite3_finalize(stmt);

    if (rc != SQLITE_DONE) {
        blorp_release(rows);
        return sqlite_result_err(sqlite3_errmsg((sqlite3*)db));
    }

    return sqlite_result_ok((void*)rows);
}

#endif // BLORP_SQLITE_FFI_H
