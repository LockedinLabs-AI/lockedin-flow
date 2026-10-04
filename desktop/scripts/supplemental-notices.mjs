import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";

const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");
const dataUrl = new URL("../notices/supplemental.json", import.meta.url);
const dataDigest = "0dda31aac1a7639ffe2bc3ee7211967528267261b29ace53882a7ca88917aa24";
const registry = "registry+https://github.com/rust-lang/crates.io-index";

// Immutable upstream notices for six explicitly pinned registry carriers only. This is
// source attribution, not runtime linkage or complete redistribution approval.
export async function supplementalNotices(pkg, checksum, read = readFile) {
  const bytes = await read(dataUrl);
  if (!Buffer.isBuffer(bytes) || bytes.length > 65536 || digest(bytes) !== dataDigest)
    throw new Error("Supplemental notice material does not match its reviewed digest.");
  const record = JSON.parse(bytes.toString("utf8")).find((item) => item.name === pkg.name);
  if (!record) return [];
  if (pkg.version !== record.version || checksum !== record.checksum ||
      pkg.license !== record.license || pkg.source !== registry)
    throw new Error("Supplemental notice carrier identity changed; review is required.");
  return record.notices.map((notice) => {
    const text = Buffer.from(notice.text, "utf8");
    if (text.length !== notice.bytes || digest(text) !== notice.sha256)
      throw new Error("Supplemental notice text identity changed.");
    return {
      label: `${notice.path} (${notice.kind === "short-notice-reference" ? "short notice/reference; not full license text" : "license text"})`,
      source: notice.url,
      text: notice.text,
    };
  });
}
