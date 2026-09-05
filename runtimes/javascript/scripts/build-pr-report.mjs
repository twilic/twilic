#!/usr/bin/env node
// Build a Markdown report comparing benchmark and bundle artifacts between
// the PR head build and the base build.
//
// Usage:
//   node scripts/build-pr-report.mjs \
//     --pr-bench PATH --base-bench PATH \
//     --pr-bundle PATH --base-bundle PATH \
//     [--pr-label "PR (sha)"] [--base-label "main (sha)"] \
//     [--out PATH]

import fs from "node:fs";
import path from "node:path";

function parseArgs(argv) {
  const options = {
    prBench: null,
    baseBench: null,
    prBundle: null,
    baseBundle: null,
    prLabel: "PR",
    baseLabel: "base",
    out: null,
  };
  const long = {
    "--pr-bench": "prBench",
    "--base-bench": "baseBench",
    "--pr-bundle": "prBundle",
    "--base-bundle": "baseBundle",
    "--pr-label": "prLabel",
    "--base-label": "baseLabel",
    "--out": "out",
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const key = long[arg];
    if (key && argv[index + 1] !== undefined) {
      options[key] = argv[index + 1];
      index += 1;
      continue;
    }
  }
  return options;
}

function readJsonSafe(filePath) {
  if (!filePath) {
    return null;
  }
  try {
    const content = fs.readFileSync(filePath, "utf8");
    return JSON.parse(content);
  } catch (error) {
    return { __error: error instanceof Error ? error.message : String(error) };
  }
}

const BYTE_UNITS = ["B", "KiB", "MiB", "GiB"];

function formatBytes(value) {
  if (value === null || value === undefined || Number.isNaN(value)) {
    return "n/a";
  }
  const bytes = Number(value);
  if (!Number.isFinite(bytes)) {
    return "n/a";
  }
  if (bytes === 0) {
    return "0 B";
  }
  const negative = bytes < 0;
  let magnitude = Math.abs(bytes);
  let unit = 0;
  while (magnitude >= 1024 && unit < BYTE_UNITS.length - 1) {
    magnitude /= 1024;
    unit += 1;
  }
  const formatted =
    unit === 0
      ? `${Math.round(magnitude).toLocaleString()} ${BYTE_UNITS[unit]}`
      : `${magnitude.toFixed(magnitude >= 100 ? 1 : 2)} ${BYTE_UNITS[unit]}`;
  return negative ? `-${formatted}` : formatted;
}

function formatSignedBytes(diff) {
  if (diff === null || diff === undefined || Number.isNaN(diff)) {
    return "n/a";
  }
  if (diff === 0) {
    return "0 B";
  }
  const sign = diff > 0 ? "+" : "-";
  return `${sign}${formatBytes(Math.abs(diff))}`;
}

function formatPercent(ratio, { signed = true } = {}) {
  if (ratio === null || ratio === undefined || !Number.isFinite(ratio)) {
    return "n/a";
  }
  const percent = ratio * 100;
  if (signed) {
    if (percent === 0) return "0.00%";
    const sign = percent > 0 ? "+" : "";
    return `${sign}${percent.toFixed(2)}%`;
  }
  return `${percent.toFixed(2)}%`;
}

function formatOps(value) {
  if (value === null || value === undefined || !Number.isFinite(value)) {
    return "n/a";
  }
  return Math.round(value).toLocaleString();
}

function buildBenchTable(prBench, baseBench, prLabel, baseLabel) {
  if (!prBench && !baseBench) {
    return "_(bench data unavailable)_";
  }
  const prTasks = new Map();
  const baseTasks = new Map();
  for (const task of prBench?.tasks ?? []) {
    prTasks.set(task.name, task);
  }
  for (const task of baseBench?.tasks ?? []) {
    baseTasks.set(task.name, task);
  }

  const names = Array.from(new Set([...prTasks.keys(), ...baseTasks.keys()]));
  names.sort((a, b) => {
    const aHz = prTasks.get(a)?.hz ?? baseTasks.get(a)?.hz ?? 0;
    const bHz = prTasks.get(b)?.hz ?? baseTasks.get(b)?.hz ?? 0;
    return bHz - aHz;
  });

  const lines = [];
  lines.push(
    `| task | ${escapeCell(baseLabel)} ops/s | ${escapeCell(prLabel)} ops/s | diff ops/s | diff % |`
  );
  lines.push("| --- | ---: | ---: | ---: | ---: |");

  for (const name of names) {
    const baseHz = baseTasks.get(name)?.hz ?? null;
    const prHz = prTasks.get(name)?.hz ?? null;
    const delta =
      baseHz !== null && prHz !== null && Number.isFinite(baseHz)
        ? prHz - baseHz
        : null;
    const ratio =
      baseHz && baseHz > 0 && prHz !== null ? (prHz - baseHz) / baseHz : null;
    lines.push(
      `| ${escapeCell(name)} | ${formatOps(baseHz)} | ${formatOps(prHz)} | ${formatSignedOps(delta)} | ${formatPercent(ratio)} |`
    );
  }
  return lines.join("\n");
}

function formatSignedOps(value) {
  if (value === null || value === undefined || !Number.isFinite(value)) {
    return "n/a";
  }
  const sign = value > 0 ? "+" : value < 0 ? "-" : "";
  return `${sign}${Math.round(Math.abs(value)).toLocaleString()}`;
}

function buildSizesTable(prBench, baseBench, prLabel, baseLabel) {
  if (!prBench && !baseBench) {
    return null;
  }
  const baseRows = new Map();
  for (const row of baseBench?.sizes ?? []) {
    baseRows.set(row.payload, row);
  }
  const prRows = new Map();
  for (const row of prBench?.sizes ?? []) {
    prRows.set(row.payload, row);
  }
  const names = Array.from(new Set([...prRows.keys(), ...baseRows.keys()]));
  if (names.length === 0) {
    return null;
  }
  const lines = [];
  lines.push(
    `| payload | ${escapeCell(baseLabel)} | ${escapeCell(prLabel)} | diff bytes | diff % |`
  );
  lines.push("| --- | ---: | ---: | ---: | ---: |");
  for (const name of names) {
    const base = baseRows.get(name)?.twilic ?? null;
    const pr = prRows.get(name)?.twilic ?? null;
    const delta = base !== null && pr !== null ? pr - base : null;
    const ratio = base && base > 0 && pr !== null ? (pr - base) / base : null;
    lines.push(
      `| ${escapeCell(name)} | ${formatBytes(base)} | ${formatBytes(pr)} | ${formatSignedBytes(delta)} | ${formatPercent(ratio)} |`
    );
  }
  return lines.join("\n");
}

function totalBytesByLabel(bundle) {
  /** @type {Map<string, number>} */
  const map = new Map();
  if (!bundle || !Array.isArray(bundle.directories)) {
    return map;
  }
  for (const dir of bundle.directories) {
    if (dir && typeof dir.label === "string") {
      map.set(dir.label, Number(dir.totalBytes ?? 0));
    }
  }
  return map;
}

function buildBundleDirTable(prBundle, baseBundle, prLabel, baseLabel) {
  const baseMap = totalBytesByLabel(baseBundle);
  const prMap = totalBytesByLabel(prBundle);
  const labels = Array.from(new Set([...baseMap.keys(), ...prMap.keys()]));
  if (labels.length === 0) {
    return "_(bundle directories unavailable)_";
  }
  labels.sort();
  const lines = [];
  lines.push(
    `| directory | ${escapeCell(baseLabel)} | ${escapeCell(prLabel)} | diff bytes | diff % |`
  );
  lines.push("| --- | ---: | ---: | ---: | ---: |");
  for (const label of labels) {
    const base = baseMap.has(label) ? baseMap.get(label) : null;
    const pr = prMap.has(label) ? prMap.get(label) : null;
    const delta = base !== null && pr !== null ? pr - base : null;
    const ratio = base && base > 0 && pr !== null ? (pr - base) / base : null;
    lines.push(
      `| \`${label}\` | ${formatBytes(base)} | ${formatBytes(pr)} | ${formatSignedBytes(delta)} | ${formatPercent(ratio)} |`
    );
  }
  return lines.join("\n");
}

function buildPackTable(prBundle, baseBundle, prLabel, baseLabel) {
  const basePack = baseBundle?.pack;
  const prPack = prBundle?.pack;
  if (!basePack && !prPack) {
    return null;
  }
  const rows = [];
  const baseSize = basePack?.ok ? Number(basePack.size ?? 0) : null;
  const baseUnpacked = basePack?.ok ? Number(basePack.unpackedSize ?? 0) : null;
  const baseFiles = basePack?.ok ? Number(basePack.fileCount ?? 0) : null;
  const prSize = prPack?.ok ? Number(prPack.size ?? 0) : null;
  const prUnpacked = prPack?.ok ? Number(prPack.unpackedSize ?? 0) : null;
  const prFiles = prPack?.ok ? Number(prPack.fileCount ?? 0) : null;

  rows.push(
    sizeRow(
      "tarball size",
      baseSize,
      prSize,
      "bytes",
      formatBytes,
      formatSignedBytes
    )
  );
  rows.push(
    sizeRow(
      "unpacked size",
      baseUnpacked,
      prUnpacked,
      "bytes",
      formatBytes,
      formatSignedBytes
    )
  );
  rows.push(
    sizeRow(
      "file count",
      baseFiles,
      prFiles,
      "files",
      (value) =>
        value === null || value === undefined
          ? "n/a"
          : Number(value).toLocaleString(),
      (value) => {
        if (value === null || value === undefined || Number.isNaN(value)) {
          return "n/a";
        }
        if (value === 0) return "0";
        const sign = value > 0 ? "+" : "-";
        return `${sign}${Math.abs(value).toLocaleString()}`;
      }
    )
  );

  const lines = [];
  lines.push(
    `| metric | ${escapeCell(baseLabel)} | ${escapeCell(prLabel)} | diff | diff % |`
  );
  lines.push("| --- | ---: | ---: | ---: | ---: |");
  for (const row of rows) {
    lines.push(row);
  }

  const notes = [];
  if (basePack && !basePack.ok) {
    notes.push(`${baseLabel} \`npm pack\` failed: \`${basePack.error}\``);
  }
  if (prPack && !prPack.ok) {
    notes.push(`${prLabel} \`npm pack\` failed: \`${prPack.error}\``);
  }

  if (notes.length > 0) {
    lines.push("");
    for (const note of notes) {
      lines.push(`> ${note}`);
    }
  }

  return lines.join("\n");
}

function sizeRow(metric, baseValue, prValue, _unit, formatValue, formatDelta) {
  const delta =
    baseValue !== null && prValue !== null && Number.isFinite(baseValue)
      ? prValue - baseValue
      : null;
  const ratio =
    baseValue && baseValue > 0 && prValue !== null
      ? (prValue - baseValue) / baseValue
      : null;
  return `| ${metric} | ${formatValue(baseValue)} | ${formatValue(prValue)} | ${formatDelta(delta)} | ${formatPercent(ratio)} |`;
}

function escapeCell(value) {
  return String(value).replace(/\|/g, "\\|").replace(/\r?\n/g, " ");
}

function buildErrorNotes(
  prBench,
  baseBench,
  prBundle,
  baseBundle,
  prLabel,
  baseLabel
) {
  const notes = [];
  for (const [name, value] of [
    [`${prLabel} bench`, prBench],
    [`${baseLabel} bench`, baseBench],
    [`${prLabel} bundle`, prBundle],
    [`${baseLabel} bundle`, baseBundle],
  ]) {
    if (value && value.__error) {
      notes.push(`failed to read ${name} report: \`${value.__error}\``);
    }
  }
  return notes;
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const prBench = readJsonSafe(options.prBench);
  const baseBench = readJsonSafe(options.baseBench);
  const prBundle = readJsonSafe(options.prBundle);
  const baseBundle = readJsonSafe(options.baseBundle);

  const errorNotes = buildErrorNotes(
    prBench,
    baseBench,
    prBundle,
    baseBundle,
    options.prLabel,
    options.baseLabel
  );

  const prLabel = options.prLabel;
  const baseLabel = options.baseLabel;

  const lines = [];

  if (errorNotes.length > 0) {
    lines.push("> [!warning]");
    for (const note of errorNotes) {
      lines.push(`> ${note}`);
    }
    lines.push("");
  }

  lines.push("## Bundle size (build directories)");
  lines.push("");
  lines.push(buildBundleDirTable(prBundle, baseBundle, prLabel, baseLabel));
  lines.push("");

  const packTable = buildPackTable(prBundle, baseBundle, prLabel, baseLabel);
  if (packTable) {
    lines.push("## npm pack (dry run)");
    lines.push("");
    lines.push(packTable);
    lines.push("");
  }

  lines.push(`## Benchmark throughput (sorted by ${baseLabel} ops/s)`);
  lines.push("");
  lines.push("<details>");
  lines.push("<summary>Click to expand benchmark task comparison</summary>");
  lines.push("");
  lines.push(buildBenchTable(prBench, baseBench, prLabel, baseLabel));
  lines.push("");
  lines.push("</details>");
  lines.push("");

  const sizesTable = buildSizesTable(prBench, baseBench, prLabel, baseLabel);
  if (sizesTable) {
    lines.push("## Encoded payload size (twilic only)");
    lines.push("");
    lines.push(sizesTable);
    lines.push("");
  }

  lines.push("---");
  lines.push(
    "Higher ops/s is better, lower bytes is better. diff % > 0 means the PR value is larger than base."
  );

  const text = lines.join("\n") + "\n";
  if (options.out) {
    fs.mkdirSync(path.dirname(path.resolve(options.out)), { recursive: true });
    fs.writeFileSync(options.out, text);
  } else {
    process.stdout.write(text);
  }
}

main();
