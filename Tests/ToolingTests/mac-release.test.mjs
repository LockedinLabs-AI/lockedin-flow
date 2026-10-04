import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { acceptedNotarization, MacReleaseError, packageMacRelease, parseOptions, verifyBundleLayout } from "../../scripts/lib/mac-release.mjs";

const source = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const commit = "a".repeat(40);
const identity = "B".repeat(40);
const team = "TESTTEAM00";
const submission = "00000000-0000-4000-8000-000000000001";
const digest = (text) => createHash("sha256").update(text).digest("hex");
const info = {
  CFBundleName: "LockedIn Flow", CFBundleDisplayName: "LockedIn Flow",
  CFBundleExecutable: "LockedInFlow", CFBundleIdentifier: "ai.lockedin.flow.community",
  CFBundleShortVersionString: "0.4.17", CFBundleVersion: "19", LockedInReleaseStage: "release-candidate",
};

function fixture(t, settings = {}) {
  const work = realpathSync(mkdtempSync(path.join(os.tmpdir(), "lockedin-release-test-")));
  t.after(() => rmSync(work, { recursive: true, force: true }));
  const root = path.join(work, "source");
  mkdirSync(path.join(root, "security"), { recursive: true });
  for (const file of ["Package.resolved", "security/model-artifacts.tsv", "security/model-sources.tsv"]) writeFileSync(path.join(root, file), "synthetic");
  const options = parseOptions(["--commit", commit, "--identity", identity, "--team", team,
    "--notary-profile", "synthetic-profile", "--output", path.join(work, "output")]);
  const calls = [];
  let statuses = 0;
  const run = async (program, args, environment) => {
    calls.push({ program, args });
    if (settings.throwAt?.(program, args)) throw new Error("synthetic-private-tool-detail");
    let stdout = "";
    if (program === "git") {
      if (args[0] === "rev-parse") stdout = settings.head ?? commit;
      if (args[0] === "status") stdout = ++statuses > 1 ? (settings.modifiedDuringBuild ?? "") : (settings.dirty ?? "");
      if (args[0] === "ls-remote") stdout = `${settings.main ?? commit}\trefs/heads/main`;
    } else if (program === "/usr/bin/security") {
      stdout = `  1) ${identity} "${settings.identityKind ?? "Developer ID Application"}: Synthetic Publisher (${settings.identityTeam ?? team})"`;
    } else if (program.endsWith("/package-app.sh")) {
      const app = path.join(environment.env.LOCKEDIN_PACKAGE_OUTPUT_DIR, "LockedIn Flow.app");
      mkdirSync(path.join(app, "Contents/MacOS"), { recursive: true });
      mkdirSync(path.join(app, "Contents/Resources"), { recursive: true });
      writeFileSync(path.join(app, "Contents/MacOS/LockedInFlow"), Buffer.from("cffaedfe", "hex"), { mode: 0o755 });
      writeFileSync(path.join(app, "Contents/Resources/SBOM.cdx.json"), "{}");
      const lines = [`source-revision: ${settings.provenanceCommit ?? commit}`, "source-state: clean",
        `package-resolved-sha256: ${digest("synthetic")}`, `sbom-sha256: ${digest("{}")}`,
        `model-artifacts-sha256: ${digest("synthetic")}`, `model-sources-sha256: ${digest("synthetic")}`];
      writeFileSync(path.join(app, "Contents/Resources/BUILD-PROVENANCE.txt"), lines.join("\n"));
    } else if (program === "/usr/bin/plutil") {
      stdout = JSON.stringify(args.at(-1).endsWith("entitlements.plist")
        ? (settings.entitlements ?? { "com.apple.security.device.audio-input": true })
        : args.at(-1).startsWith(root) ? Object.fromEntries(Object.entries(info).reverse())
        : { ...info, ...settings.appMetadata });
    } else if (program === "/usr/bin/lipo") {
      stdout = settings.architecture ?? "arm64";
    } else if (program === "/usr/bin/codesign" && args[0] === "--display") {
      stdout = settings.signature ?? `flags=0x10000(runtime)\nTimestamp=synthetic\nTeamIdentifier=${team}`;
    } else if (program === "/usr/bin/xcrun" && args[0] === "notarytool") {
      stdout = JSON.stringify(args[1] === "submit"
        ? { id: submission, status: settings.notaryStatus ?? "Accepted" }
        : { jobId: submission, status: "Accepted", issues: settings.issues ?? null });
    } else if (program === "/usr/bin/ditto" && args[0] === "--noextattr") {
      cpSync(args.at(-2), args.at(-1), { recursive: true });
    } else if (program === "/usr/bin/hdiutil" && args[0] === "create") {
      writeFileSync(args.at(-1), "synthetic-disk-image");
    }
    return { stdout, stderr: "" };
  };
  const invoke = () => packageMacRelease(options, { root, run, platform: "darwin", progress: () => {} });
  return { root, work, options, calls, invoke };
}

test("release help is side-effect-free and malformed options never run tools", () => {
  const command = path.join(source, "scripts/package-mac-release.mjs");
  const help = spawnSync(process.execPath, [command, "--help"], { encoding: "utf8" });
  assert.equal(help.status, 0);
  assert.match(help.stdout, /Never installs/);
  assert.throws(() => parseOptions(["--password", "synthetic"]), /Unknown/);
  assert.throws(() => parseOptions(["--identity", "-", "--commit", commit]), /fingerprint/);
  assert.throws(() => parseOptions(["--commit", commit, "--commit", commit]), /duplicate/);
});

for (const [label, settings, message] of [
  ["dirty source", { dirty: " M synthetic.txt" }, /clean source/],
  ["wrong HEAD", { head: "c".repeat(40) }, /approved source/],
  ["unmerged commit", { main: "c".repeat(40) }, /protected corporate main/],
  ["wrong certificate kind", { identityKind: "Apple Development" }, /identity and team/],
  ["wrong team", { identityTeam: "OTHERTEAM0" }, /identity and team/],
]) {
  test(`preflight rejects ${label} before any build, signature, or output creation`, async (t) => {
    const f = fixture(t, settings);
    await assert.rejects(f.invoke(), message);
    assert.equal(existsSync(f.options.output), false);
    assert.equal(f.calls.some(({ program }) => program.endsWith("package-app.sh") || program.endsWith("codesign") || program.endsWith("xcrun")), false);
  });
}

test("check-only reads preflight state but creates no output and never signs", async (t) => {
  const f = fixture(t);
  f.options.checkOnly = true;
  assert.deepEqual(await f.invoke(), { checkOnly: true });
  assert.equal(existsSync(f.options.output), false);
  assert.equal(f.calls.some(({ program }) => program.endsWith("package-app.sh") || program.endsWith("codesign") || program.endsWith("xcrun")), false);
});

test("existing output is retained and source-contained output is rejected", async (t) => {
  const f = fixture(t);
  mkdirSync(f.options.output);
  const marker = path.join(f.options.output, "keep.txt");
  writeFileSync(marker, "keep");
  await assert.rejects(f.invoke(), /already exists/);
  assert.equal(readFileSync(marker, "utf8"), "keep");
  f.options.output = path.join(f.root, "new-artifacts");
  await assert.rejects(f.invoke(), /outside the source/);
  assert.equal(existsSync(f.options.output), false);
});

for (const [label, settings, message] of [
  ["source mutation", { modifiedDuringBuild: " M synthetic.txt" }, /clean source/],
  ["provenance mismatch", { provenanceCommit: "c".repeat(40) }, /provenance/],
  ["extra permission", { entitlements: { "com.apple.security.device.audio-input": true, extra: true } }, /entitlements/],
  ["wrong architecture", { architecture: "x86_64" }, /arm64/],
  ["changed packaged metadata", { appMetadata: { CFBundleDisplayName: "Wrong Name" } }, /metadata differs/],
  ["missing hardened runtime", { signature: `Timestamp=synthetic\nTeamIdentifier=${team}` }, /hardened runtime/],
  ["rejected notarization", { notaryStatus: "Invalid" }, /not accepted/],
  ["notarization warnings", { issues: [{ severity: "warning", message: "synthetic" }] }, /issues requiring review/],
]) {
  test(`${label} stops packaging without a success manifest`, async (t) => {
    const f = fixture(t, settings);
    await assert.rejects(f.invoke(), message);
    assert.equal(existsSync(path.join(f.options.output, "release-evidence.json")), false);
    assert.equal(f.calls.some(({ program }) => program === "/usr/bin/hdiutil"), false);
  });
}

test("native failures are redacted and stop before later release steps", async (t) => {
  const f = fixture(t, { throwAt: (program, args) => program.endsWith("xcrun") && args[0] === "stapler" });
  await assert.rejects(f.invoke(), (error) => error instanceof MacReleaseError
    && /Ticket stapling failed/.test(error.message) && !error.message.includes("synthetic-private-tool-detail"));
  assert.equal(existsSync(path.join(f.options.output, "release-evidence.json")), false);
});

test("notarization evidence requires a matching job and a zero-issue log", () => {
  const result = { id: submission, status: "Accepted" };
  assert.throws(() => acceptedNotarization(result, { jobId: submission, status: "Accepted" }), /issues requiring review/);
  assert.throws(() => acceptedNotarization(result, { jobId: "other", status: "Accepted", issues: [] }), /mismatched/);
  assert.deepEqual(acceptedNotarization(result, { jobId: submission, status: "Accepted", issues: [] }), { ...result, issues: 0 });
});

test("complete orchestration preserves stage and records only safe exact-artifact evidence", async (t) => {
  const f = fixture(t);
  const manifest = await f.invoke();
  assert.equal(manifest.releaseStage, "release-candidate");
  assert.equal(manifest.publicationStatus, "pending-installed-acceptance-and-approval");
  assert.equal(manifest.artifact.sha256, digest("synthetic-disk-image"));
  assert.equal(manifest.artifact.bytes, Buffer.byteLength("synthetic-disk-image"));
  assert.equal(manifest.sbomSHA256, digest("{}"));
  const evidence = readFileSync(path.join(f.options.output, "release-evidence.json"), "utf8");
  for (const privateValue of [f.work, "synthetic-profile", "Synthetic Publisher"]) assert.equal(evidence.includes(privateValue), false);
  const submits = f.calls.filter(({ args }) => args[0] === "notarytool" && args[1] === "submit");
  assert.equal(submits.length, 2);
  assert.equal(submits[0].args[2].endsWith(".zip"), true);
  assert.equal(submits[1].args[2].endsWith(".dmg"), true);
  const firstStaple = f.calls.findIndex(({ args }) => args[0] === "stapler" && args[1] === "staple");
  const imageCreation = f.calls.findIndex(({ program, args }) => program.endsWith("hdiutil") && args[0] === "create");
  assert.ok(firstStaple < imageCreation);
  assert.equal(f.calls.filter(({ program }) => program.endsWith("spctl")).length, 2);
  assert.equal(f.calls.some(({ program, args }) => /^(?:gh|sudo|installer|open)$/.test(program) || args.includes("push")), false);
});

test("bundle scan rejects links, nested code and extra executable payloads", (t) => {
  const f = fixture(t);
  const app = path.join(f.work, "Synthetic.app");
  const macos = path.join(app, "Contents/MacOS");
  mkdirSync(macos, { recursive: true });
  writeFileSync(path.join(macos, "LockedInFlow"), Buffer.from("cffaedfe", "hex"), { mode: 0o755 });
  verifyBundleLayout(app);
  const extra = path.join(app, "extra");
  writeFileSync(extra, Buffer.from("feedfacf", "hex"));
  assert.throws(() => verifyBundleLayout(app), /Unexpected executable/);
  rmSync(extra);
  symlinkSync("/Applications", extra);
  assert.throws(() => verifyBundleLayout(app), /bundle link/);
  rmSync(extra);
  mkdirSync(path.join(app, "Nested.framework"));
  assert.throws(() => verifyBundleLayout(app), /signing plan/);
  const appLink = path.join(f.work, "Linked.app");
  symlinkSync(app, appLink);
  assert.throws(() => verifyBundleLayout(appLink), /real directory/);
});
