import assert from "node:assert/strict";
import test from "node:test";
import { deflateSync, zstdCompressSync } from "node:zlib";
import { existsSync } from "node:fs";
import { mkdtemp, mkdir, writeFile, readFile, link, symlink, rm } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import os from "node:os";
import path from "node:path";
import { squashfsEntries } from "../scripts/squashfs-evidence.mjs";
import { digest, limits, inspectPackage } from "../scripts/linux-package-evidence.mjs";

// Entirely synthetic filesystem images assembled in memory. They are never
// mounted, extracted or executed, and are not native installer acceptance.
function filesystem(files = [["file", Buffer.from("synthetic-content")]], options = {}) {
  const nodes = new Map([["", { kind: 1 }]]);
  for (const [name, value, kind = 2] of files) {
    const parts = name.split("/");
    for (let n = 1; n < parts.length; n++) nodes.set(parts.slice(0, n).join("/"), { kind: 1 });
    nodes.set(name, { kind, data: Buffer.from(value) });
  }
  const compression = options.compression ?? 1, blockSize = 4096;
  const compress = (b) => compression === 1 ? deflateSync(b) : zstdCompressSync(b);
  const meta = (b) => { const data = options.plain ? b : compress(b), head = Buffer.alloc(2); head.writeUInt16LE(data.length | (options.plain ? 0x8000 : 0)); return Buffer.concat([head, data]); };
  const chunks = [], inodeChunks = [], directoryChunks = [];
  let dataAt = 96, inodeAt = 0, directoryAt = 0, number = 0;
  for (const [name, node] of nodes) {
    node.number = ++number; node.at = inodeAt;
    if (node.kind === 1) node.inodeSize = 32;
    else if (node.kind === 3) node.inodeSize = 24 + node.data.length;
    else node.inodeSize = 32 + 4 * Math.ceil(node.data.length / blockSize);
    inodeAt += node.inodeSize;
  }
  for (const [name, node] of nodes) {
    const inode = Buffer.alloc(node.inodeSize);
    inode.writeUInt16LE(node.kind, 0); inode.writeUInt16LE(node.kind === 1 || name.startsWith("usr/bin/") || name === "AppRun" ? 0o755 : 0o644, 2);
    inode.writeUInt32LE(node.number, 12);
    if (node.kind === 1) {
      const children = [...nodes].filter(([n]) => n && n.split("/").slice(0, -1).join("/") === name).sort(([a], [b]) => a < b ? -1 : 1);
      const parts = [];
      if (children.length) {
        const head = Buffer.alloc(12); head.writeUInt32LE(children.length - 1); head.writeUInt32LE(1, 8); parts.push(head);
        for (const [path, child] of children) {
          const label = Buffer.from(path.split("/").at(-1)), entry = Buffer.alloc(8);
          entry.writeUInt16LE(child.at); entry.writeInt16LE(child.number - 1, 2);
          entry.writeUInt16LE(child.kind, 4); entry.writeUInt16LE(label.length - 1, 6);
          parts.push(entry, label);
        }
      }
      const directory = Buffer.concat(parts);
      inode.writeUInt32LE(2, 20); inode.writeUInt16LE(directory.length + 3, 24); inode.writeUInt16LE(directoryAt, 26);
      inode.writeUInt32LE(name ? nodes.get(name.split("/").slice(0, -1).join("/")).number : nodes.size + 1, 28);
      directoryChunks.push(directory); directoryAt += directory.length;
    } else if (node.kind === 3) {
      inode.writeUInt32LE(1, 16); inode.writeUInt32LE(node.data.length, 20); node.data.copy(inode, 24);
    } else {
      inode.writeUInt32LE(dataAt, 16); inode.writeUInt32LE(0xffffffff, 20); inode.writeUInt32LE(node.data.length, 28);
      let index = 32;
      for (let i = 0; i < node.data.length; i += blockSize) {
        const raw = node.data.subarray(i, i + blockSize), data = options.plain ? raw : compress(raw);
        inode.writeUInt32LE(data.length | (options.plain ? 0x1000000 : 0), index); index += 4;
        chunks.push(data); dataAt += data.length;
      }
    }
    inodeChunks.push(inode);
  }
  const inodeTable = meta(Buffer.concat(inodeChunks)), directoryTable = meta(Buffer.concat(directoryChunks));
  const idTable = meta(Buffer.alloc(4)), idStart = dataAt + inodeTable.length + directoryTable.length;
  const index = Buffer.alloc(8); index.writeBigUInt64LE(BigInt(idStart));
  const header = Buffer.alloc(96);
  header.writeUInt32LE(0x73717368); header.writeUInt32LE(nodes.size, 4); header.writeUInt32LE(blockSize, 12);
  header.writeUInt16LE(compression, 20); header.writeUInt16LE(12, 22); header.writeUInt16LE(1, 26); header.writeUInt16LE(4, 28);
  header.writeBigUInt64LE(BigInt(idStart + idTable.length + 8), 40);
  header.writeBigUInt64LE(BigInt(idStart + idTable.length), 48); header.writeBigUInt64LE(0xffffffffffffffffn, 56);
  header.writeBigUInt64LE(BigInt(dataAt), 64); header.writeBigUInt64LE(BigInt(dataAt + inodeTable.length), 72);
  header.writeBigUInt64LE(0xffffffffffffffffn, 80); header.writeBigUInt64LE(0xffffffffffffffffn, 88);
  return { bytes: Buffer.concat([header, ...chunks, inodeTable, directoryTable, idTable, index]), nodes };
}

test("original gzip, zstd and uncompressed filesystem bytes yield exact file hashes", () => {
  for (const options of [{}, { compression: 6 }, { plain: true }]) {
    const source = Buffer.alloc(9301, 42), fixture = filesystem([["usr/bin/app", source], ["empty", ""]], options);
    const entries = squashfsEntries(fixture.bytes, limits);
    assert.equal(entries.get("usr/bin/app").sha256, digest(source));
    assert.equal(entries.get("usr/bin/app").bytes, source.length);
    assert.equal(entries.get("empty").sha256, digest(Buffer.alloc(0)));
    assert.equal(entries.get("usr").type, "directory");
    assert.equal(entries.size, 5);
  }
});

test("safe relative symlinks resolve inside the tree without host access", () => {
  const fixture = filesystem([["usr/lib/a", "data"], ["usr/lib/b", "./a", 3], ["lib", "usr/lib", 3], ["link", "lib/b", 3]]);
  const entries = squashfsEntries(fixture.bytes, limits);
  assert.equal(entries.get("link").resolvedPathSha256, digest("usr/lib/a"));
  assert.equal(entries.get("usr/lib/b").targetSha256, digest("./a"));
  assert.equal(entries.get("lib").resolvedPathSha256, digest("usr/lib"));
});

test("absolute, escaping, dangling, cyclic and nondirectory links fail closed", () => {
  for (const target of ["/file", "../file", "folder/../../file", "missing", "link", "file/child", "file/../file"]) {
    assert.throws(() => squashfsEntries(filesystem([["file", "data"], ["folder/entry", "x"], ["link", target, 3]]).bytes, limits));
  }
  assert.throws(() => squashfsEntries(filesystem([["a", "b", 3], ["b", "a", 3]]).bytes, limits));
});

test("every truncation, nonzero trailer and concatenated filesystem is refused", () => {
  const { bytes } = filesystem();
  for (let size = 0; size < bytes.length; size++) assert.throws(() => squashfsEntries(bytes.subarray(0, size), limits));
  assert.throws(() => squashfsEntries(Buffer.concat([bytes, bytes]), limits));
  assert.throws(() => squashfsEntries(Buffer.concat([bytes, Buffer.from([1])]), limits));
  assert.throws(() => squashfsEntries(Buffer.concat([bytes, Buffer.alloc(4096)]), limits));
  assert.equal(squashfsEntries(Buffer.concat([bytes, Buffer.alloc(16)]), limits).get("file").sha256, digest("synthetic-content"));
});

test("bounds, unsupported compression, xattrs, modes and malformed references are rejected", () => {
  const { bytes, nodes } = filesystem([["file", "data"]], { plain: true });
  for (const [offset, value] of [[4, 10001], [12, 3], [16, 10001], [20, 4], [26, 0], [28, 3]]) {
    const bad = Buffer.from(bytes); bad.writeUInt32LE(value, offset);
    assert.throws(() => squashfsEntries(bad, limits));
  }
  for (const offset of [32, 40, 48, 56, 64, 72, 80, 88]) {
    const bad = Buffer.from(bytes); bad.writeBigUInt64LE(0xfffffffffffffffen, offset);
    assert.throws(() => squashfsEntries(bad, limits));
  }
  const inodeAt = Number(bytes.readBigUInt64LE(64)) + 2;
  for (const [offset, value] of [[0, 4], [2, 0o4755], [4, 1], [12, 99], [24, 65535]]) {
    const bad = Buffer.from(bytes); bad.writeUInt16LE(value, inodeAt + offset);
    assert.throws(() => squashfsEntries(bad, limits));
  }
  const badSize = Buffer.from(bytes); badSize.writeUInt32LE(limits.file + 1, inodeAt + nodes.get("file").at + 28);
  assert.throws(() => squashfsEntries(badSize, limits));
  assert.throws(() => squashfsEntries(bytes, { ...limits, payload: 1 }));
});

test("duplicate names, traversal names, directory cycles and wrong inode identity are refused", () => {
  const { bytes } = filesystem([["a", "a"], ["b", "b"]], { plain: true });
  const dir = Number(bytes.readBigUInt64LE(72)) + 2;
  for (const mutate of [
    (b) => b.write("a", dir + 29),
    (b) => b.write("/", dir + 20),
    (b) => { b.writeUInt16LE(0, dir + 12); b.writeInt16LE(0, dir + 14); b.writeUInt16LE(1, dir + 16); },
    (b) => b.writeUInt16LE(1, dir + 16),
    (b) => b.writeInt16LE(20, dir + 14),
  ]) { const bad = Buffer.from(bytes); mutate(bad); assert.throws(() => squashfsEntries(bad, limits)); }
});

function appImage(squashfs) {
  const elf = Buffer.alloc(256);
  elf.set([127, 69, 76, 70, 2, 1, 1]); elf.set([65, 73, 2], 8);
  elf.writeUInt16LE(2, 16); elf.writeUInt16LE(62, 18); elf.writeUInt32LE(1, 20);
  elf.writeBigUInt64LE(64n, 32); elf.writeBigUInt64LE(128n, 40);
  elf.writeUInt16LE(64, 52); elf.writeUInt16LE(56, 54); elf.writeUInt16LE(1, 56);
  elf.writeUInt16LE(64, 58); elf.writeUInt16LE(2, 60);
  elf.writeUInt32LE(1, 64); elf.writeBigUInt64LE(120n, 96);
  return Buffer.concat([elf, squashfs]);
}

test("AppImage inspection binds every required resource and never runs the runtime", () => {
  const root = "usr/lib/lockedin-flow-desktop", application = Buffer.from([127, 69, 76, 70, 1]);
  const labels = ["SBOM.cdx.json", "THIRD-PARTY-NOTICES.txt", "LICENSE.txt", "MODEL.json"];
  const files = [["usr/bin/lockedin-flow-desktop", application], [root + "/models/ggml-base.en.bin", "synthetic-model"],
    ...labels.map((label) => [root + "/compliance/" + label, "synthetic-" + label]), ["AppRun", "usr/bin/lockedin-flow-desktop", 3]];
  const expected = { application: digest(application), model: digest("synthetic-model"),
    ...Object.fromEntries(labels.map((label) => [label, digest("synthetic-" + label)])) };
  const bytes = appImage(filesystem(files).bytes);
  const check = (buffer, reference) => inspectPackage("appimage", "/synthetic/unused", buffer, reference, () => assert.fail("Must not execute a package helper"));
  const report = check(bytes, expected);
  assert.equal(report.status, "payload-inspected");
  assert.equal(report.metadata, null); assert.equal(report.licenseReview, "unresolved");
  assert.equal(report.files.filter((entry) => entry.verifiedResource).length, 6);
  for (const key of Object.keys(expected)) {
    const invalid = check(bytes, { ...expected, [key]: "0".repeat(64) });
    assert.equal(invalid.status, "unverified"); assert.equal(invalid.files, null);
  }
  for (const list of [files.slice(1), files.slice(0, 5), [...files, ["copy/models/ggml-base.en.bin", "synthetic-model"]],
    files.filter(([name]) => name !== "AppRun"),
    files.map(([name, value, kind]) => name.endsWith("LICENSE.txt") ? [name, "../../../../../missing", 3] : [name, value, kind])]) {
    assert.equal(check(appImage(filesystem(list).bytes), expected).status, "unverified");
  }
});

test("corrupt compressed data and hidden or malformed inode metadata are refused", () => {
  const { bytes } = filesystem();
  const checksum = Buffer.from(bytes); checksum[Number(bytes.readBigUInt64LE(64)) - 1] ^= 255;
  assert.throws(() => squashfsEntries(checksum, limits));
  const header = Buffer.from(bytes); header.writeUInt32LE(2, 0);
  assert.throws(() => squashfsEntries(header, limits));
  const { bytes: plain } = filesystem([["file", "data"]], { plain: true });
  const inode = Number(plain.readBigUInt64LE(64)), directory = Number(plain.readBigUInt64LE(72));
  const badSize = Buffer.from(plain); badSize.writeUInt16LE(0xffff, inode);
  assert.throws(() => squashfsEntries(badSize, limits));
  // Hiding the sole child leaves an unreachable inode and unconsumed inode bytes.
  const hidden = Buffer.from(plain); hidden.writeUInt16LE(3, inode + 2 + 24);
  assert.throws(() => squashfsEntries(hidden, limits));
  const escaped = Buffer.from(plain); escaped.writeUInt16LE(8192, directory + 2 + 12);
  assert.throws(() => squashfsEntries(escaped, limits));
});

const nativeWriter = process.env.FLOW_TEST_MKSQUASHFS || (process.platform === "linux" ? "/usr/bin/mksquashfs" : "");
test("native writer cross-check covers fragments, exports, hardlinks, sparse files and long directories", { skip: !nativeWriter || !existsSync(nativeWriter) }, async () => {
  const scratch = await mkdtemp(path.join(os.tmpdir(), "flow-squashfs-test-"));
  try {
    const directory = path.join(scratch, "input");
    await mkdir(path.join(directory, "lib"), { recursive: true });
    const source = new Map();
    for (let n = 0; n < 400; n++) {
      const name = "lib/synthetic-" + n.toString().padStart(4, "0") + ".so", bytes = Buffer.from("synthetic-file-" + n);
      source.set(name, bytes); await writeFile(path.join(directory, name), bytes);
    }
    const large = Buffer.alloc(22001, 42); source.set("large", large); await writeFile(path.join(directory, "large"), large);
    const sparse = Buffer.alloc(10001); source.set("sparse", sparse); await writeFile(path.join(directory, "sparse"), sparse);
    await link(path.join(directory, "large"), path.join(directory, "hardlink")); source.set("hardlink", large);
    await symlink("../large", path.join(directory, "lib/relative"));
    for (const compression of ["gzip", "zstd"]) {
      const image = path.join(scratch, compression + ".squashfs");
      execFileSync(nativeWriter, [directory, image, "-noappend", "-no-xattrs", "-no-progress", "-processors", "1", "-b", "4096", "-comp", compression], { timeout: 20000, maxBuffer: limits.metadata, stdio: ["ignore", "pipe", "pipe"] });
      const entries = squashfsEntries(await readFile(image), limits);
      for (const [name, bytes] of source) {
        assert.equal(entries.get(name)?.sha256, digest(bytes), name);
        assert.equal(entries.get(name)?.bytes, bytes.length);
      }
      assert.equal(entries.get("lib/relative").resolvedPathSha256, digest("large"));
      assert.equal(entries.size, source.size + 3);
    }
  } finally { await rm(scratch, { recursive: true, force: true }); }
});
