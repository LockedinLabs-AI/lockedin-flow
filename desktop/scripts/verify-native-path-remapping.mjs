#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { mkdtemp, readFile, copyFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { nativeCxxFlags, nativePrivacyFlags, privatePathFindings } from "./build-path-privacy.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
// Deliberate spaces exercise the same mapping used in normal developer folders.
const temporary = await mkdtemp(path.join(os.tmpdir(), "flow compiler probe "));
try {
  const source = path.join(temporary, "path-privacy.cpp");
  const object = path.join(temporary, process.platform === "win32" ? "probe.obj" : "probe.o");
  await copyFile(path.join(root, "tests/fixtures/path-privacy.cpp"), source);
  const windows = process.platform === "win32";
  const compiler = windows ? "clang-cl" : "clang++";
  const common = nativePrivacyFlags([[temporary, "/lockedin-probe"]], process.platform);
  const args = windows
    ? ["/nologo", "/WX", "/c", ...nativeCxxFlags(process.platform), ...common, source, `/Fo${object}`]
    : ["-Werror", "-c", ...common, source, "-o", object];
  const result = spawnSync(compiler, args, { encoding: "utf8", shell: false });
  // Never reflect raw compiler errors, which may contain source-machine paths.
  if (result.error || result.status !== 0)
    throw new Error("Native path-remapping probe failed to compile; check the documented compiler prerequisites.");
  const binary = await readFile(object);
  if (privatePathFindings(binary, [{ scope: "checkout", prefix: temporary + path.sep }]).length)
    throw new Error("Native compiler retained a private source path.");
  // clang-cl may normalize the replacement itself to Windows separators.
  const portablePrefixes = windows ? ["/lockedin-probe", "\\lockedin-probe"] : ["/lockedin-probe"];
  if (!portablePrefixes.some((prefix) => binary.includes(Buffer.from(prefix))))
    throw new Error("Native compiler did not retain the remapped fixture.");
  const widePrefixes = windows ? portablePrefixes.map((prefix) => Buffer.from(prefix, "utf16le")) : [Buffer.concat(
    [..."/lockedin-probe"].map((character) => {
      const bytes = Buffer.alloc(4);
      bytes.writeUInt32LE(character.codePointAt(0));
      return bytes;
    }),
  )];
  if (!widePrefixes.some((prefix) => binary.includes(prefix)))
    throw new Error("Native compiler did not retain the remapped wide fixture.");
  process.stdout.write("Native C++ exception and narrow/wide source-path remapping probe passed.\n");
} finally {
  await rm(temporary, { recursive: true, force: true });
}
