// Explicit build-time inputs only. Never imported by the installed application.
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { chmod, lstat, mkdir, mkdtemp, realpath, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { boundedFile } from "./linux-package-evidence.mjs";

const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
const fail = () => { throw new Error("Pinned Linux packaging tools rejected; input details withheld."); };
const maximum = 64 * 1024 ** 2;
const expected = [
  ["AppRun-x86_64", "https://github.com/tauri-apps/binary-releases/releases/download/apprun-old/AppRun-x86_64", "none"],
  ["linuxdeploy-07333c6-x86_64.AppImage", "https://github.com/tauri-apps/binary-releases/releases/download/linuxdeploy-07333c6/linuxdeploy-x86_64.AppImage", "zero-appimage-magic"],
  ["linuxdeploy-plugin-appimage.AppImage", "https://github.com/linuxdeploy/linuxdeploy-plugin-appimage/releases/download/continuous/linuxdeploy-plugin-appimage-x86_64.AppImage", "none"],
];
const keys = (value, fields) => {
  if (!value || typeof value !== "object" || Array.isArray(value)
      || Object.keys(value).length !== fields.length || fields.some((key) => !Object.hasOwn(value, key))) fail();
};

export function validateToolManifest(manifest) {
  keys(manifest, ["schemaVersion", "target", "tauriCliVersion", "upstreamBundlerRevision", "tools"]);
  if (manifest.schemaVersion !== 1 || manifest.target !== "x86_64-unknown-linux-gnu"
      || manifest.tauriCliVersion !== "2.12.0" || manifest.upstreamBundlerRevision !== "447fa9f3f993fe77724189e355078b38ce20baea"
      || !Array.isArray(manifest.tools) || manifest.tools.length !== expected.length) fail();
  manifest.tools.forEach((tool, n) => {
    keys(tool, ["file", "assetId", "url", "bytes", "sha256", "mutation"]);
    if (tool.file !== expected[n][0] || tool.url !== expected[n][1] || tool.mutation !== expected[n][2]
        || !Number.isSafeInteger(tool.assetId) || tool.assetId < 1
        || !Number.isSafeInteger(tool.bytes) || tool.bytes < 64 || tool.bytes > maximum
        || !/^[a-f0-9]{64}$/.test(tool.sha256)) fail();
  });
  return manifest;
}

export function loadToolManifest() {
  return validateToolManifest(JSON.parse(readFileSync(new URL("../linux-packaging-tools.json", import.meta.url), "utf8")));
}

export function toolExecutionBytes(bytes, tool) {
  if (!Buffer.isBuffer(bytes) || bytes.length < 64 || bytes.length !== tool.bytes || hash(bytes) !== tool.sha256
      || !bytes.subarray(0, 7).equals(Buffer.from([127, 69, 76, 70, 2, 1, 1]))
      || bytes.readUInt16LE(18) !== 62) fail();
  const result = Buffer.from(bytes);
  if (tool.mutation === "zero-appimage-magic") {
    // Pinned Tauri applies this exact dd write before launch. Apply it only
    // AFTER verifying the original download, and retain a separate final hash.
    if (!bytes.subarray(8, 11).equals(Buffer.from([65, 73, 2]))) fail();
    result.fill(0, 8, 11);
  } else if (tool.mutation !== "none") fail();
  return result;
}

export async function downloadTool(tool, fetchImpl = fetch) {
  let url = new URL(tool.url);
  const signal = AbortSignal.timeout(120000);
  for (let redirects = 0; redirects <= 5; redirects++) {
    if (url.protocol !== "https:" || url.username || url.password || url.hash
        || (url.port && url.port !== "443")
        || !["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].includes(url.hostname)) fail();
    let response;
    try {
      response = await fetchImpl(url, { redirect: "manual", signal, credentials: "omit" });
      if ([301, 302, 303, 307, 308].includes(response.status)) {
        const next = response.headers.get("location");
        await response.body?.cancel();
        if (!next) fail();
        url = new URL(next, url);
        continue;
      }
      if (response.status !== 200 || !response.body) fail();
      const declared = response.headers.get("content-length");
      if (declared !== null && declared !== String(tool.bytes)) fail();
      const chunks = []; let count = 0;
      for await (const chunk of response.body) {
        count += chunk.length;
        if (count > tool.bytes || count > maximum) fail();
        chunks.push(Buffer.from(chunk));
      }
      const bytes = Buffer.concat(chunks, count);
      toolExecutionBytes(bytes, tool); // Complete size, digest and ELF checks.
      return bytes;
    } catch {
      try { await response?.body?.cancel(); } catch { /* Already consumed. */ }
      fail(); // Never expose signed redirect queries or network diagnostics.
    }
  }
  fail();
}

export async function prepareLinuxPackagingTools({ manifest = loadToolManifest(), fetchImpl = fetch, temporaryRoot = os.tmpdir() } = {}) {
  validateToolManifest(manifest);
  let cache;
  try {
    const parent = await realpath(temporaryRoot);
    cache = await mkdtemp(path.join(parent, "flow-appimage-tools-"));
  } catch { fail(); }
  const directory = path.join(cache, "tauri"), staged = [];
  const assertCache = async () => {
    if (!(await lstat(cache)).isDirectory() || await realpath(cache) !== cache) fail();
  };
  const cleanup = async () => {
    try {
      await assertCache();
      // Only the freshly created, exact owned cache; never the user's cache.
      await rm(cache, { recursive: true });
    } catch { fail(); }
  };
  try {
    await mkdir(directory, { mode: 0o700 });
    for (const tool of manifest.tools) {
      const original = await downloadTool(tool, fetchImpl);
      const executable = toolExecutionBytes(original, tool);
      // AppRun is copied into the final package with its permissions intact.
      // Keep it executable for installed users; the enclosing cache is private.
      await writeFile(path.join(directory, tool.file), executable, { flag: "wx", mode: 0o755 });
      await chmod(path.join(directory, tool.file), 0o755);
      staged.push({ file: tool.file, bytes: executable.length, sha256: hash(executable) });
    }
    const verify = async () => {
      await assertCache();
      const cacheStat = await lstat(cache), directoryStat = await lstat(directory);
      if ((cacheStat.mode & 0o077) !== 0 || !directoryStat.isDirectory()
          || (directoryStat.mode & 0o077) !== 0 || await realpath(directory) !== directory) fail();
      for (const tool of staged) {
        const location = path.join(directory, tool.file), stat = await lstat(location);
        if (!stat.isFile() || stat.nlink !== 1 || (stat.mode & 0o7777) !== 0o755 || stat.size !== tool.bytes
            || hash(await boundedFile(location, maximum)) !== tool.sha256) fail();
      }
    };
    await verify();
    return { cache, verify, cleanup };
  } catch {
    await cleanup();
    fail();
  }
}
