import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const packageJsonPath = path.resolve(__dirname, "..", "package.json");
const packageJson = JSON.parse(readFileSync(packageJsonPath, "utf8"));

const tag = process.env.GITHUB_REF_NAME || process.argv[2];
if (!tag) {
  throw new Error("tag is required (set GITHUB_REF_NAME or pass tag as arg)");
}

const normalizedTag = tag.startsWith("v") ? tag.slice(1) : tag;
if (normalizedTag !== packageJson.version) {
  throw new Error(
    `tag/version mismatch: tag=${tag} package.json version=${packageJson.version}`
  );
}
