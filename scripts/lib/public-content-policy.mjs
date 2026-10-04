import { createHash } from "node:crypto";
import path from "node:path";

const rootFiles = new Set([
  ".gitattributes", ".gitignore", ".swift-format", "CHANGELOG.md", "CODE_OF_CONDUCT.md",
  "CONTRIBUTING.md", "GOVERNANCE.md", "Info.plist", "LICENSE", "NOTICE",
  "Package.resolved", "Package.swift", "README.md", "SECURITY.md", "SUPPORT.md",
  "TRADEMARKS.md", "entitlements.plist", "package.json", "package-lock.json",
]);
const roots = new Set([
  ".github", "Sources", "Tests", "ThirdPartyLicenses", "Vendor", "branding",
  "distribution", "docs", "examples", "scripts", "security", "desktop",
]);
const textExtensions = new Set([
  ".swift", ".md", ".json", ".txt", ".yaml", ".yml", ".svg", ".plist",
  ".sh", ".mjs", ".jq", ".tsv", ".csv", ".strings", ".resolved",
]);

export function scanText(text, { attribution = false, commitMetadata = false } = {}) {
  const rules = [];
  if (/\/(?:Users|home)\/[A-Za-z0-9._-]+\//.test(text)
      || /[A-Z]:\\Users\\[^\\\r\n]+\\/i.test(text)) rules.push("personal-home-path");
  if (/file:\/\/\/(?:Users|home|private)\//.test(text)) rules.push("local-file-url");
  if (/^\s*(?:#{1,6}\s*)?(?:BEGIN (?:CHAT|CONVERSATION)|<\|(?:im_start|start_header_id)\|>)/im.test(text)
      || /"role"\s*:\s*"(?:user|assistant)"[\s\S]{0,100}"content"\s*:/.test(text)) {
    rules.push("conversation-export");
  }
  if (/^\s*(?:TRANSCRIPT|LIVE-TRANSCRIPT|INSERT-DIAGNOSTICS):/m.test(text)) {
    rules.push("captured-diagnostic-output");
  }
  const emails = text.match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi) ?? [];
  if (!attribution && emails.some((email) => {
    // GitHub signs web/automation commits with these public service identities.
    // This exception applies to commit metadata, never source or prose.
    if (commitMetadata && ["noreply", "support"].some((name) =>
      email.toLowerCase() === [name, "github.com"].join("@"))) return false;
    if (/^[a-z0-9_-]+@[23]x\.png$/i.test(email)) return false;
    const domain = email.split("@")[1].toLowerCase();
    return !/^(?:example\.(?:com|org|net)|[a-z0-9.-]+\.example|[a-z0-9.-]+\.invalid|lockedinlabs\.ai|lockedinflow\.com|(?:[a-z0-9.-]+\.)?users\.noreply\.github\.com)$/.test(domain);
  })) rules.push("unreviewed-contact-address");
  return [...new Set(rules)];
}

export function scanEntry(file, bytes, { mode = "100644", media = {} } = {}) {
  const rules = [];
  const parts = file.split("/");
  const basename = parts.at(-1);
  if (mode !== "100644" && mode !== "100755") rules.push("nonregular-git-entry");
  if (parts.some((part) => ["", ".", ".."].includes(part))) rules.push("invalid-path");
  if (parts.length === 1 ? !rootFiles.has(file) : !roots.has(parts[0])) rules.push("unapproved-surface");
  if (parts.some((part) => /^(?:\.codex|\.agents|\.env(?:\..*)?|node_modules|logs?|recordings?|sessions?|scratch|internal|handoffs?)$/i.test(part))
      || /^(?:AGENTS|CLAUDE|CONTINUE|HANDOFF|SESSION|BUILD_STATUS)(?:[._-]|$)/i.test(basename)) {
    rules.push("private-or-generated-material");
  }
  if (bytes.length > 8 * 1024 * 1024) rules.push("oversized-source-asset");
  const extension = path.posix.extname(file).toLowerCase();
  if (extension === ".png") {
    const hash = createHash("sha256").update(bytes).digest("hex");
    if (media[file] !== hash) rules.push("unreviewed-media");
    if (!bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) {
      rules.push("invalid-png");
    } else {
      let cursor = 8;
      while (cursor + 12 <= bytes.length) {
        const length = bytes.readUInt32BE(cursor);
        if (cursor + length + 12 > bytes.length) { rules.push("invalid-png"); break; }
        const type = bytes.toString("ascii", cursor + 4, cursor + 8);
        if (["eXIf", "tEXt", "zTXt", "iTXt"].includes(type)) rules.push("embedded-image-metadata");
        cursor += length + 12;
        if (type === "IEND") break;
      }
    }
  } else if (rootFiles.has(file) || textExtensions.has(extension)
      || file === "desktop/tests/fixtures/path-privacy.cpp"
      || file === "desktop/app/windows/install-directory.wxs"
      || (parts[0] === "desktop" && [".rs", ".toml", ".lock", ".html", ".css", ".js", ".ps1"].includes(extension))
      || ["LICENSE", "NOTICE", "CODEOWNERS"].includes(basename)) {
    if (bytes.includes(0)) rules.push("binary-in-text-file");
    // Preserve authentic upstream copyright contacts only in this exact pinned
    // notice material. Any changed bytes or other path still undergo contact screening.
    const pinnedNoticeAttribution = file === "desktop/notices/supplemental.json"
      && createHash("sha256").update(bytes).digest("hex") === "0dda31aac1a7639ffe2bc3ee7211967528267261b29ace53882a7ca88917aa24";
    rules.push(...scanText(bytes.toString("utf8"), {
      attribution: pinnedNoticeAttribution || (/^(?:Vendor|ThirdPartyLicenses)\//.test(file) && /(?:LICENSE|\.txt$)/.test(basename)),
    }));
  } else {
    rules.push("unapproved-file-type");
  }
  return [...new Set(rules)];
}

export function stripPngMetadata(bytes) {
  const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  if (!bytes.subarray(0, 8).equals(signature)) throw new Error("Invalid PNG signature.");
  const chunks = [signature];
  let cursor = 8;
  while (cursor + 12 <= bytes.length) {
    const length = bytes.readUInt32BE(cursor);
    const end = cursor + length + 12;
    if (end > bytes.length) throw new Error("Truncated PNG.");
    const type = bytes.toString("ascii", cursor + 4, cursor + 8);
    if (!["eXIf", "tEXt", "zTXt", "iTXt"].includes(type)) chunks.push(bytes.subarray(cursor, end));
    cursor = end;
    if (type === "IEND") {
      if (cursor !== bytes.length) throw new Error("Unexpected data after PNG end.");
      return Buffer.concat(chunks);
    }
  }
  throw new Error("Missing PNG end.");
}

export function localLinks(file, text) {
  if (!file.endsWith(".md")) return [];
  const targets = [];
  for (const match of text.matchAll(/(?:\]\((?:<([^>]+)>|([^\s)]+))(?:\s+"[^"]*")?\)|\b(?:href|src|srcset)="([^"\s]+)")/g)) {
    const value = match[1] ?? match[2] ?? match[3];
    // Preserve the checksum-verified upstream Rustdoc link, not a filesystem link.
    if (file === "desktop/vendor/glib/README.md" && value === "struct@Variant") continue;
    if (/^(?:[a-z][a-z0-9+.-]*:|#|\/\/)/i.test(value)) continue;
    let clean;
    try { clean = decodeURIComponent(value.split(/[?#]/, 1)[0]); }
    catch { targets.push("!invalid-link"); continue; }
    if (clean) targets.push(path.posix.normalize(path.posix.join(path.posix.dirname(file), clean)));
  }
  return targets;
}
