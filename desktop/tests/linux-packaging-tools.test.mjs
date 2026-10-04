import assert from "node:assert/strict";
import test from "node:test";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { mkdtemp, readdir, readFile, writeFile, rm, symlink, chmod, lstat, realpath } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { loadToolManifest, validateToolManifest, toolExecutionBytes, downloadTool, prepareLinuxPackagingTools } from "../scripts/linux-packaging-tools.mjs";

const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
const elf = () => {
  const bytes = Buffer.alloc(96, 17);
  Buffer.from([127, 69, 76, 70, 2, 1, 1]).copy(bytes);
  Buffer.from([65, 73, 2]).copy(bytes, 8);
  bytes.writeUInt16LE(62, 18);
  return bytes;
};
const synthetic = () => {
  const manifest = structuredClone(loadToolManifest()), bytes = elf();
  for (const tool of manifest.tools) Object.assign(tool, { bytes: bytes.length, sha256: hash(bytes) });
  return { manifest, bytes, fetchImpl: async () => new Response(bytes, { headers: { "content-length": String(bytes.length) } }) };
};
const localCache = { skip: process.platform === "win32" }; // POSIX cache permissions; production is Linux-only.

test("AppImage tool manifest matches the pinned CLI and exact allowed asset set", () => {
  const manifest = loadToolManifest();
  const pkg = JSON.parse(readFileSync(new URL("../package.json", import.meta.url)));
  assert.equal(manifest.tauriCliVersion, pkg.devDependencies["@tauri-apps/cli"]);
  assert.equal(new Set(manifest.tools.map(t => t.assetId)).size, 3);
  for (const change of [m => m.tools.reverse(), m => m.tools.pop(), m => m.tools[0].file = "../outside",
    m => m.tools[0].url += "?token=synthetic", m => m.tools[0].bytes = 2 ** 30,
    m => m.tools[0].sha256 = "unknown", m => m.tools[0].mutation = "none-or-other",
    m => m.tools[0].assetId = -1, m => m.tauriCliVersion = "next", m => m.extra = true]) {
    const changed = structuredClone(manifest); change(changed);
    assert.throws(() => validateToolManifest(changed), /input details withheld/);
  }
});

test("linuxdeploy mutation is exactly bytes eight through ten after original hash verification", () => {
  const {manifest, bytes} = synthetic();
  const tool = manifest.tools[1], original = Buffer.from(bytes), result = toolExecutionBytes(bytes, tool);
  assert.deepEqual(bytes, original);
  assert.deepEqual(result.subarray(0, 8), bytes.subarray(0, 8));
  assert.deepEqual(result.subarray(8, 11), Buffer.alloc(3));
  assert.deepEqual(result.subarray(11), bytes.subarray(11));
  assert.notEqual(hash(result), tool.sha256);
  assert.throws(() => toolExecutionBytes(result, tool)); // Already mutated input is not the pinned download.
  assert.deepEqual(toolExecutionBytes(bytes, manifest.tools[0]), bytes);
  const invalid = Buffer.from(bytes); invalid[8] = 0;
  assert.throws(() => toolExecutionBytes(invalid, {...tool, sha256: hash(invalid)}));
  const wrongMachine = Buffer.from(bytes); wrongMachine.writeUInt16LE(183, 18);
  assert.throws(() => toolExecutionBytes(wrongMachine, {...tool, sha256: hash(wrongMachine)}));
});

test("download verifies complete bytes and permits only bounded approved HTTPS redirects", async () => {
  const {manifest, bytes} = synthetic(), calls = [];
  const result = await downloadTool(manifest.tools[0], async (url, options) => {
    calls.push(url.hostname);
    assert.equal(options.redirect, "manual"); assert.equal(options.credentials, "omit");
    assert.ok(options.signal);
    return calls.length === 1 ? new Response(null, {status:302, headers:{location:"https://release-assets.githubusercontent.com/synthetic"}}) : new Response(bytes);
  });
  assert.deepEqual(result, bytes);
  assert.deepEqual(calls, ["github.com", "release-assets.githubusercontent.com"]);
  const credentialURL = new URL("https://github.com/synthetic");
  credentialURL.username = "synthetic"; credentialURL.password = "test-only";
  for (const destination of ["http://github.com/synthetic", "https://github.com:444/synthetic", "https://github.com.evil.test/synthetic",
    credentialURL.href, "https://127.0.0.1/synthetic", "https://github.com/synthetic#fragment"]) {
    let count = 0;
    await assert.rejects(downloadTool(manifest.tools[0], async () => {
      count++; return new Response(null, {status:302, headers:{location:destination}});
    }), /input details withheld/);
    assert.equal(count, 1);
  }
  let loops = 0;
  await assert.rejects(downloadTool(manifest.tools[0], async () => { loops++; return new Response(null, {status:302, headers:{location:manifest.tools[0].url}}); }));
  assert.equal(loops, 6);
});

test("download rejects altered, truncated, oversized and failed responses with no raw errors", async () => {
  const {manifest, bytes} = synthetic(), changed = Buffer.from(bytes); changed[70] ^= 1;
  for (const response of [() => new Response(changed), () => new Response(bytes.subarray(1)),
    () => new Response(Buffer.concat([bytes, Buffer.from([0])])), () => new Response(bytes, {status:206}),
    () => new Response(bytes, {headers:{"content-length":"123"}}), () => new Response(null, {status:302}),
    () => { throw new Error("signed-private-redirect-or-token"); }]) {
    await assert.rejects(downloadTool(manifest.tools[0], response), e => e.message === "Pinned Linux packaging tools rejected; input details withheld.");
  }
});

test("fresh cache is complete before use, verifies mutation, and removes only its own directory", localCache, async () => {
  const parent = await mkdtemp(path.join(os.tmpdir(), "flow-tool-test-"));
  try {
    await writeFile(path.join(parent, "preserve.txt"), "synthetic unrelated data");
    const fixture = synthetic(), tools = await prepareLinuxPackagingTools({...fixture, temporaryRoot:parent});
    assert.ok(tools.cache.startsWith(await realpath(parent) + path.sep));
    const names = (await readdir(path.join(tools.cache, "tauri"))).sort();
    assert.deepEqual(names, fixture.manifest.tools.map(t => t.file).sort());
    for (const tool of fixture.manifest.tools) assert.deepEqual(await readFile(path.join(tools.cache, "tauri", tool.file)), toolExecutionBytes(fixture.bytes, tool));
    assert.equal((await lstat(tools.cache)).mode & 0o777, 0o700);
    // Tauri copies AppRun with these permissions; owner-only mode would make
    // a root-owned SquashFS entry unexecutable for ordinary installed users.
    assert.equal((await lstat(path.join(tools.cache, "tauri", "AppRun-x86_64"))).mode & 0o777, 0o755);
    await tools.verify(); await tools.cleanup();
    assert.deepEqual(await readdir(parent), ["preserve.txt"]);
  } finally { await rm(parent, {recursive:true}); }
});

test("partial provisioning never returns a cache or falls back to older tools", localCache, async () => {
  const parent = await mkdtemp(path.join(os.tmpdir(), "flow-tool-test-"));
  try {
    const fixture = synthetic(); let count = 0;
    await assert.rejects(prepareLinuxPackagingTools({...fixture, temporaryRoot:parent, fetchImpl:async () => {
      if (++count === 2) throw new Error("synthetic network failure");
      return new Response(fixture.bytes);
    }}), /input details withheld/);
    assert.deepEqual(await readdir(parent), []);
  } finally { await rm(parent, {recursive:true}); }
});

test("post-build verification rejects mutated tools, unsafe permissions and symlink substitution", localCache, async () => {
  for (const tamper of [
    async file => { await writeFile(file, "synthetic tampering"); },
    async file => { await chmod(file, 0o777); },
    async file => { await rm(file); await symlink("missing", file); },
  ]) {
    const tools = await prepareLinuxPackagingTools(synthetic());
    try {
      await tamper(path.join(tools.cache, "tauri", "AppRun-x86_64"));
      await assert.rejects(tools.verify());
    } finally { await tools.cleanup(); }
  }
});

test("build entry point verifies isolated Linux tools around the native build and cleans up", () => {
  const source = readFileSync(new URL("../scripts/build.mjs", import.meta.url), "utf8");
  const before = source.indexOf("tools = await prepareLinuxPackagingTools()"), build = source.indexOf("const result = spawnSync(");
  assert.ok(before > 0 && before < build);
  assert.ok(source.indexOf("if (tools) await tools.verify();") > build);
  assert.match(source, /env\.XDG_CACHE_HOME = tools\.cache/);
  assert.match(source, /useLocalToolsDir: false/);
  assert.match(source, /\.\.\.buildArgs, \.\.\.toolConfig, "--", "--locked"/);
  assert.match(source, /finally \{\s*if \(tools\) \{\s*try \{ await tools\.cleanup\(\)/);
  assert.match(source, /process\.platform === "linux"/);
});
