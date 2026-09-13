/**
 * Parse every Luau source file (and the generated bundle) with luau-parser.
 *
 * There is no Luau runtime in CI, so this is a syntax-only gate: it catches
 * typos, unbalanced `end`s and malformed strings before they reach Roblox.
 *
 * Setup:  npm install luau-parser
 * Usage:  node tools/check-syntax.js            # check src/ + dist/
 *         node tools/check-syntax.js src/TBVv4  # check one path
 */

const fs = require("fs");
const path = require("path");

let parser;
try {
  parser = require("luau-parser");
} catch (error) {
  console.error("luau-parser is not installed. Run:  npm install luau-parser");
  process.exit(2);
}

const ROOT = path.resolve(__dirname, "..");
const DEFAULT_TARGETS = [path.join(ROOT, "src"), path.join(ROOT, "dist")];

function collect(target, out = []) {
  const stat = fs.statSync(target);
  if (stat.isFile()) {
    if (target.endsWith(".lua")) out.push(target);
    return out;
  }
  for (const entry of fs.readdirSync(target, { withFileTypes: true })) {
    if (entry.name === "node_modules" || entry.name.startsWith(".")) continue;
    collect(path.join(target, entry.name), out);
  }
  return out;
}

const targets = process.argv.slice(2).length ? process.argv.slice(2) : DEFAULT_TARGETS;
const files = targets.flatMap((t) => {
  const resolved = path.resolve(ROOT, t);
  return fs.existsSync(resolved) ? collect(resolved) : [];
});

if (files.length === 0) {
  console.error("No .lua files found.");
  process.exit(1);
}

let failures = 0;
for (const file of files) {
  const source = fs.readFileSync(file, "utf8");
  try {
    parser.parse(source);
    console.log(`  ok    ${path.relative(ROOT, file)}`);
  } catch (error) {
    failures++;
    const message = (error && error.message) || String(error);
    console.error(`  FAIL  ${path.relative(ROOT, file)}`);
    console.error(`        ${message.split("\n")[0]}`);
  }
}

console.log(
  `\n${files.length - failures}/${files.length} files parsed successfully.`
);
process.exit(failures === 0 ? 0 : 1);
