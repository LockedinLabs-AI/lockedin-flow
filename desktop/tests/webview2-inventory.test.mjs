import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { packagingEvidence, verifiedWebviewInput, webviewBuildInputs } from "../scripts/webview2-inventory.mjs";

const syntheticDirectory = 'C:\\synthetic-cache\\00000000-0000-4000-8000-000000000001';
const file = syntheticDirectory + "\\MicrosoftEdgeWebView2RuntimeInstallerX64.exe";
const nsis = `!define INSTALLWEBVIEW2MODE "offlineInstaller"\r\n!define WEBVIEW2INSTALLERPATH "${file}"\r\n`;
const wix = `<Binary Id="MicrosoftEdgeWebView2RuntimeInstaller.exe" SourceFile="${file}"/>`;
const bytes = Buffer.alloc(1024);
bytes.write("MZ");
const facts = {
  bytes: bytes.length, sha256: createHash("sha256").update(bytes).digest("hex"),
  fileVersion: "1.2.3.4", publisher: "Microsoft Corporation", signatureStatus: "Valid",
  signerThumbprint: "b".repeat(40), timestampThumbprint: "c".repeat(40),
};

test("pinned Windows templates identify explicit offline installer inputs", () => {
  assert.deepEqual(webviewBuildInputs(nsis, wix), { nsis: file, msi: file });
  assert.deepEqual(webviewBuildInputs(nsis.replace("synthetic-cache", "synthetic&cache"), wix.replace("synthetic-cache", "synthetic&amp;cache")), {
    nsis: file.replace("synthetic-cache", "synthetic&cache"), msi: file.replace("synthetic-cache", "synthetic&cache"),
  });
});

test("unknown, ambiguous, remote, and network-bootstrapper inputs are rejected", () => {
  for (const [nsi, xml] of [
    [nsis.replace("offlineInstaller", "downloadBootstrapper"), wix],
    [nsis + nsis, wix], [nsis, wix + wix], [nsis, "<!DOCTYPE x>" + wix],
    [nsis, wix.replace("synthetic-cache", "&unknown;")],
    [nsis.replace("C:\\synthetic-cache", "\\\\network\\cache"), wix],
    [nsis.replace("synthetic-cache", "synthetic-cache\\.."), wix],
    [nsis.replace("synthetic-cache", "$TEMP"), wix],
    [nsis.replace("X64.exe", "X86.exe"), wix],
  ]) assert.throws(() => webviewBuildInputs(nsi, xml));
});

test("runtime input records are bound to exact bytes and timestamped Microsoft signatures", () => {
  const verified = verifiedWebviewInput(bytes, { ...facts, privatePath: file });
  assert.equal(verified.sha256, facts.sha256);
  assert.equal(verified.installerFileVersion, "1.2.3.4");
  assert.equal(JSON.stringify(verified).includes(syntheticDirectory), false);
  for (const invalid of [
    { sha256: "0".repeat(64) }, { bytes: 1 }, { signatureStatus: "NotSigned" },
    { publisher: "Other Publisher" }, { timestampThumbprint: "" },
    { signerThumbprint: "" }, { fileVersion: "private-metadata" },
  ]) assert.throws(() => verifiedWebviewInput(bytes, { ...facts, ...invalid }));
  assert.throws(() => verifiedWebviewInput(Buffer.alloc(1024), facts));
});

test("sidecar binds both final installers and refuses runtime drift between formats", () => {
  const input = verifiedWebviewInput(bytes, facts);
  const installers = ["LockedIn Flow_0.5.0-alpha.1_x64-setup.exe", "LockedIn Flow_0.5.0-alpha.1_x64_en-US.msi"].map((filename) => ({ filename, bytes: 2048, sha256: "d".repeat(64) }));
  const result = packagingEvidence("a".repeat(40), [input, input], installers);
  assert.equal(result.scope, "verified-installer-build-inputs");
  assert.equal(result.redistributionReview, "required-before-production-release");
  assert.match(result.coverage, /not extracted-payload proof/);
  assert.throws(() => packagingEvidence("a".repeat(40), [input, { ...input, sha256: "e".repeat(64) }], installers));
  assert.throws(() => packagingEvidence("a".repeat(40), [input, input], [installers[0], installers[0]]));
  assert.throws(() => packagingEvidence("a".repeat(40), [input, input], [{ ...installers[0], filename: file }, installers[1]]));
});

test("the signature probe cannot execute payloads or change trust and precedes installation", () => {
  const probe = readFileSync(new URL("../scripts/inspect-windows-signature.ps1", import.meta.url), "utf8");
  assert.match(probe, /Get-AuthenticodeSignature -LiteralPath/);
  assert.match(probe, /TimeStamperCertificate/);
  assert.match(probe, /O=Microsoft Corporation/);
  assert.doesNotMatch(probe, /Start-Process|Invoke-Expression|Invoke-WebRequest|ExecutionPolicy|Import-Certificate/);
  const workflow = readFileSync(new URL("../../.github/workflows/desktop.yml", import.meta.url), "utf8");
  assert.ok(workflow.indexOf("node scripts/verify-windows-prerequisites.mjs") < workflow.indexOf("./scripts/test-windows-installers.ps1"));
  assert.ok(workflow.includes("desktop/target/release/bundle/WINDOWS-PACKAGING-INPUTS.json"));
});

test("native signature probe parses on Windows and redacts missing-file errors", { skip: process.platform !== "win32" }, () => {
  const probe = fileURLToPath(new URL("../scripts/inspect-windows-signature.ps1", import.meta.url));
  const result = spawnSync("powershell.exe", ["-NoProfile", "-NonInteractive", "-File", probe, "-InputFile", "synthetic-missing-signature-input.exe"], { encoding: "utf8" });
  assert.equal(result.status, 1);
  assert.equal(result.stdout.trim(), "");
  assert.match(result.stderr, /signature inspection failed; details withheld/);
  assert.equal(result.stderr.includes("synthetic-missing-signature-input"), false);
});
