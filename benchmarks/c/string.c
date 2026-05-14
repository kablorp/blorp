#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ITERS 100000

static const char *test_string =
    "The quick brown fox jumps over the lazy dog. "
    "This is a test string for benchmarking purposes.";

static const char *chain_string =
    "   The quick brown fox jumps over the lazy dog. "
    "This is a test string for benchmarking purposes.   ";

static inline void black_box_ptr(const void *ptr) {
#if defined(__clang__) || defined(__GNUC__)
    __asm__ __volatile__("" : : "r"(ptr) : "memory");
#else
    (void)ptr;
#endif
}

static char *copy_range(const char *s, int start, int len) {
    char *buf = malloc((size_t)len + 1);
    memcpy(buf, s + start, (size_t)len);
    buf[len] = '\0';
    return buf;
}

static char *replace_copy(const char *s, const char *old, const char *new_value) {
    int slen = (int)strlen(s);
    int olen = (int)strlen(old);
    int nlen = (int)strlen(new_value);
    char *buf = malloc((size_t)slen * 4 + 1);
    char *out = buf;
    const char *p = s;
    const char *found;
    while ((found = strstr(p, old)) != NULL) {
        int chunk = (int)(found - p);
        memcpy(out, p, (size_t)chunk);
        out += chunk;
        memcpy(out, new_value, (size_t)nlen);
        out += nlen;
        p = found + olen;
    }
    int remaining = (int)strlen(p);
    memcpy(out, p, (size_t)remaining + 1);
    return buf;
}

static char *upper_copy(const char *s) {
    int slen = (int)strlen(s);
    char *buf = malloc((size_t)slen + 1);
    for (int j = 0; j < slen; j++) {
        char c = s[j];
        buf[j] = (c >= 'a' && c <= 'z') ? (char)(c - ('a' - 'A')) : c;
    }
    buf[slen] = '\0';
    return buf;
}

static char *lower_copy(const char *s) {
    int slen = (int)strlen(s);
    char *buf = malloc((size_t)slen + 1);
    for (int j = 0; j < slen; j++) {
        char c = s[j];
        buf[j] = (c >= 'A' && c <= 'Z') ? (char)(c + ('a' - 'A')) : c;
    }
    buf[slen] = '\0';
    return buf;
}

static char *reverse_copy(const char *s) {
    int slen = (int)strlen(s);
    char *buf = malloc((size_t)slen + 1);
    for (int j = 0; j < slen; j++) {
        buf[j] = s[slen - 1 - j];
    }
    buf[slen] = '\0';
    return buf;
}

static char *trim_copy(const char *s) {
    int slen = (int)strlen(s);
    int start = 0, end = slen - 1;
    while (start < slen && s[start] == ' ') start++;
    while (end >= start && s[end] == ' ') end--;
    int len = end - start + 1;
    char *trimmed = malloc((size_t)len + 1);
    memcpy(trimmed, s + start, (size_t)len);
    trimmed[len] = '\0';
    return trimmed;
}

__attribute__((noinline))
static long bench_count(const char *s, const char *needle, int iters) {
    long total = 0;
    int nlen = (int)strlen(needle);
    for (int i = 0; i < iters; i++) {
        black_box_ptr(s);
        const char *p = s;
        while ((p = strstr(p, needle)) != NULL) {
            total++;
            p += nlen;
        }
    }
    return total;
}

__attribute__((noinline))
static long bench_contains(const char *s, const char *needle, int iters) {
    long total = 0;
    for (int i = 0; i < iters; i++) {
        black_box_ptr(s);
        if (strstr(s, needle) != NULL) total++;
    }
    return total;
}

__attribute__((noinline))
static long bench_replace(const char *s, const char *old, const char *new_value, int iters) {
    int slen = (int)strlen(s);
    int olen = (int)strlen(old);
    int nlen = (int)strlen(new_value);
    long total = 0;
    for (int i = 0; i < iters; i++) {
        black_box_ptr(s);
        char *buf = malloc((size_t)slen * 4 + 1);
        char *out = buf;
        const char *p = s;
        const char *found;
        while ((found = strstr(p, old)) != NULL) {
            int chunk = (int)(found - p);
            memcpy(out, p, (size_t)chunk);
            out += chunk;
            memcpy(out, new_value, (size_t)nlen);
            out += nlen;
            p = found + olen;
        }
        int remaining = (int)strlen(p);
        memcpy(out, p, (size_t)remaining + 1);
        out += remaining;
        total += out - buf;
        free(buf);
    }
    return total;
}

__attribute__((noinline))
static long bench_substring(const char *s, int iters) {
    long total = 0;
    for (int i = 0; i < iters; i++) {
        int start = i % 16;
        int len = 24;
        black_box_ptr(s);
        char *buf = malloc((size_t)len + 1);
        memcpy(buf, s + start, (size_t)len);
        buf[len] = '\0';
        total += strlen(buf);
        free(buf);
    }
    return total;
}

__attribute__((noinline))
static long bench_split(const char *s, const char *delim, int iters) {
    long total = 0;
    int dlen = (int)strlen(delim);
    for (int i = 0; i < iters; i++) {
        black_box_ptr(s);
        int count = 0;
        int capacity = 16;
        char **parts = malloc((size_t)capacity * sizeof(char *));
        const char *p = s;
        const char *found;
        while ((found = strstr(p, delim)) != NULL) {
            if (count == capacity) {
                capacity *= 2;
                parts = realloc(parts, (size_t)capacity * sizeof(char *));
            }
            int len = (int)(found - p);
            char *part = malloc((size_t)len + 1);
            memcpy(part, p, (size_t)len);
            part[len] = '\0';
            parts[count++] = part;
            p = found + dlen;
        }
        if (count == capacity) {
            capacity *= 2;
            parts = realloc(parts, (size_t)capacity * sizeof(char *));
        }
        int len = (int)strlen(p);
        char *part = malloc((size_t)len + 1);
        memcpy(part, p, (size_t)len + 1);
        parts[count++] = part;
        total += count;
        for (int j = 0; j < count; j++) free(parts[j]);
        free(parts);
    }
    return total;
}

__attribute__((noinline))
static long bench_upper(const char *s, int iters) {
    int slen = (int)strlen(s);
    long total = 0;
    for (int i = 0; i < iters; i++) {
        black_box_ptr(s);
        char *buf = malloc((size_t)slen + 1);
        for (int j = 0; j < slen; j++) {
            char c = s[j];
            buf[j] = (c >= 'a' && c <= 'z') ? (char)(c - ('a' - 'A')) : c;
        }
        buf[slen] = '\0';
        total += strlen(buf);
        free(buf);
    }
    return total;
}

__attribute__((noinline))
static long bench_lower(const char *s, int iters) {
    int slen = (int)strlen(s);
    long total = 0;
    for (int i = 0; i < iters; i++) {
        black_box_ptr(s);
        char *buf = malloc((size_t)slen + 1);
        for (int j = 0; j < slen; j++) {
            char c = s[j];
            buf[j] = (c >= 'A' && c <= 'Z') ? (char)(c + ('a' - 'A')) : c;
        }
        buf[slen] = '\0';
        total += strlen(buf);
        free(buf);
    }
    return total;
}

__attribute__((noinline))
static long bench_reverse(const char *s, int iters) {
    int slen = (int)strlen(s);
    long total = 0;
    for (int i = 0; i < iters; i++) {
        black_box_ptr(s);
        char *buf = malloc((size_t)slen + 1);
        for (int j = 0; j < slen; j++) {
            buf[j] = s[slen - 1 - j];
        }
        buf[slen] = '\0';
        total += strlen(buf);
        free(buf);
    }
    return total;
}

__attribute__((noinline))
static long bench_trim(int iters) {
    const char *padded = "   hello world   ";
    long total = 0;
    for (int i = 0; i < iters; i++) {
        black_box_ptr(padded);
        char *trimmed = trim_copy(padded);
        total += strlen(trimmed);
        free(trimmed);
    }
    return total;
}

__attribute__((noinline))
static long bench_chain_window_replace(const char *s, int iters) {
    long total = 0;
    for (int i = 0; i < iters; i++) {
        int start = i % 16;
        black_box_ptr(s);
        char *trimmed_source = trim_copy(s);
        char *window = copy_range(trimmed_source, start, 40);
        char *replaced = replace_copy(window, " ", "_");
        total += strlen(replaced);
        free(replaced);
        free(window);
        free(trimmed_source);
    }
    return total;
}

__attribute__((noinline))
static long bench_chain_case_replace(const char *s, int iters) {
    long total = 0;
    for (int i = 0; i < iters; i++) {
        black_box_ptr(s);
        char *lowered = lower_copy(s);
        char *replaced = replace_copy(lowered, "the", "a");
        char *uppered = upper_copy(replaced);
        total += strlen(uppered);
        free(uppered);
        free(replaced);
        free(lowered);
    }
    return total;
}

__attribute__((noinline))
static long bench_chain_trim_reverse(int iters) {
    const char *padded = "   hello world   ";
    long total = 0;
    for (int i = 0; i < iters; i++) {
        black_box_ptr(padded);
        char *trimmed = trim_copy(padded);
        char *reversed = reverse_copy(trimmed);
        char *replaced = replace_copy(reversed, "l", "L");
        total += strlen(replaced);
        free(replaced);
        free(reversed);
        free(trimmed);
    }
    return total;
}

int main(void) {
    printf("count checksum: %ld\n", bench_count(test_string, "e", ITERS));
    printf("contains checksum: %ld\n", bench_contains(test_string, "fox", ITERS));
    printf("replace_same checksum: %ld\n", bench_replace(test_string, "the", "THE", ITERS));
    printf("replace_grow checksum: %ld\n", bench_replace(test_string, "dog", "catapult", ITERS));
    printf("replace_shrink checksum: %ld\n", bench_replace(test_string, "benchmarking", "bench", ITERS));
    printf("substring checksum: %ld\n", bench_substring(test_string, ITERS));
    printf("split checksum: %ld\n", bench_split(test_string, " ", ITERS));
    printf("upper checksum: %ld\n", bench_upper(test_string, ITERS));
    printf("lower checksum: %ld\n", bench_lower(test_string, ITERS));
    printf("reverse checksum: %ld\n", bench_reverse(test_string, ITERS));
    printf("trim checksum: %ld\n", bench_trim(ITERS));
    printf("chain_window_replace checksum: %ld\n", bench_chain_window_replace(chain_string, ITERS));
    printf("chain_case_replace checksum: %ld\n", bench_chain_case_replace(test_string, ITERS));
    printf("chain_trim_reverse checksum: %ld\n", bench_chain_trim_reverse(ITERS));
    return 0;
}
