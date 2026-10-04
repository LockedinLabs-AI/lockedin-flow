import assert from "node:assert/strict";
import test from "node:test";
import { dependencyQueries, queryAdvisories, queryCrateAdvisories } from "../../scripts/lib/dependency-advisories.mjs";

const commit = "a".repeat(40);
const response = (value) => ({ ok: true, json: async () => value });
test("advisory lookup sends only the immutable commit with bounded, non-redirected requests", async () => {
  assert.deepEqual(await queryAdvisories(commit, async (url, options) => {
    assert.equal(url, "https://api.osv.dev/v1/query");
    assert.deepEqual(JSON.parse(options.body), { commit });
    assert.equal(options.redirect, "error");
    assert.ok(options.signal);
    return response({});
  }), []);
});
test("advisories accumulate through pagination; withdrawn records are excluded", async () => {
  let calls = 0;
  const ids = await queryAdvisories(commit, async (_, options) => {
    if (calls++ === 0) return response({ vulns: [{ id: "CVE-2026-0001" }], next_page_token: "next" });
    assert.equal(JSON.parse(options.body).page_token, "next");
    return response({ vulns: [{ id: "CVE-2026-0002" }, { id: "CVE-2026-0003", withdrawn: "2026-01-01" }] });
  });
  assert.deepEqual(ids, ["CVE-2026-0001", "CVE-2026-0002"]);
});
test("service errors and malformed responses never become a clean scan", async () => {
  for (const value of [null, [], { vulns: {} }, { vulns: [{}] }, { next_page_token: 5 }]) {
    await assert.rejects(queryAdvisories(commit, async () => response(value)));
  }
  await assert.rejects(queryAdvisories(commit, async () => ({ ok: false })));
  await assert.rejects(queryAdvisories(commit, async () => { throw new Error("synthetic failure"); }));
});
test("repeated pagination and invalid commits fail closed", async () => {
  await assert.rejects(queryAdvisories(commit, async () => response({ next_page_token: "same" })));
  await assert.rejects(queryAdvisories("not-a-commit"));
});
test("registry queries send only a validated public crate identity", async () => {
  assert.deepEqual(await queryCrateAdvisories("glib", "0.18.5", async (_, options) => {
    assert.deepEqual(JSON.parse(options.body), { package: { ecosystem: "crates.io", name: "glib" }, version: "0.18.5" });
    return response({ vulns: [{ id: "SYNTHETIC-ADVISORY" }] });
  }), ["SYNTHETIC-ADVISORY"]);
  await assert.rejects(queryCrateAdvisories("../private", "0.18.5"));
  await assert.rejects(queryCrateAdvisories("glib", "not-a-version"));
});
test("inventory rejects unreviewed packages, drifting vendors, and incomplete coverage", () => {
  const resolved = { version: 3, pins: [{ identity: "synthetic", location: "https://example.com/source.git", kind: "remoteSourceControl", state: { revision: commit } }] };
  const inventory = { schemaVersion: 1, vendored: [] };
  const profile = { swiftPackages: [{ identity: "synthetic", expectedLocation: "https://example.com/source.git" }], vendoredComponents: [] };
  assert.deepEqual(dependencyQueries(resolved, inventory, profile), [{ name: "synthetic", commit }]);
  assert.throws(() => dependencyQueries(resolved, inventory, { ...profile, swiftPackages: [] }));
  assert.throws(() => dependencyQueries({ ...resolved, pins: [] }, inventory, profile));
  assert.throws(() => dependencyQueries(resolved, { schemaVersion: 1, vendored: [{ name: "unexpected" }] }, profile));
});
