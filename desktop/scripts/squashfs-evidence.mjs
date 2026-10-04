import { createHash } from "node:crypto";
import { constants, inflateSync, zstdDecompressSync } from "node:zlib";

const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
const reject = () => { throw new Error("SquashFS evidence rejected; input details withheld."); };
const absent = 0xffffffffffffffffn;
const noFragment = 0xffffffff;

// Read-only SquashFS 4.0 walker. No extraction, mounting or application execution.
// Format references: docs.kernel.org/filesystems/squashfs.html and the on-disk
// structures in squashfs-tools 4.5.1 squashfs_fs.h. This is intentionally narrower
// than a general filesystem driver: gzip/zstd, no xattrs or special device files.
export function squashfsEntries(input, limits) {
  if (!Buffer.isBuffer(input) || input.length < 96 || input.length > limits.package) reject();
  const range = (bytes, at, size) => {
    if (!Number.isSafeInteger(at) || !Number.isSafeInteger(size) || at < 0 || size < 0 || at + size > bytes.length) reject();
    return bytes.subarray(at, at + size);
  };
  const u16 = (b, at) => range(b, at, 2).readUInt16LE();
  const u32 = (b, at) => range(b, at, 4).readUInt32LE();
  const u64 = (b, at) => {
    const n = range(b, at, 8).readBigUInt64LE();
    if (n > BigInt(Number.MAX_SAFE_INTEGER)) reject();
    return Number(n);
  };
  if (u32(input, 0) !== 0x73717368 || u16(input, 28) !== 4 || u16(input, 30) !== 0) reject();
  const count = u32(input, 4), blockSize = u32(input, 12), fragments = u32(input, 16);
  const compression = u16(input, 20), flags = u16(input, 24), ids = u16(input, 26);
  if (count < 1 || count > limits.entries || fragments > limits.entries || ids < 1 || ids > limits.entries
      || blockSize < 4096 || blockSize > 1048576 || (blockSize & (blockSize - 1))
      || 2 ** u16(input, 22) !== blockSize || ![1, 6].includes(compression)
      || (flags & ~0x0fff) || (flags & 4) || input.readBigUInt64LE(56) !== absent) reject();
  const used = u64(input, 40);
  if (used < 96 || used > input.length || input.length - used > 4095 || input.subarray(used).some((x) => x !== 0)) reject();
  const bytes = input.subarray(0, used);
  const inodeStart = u64(bytes, 64), directoryStart = u64(bytes, 72);
  if (inodeStart < 96 || directoryStart <= inodeStart || directoryStart >= used) reject();
  let decodedBytes = 0;
  const decompress = (data, maximum, plain) => {
    const account = (output) => {
      decodedBytes += output.length;
      if (!output.length || output.length > maximum || decodedBytes > limits.payload + 16 * limits.metadata) reject();
      return output;
    };
    if (plain) return account(data);
    try {
      const result = (compression === 1 ? inflateSync : zstdDecompressSync)(data, {
        info: true, maxOutputLength: maximum,
        ...(compression === 6 ? { params: { [constants.ZSTD_d_windowLogMax]: 20 } } : {}),
      });
      if (!result.buffer.length || result.engine.bytesWritten !== data.length) reject();
      return account(result.buffer);
    } catch { reject(); }
  };
  let metadataBytes = 0;
  const metadata = (at, end) => {
    if (at < inodeStart || at + 2 > end) reject();
    const header = u16(bytes, at), size = header & 0x7fff;
    if (!size || size > 8192 || at + 2 + size > end) reject();
    const data = decompress(range(bytes, at + 2, size), 8192, !!(header & 0x8000));
    metadataBytes += data.length;
    if (metadataBytes > 16 * limits.metadata) reject();
    return { data, end: at + 2 + size };
  };
  // Indexed tables must be consecutive, exactly sized and finish at their index.
  const indexed = (index, amount, width, end) => {
    if (index < directoryStart || index + Math.ceil(amount * width / 8192) * 8 !== end) reject();
    const pieces = [], starts = [];
    for (let i = 0; i < Math.ceil(amount * width / 8192); i++) starts.push(u64(bytes, index + i * 8));
    for (let i = 0; i < starts.length; i++) {
      if (starts[i] < directoryStart) reject();
      const next = starts[i + 1] ?? index, block = metadata(starts[i], next);
      if (block.end !== next || block.data.length !== Math.min(8192, amount * width - i * 8192)) reject();
      pieces.push(block.data);
    }
    return { data: Buffer.concat(pieces), start: starts[0] ?? index };
  };
  const idTable = indexed(u64(bytes, 48), ids, 4, used);
  let tail = idTable.start;
  let exports;
  if (bytes.readBigUInt64LE(88) !== absent) {
    exports = indexed(u64(bytes, 88), count, 8, tail);
    tail = exports.start;
  }
  let fragmentTable = Buffer.alloc(0);
  if (fragments) {
    const table = indexed(u64(bytes, 80), fragments, 16, tail);
    fragmentTable = table.data; tail = table.start;
  } else if (bytes.readBigUInt64LE(80) !== absent && u64(bytes, 80) !== tail) reject();
  const table = (start, end) => {
    const blocks = new Map(), pieces = [];
    let at = start, total = 0;
    while (at < end) {
      const block = metadata(at, end);
      blocks.set(at - start, { offset: total, size: block.data.length });
      pieces.push(block.data); total += block.data.length; at = block.end;
      if (at < end && block.data.length !== 8192) reject();
    }
    if (at !== end) reject();
    return { bytes: Buffer.concat(pieces), blocks };
  };
  const inodes = table(inodeStart, directoryStart), directories = table(directoryStart, tail);
  const position = (table, block, offset) => {
    const found = table.blocks.get(block);
    if (!found || offset >= found.size) reject();
    return found.offset + offset;
  };
  const inodePosition = (reference) => position(inodes, Math.floor(reference / 65536), reference % 65536);
  const text = (data) => {
    if (!data.length || data.length > 256 || data.some((x) => x < 32 || x > 126)) reject();
    const value = data.toString("ascii");
    if (!/^[A-Za-z0-9_+.,@() /-]+$/.test(value)) reject();
    return value;
  };
  const dataBlock = (start, field, maximum) => {
    const size = field & 0xffffff;
    if (field > 0x1ffffff || !size || start < 96 || start + size > inodeStart) reject();
    return decompress(range(bytes, start, size), maximum, !!(field & 0x1000000));
  };
  const fragmentCache = new Map();
  const fragment = (number) => {
    if (number >= fragments) reject();
    if (!fragmentCache.has(number)) {
      const at = number * 16;
      if (u32(fragmentTable, at + 12) !== 0) reject();
      const decoded = dataBlock(u64(fragmentTable, at), u32(fragmentTable, at + 8), blockSize);
      // A small bounded cache avoids repeatedly decompressing shared file tails.
      if (fragmentCache.size >= 16) fragmentCache.delete(fragmentCache.keys().next().value);
      fragmentCache.set(number, decoded);
    }
    return fragmentCache.get(number);
  };
  const entries = new Map(), parsed = new Map(), numbers = new Map(), spans = [], targets = new Map();
  let logicalBytes = 0;
  function walk(reference, name, parentNumber, entryType, entryNumber, depth = 0) {
    if (depth > 64 || entries.size >= limits.entries || name.length > 256 || entries.has(name)) reject();
    const at = inodePosition(reference), b = inodes.bytes;
    const type = u16(b, at), mode = u16(b, at + 2), number = u32(b, at + 12);
    const basicType = type > 7 ? type - 7 : type;
    if (![1, 2, 3, 8, 9, 10].includes(type) || mode > 0o777 || u16(b, at + 4) >= ids || u16(b, at + 6) >= ids
        || number < 1 || number > count || (entryType !== undefined && entryType !== basicType)
        || (entryNumber !== undefined && entryNumber !== number) || (numbers.has(number) && numbers.get(number) !== reference)) reject();
    numbers.set(number, reference);
    const prior = parsed.get(reference);
    if (prior) {
      if (basicType === 1) reject(); // No directory hard links or recursion cycles.
      prior.references++;
      logicalBytes += prior.entry.bytes;
      if (logicalBytes > limits.payload) reject();
      entries.set(name, { ...prior.entry, pathSha256: hash(name) });
      if (prior.target !== null) targets.set(name, prior.target);
      return;
    }
    const entry = { pathSha256: hash(name), type: ["", "directory", "file", "symlink"][basicType], mode, bytes: 0 };
    const record = { entry, references: 1, links: 1, target: null };
    parsed.set(reference, record); entries.set(name, entry);
    let end;
    if (basicType === 1) {
      const size = type === 1 ? u16(b, at + 24) : u32(b, at + 20);
      const block = u32(b, at + (type === 1 ? 16 : 24));
      const offset = u16(b, at + (type === 1 ? 26 : 34));
      const parent = u32(b, at + 28), indexRecords = [];
      if (size < 3 || size > limits.metadata || (name && parent !== parentNumber)) reject();
      end = at + (type === 1 ? 32 : 40);
      if (type === 8) {
        if (u32(b, at + 36) !== noFragment) reject();
        const indexes = u16(b, at + 32);
        for (let i = 0; i < indexes; i++) {
          const length = u32(b, end + 8) + 1;
          if (length > 256) reject();
          indexRecords.push({ index: u32(b, end), block: u32(b, end + 4), name: text(range(b, end + 12, length)) });
          range(b, end, 12 + length); end += 12 + length;
        }
      }
      if (size > 3) {
        const directoryPosition = position(directories, block, offset);
        const content = range(directories.bytes, directoryPosition, size - 3), headers = new Map();
        let cursor = 0, previous = "";
        while (cursor < content.length) {
          const headerPosition = cursor;
          const children = u32(content, cursor) + 1, inodeBlock = u32(content, cursor + 4), base = u32(content, cursor + 8);
          if (children > 256) reject();
          cursor += 12;
          for (let i = 0; i < children; i++) {
            const inodeOffset = u16(content, cursor), delta = range(content, cursor + 2, 2).readInt16LE();
            const childType = u16(content, cursor + 4), length = u16(content, cursor + 6) + 1;
            const child = text(range(content, cursor + 8, length));
            if (child.includes("/") || child === "." || child === ".." || child <= previous) reject();
            if (i === 0) headers.set(headerPosition, child);
            previous = child; cursor += 8 + length;
            walk(inodeBlock * 65536 + inodeOffset, name ? name + "/" + child : child, number, childType, base + delta, depth + 1);
          }
        }
        if (cursor !== content.length) reject();
        let previousIndex = -1;
        for (const item of indexRecords) {
          if (item.index <= previousIndex || headers.get(item.index) !== item.name
              || position(directories, item.block, (offset + item.index) % 8192) !== directoryPosition + item.index) reject();
          previousIndex = item.index;
        }
      } else if (indexRecords.length) reject();
    } else if (basicType === 3) {
      record.links = u32(b, at + 16);
      const length = u32(b, at + 20), target = text(range(b, at + 24, length));
      end = at + 24 + length;
      if (type === 10) { if (u32(b, end) !== noFragment) reject(); end += 4; }
      entry.bytes = length; entry.targetSha256 = hash(target); record.target = target;
      targets.set(name, target);
    } else {
      const extended = type === 9;
      let start = extended ? u64(b, at + 16) : u32(b, at + 16);
      const size = extended ? u64(b, at + 24) : u32(b, at + 28);
      const frag = u32(b, at + (extended ? 44 : 20)), offset = u32(b, at + (extended ? 48 : 24));
      if (size > limits.file) reject();
      let sparse = 0;
      if (extended) { record.links = u32(b, at + 40); if (u32(b, at + 52) !== noFragment) reject(); }
      const blocks = frag === noFragment ? Math.ceil(size / blockSize) : Math.floor(size / blockSize);
      end = at + (extended ? 56 : 32);
      const hasher = createHash("sha256"); let prefix = Buffer.alloc(0);
      const consume = (data) => { hasher.update(data); if (prefix.length < 4) prefix = Buffer.concat([prefix, data.subarray(0, 4 - prefix.length)]); };
      logicalBytes += size;
      if (logicalBytes > limits.payload) reject();
      for (let i = 0; i < blocks; i++) {
        const field = u32(b, end); end += 4;
        const length = Math.min(blockSize, size - i * blockSize);
        if (field === 0) { consume(Buffer.alloc(length)); sparse += length; continue; }
        const data = dataBlock(start, field, length);
        if (data.length !== length) reject();
        consume(data); start += field & 0xffffff;
      }
      if (extended && u64(b, at + 32) !== sparse) reject();
      if (frag !== noFragment) {
        if (size % blockSize === 0) reject();
        consume(range(fragment(frag), offset, size % blockSize));
      }
      entry.bytes = size; entry.sha256 = hasher.digest("hex");
      entry.elf = prefix.equals(Buffer.from([127, 69, 76, 70])); entry.componentMapping = "unresolved";
    }
    range(b, at, end - at); spans.push([at, end]);
  }
  const root = u64(bytes, 32);
  walk(root, "", undefined);
  if (entries.get("")?.type !== "directory" || parsed.size !== count) reject();
  // All inodes must be reachable, non-overlapping, and exactly consumed.
  let end = 0;
  for (const [start, stop] of spans.sort((a, b) => a[0] - b[0])) { if (start !== end) reject(); end = stop; }
  if (end !== inodes.bytes.length) reject();
  for (const [reference, record] of parsed) {
    if (record.entry.type !== "directory" && record.references !== record.links) reject();
    if (exports && u64(exports.data, (u32(inodes.bytes, inodePosition(reference) + 12) - 1) * 8) !== reference) reject();
  }
  // Resolve links inside this in-memory tree only. Absolute, escaping, dangling,
  // cyclic and through-nondirectory links fail closed. No host paths are read.
  for (const [name, target] of targets) {
    if (!target || target.startsWith("/")) reject();
    const parts = name.split("/").slice(0, -1), pending = target.split("/");
    let hops = 0;
    while (pending.length) {
      const part = pending.shift();
      if (!part || part === ".") continue;
      if (part === "..") { if (!parts.length) reject(); parts.pop(); continue; }
      parts.push(part);
      const current = parts.join("/"), found = entries.get(current);
      if (!found) reject();
      if (found.type === "symlink") {
        if (++hops > 40) reject();
        const next = targets.get(current);
        if (!next || next.startsWith("/")) reject();
        parts.pop(); pending.unshift(...next.split("/"));
      } else if (pending.length && found.type !== "directory") reject();
    }
    const resolved = parts.join("/");
    if (!entries.has(resolved)) reject();
    entries.get(name).resolvedPathSha256 = hash(resolved);
  }
  return entries;
}
