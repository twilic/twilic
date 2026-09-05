import { mkdir, copyFile, readdir, unlink } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const root = path.resolve(__dirname, "..");
const targetDir = path.join(root, "native");
const platformKey = `${process.platform}-${process.arch}`;
const targetFile = path.join(targetDir, `twilic_napi-${platformKey}.node`);

const cargoTargetDir = process.env.CARGO_TARGET_DIR
  ? path.resolve(process.env.CARGO_TARGET_DIR)
  : path.join(root, "target");
const sourceFile = resolveSourceBinary(path.join(cargoTargetDir, "release"));

await mkdir(targetDir, { recursive: true });
await copyFile(sourceFile, targetFile);
await pruneLegacyNativeAddons(targetDir);

async function pruneLegacyNativeAddons(dir) {
  const entries = await readdir(dir, { withFileTypes: true });
  for (const entry of entries) {
    if (!entry.isFile() || !entry.name.endsWith(".node")) {
      continue;
    }
    if (!entry.name.startsWith("twilic_napi-")) {
      await unlink(path.join(dir, entry.name));
    }
  }
}

function resolveSourceBinary(releaseDir) {
  if (process.platform === "darwin") {
    return path.join(releaseDir, "libtwilic_napi.dylib");
  }
  if (process.platform === "linux") {
    return path.join(releaseDir, "libtwilic_napi.so");
  }
  if (process.platform === "win32") {
    return path.join(releaseDir, "twilic_napi.dll");
  }
  throw new Error(`unsupported platform: ${process.platform}`);
}
