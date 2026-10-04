#!/usr/bin/env node
import { constants } from "node:fs";
import { open, realpath, writeFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { validateInventorySummary } from "./inventory-summary.mjs";
import { validateHostReferences } from "./linux-host-references.mjs";

export const maxReportBytes = 16 * 1024 ** 2;
const sha = /^[a-f0-9]{64}$/;
const commit = /^[a-f0-9]{40}$/;
const fail = () => { throw new Error("Linux evidence validation failed; content withheld."); };
const plain = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
function keys(value, required, optional = []) {
  if (!plain(value) || required.some((key) => !Object.hasOwn(value, key))
      || Object.keys(value).some((key) => !required.includes(key) && !optional.includes(key))) fail();
}
const integer = (value, min, max) => { if (!Number.isSafeInteger(value) || value < min || value > max) fail(); };
const hash = (value) => { if (typeof value !== "string" || !sha.test(value)) fail(); };
const equal = (actual, expected) => { if (actual !== expected) fail(); };

function metadata(value, format) {
  keys(value, ["name", "declaredVersion", "architecture", "declaredOsDependencies"]);
  if (!["lockedin-flow", "locked-in-flow", "lockedin-flow-desktop", "locked-in-flow-desktop"].includes(value.name)
      || typeof value.declaredVersion !== "string"
      || !/^\d{1,5}\.\d{1,5}\.\d{1,5}(?:[~+-](?:alpha|beta|rc)\.\d{1,5})?(?:-\d{1,5})?$/.test(value.declaredVersion)) fail();
  equal(value.architecture, format === "deb" ? "amd64" : "x86_64");
  const deps = value.declaredOsDependencies;
  keys(deps, ["scope", "sha256", "recordSha256"]);
  equal(deps.scope, "requirements-not-bundled-components");
  hash(deps.sha256);
  if (!Array.isArray(deps.recordSha256) || deps.recordSha256.length > 4096) fail();
  deps.recordSha256.forEach(hash);
}

function files(entries, inventoryHash, format) {
  if (!Array.isArray(entries) || entries.length < 6 || entries.length > 10000) fail();
  const paths = new Set(), resources = new Set();
  const labels = ["application", "pinned-model", "SBOM.cdx.json", "THIRD-PARTY-NOTICES.txt", "LICENSE.txt", "MODEL.json"];
  for (const file of entries) {
    const base = ["pathSha256", "type", "mode", "bytes"];
    if (file?.type === "directory") {
      keys(file, base);
      equal(file.bytes, 0);
    } else if (file?.type === "symlink" && format === "appimage") {
      keys(file, [...base, "targetSha256", "resolvedPathSha256"]);
      hash(file.targetSha256); hash(file.resolvedPathSha256);
      integer(file.bytes, 1, 256);
    } else {
      keys(file, [...base, "sha256", "elf", "componentMapping"], ["verifiedResource"]);
      equal(file.type, "file");
      hash(file.sha256);
      if (typeof file.elf !== "boolean") fail();
      equal(file.componentMapping, "unresolved");
      if (Object.hasOwn(file, "verifiedResource")) {
        if (!labels.includes(file.verifiedResource) || resources.has(file.verifiedResource)) fail();
        resources.add(file.verifiedResource);
        if (file.verifiedResource === "application" && !file.elf) fail();
        if (file.verifiedResource === "SBOM.cdx.json") equal(file.sha256, inventoryHash);
      }
    }
    hash(file.pathSha256);
    if (paths.has(file.pathSha256)) fail();
    paths.add(file.pathSha256);
    integer(file.mode, 0, 0o777);
    integer(file.bytes, 0, 256 * 1024 ** 2);
  }
  const destinations = new Set(entries.filter((entry) => entry.type !== "symlink").map((entry) => entry.pathSha256));
  for (const file of entries.filter((entry) => entry.type === "symlink")) if (!destinations.has(file.resolvedPathSha256)) fail();
  if (resources.size !== labels.length) fail();
}

function packageRecord(value, expectedFormat, inventoryHash) {
  if (value?.status === "payload-inspected") {
    keys(value, ["format", "bytes", "sha256", "status", "licenseReview", "metadata", "files"]);
    if (expectedFormat === "appimage") equal(value.metadata, null);
    else metadata(value.metadata, expectedFormat);
    files(value.files, inventoryHash, expectedFormat);
  } else {
    const base = ["format", "status", "reason", "licenseReview"];
    equal(value?.status, "unverified");
    if (value.reason === "package-input-unavailable-or-invalid") {
      keys(value, base, ["bytes", "sha256"]);
      if (Object.hasOwn(value, "bytes") !== Object.hasOwn(value, "sha256")) fail();
    } else {
      keys(value, [...base, "bytes", "sha256", "metadata", "files"], ["deb", "appimage"].includes(expectedFormat) && value.reason === "tool-or-payload-validation-failed" ? ["failureStage"] : []);
      if (Object.hasOwn(value, "failureStage") && !["identity-query", "dependency-query", "payload-read", "metadata-validation", "archive-validation", "archive-header", "archive-bounds", "archive-framing", "archive-entry-type", "archive-checksum", "archive-path", "resource-validation", "resource-model-count", "resource-model-hash", "resource-compliance-count", "resource-compliance-location", "resource-compliance-hash", "resource-application-missing", "resource-application-format", "resource-application-hash"].includes(value.failureStage)) fail();
      equal(value.files, null);
      if (value.reason === "rpm-original-payload-validation-unavailable") {
        equal(expectedFormat, "rpm");
        metadata(value.metadata, "rpm");
      } else {
        equal(value.metadata, null);
        if (value.reason !== "tool-or-payload-validation-failed"
            && !(expectedFormat === "appimage" && value.reason === "appimage-payload-reader-not-implemented")) fail();
      }
    }
  }
  equal(value.format, expectedFormat);
  equal(value.licenseReview, "unresolved");
  if (Object.hasOwn(value, "sha256")) {
    hash(value.sha256);
    integer(value.bytes, 1, 512 * 1024 ** 2);
  }
}

export function reviewEnvelope(bytes, context) {
  if (!Buffer.isBuffer(bytes) || bytes.length < 1 || bytes.length > maxReportBytes || bytes.some((byte) => byte > 127)) fail();
  const text = bytes.toString("utf8");
  let report;
  try { report = JSON.parse(text); } catch { fail(); }
  // The producer uses this exact canonical serialization. Reject duplicate keys,
  // hidden ignored fields, alternate encodings and trailing data before upload.
  if (JSON.stringify(report, null, 2) + "\n" !== text) fail();
  keys(context, ["checkoutRevision", "githubRevision", "proposedHeadRevision", "event", "runId", "runAttempt", "inspectorExitCode", "inspectionStartedAt"]);
  if (typeof context.checkoutRevision !== "string" || !commit.test(context.checkoutRevision) || context.githubRevision !== context.checkoutRevision
      || !["pull_request", "push", "workflow_dispatch"].includes(context.event)
      || typeof context.runId !== "string" || !/^[1-9]\d{0,19}$/.test(context.runId)
      || typeof context.runAttempt !== "string" || !/^[1-9]\d{0,5}$/.test(context.runAttempt)
      || typeof context.inspectionStartedAt !== "string" || !/^[1-9]\d{9,12}$/.test(context.inspectionStartedAt)) fail();
  if (context.event === "pull_request" ? typeof context.proposedHeadRevision !== "string" || !commit.test(context.proposedHeadRevision) : context.proposedHeadRevision !== null) fail();
  if (![0, 2].includes(context.inspectorExitCode)) fail(); // Exit 1 never authorizes a stale report.
  keys(report, ["schemaVersion", "product", "builtSourceRevision", "target", "scope", "coverage", "pathPolicy", "sourceInventorySha256", "unresolved", "packages"], ["inventorySummary", "hostReferences"]);
  equal(report.schemaVersion, 1);
  equal(report.product, "LockedIn Flow");
  equal(report.builtSourceRevision, context.checkoutRevision);
  equal(report.target, "x86_64-unknown-linux-gnu");
  equal(report.scope, "linux-package-payload-evidence");
  equal(report.coverage, "File digests and staged-resource comparison, not component/version identification, license closure, signatures or installed-device acceptance");
  equal(report.pathPolicy, "Archive names, link targets, dependency strings, tool output and host paths withheld; SHA-256 identifiers permit private reconciliation");
  hash(report.sourceInventorySha256);
  const unresolved = ["component-source-version-mapping", "native-license-and-notice-mapping", "package-control-scripts-and-signatures"];
  if (report.packages?.[2]?.status !== "payload-inspected") unresolved.push("appimage-payload");
  equal(JSON.stringify(report.unresolved), JSON.stringify(unresolved));
  if (!Array.isArray(report.packages) || report.packages.length !== 3) fail();
  ["deb", "rpm", "appimage"].forEach((format, index) => packageRecord(report.packages[index], format, report.sourceInventorySha256));
  if (Object.hasOwn(report, "hostReferences")) {
    try { validateHostReferences(report.hostReferences, report.packages); } catch { fail(); }
  }
  if (Object.hasOwn(report, "inventorySummary")) {
    try { validateInventorySummary(report.inventorySummary, report.sourceInventorySha256); } catch { fail(); }
    for (const pkg of report.packages.filter((p) => p.status === "payload-inspected")) {
      const notice = pkg.files.find((f) => f.verifiedResource === "THIRD-PARTY-NOTICES.txt");
      equal(notice.sha256, report.inventorySummary.noticesSha256);
      equal(notice.bytes, report.inventorySummary.noticesBytes);
    }
  }
  const partial = report.packages.some((entry) => entry.status === "unverified");
  equal(context.inspectorExitCode, partial ? 2 : 0);
  return {
    schemaVersion: 1, product: "LockedIn Flow", disposition: "incomplete-not-release-acceptance",
    execution: { ...context }, evidence: report,
  };
}

// The CLI fixes root and context. Exported for synthetic filesystem tests only;
// callers cannot supply an upload filename or bypass schema validation.
export async function prepareReviewReport(root, context) {
  const source = path.join(root, "target/release/bundle/LINUX-PACKAGE-EVIDENCE.json");
  const destination = path.join(root, "target/release/bundle/LINUX-PACKAGE-EVIDENCE.review.json");
  if (await realpath(source) !== source || await realpath(path.dirname(destination)) !== path.dirname(destination)) fail();
  const handle = await open(source, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  let bytes;
  try {
    const stat = await handle.stat();
    if (!stat.isFile() || stat.nlink !== 1 || stat.size < 1 || stat.size > maxReportBytes) fail();
    const buffer = Buffer.alloc(stat.size + 1);
    let used = 0;
    while (used < buffer.length) {
      const { bytesRead } = await handle.read(buffer, used, buffer.length - used, used);
      if (!bytesRead) break;
      used += bytesRead;
    }
    const after = await handle.stat();
    if (used !== stat.size || after.size !== stat.size || after.mtimeMs !== stat.mtimeMs) fail();
    if (typeof context.inspectionStartedAt !== "string" || !/^[1-9]\d{9,12}$/.test(context.inspectionStartedAt)
        || stat.mtimeMs < Number(context.inspectionStartedAt) * 1000 || stat.mtimeMs > Date.now() + 2000) fail();
    bytes = buffer.subarray(0, used);
  } finally { await handle.close(); }
  const envelope = reviewEnvelope(bytes, context);
  const output = JSON.stringify(envelope, null, 2) + "\n";
  if (Buffer.byteLength(output) > maxReportBytes) fail();
  await writeFile(destination, output, { flag: "wx", mode: 0o600 });
}

async function main() {
  if (process.argv.length !== 2 || process.platform !== "linux" || process.env.GITHUB_ACTIONS !== "true") fail();
  const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const checkoutRevision = execFileSync("/usr/bin/git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8", maxBuffer: 4096, timeout: 5000, stdio: ["ignore", "pipe", "pipe"] }).trim();
  if (!["0", "2"].includes(process.env.FLOW_INSPECTOR_EXIT)) fail();
  await prepareReviewReport(root, {
    checkoutRevision, githubRevision: process.env.GITHUB_SHA,
    proposedHeadRevision: process.env.FLOW_PR_HEAD_SHA || null,
    event: process.env.GITHUB_EVENT_NAME, runId: process.env.GITHUB_RUN_ID,
    runAttempt: process.env.GITHUB_RUN_ATTEMPT,
    inspectorExitCode: Number(process.env.FLOW_INSPECTOR_EXIT),
    inspectionStartedAt: process.env.FLOW_INSPECTION_STARTED_AT,
  });
  console.log("Sanitized review JSON prepared; this does not establish release acceptance.");
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  main().catch(() => {
    console.error("Linux review report rejected; no upload authorized. Content and diagnostics withheld.");
    process.exitCode = 1;
  });
}
