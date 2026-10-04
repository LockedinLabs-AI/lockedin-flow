#!/usr/bin/env node
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { archiveExtraction } from "./build-platform.mjs";
import { queryCrateAdvisories } from "../../scripts/lib/dependency-advisories.mjs";
import { unresolvedGlibAdvisories } from "./backport-policy.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const digest =
  "233daaf6e83ae6a12a52055f568f9d7cf4671dabb78ff9560ab6da230ce00ee5";
const response = await fetch(
  "https://static.crates.io/crates/glib/glib-0.18.5.crate",
  {
    redirect: "error",
    signal: AbortSignal.timeout(60_000),
  },
);
if (!response.ok)
  throw new Error("Pinned upstream source could not be fetched.");
let length = 0;
const chunks = [];
for await (const chunk of response.body) {
  length += chunk.length;
  if (length > 2 * 1024 * 1024)
    throw new Error("Upstream archive exceeds its limit.");
  chunks.push(chunk);
}
const archive = Buffer.concat(chunks);
if (createHash("sha256").update(archive).digest("hex") !== digest) {
  throw new Error("Upstream archive checksum mismatch.");
}
const temporary = await mkdtemp(path.join(os.tmpdir(), "flow-glib-source-"));
async function walk(directory, prefix = "") {
  const files = [];
  for (const item of await readdir(directory, { withFileTypes: true })) {
    const relative = prefix + item.name;
    if (item.isDirectory())
      files.push(
        ...(await walk(path.join(directory, item.name), relative + "/")),
      );
    else if (item.isFile()) files.push(relative);
    else throw new Error("Nonregular vendored source entry.");
  }
  return files.sort();
}
try {
  const file = path.join(temporary, "upstream.crate");
  await writeFile(file, archive, { flag: "wx" });
  // Extract only the immutable archive verified above, never arbitrary user input.
  const extraction = archiveExtraction(temporary);
  execFileSync("tar", extraction.args, extraction.options);
  const upstream = path.join(temporary, "glib-0.18.5");
  const vendor = path.join(root, "vendor/glib");
  const expected = (await walk(upstream)).filter(
    (name) =>
      ["Cargo.toml", "LICENSE", "README.md"].includes(name) ||
      name.startsWith("src/"),
  );
  const actual = (await walk(vendor)).filter(
    (name) => name !== "LOCKEDIN-PATCH.md",
  );
  if (JSON.stringify(expected) !== JSON.stringify(actual))
    throw new Error("Vendored source inventory differs.");
  for (const name of expected) {
    let bytes = await readFile(path.join(upstream, name));
    if (name === "src/variant_iter.rs") {
      let source = bytes.toString("utf8");
      for (const [before, after] of [
        [
          "let p: *mut libc::c_char = std::ptr::null_mut();",
          "let mut p: *mut libc::c_char = std::ptr::null_mut();",
        ],
        ["                &p,", "                &mut p,"],
      ]) {
        if (source.split(before).length !== 2)
          throw new Error("Upstream fix precondition differs.");
        source = source.replace(before, after);
      }
      bytes = Buffer.from(source);
    }
    if (!bytes.equals(await readFile(path.join(vendor, name)))) {
      throw new Error(
        "Vendored source differs beyond the approved upstream fix.",
      );
    }
  }
  process.stdout.write(
    `Verified ${expected.length} upstream files; only the two-line security backport differs.\n`,
  );
  // Cargo's registry scanner does not cover this path dependency. Check its
  // upstream identity too; only the fix verified above may be resolved locally.
  const advisories = await queryCrateAdvisories("glib", "0.18.5");
  const unresolved = unresolvedGlibAdvisories(advisories);
  if (unresolved.length)
    throw new Error(
      `Additional GLib advisory requires review: ${unresolved.join(", ")}`,
    );
  process.stdout.write(
    "Upstream GLib advisories checked; no additional unresolved advisory.\n",
  );
} finally {
  await rm(temporary, { recursive: true, force: true });
}
