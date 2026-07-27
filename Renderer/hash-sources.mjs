import { createHash } from "node:crypto";
import { readFileSync, writeFileSync, readdirSync } from "node:fs";
import path from "node:path";

const srcDir = "src";
const files = readdirSync(srcDir).sort();
const hash = createHash("sha256");
for (const name of files) {
  hash.update(name);
  hash.update(readFileSync(path.join(srcDir, name)));
}
const digest = hash.digest("hex");
writeFileSync("../Sources/diffscope-app/Renderer/SOURCE_HASH", digest + "\n");
console.log("source hash", digest.slice(0, 16), "over", files.join(", "));
