"""Static checks for the diagnostic-only R0 generated-C instrumentation."""

import importlib.util
from pathlib import Path
import unittest


SCRIPT = Path(__file__).with_name("fixed_layout_r0_instrument.py")
SPEC = importlib.util.spec_from_file_location("fixed_layout_r0_instrument", SCRIPT)
assert SPEC and SPEC.loader
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)


class BoxCallScannerTests(unittest.TestCase):
    def test_ignores_quoted_and_commented_text(self) -> None:
        source = (
            'char* text = "blorp_box_struct(&fake, sizeof(Fake))";\n'
            "// blorp_box_struct(&comment, sizeof(Fake))\n"
            "/* blorp_box_struct(&block, sizeof(Fake)) */\n"
            "void* result = blorp_box_struct(&value, sizeof(Real));\n"
        )
        sites = probe.box_site_manifest(source)
        self.assertEqual(len(sites), 1)
        self.assertEqual(sites[0]["line"], 4)
        self.assertEqual(sites[0]["c_type"], "Real")
        self.assertEqual(sites[0]["destination"], "unknown")

    def test_distinct_calls_on_one_line_get_distinct_ids(self) -> None:
        source = (
            "blorp_tuple_new(2, blorp_box_struct(&left, sizeof(Left)), "
            "blorp_box_struct(&right, sizeof(Right)));\n"
        )
        sites = probe.box_site_manifest(source)
        self.assertEqual([site["id"] for site in sites], [0, 1])
        self.assertEqual([site["c_type"] for site in sites], ["Left", "Right"])
        self.assertEqual([site["destination"] for site in sites], ["unknown", "unknown"])


if __name__ == "__main__":
    unittest.main()
