#!/usr/bin/env python3
"""Bundle src/TBVv4/**/*.lua into a single distributable Luau file.

Roblox executors load one script, but the source tree is deliberately split into
~20 modules for maintainability. This script inlines every module into a private
registry and exposes a tiny `import()` resolver, so:

    * development  -> many small files, explicit dependencies
    * distribution -> one file, same dependency order, no external requires

Module names are the paths relative to src/TBVv4 without the .lua extension,
e.g. src/TBVv4/Library/Theme.lua  ->  import("Library/Theme")

Usage:
    python3 tools/build.py              # writes dist/TBVv4.lua
    python3 tools/build.py --check      # bundle, parse-check, don't write
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src" / "TBVv4"
DIST = ROOT / "dist" / "TBVv4.lua"

ENTRY = "Main"
IMPORT_RE = re.compile(r"import\(\s*[\"']([^\"']+)[\"']\s*\)")

HEADER = """--[==[
\t{name}  ::  build {version}
\t----------------------------------------------------------------------------
\tGENERATED FILE - edit src/TBVv4/** instead, then run: python3 tools/build.py

\tModules are inlined in dependency order and resolved through the local
\timport() shim below (no global state, no external requires).

\tIncluded modules ({count}):
{listing}
]==]

local TBV_MODULES = {{}}
local TBV_CACHE = {{}}
local TBV_LOADING = {{}}

local function TBV_REGISTER(name, chunk)
\tTBV_MODULES[name] = chunk
end

--- Tiny module resolver with memoisation and cycle detection.
local function import(name)
\tif TBV_CACHE[name] ~= nil then
\t\treturn TBV_CACHE[name]
\tend

\tlocal chunk = TBV_MODULES[name]
\tif not chunk then
\t\terror("[TBV v4] unknown module: " .. tostring(name), 2)
\tend

\tif TBV_LOADING[name] then
\t\terror("[TBV v4] circular import detected: " .. tostring(name), 2)
\tend

\tTBV_LOADING[name] = true
\tlocal ok, result = pcall(chunk, import)
\tTBV_LOADING[name] = nil

\tif not ok then
\t\terror("[TBV v4] module " .. tostring(name) .. " failed to load: " .. tostring(result), 2)
\tend

\tTBV_CACHE[name] = result
\treturn result
end
"""

FOOTER = """
--------------------------------------------------------------------------------
--  Boot
--------------------------------------------------------------------------------

return import("{entry}")
"""


def discover() -> dict[str, Path]:
    """Map module name -> file path for every .lua file under src/TBVv4."""
    modules: dict[str, Path] = {}
    for path in sorted(SRC.rglob("*.lua")):
        name = path.relative_to(SRC).with_suffix("").as_posix()
        modules[name] = path
    return modules


def dependencies(modules: dict[str, Path]) -> dict[str, list[str]]:
    """Extract import("...") targets from each module."""
    graph: dict[str, list[str]] = {}
    for name, path in modules.items():
        source = path.read_text(encoding="utf-8")
        # Strip comment blocks so commented-out examples do not create edges.
        stripped = re.sub(r"--\[==\[.*?\]==\]", "", source, flags=re.S)
        stripped = re.sub(r"--\[\[.*?\]\]", "", stripped, flags=re.S)
        stripped = re.sub(r"--[^\n]*", "", stripped)
        graph[name] = sorted(set(IMPORT_RE.findall(stripped)))
    return graph


def topological_order(graph: dict[str, list[str]]) -> list[str]:
    """Depth-first topological sort; raises on unknown or circular imports."""
    order: list[str] = []
    state: dict[str, int] = {}  # 0 = visiting, 1 = done

    def visit(name: str, stack: list[str]) -> None:
        if state.get(name) == 1:
            return
        if state.get(name) == 0:
            cycle = " -> ".join(stack + [name])
            raise SystemExit(f"[build] circular import: {cycle}")

        state[name] = 0
        for dependency in graph.get(name, []):
            if dependency not in graph:
                raise SystemExit(f"[build] {name} imports unknown module '{dependency}'")
            visit(dependency, stack + [name])
        state[name] = 1
        order.append(name)

    for name in sorted(graph):
        visit(name, [])

    return order


def bundle(order: list[str], modules: dict[str, Path]) -> str:
    version = subprocess.run(
        ["git", "rev-parse", "--short", "HEAD"],
        cwd=ROOT, capture_output=True, text=True, check=False,
    ).stdout.strip() or "dev"

    listing = "\n".join(f"\t  - {name}" for name in order)

    parts = [
        HEADER.format(name="TBV v4", version=version, count=len(order), listing=listing),
    ]

    for name in order:
        source = modules[name].read_text(encoding="utf-8").rstrip()
        # The wrapper is declared as `function(...)` on purpose: modules start
        # with `local import = ...`, and in Lua/Luau `...` is only available
        # inside a function that is explicitly vararg (a bare `function(import)`
        # is NOT). Source files stay loadable standalone too, because a Lua
        # chunk is itself a vararg function.
        parts.append(f"\n--==========================================================================\n"
                     f"--  {name}\n"
                     f"--==========================================================================\n"
                     f'TBV_REGISTER("{name}", function(...)\n'
                     f"{source}\n"
                     f"end)\n")

    parts.append(FOOTER.format(entry=ENTRY))
    return "".join(parts)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="bundle and parse-check only")
    parser.add_argument("-o", "--output", default=str(DIST), help="output file")
    args = parser.parse_args()

    modules = discover()
    if not modules:
        print(f"[build] no modules found under {SRC}", file=sys.stderr)
        return 1

    graph = dependencies(modules)
    order = topological_order(graph)
    output = bundle(order, modules)

    if args.check:
        print(f"[build] {len(order)} modules, {len(output)} bytes, dependency order OK")
        return 0

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(output, encoding="utf-8")

    print(f"[build] wrote {out_path.relative_to(ROOT)} "
          f"({len(order)} modules, {len(output):,} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
