import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { scanPullRequest } from "../../scripts/lib/public-metadata-policy.mjs";

const script = fileURLToPath(new URL("../../scripts/check-public-metadata.mjs", import.meta.url));
const event = (title, body = null) => ({ pull_request: { title, body } });
const run = (input) => spawnSync(process.execPath, [script], {
  input, encoding: "utf8", timeout: 10000,
});

test("safe public product text and an empty description pass", () => {
  assert.deepEqual(scanPullRequest(event("Fix microphone recovery")), []);
  assert.deepEqual(scanPullRequest(event("Document setup", "Uses synthetic fixtures; see https://example.org/test.")), []);
});

test("both fields use the publication policy without attribution exceptions", () => {
  const home = ["", "Users", "synthetic-person", "private-note"].join("/");
  const contact = ["synthetic-person", "unapproved.test"].join("@");
  assert.deepEqual(scanPullRequest(event(home, contact)), [
    { field: "title", rule: "personal-home-path" },
    { field: "body", rule: "unreviewed-contact-address" },
  ]);
  const chat = JSON.stringify([{ role: "user", content: "synthetic confidential sentence" }]);
  assert.deepEqual(scanPullRequest(event("Docs", chat)), [{ field: "body", rule: "conversation-export" }]);
});

test("high-confidence credential shapes are rejected without online verification", () => {
  for (const value of [
    "gh" + "p_" + "x".repeat(36),
    "github_" + "pat_" + "x".repeat(30),
    "AK" + "IA" + "X".repeat(16),
    ["-----BEGIN", "OPENSSH PRIVATE KEY-----"].join(" "),
  ]) {
    assert.deepEqual(scanPullRequest(event("Test", value)), [{ field: "body", rule: "credential-pattern" }]);
  }
});

test("missing or non-text metadata fails closed", () => {
  for (const value of [null, {}, { pull_request: {} }, event(""), event("x", {}), event(42)]) {
    assert.throws(() => scanPullRequest(value), /Invalid pull request metadata/);
  }
});

test("CLI output never echoes unsafe values, malformed input, or event paths", () => {
  const canary = ["", "home", "synthetic-canary", "private-content"].join("/");
  for (const input of [JSON.stringify(event("Fix", canary)), `{bad-json:${canary}`]) {
    const result = run(input);
    assert.equal(result.status, 1);
    assert.equal(result.error, undefined);
    assert.doesNotMatch(result.stdout + result.stderr, /synthetic-canary|private-content|bad-json/);
  }
});

test("CLI accepts valid input and bounds oversized events", () => {
  assert.equal(run(JSON.stringify(event("Fix recovery"))).status, 0);
  const result = run(JSON.stringify(event("Fix", "x".repeat(4 * 1024 * 1024))));
  assert.equal(result.status, 1);
  assert.match(result.stderr, /could not complete/);
  assert.ok(result.stderr.length < 200);
});

test("workflow checks edits without secrets, shell interpolation, or privileged PR context", () => {
  const workflow = readFileSync(new URL("../../.github/workflows/public-metadata.yml", import.meta.url), "utf8");
  assert.match(workflow, /types: \[opened, edited, synchronize, reopened\]/);
  assert.match(workflow, /persist-credentials: false/);
  assert.match(workflow, /check-public-metadata\.mjs < "\$GITHUB_EVENT_PATH"/);
  assert.doesNotMatch(workflow, /pull_request_target|secrets\.|contents: write|pull_request\.(?:title|body)/);
});
