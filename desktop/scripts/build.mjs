#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import os from "node:os";
import { linkerPrivacyFlags, sourcePathMappings, nativeCompilerEnvironment } from "./build-path-privacy.mjs";
import { loadToolManifest, prepareLinuxPackagingTools } from "./linux-packaging-tools.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const cli = path.join(root, "node_modules", "@tauri-apps", "cli", "tauri.js");
let env = { ...process.env };
const buildArgs = process.argv.slice(2);
const targetIndex = buildArgs.indexOf("--target");
const target = targetIndex >= 0 ? buildArgs[targetIndex + 1] : undefined;
if (targetIndex >= 0 && !target) throw new Error("A build target is required.");
const mappings = [
  [path.dirname(root), "/lockedin-flow"],
  [env.CARGO_HOME ?? path.join(os.homedir(), ".cargo"), "/cargo"],
  [env.RUSTUP_HOME ?? path.join(os.homedir(), ".rustup"), "/rustup"],
];
const rustFlags =
  env.CARGO_ENCODED_RUSTFLAGS?.split("\u001f") ??
  env.RUSTFLAGS?.split(/\s+/).filter(Boolean) ??
  [];
env.CARGO_ENCODED_RUSTFLAGS = [
  ...rustFlags,
  ...linkerPrivacyFlags(process.platform),
  ...sourcePathMappings(mappings, process.platform).map(([from, to]) => `--remap-path-prefix=${from}=${to}`),
].join("\u001f");
env = nativeCompilerEnvironment(env, mappings, process.platform);
for (const script of ["provision-model.mjs", "generate-inventory.mjs"]) {
  const arguments_ =
    script === "provision-model.mjs" ? ["--verify"] : target ? [target] : [];
  const prerequisite = spawnSync(
    process.execPath,
    [path.join(root, "scripts", script), ...arguments_],
    { cwd: root, env, stdio: "inherit", shell: false },
  );
  if (prerequisite.status !== 0) process.exit(prerequisite.status ?? 1);
}
if (process.platform === "darwin") {
  env.MACOSX_DEPLOYMENT_TARGET = "13.0";
  env.CMAKE_OSX_DEPLOYMENT_TARGET = "13.0";
}
let tools;
try {
  const toolConfig = [];
  if (process.platform === "linux") {
    if (process.arch !== "x64" || (target && target !== "x86_64-unknown-linux-gnu")) {
      throw new Error("Unsupported Linux packaging target.");
    }
    const installedCLI = JSON.parse(readFileSync(path.join(root, "node_modules/@tauri-apps/cli/package.json"), "utf8"));
    if (installedCLI.version !== loadToolManifest().tauriCliVersion) throw new Error("Unpinned packager version.");
    tools = await prepareLinuxPackagingTools();
    env.XDG_CACHE_HOME = tools.cache;
    // Last config wins: do not let a pre-existing local tools directory bypass
    // the verified, fresh XDG cache. Other platforms keep their current path.
    toolConfig.push("--config", JSON.stringify({ bundle: { useLocalToolsDir: false } }));
    console.log("Pinned Linux packaging tools verified in an isolated build cache.");
  }
  const result = spawnSync(
    process.execPath,
    [cli, "build", "--config", "app/tauri.conf.json", ...buildArgs, ...toolConfig, "--", "--locked"],
    { cwd: root, env, stdio: "inherit", shell: false },
  );
  if (tools) await tools.verify();
  process.exitCode = result.status ?? 1;
  if (tools && process.exitCode === 0) console.log("Pinned Linux packaging tool bytes verified after the build.");
} catch {
  console.error("Desktop build failed. Check the pinned tool inputs and supported native target privately; no tool fallback was accepted.");
  process.exitCode = 1;
} finally {
  if (tools) {
    try { await tools.cleanup(); }
    catch { console.error("Temporary packaging cache cleanup failed; inspect the build host privately."); process.exitCode = 1; }
  }
}
