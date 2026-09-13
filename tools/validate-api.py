#!/usr/bin/env python3
"""Validate Roblox API usage (Enums + instance properties) in the Luau sources.

Roblox silently ignores writes to properties that do not exist, and an invalid
`Enum.X.Y` throws at runtime - both are easy to introduce and hard to spot in a
20-file UI library. This script checks every `Enum.X.Y` reference and every
property key passed to Utility:Create() against the official API surface.

API data comes from @rbxts/types (generated from Roblox's own API dump):

    npm install @rbxts/types

Usage:
    python3 tools/validate-api.py
    python3 tools/validate-api.py --types /path/to/node_modules/@rbxts/types
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src" / "TBVv4"

CANDIDATE_PATHS = [
    "node_modules/@rbxts/types/include/generated",
    "/tmp/node_modules/@rbxts/types/include/generated",
    str(Path.home() / "node_modules/@rbxts/types/include/generated"),
]

ENUM_RE = re.compile(r"\bEnum\.(\w+)\.(\w+)")
CREATE_RE = re.compile(r'Utility:Create\(\s*["\'](\w+)["\']\s*,\s*\{')
PROP_RE = re.compile(r"^\s*(\w+)\s*=\s*", re.M)

# Property names we set that the dump marks read-only but Roblox allows from
# Lua, or that live on a sibling class we do not model. Extend as needed.
ALLOWED_READONLY = {
    "Name", "Parent", "Rotation",
}


def locate_types(explicit: str | None) -> Path:
    if explicit:
        path = Path(explicit) / "include" / "generated"
        if path.is_dir():
            return path
        path = Path(explicit)
        if path.is_dir():
            return path
        raise SystemExit(f"[validate] types not found at {explicit}")

    for candidate in CANDIDATE_PATHS:
        path = Path(candidate)
        if not path.is_absolute():
            path = ROOT / path
        if path.is_dir():
            return path
    raise SystemExit(
        "[validate] @rbxts/types not found. Run:  npm install @rbxts/types"
    )


def parse_enums(path: Path) -> dict[str, set[str]]:
    """Enum.<Name> -> {members} from the generated enums.d.ts.

    Each enum member is declared as `export const <Member>` inside
    `export namespace <EnumName> { ... }`, but those namespaces also contain
    `export interface <Member>` blocks - so tracking braces by depth (rather than
    "any line starting with }") is required, otherwise the first nested interface
    pops the namespace off the stack and every member is lost.
    """
    enums: dict[str, set[str]] = {}
    stack: list[tuple[str, int]] = []  # (enum name, brace depth at its opening)
    depth = 0

    for raw in path.joinpath("enums.d.ts").read_text(encoding="utf-8").splitlines():
        line = raw.strip()

        if line.startswith("export namespace ") and "{" in line:
            name = line[len("export namespace "):].split()[0].rstrip("{").strip()
            enums.setdefault(name, set())
            stack.append((name, depth))
        elif line.startswith("export const ") and stack:
            # Only constants inside an enum namespace count as enum members
            # (the file also declares top-level helpers we must ignore).
            member = line[len("export const "):].split(":")[0].split("=")[0].strip()
            if re.fullmatch(r"[A-Za-z_]\w*", member):
                enums[stack[-1][0]].add(member)

        depth += line.count("{") - line.count("}")
        while stack and depth <= stack[-1][1]:
            stack.pop()

    return enums


def parse_classes(path: Path) -> tuple[dict[str, set[str]], dict[str, str], dict[str, set[str]]]:
    """Return (class -> properties, class -> parent, class -> readonly props)."""
    properties: dict[str, set[str]] = {}
    parents: dict[str, str] = {}
    readonly: dict[str, set[str]] = {}

    current: list[tuple[str, int]] = []  # (class, brace depth at declaration)

    for raw in path.joinpath("None.d.ts").read_text(encoding="utf-8").splitlines():
        stripped = raw.strip()

        match = re.match(r"^interface\s+(\w+)(?:\s+extends\s+(\w+))?\s*\{", stripped)
        if match:
            class_name, parent = match.group(1), match.group(2)
            depth = len(current) + 1
            current.append((class_name, depth))
            properties.setdefault(class_name, set())
            readonly.setdefault(class_name, set())
            if parent:
                parents[class_name] = parent
            continue

        if stripped.startswith("}"):
            if current:
                current.pop()
            continue

        if not current:
            continue

        class_name = current[-1][0]
        if stripped.startswith("readonly "):
            prop = re.match(r"^readonly\s+(\w+)", stripped)
            if prop:
                readonly[class_name].add(prop.group(1))
                properties[class_name].add(prop.group(1))
            continue

        prop = re.match(r"^(\w+)\??\s*[:(]", stripped)
        if prop and not stripped.startswith("//"):
            properties[class_name].add(prop.group(1))

    return properties, parents, readonly


def resolve(class_name: str, properties: dict[str, set[str]],
            parents: dict[str, str]) -> set[str]:
    """All properties available on a class, walking the inheritance chain."""
    seen: set[str] = set()
    cursor: str | None = class_name
    while cursor and cursor not in seen:
        seen.add(cursor)
        seen |= properties.get(cursor, set())
        cursor = parents.get(cursor)
    return seen


def extract_props(block: str) -> list[str]:
    """Top-level property keys inside a `{ ... }` block.

    A regex alone is not enough: property tables may be written on one line, and
    nested tables (ColorSequence keypoints, UDim2 arguments) contain `=` signs of
    their own. So scan character by character and only record identifiers that
    appear at depth 1.
    """
    props: list[str] = []
    depth = 0
    index, length = 0, len(block)
    identifier = re.compile(r"[A-Za-z_]\w*")

    while index < length:
        char = block[index]

        if char in "{([":
            depth += 1
            index += 1
            continue
        if char in "})]":
            depth -= 1
            index += 1
            continue
        if char in "\"'":
            quote = char
            index += 1
            while index < length and block[index] != quote:
                if block[index] == "\\":
                    index += 1
                index += 1
            index += 1
            continue
        if block.startswith("--", index):
            newline = block.find("\n", index)
            index = length if newline < 0 else newline + 1
            continue

        if depth == 1:
            match = identifier.match(block, index)
            if match:
                after = match.end()
                while after < length and block[after] in " \t":
                    after += 1
                if after < length and block[after] == "=" and not block.startswith("==", after):
                    props.append(match.group(0))
                index = match.end()
                continue

        index += 1

    return props


def extract_create_blocks(source: str) -> list[tuple[str, str]]:
    """Find Utility:Create("Class", { ... }) and return (class, block text)."""
    blocks: list[tuple[str, str]] = []
    for match in CREATE_RE.finditer(source):
        class_name = match.group(1)
        start = match.end() - 1  # position of the opening brace
        depth = 0
        for index in range(start, len(source)):
            char = source[index]
            if char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
                if depth == 0:
                    blocks.append((class_name, source[start:index + 1]))
                    break
    return blocks


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--types", help="path to the @rbxts/types package")
    args = parser.parse_args()

    types_path = locate_types(args.types)
    enums = parse_enums(types_path)
    properties, parents, readonly = parse_classes(types_path)

    files = sorted(SRC.rglob("*.lua"))
    errors: list[str] = []
    warnings: list[str] = []
    checked_properties = 0

    for file in files:
        source = file.read_text(encoding="utf-8")
        # Strip block comments so documentation examples are not validated.
        source = re.sub(r"--\[==\[.*?\]==\]", "", source, flags=re.S)

        for enum_name, member in ENUM_RE.findall(source):
            members = enums.get(enum_name)
            if members is None:
                errors.append(f"{file.relative_to(ROOT)}: unknown enum '{enum_name}' (Enum.{enum_name}.{member})")
            elif member not in members:
                errors.append(f"{file.relative_to(ROOT)}: Enum.{enum_name}.{member} is not a valid member")

        for class_name, block in extract_create_blocks(source):
            available = resolve(class_name, properties, parents)
            if not available:
                warnings.append(f"{file.relative_to(ROOT)}: unknown class '{class_name}' - properties not checked")
                continue

            all_readonly: set[str] = set()
            cursor: str | None = class_name
            visited: set[str] = set()
            while cursor and cursor not in visited:
                visited.add(cursor)
                all_readonly |= readonly.get(cursor, set())
                cursor = parents.get(cursor)

            for prop in extract_props(block):
                checked_properties += 1
                if prop in ("Parent",):
                    continue
                if prop not in available:
                    errors.append(f"{file.relative_to(ROOT)}: {class_name} has no property '{prop}'")
                elif prop in all_readonly and prop not in ALLOWED_READONLY:
                    warnings.append(f"{file.relative_to(ROOT)}: {class_name}.{prop} is read-only in the dump")

    for line in sorted(set(errors)):
        print(f"  ERROR  {line}")
    for line in sorted(set(warnings)):
        print(f"  warn   {line}")

    print(f"\nchecked {len(files)} files, {checked_properties} property assignments")
    if errors:
        print(f"{len(set(errors))} error(s)")
        return 1
    print("no API errors")
    return 0


if __name__ == "__main__":
    sys.exit(main())
