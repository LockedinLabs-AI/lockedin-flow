import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import { componentIdentity, noticeWriter, summaryProperty, summaryScope, summaryLimits, verifiedInventorySummary, validateInventorySummary } from "../scripts/inventory-summary.mjs";
const hash = (b) => createHash("sha256").update(b).digest("hex");
const component = (ref) => ({ "bom-ref": ref, licenses: [{ license: { id: "MIT" } }] });
function fixture() {
  const writer = noticeWriter();
  writer.push("# Synthetic notices", "");
  writer.forComponents(["app", "shared"], "## Synthetic", "", "Synthetic café 漢字 license.\r\n", "");
  writer.push("Source reference only", "");
  const components = [component("app"), component("shared"), component("missing")];
  const index = writer.index(components);
  const sbom = { metadata: { component: components[0], properties: [{ name: summaryProperty, value: JSON.stringify(index) }] }, components: components.slice(1) };
  return { writer, index, sbom };
}
function verify(f) {
  const sbom = Buffer.from(JSON.stringify(f.sbom));
  const notices = f.writer.bytes();
  return verifiedInventorySummary(sbom, notices, { sbomSha256: hash(sbom), noticesSha256: hash(notices) });
}
test("synthetic legacy join is byte-identical with UTF-8, empty separators, CRLF and shared blocks", () => {
  const f = fixture();
  const old = ["# Synthetic notices", "", "## Synthetic", "", "Synthetic café 漢字 license.\r\n", "", "Source reference only", ""].join("\n");
  assert.deepEqual(f.writer.bytes(), Buffer.from(old));
  const summary = verify(f);
  const app = summary.components.find((c) => c.referenceSha256 === componentIdentity(component("app")).referenceSha256);
  const shared = summary.components.find((c) => c.referenceSha256 === componentIdentity(component("shared")).referenceSha256);
  assert.deepEqual(app.noticeBlocks, shared.noticeBlocks);
  const block = app.noticeBlocks[0];
  assert.equal(block.offset, Buffer.byteLength("# Synthetic notices\n\n"));
  assert.equal(block.sha256, hash(Buffer.from(old).subarray(block.offset, block.offset + block.bytes)));
  assert.equal(summary.components.find((c) => !c.noticeBlocks.length).noticeEvidence, "source-reference-only");
  assert.equal(summary.scope, summaryScope);
  assert.equal(Object.hasOwn(app, "sourceIdentitySha256"), false);
});
test("canonical tagged identity inputs and carrier tree distinguish source from guessed release", () => {
  const c = component("synthetic-ref");
  assert.equal(componentIdentity(c).referenceSha256, hash('["reference-v1","synthetic-ref"]'));
  assert.equal(componentIdentity(c).licenseDeclarationSha256, hash('["licenses-v1",[["id","MIT"]]]'));
  c.hashes = [{ alg: "SHA-256", content: "a".repeat(64) }];
  assert.equal(componentIdentity(c).sourceIdentitySha256, hash(JSON.stringify(["inventory-sha256-v1", "a".repeat(64)])));
  const names = ["carrier", "carrier-sha256", "carrier-vcs-revision", "source-subdirectory", "source-tree-sha256"];
  const values = ["pkg:cargo/synthetic@0.0.0", "b".repeat(64), "c".repeat(40), "synthetic/", "d".repeat(64)];
  c.properties = names.map((n, i) => ({ name: "lockedin:" + n, value: values[i] }));
  assert.equal(componentIdentity(c).sourceIdentitySha256, hash(JSON.stringify(["native-carrier-tree-v1", ...values])));
  c.properties.pop(); assert.throws(() => componentIdentity(c));
});
test("verified summary rejects altered actual bytes and mismatched source declarations", () => {
  const f = fixture(), sbom = Buffer.from(JSON.stringify(f.sbom)), notices = f.writer.bytes();
  const expected = { sbomSha256: hash(sbom), noticesSha256: hash(notices) };
  assert.throws(() => verifiedInventorySummary(Buffer.concat([sbom, Buffer.from(" ")]), notices, expected));
  assert.throws(() => verifiedInventorySummary(sbom, Buffer.concat([notices, Buffer.from("x")]), expected));
  f.sbom.components[0].licenses[0].license.id = "Apache-2.0";
  assert.throws(() => verify(f));
});
test("span digests are recomputed even with correctly rebound whole-file hashes", () => {
  const f = fixture();
  f.index.components.find((c) => c.noticeBlocks.length).noticeBlocks[0].sha256 = "a".repeat(64);
  f.sbom.metadata.properties[0].value = JSON.stringify(f.index);
  assert.throws(() => verify(f));
});
test("strict schema rejects duplicate/unsorted identities, injected text, span and evidence corruption", () => {
  const base = verify(fixture());
  const mutations = [
    (s) => { s.rawPath = "/synthetic/private"; },
    (s) => { s.scope = "approved"; },
    (s) => { s.sbomSha256 = "A".repeat(64); },
    (s) => { s.components.reverse(); },
    (s) => { s.components[1] = structuredClone(s.components[0]); },
    (s) => { s.components[0].licenseDeclarationSha256 = "MIT"; },
    (s) => { s.components[0].noticeEvidence = "approved"; },
    (s) => { s.components[0].sourceIdentitySha256 = null; },
    (s) => { s.noticesBytes = summaryLimits.bytes + 1; },
    (s) => { s.components = Array(summaryLimits.components + 1).fill(s.components[0]); },
    ...[-1, 0.5, Number.MAX_SAFE_INTEGER].map((offset) => (s) => { s.components.find((c) => c.noticeBlocks.length).noticeBlocks[0].offset = offset; }),
    ...[0, -1, Number.MAX_SAFE_INTEGER].map((bytes) => (s) => { s.components.find((c) => c.noticeBlocks.length).noticeBlocks[0].bytes = bytes; }),
    (s) => { const c = s.components.find((c) => c.noticeBlocks.length); c.noticeBlocks.push(c.noticeBlocks[0]); },
    (s) => { const c = s.components.find((c) => c.noticeBlocks.length); c.noticeBlocks = Array(summaryLimits.blocks + 1).fill(c.noticeBlocks[0]); },
    (s) => { s.components.find((c) => c.noticeBlocks.length).noticeBlocks[0].text = "synthetic raw notice"; },
  ];
  for (const mutate of mutations) {
    const s = structuredClone(base); mutate(s);
    assert.throws(() => validateInventorySummary(s, base.sbomSha256), /content withheld/);
  }
});
test("canonical index, duplicate property and duplicate component coverage fail closed; no-index history works", () => {
  for (const mutate of [
    (f) => { f.sbom.metadata.properties[0].value += " "; },
    (f) => { f.sbom.metadata.properties.push(f.sbom.metadata.properties[0]); },
    (f) => { f.sbom.components.push(f.sbom.components[0]); },
    (f) => { f.sbom.metadata.properties[0].value = '{"raw":"synthetic"}'; },
  ]) { const f = fixture(); mutate(f); assert.throws(() => verify(f)); }
  const f = fixture(); f.sbom.metadata.properties = [];
  assert.equal(verify(f), undefined);
});
test("writer rejects unmapped associations, duplicate references and output overflow", () => {
  const w = noticeWriter(); w.forComponents(["a"], "synthetic");
  assert.throws(() => w.index([component("b")]));
  assert.throws(() => w.index([component("a"), component("a")]));
  assert.throws(() => w.push("x".repeat(summaryLimits.bytes + 1)));
});

test("total block and encoded index limits reject bounded but excessive evidence", () => {
  const s = verify(fixture());
  s.noticesBytes = 128;
  s.components = Array.from({ length: 257 }, (_, i) => ({
    ...componentIdentity(component(`synthetic-${i}`)), noticeEvidence: "retained-text",
    noticeBlocks: Array.from({ length: 64 }, (_, offset) => ({ sha256: hash("x"), offset, bytes: 1 })),
  })).sort((a, b) => a.referenceSha256 < b.referenceSha256 ? -1 : 1);
  assert.throws(() => validateInventorySummary(s, s.sbomSha256), /content withheld/);
  const f = fixture();
  f.sbom.metadata.properties[0].value = " ".repeat(summaryLimits.indexBytes + 1);
  assert.throws(() => verify(f), /content withheld/);
});
