import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { linkerPrivacyFlags, privatePathFindings, sourcePathMappings, nativePrivacyFlags, nativeCompilerEnvironment, nativeCxxFlags } from "../scripts/build-path-privacy.mjs";

const prefix = "X:\\synthetic-checkout\\";
const boundaries = [{ scope: "checkout", prefix }];

test("Windows linker records only a symbol basename", () => {
  assert.deepEqual(linkerPrivacyFlags("win32"), ["-C", "link-arg=/PDBALTPATH:%_PDB%"]);
  assert.deepEqual(linkerPrivacyFlags("linux"), []);
  assert.deepEqual(linkerPrivacyFlags("darwin"), []);
});

test("CodeView paths are classified without exposing their contents", () => {
  const record = Buffer.concat([Buffer.from("RSDS"), Buffer.alloc(20), Buffer.from(prefix + "internal-symbols.pdb\0")]);
  const findings = privatePathFindings(record, boundaries);
  assert.deepEqual(findings, [{ scope: "checkout", encoding: "utf8", kind: "debug-symbol-reference", count: 1 }]);
  assert.doesNotMatch(JSON.stringify(findings), /synthetic|internal|symbols\.pdb/);
});

test("ordinary UTF-8 and UTF-16 paths still fail the artifact boundary", () => {
  const bytes = Buffer.concat([
    Buffer.from(prefix + "synthetic.cpp\0"),
    Buffer.from(prefix.replaceAll("\\", "/") + "synthetic.rs\0", "utf16le"),
  ]);
  const findings = privatePathFindings(bytes, boundaries);
  assert.equal(findings.length, 2);
  assert.ok(findings.every(({ kind }) => kind === "source-or-data"));
  assert.deepEqual(new Set(findings.map(({ encoding }) => encoding)), new Set(["utf8", "utf16le"]));
  assert.deepEqual(privatePathFindings(Buffer.from("portable-symbols.pdb\0"), boundaries), []);
});

test("privacy diagnostics reject unrecognized labels instead of echoing them", () => {
  assert.throws(() => privatePathFindings(Buffer.alloc(0), [{ scope: "untrusted", prefix }]), /Invalid artifact/);
});

test("Windows mappings cover native and forward separators without splitting spaces", () => {
  const mappings = [["X:\\synthetic checkout", "/lockedin-flow"]];
  assert.deepEqual(sourcePathMappings(mappings, "win32"), [
    ["X:\\synthetic checkout", "/lockedin-flow"],
    ["X:/synthetic checkout", "/lockedin-flow"],
  ]);
  assert.deepEqual(nativePrivacyFlags(mappings, "win32"), [
    "/clang:-ffile-prefix-map=X:\\synthetic checkout=/lockedin-flow",
    "/clang:-ffile-prefix-map=X:/synthetic checkout=/lockedin-flow",
  ]);
  const original = { CXXFLAGS: "/DSYNTHETIC=1" };
  const env = nativeCompilerEnvironment(original, mappings, "win32");
  assert.equal(env.CC, "clang-cl");
  assert.equal(env.CXX, "clang-cl");
  assert.equal(env.CMAKE_GENERATOR, "Ninja");
  assert.ok(env.CMAKE_CXX_FLAGS.includes('"/clang:-ffile-prefix-map=X:/synthetic checkout=/lockedin-flow"'));
  assert.match(env.CMAKE_CXX_FLAGS, /^\/DSYNTHETIC=1 \/utf-8 \/EHsc /);
  assert.deepEqual(original, { CXXFLAGS: "/DSYNTHETIC=1" });
});

test("Windows C++ exceptions are enabled in release and direct Cargo builds only", () => {
  assert.deepEqual(nativeCxxFlags("win32"), ["/utf-8", "/EHsc"]);
  assert.deepEqual(nativeCxxFlags("linux"), []);
  assert.deepEqual(nativeCxxFlags("darwin"), []);
  const env = nativeCompilerEnvironment({}, [], "win32");
  assert.equal(env.CMAKE_CXX_FLAGS, "/utf-8 /EHsc");
  assert.equal(env.CMAKE_C_FLAGS, "");
  const cargo = readFileSync(new URL("../.cargo/config.toml", import.meta.url), "utf8");
  assert.match(cargo, /^CXXFLAGS_x86_64_pc_windows_msvc = "\/EHsc"$/m);
  assert.doesNotMatch(cargo, /^CXXFLAGS\s*=/m);
});

test("Unix compiler selection is preserved and unsafe mapping syntax is rejected", () => {
  const env = nativeCompilerEnvironment({ CC: "cc", CFLAGS: "-DSYNTHETIC=1" }, [["/synthetic checkout", "/source"]], "linux");
  assert.equal(env.CC, "cc");
  assert.equal(env.CMAKE_GENERATOR, undefined);
  assert.equal(env.CFLAGS, '-DSYNTHETIC=1 -ffile-prefix-map="/synthetic checkout"=/source');
  for (const from of ["", '/synthetic"input', "/synthetic;input", "/synthetic\ninput"])
    assert.throws(() => sourcePathMappings([[from, "/source"]], "win32"), /Unsupported compiler/);
});
