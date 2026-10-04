import assert from "node:assert/strict";
import test from "node:test";
import { archiveExtraction, rustHost } from "../scripts/build-platform.mjs";

test("Rust host parser accepts x64 underscores and Windows line endings", () => {
  for (const target of [
    "x86_64-unknown-linux-gnu",
    "x86_64-pc-windows-msvc",
    "aarch64-apple-darwin",
  ]) {
    for (const newline of ["\n", "\r\n"]) {
      assert.equal(
        rustHost(
          ["rustc 1.94.1", `host: ${target}`, "release: 1.94.1"].join(newline),
        ),
        target,
      );
    }
  }
  assert.throws(() => rustHost("host: invalid/target"));
  assert.throws(() => rustHost("release: 1.94.1"));
});

test("archive extraction never passes a drive path as tar's archive argument", () => {
  const directory = String.raw`E:\build\synthetic-source`;
  const extraction = archiveExtraction(directory);
  assert.deepEqual(extraction.args, ["-xzf", "upstream.crate"]);
  assert.equal(extraction.options.cwd, directory);
});
