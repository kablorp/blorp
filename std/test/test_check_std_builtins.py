from __future__ import annotations

import importlib.util
from importlib.machinery import SourceFileLoader
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
LOADER = SourceFileLoader(
    "check_std_builtins",
    str(ROOT / "scripts" / "check-std-builtins"),
)
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
assert SPEC is not None and SPEC.loader is not None
CHECK_STD_BUILTINS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK_STD_BUILTINS)


class BuiltinTypeStorageInventoryTests(unittest.TestCase):
    def check_inventory(
        self,
        std_sources: dict[str, str],
        manifest: str,
    ) -> list[str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            std_dir = root / "std"
            std_dir.mkdir()
            for relative_path, source in std_sources.items():
                path = std_dir / relative_path
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(source)
            manifest_path = root / "language_surface_manifest.brp"
            manifest_path.write_text(manifest)
            return CHECK_STD_BUILTINS.check_type_storage_manifest(
                std_dir,
                manifest_path,
                root,
            )

    def test_accepts_complete_non_resource_inventory(self) -> None:
        errors = self.check_inventory(
            {
                "int.brp": "type Int = builtin\n",
                "list.brp": "type List[T] = builtin\n",
                "fs.brp": 'resource type File = builtin("close")\n',
                "void.brp": "type Void = builtin\n",
            },
            """
private INLINE_SCALAR_BUILTIN_TYPES: List[(String, String)] = [
    ("std/int", "Int"),
]
private MANAGED_REFERENCE_BUILTIN_TYPES: List[(String, String)] = [
    ("std/list", "List"),
]
""",
        )
        self.assertEqual([], errors)

    def test_reports_missing_and_stale_manifest_entries(self) -> None:
        errors = self.check_inventory(
            {"int.brp": "type Int = builtin\n"},
            """
private INLINE_SCALAR_BUILTIN_TYPES: List[(String, String)] = []
private MANAGED_REFERENCE_BUILTIN_TYPES: List[(String, String)] = [
    ("std/string", "String"),
]
""",
        )
        self.assertIn(
            "std/int.brp: non-resource builtin type 'Int' is missing from compiler builtin storage metadata",
            errors,
        )
        self.assertIn(
            "compiler builtin storage metadata contains stale type std/string::String",
            errors,
        )

    def test_reports_duplicate_storage_classification(self) -> None:
        errors = self.check_inventory(
            {"int.brp": "type Int = builtin\n"},
            """
private INLINE_SCALAR_BUILTIN_TYPES: List[(String, String)] = [
    ("std/int", "Int"),
]
private MANAGED_REFERENCE_BUILTIN_TYPES: List[(String, String)] = [
    ("std/int", "Int"),
]
""",
        )
        self.assertIn(
            "compiler builtin storage metadata classifies std/int::Int more than once",
            errors,
        )

    def test_rejects_unparsed_manifest_entries(self) -> None:
        errors = self.check_inventory(
            {"int.brp": "type Int = builtin\n"},
            """
private INLINE_SCALAR_BUILTIN_TYPES: List[(String, String)] = [
    EXTRA_STORAGE_PAIR,
]
private MANAGED_REFERENCE_BUILTIN_TYPES: List[(String, String)] = []
""",
        )
        self.assertIn(
            "unsupported entry in INLINE_SCALAR_BUILTIN_TYPES: EXTRA_STORAGE_PAIR,",
            errors,
        )

    def test_ignores_builtin_declarations_in_documentation(self) -> None:
        errors = self.check_inventory(
            {
                "int.brp": """
---
Example only:
type Phantom = builtin
---
type Int = builtin
""",
                "void.brp": "type Void = builtin\n",
            },
            """
private INLINE_SCALAR_BUILTIN_TYPES: List[(String, String)] = [
    ("std/int", "Int"),
]
private MANAGED_REFERENCE_BUILTIN_TYPES: List[(String, String)] = []
""",
        )
        self.assertEqual([], errors)


if __name__ == "__main__":
    unittest.main()
