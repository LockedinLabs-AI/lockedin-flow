import assert from "node:assert/strict";
import path from "node:path";
import test from "node:test";
import { describeNativeSources, verifyNativeSource, nativeReferences } from "../scripts/native-inventory.mjs";
import { noticeWriter } from "../scripts/inventory-summary.mjs";

const archive = "a".repeat(64);
const directory = path.resolve("synthetic-carrier");
const pkg = {
  name: "whisper-rs-sys",
  version: "0.0.0-test",
  manifest_path: path.join(directory, "Cargo.toml"),
};

// Deliberately synthetic source fragments; no audio or personal data.
function fixture() {
  const files = {
    ".cargo_vcs_info.json": JSON.stringify({ git: { sha1: "b".repeat(40) }, path_in_vcs: "sys" }),
    "whisper.cpp/CMakeLists.txt": 'project("whisper.cpp" VERSION 1.8.3)',
    "whisper.cpp/ggml/CMakeLists.txt": "set(GGML_VERSION_MAJOR 0)\nset(GGML_VERSION_MINOR 9)\nset(GGML_VERSION_PATCH 5)",
    "whisper.cpp/LICENSE": "MIT License\nThe ggml authors\nSynthetic license fixture.",
    "whisper.cpp/ggml/src/ggml-cpu/llamafile/sgemm.cpp": "// Copyright 2024 Mozilla Foundation\n// Synthetic notice fixture.\n// SOFTWARE.\n\n// synthetic implementation",
    "whisper.cpp/ggml/src/ggml-cpu/ops.cpp": "// MIT licensed. Copyright (c) 2023 Jeffrey Quesnelle and Bowen Peng.",
  };
  return new Map(Object.entries(files).map(([name, value]) => [name, Buffer.from(value)]));
}

test("inventory identifies both nested native versions and their carrier", async () => {
  const input = fixture();
  const result = describeNativeSources(pkg, archive, input);
  assert.deepEqual(result.components.map(({ name, version }) => ({ name, version })), [
    { name: "whisper.cpp", version: "1.8.3" },
    { name: "ggml", version: "0.9.5" },
  ]);
  assert.deepEqual(result.dependencies[0], { ref: nativeReferences.whisper, dependsOn: [nativeReferences.ggml] });
  for (const component of result.components) {
    const properties = Object.fromEntries(component.properties.map(({ name, value }) => [name, value]));
    assert.equal(properties["lockedin:carrier-sha256"], archive);
    assert.match(properties["lockedin:source-tree-sha256"], /^[a-f0-9]{64}$/);
    assert.equal(component.purl, undefined, "Do not invent a separately resolved upstream package.");
  }
  const notices = result.notices.join("\n");
  assert.match(notices, /Mozilla Foundation/);
  assert.match(notices, /Jeffrey Quesnelle and Bowen Peng/);
  assert.doesNotMatch(notices, /synthetic-carrier/);
});

test("unlocked or altered native carriers are rejected", () => {
  const input = fixture();
  assert.throws(() => describeNativeSources(pkg, undefined, input), /locked registry/);
  verifyNativeSource(fixture(), input);
  input.set("whisper.cpp/CMakeLists.txt", Buffer.from("modified"));
  assert.throws(() => verifyNativeSource(fixture(), input), /locked archive/);
});

test("extra native source files do not go unrecorded", () => {
  const input = fixture();
  input.set("whisper.cpp/additional.cpp", Buffer.from("extra"));
  assert.throws(() => verifyNativeSource(fixture(), input), /inventory differs/);
});

test("missing source and changed license attribution require review", () => {
  const input = fixture();
  input.delete("whisper.cpp/ggml/CMakeLists.txt");
  assert.throws(() => describeNativeSources(pkg, archive, input), /required native source/);
  const changed = fixture();
  changed.set("whisper.cpp/LICENSE", Buffer.from("Changed license"));
  assert.throws(() => describeNativeSources(pkg, archive, changed), /license needs review/);
});

test("native notice associations preserve legacy bytes and explicitly share MIT, CPU and YaRN blocks", () => {
  const result = describeNativeSources(pkg, archive, fixture());
  const writer = noticeWriter();
  for (let i = 0; i < result.notices.length;) {
    const entry = result.noticeAssociations.find((a) => a.start === i);
    if (entry) { writer.forComponents(entry.refs, ...result.notices.slice(i, entry.end)); i = entry.end; }
    else writer.push(result.notices[i++]);
  }
  assert.deepEqual(writer.bytes(), Buffer.from(result.notices.join("\n")));
  const records = writer.index(result.components).components;
  assert.deepEqual(records[0].noticeBlocks, records[1].noticeBlocks);
  assert.equal(records[0].noticeBlocks.length, 3);
  const text = records[0].noticeBlocks.map((b) => writer.bytes().subarray(b.offset, b.offset + b.bytes).toString());
  assert.match(text[0], /^MIT License/); assert.match(text[1], /^Copyright 2024 Mozilla/);
  assert.match(text[2], /^MIT licensed/); assert.match(text[2], /permission and warranty/);
});
