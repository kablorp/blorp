#include "aggregate_runtime_test.h"

static void test_valid_argv(void) {
    char executable[] = "compiler";
    char empty[] = "";
    char multilingual[] = {'e', (char)0xc3, (char)0xa9,
                           (char)0xf0, (char)0x9f, (char)0x98, (char)0x80, '\0'};
    char *arguments[] = {executable, empty, multilingual};
    struct blorp_l_0_s *result = blorp_list_from_argv(3, arguments);
    assert(result != NULL);
    assert(result->length == 3);
    assert(atomic_load(&result->references) == 1);
    assert_text(result->values[0], executable, (int64_t)strlen(executable));
    assert_text(result->values[1], empty, 0);
    assert_text(result->values[2], multilingual, (int64_t)sizeof multilingual - 1);
    for (size_t index = 0; index < 3; index += 1) {
        assert(atomic_load(&result->values[index]->references) == 1);
    }
    assert(allocation_count == 4 && destruction_count == 0);
    blorp_list_drop_0_s(result);
    assert(destruction_count == 4);
    for (size_t id = 0; id < allocation_count; id += 1) assert_frees(id, 1);
}

static void test_invalid_argv(size_t invalid_index, const char *invalid_bytes) {
    char executable[] = "compiler";
    char empty[] = "";
    char text[] = "source.brp";
    /* Raw native bytes, never a fabricated malformed language String. */
    enum { ARGV_TEST_BUFFER_CAPACITY = 16 };
    char invalid[ARGV_TEST_BUFFER_CAPACITY];
    const size_t length = strlen(invalid_bytes);
    assert(length < sizeof invalid);
    memcpy(invalid, invalid_bytes, length + 1);
    char *arguments[] = {executable, empty, text};
    assert(invalid_index < 3);
    arguments[invalid_index] = invalid;
    struct blorp_l_0_s *result = blorp_list_from_argv(3, arguments);
    assert(result == NULL);
    assert(memcmp(invalid, invalid_bytes, length + 1) == 0);
    /* One list root and exactly the Strings before the rejected argument. */
    assert(allocation_count == invalid_index + 1);
    assert(destruction_count == invalid_index + 1);
    for (size_t id = 0; id < allocation_count; id += 1) assert_frees(id, 1);
}

static void test_empty_argv(void) {
    struct blorp_l_0_s *result = blorp_list_from_argv(0, NULL);
    assert(result != NULL && result->length == 0);
    assert(allocation_count == 1 && destruction_count == 0);
    blorp_list_drop_0_s(result);
    assert_frees(0, 1);
}

static void test_argv_escape(void) {
    char text[] = "\xef\xbf\xbf"; /* U+FFFF is a valid noncharacter. */
    char *arguments[] = {text};
    struct blorp_l_0_s *root = blorp_list_from_argv(1, arguments);
    assert(root != NULL);
    struct blorp_string *escaped = NULL;
    assert(blorp_list_get_0_s(root, 0, &escaped) == 1);
    assert(allocation_count == 2 && destruction_count == 0);
    blorp_list_drop_0_s(root);
    assert_frees(0, 1);
    assert_frees(1, 0);
    assert_text(escaped, text, 3);
    assert(atomic_load(&escaped->references) == 1);
    blorp_string_release(escaped);
    assert_frees(1, 1);
}

static void assert_utf8(const char *bytes, size_t length, uint8_t expected) {
    enum { UTF8_TEST_BUFFER_CAPACITY = 128 };
    char original[UTF8_TEST_BUFFER_CAPACITY];
    assert(length <= sizeof original);
    memcpy(original, bytes, length);
    const size_t allocations_before = allocation_count;
    const size_t destructions_before = destruction_count;
    assert(blorp_utf8_is_valid(bytes, length) == expected);
    assert(memcmp(bytes, original, length) == 0);
    assert(allocation_count == allocations_before);
    assert(destruction_count == destructions_before);
}

static void test_utf8_ascii(void) {
    char bytes[128];
    for (size_t index = 0; index < sizeof bytes; index += 1) bytes[index] = (char)index;
    assert_utf8(bytes, sizeof bytes, 1);
}

static void test_utf8_scalar_boundaries(void) {
    static const char bytes[] =
        "\xc2\x80\xdf\xbf\xe0\xa0\x80\xed\x9f\xbf\xee\x80\x80\xef\xbf\xbf"
        "\xf0\x90\x80\x80\xf4\x8f\xbf\xbf";
    assert_utf8(bytes, sizeof bytes - 1, 1);
}

static void test_utf8_noncharacters(void) {
    static const char bytes[] =
        "\xef\xb7\x90\xef\xb7\xaf\xef\xbf\xbe\xef\xbf\xbf"
        "\xf4\x8f\xbf\xbe\xf4\x8f\xbf\xbf";
    assert_utf8(bytes, sizeof bytes - 1, 1);
}

static void test_utf8_forbidden_leads(void) {
    for (unsigned int lead = 0xf5; lead <= 0xff; lead += 1) {
        const char bytes[] = {(char)lead, (char)0x80, (char)0x80, (char)0x80};
        assert_utf8(bytes, sizeof bytes, 0);
    }
    /* Rehome both former malformed String equality inputs at admission. */
    assert_utf8("\xff\x80x", 3, 0);
    assert_utf8("\xff\x81x", 3, 0);
}

static void test_utf8_truncated_two(void) {
    const char bytes[] = {(char)0xc2};
    assert_utf8(bytes, sizeof bytes, 0);
}

static void test_utf8_truncated_three(void) {
    const char first[] = {(char)0xe2};
    const char second[] = {(char)0xe2, (char)0x82};
    assert_utf8(first, sizeof first, 0);
    assert_utf8(second, sizeof second, 0);
}

static void test_utf8_truncated_four(void) {
    const char first[] = {(char)0xf0};
    const char second[] = {(char)0xf0, (char)0x90};
    const char third[] = {(char)0xf0, (char)0x90, (char)0x80};
    assert_utf8(first, sizeof first, 0);
    assert_utf8(second, sizeof second, 0);
    assert_utf8(third, sizeof third, 0);
}

static void test_utf8_bad_continuations(void) {
    assert_utf8("\xc2\x7f", 2, 0);
    assert_utf8("\xc2\xc0", 2, 0);
    assert_utf8("\xe2\x28\xa1", 3, 0);
    assert_utf8("\xe2\x82\x41", 3, 0);
    assert_utf8("\xf0\x90\xff\x80", 4, 0);
    assert_utf8("\xf0\x90\x80\x41", 4, 0);
}

int main(int argc, char **argv) {
    assert(argc == 2);
    if (strcmp(argv[1], "valid") == 0) test_valid_argv();
    else if (strcmp(argv[1], "empty_argv") == 0) test_empty_argv();
    else if (strcmp(argv[1], "argv_escape") == 0) test_argv_escape();
    else if (strcmp(argv[1], "invalid_first") == 0) test_invalid_argv(0, "\xc0\x80");
    else if (strcmp(argv[1], "invalid_middle") == 0) test_invalid_argv(1, "\xc0\x80");
    else if (strcmp(argv[1], "invalid_last") == 0) test_invalid_argv(2, "\xc0\x80");
    else if (strcmp(argv[1], "argv_continuation") == 0) test_invalid_argv(1, "\x80");
    else if (strcmp(argv[1], "argv_truncated") == 0) test_invalid_argv(1, "\xf0\x90\x80");
    else if (strcmp(argv[1], "argv_overlong") == 0) test_invalid_argv(1, "\xe0\x9f\xbf");
    else if (strcmp(argv[1], "argv_surrogate") == 0) test_invalid_argv(1, "\xed\xa0\x80");
    else if (strcmp(argv[1], "argv_above_max") == 0) test_invalid_argv(1, "\xf4\x90\x80\x80");
    else if (strcmp(argv[1], "argv_bad_suffix") == 0) test_invalid_argv(1, "a\xc3\xa9\xff");
    else if (strcmp(argv[1], "utf8_empty") == 0) assert_utf8("", 0, 1);
    else if (strcmp(argv[1], "utf8_ascii") == 0) test_utf8_ascii();
    else if (strcmp(argv[1], "utf8_multilingual") == 0) assert_utf8("\xc3\xa9\xe6\x97\xa5\xf0\x9f\x98\x80", 9, 1);
    else if (strcmp(argv[1], "utf8_decomposed") == 0) assert_utf8("e\xcc\x81", 3, 1);
    else if (strcmp(argv[1], "utf8_boundaries") == 0) test_utf8_scalar_boundaries();
    else if (strcmp(argv[1], "utf8_noncharacters") == 0) test_utf8_noncharacters();
    else if (strcmp(argv[1], "utf8_unassigned") == 0) assert_utf8("\xcd\xb8", 2, 1);
    else if (strcmp(argv[1], "utf8_nul") == 0) assert_utf8("a\0\xc3\xa9z", 5, 1);
    else if (strcmp(argv[1], "utf8_after_nul") == 0) assert_utf8("a\0\xff", 3, 0);
    else if (strcmp(argv[1], "utf8_isolated") == 0) {
        assert_utf8("\x80", 1, 0);
        assert_utf8("\xbf", 1, 0);
    } else if (strcmp(argv[1], "utf8_forbidden_leads") == 0) test_utf8_forbidden_leads();
    else if (strcmp(argv[1], "utf8_overlong_two") == 0) {
        assert_utf8("\xc0\x80", 2, 0);
        assert_utf8("\xc1\xbf", 2, 0);
    } else if (strcmp(argv[1], "utf8_overlong_three") == 0) {
        assert_utf8("\xe0\x80\x80", 3, 0);
        assert_utf8("\xe0\x9f\xbf", 3, 0);
    } else if (strcmp(argv[1], "utf8_overlong_four") == 0) {
        assert_utf8("\xf0\x80\x80\x80", 4, 0);
        assert_utf8("\xf0\x8f\xbf\xbf", 4, 0);
    } else if (strcmp(argv[1], "utf8_surrogates") == 0) {
        assert_utf8("\xed\xa0\x80", 3, 0);
        assert_utf8("\xed\xbf\xbf", 3, 0);
    } else if (strcmp(argv[1], "utf8_above_max") == 0) {
        assert_utf8("\xf4\x90\x80\x80", 4, 0);
        assert_utf8("\xf4\xbf\xbf\xbf", 4, 0);
    } else if (strcmp(argv[1], "utf8_truncated_two") == 0) test_utf8_truncated_two();
    else if (strcmp(argv[1], "utf8_truncated_three") == 0) test_utf8_truncated_three();
    else if (strcmp(argv[1], "utf8_truncated_four") == 0) test_utf8_truncated_four();
    else if (strcmp(argv[1], "utf8_continuations") == 0) test_utf8_bad_continuations();
    else if (strcmp(argv[1], "utf8_bad_suffix") == 0) assert_utf8("a\xc3\xa9\xff", 4, 0);
    else assert(0 && "unknown argv runtime case");
    assert(allocation_count == destruction_count);
    return 0;
}
