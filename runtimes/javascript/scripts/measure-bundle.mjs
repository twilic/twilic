#!/usr/bin/env node
// Measure publishable artifact sizes for twilic-js and emit a JSON report.
//
// Usage:
//   node scripts/measure-bundle.mjs [--out PATH] [--cwd DIR]
//
// The report includes per-directory totals (dist, native, wasm/pkg),
// per-file sizes, and a `npm pack --dry-run --json --ignore-scripts` snapshot
// so the resulting tarball size can be compared between branches. Lifecycle
// scripts are skipped because CI already runs `pnpm build` and prepack output
// would otherwise pollute stdout and break JSON parsing.

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

function parseArgs(argv) {
  const options = { out: null, cwd: process.cwd() };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--out" && argv[index + 1]) {
      options.out = argv[index + 1];
      index += 1;
      continue;
    }
    if (arg === "--cwd" && argv[index + 1]) {
      options.cwd = path.resolve(argv[index + 1]);
      index += 1;
      continue;
    }
  }
  return options;
}

function walk(rootDir) {
  /** @type {{ path: string, bytes: number }[]} */
  const files = [];
  if (!fs.existsSync(rootDir)) {
    return files;
  }
  const stack = [rootDir];
  while (stack.length > 0) {
    const current = stack.pop();
    const entries = fs.readdirSync(current, { withFileTypes: true });
    for (const entry of entries) {
      const absolute = path.join(current, entry.name);
      if (entry.isDirectory()) {
        stack.push(absolute);
      } else if (entry.isFile()) {
        const stat = fs.statSync(absolute);
        files.push({
          path: path.relative(rootDir, absolute),
          bytes: stat.size,
        });
      }
    }
  }
  files.sort((a, b) => a.path.localeCompare(b.path));
  return files;
}

function summarizeDir(rootDir, label) {
  const files = walk(rootDir);
  const totalBytes = files.reduce((sum, file) => sum + file.bytes, 0);
  return {
    label,
    rootDir: path.relative(process.cwd(), rootDir) || ".",
    exists: fs.existsSync(rootDir),
    fileCount: files.length,
    totalBytes,
    files,
  };
}

function runNpmPackDryRun(cwd) {
  const result = spawnSync(
    "npm",
    ["pack", "--dry-run", "--json", "--ignore-scripts"],
    {
      cwd,
      encoding: "utf8",
      maxBuffer: 32 * 1024 * 1024,
    }
  );
  if (result.status !== 0) {
    return {
      ok: false,
      error: (result.stderr || result.stdout || "npm pack failed").trim(),
    };
  }
  try {
    const parsed = JSON.parse(result.stdout);
    const entry = Array.isArray(parsed) ? parsed[0] : parsed;
    if (!entry) {
      return { ok: false, error: "empty npm pack output" };
    }
    return {
      ok: true,
      name: entry.name,
      version: entry.version,
      filename: entry.filename,
      unpackedSize: entry.unpackedSize ?? null,
      size: entry.size ?? null,
      fileCount: Array.isArray(entry.files) ? entry.files.length : null,
    };
  } catch (error) {
    return {
      ok: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const cwd = options.cwd;

  const targets = [
    { dir: path.join(cwd, "dist"), label: "dist" },
    { dir: path.join(cwd, "native"), label: "native" },
    { dir: path.join(cwd, "wasm/pkg"), label: "wasm/pkg" },
  ];

  const directories = targets.map((target) =>
    summarizeDir(target.dir, target.label)
  );

  const packResult = runNpmPackDryRun(cwd);

  const report = {
    cwd: path.relative(process.cwd(), cwd) || ".",
    platform: `${process.platform}-${process.arch}`,
    nodeVersion: process.version,
    measuredAt: new Date().toISOString(),
    directories,
    pack: packResult,
  };

  const serialized = `${JSON.stringify(report, null, 2)}\n`;
  if (options.out) {
    fs.writeFileSync(options.out, serialized);
  } else {
    process.stdout.write(serialized);
  }
}

main();
