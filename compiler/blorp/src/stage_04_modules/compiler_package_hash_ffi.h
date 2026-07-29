#ifndef BLORP_COMPILER_PACKAGE_HASH_FFI_H
#define BLORP_COMPILER_PACKAGE_HASH_FFI_H

#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#if defined(_WIN32)
#include <windows.h>
#endif

extern blorp_String* blorp_string_create(const char* cstr);

static inline int blorp_compiler_package_is_windows(void) {
#if defined(_WIN32)
    return 1;
#else
    return 0;
#endif
}

#if defined(_WIN32)
static inline char* blorp_compiler_package_windows_final_path(
    const char* path
) {
    int path_size = MultiByteToWideChar(
        CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0
    );
    if (path_size <= 0) return NULL;

    wchar_t* wide_path = (wchar_t*)malloc((size_t)path_size * sizeof(wchar_t));
    if (!wide_path) return NULL;
    if (MultiByteToWideChar(
            CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide_path, path_size
        ) <= 0) {
        free(wide_path);
        return NULL;
    }

    HANDLE handle = CreateFileW(
        wide_path,
        0,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL,
        OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS,
        NULL
    );
    free(wide_path);
    if (handle == INVALID_HANDLE_VALUE) return NULL;

    DWORD final_size = GetFinalPathNameByHandleW(
        handle, NULL, 0, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS
    );
    if (final_size == 0) {
        CloseHandle(handle);
        return NULL;
    }

    wchar_t* wide_final =
        (wchar_t*)malloc(((size_t)final_size + 1) * sizeof(wchar_t));
    if (!wide_final) {
        CloseHandle(handle);
        return NULL;
    }

    DWORD written = GetFinalPathNameByHandleW(
        handle,
        wide_final,
        final_size + 1,
        FILE_NAME_NORMALIZED | VOLUME_NAME_DOS
    );
    CloseHandle(handle);
    if (written == 0 || written > final_size) {
        free(wide_final);
        return NULL;
    }

    int utf8_size = WideCharToMultiByte(
        CP_UTF8, WC_ERR_INVALID_CHARS, wide_final, -1, NULL, 0, NULL, NULL
    );
    char* result = NULL;
    if (utf8_size > 0) {
        result = (char*)malloc((size_t)utf8_size);
        if (result &&
            WideCharToMultiByte(
                CP_UTF8,
                WC_ERR_INVALID_CHARS,
                wide_final,
                -1,
                result,
                utf8_size,
                NULL,
                NULL
            ) <= 0) {
            free(result);
            result = NULL;
        }
    }

    free(wide_final);
    return result;
}
#endif

/*
 * Return an owned Blorp string so the temporary platform allocation can be
 * released before crossing the FFI boundary. An empty result tells Blorp to
 * retain the lexical absolute path, matching the OCaml best-effort fallback.
 */
static inline blorp_String* blorp_compiler_package_realpath(const char* path) {
    char* resolved = NULL;

    if (path) {
#if defined(_WIN32)
        resolved = blorp_compiler_package_windows_final_path(path);
#else
        resolved = realpath(path, NULL);
#endif
    }

    blorp_String* result = blorp_string_create(resolved ? resolved : "");
    free(resolved);
    return result;
}

#endif
