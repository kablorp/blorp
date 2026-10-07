"""The import graph of a checkout's Blorp files.

Shared by `scripts/compiler-check` (which gates a change by what imports it) and
`scripts/blorp-build-inputs` (which lists what a built program reads), so both
read `import:` blocks and resolve module spellings one way.

Resolution here is deliberately a subset of the compiler's: a spelling names the
file beside the importer or a standard library module. Anything else (a `pkg/`
request, a source package alias, a generated module not yet written) is reported
as unresolved, never guessed, and each caller treats unresolved as unprovable.

The compiler tries a source package alias, then the standard library, then the
file beside the importer; this reader tries beside the importer first. That is
safe for the callers: the order only decides which of two existing files a
spelling names, and `blorp-build-inputs` lists every standard library module
anyway, so it can over-include but never miss a file.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import posixpath
import re

BLORP_SOURCE_SUFFIX = ".brp"
STANDARD_LIBRARY_ROOT = "standard_library/src/"


@dataclass(frozen=True)
class SourceImports:
    """What a Blorp file imports: the files its imports resolve to, and the
    spellings that resolve to no file (what they name is unknown, never assumed
    safe)."""

    targets: tuple[str, ...]
    unresolved: tuple[str, ...]

    @property
    def complete(self) -> bool:
        return not self.unresolved


def module_imports(text: str) -> list[str]:
    """The module spellings of every `import:` block in a Blorp file."""
    spellings = []
    for block in re.finditer(r"^import:\n((?:(?:\t.*)?\n)*)", text, re.MULTILINE):
        for line in block.group(1).splitlines():
            header = re.match(r"\t(\S+?)(?: as \w+)?(?::.*)?$", line)
            if header is not None and not line.startswith("\t\t"):
                spellings.append(header.group(1))
    return spellings


class ImportGraph:
    """The import graph of the checkout's Blorp files, read on demand."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self._imports: dict[str, SourceImports | None] = {}

    def imports(self, path: str) -> SourceImports | None:
        """The imports of `path`, or `None` when it is not a readable file."""
        if path not in self._imports:
            self._imports[path] = self._read_imports(path)
        return self._imports[path]

    def _read_imports(self, path: str) -> SourceImports | None:
        file = self.root / path
        if not path.endswith(BLORP_SOURCE_SUFFIX) or not file.is_file():
            return None
        targets: list[str] = []
        unresolved: list[str] = []
        for spelling in module_imports(file.read_text(encoding="utf-8")):
            beside = posixpath.normpath(
                posixpath.join(posixpath.dirname(path), spelling + BLORP_SOURCE_SUFFIX)
            )
            library = f"{STANDARD_LIBRARY_ROOT}{spelling}{BLORP_SOURCE_SUFFIX}"
            for candidate in (beside, library):
                if (self.root / candidate).is_file():
                    targets.append(candidate)
                    break
            else:
                unresolved.append(spelling)
        return SourceImports(tuple(targets), tuple(unresolved))

    def reachable_from(self, starts: list[str]) -> set[str]:
        """Every Blorp file `starts` name, and every file they import, directly
        or not. A start that is not a Blorp file is left out."""
        seen = {start for start in starts if self.imports(start) is not None}
        pending = list(seen)
        while pending:
            imported = self.imports(pending.pop())
            for target in imported.targets if imported else ():
                if target not in seen:
                    seen.add(target)
                    pending.append(target)
        return seen

    def importers_of(self, modules: set[str]) -> set[str]:
        """The Blorp files under `blorp/` that import any of `modules`,
        transitively."""
        reverse: dict[str, set[str]] = {}
        for file in sorted((self.root / "blorp").rglob(f"*{BLORP_SOURCE_SUFFIX}")):
            path = file.relative_to(self.root).as_posix()
            imported = self.imports(path)
            for target in imported.targets if imported else ():
                reverse.setdefault(target, set()).add(path)
        seen: set[str] = set()
        pending = list(modules)
        while pending:
            for importer in reverse.get(pending.pop(), ()):
                if importer not in seen:
                    seen.add(importer)
                    pending.append(importer)
        return seen
