import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { mkdtemp, mkdir, writeFile, readFile, stat, symlink, link, utimes, rm, realpath } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { reviewEnvelope, prepareReviewReport, maxReportBytes } from "../scripts/validate-linux-evidence.mjs";
import { noticeWriter, summaryScope } from "../scripts/inventory-summary.mjs";
import { reconcileHostReferences, hostReferenceScope } from "../scripts/linux-host-references.mjs";

const hash = (value) => createHash("sha256").update(value).digest("hex");
const encode = (value) => Buffer.from(JSON.stringify(value, null, 2) + "\n");
const context = () => ({ checkoutRevision: "a".repeat(40), githubRevision: "a".repeat(40), proposedHeadRevision: "b".repeat(40), event: "pull_request", runId: "123456", runAttempt: "1", inspectorExitCode: 2, inspectionStartedAt: String(Math.floor(Date.now() / 1000)) });
function fixture() {
  const inventory = hash("synthetic-inventory");
  const meta = (architecture) => ({ name: "lockedin-flow", declaredVersion: "0.5.0-1", architecture, declaredOsDependencies: { scope: "requirements-not-bundled-components", sha256: hash("synthetic-requirements"), recordSha256: [hash("synthetic-requirement")] } });
  const files = ["application", "pinned-model", "SBOM.cdx.json", "THIRD-PARTY-NOTICES.txt", "LICENSE.txt", "MODEL.json"].map((label) => ({ pathSha256: hash(label), type: "file", mode: 0o644, bytes: 128, sha256: label === "SBOM.cdx.json" ? inventory : hash("synthetic-" + label), elf: label === "application", componentMapping: "unresolved", verifiedResource: label }));
  return {
    schemaVersion: 1, product: "LockedIn Flow", builtSourceRevision: "a".repeat(40), target: "x86_64-unknown-linux-gnu", scope: "linux-package-payload-evidence",
    coverage: "File digests and staged-resource comparison, not component/version identification, license closure, signatures or installed-device acceptance",
    pathPolicy: "Archive names, link targets, dependency strings, tool output and host paths withheld; SHA-256 identifiers permit private reconciliation",
    sourceInventorySha256: inventory,
    unresolved: ["component-source-version-mapping", "native-license-and-notice-mapping", "package-control-scripts-and-signatures", "appimage-payload"],
    packages: [
      { format: "deb", bytes: 128, sha256: hash("synthetic-deb"), status: "payload-inspected", licenseReview: "unresolved", metadata: meta("amd64"), files },
      { format: "rpm", bytes: 128, sha256: hash("synthetic-rpm"), status: "unverified", licenseReview: "unresolved", reason: "rpm-original-payload-validation-unavailable", metadata: meta("x86_64"), files: null },
      { format: "appimage", bytes: 128, sha256: hash("synthetic-appimage"), status: "unverified", licenseReview: "unresolved", reason: "appimage-payload-reader-not-implemented", metadata: null, files: null },
    ],
  };
}
const reject = (value, ctx = context()) => assert.throws(() => reviewEnvelope(encode(value), ctx), /^Error: Linux evidence validation failed; content withheld\.$/);

test("host references bind the exact payload set without approving source or license claims", () => {
  const report = fixture();
  report.packages[0].files.push({ pathSha256: hash("synthetic-library"), sha256: hash("synthetic-elf"), bytes: 17, type: "file", mode: 0o644, elf: true, componentMapping: "unresolved" });
  const file = report.packages[0].files.at(-1);
  const reference = { sha256: file.sha256, bytes: file.bytes, binaryIdentitySha256: hash("binary"), sourceIdentitySha256: hash("source"), systemPathSha256: hash("path"), copyright: { status: "unavailable" } };
  report.hostReferences = reconcileHostReferences(report.packages, hash("database"), [reference], { runtimePaths: 1, sizeCandidates: 1, hashedElfFiles: 1, unreadableFiles: 0 });
  const result = reviewEnvelope(encode(report), context());
  assert.equal(result.disposition, "incomplete-not-release-acceptance");
  assert.equal(result.evidence.packages[0].files.at(-1).componentMapping, "unresolved");
  for (const mutate of [
    (r) => { r.hostReferences.packages[0].files[0].references[0].systemPath = "private"; },
    (r) => { r.hostReferences.packages[0].files[0].references[0].copyright = { status: "retained-text" }; },
    (r) => { r.hostReferences.packages.pop(); },
    (r) => { r.hostReferences.packages[0].files[0].references[0].sha256 = hash("modified"); },
    (r) => { r.hostReferences.packages[0].files[0].bytes++; },
  ]) { const bad = structuredClone(report); mutate(bad); reject(bad); }
  report.hostReferences = { scope: hostReferenceScope, status: "unavailable", reason: "host-reference-collection-failed" };
  assert.equal(reviewEnvelope(encode(report), context()).evidence.hostReferences.status, "unavailable");
});

test("optional summary binds inspected notice bytes without changing incomplete disposition", () => {
  const report = fixture(), writer = noticeWriter();
  writer.forComponents(["synthetic"], "Synthetic notice");
  report.inventorySummary = { scope: summaryScope, sbomSha256: report.sourceInventorySha256, ...writer.index([{ "bom-ref": "synthetic", licenses: [{ license: { id: "MIT" } }] }]) };
  const notice = report.packages[0].files.find((f) => f.verifiedResource === "THIRD-PARTY-NOTICES.txt");
  notice.sha256 = report.inventorySummary.noticesSha256; notice.bytes = report.inventorySummary.noticesBytes;
  assert.equal(reviewEnvelope(encode(report), context()).disposition, "incomplete-not-release-acceptance");
  const clone = () => structuredClone(report);
  for (const mutate of [
    (r) => { r.inventorySummary.rawText = "synthetic private"; },
    (r) => { r.inventorySummary.sbomSha256 = "f".repeat(64); },
    (r) => { r.inventorySummary.noticesSha256 = "f".repeat(64); },
    (r) => { r.inventorySummary.noticesBytes += 1; },
    (r) => { r.inventorySummary.components[0].noticeBlocks[0].offset = -1; },
    (r) => { r.inventorySummary.components[0].noticeEvidence = "approved"; },
  ]) { const r = clone(); mutate(r); reject(r); }
});

test("valid partial report retains actual checkout, distinct PR head, run and incomplete disposition", () => {
  const ctx = context(), report = fixture();
  const result = reviewEnvelope(encode(report), ctx);
  assert.deepEqual(result.execution, ctx);
  assert.deepEqual(result.evidence, report);
  assert.equal(result.disposition, "incomplete-not-release-acceptance");
  assert.equal(result.evidence.packages[1].metadata.architecture, "x86_64");
  assert.equal(result.evidence.packages[1].files, null);
  assert.ok(result.evidence.packages.every((entry) => entry.licenseReview === "unresolved"));
});

test("missing inputs and tool failures can be retained only as explicitly unverified evidence", () => {
  const report = fixture();
  report.packages[0] = { format: "deb", status: "unverified", reason: "package-input-unavailable-or-invalid", licenseReview: "unresolved" };
  report.packages[1].reason = "tool-or-payload-validation-failed";
  report.packages[1].metadata = null;
  assert.equal(reviewEnvelope(encode(report), context()).evidence.packages[0].status, "unverified");
  report.packages[0].bytes = 128; // Hash/size must be a pair.
  reject(report);
});

test("inspected RPM evidence retains unresolved release and AppImage boundaries", () => {
  const report = fixture();
  report.packages[1] = { ...structuredClone(report.packages[0]), format: "rpm", sha256: hash("synthetic-rpm") };
  report.packages[1].metadata.architecture = "x86_64";
  const reviewed = reviewEnvelope(encode(report), context());
  assert.equal(reviewed.disposition, "incomplete-not-release-acceptance");
  assert.equal(reviewed.evidence.packages[1].status, "payload-inspected");
  reject(report, { ...context(), inspectorExitCode: 0 });
  report.packages[1].files.pop();
  reject(report);
});

test("complete AppImage payload evidence permits exit zero but never release approval", () => {
  const report = fixture();
  report.packages[1] = { ...structuredClone(report.packages[0]), format: "rpm", sha256: hash("synthetic-rpm") };
  report.packages[1].metadata.architecture = "x86_64";
  report.packages[2] = { ...structuredClone(report.packages[0]), format: "appimage", metadata: null, sha256: hash("synthetic-appimage") };
  report.packages[2].files.push({ pathSha256: hash("synthetic-link"), type: "symlink", mode: 0o777, bytes: 10,
    targetSha256: hash("synthetic-target"), resolvedPathSha256: report.packages[2].files[0].pathSha256 });
  report.unresolved.pop();
  const ctx = { ...context(), inspectorExitCode: 0 };
  assert.equal(reviewEnvelope(encode(report), ctx).disposition, "incomplete-not-release-acceptance");
  reject(report); // Complete payload inspection cannot report a partial exit.
  for (const mutate of [
    (r) => r.packages[2].files.pop() && r.packages[2].files.pop(),
    (r) => { r.packages[2].files.at(-1).target = "unreviewed-path"; },
    (r) => { r.packages[2].files.at(-1).resolvedPathSha256 = hash("missing"); },
    (r) => { r.packages[2].files.at(-1).verifiedResource = "application"; },
    (r) => { r.packages[2].metadata = r.packages[0].metadata; },
    (r) => { r.packages[0].files.push(r.packages[2].files.at(-1)); },
    (r) => { r.packages[2].files[0].mode = 0o4755; },
    (r) => { r.unresolved.push("appimage-payload"); },
    (r) => { r.packages[2].licenseReview = "approved"; },
  ]) { const invalid = structuredClone(report); mutate(invalid); reject(invalid, ctx); }
});

test("AppImage failures retain only fixed diagnostics and preserve historical reports", () => {
  const report = fixture();
  Object.assign(report.packages[2], { reason: "tool-or-payload-validation-failed", failureStage: "archive-validation" });
  assert.equal(reviewEnvelope(encode(report), context()).evidence.packages[2].status, "unverified");
  report.packages[2].failureStage = "unreviewed tool output"; reject(report);
});

test("exit 1, unexpected exits and a false exit 0 never authorize a partial or stale report", () => {
  for (const inspectorExitCode of [0, 1, 3, -1, "2", null]) reject(fixture(), { ...context(), inspectorExitCode });
  for (const index of [1, 2]) {
    const report = fixture();
    report.packages[index] = { ...structuredClone(report.packages[0]), format: index === 1 ? "rpm" : "appimage" };
    reject(report);
  }
});

test("DEB diagnostic enum round-trips only on unverified DEB failures; historical reports remain valid", () => {
  const make = () => {
    const report = fixture();
    Object.assign(report.packages[0], { status: "unverified", reason: "tool-or-payload-validation-failed", metadata: null, files: null });
    return report;
  };
  assert.equal(reviewEnvelope(encode(make()), context()).evidence.packages[0].status, "unverified");
  const stages = ["identity-query", "dependency-query", "payload-read", "metadata-validation", "archive-validation", "archive-header", "archive-bounds", "archive-framing", "archive-entry-type", "archive-checksum", "archive-path", "resource-validation", "resource-model-count", "resource-model-hash", "resource-compliance-count", "resource-compliance-location", "resource-compliance-hash", "resource-application-missing", "resource-application-format", "resource-application-hash"];
  for (const stage of stages) {
    const report = make(); report.packages[0].failureStage = stage;
    const retained = reviewEnvelope(encode(report), context());
    assert.deepEqual(retained.evidence, report);
    assert.equal(retained.disposition, "incomplete-not-release-acceptance");
    reject(report, { ...context(), inspectorExitCode: 0 });
  }
  for (const value of ["raw private diagnostics", "/synthetic/private-path", "approved", "", null, 42, {}, ["archive-header"]]) {
    const report = make(); report.packages[0].failureStage = value; reject(report);
  }
  for (const index of [0, 1, 2]) {
    const report = fixture(); report.packages[index].failureStage = "archive-header"; reject(report);
  }
  const missing = make();
  missing.packages[0] = { format: "deb", status: "unverified", reason: "package-input-unavailable-or-invalid", licenseReview: "unresolved", failureStage: "archive-header" };
  reject(missing);
});

test("rejects stale source and invalid source, event, PR-head and run identities", () => {
  const changes = [
    { checkoutRevision: "c".repeat(40) }, { githubRevision: "c".repeat(40) }, { proposedHeadRevision: null },
    { event: "pull_request_target" }, { runId: "../run" }, { runId: 123 }, { runAttempt: "0" },
    { inspectionStartedAt: "yesterday" }, { extra: "unreviewed" },
  ];
  for (const change of changes) reject(fixture(), { ...context(), ...change });
  const report = fixture(); report.builtSourceRevision = "c".repeat(40); reject(report);
  const ctx = { ...context(), event: "push", proposedHeadRevision: null };
  assert.equal(reviewEnvelope(encode(fixture()), ctx).execution.proposedHeadRevision, null);
  reject(fixture(), { ...ctx, proposedHeadRevision: "b".repeat(40) });
});

test("strict key and content allowlists reject raw paths, dependencies, diagnostics and claims", () => {
  const edits = [
    (r) => { r.rawPath = "/synthetic/private-path"; },
    (r) => { r.coverage = "approved"; },
    (r) => { r.unresolved = []; },
    (r) => { r.packages[0].licenseReview = "approved"; },
    (r) => { r.packages[0].metadata.declaredVersion = "0.5.0-private-client"; },
    (r) => { r.packages[0].metadata.declaredOsDependencies.raw = "synthetic-private-dependency"; },
    (r) => { r.packages[0].files[0].path = "/synthetic/hidden"; },
    (r) => { r.packages[2].reason = "raw tool error"; },
    (r) => { r.packages[1].files = []; },
  ];
  for (const edit of edits) { const report = fixture(); edit(report); reject(report); }
});

test("rejects malformed, duplicate-key, noncanonical, non-ASCII and oversized JSON", () => {
  const valid = encode(fixture());
  for (const bytes of [Buffer.from("{"), Buffer.concat([valid, Buffer.from("tail")]), Buffer.from(valid.toString().replace('"schemaVersion": 1,', '"schemaVersion": 1,\n  "schemaVersion": 1,')), Buffer.from(JSON.stringify(fixture())), Buffer.from("é"), Buffer.alloc(maxReportBytes + 1)])
    assert.throws(() => reviewEnvelope(bytes, context()), /content withheld/);
});

test("package/file bounds, uniqueness, required resources and inventory digests fail closed", () => {
  const edits = [
    (r) => { r.packages.push(r.packages[0]); },
    (r) => { r.packages.reverse(); },
    (r) => { r.packages[0].bytes = 512 * 1024 ** 2 + 1; },
    (r) => { r.packages[0].files[0].mode = 0o4755; },
    (r) => { r.packages[0].files[0].type = "symlink"; },
    (r) => { r.packages[0].files[0].sha256 = "not-a-hash"; },
    (r) => { r.packages[0].files[1].pathSha256 = r.packages[0].files[0].pathSha256; },
    (r) => { r.packages[0].files[1].verifiedResource = "application"; },
    (r) => { r.packages[0].files[0].elf = false; },
    (r) => { r.packages[0].files[2].sha256 = hash("wrong-inventory"); },
    (r) => { r.packages[0].files.pop(); },
    (r) => { r.packages[0].files = Array(10001).fill(r.packages[0].files[0]); },
    (r) => { r.packages[0].metadata.declaredOsDependencies.recordSha256 = Array(4097).fill(hash("x")); },
  ];
  for (const edit of edits) { const report = fixture(); edit(report); reject(report); }
});

async function withFiles(run) {
  const root = await realpath(await mkdtemp(path.join(os.tmpdir(), "flow-review-json-")));
  const directory = path.join(root, "target/release/bundle");
  await mkdir(directory, { recursive: true });
  const source = path.join(directory, "LINUX-PACKAGE-EVIDENCE.json");
  const output = path.join(directory, "LINUX-PACKAGE-EVIDENCE.review.json");
  try { await run({ root, directory, source, output }); }
  finally { await rm(root, { recursive: true, force: true }); }
}

test("fixed review file is private, canonical and exclusively created; exit 1 cannot reuse it", async () => {
  await withFiles(async ({ root, source, output }) => {
    const ctx = context();
    await writeFile(source, encode(fixture()), { flag: "wx", mode: 0o600 });
    await prepareReviewReport(root, ctx);
    const bytes = await readFile(output);
    const report = JSON.parse(bytes);
    assert.equal(report.execution.inspectorExitCode, 2);
    assert.equal(report.disposition, "incomplete-not-release-acceptance");
    assert.deepEqual(bytes, encode(report));
    if (process.platform !== "win32") assert.equal((await stat(output)).mode & 0o777, 0o600);
    await assert.rejects(prepareReviewReport(root, ctx));
    await assert.rejects(prepareReviewReport(root, { ...ctx, inspectorExitCode: 1 }));
    assert.deepEqual(await readFile(output), bytes);
  });
});

test("stale mtime and changed source identity cannot produce uploadable output", async () => {
  await withFiles(async ({ root, source, output }) => {
    const ctx = context();
    await writeFile(source, encode(fixture()), { flag: "wx" });
    const previous = Number(ctx.inspectionStartedAt) - 60;
    await utimes(source, previous, previous);
    await assert.rejects(prepareReviewReport(root, ctx));
    await assert.rejects(stat(output));
  });
});

test("symlink and hardlinked input, symlink output and redirected directories cannot be uploaded", { skip: process.platform === "win32" }, async () => {
  for (const kind of ["input-link", "input-hardlink", "output-link", "directory-link"]) {
    await withFiles(async ({ root, directory, source, output }) => {
      const ctx = context();
      const target = path.join(root, "synthetic-target");
      await writeFile(target, encode(fixture()), { flag: "wx" });
      if (kind === "input-link") await symlink(target, source);
      else if (kind === "input-hardlink") await link(target, source);
      else {
        await writeFile(source, encode(fixture()), { flag: "wx" });
        if (kind === "output-link") await symlink(target, output);
        else {
          const redirected = path.join(root, "redirected");
          await mkdir(redirected);
          await writeFile(path.join(redirected, "LINUX-PACKAGE-EVIDENCE.json"), encode(fixture()));
          await rm(directory, { recursive: true });
          await symlink(redirected, directory);
        }
      }
      await assert.rejects(prepareReviewReport(root, ctx));
      assert.deepEqual(await readFile(target), encode(fixture()));
    });
  }
});

const workflowFile = fileURLToPath(new URL("../../.github/workflows/desktop.yml", import.meta.url));
function block(workflow, name) {
  const marker = "      - name: " + name + "\n";
  const start = workflow.indexOf(marker);
  assert.notEqual(start, -1);
  const next = workflow.indexOf("      - name: ", start + marker.length);
  return workflow.slice(start, next === -1 ? undefined : next);
}
function runBody(step) {
  const marker = "        run: |\n";
  assert.ok(step.includes(marker));
  return step.slice(step.indexOf(marker) + marker.length).trimEnd().split("\n").map((line) => line.slice(10)).join("\n");
}

test("workflow validates one fixed JSON immediately before pinned read-only retention and preserves the binary condition", async () => {
  const workflow = await readFile(workflowFile, "utf8");
  assert.match(workflow, /permissions:\n  contents: read\n\n/);
  assert.doesNotMatch(workflow, /pull_request_target|continue-on-error|libarchive-tools|bsdtar/);
  assert.match(workflow, /patchelf dpkg rpm espeak sox/);
  const validation = block(workflow, "Validate fixed Linux report immediately before retention");
  const upload = block(workflow, "Retain sanitized Linux JSON only (not binaries or approval)");
  assert.equal(workflow.indexOf(validation) + validation.length, workflow.indexOf(upload));
  assert.match(validation, /exit_code == '0' \|\| steps\.linux_evidence\.outputs\.exit_code == '2'/);
  assert.match(upload, /steps\.linux_review_json\.outcome == 'success'/);
  assert.match(upload, /actions\/upload-artifact@b7c566a772e6b6bfb58ed0dc250532a479d7789f/);
  assert.match(upload, /path: desktop\/target\/release\/bundle\/LINUX-PACKAGE-EVIDENCE\.review\.json\n/);
  assert.doesNotMatch(upload, /path: \||\.deb|\.rpm|\.AppImage|\.exe|\.msi|\*/);
  assert.match(upload, /if-no-files-found: error\n          include-hidden-files: false\n          overwrite: false\n          retention-days: 7/);
  const binary = block(workflow, "Upload protected-main evaluation installers only");
  assert.match(binary, /if: github\.ref == 'refs\/heads\/main' && github\.event_name != 'pull_request'\n/);
  assert.match(binary, /actions\/upload-artifact@b7c566a772e6b6bfb58ed0dc250532a479d7789f/);
  assert.ok(workflow.indexOf("Enforce Linux payload acceptance") < workflow.indexOf(binary));
});

test("isolated acceptance shell fails partial/failed/unretained evidence and passes only complete retained evidence", { skip: process.platform === "win32" }, async () => {
  const workflow = await readFile(workflowFile, "utf8");
  const script = runBody(block(workflow, "Enforce Linux payload acceptance after evidence retention"));
  for (const [code, validation, upload, expectedStatus] of [["0", "success", "success", 0], ["2", "success", "success", 1], ["1", "skipped", "skipped", 1], ["0", "failure", "skipped", 1], ["0", "success", "failure", 1]]) {
    const result = spawnSync("/bin/bash", ["--noprofile", "--norc", "-e", "-o", "pipefail", "-c", script], { encoding: "utf8", timeout: 5000, maxBuffer: 4096, env: { PATH: "/usr/bin:/bin", FLOW_INSPECTOR_EXIT: code, FLOW_REVIEW_VALIDATION: validation, FLOW_REVIEW_UPLOAD: upload } });
    assert.equal(result.status, expectedStatus);
  }
});

test("isolated collector preserves inspector exit and refuses stale report reuse", { skip: process.platform === "win32" }, async () => {
  const workflow = await readFile(workflowFile, "utf8");
  const body = runBody(block(workflow, "Collect Linux inspection evidence (not acceptance)"));
  const script = 'node() { NODE_CALLED=1; return "$SYNTHETIC_EXIT"; }\n' + body + '\nprintf "called=%s\\n" "${NODE_CALLED:-0}" >> "$GITHUB_OUTPUT"';
  for (const [code, stale, expectedCode, called] of [["0", false, "0", "1"], ["2", false, "2", "1"], ["1", false, "1", "1"], ["42", false, "1", "1"], ["2", true, "1", "0"]]) {
    await withFiles(async ({ root, source }) => {
      if (stale) await writeFile(source, "synthetic-stale-report", { flag: "wx" });
      const output = path.join(root, "synthetic-step-output");
      const result = spawnSync("/bin/bash", ["--noprofile", "--norc", "-e", "-o", "pipefail", "-c", script], { cwd: root, encoding: "utf8", timeout: 5000, maxBuffer: 4096, env: { PATH: "/usr/bin:/bin", SYNTHETIC_EXIT: code, GITHUB_OUTPUT: output } });
      assert.equal(result.status, 0); // Collection is not the acceptance gate.
      const outputs = await readFile(output, "utf8");
      assert.ok(outputs.includes(`exit_code=${expectedCode}\n`));
      assert.ok(outputs.includes(`called=${called}\n`));
      if (stale) assert.equal(await readFile(source, "utf8"), "synthetic-stale-report");
    });
  }
});
