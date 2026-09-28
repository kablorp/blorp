#!/usr/bin/env python3
"""Differential check that upper/lower match the span-array case mapper.

The runtime maps each code point once into a scratch buffer and finds the
Final_Sigma context lazily. This test compares it with the original mapper
(decode every span, then map each one twice) on every two-byte code point
and every code point the case tables name (alone and as Final_Sigma
context), every byte value, random sequences of sigma, case-ignorable,
expanding and invalid pieces (including texts longer than the stack buffer),
and random bytes. Compiling the harness and running it with arguments
`10 full` sweeps every Unicode scalar value instead (about 4.9M cases).
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]

# Tenths of the full random workload; the targeted code-point sweep always runs.
WORKLOAD_TENTHS = "2"

HARNESS_SOURCE = textwrap.dedent(
    r"""
    #define _GNU_SOURCE
    #define MINICORO_IMPL
    #include "minicoro.h"
    #include "runtime.c"

    /* The original span-array mapper, kept as the specification: decode every
       span first, then map each one twice (once to size, once to write). */
    static bool reference_is_final_sigma_context(const blorp_utf8_span* spans, long count, long index) {
        bool has_cased_before = false;
        for (long i = index - 1; i >= 0; i--) {
            if (!spans[i].valid) break;
            int32_t cp = spans[i].codepoint;
            if (blorp_is_case_ignorable_codepoint(cp)) continue;
            has_cased_before = blorp_is_cased_codepoint(cp);
            break;
        }
        if (!has_cased_before) return false;
        for (long i = index + 1; i < count; i++) {
            if (!spans[i].valid) break;
            int32_t cp = spans[i].codepoint;
            if (blorp_is_case_ignorable_codepoint(cp)) continue;
            return !blorp_is_cased_codepoint(cp);
        }
        return true;
    }

    static blorp_unicode_case_mapping reference_mapping_for_span(
        const blorp_utf8_span* spans, long count, long index, bool upper
    ) {
        int32_t cp = spans[index].codepoint;
        if (!upper && cp == 0x03A3 && reference_is_final_sigma_context(spans, count, index)) {
            return (blorp_unicode_case_mapping){ .length = 1, .codepoints = {0x03C2, 0, 0} };
        }
        if (upper) {
            return blorp_unicode_case_lookup(cp, blorp_upper_ranges,
                sizeof(blorp_upper_ranges) / sizeof(blorp_upper_ranges[0]),
                blorp_upper_specials, sizeof(blorp_upper_specials) / sizeof(blorp_upper_specials[0]));
        }
        return blorp_unicode_case_lookup(cp, blorp_lower_ranges,
            sizeof(blorp_lower_ranges) / sizeof(blorp_lower_ranges[0]),
            blorp_lower_specials, sizeof(blorp_lower_specials) / sizeof(blorp_lower_specials[0]));
    }

    /* Returns a malloc'd buffer; *out_len receives its length. */
    static char* reference_case_map(const blorp_String* s, bool upper, size_t* out_len_ptr) {
        if (s->len == 0) { *out_len_ptr = 0; return calloc(1, 1); }
        if (blorp_string_is_ascii(s)) {
            char* r = malloc((size_t)s->len + 1);
            for (long i = 0; i < s->len; i++) {
                unsigned char b = (unsigned char)s->data[i];
                r[i] = upper ? (char)((b >= 'a' && b <= 'z') ? b - 32 : b)
                             : (char)((b >= 'A' && b <= 'Z') ? b + 32 : b);
            }
            *out_len_ptr = (size_t)s->len;
            return r;
        }
        blorp_utf8_span* spans = malloc(sizeof(blorp_utf8_span) * (size_t)s->len);
        long count = 0;
        for (long pos = 0; pos < s->len; ) {
            blorp_utf8_span span;
            blorp_utf8_decode_span(s, pos, &span);
            spans[count++] = span;
            pos += span.length;
        }
        size_t out_len = 0;
        for (long i = 0; i < count; i++) {
            if (!spans[i].valid) { out_len += (size_t)spans[i].length; continue; }
            blorp_unicode_case_mapping mapped = reference_mapping_for_span(spans, count, i, upper);
            for (uint8_t j = 0; j < mapped.length; j++) out_len += (size_t)blorp_utf8_encoded_len(mapped.codepoints[j]);
        }
        char* r = malloc(out_len + 1);
        size_t write = 0;
        for (long i = 0; i < count; i++) {
            if (!spans[i].valid) {
                memcpy(r + write, s->data + spans[i].start, (size_t)spans[i].length);
                write += (size_t)spans[i].length;
                continue;
            }
            blorp_unicode_case_mapping mapped = reference_mapping_for_span(spans, count, i, upper);
            for (uint8_t j = 0; j < mapped.length; j++) {
                unsigned char encoded[4];
                int len = blorp_utf8_encode(mapped.codepoints[j], encoded);
                memcpy(r + write, encoded, (size_t)len);
                write += (size_t)len;
            }
        }
        free(spans);
        *out_len_ptr = out_len;
        return r;
    }

    static unsigned long long compared = 0;
    static unsigned long long mismatches = 0;
    static unsigned long long total_bytes = 0;

    static void check_bytes(const char* bytes, long len) {
        blorp_String* input = blorp_string_from_buf(bytes, len);
        for (int u = 0; u < 2; u++) {
            size_t expected_len = 0;
            char* expected = reference_case_map(input, u == 1, &expected_len);
            blorp_String* actual = u ? blorp_upper(input) : blorp_lower(input);
            compared++;
            total_bytes += (unsigned long long)len;
            if ((size_t)actual->len != expected_len || memcmp(actual->data, expected, expected_len) != 0 ||
                actual->data[actual->len] != '\0') {
                mismatches++;
                if (mismatches < 10) {
                    fprintf(stderr, "MISMATCH %s len %ld:", u ? "upper" : "lower", len);
                    for (long i = 0; i < len && i < 40; i++) fprintf(stderr, " %02x", (unsigned char)bytes[i]);
                    fprintf(stderr, "\n");
                }
            }
            free(expected);
            blorp_release(actual);
        }
        blorp_release(input);
    }

    static uint64_t rng_state = 0x243F6A8885A308D3ull;
    static uint64_t next_random(void) {
        rng_state ^= rng_state << 13;
        rng_state ^= rng_state >> 7;
        rng_state ^= rng_state << 17;
        return rng_state;
    }

    /* Pieces that stress each rule: ASCII, cased and case-ignorable letters,
       capital and small sigma, expanding mappings, and invalid sequences
       (lone continuation, truncated lead, overlong, surrogate, out of range). */
    static const char* const pieces[] = {
        "a", "Z", " ", "1", "'", ".", ":", "-", "\xCE\xA3", "\xCE\xA3", "\xCF\x83", "\xCF\x82",
        "\xCE\x91", "\xCE\xB2", "\xCC\x81", "\xC2\xAD", "\xE2\x80\x99", "\xC3\x9F", "\xEF\xAC\x83",
        "\xCE\x90", "\xC4\xB0", "\xC5\x89", "\xC7\xB0", "\xE1\xBE\x80", "\xF0\x9F\x98\x80",
        "\xD0\x9F", "\xD0\xBF", "\xC3\xA9", "\xC3\x89", "\xE2\xB1\xA5", "\xC8\xBA",
        "\x80", "\xC3", "\xE2\x82", "\xF5\x80\x80\x80", "\xC0\x80", "\xED\xA0\x80", "\xFF",
        "\xF0\x90\x90\x80", "\xF0\x90\x90\xA8",
    };

    static long append_random_codepoint(char* buf) {
        uint32_t cp;
        do { cp = (uint32_t)(next_random() % 0x110000); } while (cp >= 0xD800 && cp <= 0xDFFF);
        return blorp_utf8_encode((int32_t)cp, (unsigned char*)buf);
    }

    /* One code point alone, and between a cased letter and a capital sigma
       so it is also checked as Final_Sigma context. */
    static void check_codepoint(int32_t cp) {
        char buf[16];
        if (cp >= 0xD800 && cp <= 0xDFFF) return;
        long n = blorp_utf8_encode(cp, (unsigned char*)buf);
        check_bytes(buf, n);
        buf[0] = (char)0xCE; buf[1] = (char)0x91;
        long m = 2 + blorp_utf8_encode(cp, (unsigned char*)buf + 2);
        buf[m] = (char)0xCE; buf[m + 1] = (char)0xA3;
        check_bytes(buf, m + 2);
    }

    static void check_ranges(const blorp_unicode_case_range* ranges, size_t count) {
        for (size_t i = 0; i < count; i++) {
            for (int32_t cp = ranges[i].start; cp <= ranges[i].end; cp++) check_codepoint(cp);
        }
    }

    static void check_specials(const blorp_unicode_case_special* specials, size_t count) {
        for (size_t i = 0; i < count; i++) check_codepoint(specials[i].codepoint);
    }

    #define CHECK_TABLE(check, table) check(table, sizeof(table) / sizeof(table[0]))

    int main(int argc, char** argv) {
        /* Workload in tenths of the random-string sets; 10 is the full run.
           A second argument "full" sweeps every Unicode scalar value. */
        long scale = argc > 1 ? atol(argv[1]) : 10;
        bool full_sweep = argc > 2 && strcmp(argv[2], "full") == 0;
        char buf[8192];

        if (full_sweep) {
            for (int32_t cp = 0; cp <= 0x10FFFF; cp++) check_codepoint(cp);
        } else {
            /* Every two-byte code point (Latin, Greek incl. sigma, Cyrillic,
               combining marks), then every code point any case table names:
               mapped, special, cased and case-ignorable. */
            for (int32_t cp = 0; cp < 0x800; cp++) check_codepoint(cp);
            CHECK_TABLE(check_ranges, blorp_upper_ranges);
            CHECK_TABLE(check_ranges, blorp_lower_ranges);
            CHECK_TABLE(check_ranges, blorp_cased_ranges);
            CHECK_TABLE(check_ranges, blorp_case_ignorable_ranges);
            CHECK_TABLE(check_specials, blorp_upper_specials);
            CHECK_TABLE(check_specials, blorp_lower_specials);
        }
        /* Every byte value, alone and inside non-ASCII text. */
        for (int b = 0; b < 256; b++) {
            buf[0] = (char)b; check_bytes(buf, 1);
            buf[0] = (char)0xC3; buf[1] = (char)0xA9; buf[2] = (char)b; buf[3] = 'x';
            check_bytes(buf, 4);
        }

        /* Random piece sequences, short and past the stack buffer. */
        for (long i = 0; i < 20000 * scale; i++) {
            long target = (i % 10 == 0) ? (long)(next_random() % 4000) : (long)(next_random() % 60);
            long len = 0;
            while (len < target) {
                if (next_random() % 8 == 0) {
                    len += append_random_codepoint(buf + len);
                } else {
                    const char* piece = pieces[next_random() % (sizeof(pieces) / sizeof(pieces[0]))];
                    size_t n = strlen(piece);
                    memcpy(buf + len, piece, n);
                    len += (long)n;
                }
            }
            check_bytes(buf, len);
        }
        /* Random bytes. */
        for (long i = 0; i < 5000 * scale; i++) {
            long len = (long)(next_random() % 700);
            for (long j = 0; j < len; j++) buf[j] = (char)next_random();
            check_bytes(buf, len);
        }

        printf("compared=%llu mismatches=%llu input_bytes=%llu\n", compared, mismatches, total_bytes);
        return mismatches != 0;
    }
    """
)


class RuntimeUnicodeCaseMapTests(unittest.TestCase):
    def test_single_pass_mapper_matches_span_array_mapper(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            executable = Path(temp_name) / "unicode-case-map-differential"
            compiled = subprocess.run(
                [
                    os.environ.get("CC", "cc"),
                    "-O2",
                    "-w",
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
                input=HARNESS_SOURCE,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            completed = subprocess.run(
                [str(executable), WORKLOAD_TENTHS],
                cwd=ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            self.assertIn(" mismatches=0", completed.stdout)


if __name__ == "__main__":
    unittest.main()
