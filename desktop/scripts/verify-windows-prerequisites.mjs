#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, lstatSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { packagingEvidence, verifiedWebviewInput, webviewBuildInputs } from "./webview2-inventory.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
let stage = "invocation";
try {
  if (process.platform !== "win32" || process.argv.length !== 2) throw new Error("Unsupported invocation.");
  const output = path.join(root, "target/release/bundle/WINDOWS-PACKAGING-INPUTS.json");
  if (existsSync(output)) throw new Error("Use a fresh packaging output; never reuse a previous acceptance report.");
  const run = (program, args) => execFileSync(program, args, { cwd: root, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: 120000 });
  stage = "generated installer input parsing";
  const input = webviewBuildInputs(
    readFileSync(path.join(root, "target/release/nsis/x64/installer.nsi"), "utf8"),
    readFileSync(path.join(root, "target/release/wix/x64/main.wxs"), "utf8"),
  );
  const payloads = Object.values(input).map((file) => {
    stage = "prerequisite file validation";
    const stat = lstatSync(file);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 512 * 1024 * 1024) throw new Error("Unexpected payload.");
    stage = "native Microsoft signature inspection";
    const facts = JSON.parse(run("powershell.exe", ["-NoProfile", "-NonInteractive", "-File", path.join(root, "scripts/inspect-windows-signature.ps1"), "-InputFile", file]));
    stage = "prerequisite identity cross-check";
    return verifiedWebviewInput(readFileSync(file), facts);
  });
  stage = "final installer hashing";
  const installers = ["nsis", "msi"].map((format) => {
    const directory = path.join(root, "target/release/bundle", format);
    const files = readdirSync(directory).filter((file) => file.endsWith(format === "msi" ? ".msi" : "-setup.exe"));
    if (files.length !== 1) throw new Error("Unexpected installer count.");
    const file = path.join(directory, files[0]);
    const stat = lstatSync(file);
    if (!stat.isFile() || stat.isSymbolicLink()) throw new Error("Unexpected installer.");
    const bytes = readFileSync(file);
    return { filename: files[0], bytes: bytes.length, sha256: createHash("sha256").update(bytes).digest("hex") };
  });
  stage = "source and paired-input verification";
  if (run("git", ["status", "--porcelain", "--untracked-files=all"]).trim()) throw new Error("Dirty source.");
  const report = packagingEvidence(run("git", ["rev-parse", "HEAD"]).trim(), payloads, installers);
  // Sidecar only: do not mutate the already packaged application's embedded SBOM.
  stage = "exclusive report creation";
  writeFileSync(output, JSON.stringify(report, null, 2) + "\n", { flag: "wx" });
  console.log("Verified matching Microsoft-signed offline WebView2 inputs; recorded input identity and final NSIS/MSI hashes.");
} catch {
  console.error(`Windows prerequisite verification failed at ${stage}. No new report produced; do not reuse prior reports. Inspect native build inputs privately.`);
  process.exitCode = 1;
}
