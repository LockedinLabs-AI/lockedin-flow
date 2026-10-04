#!/usr/bin/env node
import { lstat, realpath, mkdtemp, readdir, writeFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { digest, linuxApplicationDigest, inspectPackage, limits, standardTool, verifyBuildIdentity, boundedFile } from "./linux-package-evidence.mjs";
import { verifiedInventorySummary } from "./inventory-summary.mjs";
import { collectHostReferences, hostReferenceScope } from "./linux-host-references.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const resourceLimit = 16 * 1024 ** 2;

async function main() {
  if (process.platform !== "linux" || process.argv.length !== 2) throw new Error();
  const git = (...args) => standardTool("/usr/bin/git", ["-C", root, ...args]).toString("utf8").trim();
  const revision = git("rev-parse", "HEAD");
  if (!/^[a-f0-9]{40}$/.test(revision) || git("status", "--porcelain", "--untracked-files=all")) throw new Error();
  const expected = {};
  let sbom;
  const inventoryBytes = {};
  for (const label of ["SBOM.cdx.json", "THIRD-PARTY-NOTICES.txt", "LICENSE.txt", "MODEL.json"]) {
    const bytes = await boundedFile(path.join(root, "app/resources/compliance", label), resourceLimit);
    expected[label] = digest(bytes);
    inventoryBytes[label] = bytes;
    if (label === "SBOM.cdx.json") sbom = JSON.parse(bytes);
  }
  verifyBuildIdentity(sbom, revision,
    digest(await boundedFile(path.join(root, "Cargo.lock"), resourceLimit)),
    digest(await boundedFile(path.join(root, "package-lock.json"), resourceLimit)));
  const inventorySummary = verifiedInventorySummary(inventoryBytes["SBOM.cdx.json"], inventoryBytes["THIRD-PARTY-NOTICES.txt"], {
    sbomSha256: expected["SBOM.cdx.json"], noticesSha256: expected["THIRD-PARTY-NOTICES.txt"],
  });
  const model = JSON.parse(await boundedFile(path.join(root, "models.json"), resourceLimit));
  if (model.file !== "ggml-base.en.bin" || !/^[a-f0-9]{64}$/.test(model.sha256)) throw new Error();
  expected.model = model.sha256;
  const application = await boundedFile(path.join(root, "target/release/lockedin-flow-desktop"), limits.file);
  const applicationDigests = Object.fromEntries(["deb", "rpm"].map((format) => [format, linuxApplicationDigest(application, format)]));
  const bundle = path.join(root, "target/release/bundle");
  // Reject redirected output directories; never write through a build-tree link.
  if (await realpath(bundle) !== bundle || !(await lstat(bundle)).isDirectory()) throw new Error();
  const report = {
    schemaVersion: 1, product: "LockedIn Flow", builtSourceRevision: revision,
    target: "x86_64-unknown-linux-gnu", scope: "linux-package-payload-evidence",
    coverage: "File digests and staged-resource comparison, not component/version identification, license closure, signatures or installed-device acceptance",
    pathPolicy: "Archive names, link targets, dependency strings, tool output and host paths withheld; SHA-256 identifiers permit private reconciliation",
    sourceInventorySha256: expected["SBOM.cdx.json"],
    unresolved: ["component-source-version-mapping", "native-license-and-notice-mapping", "package-control-scripts-and-signatures"],
    packages: [],
  };
  if (inventorySummary) report.inventorySummary = inventorySummary;
  const scratch = await mkdtemp(path.join(os.tmpdir(), "flow-package-evidence-"));
  try {
    for (const [format, extension] of [["deb", ".deb"], ["rpm", ".rpm"], ["appimage", ".AppImage"]]) {
      let record = { format, status: "unverified", reason: "package-input-unavailable-or-invalid", licenseReview: "unresolved" };
      try {
        const directory = path.join(bundle, format);
        if (await realpath(directory) !== directory) throw new Error();
        const candidates = (await readdir(directory, { withFileTypes: true })).filter((entry) => entry.name.endsWith(extension));
        if (candidates.length !== 1 || !candidates[0].isFile()) throw new Error();
        const bytes = await boundedFile(path.join(directory, candidates[0].name), limits.package);
        record = { ...record, bytes: bytes.length, sha256: digest(bytes) };
        if (format === "appimage") {
          // linuxdeploy can patch/strip ELF after Tauri's APP token replacement.
          // Bind to its separately staged output; never normalize package bytes.
          const reference = path.join(directory, "LockedIn Flow.AppDir/usr/bin/lockedin-flow-desktop");
          if (await realpath(reference) !== reference) throw new Error();
          const staged = await boundedFile(reference, limits.file);
          if (!staged.subarray(0, 4).equals(Buffer.from([127, 69, 76, 70]))) throw new Error();
          applicationDigests.appimage = digest(staged);
        }
        const snapshot = path.join(scratch, "input" + extension);
        await writeFile(snapshot, bytes, { flag: "wx", mode: 0o600 });
        record = inspectPackage(format, snapshot, bytes, { ...expected, application: applicationDigests[format] });
      } catch { /* Fixed classification only; do not expose file paths/tool errors. */ }
      report.packages.push(record);
    }
    if (report.packages[2].status !== "payload-inspected") report.unresolved.push("appimage-payload");
    try {
      report.hostReferences = await collectHostReferences(report.packages);
    } catch {
      report.hostReferences = { scope: hostReferenceScope, status: "unavailable", reason: "host-reference-collection-failed" };
    }
    // Exclusive creation preserves an earlier receipt instead of overwriting it.
    await writeFile(path.join(bundle, "LINUX-PACKAGE-EVIDENCE.json"), JSON.stringify(report, null, 2) + "\n", { flag: "wx", mode: 0o600 });
  } finally { await rm(scratch, { recursive: true, force: true }); }
  const complete = report.packages.every((entry) => entry.status === "payload-inspected");
  console.log(complete ? "Linux payload inspection recorded; component and license review remains unresolved." : "Partial Linux evidence recorded; one or more package payloads remain unverified.");
  process.exitCode = complete ? 0 : 2;
}

main().catch(() => {
  console.error("Linux package evidence could not be recorded; check the clean source, staged resources, native tools and output location privately.");
  process.exitCode = 1;
});
