import { readFile } from "node:fs/promises";

async function loadConfig(path: string) {
  const raw = await readFile(path, "utf8");
  return JSON.parse(raw) as Record<string, unknown>;
}

const DEFAULT_TIMEOUT_MS = 5_000;

function withTimeout<T>(work: Promise<T>, ms = DEFAULT_TIMEOUT_MS) {
  return Promise.race([work, delay(ms).then(() => null)]);
}
