import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { mkdtemp, writeFile, symlink, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { gzipSync } from "node:zlib";
import { digest, debApplicationDigest, linuxApplicationDigest, readRpmPayload, appImageFilesystemOffset, inspectTar, inspectCpio, inspectPackage, packageMetadata, standardTool, limits, verifyBuildIdentity, boundedFile } from "../scripts/linux-package-evidence.mjs";

// Only synthetic, in-memory USTAR fixtures. No application or model is run.
const resourceRoot = "usr/lib/lockedin-flow-desktop";
const payload = [
  ["usr/bin/lockedin-flow-desktop", Buffer.from([127, 69, 76, 70, 1, 2, 3])],
  [resourceRoot + "/models/ggml-base.en.bin", Buffer.from("synthetic-model")],
  ...["SBOM.cdx.json", "THIRD-PARTY-NOTICES.txt", "LICENSE.txt", "MODEL.json"].map((label) => [resourceRoot + "/compliance/" + label, Buffer.from("synthetic-" + label)]),
  ["usr/lib/synthetic-native.so", Buffer.from([127, 69, 76, 70, 9])],
];
const expected = {
  application: digest(payload[0][1]), model: digest(payload[1][1]),
  ...Object.fromEntries(payload.slice(2, 6).map(([name, bytes]) => [name.split("/").at(-1), digest(bytes)])),
};
function header(name, size, { type = "0", mode = 0o644, link = "", prefix = "", gnu = false } = {}) {
  const out = Buffer.alloc(512);
  const octal = (value, at, length) => out.write(value.toString(8).padStart(length - 1, "0") + "\0", at, length);
  out.write(name, 0, 100);
  octal(mode, 100, 8);
  octal(0, 108, 8);
  octal(0, 116, 8);
  octal(size, 124, 12);
  octal(0, 136, 12);
  out.fill(32, 148, 156);
  out.write(type, 156);
  out.write(link, 157, 100);
  out.write(gnu ? "ustar  \0" : "ustar\0" + "00", 257);
  if (gnu) { octal(0, 329, 8); octal(0, 337, 8); }
  out.write(prefix, 345, 155);
  out.write(out.reduce((sum, byte) => sum + byte, 0).toString(8).padStart(6, "0") + "\0 ", 148);
  return out;
}
function tar(files = payload) {
  return Buffer.concat([
    ...files.flatMap(([name, value, options]) => {
      const bytes = Buffer.from(value);
      return [header(name, bytes.length, options), bytes, Buffer.alloc((512 - bytes.length % 512) % 512)];
    }), Buffer.alloc(1024),
  ]);
}
function packageBytes(format) {
  const bytes = Buffer.alloc(128);
  if (format === "deb") bytes.write("!<arch>\n");
  if (format === "rpm") bytes.set([237, 171, 238, 219]);
  if (format === "appimage") { bytes.set([127, 69, 76, 70]); bytes.set([65, 73, 2], 8); }
  return bytes;
}

function syntheticAppImage(sectionAfterTable = false) {
  const out = Buffer.alloc(512);
  out.set([127, 69, 76, 70, 2, 1, 1]); out.set([65, 73, 2], 8);
  out.writeUInt16LE(2, 16); out.writeUInt16LE(62, 18); out.writeUInt32LE(1, 20);
  out.writeBigUInt64LE(64n, 32); out.writeBigUInt64LE(128n, 40);
  out.writeUInt16LE(64, 52); out.writeUInt16LE(56, 54); out.writeUInt16LE(1, 56);
  out.writeUInt16LE(64, 58); out.writeUInt16LE(2, 60);
  out.writeUInt32LE(1, 64); out.writeBigUInt64LE(120n, 96);
  out.writeUInt32LE(1, 196);
  out.writeBigUInt64LE(sectionAfterTable ? 256n : 120n, 216);
  out.writeBigUInt64LE(sectionAfterTable ? 32n : 8n, 224);
  const offset = sectionAfterTable ? 288 : 256;
  out.write("hsqs", offset); out.writeUInt16LE(4, offset + 28);
  out.writeBigUInt64LE(96n, offset + 40);
  return out;
}

test("AppImage filesystem boundary follows ELF structure without executing runtime", () => {
  assert.equal(appImageFilesystemOffset(syntheticAppImage()), 256);
  assert.equal(appImageFilesystemOffset(syntheticAppImage(true)), 288);
  const decoy = syntheticAppImage(); decoy.write("hsqs", 120);
  assert.equal(appImageFilesystemOffset(decoy), 256);
});

test("AppImage boundary rejects wrong targets, overflows, absent tables and truncated superblocks", () => {
  const valid = syntheticAppImage();
  for (let length = 0; length < 352; length++) assert.throws(() => appImageFilesystemOffset(valid.subarray(0, length)));
  for (const offset of [0, 4, 5, 6, 8, 10, 16, 18, 20, 52, 54, 56, 58, 60, 256, 284, 286]) {
    const changed = Buffer.from(valid); changed[offset] ^= 255;
    assert.throws(() => appImageFilesystemOffset(changed));
  }
  for (const offset of [32, 40, 72, 96, 216, 224, 296]) {
    const changed = Buffer.from(valid); changed.writeBigUInt64LE(0xffffffffffffffffn, offset);
    assert.throws(() => appImageFilesystemOffset(changed));
  }
  const hidden = Buffer.from(valid); hidden.writeUInt32LE(1, 132); hidden.writeBigUInt64LE(300n, 152); hidden.writeBigUInt64LE(10n, 160);
  assert.throws(() => appImageFilesystemOffset(hidden));
  const segment = Buffer.from(valid); segment.writeBigUInt64LE(300n, 96);
  assert.throws(() => appImageFilesystemOffset(segment));
  assert.throws(() => appImageFilesystemOffset(null));
});

function cpioEntry(name, data, overrides = {}) {
  const value = Buffer.from(data);
  const fields = { ino: 1, mode: 0o100644, uid: 0, gid: 0, links: 1, time: 0,
    size: value.length, major: 0, minor: 0, rmajor: 0, rminor: 0,
    nameSize: Buffer.byteLength(name) + 1, checksum: 0, ...overrides };
  const header = Buffer.from("070701" + Object.values(fields).map((v) => v.toString(16).padStart(8, "0")).join(""));
  const prefix = Buffer.concat([header, Buffer.from(name + "\0")]);
  return Buffer.concat([prefix, Buffer.alloc((4 - prefix.length % 4) % 4), value, Buffer.alloc((4 - value.length % 4) % 4)]);
}
const cpioTrailer = () => cpioEntry("TRAILER!!!", "", { mode: 0 });
const cpio = (files = payload) => Buffer.concat([...files.map(([name, data, options]) => cpioEntry(name, data, options)), cpioTrailer()]);

function rpmHeader(region, strings = []) {
  const count = strings.length + 1;
  const intro = Buffer.from([142, 173, 232, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  const trailer = Buffer.alloc(16);
  trailer.writeUInt32BE(region); trailer.writeUInt32BE(7, 4);
  trailer.writeInt32BE(-16 * count, 8); trailer.writeUInt32BE(16, 12);
  const indexes = Buffer.alloc(count * 16);
  indexes.writeUInt32BE(region); indexes.writeUInt32BE(7, 4); indexes.writeUInt32BE(16, 12);
  const data = [trailer];
  let size = 16;
  strings.forEach(([tag, text], i) => {
    const at = (i + 1) * 16, value = Buffer.from(text + "\0");
    indexes.writeUInt32BE(tag, at); indexes.writeUInt32BE(6, at + 4);
    indexes.writeUInt32BE(size, at + 8); indexes.writeUInt32BE(1, at + 12);
    data.push(value); size += value.length;
  });
  intro.writeUInt32BE(count, 8); intro.writeUInt32BE(size, 12);
  return Buffer.concat([intro, indexes, ...data]);
}
function rpmBytes(archive = cpio(), compressor = "gzip") {
  const lead = Buffer.alloc(96);
  lead.set([237, 171, 238, 219, 3, 0]); lead.writeUInt16BE(5, 78);
  const sig = rpmHeader(62);
  return Buffer.concat([lead, sig, Buffer.alloc((8 - sig.length % 8) % 8), rpmHeader(63, [[1124, "cpio"], [1125, compressor]]), gzipSync(archive)]);
}

test("RPM framing reader preserves exact original CPIO bytes", () => {
  assert.deepEqual(readRpmPayload(rpmBytes()), cpio());
  assert.deepEqual(inspectCpio(readRpmPayload(rpmBytes()), expected), inspectTar(tar(), expected));
  assert.throws(() => readRpmPayload(rpmBytes(cpio(), "xz")));
  const appended = Buffer.concat([rpmBytes(), gzipSync(cpio())]);
  assert.throws(() => inspectCpio(readRpmPayload(appended), expected));
  for (const suffix of [Buffer.from([1]), Buffer.alloc(8)]) assert.throws(() => readRpmPayload(Buffer.concat([rpmBytes(), suffix])));
});

test("RPM rejects truncation, corrupt gzip and invalid bounded header fields", () => {
  const valid = rpmBytes();
  for (let end = 0; end < valid.length; end++) assert.throws(() => readRpmPayload(valid.subarray(0, end)));
  for (const offset of [0, 4, 6, 78, 80, 96, 100, 104, 108, 112, 116, 120, 124, 136, 144, valid.length - 8]) {
    const changed = Buffer.from(valid); changed[offset] ^= 0xff;
    assert.throws(() => readRpmPayload(changed));
  }
  const main = 144;
  for (const [offset, value] of [[main + 8, 0xffffffff], [main + 12, 0xffffffff], [main + 48, 1124], [main + 40, 0xffffffff], [main + 44, 2]]) {
    const changed = Buffer.from(valid); changed.writeUInt32BE(value, offset);
    assert.throws(() => readRpmPayload(changed));
  }
  assert.throws(() => readRpmPayload(null));
});

test("original CPIO reader binds all resources without extraction", () => {
  assert.deepEqual(inspectCpio(cpio(), expected), inspectTar(tar(), expected));
  const prefixed = payload.map(([name, data]) => ["./" + name, data]);
  assert.deepEqual(inspectCpio(cpio(prefixed), expected), inspectTar(tar(), expected));
  assert.equal(inspectCpio(Buffer.concat([cpio(), Buffer.alloc(512)]), expected).length, payload.length);
  assert.throws(() => inspectCpio(cpio(), { ...expected, application: "0".repeat(64) }));
  assert.throws(() => inspectCpio(cpio(), { ...expected, model: "0".repeat(64) }));
});

test("CPIO rejects ambiguous paths, links, devices and privileged entries", () => {
  for (const name of ["../escape", "/absolute", "usr//bad", "usr/./bad", "usr/../bad", "bad\0name", "bad\nname", "usr/bin/lockedin-flow-desktop"]) {
    assert.throws(() => inspectCpio(cpio([...payload, [name, "x"]]), expected));
  }
  for (const options of [{ links: 2 }, { links: 0 }, { mode: 0o120777 }, { mode: 0o020600 },
    { mode: 0o104755 }, { mode: 0o100000 + 0x80000000 }, { rmajor: 1 }, { checksum: 1 }, { mode: 0o040755 }]) {
    assert.throws(() => inspectCpio(cpio([...payload, ["extra", "x", options]]), expected));
  }
  assert.throws(() => inspectCpio(cpio([...payload, ["usr", "x"]]), expected));
  const withDirectory = cpio([...payload, ["usr", "", { mode: 0o040755, links: 2 }]]);
  assert.equal(inspectCpio(withDirectory, expected).length, payload.length + 1);
});

test("CPIO requires full framing, bounded fields and one final trailer", () => {
  const valid = cpio();
  for (let size = 0; size < valid.length; size++) {
    assert.throws(() => inspectCpio(valid.subarray(0, size), expected));
  }
  for (const offset of [0, 6, 109, 110 + Buffer.byteLength(payload[0][0])]) {
    const changed = Buffer.from(valid);
    changed[offset] = 255;
    assert.throws(() => inspectCpio(changed, expected));
  }
  for (const options of [{ nameSize: 0 }, { nameSize: 0xffffffff }, { size: 0xffffffff }]) {
    assert.throws(() => inspectCpio(cpio([[payload[0][0], payload[0][1], options], ...payload.slice(1)]), expected));
  }
  assert.throws(() => inspectCpio(Buffer.concat([valid, cpio()]), expected));
  assert.throws(() => inspectCpio(Buffer.concat([valid, Buffer.from([1])]), expected));
  assert.throws(() => inspectCpio(Buffer.concat([valid.subarray(0, valid.length - cpioTrailer().length), cpioEntry("TRAILER!!!", "x", { mode: 0 })]), expected));
  assert.throws(() => inspectCpio("not bytes", expected));
});

test("payload hashes bind the exact binary, model and four compliance resources", () => {
  const files = inspectTar(tar(), expected);
  assert.equal(files.length, payload.length);
  assert.equal(files.filter((file) => file.verifiedResource).length, 6);
  assert.equal(files.filter((file) => file.elf).length, 2);
  assert.ok(files.every((file) => file.componentMapping === "unresolved"));
  assert.ok(files.every((file) => /^[a-f0-9]{64}$/.test(file.pathSha256)));
  assert.doesNotMatch(JSON.stringify(files), /synthetic-native|synthetic-model|usr\//);
});

test("DEB reference follows pinned bundle patching without weakening full-file identity", () => {
  const prefix = Buffer.from([127, 69, 76, 70]);
  const source = Buffer.concat([prefix, Buffer.from("__TAURI_BUNDLE_TYPE_VAR_UNK"), Buffer.from("synthetic-code")]);
  const before = Buffer.from(source);
  const packaged = Buffer.from(source);
  Buffer.from("__TAURI_BUNDLE_TYPE_VAR_DEB").copy(packaged, prefix.length);
  const reference = { ...expected, application: debApplicationDigest(source) };
  const packageWith = (app) => tar([[payload[0][0], app], ...payload.slice(1)]);
  assert.notEqual(reference.application, digest(source));
  assert.equal(reference.application, digest(packaged));
  assert.equal(inspectTar(packageWith(packaged), reference).filter((file) => file.verifiedResource).length, 6);
  for (const kind of ["UNK", "RPM", "APP"]) {
    const wrong = Buffer.from(packaged);
    Buffer.from("__TAURI_BUNDLE_TYPE_VAR_" + kind).copy(wrong, prefix.length);
    assert.throws(() => inspectTar(packageWith(wrong), reference), (error) => error.category === "resource-application-hash");
  }
  const corrupted = Buffer.from(packaged);
  corrupted[corrupted.length - 1] ^= 1;
  assert.throws(() => inspectTar(packageWith(corrupted), reference), (error) => error.category === "resource-application-hash");
  assert.deepEqual(source, before);
  const runtimeConstants = Buffer.from(["DEB", "RPM", "APP", "NSS", "MSI"].map((kind) => "__TAURI_BUNDLE_TYPE_VAR_" + kind).join("\0"));
  assert.equal(debApplicationDigest(Buffer.concat([source, runtimeConstants])), digest(Buffer.concat([packaged, runtimeConstants])));
  for (const invalid of [null, "text", Buffer.alloc(0), prefix,
    Buffer.from("__TAURI_BUNDLE_TYPE_VAR_UNK"), packaged,
    Buffer.concat([source, Buffer.from("__TAURI_BUNDLE_TYPE_VAR_UNK")]),
  ]) assert.throws(() => debApplicationDigest(invalid));
});

test("RPM reference derives the pinned producer token independently of packaged bytes", () => {
  const source = Buffer.concat([Buffer.from([127, 69, 76, 70]), Buffer.from("__TAURI_BUNDLE_TYPE_VAR_UNK\0synthetic-code\0__TAURI_BUNDLE_TYPE_VAR_DEB\0__TAURI_BUNDLE_TYPE_VAR_RPM")]);
  const unchanged = Buffer.from(source);
  const packaged = Buffer.from(source);
  Buffer.from("__TAURI_BUNDLE_TYPE_VAR_RPM").copy(packaged, 4);
  const reference = { ...expected, application: linuxApplicationDigest(source, "rpm") };
  assert.equal(reference.application, digest(packaged));
  assert.notEqual(reference.application, linuxApplicationDigest(source, "deb"));
  assert.deepEqual(source, unchanged);
  assert.equal(inspectCpio(cpio([[payload[0][0], packaged], ...payload.slice(1)]), reference).filter((file) => file.verifiedResource).length, 6);
  const changed = Buffer.from(packaged);
  changed[changed.length - 1] ^= 1;
  for (const wrong of [changed, source]) {
    assert.throws(() => inspectCpio(cpio([[payload[0][0], wrong], ...payload.slice(1)]), reference));
  }
  for (const format of [undefined, "RPM", "appimage", "", null]) assert.throws(() => linuxApplicationDigest(source, format));
  assert.throws(() => linuxApplicationDigest(packaged, "rpm"));
  assert.throws(() => linuxApplicationDigest(Buffer.concat([source, Buffer.from("__TAURI_BUNDLE_TYPE_VAR_UNK")]), "rpm"));
});

test("bounded input reader rejects oversized files, empty files, directories, FIFOs and symlinks", { skip: process.platform === "win32" }, async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "flow-inventory-fixture-"));
  try {
    const file = path.join(directory, "synthetic");
    await writeFile(file, "synthetic", { flag: "wx" });
    assert.equal((await boundedFile(file, 9)).toString(), "synthetic");
    await assert.rejects(boundedFile(file, 3));
    await assert.rejects(boundedFile(directory, 1024));
    await writeFile(path.join(directory, "empty"), "", { flag: "wx" });
    await assert.rejects(boundedFile(path.join(directory, "empty"), 1024));
    await symlink(file, path.join(directory, "link"));
    await assert.rejects(boundedFile(path.join(directory, "link"), 1024));
    standardTool("/usr/bin/mkfifo", [path.join(directory, "fifo")]);
    await assert.rejects(boundedFile(path.join(directory, "fifo"), 1024));
  } finally { await rm(directory, { recursive: true, force: true }); }
});

test("build identity rejects mismatched checkout, target, locks, dirty state and duplicate properties", () => {
  const revision = "a".repeat(40), cargo = "b".repeat(64), npm = "c".repeat(64);
  const properties = Object.entries({
    "lockedin:source-revision": revision, "lockedin:source-state": "clean",
    "lockedin:target": "x86_64-unknown-linux-gnu", "lockedin:cargo-lock-sha256": cargo, "lockedin:npm-lock-sha256": npm,
  }).map(([name, value]) => ({ name, value }));
  const sbom = { bomFormat: "CycloneDX", specVersion: "1.6", metadata: { properties } };
  verifyBuildIdentity(sbom, revision, cargo, npm);
  for (let index = 0; index < properties.length; index++) {
    const changed = structuredClone(sbom);
    changed.metadata.properties[index].value = "different";
    assert.throws(() => verifyBuildIdentity(changed, revision, cargo, npm));
  }
  sbom.metadata.properties.push(properties[0]);
  assert.throws(() => verifyBuildIdentity(sbom, revision, cargo, npm));
});

test("rejects traversal, absolute paths, unsafe characters, aliases and non-directory ancestors", () => {
  for (const name of ["../escape", "/absolute", "usr/../escape", "usr//file", "usr/./file", "C:\\escape", "usr/hidden\nvalue"])
    assert.throws(() => inspectTar(tar([...payload, [name, "x"]]), expected), /details withheld/);
  assert.throws(() => inspectTar(tar([...payload, ["./" + payload[0][0], payload[0][1]]]), expected));
  assert.throws(() => inspectTar(tar([...payload, ["usr", "not-a-directory"]]), expected));
});

test("rejects links (including otherwise safe ones), devices, FIFOs, extensions and privilege bits", () => {
  for (const type of ["1", "2", "3", "4", "6", "x", "g", "S"])
    assert.throws(() => inspectTar(tar([...payload, ["usr/link", "", { type, link: "../private-target" }]]), expected));
  assert.throws(() => inspectTar(tar([...payload, ["usr/link", "", { type: "2", link: "bin/lockedin-flow-desktop" }]]), expected));
  for (const mode of [0o4755, 0o2755, 0o1777])
    assert.throws(() => inspectTar(tar([...payload, ["usr/privileged", "x", { mode }]]), expected));
});

test("rejects bad checksums, missing terminators, hidden tails, truncated and oversized members", () => {
  const corrupt = tar(); corrupt[20] ^= 1;
  assert.throws(() => inspectTar(corrupt, expected));
  assert.throws(() => inspectTar(tar().subarray(0, -1024), expected));
  assert.throws(() => inspectTar(tar().subarray(0, -1), expected));
  assert.throws(() => inspectTar(Buffer.concat([tar(), tar()]), expected));
  assert.throws(() => inspectTar(Buffer.concat([header("usr/huge", limits.file + 1), Buffer.alloc(1024)]), expected));
  assert.throws(() => inspectTar(Buffer.concat([header("usr/missing", 4096), Buffer.alloc(1024)]), expected));
});

test("entry count is bounded even when members contain no data", () => {
  const files = Array.from({ length: limits.entries + 1 }, (_, index) => ["usr/entry-" + index, ""]);
  assert.throws(() => inspectTar(tar(files), expected));
});

test("rejects missing, changed, duplicated or relocated staged resources", () => {
  assert.throws(() => inspectTar(tar(payload.slice(1)), expected));
  assert.throws(() => inspectTar(tar(), { ...expected, model: "0".repeat(64) }));
  assert.throws(() => inspectTar(tar(), { ...expected, application: "0".repeat(64) }));
  assert.throws(() => inspectTar(tar([...payload, ["usr/extra/compliance/MODEL.json", payload[5][1]]]), expected));
  const moved = payload.map(([name, bytes]) => [name.replace("/compliance/", "/elsewhere/compliance/"), bytes]);
  assert.throws(() => inspectTar(tar(moved), expected));
});

test("metadata uses actual query fields and hashes unreviewed dependency declarations", () => {
  const data = packageMetadata("rpm", "lockedin-flow\n0.5.0-1\nx86_64\n", "libexample.so.1()(64bit)\n/private-synthetic/requirement\n");
  assert.equal(data.declaredVersion, "0.5.0-1");
  assert.equal(data.declaredOsDependencies.scope, "requirements-not-bundled-components");
  assert.equal(data.declaredOsDependencies.recordSha256.length, 2);
  assert.doesNotMatch(JSON.stringify(data), /libexample|private-synthetic/);
  for (const identity of ["foreign\n0.5.0\namd64", "lockedin-flow\nprivate/value\namd64", "lockedin-flow\n0.5.0-client-private\namd64", "lockedin-flow\n0.5.0\narm64", "lockedin-flow\n0.5.0\namd64\nextra"])
    assert.throws(() => packageMetadata("deb", identity, ""));
  assert.throws(() => packageMetadata("deb", "lockedin-flow\n0.5.0\namd64", "injected\u001b[31m"));
  assert.throws(() => packageMetadata("deb", "x".repeat(limits.metadata + 1), ""));
});

test("DEB adapter queries metadata and checks the bounded original stream without normalization", () => {
  const calls = [];
  const run = (command, args, input, cap) => {
    calls.push({ command, args, input, cap });
    if (args[0] === "--field") return Buffer.from(({ Package: "lockedin-flow", Version: "0.5.0-alpha.1", Architecture: "amd64", Depends: "libc6", "Pre-Depends": "" })[args[2]] + "\n");
    assert.equal(command, "/usr/bin/dpkg-deb");
    assert.deepEqual(args, ["--fsys-tarfile", "/synthetic/input.deb"]);
    assert.equal(cap, limits.payload);
    return tar();
  };
  const bytes = packageBytes("deb");
  const report = inspectPackage("deb", "/synthetic/input.deb", bytes, expected, run);
  assert.equal(report.status, "payload-inspected");
  assert.equal(report.sha256, digest(bytes));
  assert.equal(report.licenseReview, "unresolved");
  assert.ok(calls.every(({ args }) => !args.includes("--install") && !args.includes("-x")));
  assert.doesNotMatch(JSON.stringify(report), /synthetic\/input|libc6/);
});

test("DEB adapter validates original framing before any normalizer can hide trailing data", () => {
  const clean = tar(payload.slice(0, 6));
  const concatenated = Buffer.concat([clean, tar([["usr/trailing-synthetic-link", "", { type: "2", link: "../../outside-synthetic" }]])]);
  const tail = Buffer.concat([clean, Buffer.alloc(512, 0x58)]);
  const calls = [];
  for (const [stream, size, status] of [[clean, 7168, "payload-inspected"], [concatenated, 8704, "unverified"], [tail, 7680, "unverified"]]) {
    assert.equal(stream.length, size);
    const run = (command, args) => {
      calls.push(command);
      if (command === "/usr/bin/bsdtar") return clean; // Model the normalizer discarding trailing data.
      assert.equal(command, "/usr/bin/dpkg-deb");
      if (args[0] === "--fsys-tarfile") return stream;
      return Buffer.from(({ Package: "lockedin-flow", Version: "0.5.0", Architecture: "amd64", Depends: "", "Pre-Depends": "" })[args[2]] + "\n");
    };
    const report = inspectPackage("deb", "/synthetic/owned.deb", packageBytes("deb"), expected, run);
    assert.equal(report.status, status, `Original ${size}-byte stream must determine inspection status`);
    if (status === "unverified") {
      assert.equal(report.files, null);
      assert.equal(report.reason, "tool-or-payload-validation-failed");
    }
  }
  assert.ok(calls.every((command) => command === "/usr/bin/dpkg-deb"), "Original bytes must not be normalized");
});

test("GNU without producer metadata and PAX stay unverified instead of being normalized", () => {
  const gnu = tar();
  gnu.write("ustar  \0", 257);
  gnu.fill(32, 148, 156);
  gnu.write(gnu.subarray(0, 512).reduce((sum, byte) => sum + byte, 0).toString(8).padStart(6, "0") + "\0 ", 148);
  const pax = tar([["PaxHeader", "", { type: "x" }], ...payload]);
  for (const stream of [gnu, pax]) {
    const calls = [];
    const run = (command, args) => {
      calls.push(command);
      if (command === "/usr/bin/bsdtar") return tar();
      assert.equal(command, "/usr/bin/dpkg-deb");
      if (args[0] === "--fsys-tarfile") return stream;
      return Buffer.from(({ Package: "lockedin-flow", Version: "0.5.0", Architecture: "amd64", Depends: "", "Pre-Depends": "" })[args[2]] + "\n");
    };
    const report = inspectPackage("deb", "/synthetic/unsupported.deb", packageBytes("deb"), expected, run);
    assert.equal(report.status, "unverified");
    assert.equal(report.files, null);
    assert.ok(calls.every((command) => command === "/usr/bin/dpkg-deb"));
  }
});

// tar 0.4.46 new_gnu + deterministic Unix metadata, with no extension records.
const ordinaryGnu = () => tar(payload.slice(0, 6).map(([name, bytes], index) => [name, bytes, { gnu: true, mode: index === 0 ? 0o755 : 0o644 }]));
function checksumFirstHeader(stream) {
  stream.fill(32, 148, 156);
  stream.write(stream.subarray(0, 512).reduce((sum, byte) => sum + byte, 0).toString(8).padStart(6, "0") + "\0 ", 148);
  return stream;
}
function inspectOriginalDeb(stream) {
  const calls = [];
  const run = (command, args) => {
    calls.push(command);
    assert.equal(command, "/usr/bin/dpkg-deb");
    if (args[0] === "--fsys-tarfile") return stream;
    return Buffer.from(({ Package: "lockedin-flow", Version: "0.5.0", Architecture: "amd64", Depends: "", "Pre-Depends": "" })[args[2]] + "\n");
  };
  const report = inspectPackage("deb", "/synthetic/ordinary-gnu.deb", packageBytes("deb"), expected, run);
  assert.ok(calls.every((command) => command === "/usr/bin/dpkg-deb"));
  return report;
}

test("ordinary producer GNU files and directories are inspected directly with permission-only modes", () => {
  const stream = ordinaryGnu();
  assert.equal(stream.length, 7168);
  assert.equal(inspectTar(stream, expected).length, 6);
  const report = inspectOriginalDeb(stream);
  assert.equal(report.status, "payload-inspected");
  assert.equal(report.files.find((file) => file.verifiedResource === "application").mode, 0o755);
  assert.ok(report.files.filter((file) => file.verifiedResource !== "application").every((file) => file.mode === 0o644));
  const withDirectory = tar([["usr", "", { gnu: true, type: "5", mode: 0o755 }], ...payload.map(([name, bytes]) => [name, bytes, { gnu: true }])]);
  assert.equal(inspectOriginalDeb(withDirectory).status, "payload-inspected");
  assert.equal(inspectTar(withDirectory, expected).find((file) => file.type === "directory").mode, 0o755);
});

test("GNU fields cannot become a USTAR prefix or activate time/offset/sparse extensions", () => {
  for (const offset of [345, 357, 369, 381, 385, 386, 410, 434, 458, 482, 483, 495, 511]) {
    const stream = ordinaryGnu(); stream[offset] = 49; checksumFirstHeader(stream);
    assert.throws(() => inspectTar(stream, expected));
    assert.equal(inspectOriginalDeb(stream).status, "unverified");
  }
  for (const type of ["L", "K", "S", "x", "g", "1", "2", "3", "4", "6"]) {
    const stream = ordinaryGnu(); stream.write(type, 156); checksumFirstHeader(stream);
    assert.throws(() => inspectTar(stream, expected));
    assert.equal(inspectOriginalDeb(stream).files, null);
  }
});

test("GNU mode validation does not mask file-type or privilege bits", () => {
  for (const mode of [0o100644, 0o100755, 0o4755, 0o2755, 0o1777, 0o666]) {
    const stream = ordinaryGnu(); stream.write(mode.toString(8).padStart(7, "0") + "\0", 100); checksumFirstHeader(stream);
    assert.throws(() => inspectTar(stream, expected));
    assert.equal(inspectOriginalDeb(stream).status, "unverified");
  }
  for (const mode of [0o644, 0o40755]) {
    const stream = tar([["usr", "", { gnu: true, type: "5", mode }], ...payload.map(([name, bytes]) => [name, bytes, { gnu: true }])]);
    assert.equal(inspectOriginalDeb(stream).status, "unverified");
  }
});

test("GNU producer metadata and magic are byte-checked, not silently reinterpreted", () => {
  for (const offset of [108, 116, 265, 297, 329, 337, 136]) {
    const stream = ordinaryGnu(); stream[offset] = offset === 136 ? 90 : 49; checksumFirstHeader(stream);
    assert.equal(inspectOriginalDeb(stream).status, "unverified");
  }
  for (const offset of [257, 263]) {
    const stream = ordinaryGnu(); stream[offset] |= 128; checksumFirstHeader(stream);
    assert.equal(inspectOriginalDeb(stream).status, "unverified");
  }
});

test("GNU acceptance preserves full-stream framing, no-links and path guards", () => {
  const clean = ordinaryGnu();
  const hidden = Buffer.concat([clean, tar([["usr/trailing-link", "", { gnu: true, type: "2", link: "../../outside" }]])]);
  const tail = Buffer.concat([clean, Buffer.alloc(512, 0x58)]);
  assert.equal(hidden.length, 8704);
  assert.equal(tail.length, 7680);
  for (const stream of [hidden, tail, clean.subarray(0, -512)]) {
    assert.throws(() => inspectTar(stream, expected));
    const report = inspectOriginalDeb(stream);
    assert.equal(report.status, "unverified");
    assert.equal(report.files, null);
  }
  for (const name of ["../outside", "/absolute", "usr/../escape", "usr/bin/lockedin-flow-desktop"]) {
    const stream = tar([...payload.map(([entry, bytes]) => [entry, bytes, { gnu: true }]), [name, "x", { gnu: true }]]);
    assert.equal(inspectOriginalDeb(stream).status, "unverified");
  }
});

test("RPM metadata and original payload are checked without invoking a normalizer", () => {
  const calls = [];
  const run = (command, args) => {
    calls.push(command);
    assert.equal(command, "/usr/bin/rpm");
    if (args.includes("--queryformat")) return Buffer.from("lockedin-flow\n0.5.0-1\nx86_64\n");
    if (args.includes("--requires")) return Buffer.from("libc.so.6\n");
    assert.fail("Only RPM metadata queries are permitted");
  };
  const report = inspectPackage("rpm", "/synthetic/misleading-9.9.rpm", rpmBytes(), expected, run);
  assert.equal(report.status, "payload-inspected");
  assert.equal(report.files.filter((file) => file.verifiedResource).length, 6);
  assert.equal(report.sha256, digest(rpmBytes()));
  assert.equal(calls.length, 2);
  assert.ok(calls.every((command) => command === "/usr/bin/rpm"));
  assert.equal(report.metadata.declaredVersion, "0.5.0-1");
  const invalid = inspectPackage("rpm", "/synthetic/bad.rpm", packageBytes("rpm"), expected, run);
  assert.equal(invalid.status, "unverified");
  assert.equal(invalid.reason, "tool-or-payload-validation-failed");
  assert.equal(invalid.files, null);
});

test("tool errors and malformed payloads stay unverified with no raw diagnostics", () => {
  const report = inspectPackage("rpm", "/synthetic/private.rpm", packageBytes("rpm"), expected, () => { throw new Error("private-diagnostic-secret"); });
  assert.equal(report.status, "unverified");
  assert.equal(report.files, null);
  assert.doesNotMatch(JSON.stringify(report), /private|secret/);
  assert.throws(() => standardTool(process.execPath, ["-e", "process.stderr.write('private-diagnostic-secret'); process.exit(1)"]), /^Error: Package evidence rejected; input details withheld\.$/);
  assert.throws(() => standardTool(process.execPath, ["-e", "process.stdout.write('x'.repeat(4096))"], undefined, 128), /details withheld/);
});

test("malformed AppImage remains unverified; its runtime is never invoked", () => {
  const bytes = packageBytes("appimage");
  const report = inspectPackage("appimage", "/synthetic/app.AppImage", bytes, expected, () => assert.fail("Must not run any AppImage helper"));
  assert.equal(report.sha256, digest(bytes));
  assert.equal(report.status, "unverified");
  assert.equal(report.reason, "tool-or-payload-validation-failed");
  assert.equal(report.failureStage, "archive-header");
  assert.equal(report.files, null);
  assert.throws(() => inspectPackage("appimage", "unused", packageBytes("deb"), expected));
});

test("installed bsdtar converts a synthetic stream without hiding unsafe names", { skip: !existsSync("/usr/bin/bsdtar") }, () => {
  const converted = standardTool("/usr/bin/bsdtar", ["-cPf", "-", "--format=ustar", "@-"], tar(), limits.payload);
  assert.deepEqual(inspectTar(converted, expected), inspectTar(tar(), expected));
  const unsafe = standardTool("/usr/bin/bsdtar", ["-cPf", "-", "--format=ustar", "@-"], tar([...payload, ["/absolute-synthetic", "x"]]), limits.payload);
  assert.throws(() => inspectTar(unsafe, expected));
  const cpio = standardTool("/usr/bin/bsdtar", ["-cPf", "-", "--format=newc", "@-"], tar(), limits.payload);
  const normalized = standardTool("/usr/bin/bsdtar", ["-cPf", "-", "--format=ustar", "@-"], cpio, limits.payload);
  assert.deepEqual(inspectTar(normalized, expected), inspectTar(tar(), expected));
});

test("DEB failure stages distinguish tools and validation without exposing exception content", () => {
  const inspect = ({ failure = -1, version = "0.5.0-alpha.1", stream = tar(), resources = expected } = {}) => {
    let call = 0;
    const values = ["locked-in-flow", version, "amd64", "libc6", ""];
    return inspectPackage("deb", "/synthetic/input.deb", packageBytes("deb"), resources, () => {
      const index = call++;
      if (index === failure) throw Object.assign(new Error("synthetic-private-diagnostics"), { category: "synthetic-private-category" });
      return index < 5 ? Buffer.from(values[index] + "\n") : stream;
    });
  };
  for (const [failure, stage] of [[0, "identity-query"], [1, "identity-query"], [2, "identity-query"], [3, "dependency-query"], [4, "dependency-query"], [5, "payload-read"]]) {
    const result = inspect({ failure });
    assert.equal(result.failureStage, stage);
    assert.equal(result.status, "unverified");
    assert.equal(result.metadata, null);
    assert.equal(result.files, null);
    assert.doesNotMatch(JSON.stringify(result), /synthetic-private/);
  }
  const badChecksum = tar(); badChecksum[20] ^= 1;
  const badHeader = tar(); badHeader[257] = 0;
  for (const [options, stage] of [
    [{ version: "not-a-version" }, "metadata-validation"],
    [{ stream: Buffer.concat([tar(), tar()]) }, "archive-framing"],
    [{ stream: badChecksum }, "archive-checksum"],
    [{ stream: badHeader }, "archive-header"],
    [{ stream: tar([...payload, ["../escape", "x"]]) }, "archive-path"],
    [{ stream: tar([...payload, ["usr/link", "", { type: "2", link: "bin/example" }]]) }, "archive-entry-type"],
    [{ stream: Buffer.concat([header("usr/huge", limits.file + 1), Buffer.alloc(1024)]) }, "archive-bounds"],
    [{ resources: { ...expected, application: "0".repeat(64) } }, "resource-application-hash"],
  ]) {
    const result = inspect(options);
    assert.equal(result.failureStage, stage);
    assert.equal(result.reason, "tool-or-payload-validation-failed");
    assert.equal(result.status, "unverified");
  }
  assert.equal(inspect().status, "payload-inspected");
  assert.equal(Object.hasOwn(inspect(), "failureStage"), false);
});

test("DEB resource diagnostics distinguish every predicate without exposing offending content", () => {
  const inspect = (files = payload, resources = expected) => {
    let call = 0;
    const values = ["locked-in-flow", "0.5.0-alpha.1", "amd64", "", ""];
    return inspectPackage("deb", "/synthetic/input.deb", packageBytes("deb"), resources, () => {
      const index = call++;
      return index < 5 ? Buffer.from(values[index] + "\n") : tar(files);
    });
  };
  const cases = [
    [payload.filter((_, i) => i !== 1), expected, "resource-model-count"],
    [[...payload, ["usr/extra/models/ggml-base.en.bin", payload[1][1]]], expected, "resource-model-count"],
    [payload, { ...expected, model: "0".repeat(64) }, "resource-model-hash"],
    [payload.slice(1), expected, "resource-application-missing"],
    [payload.map(([p, b], i) => [p, i === 0 ? Buffer.from("synthetic-not-elf") : b]), expected, "resource-application-format"],
    [payload, { ...expected, application: "0".repeat(64) }, "resource-application-hash"],
  ];
  for (let i = 2; i < 6; i++) {
    const label = payload[i][0].split("/").at(-1);
    cases.push(
      [payload.filter((_, index) => index !== i), expected, "resource-compliance-count"],
      [[...payload, ["usr/extra/compliance/" + label, payload[i][1]]], expected, "resource-compliance-count"],
      [payload.map(([p, b], index) => [index === i ? "usr/elsewhere/compliance/" + label : p, b]), expected, "resource-compliance-location"],
      [payload, { ...expected, [label]: "0".repeat(64) }, "resource-compliance-hash"],
    );
  }
  for (const [files, resources, stage] of cases) {
    const result = inspect(files, resources);
    assert.equal(result.failureStage, stage);
    assert.equal(result.status, "unverified");
    assert.equal(result.reason, "tool-or-payload-validation-failed");
    assert.equal(result.metadata, null);
    assert.equal(result.files, null);
    assert.deepEqual(Object.keys(result).sort(), ["format", "bytes", "sha256", "status", "licenseReview", "reason", "metadata", "files", "failureStage"].sort());
    assert.doesNotMatch(JSON.stringify(result), /synthetic|ggml|SBOM|MODEL|LICENSE|NOTICES|usr/);
  }
  assert.equal(inspect().status, "payload-inspected");
});
