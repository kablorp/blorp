#ifndef BLORP_COMPILER_BRIDGE_BOOTSTRAP_COMPAT_H
#define BLORP_COMPILER_BRIDGE_BOOTSTRAP_COMPAT_H

/*
 * The pinned bootstrap compiler still emits this retired string-literal
 * comparison helper. Keep the compatibility implementation confined to
 * bootstrap-built bridge helpers instead of restoring it to the runtime ABI.
 */
static inline bool blorp_string_eq_cstr(
    const blorp_String* string,
    const char* literal
) {
    if (!string && (!literal || literal[0] == '\0')) return true;
    if (!string || !literal) return false;
    size_t literal_length = strlen(literal);
    return string->len == (long)literal_length
        && memcmp(string->data, literal, literal_length) == 0;
}

#endif
