import { createHash } from "node:crypto";
import { lstat, realpath } from "node:fs/promises";
import { boundedFile, standardTool } from "./linux-package-evidence.mjs";

export const hostReferenceScope = "exact-host-file-references-not-component-or-license-approval";
export const hostReferenceLimits = Object.freeze({ database: 32 * 1024 ** 2, packages: 4096, paths: 750000, runtimePaths: 150000, file: 256 * 1024 ** 2, readBytes: 1024 ** 3, copyright: 2 * 1024 ** 2 });
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
const failureCategories = new Set(["validation", "database-bounds", "database-encoding", "database-framing", "database-records", "database-metadata", "database-paths", "database-identity", "database-duplicates"]);
const fail = (category = "validation") => {
  // Fixed classifications only: never include database contents or tool errors.
  if (!failureCategories.has(category)) category = "validation";
  throw new Error("Linux host-reference evidence rejected (" + category + "); content withheld.");
};
const namePattern = /^[a-z0-9][a-z0-9+.-]{1,127}$/;
const versionPattern = /^[0-9][A-Za-z0-9.+:~\-]{0,127}$/;
// db-fsys:Files avoids localized diversion prose from --listfiles. The explicit
// delimiter is not a legal absolute file path. No package scripts are executed.
// Field definitions: manpages.debian.org/bookworm/dpkg/dpkg-query.1.en.html
export const dpkgReferenceFormat = "${binary:Package}\t${Version}\t${Architecture}\t${source:Package}\t${source:Version}\t${db:Status-Status}\n${db-fsys:Files}\n.\n";
const runtimePath = (value) => typeof value === "string" && value.length <= 512
  && /^\/(?:usr\/lib(?:exec)?|lib)\/[A-Za-z0-9_+.,@() /-]+$/.test(value)
  && !value.split("/").slice(1).some((part) => !part || part === "." || part === "..");
const docPath = (value) => typeof value === "string" && value.length <= 512
  && /^\/usr\/share\/doc\/[a-z0-9+.-]+\/copyright$/.test(value);

// This is installed-database observation, NOT repository/archive authentication.
// The returned raw identities/paths stay in process; only hashes reach reports.
export function parseDpkgReferences(bytes) {
  if (!Buffer.isBuffer(bytes) || !bytes.length || bytes.length > hostReferenceLimits.database) fail("database-bounds");
  if (bytes.some((b) => b === 127 || (b < 32 && b !== 9 && b !== 10))) fail("database-encoding");
  // Installed packages can own UTF-8 documentation filenames. Reject malformed
  // encoding rather than stripping high bits or using replacement characters.
  // Identity fields and eligible runtime paths retain their ASCII allowlists.
  let text;
  try { text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes); }
  catch { fail("database-encoding"); }
  if (!text.endsWith("\n.\n")) fail("database-framing");
  const records = text.slice(0, -3).split("\n.\n"), result = [], identities = new Set();
  if (records.length > hostReferenceLimits.packages) fail("database-records");
  let pathCount = 0;
  for (const record of records) {
    const lines = record.split("\n"), fields = lines.shift().split("\t");
    if (fields.length !== 6 || fields.some((f) => f.length > 160)) fail("database-metadata");
    const [binary, version, architecture, source, sourceVersion, status] = fields;
    if (!["not-installed", "config-files", "half-installed", "unpacked", "half-configured", "triggers-awaited", "triggers-pending", "installed"].includes(status)) fail("database-metadata");
    // db-fsys:Files prefixes each absolute filename with one formatting space
    // and may end in a newline. Consume that prefix, not arbitrary whitespace
    // in filenames (verified against native Ubuntu 22.04 dpkg-query output).
    if (lines.at(-1) === "") lines.pop();
    pathCount += lines.length;
    if (pathCount > hostReferenceLimits.paths || lines.some((line) => !line.startsWith(" /") || line.length > 4097 || line.includes("\t"))) fail("database-paths");
    const paths = lines.map((line) => line.slice(1));
    // Removed/partially installed records may lack version or source fields.
    if (status !== "installed") continue;
    const [name, qualifier, extra] = binary.split(":");
    if (!namePattern.test(name) || extra !== undefined || (qualifier !== undefined && qualifier !== architecture)
        || !versionPattern.test(version) || !/^[a-z0-9-]{1,32}$/.test(architecture)
        || !namePattern.test(source) || !versionPattern.test(sourceVersion)) fail("database-identity");
    const identity = JSON.stringify(["binary-dpkg-v1", binary, version, architecture]);
    if (identities.has(binary)) fail("database-duplicates");
    identities.add(binary);
    if (!["amd64", "all"].includes(architecture)) continue;
    result.push({ name, binaryIdentitySha256: hash(identity),
      sourceIdentitySha256: hash(JSON.stringify(["source-dpkg-v1", source, sourceVersion])),
      paths: [...new Set(paths.filter(runtimePath))] });
  }
  return result;
}

const nativeFiles = (pkg) => pkg.status === "payload-inspected"
  ? pkg.files.filter((f) => f.type === "file" && f.elf && f.verifiedResource !== "application") : [];
const matchingStatus = (count) => count === 0 ? "no-exact-host-file-match" : count === 1 ? "exact-host-file-match" : "ambiguous-host-file-match";

export function reconcileHostReferences(packages, databaseSha256, references, scan) {
  const index = new Map();
  for (const reference of references) {
    const key = reference.sha256 + ":" + reference.bytes;
    const candidates = index.get(key) ?? new Map();
    const identity = reference.binaryIdentitySha256 + ":" + reference.systemPathSha256;
    if (candidates.has(identity)) fail();
    candidates.set(identity, reference); index.set(key, candidates);
    if (candidates.size > 16) fail();
  }
  const result = { scope: hostReferenceScope, status: "collected", databaseSha256, scan,
    packages: packages.filter((p) => p.status === "payload-inspected").map((pkg) => ({
      format: pkg.format, packageSha256: pkg.sha256,
      files: nativeFiles(pkg).map((file) => {
        const refs = [...(index.get(file.sha256 + ":" + file.bytes)?.values() ?? [])]
          .sort((a, b) => (a.binaryIdentitySha256 + a.systemPathSha256).localeCompare(b.binaryIdentitySha256 + b.systemPathSha256));
        return { pathSha256: file.pathSha256, sha256: file.sha256, bytes: file.bytes,
          status: matchingStatus(refs.length), references: refs };
      }),
    })),
  };
  validateHostReferences(result, packages);
  return result;
}

export function validateHostReferences(value, packages) {
  const keys = (v, names) => {
    if (!v || typeof v !== "object" || Array.isArray(v) || Object.keys(v).length !== names.length
        || names.some((name) => !Object.hasOwn(v, name))) fail();
  };
  const digest = (v) => { if (typeof v !== "string" || !/^[a-f0-9]{64}$/.test(v)) fail(); };
  const integer = (v, min, max) => { if (!Number.isSafeInteger(v) || v < min || v > max) fail(); };
  if (value?.status === "unavailable") {
    keys(value, ["scope", "status", "reason"]);
    if (value.scope !== hostReferenceScope || value.reason !== "host-reference-collection-failed") fail();
    return;
  }
  keys(value, ["scope", "status", "databaseSha256", "scan", "packages"]);
  if (value.scope !== hostReferenceScope || value.status !== "collected") fail();
  digest(value.databaseSha256);
  keys(value.scan, ["runtimePaths", "sizeCandidates", "hashedElfFiles", "unreadableFiles"]);
  for (const n of Object.values(value.scan)) integer(n, 0, hostReferenceLimits.runtimePaths);
  if (value.scan.hashedElfFiles > value.scan.sizeCandidates || value.scan.sizeCandidates > value.scan.runtimePaths
      || value.scan.unreadableFiles > value.scan.runtimePaths) fail();
  const inspected = packages.filter((p) => p.status === "payload-inspected");
  const identities = new Map();
  if (!Array.isArray(value.packages) || value.packages.length !== inspected.length) fail();
  value.packages.forEach((pkg, p) => {
    keys(pkg, ["format", "packageSha256", "files"]);
    if (pkg.format !== inspected[p].format || pkg.packageSha256 !== inspected[p].sha256) fail();
    const files = nativeFiles(inspected[p]);
    if (!Array.isArray(pkg.files) || pkg.files.length !== files.length) fail();
    pkg.files.forEach((file, f) => {
      keys(file, ["pathSha256", "sha256", "bytes", "status", "references"]);
      for (const key of ["pathSha256", "sha256", "bytes"]) if (file[key] !== files[f][key]) fail();
      digest(file.pathSha256); digest(file.sha256); integer(file.bytes, 1, hostReferenceLimits.file);
      if (!Array.isArray(file.references) || file.references.length > 16 || file.status !== matchingStatus(file.references.length)) fail();
      let previous = "";
      for (const ref of file.references) {
        keys(ref, ["sha256", "bytes", "binaryIdentitySha256", "sourceIdentitySha256", "systemPathSha256", "copyright"]);
        for (const key of ["binaryIdentitySha256", "sourceIdentitySha256", "systemPathSha256"]) digest(ref[key]);
        if (ref.sha256 !== file.sha256 || ref.bytes !== file.bytes) fail();
        const identity = ref.binaryIdentitySha256 + ref.systemPathSha256;
        if (identity <= previous) fail(); previous = identity;
        const record = JSON.stringify(ref);
        if (identities.has(identity) && identities.get(identity) !== record) fail();
        identities.set(identity, record);
        if (ref.copyright?.status === "unavailable") keys(ref.copyright, ["status"]);
        else {
          keys(ref.copyright, ["status", "sha256", "bytes"]);
          if (ref.copyright.status !== "host-file-hashed-not-retained") fail();
          digest(ref.copyright.sha256); integer(ref.copyright.bytes, 1, hostReferenceLimits.copyright);
        }
      }
    });
  });
  if (identities.size > value.scan.hashedElfFiles) fail();
}

// Read only package-owned runtime paths on the native Linux build host. No
// recursive filesystem search, model/application execution or network access.
export async function collectHostReferences(packages, io = { run: standardTool, lstat, realpath, read: boundedFile }) {
  const args = ["--admindir=/var/lib/dpkg", "--show", "--showformat=" + dpkgReferenceFormat];
  const database = io.run("/usr/bin/dpkg-query", args, undefined, hostReferenceLimits.database);
  const owners = parseDpkgReferences(database), references = [], seen = new Set();
  const wanted = packages.flatMap(nativeFiles), sizes = new Set(wanted.map((f) => f.bytes));
  const wantedHashes = new Set(wanted.map((f) => f.sha256 + ":" + f.bytes));
  const scan = { runtimePaths: 0, sizeCandidates: 0, hashedElfFiles: 0, unreadableFiles: 0 };
  let readBytes = 0;
  const deadline = Date.now() + 120000;
  const copyrightCache = new Map();
  for (const owner of owners) for (const file of owner.paths) {
    if (++scan.runtimePaths > hostReferenceLimits.runtimePaths || Date.now() > deadline) fail();
    try {
      const original = await io.lstat(file);
      if (!original.isFile()) continue; // Do not follow package file symlinks.
      const resolved = await io.realpath(file);
      if (!runtimePath(resolved)) { scan.unreadableFiles++; continue; }
      const identity = owner.binaryIdentitySha256 + ":" + resolved;
      if (seen.has(identity)) continue;
      seen.add(identity);
      if (!sizes.has(original.size) || original.size > hostReferenceLimits.file) continue;
      scan.sizeCandidates++;
      readBytes += original.size;
      if (readBytes > hostReferenceLimits.readBytes) fail();
      const bytes = await io.read(resolved, hostReferenceLimits.file);
      if (bytes.length !== original.size || !bytes.subarray(0, 4).equals(Buffer.from([127, 69, 76, 70]))) continue;
      scan.hashedElfFiles++;
      const sha256 = hash(bytes);
      if (!wantedHashes.has(sha256 + ":" + bytes.length)) continue;
      if (!copyrightCache.has(owner.name)) {
        let copyright = { status: "unavailable" };
        try {
          const location = await io.realpath("/usr/share/doc/" + owner.name + "/copyright");
          if (!docPath(location)) fail();
          const text = await io.read(location, hostReferenceLimits.copyright);
          copyright = { status: "host-file-hashed-not-retained", sha256: hash(text), bytes: text.length };
        } catch { /* Absence is not proof of complete or shipped attribution. */ }
        copyrightCache.set(owner.name, copyright);
      }
      references.push({ sha256, bytes: bytes.length, binaryIdentitySha256: owner.binaryIdentitySha256,
        sourceIdentitySha256: owner.sourceIdentitySha256, systemPathSha256: hash(resolved), copyright: copyrightCache.get(owner.name) });
    } catch {
      // Do not convert an exhausted resource budget into a successful scan.
      if (readBytes > hostReferenceLimits.readBytes || Date.now() > deadline) fail();
      scan.unreadableFiles++;
    }
  }
  // Do not bind references to a database that changed while files were read.
  if (!database.equals(io.run("/usr/bin/dpkg-query", args, undefined, hostReferenceLimits.database))) fail();
  return reconcileHostReferences(packages, hash(database), references, scan);
}
