import assert from "node:assert/strict";
import path from "node:path";
import test from "node:test";
import { workspaceNoticeReferences } from "../scripts/workspace-notices.mjs";
import { noticeWriter, componentIdentity } from "../scripts/inventory-summary.mjs";
const root = path.resolve("synthetic-workspace");
const names = ["lockedin-flow-core", "lockedin-flow-engine"];
function fixture() {
  const packages = names.map((name, i) => ({ name, id: `synthetic-member-${i}`, version: "0.5.0-alpha.1", source: null, license: "MIT", license_file: null, manifest_path: path.join(root, i ? "engine" : "core", "Cargo.toml") }));
  const manifests = new Map(packages.map((p) => [p.manifest_path, Buffer.from(`[package]\nname = "${p.name}"\nlicense.workspace = true\n\n[dependencies]\n`)]));
  return { metadata: { workspace_root: root, workspace_members: packages.map((p) => p.id), packages }, manifests };
}
const verify = (f) => workspaceNoticeReferences(f.metadata, root, async (file) => f.manifests.get(file));
test("root notice associates only exact owned crates, without changing text or claiming third-party coverage", async () => {
  const f = fixture();
  f.metadata.packages.push({ name: "third-party", id: "external", version: "1.0.0", license: "MIT", source: "registry" });
  const refs = await verify(f);
  assert.deepEqual(refs, names.map((n) => `pkg:cargo/${n}@0.5.0-alpha.1`));
  const old = noticeWriter(), current = noticeWriter();
  const chunks = ["## LockedIn Flow", "", "Synthetic MIT notice", ""];
  old.forComponents(["lockedin-flow"], ...chunks);
  current.forComponents(["lockedin-flow", ...refs], ...chunks);
  assert.deepEqual(old.bytes(), current.bytes());
  const components = ["lockedin-flow", ...refs, "third-party"].map((ref) => ({ "bom-ref": ref, licenses: [{ license: { id: "MIT" } }] }));
  const index = current.index(components);
  assert.equal(index.components.filter((c) => c.noticeEvidence === "retained-text").length, 3);
  const third = index.components.find((c) => c.referenceSha256 === componentIdentity(components[3]).referenceSha256);
  assert.equal(third.noticeEvidence, "source-reference-only");
  assert.deepEqual(third.noticeBlocks, []);
});
test("wrong ownership, license, membership, version or duplicate identity fails closed", async () => {
  for (const change of [
    (f) => { f.metadata.workspace_root += "-other"; },
    (f) => { f.metadata.packages[0].source = "registry"; },
    (f) => { f.metadata.packages[0].license = "MIT OR Apache-2.0"; },
    (f) => { f.metadata.packages[0].license_file = "LICENSE"; },
    (f) => { f.metadata.packages[0].manifest_path = path.join(root, "vendor", "Cargo.toml"); },
    (f) => { f.metadata.packages[0].name = "external"; },
    (f) => { f.metadata.workspace_members.pop(); },
    (f) => { f.metadata.workspace_members.push(f.metadata.workspace_members[0]); },
    (f) => { f.metadata.packages.push(f.metadata.packages[0]); },
    (f) => { f.metadata.packages[0].version = "private/path"; },
  ]) { const f = fixture(); change(f); await assert.rejects(verify(f), /content withheld/); }
});
test("inheritance must be real and unambiguous in the existing package-header layout", async () => {
  for (const value of [
    '[package]\nname = "lockedin-flow-core"\nlicense = "MIT"\n',
    '[package]\nname = "lockedin-flow-core"\nlicense.workspace = false\n',
    '[package]\nname = "lockedin-flow-core"\n[dependencies]\nlicense.workspace = true\n',
    '[package]\nname = "lockedin-flow-core"\n# license.workspace = true\n',
    '[package]\nname = "lockedin-flow-core"\ndescription = """\nlicense.workspace = true\n"""\n',
    '[package]\nname = "external"\nlicense.workspace = true\n',
    '[package]\nname = "lockedin-flow-core"\nlicense.workspace = true\nlicense.workspace = true\n',
    "x".repeat(16385), "\0",
  ]) { const f = fixture(); f.manifests.set(f.metadata.packages[0].manifest_path, Buffer.from(value)); await assert.rejects(verify(f), /content withheld/); }
});
