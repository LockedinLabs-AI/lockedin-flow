import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { constants } from "node:fs";
import { open } from "node:fs/promises";
import { gunzipSync } from "node:zlib";
import { squashfsEntries } from "./squashfs-evidence.mjs";

export const limits = Object.freeze({ package: 512 * 1024 ** 2, payload: 768 * 1024 ** 2, file: 256 * 1024 ** 2, entries: 10000, metadata: 1024 * 1024 });
export const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");

// Tauri CLI 2.12.0 patches its first bundle token before copying the executable
// into a package, then restores the build output. Derive the expected bytes
// from that independent output; never normalize or trust the package payload.
export function debApplicationDigest(reference) {
  return linuxApplicationDigest(reference, "deb");
}

export function linuxApplicationDigest(reference, format) {
  if (!["deb", "rpm"].includes(format)) throw new Error("Unsupported application reference format.");
  const token = Buffer.from("__TAURI_BUNDLE_TYPE_VAR_UNK");
  if (!Buffer.isBuffer(reference) || reference.length > limits.file
      || !reference.subarray(0, 4).equals(Buffer.from([127, 69, 76, 70]))) throw new Error("Invalid application reference.");
  const offset = reference.indexOf(token);
  // Runtime dispatch also contains the other format strings; preserve them.
  if (offset < 0 || reference.indexOf(token, offset + 1) !== -1) {
    throw new Error("Ambiguous application reference.");
  }
  const packaged = Buffer.from(reference);
  Buffer.from("__TAURI_BUNDLE_TYPE_VAR_" + format.toUpperCase()).copy(packaged, offset);
  return digest(packaged);
}
class EvidenceFailure extends Error {
  constructor(category) {
    super("Package evidence rejected; input details withheld.");
    this.category = category;
  }
}
const fail = (category = "archive-header") => { throw new EvidenceFailure(category); };
const names = new Set(["lockedin-flow", "locked-in-flow", "lockedin-flow-desktop", "locked-in-flow-desktop"]);
const required = ["SBOM.cdx.json", "THIRD-PARTY-NOTICES.txt", "LICENSE.txt", "MODEL.json"];

// Narrow Linux x86-64 type-2 boundary reader. Match the runtime's section-table
// rule, then ensure no other file-backed section/segment extends into its payload.
// This locates SquashFS only; it does not inspect filesystem entries or execute ELF.
export function appImageFilesystemOffset(bytes) {
  if (!Buffer.isBuffer(bytes) || bytes.length < 160 || bytes.length > limits.package
      || !bytes.subarray(0, 7).equals(Buffer.from([127, 69, 76, 70, 2, 1, 1]))
      || !bytes.subarray(8, 11).equals(Buffer.from([65, 73, 2]))
      || ![2, 3].includes(bytes.readUInt16LE(16)) || bytes.readUInt16LE(18) !== 62
      || bytes.readUInt32LE(20) !== 1 || bytes.readUInt16LE(52) !== 64) fail();
  const read64 = (offset) => {
    const value = bytes.readBigUInt64LE(offset);
    if (value > BigInt(bytes.length)) fail("archive-bounds");
    return Number(value);
  };
  const table = read64(40), size = bytes.readUInt16LE(58), count = bytes.readUInt16LE(60);
  if (table < 64 || size !== 64 || count < 1 || count > 4096 || table + size * count > bytes.length) fail("archive-bounds");
  const tableEnd = table + size * count, last = tableEnd - size;
  const offset = Math.max(tableEnd, read64(last + 24) + read64(last + 32));
  if (offset + 96 > bytes.length) fail("archive-bounds");
  for (let i = 0; i < count; i++) {
    const at = table + size * i;
    if (bytes.readUInt32LE(at + 4) !== 8 && read64(at + 24) + read64(at + 32) > offset) fail("archive-bounds");
  }
  const programs = read64(32), programSize = bytes.readUInt16LE(54), programCount = bytes.readUInt16LE(56);
  if (programCount < 1 || programCount > 4096 || programSize !== 56 || programs < 64
      || programs + programSize * programCount > offset) fail("archive-bounds");
  for (let i = 0; i < programCount; i++) {
    const at = programs + programSize * i;
    if (read64(at + 8) + read64(at + 32) > offset) fail("archive-bounds");
  }
  if (!bytes.subarray(offset, offset + 4).equals(Buffer.from("hsqs"))
      || bytes.readUInt16LE(offset + 28) !== 4 || bytes.readUInt16LE(offset + 30) !== 0) fail();
  const used = read64(offset + 40);
  if (used < 96 || offset + used > bytes.length) fail("archive-bounds");
  return offset;
}

// Locate the original payload without rpm2cpio/tar normalization. RPM metadata
// semantics/signatures still require librpm; this only validates bounded framing
// and the pinned producer's cpio+gzip declaration. Never executes package code.
export function readRpmPayload(bytes) {
  if (!Buffer.isBuffer(bytes) || bytes.length < 128 || bytes.length > limits.package
      || !bytes.subarray(0, 6).equals(Buffer.from([237, 171, 238, 219, 3, 0]))
      || bytes.readUInt16BE(6) !== 0 || bytes.readUInt16BE(78) !== 5
      || bytes.subarray(80, 96).some((byte) => byte !== 0)) fail();
  function header(at, region) {
    if (at + 16 > bytes.length || !bytes.subarray(at, at + 8).equals(Buffer.from([142, 173, 232, 1, 0, 0, 0, 0]))) fail();
    const count = bytes.readUInt32BE(at + 8), size = bytes.readUInt32BE(at + 12);
    if (count < 1 || count > 4096 || size < 16 || size > limits.metadata) fail("archive-bounds");
    const start = at + 16 + count * 16, end = start + size;
    if (end > bytes.length) fail("archive-bounds");
    let previous = 0, values = 0;
    const strings = new Map();
    for (let i = 0; i < count; i++) {
      const index = at + 16 + i * 16;
      const tag = bytes.readUInt32BE(index), type = bytes.readUInt32BE(index + 4);
      const offset = bytes.readInt32BE(index + 8), length = bytes.readUInt32BE(index + 12);
      if (tag <= previous || type < 1 || type > 9 || offset < 0 || offset >= size || length < 1 || length > limits.metadata) fail();
      values += length;
      if (values > limits.entries * 16) fail("archive-bounds");
      previous = tag;
      const widths = { 1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 7: 1 };
      if (widths[type]) {
        if (offset % widths[type] || offset + widths[type] * length > size) fail("archive-bounds");
      } else {
        if (type === 6 && length !== 1) fail();
        let cursor = start + offset;
        for (let n = 0; n < length; n++) {
          const zero = bytes.indexOf(0, cursor);
          if (zero < cursor || zero >= end) fail("archive-bounds");
          if (type === 6 && [1124, 1125].includes(tag)) strings.set(tag, bytes.subarray(cursor, zero));
          cursor = zero + 1;
        }
      }
      if (i === 0) {
        const trailer = start + offset;
        if (tag !== region || type !== 7 || length !== 16
            || bytes.readUInt32BE(trailer) !== region || bytes.readUInt32BE(trailer + 4) !== 7
            || bytes.readInt32BE(trailer + 8) !== -count * 16 || bytes.readUInt32BE(trailer + 12) !== 16) fail();
      }
    }
    return { end, strings };
  }
  const signature = header(96, 62);
  const next = Math.ceil(signature.end / 8) * 8;
  if (next > bytes.length || bytes.subarray(signature.end, next).some((byte) => byte !== 0)) fail("archive-framing");
  const main = header(next, 63);
  if (!main.strings.get(1124)?.equals(Buffer.from("cpio"))
      || !main.strings.get(1125)?.equals(Buffer.from("gzip"))) fail();
  const compressed = bytes.subarray(main.end);
  if (!compressed.subarray(0, 3).equals(Buffer.from([31, 139, 8]))) fail();
  try {
    const decoded = gunzipSync(compressed, { maxOutputLength: limits.payload, info: true });
    if (decoded.engine.bytesWritten !== compressed.length) fail("archive-framing");
    return decoded.buffer;
  } catch { fail("archive-framing"); }
}

export async function boundedFile(file, maximum) {
  const handle = await open(file, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const stat = await handle.stat();
    if (!stat.isFile() || stat.size < 1 || stat.size > maximum) fail();
    const bytes = Buffer.alloc(stat.size + 1);
    let used = 0;
    while (used < bytes.length) {
      const { bytesRead } = await handle.read(bytes, used, bytes.length - used, used);
      if (!bytesRead) break;
      used += bytesRead;
    }
    const after = await handle.stat();
    if (used !== stat.size || after.size !== stat.size || after.mtimeMs !== stat.mtimeMs) fail();
    return bytes.subarray(0, used);
  } finally { await handle.close(); }
}

export function verifyBuildIdentity(sbom, revision, cargoHash, npmHash) {
  if (!/^[a-f0-9]{40}$/.test(revision) || ![cargoHash, npmHash].every((hash) => /^[a-f0-9]{64}$/.test(hash))
      || sbom?.bomFormat !== "CycloneDX" || sbom.specVersion !== "1.6" || !Array.isArray(sbom.metadata?.properties)) fail();
  const properties = new Map(sbom.metadata.properties.map(({ name, value }) => [name, value]));
  if (properties.size !== sbom.metadata.properties.length) fail();
  for (const [key, value] of Object.entries({
    "lockedin:source-revision": revision,
    "lockedin:source-state": "clean",
    "lockedin:target": "x86_64-unknown-linux-gnu",
    "lockedin:cargo-lock-sha256": cargoHash,
    "lockedin:npm-lock-sha256": npmHash,
  })) if (properties.get(key) !== value) fail();
}

function archivePath(value, directory = false) {
  if (value.startsWith("./")) value = value.slice(2);
  if (directory && value.endsWith("/")) value = value.slice(0, -1);
  if (directory && (value === "" || value === ".")) return "";
  if (value.length > 256 || !/^[A-Za-z0-9_+.,@() /-]+$/.test(value)
      || value.split("/").some((part) => !part || part === "." || part === "..")) fail("archive-path");
  return value;
}

function field(header, offset, size) {
  const bytes = header.subarray(offset, offset + size);
  const end = bytes.indexOf(0);
  if (end !== -1 && bytes.subarray(end).some((byte) => byte !== 0)) fail();
  if (bytes.subarray(0, end === -1 ? size : end).some((byte) => byte < 32 || byte > 126)) fail();
  return bytes.subarray(0, end === -1 ? size : end).toString("ascii");
}

function octal(bytes) {
  const value = bytes.toString("ascii").replace(/[\0 ]+$/, "").replace(/^ +/, "");
  if (!/^[0-7]+$/.test(value) || bytes.some((byte) => byte > 127)) fail();
  const number = Number.parseInt(value, 8);
  if (!Number.isSafeInteger(number)) fail();
  return number;
}

// Original USTAR or the pinned producer's ordinary GNU headers only. No
// normalization, extraction, GNU/PAX extensions, links, devices or sparse entries.
export function inspectTar(bytes, expected) {
  if (!Buffer.isBuffer(bytes) || bytes.length > limits.payload || bytes.length % 512) fail("archive-framing");
  const entries = new Map();
  let cursor = 0;
  let ended = false;
  while (cursor + 512 <= bytes.length) {
    const header = bytes.subarray(cursor, cursor + 512);
    cursor += 512;
    if (header.every((byte) => byte === 0)) {
      if (bytes.length - cursor < 512 || bytes.subarray(cursor).some((byte) => byte !== 0)) fail("archive-framing");
      ended = true;
      break;
    }
    const signature = header.subarray(257, 265);
    const gnu = signature.equals(Buffer.from("ustar  \0"));
    if (entries.size >= limits.entries || (!gnu && !signature.equals(Buffer.from("ustar\0" + "00")))) fail();
    if (gnu) {
      // tar 0.4.46 new_gnu + deterministic Unix metadata: GNU offsets 345..511
      // are NOT a USTAR prefix. Require its unused time/offset/sparse area empty.
      // Long-name/link extension entries are still rejected by the type guard.
      if (header.subarray(157, 257).some((byte) => byte !== 0)
          || header.subarray(265, 329).some((byte) => byte !== 0)
          || header.subarray(345).some((byte) => byte !== 0)
          || [108, 116, 329, 337].some((offset) => octal(header.subarray(offset, offset + 8)) !== 0)) fail();
      octal(header.subarray(136, 148));
    }
    const checksum = header.reduce((sum, byte, index) => sum + (index >= 148 && index < 156 ? 32 : byte), 0);
    if (checksum !== octal(header.subarray(148, 156))) fail("archive-checksum");
    const type = header[156] === 0 ? "0" : String.fromCharCode(header[156]);
    if (!["0", "2", "5"].includes(type)) fail("archive-entry-type");
    const prefix = gnu ? "" : field(header, 345, 155);
    const name = archivePath((prefix ? prefix + "/" : "") + field(header, 0, 100), type === "5");
    const size = octal(header.subarray(124, 136));
    const mode = octal(header.subarray(100, 108));
    // Deterministic mode contains permission bits only, not Unix file-type bits.
    if (gnu && (type === "5" ? mode !== 0o755 : ![0o644, 0o755].includes(mode))) fail();
    if (size > limits.file || (type !== "0" && size !== 0) || (mode & ~0o777) || cursor + Math.ceil(size / 512) * 512 > bytes.length) fail("archive-bounds");
    if (entries.has(name)) fail("archive-path");
    const data = bytes.subarray(cursor, cursor + size);
    if (bytes.subarray(cursor + size, cursor + Math.ceil(size / 512) * 512).some((byte) => byte !== 0)) fail("archive-framing");
    cursor += Math.ceil(size / 512) * 512;
    const entry = { pathSha256: digest(name), type: { "0": "file", "2": "symlink", "5": "directory" }[type], mode, bytes: size };
    if (type === "2") {
      // Conservative policy: reject all symlinks until a native, format-specific
      // link-resolution contract is tested. Never dereference an archive link.
      fail("archive-entry-type");
    }
    if (type === "0") {
      entry.sha256 = digest(data);
      entry.elf = data.subarray(0, 4).equals(Buffer.from([127, 69, 76, 70]));
      entry.componentMapping = "unresolved";
    }
    entries.set(name, entry);
  }
  if (!ended) fail("archive-framing");
  return verifyEntries(entries, expected);
}

// Original newc CPIO bytes; never extract or rewrite the payload. Deliberately
// narrower than general CPIO: one terminated archive, regular files/directories,
// no links/devices/privileged modes. RPM framing/decompression is a separate gate.
// Layout: kernel.org/doc/html/latest/driver-api/early-userspace/buffer-format.html
export function inspectCpio(bytes, expected) {
  if (!Buffer.isBuffer(bytes) || bytes.length > limits.payload) fail("archive-framing");
  const entries = new Map();
  let cursor = 0;
  let ended = false;
  const aligned = (end) => {
    const next = Math.ceil(end / 4) * 4;
    if (next > bytes.length || bytes.subarray(end, next).some((byte) => byte !== 0)) fail("archive-framing");
    return next;
  };
  while (cursor + 110 <= bytes.length) {
    const header = bytes.subarray(cursor, cursor + 110);
    if (header.subarray(0, 6).toString("ascii") !== "070701"
        || header.some((byte) => byte > 127)) fail();
    const fields = [];
    for (let offset = 6; offset < 110; offset += 8) {
      const value = header.subarray(offset, offset + 8).toString("ascii");
      if (!/^[a-fA-F0-9]{8}$/.test(value)) fail();
      fields.push(Number.parseInt(value, 16));
    }
    const [, mode, , , links, , size, , , rmajor, rminor, nameSize, checksum] = fields;
    cursor += 110;
    if (nameSize < 2 || nameSize > 259 || cursor + nameSize > bytes.length
        || size > limits.file) fail("archive-bounds");
    const rawName = bytes.subarray(cursor, cursor + nameSize);
    if (rawName.at(-1) !== 0 || rawName.subarray(0, -1).some((byte) => byte < 32 || byte > 126)) fail("archive-path");
    const nameText = rawName.subarray(0, -1).toString("ascii");
    cursor = aligned(cursor + nameSize);
    if (checksum !== 0 || rmajor !== 0 || rminor !== 0) fail();
    if (nameText === "TRAILER!!!") {
      if (size !== 0 || mode !== 0 || bytes.subarray(cursor).some((byte) => byte !== 0)) fail("archive-framing");
      ended = true;
      break;
    }
    const kind = mode & 0o170000;
    if (![0o100000, 0o040000].includes(kind) || (mode & ~0o170777)
        || links < 1 || (kind === 0o100000 && links !== 1)
        || (kind === 0o040000 && size !== 0)) fail("archive-entry-type");
    const name = archivePath(nameText, kind === 0o040000);
    if (entries.size >= limits.entries || entries.has(name)) fail("archive-path");
    if (cursor + size > bytes.length) fail("archive-bounds");
    const data = bytes.subarray(cursor, cursor + size);
    cursor = aligned(cursor + size);
    const entry = { pathSha256: digest(name), type: kind === 0o040000 ? "directory" : "file", mode: mode & 0o777, bytes: size };
    if (kind === 0o100000) {
      entry.sha256 = digest(data);
      entry.elf = data.subarray(0, 4).equals(Buffer.from([127, 69, 76, 70]));
      entry.componentMapping = "unresolved";
    }
    entries.set(name, entry);
  }
  if (!ended) fail("archive-framing");
  return verifyEntries(entries, expected);
}

function verifyEntries(entries, expected) {
  for (const name of entries.keys()) {
    const segments = name.split("/");
    while (segments.length > 1) {
      segments.pop();
      const parent = entries.get(segments.join("/"));
      if (parent && parent.type !== "directory") fail("archive-path");
    }
  }
  const matches = (suffix) => [...entries].filter(([name, entry]) => entry.type === "file" && name.endsWith(suffix));
  const models = matches("/models/ggml-base.en.bin");
  if (models.length !== 1) fail("resource-model-count");
  if (models[0][1].sha256 !== expected.model) fail("resource-model-hash");
  const resourceRoot = models[0][0].slice(0, -"/models/ggml-base.en.bin".length);
  for (const label of required) {
    const found = matches("/compliance/" + label);
    if (found.length !== 1) fail("resource-compliance-count");
    if (found[0][0] !== resourceRoot + "/compliance/" + label) fail("resource-compliance-location");
    if (found[0][1].sha256 !== expected[label]) fail("resource-compliance-hash");
    found[0][1].verifiedResource = label;
  }
  models[0][1].verifiedResource = "pinned-model";
  const app = entries.get("usr/bin/lockedin-flow-desktop");
  if (!app) fail("resource-application-missing");
  if (!app.elf) fail("resource-application-format");
  if (app.sha256 !== expected.application) fail("resource-application-hash");
  app.verifiedResource = "application";
  return [...entries.values()].sort((a, b) => a.pathSha256.localeCompare(b.pathSha256));
}

export function packageMetadata(format, identity, dependencies) {
  if (!["deb", "rpm"].includes(format) || identity.length > limits.metadata || dependencies.length > limits.metadata) fail();
  const rows = identity.trimEnd().split("\n");
  if (rows.length !== 3 || !names.has(rows[0]) || !/^\d{1,5}\.\d{1,5}\.\d{1,5}(?:[~+-](?:alpha|beta|rc)\.\d{1,5})?(?:-\d{1,5})?$/.test(rows[1])
      || rows[2] !== (format === "deb" ? "amd64" : "x86_64")) fail();
  const requirements = dependencies.split("\n").filter(Boolean);
  if (requirements.length > 4096 || requirements.some((line) => line.length > 4096 || /[^\x20-\x7e]/.test(line))) fail();
  // Unreviewed package metadata is never echoed. Keep hashes for reconciliation;
  // do not infer bundled component identities/licenses from requirement names.
  return {
    name: rows[0], declaredVersion: rows[1], architecture: rows[2],
    declaredOsDependencies: { scope: "requirements-not-bundled-components", sha256: digest(dependencies), recordSha256: requirements.map(digest).sort() },
  };
}

export function standardTool(command, args, input, maxBuffer = limits.metadata) {
  const result = spawnSync(command, args, {
    input, encoding: null, maxBuffer, timeout: 60000, killSignal: "SIGKILL",
    stdio: [input ? "pipe" : "ignore", "pipe", "pipe"],
    detached: process.platform !== "win32",
    env: { PATH: "/usr/bin:/bin", LANG: "C", LC_ALL: "C" },
  });
  if (result.error && result.pid > 0 && process.platform !== "win32") {
    // Also stop decompressor children in this tool's newly owned process group.
    try { process.kill(-result.pid, "SIGKILL"); } catch { /* Already exited. */ }
  }
  if (result.error || result.status !== 0 || result.signal) fail();
  return result.stdout;
}

export function inspectPackage(format, snapshot, bytes, expected, run = standardTool) {
  if (!["deb", "rpm", "appimage"].includes(format) || bytes.length < 64 || bytes.length > limits.package) fail();
  const result = { format, bytes: bytes.length, sha256: digest(bytes), status: "unverified", licenseReview: "unresolved" };
  if (format === "appimage") {
    // Read the original filesystem in memory. Never invoke --appimage-extract,
    // a supplied executable, mount, extractor or archive-normalization tool.
    if (!bytes.subarray(0, 4).equals(Buffer.from([127, 69, 76, 70])) || !bytes.subarray(8, 11).equals(Buffer.from([65, 73, 2]))) fail();
    let failureStage = "archive-header";
    try {
      const offset = appImageFilesystemOffset(bytes);
      failureStage = "archive-validation";
      const entries = squashfsEntries(bytes.subarray(offset), limits);
      failureStage = "resource-validation";
      const application = entries.get("usr/bin/lockedin-flow-desktop"), launcher = entries.get("AppRun");
      const launchTarget = launcher?.type === "symlink"
        ? [...entries.values()].find((entry) => entry.pathSha256 === launcher.resolvedPathSha256) : launcher;
      if (application?.type !== "file" || !(application.mode & 0o111)
          || launchTarget?.type !== "file" || !(launchTarget.mode & 0o111)) fail("resource-application-format");
      return { ...result, status: "payload-inspected", metadata: null, files: verifyEntries(entries, expected) };
    } catch (error) {
      if (error instanceof EvidenceFailure) failureStage = error.category;
      return { ...result, reason: "tool-or-payload-validation-failed", failureStage, metadata: null, files: null };
    }
  }
  if (format === "deb" ? bytes.subarray(0, 8).toString("ascii") !== "!<arch>\n" : !bytes.subarray(0, 4).equals(Buffer.from([237, 171, 238, 219]))) fail();
  let failureStage = "identity-query";
  try {
    let identity, dependencies, tar;
    if (format === "deb") {
      identity = ["Package", "Version", "Architecture"].map((field) => run("/usr/bin/dpkg-deb", ["--field", snapshot, field]).toString("utf8").trimEnd()).join("\n");
      failureStage = "dependency-query";
      dependencies = ["Depends", "Pre-Depends"].map((field) => run("/usr/bin/dpkg-deb", ["--field", snapshot, field]).toString("utf8").trimEnd()).join("\n");
      // Validate every original decompressed byte. A rewriting tool can silently
      // discard trailing archives/data and cannot establish full consumption.
      failureStage = "payload-read";
      tar = run("/usr/bin/dpkg-deb", ["--fsys-tarfile", snapshot], undefined, limits.payload);
    } else {
      identity = run("/usr/bin/rpm", ["--noplugins", "-qp", "--queryformat", "%{NAME}\n%{VERSION}-%{RELEASE}\n%{ARCH}\n", snapshot]).toString("utf8");
      dependencies = run("/usr/bin/rpm", ["--noplugins", "-qp", "--requires", snapshot]).toString("utf8");
      failureStage = "payload-read";
      const archive = readRpmPayload(bytes);
      failureStage = "metadata-validation";
      const metadata = packageMetadata(format, identity, dependencies);
      failureStage = "archive-validation";
      return { ...result, status: "payload-inspected", metadata, files: inspectCpio(archive, expected) };
    }
    failureStage = "metadata-validation";
    const metadata = packageMetadata(format, identity, dependencies);
    failureStage = "archive-validation";
    return { ...result, status: "payload-inspected", metadata, files: inspectTar(tar, expected) };
  } catch (error) {
    // Only internally constructed validation failures can refine the archive
    // category. Never copy properties/messages from an external tool exception.
    if (failureStage === "archive-validation" && error instanceof EvidenceFailure) failureStage = error.category;
    return { ...result, reason: "tool-or-payload-validation-failed", metadata: null, files: null,
      ...(format === "deb" ? { failureStage } : {}) };
  }
}
