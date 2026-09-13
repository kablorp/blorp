#!/usr/bin/env python3
"""Generate nested-hoist source fixtures outside the measured process."""

from __future__ import annotations

import argparse
from pathlib import Path


SIZES = (4096, 8192, 16384)


def independent_source(function_count: int) -> str:
    chunks: list[str] = []
    for index in range(function_count):
        chunks.append(f"func independent_{index}() -> Int:\n\t{index}\n\n")
    return "".join(chunks)


def ordinary_nested_source(index: int) -> str:
    return (
        f"func outer_{index}() -> Int:\n"
        f"\tfunc helper_{index}() -> Int:\n"
        f"\t\t{index}\n"
        f"\thelper_{index}()\n\n"
    )


def private_nested_source(index: int) -> str:
    return (
        f"private func hidden_{index}() -> Int:\n"
        f"\tfunc secret_{index}() -> Int:\n"
        f"\t\t{index}\n"
        f"\tsecret_{index}()\n\n"
    )


def impl_nested_source(index: int) -> str:
    return (
        "implements NestedHoistProfileTrait for NestedHoistProfileBox:\n"
        f"\tfunc value_{index}(self: NestedHoistProfileBox) -> Int:\n"
        f"\t\tfunc method_helper_{index}() -> Int:\n"
        f"\t\t\t{index}\n"
        f"\t\tmethod_helper_{index}()\n\n"
    )


def mixed_source(function_count: int) -> str:
    chunks = [
        "record NestedHoistProfileBox {value: Int}\n"
        "trait NestedHoistProfileTrait:\n"
        "\tfunc value(self: Self) -> Int\n\n"
    ]
    for index in range(function_count):
        remainder = index % 3
        if remainder == 0:
            chunks.append(ordinary_nested_source(index))
        elif remainder == 1:
            chunks.append(private_nested_source(index))
        else:
            chunks.append(impl_nested_source(index))
    return "".join(chunks)


def write_fixture(output_dir: Path, variant: str, function_count: int, source: str) -> None:
    output_path = output_dir / f"nested_hoist_{variant}_{function_count}.brp"
    output_path.write_text(source, encoding="utf-8")
    print(output_path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output_dir", type=Path)
    args = parser.parse_args()

    args.output_dir.mkdir(parents=True, exist_ok=True)
    for function_count in SIZES:
        write_fixture(
            args.output_dir,
            "independent",
            function_count,
            independent_source(function_count),
        )
        write_fixture(args.output_dir, "mixed", function_count, mixed_source(function_count))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
