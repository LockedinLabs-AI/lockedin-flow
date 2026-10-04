import assert from "node:assert/strict";
import test from "node:test";
import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { collectHostReferences, parseDpkgReferences, reconcileHostReferences, validateHostReferences, hostReferenceScope, hostReferenceLimits, dpkgReferenceFormat } from "../scripts/linux-host-references.mjs";
import { standardTool } from "../scripts/linux-package-evidence.mjs";

const hash = (value) => createHash("sha256").update(value).digest("hex");
const library = Buffer.from([127, 69, 76, 70, 17, 18, 19]);
const header = "libsynthetic:amd64\t1.2.3-4\tamd64\tsynthetic-source\t1.2.3-4\tinstalled";
const database = (paths, heading = header) => Buffer.from(heading + "\n" + paths.map((p) => " " + p).join("\n") + "\n.\n");
const packageFiles = () => [{ format: "appimage", status: "payload-inspected", sha256: hash("synthetic-package"), files: [
  { pathSha256: hash("application"), type: "file", sha256: hash(library), bytes: library.length, elf: true, verifiedResource: "application" },
  { pathSha256: hash("library"), type: "file", sha256: hash(library), bytes: library.length, elf: true },
  { pathSha256: hash("other"), type: "file", sha256: hash("other"), bytes: 5, elf: false },
] }];
function syntheticIO(db, files, resolved = {}) {
  const reads = [], commands = [];
  return { reads, commands,
    run(command, args) { commands.push([command, args]); return db; },
    async realpath(file) { if (!Object.hasOwn(files, resolved[file] ?? file)) throw new Error("synthetic private path"); return resolved[file] ?? file; },
    async lstat(file) { const value = files[file]; if (!value) throw new Error("synthetic private path"); return { size: value.length, isFile: () => Buffer.isBuffer(value) }; },
    async read(file, maximum) { reads.push(file); const value = files[file]; if (!Buffer.isBuffer(value) || value.length > maximum) throw new Error("synthetic private contents"); return value; },
  };
}

test("dpkg parser binds exact package/source identities and narrows paths", () => {
  const paths = ["/usr/lib/libsynthetic.so.1", "/lib/../private/value", "/usr/lib//ambiguous", "/outside-fixture/private", "/usr/libexec/synthetic", "/usr/lib/libsynthetic.so.1"];
  const parsed = parseDpkgReferences(database(paths));
  assert.equal(parsed.length, 1);
  assert.equal(parsed[0].name, "libsynthetic");
  assert.equal(parsed[0].binaryIdentitySha256, hash(JSON.stringify(["binary-dpkg-v1", "libsynthetic:amd64", "1.2.3-4", "amd64"])));
  assert.equal(parsed[0].sourceIdentitySha256, hash(JSON.stringify(["source-dpkg-v1", "synthetic-source", "1.2.3-4"])));
  assert.deepEqual(parsed[0].paths, ["/usr/lib/libsynthetic.so.1", "/usr/libexec/synthetic"]);
  assert.deepEqual(parseDpkgReferences(database([], "gone\t\t\t\t\tconfig-files")), []);
  assert.deepEqual(parseDpkgReferences(database([], header.replaceAll("amd64", "arm64"))), []);
});

test("dpkg malformed, duplicate, redirected, truncated and unbounded records fail", () => {
  const valid = database(["/usr/lib/libsynthetic.so.1"]);
  for (const bytes of [Buffer.alloc(0), valid.subarray(0, valid.length - 1), Buffer.concat([valid, valid]),
    Buffer.concat([valid, database([], header.replaceAll("1.2.3-4", "1.2.4-1"))]),
    database(["relative"]), database(["/usr/lib/private\tvalue"]), Buffer.concat([valid, Buffer.from([0])]),
    database([], header.replace(":amd64", ":all")), database([], header.replace("1.2.3-4", "../version")),
    database([], header.replace("installed", "unknown")), Buffer.from(valid.toString().replace(" /usr", "/usr")),
    Buffer.from(valid.toString().replace(" /usr", "  /usr")), Buffer.alloc(hostReferenceLimits.database + 1)])
    assert.throws(() => parseDpkgReferences(bytes), /content withheld/);
});

test("UTF-8 documentation paths do not disable exact ASCII runtime references", async () => {
  const db = database(["/usr/share/doc/libsynthetic/exemples/français.txt", "/usr/share/doc/libsynthetic/日本語.txt",
    "/usr/lib/libsynthetic.so.1", "/usr/lib/éxcluded.so"]);
  const parsed = parseDpkgReferences(db);
  assert.deepEqual(parsed[0].paths, ["/usr/lib/libsynthetic.so.1"]);
  const io = syntheticIO(db, { "/usr/lib/libsynthetic.so.1": library });
  const evidence = await collectHostReferences(packageFiles(), io);
  assert.equal(evidence.packages[0].files[0].status, "exact-host-file-match");
  assert.equal(evidence.databaseSha256, hash(db));
  assert.deepEqual(io.reads, ["/usr/lib/libsynthetic.so.1"]);
  assert.ok(!JSON.stringify(evidence).includes("français"));
  // No lossy decoding, metadata broadening, control characters or BOM removal.
  for (const bad of [Buffer.concat([db.subarray(0, -3), Buffer.from([0xc3, 0x28]), db.subarray(-3)]),
    database(["/usr/share/doc/libsynthetic/\u007fvalue"]), database([], header.replace("libsynthetic", "libéxample")),
    Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), db])]) {
    assert.throws(() => parseDpkgReferences(bad), /content withheld/);
  }
});

test("native dpkg formatting parses without interpreting its paths as commands", { skip: process.platform !== "linux" || !existsSync("/usr/bin/dpkg-query") }, () => {
  const bytes = execFileSync("/usr/bin/dpkg-query", ["--admindir=/var/lib/dpkg", "--show", "--showformat=" + dpkgReferenceFormat, "dpkg"],
    { maxBuffer: hostReferenceLimits.database, timeout: 10000, env: { PATH: "/usr/bin:/bin", LANG: "C", LC_ALL: "C" } });
  const records = parseDpkgReferences(bytes);
  assert.ok(records.every((r) => r.name === "dpkg"));
  if (process.arch === "x64") assert.equal(records.length, 1);
});

test("native full installed database parses before expensive installer compilation", { skip: process.platform !== "linux" || !existsSync("/usr/bin/dpkg-query") }, () => {
  // The single-package format probe cannot represent the full runner database.
  // standardTool withholds stdout/stderr on failure; parser errors contain only
  // fixed classifications, not host paths or raw package identities.
  const bytes = standardTool("/usr/bin/dpkg-query", ["--admindir=/var/lib/dpkg", "--show", "--showformat=" + dpkgReferenceFormat], undefined, hostReferenceLimits.database);
  assert.ok(parseDpkgReferences(bytes).length > 0);
});

test("database diagnostics are fixed categories without raw input", () => {
  for (const bytes of [Buffer.from("synthetic-private-value"), Buffer.from([0]), database([], header.replace("installed", "synthetic-private-status"))]) {
    assert.throws(() => parseDpkgReferences(bytes), (error) => {
      assert.match(error.message, /^Linux host-reference evidence rejected \(database-[a-z]+\); content withheld\.$/);
      assert.ok(!error.message.includes("synthetic-private"));
      return true;
    });
  }
});

test("collector matches complete original bytes, hashes metadata, and does not ship notices", async () => {
  const files = { "/usr/lib/libsynthetic.so.1": library, "/usr/share/doc/libsynthetic/copyright": Buffer.from("Synthetic attribution only") };
  const db = database(["/usr/lib/libsynthetic.so.1", "/outside-fixture/private"]);
  const io = syntheticIO(db, files), packages = packageFiles();
  const evidence = await collectHostReferences(packages, io);
  validateHostReferences(evidence, packages);
  assert.equal(evidence.scope, hostReferenceScope);
  assert.equal(evidence.databaseSha256, hash(db));
  assert.equal(evidence.packages[0].files.length, 1); // Application and non-ELF excluded.
  const entry = evidence.packages[0].files[0];
  assert.equal(entry.status, "exact-host-file-match");
  assert.equal(entry.references[0].copyright.status, "host-file-hashed-not-retained");
  assert.equal(entry.references[0].sha256, hash(library));
  assert.equal(entry.references[0].systemPathSha256, hash("/usr/lib/libsynthetic.so.1"));
  const json = JSON.stringify(evidence);
  for (const raw of ["libsynthetic", "1.2.3-4", "/usr/", "Synthetic attribution", "synthetic-source", "/outside-fixture/"]) assert.ok(!json.includes(raw));
  assert.equal(io.commands.length, 2);
  assert.deepEqual(io.commands[0], ["/usr/bin/dpkg-query", ["--admindir=/var/lib/dpkg", "--show", "--showformat=" + dpkgReferenceFormat]]);
  assert.equal(io.reads.length, 2);
});

test("same-size transformed files and absent files cannot inherit host attribution", async () => {
  const altered = Buffer.from(library); altered[6] ^= 1;
  const files = { "/usr/lib/libsynthetic.so.1": altered };
  const db = database(["/usr/lib/libsynthetic.so.1", "/usr/lib/missing"]);
  const io = syntheticIO(db, files), evidence = await collectHostReferences(packageFiles(), io);
  assert.equal(evidence.packages[0].files[0].status, "no-exact-host-file-match");
  assert.equal(evidence.scan.unreadableFiles, 1);
  assert.deepEqual(io.reads, ["/usr/lib/libsynthetic.so.1"]);
});

test("multiple genuine host matches remain ambiguous, never choose one arbitrarily", async () => {
  const files = { "/usr/lib/one.so": library, "/usr/lib/two.so": library };
  const db = database(Object.keys(files)), evidence = await collectHostReferences(packageFiles(), syntheticIO(db, files));
  assert.equal(evidence.packages[0].files[0].status, "ambiguous-host-file-match");
  assert.equal(evidence.packages[0].files[0].references.length, 2);
  assert.ok(evidence.packages[0].files[0].references.every((r) => r.copyright.status === "unavailable"));
});

test("symlinks, escapes and changed database cannot authorize evidence", async () => {
  const db = database(["/usr/lib/link.so", "/lib/copy.so", "/usr/lib/synthetic.so"]);
  const files = { "/usr/lib/link.so": { length: library.length }, "/lib/copy.so": library, "/usr/lib/synthetic.so": library,
    "/outside-fixture/private": library, "/usr/share/doc/libsynthetic/copyright": Buffer.from("synthetic"), "/outside-fixture/notice": Buffer.from("not allowed") };
  const io = syntheticIO(db, files, { "/lib/copy.so": "/outside-fixture/private", "/usr/share/doc/libsynthetic/copyright": "/outside-fixture/notice" });
  const result = await collectHostReferences(packageFiles(), io);
  assert.deepEqual(io.reads, ["/usr/lib/synthetic.so"]);
  assert.equal(result.packages[0].files[0].references[0].copyright.status, "unavailable");
  let calls = 0;
  await assert.rejects(collectHostReferences(packageFiles(), { ...io, run: () => ++calls === 1 ? db : Buffer.from("changed") }), /content withheld/);
});

test("merged-root aliases deduplicate only the same owner and canonical file", async () => {
  const db = database(["/lib/synthetic.so", "/usr/lib/synthetic.so"]);
  const io = syntheticIO(db, { "/lib/synthetic.so": library, "/usr/lib/synthetic.so": library }, { "/lib/synthetic.so": "/usr/lib/synthetic.so" });
  const evidence = await collectHostReferences(packageFiles(), io);
  assert.equal(evidence.packages[0].files[0].status, "exact-host-file-match");
  assert.deepEqual(io.reads, ["/usr/lib/synthetic.so"]);
});

test("size prefilter avoids unrelated host reads; bounded reader errors stay explicit", async () => {
  const db = database(["/usr/lib/unrelated.so", "/usr/lib/synthetic.so"]);
  const io = syntheticIO(db, { "/usr/lib/unrelated.so": Buffer.alloc(40), "/usr/lib/synthetic.so": library });
  io.read = async (file) => { io.reads.push(file); throw new Error("private contents or permission failure"); };
  const evidence = await collectHostReferences(packageFiles(), io);
  assert.deepEqual(io.reads, ["/usr/lib/synthetic.so"]);
  assert.equal(evidence.scan.unreadableFiles, 1);
  assert.equal(evidence.packages[0].files[0].status, "no-exact-host-file-match");
  assert.ok(!JSON.stringify(evidence).includes("private contents"));
});

test("the aggregate read budget cannot become a successful partial scan", async () => {
  const paths = Array.from({length:5}, (_, n) => "/usr/lib/large-" + n + ".so");
  const packages = packageFiles(); packages[0].files[1].bytes = hostReferenceLimits.file;
  const io = { run: () => database(paths),
    lstat: async () => ({ isFile: () => true, size: hostReferenceLimits.file }), realpath: async (file) => file,
    // Synthetic short reads avoid allocating a gigabyte for this boundary test.
    read: async () => library };
  await assert.rejects(collectHostReferences(packages, io), /content withheld/);
});

test("validator rejects raw fields, missing coverage, false status, mismatched hashes and approval", async () => {
  const db = database(["/usr/lib/synthetic.so"]), packages = packageFiles();
  const evidence = await collectHostReferences(packages, syntheticIO(db, { "/usr/lib/synthetic.so": library }));
  for (const mutate of [
    (r) => { r.rawDatabase = "private"; },
    (r) => { r.status = "approved"; },
    (r) => { r.packages[0].packageSha256 = hash("other"); },
    (r) => { r.packages[0].files.pop(); },
    (r) => { r.packages[0].files[0].status = "no-exact-host-file-match"; },
    (r) => { r.packages[0].files[0].pathSha256 = hash("other"); },
    (r) => { r.packages[0].files[0].references[0].sha256 = hash("other"); },
    (r) => { r.packages[0].files[0].references[0].bytes++; },
    (r) => { r.packages[0].files[0].references[0].copyright = { status: "approved" }; },
    (r) => { r.packages[0].files[0].references[0].sourceIdentitySha256 = "source"; },
    (r) => { r.packages[0].files[0].references.push(r.packages[0].files[0].references[0]); r.packages[0].files[0].status = "ambiguous-host-file-match"; },
    (r) => { r.scan.runtimePaths = -1; },
    (r) => { r.scan.hashedElfFiles = 0; },
  ]) { const copy = structuredClone(evidence); mutate(copy); assert.throws(() => validateHostReferences(copy, packages)); }
  validateHostReferences({ scope: hostReferenceScope, status: "unavailable", reason: "host-reference-collection-failed" }, packages);
  assert.throws(() => validateHostReferences({ scope: hostReferenceScope, status: "unavailable", reason: "raw tool output" }, packages));
  assert.throws(() => reconcileHostReferences(packages, hash(db), Array(17).fill(evidence.packages[0].files[0].references[0]), evidence.scan));
});
