#!/usr/bin/env node
// Explicit build-time network utility, never imported by the application.
import { createHash, randomUUID } from "node:crypto";
import { createReadStream, createWriteStream } from "node:fs";
import { lstat, mkdir, rm } from "node:fs/promises";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { pipeline } from "node:stream/promises";
import { Transform, Readable } from "node:stream";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const model = JSON.parse(readFileSync(path.join(root, "models.json"), "utf8"));
const directory = path.join(root, "app", "resources", "models");
const target = path.join(directory, model.file);
const args = process.argv.slice(2);
if (args.length !== 1 || !["--download", "--verify"].includes(args[0])) {
  console.error(
    "Usage: node desktop/scripts/provision-model.mjs --download|--verify",
  );
  process.exit(64);
}

async function verify(file) {
  const stat = await lstat(file);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size !== model.size)
    throw new Error("Unexpected model size or file type.");
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(file)) hash.update(chunk);
  if (hash.digest("hex") !== model.sha256)
    throw new Error("Model integrity verification failed.");
}

async function download() {
  try {
    await verify(target);
    console.log("Bundled model already verified.");
    return;
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  await mkdir(directory, { recursive: true });
  const partial = path.join(directory, `${model.file}.${randomUUID()}.partial`);
  try {
    let url = new URL(model.url);
    let response;
    for (let redirects = 0; redirects <= 5; redirects++) {
      if (
        url.protocol !== "https:" ||
        url.username ||
        url.password ||
        !["huggingface.co", "hf.co", "xethub.hf.co"].some(
          (host) => url.hostname === host || url.hostname.endsWith(`.${host}`),
        )
      )
        throw new Error("Unapproved model download origin.");
      response = await fetch(url, {
        redirect: "manual",
        signal: AbortSignal.timeout(120_000),
      });
      if (![301, 302, 303, 307, 308].includes(response.status)) break;
      const location = response.headers.get("location");
      await response.body?.cancel();
      if (!location) throw new Error("Missing redirect destination.");
      url = new URL(location, url);
    }
    if (!response?.ok || !response.body)
      throw new Error("Model download failed.");
    let size = 0;
    const limit = new Transform({
      transform(chunk, encoding, callback) {
        size += chunk.length;
        callback(
          size > model.size
            ? new Error("Model download exceeded the pinned size.")
            : null,
          chunk,
        );
      },
    });
    await pipeline(
      Readable.fromWeb(response.body),
      limit,
      createWriteStream(partial, { flags: "wx", mode: 0o600 }),
    );
    await verify(partial);
    // Never replace an existing model: a concurrent provisioner must verify its own result.
    const { link } = await import("node:fs/promises");
    await link(partial, target);
    console.log("Bundled model downloaded and SHA-256 verified.");
  } finally {
    await rm(partial, { force: true });
  }
}

try {
  if (args[0] === "--download") await download();
  else {
    await verify(target);
    console.log("Bundled model SHA-256 verified.");
  }
} catch {
  console.error(
    "Model provisioning failed. The existing model was not replaced. Check the reviewed source and local file integrity.",
  );
  process.exit(1);
}
