import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import test from "node:test";
import { localLinks, scanEntry, scanText, stripPngMetadata } from "../../scripts/lib/public-content-policy.mjs";

test("upstream notice contacts require both the exact file and pinned bytes", () => {
  const bytes = readFileSync(new URL("../../desktop/notices/supplemental.json", import.meta.url));
  const file = "desktop/notices/supplemental.json";
  assert.deepEqual(scanEntry(file, bytes), []);
  assert.ok(scanEntry("docs/supplemental.json", bytes).includes("unreviewed-contact-address"));
  assert.ok(scanEntry(file, Buffer.concat([bytes, Buffer.from("\n")])).includes("unreviewed-contact-address"));
  const contact = Buffer.from(["synthetic", "unreviewed.test"].join("@"));
  assert.ok(scanEntry(file, contact).includes("unreviewed-contact-address"));
  assert.ok(scanEntry(file, bytes, { mode: "120000" }).includes("nonregular-git-entry"));
});

test("publication policy rejects private surfaces without returning their contents", () => {
  const bytes = Buffer.from("synthetic sensitive payload");
  for (const file of ["CONTINUE.md", ".codex/session.jsonl", "docs/internal/notes.md", "docs/capture.wav"]) {
    const rules = scanEntry(file, bytes);
    assert.ok(rules.length, file);
    assert.ok(rules.every((rule) => !rule.includes(bytes.toString())));
  }
  assert.deepEqual(scanEntry("README.md", Buffer.from("Public product introduction")), []);
  assert.ok(scanEntry("docs/link.md", bytes, { mode: "120000" }).includes("nonregular-git-entry"));
});

test("publication policy catches personal context and conversation exports", () => {
  const home = ["", "Users", "synthetic-person", "private.txt"].join("/");
  assert.ok(scanText(home).includes("personal-home-path"));
  const email = ["synthetic.person", "mail.invalid-provider.test"].join("@");
  assert.ok(scanText(email).includes("unreviewed-contact-address"));
  assert.deepEqual(scanText("reader@example.com"), []);
  assert.deepEqual(scanText("icon_128x128@2x.png"), []);
  assert.deepEqual(scanText("123+developer@users.noreply.github.com"), []);
  const transcript = JSON.stringify({ role: "user", content: "synthetic private conversation" });
  assert.ok(scanText(transcript).includes("conversation-export"));
});

test("the reviewed compiler fixture remains subject to text privacy checks", () => {
  const file = "desktop/tests/fixtures/path-privacy.cpp";
  assert.deepEqual(scanEntry(file, Buffer.from("const char *synthetic = __FILE__;")), []);
  const home = ["", "Users", "synthetic-person", "private.txt"].join("/");
  assert.ok(scanEntry(file, Buffer.from(home)).includes("personal-home-path"));
  assert.ok(scanEntry("desktop/tests/fixtures/unreviewed.cpp", Buffer.from("synthetic")).includes("unapproved-file-type"));
});

test("GitHub's public commit identity is allowed only in commit metadata", () => {
  for (const name of ["noreply", "support"]) {
    const address = [name, "github.com"].join("@");
    assert.deepEqual(scanText(address, { commitMetadata: true }), []);
    assert.ok(scanText(address).includes("unreviewed-contact-address"));
  }
  assert.ok(scanText(["synthetic", "unreviewed.test"].join("@"), { commitMetadata: true })
    .includes("unreviewed-contact-address"));
});

test("the reviewed installer fragment still rejects private content", () => {
  const file = "desktop/app/windows/install-directory.wxs";
  assert.deepEqual(scanEntry(file, Buffer.from('<Wix><Fragment /></Wix>')), []);
  const home = ["", "Users", "synthetic-person", "private.txt"].join("/");
  assert.ok(scanEntry(file, Buffer.from(home)).includes("personal-home-path"));
  assert.ok(scanEntry("desktop/app/windows/unreviewed.wxs", Buffer.from("synthetic")).includes("unapproved-file-type"));
});

test("publication media requires exact reviewed bytes and rejects embedded metadata", () => {
  const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  const chunk = (type) => Buffer.concat([Buffer.alloc(4), Buffer.from(type), Buffer.alloc(4)]);
  const bytes = Buffer.concat([signature, chunk("IEND")]);
  const file = "docs/images/synthetic.png";
  const media = { [file]: createHash("sha256").update(bytes).digest("hex") };
  assert.deepEqual(scanEntry(file, bytes, { media }), []);
  assert.ok(scanEntry(file, bytes).includes("unreviewed-media"));
  const annotated = Buffer.concat([signature, chunk("eXIf"), chunk("IEND")]);
  const annotatedMedia = { [file]: createHash("sha256").update(annotated).digest("hex") };
  assert.ok(scanEntry(file, annotated, { media: annotatedMedia }).includes("embedded-image-metadata"));
  assert.deepEqual(stripPngMetadata(annotated), bytes);
  assert.throws(() => stripPngMetadata(Buffer.concat([annotated, Buffer.from("private tail")])));
});

test("documentation links resolve relative paths and ignore external services", () => {
  assert.deepEqual(localLinks("docs/start.md", "[Guide](../README.md#start) [Web](https://example.com)"), ["README.md"]);
  assert.deepEqual(localLinks("README.md", '<img src="docs/images/example.png">'), ["docs/images/example.png"]);
  assert.deepEqual(localLinks("desktop/vendor/glib/README.md", "[Variant](struct@Variant)"), []);
  assert.deepEqual(localLinks("README.md", "[Variant](struct@Variant)"), ["struct@Variant"]);
});
