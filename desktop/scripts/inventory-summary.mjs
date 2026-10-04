import { createHash } from "node:crypto";

export const summaryProperty = "lockedin:notice-index-v1";
export const summaryScope = "source-notice-index-not-runtime-or-license-approval";
export const summaryLimits = Object.freeze({ components: 4096, blocks: 64, totalBlocks: 16384, bytes: 16 * 1024 ** 2, indexBytes: 4 * 1024 ** 2 });
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
const fail = () => { throw new Error("Inventory summary validation failed; content withheld."); };
const digest = (v) => { if (typeof v !== "string" || !/^[a-f0-9]{64}$/.test(v)) fail(); };
const number = (v, min, max) => { if (!Number.isSafeInteger(v) || v < min || v > max) fail(); };
function keys(v, required, optional = []) {
  if (!v || typeof v !== "object" || Array.isArray(v) || required.some((k) => !Object.hasOwn(v, k)) || Object.keys(v).some((k) => !required.includes(k) && !optional.includes(k))) fail();
}
const text = (v) => { if (typeof v !== "string" || !v || Buffer.byteLength(v) > 16384) fail(); return v; };

// Canonical inputs: UTF-8 JSON.stringify(tagged arrays), no trimming or Unicode
// normalization. License order is preserved from the source inventory.
export function componentIdentity(component) {
  const referenceSha256 = hash(JSON.stringify(["reference-v1", text(component["bom-ref"])]));
  if (!Array.isArray(component.licenses) || !component.licenses.length) fail();
  const licenses = component.licenses.map((entry) => {
    if (Object.hasOwn(entry, "expression")) { keys(entry, ["expression"]); return ["expression", text(entry.expression)]; }
    keys(entry, ["license"]); keys(entry.license, ["id"]);
    return ["id", text(entry.license.id)];
  });
  const result = { referenceSha256, licenseDeclarationSha256: hash(JSON.stringify(["licenses-v1", licenses])) };
  const props = new Map((component.properties ?? []).map(({ name, value }) => [name, value]));
  if (props.size !== (component.properties ?? []).length) fail();
  const nativeKeys = ["lockedin:carrier", "lockedin:carrier-sha256", "lockedin:carrier-vcs-revision", "lockedin:source-subdirectory", "lockedin:source-tree-sha256"];
  if (nativeKeys.some((k) => props.has(k))) {
    const values = nativeKeys.map((k) => text(props.get(k)));
    digest(values[1]); digest(values[4]);
    if (!/^[a-f0-9]{40}$/.test(values[2])) fail();
    result.sourceIdentitySha256 = hash(JSON.stringify(["native-carrier-tree-v1", ...values]));
  } else if (component.hashes?.length) {
    if (component.hashes.length !== 1 || component.hashes[0].alg !== "SHA-256") fail();
    digest(component.hashes[0].content);
    result.sourceIdentitySha256 = hash(JSON.stringify(["inventory-sha256-v1", component.hashes[0].content]));
  }
  // No identity is invented for local/workspace sources without locked hashes.
  return result;
}

export function noticeWriter() {
  const parts = [], blocks = new Map();
  let size = 0;
  function emit(refs, chunks) {
    if (!Array.isArray(chunks) || !chunks.length || chunks.some((v) => typeof v !== "string")) fail();
    const bytes = Buffer.from(chunks.join("\n"));
    const offset = size + (parts.length ? 1 : 0);
    if (offset + bytes.length > summaryLimits.bytes) fail();
    parts.push(...chunks); size = offset + bytes.length;
    if (refs.length && !bytes.length) fail();
    for (const ref of new Set(refs)) {
      const entries = blocks.get(ref) ?? [];
      entries.push({ sha256: hash(bytes), offset, bytes: bytes.length });
      blocks.set(ref, entries);
    }
  }
  return {
    push: (...chunks) => emit([], chunks),
    forComponents: (refs, ...chunks) => emit(refs, chunks),
    bytes: () => Buffer.from(parts.join("\n")),
    index(components) {
      const identities = components.map((c) => ({ ...componentIdentity(c), noticeBlocks: blocks.get(c["bom-ref"]) ?? [] }));
      const refs = new Set(components.map((c) => c["bom-ref"]));
      if ([...blocks.keys()].some((r) => !refs.has(r))) fail();
      const records = identities.map((c) => ({ ...c, noticeEvidence: c.noticeBlocks.length ? "retained-text" : "source-reference-only" })).sort((a, b) => a.referenceSha256 < b.referenceSha256 ? -1 : 1);
      const result = { noticesSha256: hash(this.bytes()), noticesBytes: size, components: records };
      validateIndex(result);
      return result;
    },
  };
}

function validateIndex(index) {
  keys(index, ["noticesSha256", "noticesBytes", "components"]);
  if (Buffer.byteLength(JSON.stringify(index)) > summaryLimits.indexBytes) fail();
  digest(index.noticesSha256); number(index.noticesBytes, 1, summaryLimits.bytes);
  if (!Array.isArray(index.components)) fail();
  number(index.components.length, 1, summaryLimits.components);
  let previous = "", total = 0;
  for (const c of index.components) {
    keys(c, ["referenceSha256", "licenseDeclarationSha256", "noticeBlocks", "noticeEvidence"], ["sourceIdentitySha256"]);
    digest(c.referenceSha256); digest(c.licenseDeclarationSha256);
    if (Object.hasOwn(c, "sourceIdentitySha256")) digest(c.sourceIdentitySha256);
    if (c.referenceSha256 <= previous) fail(); previous = c.referenceSha256;
    if (!Array.isArray(c.noticeBlocks)) fail();
    number(c.noticeBlocks.length, 0, summaryLimits.blocks);
    total += c.noticeBlocks.length; number(total, 0, summaryLimits.totalBlocks);
    if (c.noticeEvidence !== (c.noticeBlocks.length ? "retained-text" : "source-reference-only")) fail();
    let end = -1;
    for (const block of c.noticeBlocks) {
      keys(block, ["sha256", "offset", "bytes"]); digest(block.sha256);
      number(block.offset, 0, index.noticesBytes); number(block.bytes, 1, index.noticesBytes);
      if (block.offset < end || block.offset + block.bytes > index.noticesBytes) fail();
      end = block.offset + block.bytes;
    }
  }
}

export function validateInventorySummary(summary, sbomSha256) {
  keys(summary, ["scope", "sbomSha256", "noticesSha256", "noticesBytes", "components"]);
  if (summary.scope !== summaryScope || summary.sbomSha256 !== sbomSha256) fail();
  digest(summary.sbomSha256);
  validateIndex({ noticesSha256: summary.noticesSha256, noticesBytes: summary.noticesBytes, components: summary.components });
}

export function verifiedInventorySummary(sbomBytes, noticeBytes, expected) {
  if (!Buffer.isBuffer(sbomBytes) || !Buffer.isBuffer(noticeBytes) || sbomBytes.length > summaryLimits.bytes || noticeBytes.length > summaryLimits.bytes) fail();
  if (hash(sbomBytes) !== expected.sbomSha256 || hash(noticeBytes) !== expected.noticesSha256) fail();
  let sbom;
  try { sbom = JSON.parse(sbomBytes); } catch { fail(); }
  const entries = (sbom.metadata?.properties ?? []).filter((p) => p.name === summaryProperty);
  if (!entries.length) return undefined; // Historical inventory compatibility.
  if (entries.length !== 1 || typeof entries[0].value !== "string" || Buffer.byteLength(entries[0].value) > summaryLimits.indexBytes) fail();
  let index;
  try { index = JSON.parse(entries[0].value); } catch { fail(); }
  if (JSON.stringify(index) !== entries[0].value) fail();
  validateIndex(index);
  if (index.noticesSha256 !== expected.noticesSha256 || index.noticesBytes !== noticeBytes.length) fail();
  const identities = [sbom.metadata.component, ...sbom.components].map(componentIdentity).sort((a, b) => a.referenceSha256 < b.referenceSha256 ? -1 : 1);
  if (identities.length !== index.components.length) fail();
  index.components.forEach((c, i) => {
    const { noticeBlocks, noticeEvidence, ...identity } = c;
    if (JSON.stringify(identity) !== JSON.stringify(identities[i])) fail();
    for (const block of noticeBlocks) if (hash(noticeBytes.subarray(block.offset, block.offset + block.bytes)) !== block.sha256) fail();
  });
  return { scope: summaryScope, sbomSha256: expected.sbomSha256, ...index };
}
