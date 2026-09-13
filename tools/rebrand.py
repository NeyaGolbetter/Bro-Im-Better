#!/usr/bin/env python3
"""Rebrand an upstream VapeV4 source tree to TBV v4.

This is the "global search and replace" half of the rewrite, kept as a
repeatable script rather than a manual find-and-replace so it can be re-run
after pulling upstream changes.

What it does
  * Rewrites every case-insensitive variant of the old brand in text files:
        "VapeV4", "Vape V4", "vape v4", "Vape", "VAPE", ...  ->  "TBV v4" / "TBV"
  * Rewrites the on-disk folder prefix:
        "vape/..."  ->  "TBVv4/..."        (matches the Config root in
                                            src/TBVv4/Config/ConfigSystem.lua)
  * Renames files and directories that carry the old name.
  * Skips binaries, .git, node_modules and anything in --exclude.
  * --dry-run prints the plan without touching a file.

Usage
    python3 tools/rebrand.py ../VapeV4ForRoblox --dry-run
    python3 tools/rebrand.py ../VapeV4ForRoblox --report rebrand-report.json
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

# ---------------------------------------------------------------------------
#  Rules. Order matters: longest / most specific first.
#  (label, pattern, replacement, applies_to)
# ---------------------------------------------------------------------------

# Each rule maps a pattern to a (code_form, display_form) pair.
#
# CODE FORM is used where the old brand was a Lua identifier
# (`local VapeV4 = {}`, `Vape.Notification`, `return VapeV4`). "TBV v4"
# contains a space, so pasting it into an identifier produces invalid Lua -
# code sites get "TBVv4" instead.
#
# DISPLAY FORM is used inside comments and string literals, where readability
# is what matters and a space is harmless.
RULES: list[tuple[str, str, str, str]] = [
    # Repository / project names first, so they are not mangled by the generic
    # brand rule below.
    ("repo", r"VapeV4ForRoblox", "TBVv4", "TBVv4"),

    # "Vape V4" / "VapeV4" (any spacing or casing)
    ("brand-v4", r"Vape\s*V\s*4", "TBVv4", "TBV v4"),

    # Anything left is the bare brand.
    ("brand", r"Vape", "TBV", "TBV"),
]

# Path-shaped rewriting. These run BEFORE the text rules and only fire when the
# old name is followed by a path separator or a quote, so prose like
# "loaded vape" is not turned into a directory name.
PATH_RULES: list[tuple[str, str, str]] = [
    # Profile files: upstream used a `.vape` extension, TBV v4 stores JSON.
    ("profile-extension", r"\.vape\b", ".json"),
    # Config root: "vape/Profiles" -> "TBVv4/Profiles"
    ("config-root", r"(?<![\w.])vape(?=[/\\\"'|.])", "TBVv4"),
]

# ".vape" is upstream's profile extension - included so profile files are
# rewritten and renamed to .json by the rules above.
TEXT_EXTENSIONS = {".lua", ".luau", ".md", ".txt", ".json", ".yml", ".yaml",
                   ".toml", ".rbxm", ".rbxmx", ".vape"}
SKIP_DIRS = {".git", "node_modules", "dist", "build", "__pycache__", ".venv"}


@dataclass
class FileReport:
    path: str
    replacements: dict[str, int] = field(default_factory=dict)
    renamed_to: str | None = None


def is_binary(path: Path) -> bool:
    with path.open("rb") as handle:
        return b"\x00" in handle.read(4096)


def in_display_context(prefix: str) -> bool:
    """Is `prefix` (the text before a match, on the same line) a comment or a
    string literal?

    A cheap but effective line-local heuristic: a `--` anywhere before the match
    means we are in a comment; an odd number of unescaped quotes means we are
    inside a string. Everything else is treated as code.
    """
    if "--" in prefix:
        return True

    in_string: str | None = None
    index = 0
    while index < len(prefix):
        char = prefix[index]
        if char == "\\":
            index += 2
            continue
        if char in ("'", '"'):
            if in_string is None:
                in_string = char
            elif in_string == char:
                in_string = None
        index += 1

    return in_string is not None


def apply_text_rules(content: str) -> tuple[str, dict[str, int]]:
    """Rewrite the brand, choosing the code or display form per occurrence."""
    counts: dict[str, int] = {}
    lines = content.split("\n")
    output: list[str] = []

    for line in lines:
        # Apply each rule in order, tracking how much of the line is already
        # finalised so later rules never re-match inside a replacement.
        result = ""
        remaining = line

        while remaining:
            next_match: tuple[int, re.Match, tuple[str, str, str, str]] | None = None

            for rule in RULES:
                label, pattern, code_form, display_form = rule
                match = re.search(pattern, remaining, re.IGNORECASE)
                if not match:
                    continue
                if next_match is None or match.start() < next_match[0]:
                    next_match = (match.start(), match, rule)

            if next_match is None:
                result += remaining
                break

            start, match, rule = next_match
            label, _pattern, code_form, display_form = rule

            use_display = in_display_context(result + remaining[:start])
            replacement = display_form if use_display else code_form
            key = f"{label}:{'display' if use_display else 'code'}"
            counts[key] = counts.get(key, 0) + 1

            result += remaining[:start] + replacement
            remaining = remaining[match.end():]

        output.append(result)

    return "\n".join(output), counts


def apply_path_rules(content: str) -> tuple[str, dict[str, int]]:
    counts: dict[str, int] = {}
    for label, pattern, replacement in PATH_RULES:
        compiled = re.compile(pattern, re.IGNORECASE)
        content, count = compiled.subn(replacement, content)
        if count:
            counts["path:" + label] = count
    return content, counts


# File and directory names have their own rule set: a space is legal in a
# filename but painful in scripts, so "VapeV4.lua" becomes "TBVv4.lua" while
# prose still renders as "TBV v4".
NAME_RULES: list[tuple[str, str, str]] = [
    ("profile-file", r"\.vape$", ".json"),     # 123.vape -> 123.json
    ("root-dir", r"^vape$", "TBVv4"),          # the config root folder
    ("v4-spaced", r"Vape\s*V\s*4", "TBVv4"),
    ("v4-joined", r"VapeV\s*4", "TBVv4"),
    ("brand", r"Vape", "TBV"),
]


def rebrand_name(name: str) -> str:
    """Rename a file/directory that carries the old brand."""
    updated = name
    for _label, pattern, replacement in NAME_RULES:
        updated = re.sub(pattern, replacement, updated, flags=re.IGNORECASE)
    return updated


def walk_files(root: Path, exclude: list[str]):
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        if any(part in SKIP_DIRS or part in exclude for part in path.parts):
            continue
        yield path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", help="directory to rebrand")
    parser.add_argument("--dry-run", action="store_true", help="show the plan only")
    parser.add_argument("--report", help="write a JSON report to this path")
    parser.add_argument("--exclude", nargs="*", default=[], help="extra directory names to skip")
    args = parser.parse_args()

    root = Path(args.target).expanduser().resolve()
    if not root.is_dir():
        print(f"[rebrand] not a directory: {root}", file=sys.stderr)
        return 1

    reports: list[FileReport] = []
    renamed: list[tuple[str, str]] = []
    skipped_binary = 0

    for path in walk_files(root, args.exclude):
        if path.suffix.lower() not in TEXT_EXTENSIONS:
            continue
        if is_binary(path):
            skipped_binary += 1
            continue

        original = path.read_text(encoding="utf-8", errors="replace")

        # Path rules first: once the bare brand rule has rewritten "vape/" to
        # "TBV/", the path rules can no longer recognise it.
        content, path_counts = apply_path_rules(original)
        content, text_counts = apply_text_rules(content)
        counts = {**path_counts, **text_counts}

        report = FileReport(path=str(path.relative_to(root)))

        if counts and content != original:
            report.replacements = counts
            if not args.dry_run:
                path.write_text(content, encoding="utf-8")

        # Rename the file itself if needed.
        new_name = rebrand_name(path.name)
        if new_name != path.name:
            target = path.with_name(new_name)
            renamed.append((str(path.relative_to(root)), str(target.relative_to(root))))
            report.renamed_to = new_name
            if not args.dry_run:
                path.rename(target)

        if report.replacements or report.renamed_to:
            reports.append(report)

    # Directory renames (deepest first so parents still exist when renamed).
    for directory in sorted(root.rglob("*"), key=lambda p: len(p.parts), reverse=True):
        if not directory.is_dir():
            continue
        if any(part in SKIP_DIRS or part in args.exclude for part in directory.parts):
            continue
        new_name = rebrand_name(directory.name)
        if new_name != directory.name:
            target = directory.with_name(new_name)
            renamed.append((str(directory.relative_to(root)), str(target.relative_to(root))))
            if not args.dry_run:
                directory.rename(target)

    # ------------------------------------------------------------------ report
    total = sum(sum(r.replacements.values()) for r in reports)
    mode = "DRY RUN - no files changed" if args.dry_run else "applied"

    print(f"[rebrand] {mode}")
    print(f"[rebrand] files changed : {len(reports)}")
    print(f"[rebrand] replacements  : {total}")
    print(f"[rebrand] renamed       : {len(renamed)}")
    if skipped_binary:
        print(f"[rebrand] skipped binary: {skipped_binary}")

    for report in reports[:20]:
        detail = ", ".join(f"{key}={value}" for key, value in sorted(report.replacements.items()))
        suffix = f" -> {report.renamed_to}" if report.renamed_to else ""
        print(f"    {report.path}{suffix}  [{detail}]")
    if len(reports) > 20:
        print(f"    ... and {len(reports) - 20} more")

    if args.report:
        payload = {
            "mode": "dry-run" if args.dry_run else "applied",
            "total_replacements": total,
            "files": [
                {"path": r.path, "replacements": r.replacements, "renamed_to": r.renamed_to}
                for r in reports
            ],
            "renamed": [{"from": old, "to": new} for old, new in renamed],
        }
        Path(args.report).write_text(json.dumps(payload, indent=2), encoding="utf-8")
        print(f"[rebrand] report written to {args.report}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
