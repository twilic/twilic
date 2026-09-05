#!/usr/bin/env node
// Verify `npm pack` only ships publishable artifacts (see package.json `files`).

import { spawnSync } from "node:child_process";

const FORBIDDEN_PREFIXES = [
  "crates/",
  "scripts/",
  ".github/",
  "tests/",
  ".env",
];

const REQUIRED_PATHS = [
  "package.json",
  "LICENSE",
  "README.md",
  "dist/index.js",
  "wasm/pkg/twilic_wasm.js",
  "wasm/pkg/twilic_wasm_bg.wasm",
];

function main() {
  const result = spawnSync(
    "npm",
    ["pack", "--dry-run", "--json", "--ignore-scripts"],
    { encoding: "utf8", cwd: process.cwd() }
  );
  if (result.status !== 0) {
    console.error(result.stderr || result.stdout || "npm pack failed");
    process.exit(1);
  }

  let parsed;
  try {
    parsed = JSON.parse(result.stdout);
  } catch (error) {
    console.error(
      `failed to parse npm pack JSON: ${error instanceof Error ? error.message : error}`
    );
    process.exit(1);
  }

  const entry = Array.isArray(parsed) ? parsed[0] : parsed;
  const paths = (entry?.files ?? []).map((file) => file.path);
  if (paths.length === 0) {
    console.error("npm pack returned no files");
    process.exit(1);
  }

  const errors = [];

  for (const filePath of paths) {
    for (const prefix of FORBIDDEN_PREFIXES) {
      if (filePath === prefix.slice(0, -1) || filePath.startsWith(prefix)) {
        errors.push(`forbidden path in pack: ${filePath}`);
      }
    }
    if (
      filePath.endsWith(".node") &&
      !filePath.startsWith("native/twilic_napi-")
    ) {
      errors.push(`unexpected native addon in pack: ${filePath}`);
    }
  }

  for (const required of REQUIRED_PATHS) {
    if (!paths.includes(required)) {
      errors.push(`missing required path in pack: ${required}`);
    }
  }

  const hasTwilicNative = paths.some((filePath) =>
    /^native\/twilic_napi-[^/]+\.node$/.test(filePath)
  );
  if (!hasTwilicNative) {
    errors.push("missing native/twilic_napi-<platform>-<arch>.node in pack");
  }

  if (errors.length > 0) {
    for (const message of errors) {
      console.error(message);
    }
    process.exit(1);
  }

  console.log(`verify-pack-contents: ok (${paths.length} files)`);
}

main();
