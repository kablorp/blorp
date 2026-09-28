#!/usr/bin/env python3
"""Differential check that Float to_string matches the linear precision search.

The runtime skips precisions when searching for the fewest digits that
round-trip. This test compares it with the original one-precision-at-a-time
search over powers of two and ten, the 2^52 boundary, decimals of every digit
count, random bit patterns, subnormals, rationals, sums, and integers.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]

# Tenths of the full workload; 2 compares about 260 thousand values.
WORKLOAD_TENTHS = "2"

HARNESS_SOURCE = textwrap.dedent(
    r"""
    #define _GNU_SOURCE
    #define MINICORO_IMPL
    #include "minicoro.h"
    #include "runtime.c"

    /* The original linear search, kept as the specification: the fewest
       significant digits in [7, 17] whose %.*g text round-trips, else %.17g. */
    static int reference_float_text(double f, char* buf) {
        if (!isfinite(f)) {
            if (isnan(f)) { memcpy(buf, "nan", 3); return 3; }
            if (signbit(f)) { memcpy(buf, "-inf", 4); return 4; }
            memcpy(buf, "inf", 3); return 3;
        }
        int len = snprintf(buf, 64, "%g", f);
        uint64_t original_bits = 0;
        memcpy(&original_bits, &f, sizeof(original_bits));
        bool exact = false;
        if (len > 0 && len < 64) {
            char* end = NULL;
            double parsed = strtod(buf, &end);
            uint64_t parsed_bits = 0;
            memcpy(&parsed_bits, &parsed, sizeof(parsed_bits));
            exact = end == buf + len && original_bits == parsed_bits;
        }
        if (!exact) {
            for (int precision = 7; precision <= DBL_DECIMAL_DIG; precision++) {
                len = snprintf(buf, 64, "%.*g", precision, f);
                if (len <= 0 || len >= 64) continue;
                char* end = NULL;
                double parsed = strtod(buf, &end);
                uint64_t parsed_bits = 0;
                memcpy(&parsed_bits, &parsed, sizeof(parsed_bits));
                if (end == buf + len && original_bits == parsed_bits) break;
            }
        }
        if (len < 0) len = 0;
        return len;
    }

    static unsigned long long compared = 0;
    static unsigned long long mismatches = 0;
    static unsigned long long by_len[32];

    static void check(double f) {
        char expected[64];
        int expected_len = reference_float_text(f, expected);
        blorp_String* actual = blorp_float_to_string(f);
        compared++;
        if (actual->len != expected_len || memcmp(actual->data, expected, (size_t)expected_len) != 0) {
            mismatches++;
            if (mismatches < 20) {
                fprintf(stderr, "MISMATCH %a expected '%.*s' actual '%.*s'\n", f, expected_len, expected, (int)actual->len, actual->data);
            }
        }
        if (expected_len < 32) by_len[expected_len]++;
        blorp_release(actual);
    }

    static void check_signed(double f) { check(f); check(-f); }

    static uint64_t rng_state = 0x9E3779B97F4A7C15ull;
    static uint64_t next_random(void) {
        rng_state ^= rng_state << 13;
        rng_state ^= rng_state >> 7;
        rng_state ^= rng_state << 17;
        return rng_state;
    }

    static double from_bits(uint64_t bits) { double d; memcpy(&d, &bits, sizeof d); return d; }

    static void check_neighbourhood(double f, int radius) {
        double down = f, up = f;
        check_signed(f);
        for (int i = 0; i < radius; i++) {
            down = nextafter(down, -INFINITY);
            up = nextafter(up, INFINITY);
            check_signed(down);
            check_signed(up);
        }
    }

    int main(int argc, char** argv) {
        /* Workload in tenths: 10 compares about one million values. */
        long scale = argc > 1 ? atol(argv[1]) : 10;
        if (argc > 2) rng_state = strtoull(argv[2], NULL, 0);

        /* Special values. */
        check_signed(0.0); check_signed(NAN); check_signed(INFINITY);
        check_neighbourhood(DBL_MAX, 50); check_neighbourhood(DBL_MIN, 50);
        check_neighbourhood(DBL_TRUE_MIN, 50);

        /* Every power of two and power of ten, with neighbours. */
        for (int e = -1074; e <= 1023; e++) check_neighbourhood(ldexp(1.0, e), 4);
        for (int e = -323; e <= 308; e++) {
            char text[32];
            snprintf(text, sizeof text, "1e%d", e);
            check_neighbourhood(strtod(text, NULL), 4);
        }
        /* Around the 2^52 / 2^53 monotonicity boundary. */
        check_neighbourhood(0x1p51, 2000); check_neighbourhood(0x1p52, 2000);
        check_neighbourhood(0x1p53, 2000); check_neighbourhood(0x1p54, 200);

        /* Decimals with exactly d significant digits, the classes that need
           each precision; and their neighbours, which need 16-17 digits. */
        for (long i = 0; i < 20000 * scale / 10; i++) {
            int digits = 1 + (int)(next_random() % 17);
            int exponent = (int)(next_random() % 640) - 330;
            uint64_t mantissa = next_random();
            char text[64];
            char digit_text[32];
            int n = 0;
            digit_text[n++] = (char)('1' + mantissa % 9); mantissa /= 9;
            for (int d = 1; d < digits; d++) { digit_text[n++] = (char)('0' + next_random() % 10); }
            digit_text[n] = '\0';
            snprintf(text, sizeof text, "%c.%se%d", digit_text[0], digit_text + 1, exponent);
            check_neighbourhood(strtod(text, NULL), 1);
        }

        /* Random bit patterns over the whole double space. */
        for (long i = 0; i < 200000 * scale / 10; i++) check(from_bits(next_random()));

        /* Random values in human ranges: uniform [0, 1) times 10^k. */
        for (long i = 0; i < 100000 * scale / 10; i++) {
            double unit = (double)(next_random() >> 11) * 0x1p-53;
            int k = (int)(next_random() % 41) - 20;
            check_signed(unit * pow(10.0, k));
        }

        /* Small rationals and accumulated sums, typical arithmetic results. */
        for (int a = 1; a <= 30 * (int)(scale < 100 ? scale : 100); a++)
            for (int b = 1; b <= 300; b++) check_signed((double)a / (double)b);
        double sum = 0.0;
        for (long i = 0; i < 50000 * scale / 10; i++) { sum += 0.1; check(sum); }

        /* Integers of every magnitude up to 2^64, including just above 2^52. */
        for (long i = 0; i < 50000 * scale / 10; i++) {
            int bits = 1 + (int)(next_random() % 64);
            uint64_t value = next_random() >> (64 - bits);
            check_signed((double)value);
        }

        /* Subnormals. */
        for (long i = 0; i < 50000 * scale / 10; i++) check_signed(from_bits(next_random() & ((UINT64_C(1) << 52) - 1)));

        printf("compared=%llu mismatches=%llu\n", compared, mismatches);
        for (int i = 0; i < 32; i++) if (by_len[i]) printf("  len %d: %llu\n", i, by_len[i]);
        return mismatches != 0;
    }
    """
)


class RuntimeFloatToStringTests(unittest.TestCase):
    def test_fewest_digit_search_matches_linear_search(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            executable = Path(temp_name) / "float-to-string-differential"
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
