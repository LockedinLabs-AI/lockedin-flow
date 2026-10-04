import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { supplementalNotices } from "../scripts/supplemental-notices.mjs";

const raw = await readFile(new URL("../notices/supplemental.json", import.meta.url));
const records = JSON.parse(raw);
const pkg = (record) => ({ ...record, source: "registry+https://github.com/rust-lang/crates.io-index" });

test("six exact carriers retain nine authentic immutable notices", async () => {
  assert.deepEqual(records.map((r) => r.name), ["alloc-stdlib", "dasp_sample", "libappindicator-sys", "defmt-parser", "dlopen2", "dlopen2_derive"]);
  let count = 0;
  for (const record of records) {
    const notices = await supplementalNotices(pkg(record), record.checksum);
    count += notices.length;
    for (const [i, notice] of notices.entries()) {
      assert.equal(notice.text, record.notices[i].text);
      assert.equal(Buffer.byteLength(notice.text), record.notices[i].bytes);
      assert.equal(createHash("sha256").update(notice.text).digest("hex"), record.notices[i].sha256);
      assert.ok(notice.source.includes(record.revision));
    }
  }
  assert.equal(count, 9);
});

test("changed version, carrier, license and registry cannot inherit notices", async () => {
  for (const record of records) {
    for (const change of [{version:"999.0.0"}, {source:null}, {source:"registry+https://example.invalid/index"}, {license:record.license === "MIT" ? "Apache-2.0" : "MIT"}])
      await assert.rejects(supplementalNotices({...pkg(record), ...change}, record.checksum), /carrier identity changed/);
    await assert.rejects(supplementalNotices(pkg(record), "0".repeat(64)), /carrier identity changed/);
    await assert.rejects(supplementalNotices(pkg(record), undefined), /carrier identity changed/);
  }
});

test("changed material, text digest, attribution and missing material fail closed", async () => {
  for (const mutate of [
    (r) => { r[0].notices[0].text += " altered"; },
    (r) => { r[0].notices[0].sha256 = "0".repeat(64); },
    (r) => { r[0].checksum = "0".repeat(64); },
    (r) => { r[0].notices[0].url = "https://example.invalid"; },
    (r) => { r[1].notices[0].kind = "license-text"; },
  ]) {
    const copy = structuredClone(records); mutate(copy);
    await assert.rejects(supplementalNotices(pkg(records[0]), records[0].checksum,
      async () => Buffer.from(JSON.stringify(copy))), /reviewed digest/);
  }
  await assert.rejects(supplementalNotices(pkg(records[0]), records[0].checksum,
    async () => { throw new Error("missing material"); }), /missing material/);
});

test("short Apache reference stays distinct and unresolved carriers receive no notices", async () => {
  const dasp = records.find((r) => r.name === "dasp_sample");
  const notices = await supplementalNotices(pkg(dasp), dasp.checksum);
  assert.match(notices[0].label, /short notice\/reference; not full license text/);
  assert.equal(Buffer.byteLength(notices[0].text), 561);
  assert.match(notices[1].label, /license text/);
  for (const name of ["audio-core", "selectors", "realfft"])
    assert.deepEqual(await supplementalNotices({ name }, undefined), []);
});

test("line-ending evidence retains distinct raw identities and cannot silently change", async () => {
  for (const name of ["dlopen2", "dlopen2_derive"]) {
    const record = records.find((r) => r.name === name);
    const comparison = record.sourceComparison;
    assert.equal(comparison.kind, "exact-except-recorded-crlf-lf-differences");
    assert.equal(comparison.rustFilesCompared, name === "dlopen2" ? 37 : 5);
    assert.equal(comparison.differences.length, name === "dlopen2" ? 1 : 2);
    for (const difference of comparison.differences) {
      assert.equal(difference.classification, "CRLF-versus-LF-only-not-byte-equality");
      assert.notEqual(difference.publishedSha256, difference.upstreamSha256);
      assert.match(difference.publishedSha256, /^[a-f0-9]{64}$/);
      assert.match(difference.upstreamSha256, /^[a-f0-9]{64}$/);
      const changed = structuredClone(records);
      changed.find((r) => r.name === name).sourceComparison.differences[0].classification = "exact";
      await assert.rejects(supplementalNotices(pkg(record), record.checksum,
        async () => Buffer.from(JSON.stringify(changed))), /reviewed digest/);
    }
  }
});
