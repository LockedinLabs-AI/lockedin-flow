import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { archiveExtraction } from "./build-platform.mjs";

const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
export const nativeReferences = {
  whisper: "lockedin-native-whisper-cpp",
  ggml: "lockedin-native-ggml",
};

// These sources are nested in a registry crate, not separately resolved Cargo
// packages. Preserve that distinction rather than inventing upstream commits.
export function describeNativeSources(pkg, archiveChecksum, files) {
  if (pkg?.name !== "whisper-rs-sys" || !/^[a-f0-9]{64}$/.test(archiveChecksum))
    throw new Error("The native speech carrier needs a locked registry identity.");
  const source = (name) => {
    const bytes = files.get(name);
    if (!bytes) throw new Error("A required native source or notice is missing.");
    return bytes.toString("utf8");
  };
  const whisper = source("whisper.cpp/CMakeLists.txt").match(
    /project\("whisper\.cpp" VERSION (\d+\.\d+\.\d+)\)/,
  )?.[1];
  const ggmlCmake = source("whisper.cpp/ggml/CMakeLists.txt");
  const ggmlParts = ["MAJOR", "MINOR", "PATCH"].map(
    (part) => ggmlCmake.match(new RegExp(`set\\(GGML_VERSION_${part} (\\d+)\\)`))?.[1],
  );
  const vcs = JSON.parse(source(".cargo_vcs_info.json"));
  if (
    !whisper ||
    ggmlParts.some((part) => part === undefined) ||
    !/^[a-f0-9]{40}$/.test(vcs.git?.sha1) ||
    vcs.path_in_vcs !== "sys"
  )
    throw new Error("Unrecognized nested native source identity.");
  const license = source("whisper.cpp/LICENSE");
  if (!license.startsWith("MIT License") || !license.includes("The ggml authors"))
    throw new Error("Native speech license needs review.");
  const fingerprint = (prefix) => {
    const lines = [...files].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)
      .filter(([name]) => name.startsWith(prefix))
      .map(([name, bytes]) => `${hash(bytes)}  ${name}\n`)
      .join("");
    if (!lines) throw new Error("Native source tree is empty.");
    return hash(lines);
  };
  const component = (name, version, ref, prefix, repository) => ({
    type: "library",
    "bom-ref": ref,
    name,
    version,
    licenses: [{ license: { id: "MIT" } }],
    externalReferences: [{ type: "vcs", url: repository }],
    properties: [
      { name: "lockedin:carrier", value: `pkg:cargo/${pkg.name}@${pkg.version}` },
      { name: "lockedin:carrier-sha256", value: archiveChecksum },
      { name: "lockedin:carrier-vcs-revision", value: vcs.git.sha1 },
      { name: "lockedin:source-subdirectory", value: prefix.slice(0, -1) },
      { name: "lockedin:source-tree-sha256", value: fingerprint(prefix) },
      {
        name: "lockedin:source-identity-method",
        value: "Version read from bundled CMake source; carrier revision is not a standalone upstream component commit.",
      },
    ],
  });
  const components = [
    component("whisper.cpp", whisper, nativeReferences.whisper, "whisper.cpp/", "https://github.com/ggml-org/whisper.cpp"),
    component("ggml", ggmlParts.join("."), nativeReferences.ggml, "whisper.cpp/ggml/", "https://github.com/ggml-org/ggml"),
  ];
  const sgemm = source("whisper.cpp/ggml/src/ggml-cpu/llamafile/sgemm.cpp")
    .split(/\r?\n\r?\n/)[0]
    .replace(/^\/\/ ?/gm, "");
  if (!sgemm.startsWith("Copyright 2024 Mozilla Foundation") || !sgemm.endsWith("SOFTWARE."))
    throw new Error("Embedded CPU implementation notice needs review.");
  const yarn = source("whisper.cpp/ggml/src/ggml-cpu/ops.cpp").match(
    /^\/\/ MIT licensed\. Copyright \(c\) 2023 Jeffrey Quesnelle and Bowen Peng\.$/m,
  )?.[0];
  if (!yarn) throw new Error("Embedded algorithm attribution needs review.");
  return {
    components,
    // Shared retained source notices, not a claim that these backends are linked.
    noticeAssociations: [
      { start: 6, end: 7, refs: [nativeReferences.whisper, nativeReferences.ggml] },
      { start: 9, end: 10, refs: [nativeReferences.whisper, nativeReferences.ggml] },
      { start: 13, end: 15, refs: [nativeReferences.whisper, nativeReferences.ggml] },
    ],
    dependencies: [
      { ref: nativeReferences.whisper, dependsOn: [nativeReferences.ggml] },
      { ref: nativeReferences.ggml, dependsOn: [] },
    ],
    notices: [
      "## Bundled native speech sources",
      "",
      `whisper.cpp ${whisper}; ggml ${ggmlParts.join(".")}. Source: whisper-rs-sys ${pkg.version}, archive SHA-256 ${archiveChecksum}.`,
      "",
      "Native versions come from the bundled source. The carrier revision does not identify an independently released ggml snapshot. Optional source notices are retained even when a backend is not enabled.",
      "",
      license,
      "### Embedded CPU matrix multiplication (llamafile)",
      "",
      sgemm,
      "",
      "### YaRN algorithm",
      "",
      yarn.slice(3),
      "The MIT permission and warranty terms above apply.",
      "",
    ],
  };
}

async function sourceFiles(directory, prefix = "") {
  const files = [];
  for (const item of await readdir(directory, { withFileTypes: true })) {
    const name = prefix + item.name;
    if (item.isDirectory())
      files.push(...await sourceFiles(path.join(directory, item.name), name + "/"));
    else if (item.isFile()) files.push(name);
    else throw new Error("Native source contains a nonregular entry.");
  }
  return files.sort();
}

export function verifyNativeSource(expected, actual) {
  const names = [...expected.keys()].sort();
  if (JSON.stringify(names) !== JSON.stringify([...actual.keys()].sort()))
    throw new Error("Native source inventory differs from the locked archive.");
  for (const name of names) {
    if (!expected.get(name).equals(actual.get(name)))
      throw new Error("Native source differs from the locked archive.");
  }
}

export async function nativeInventory(pkg, archiveChecksum) {
  if (pkg?.name !== "whisper-rs-sys" || !/^[a-f0-9]{64}$/.test(archiveChecksum))
    throw new Error("The native speech carrier needs a locked registry identity.");
  const directory = path.dirname(pkg.manifest_path);
  const registry = path.resolve(directory, "../../..");
  const archivePath = path.join(registry, "cache", path.basename(path.dirname(directory)), `${pkg.name}-${pkg.version}.crate`);
  const archive = await readFile(archivePath);
  if (archive.length > 32 * 1024 * 1024 || hash(archive) !== archiveChecksum)
    throw new Error("Native source carrier differs from the Cargo lockfile.");
  const temporary = await mkdtemp(path.join(os.tmpdir(), "flow-native-source-"));
  try {
    // Only extract the checksum-pinned registry archive Cargo already fetched.
    await writeFile(path.join(temporary, "upstream.crate"), archive, { flag: "wx" });
    const extraction = archiveExtraction(temporary);
    execFileSync("tar", extraction.args, extraction.options);
    const upstream = path.join(temporary, `${pkg.name}-${pkg.version}`);
    const collect = async (base) => {
      const names = [".cargo_vcs_info.json", ...await sourceFiles(path.join(base, "whisper.cpp"), "whisper.cpp/")];
      const files = new Map();
      for (const name of names) files.set(name, await readFile(path.join(base, name)));
      return files;
    };
    const expected = await collect(upstream);
    const actual = await collect(directory);
    verifyNativeSource(expected, actual);
    return describeNativeSources(pkg, archiveChecksum, actual);
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
}
