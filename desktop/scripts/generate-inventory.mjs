#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile, readdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { rustHost } from "./build-platform.mjs";
import { nativeInventory, nativeReferences } from "./native-inventory.mjs";
import { cargoLicenseExpression, assertInventoryLicenses } from "./inventory-licenses.mjs";
import { noticeWriter, summaryProperty } from "./inventory-summary.mjs";
import { workspaceNoticeReferences } from "./workspace-notices.mjs";
import { supplementalNotices } from "./supplemental-notices.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const run = (command, args) =>
  execFileSync(command, args, {
    cwd: root,
    encoding: "utf8",
    maxBuffer: 32 * 1024 * 1024,
  });
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
const host = rustHost(run("rustc", ["-vV"]));
const target = process.argv[2] ?? host;
if (!target || !/^[-a-z0-9_]+$/.test(target))
  throw new Error("A Rust target triple is required.");
const metadata = JSON.parse(
  run("cargo", [
    "metadata",
    "--format-version",
    "1",
    "--locked",
    "--all-features",
    "--filter-platform",
    target,
  ]),
);
const nodes = new Map(metadata.resolve.nodes.map((node) => [node.id, node]));
const packages = metadata.packages
  .filter((pkg) => nodes.has(pkg.id))
  .sort((a, b) =>
    `${a.name}@${a.version}`.localeCompare(`${b.name}@${b.version}`),
  );
const reference = (pkg) => `pkg:cargo/${pkg.name}@${pkg.version}`;
const references = new Map(packages.map((pkg) => [pkg.id, reference(pkg)]));
const lock = await readFile(path.join(root, "Cargo.lock"), "utf8");
const checksums = new Map(
  [
    ...lock.matchAll(
      /\[\[package\]\]\nname = "([^"]+)"\nversion = "([^"]+)"(?:\nsource = "[^"]+")?\nchecksum = "([a-f0-9]{64})"/g,
    ),
  ].map((match) => [`${match[1]}@${match[2]}`, match[3]]),
);
const notices = noticeWriter();
notices.push(
  "# LockedIn Flow desktop dependency notices",
  "",
  "This build inventory covers Cargo target/build dependencies, verified nested speech sources, and the model; not every listed crate is linked at runtime.",
  "It is not an extracted installer inventory or complete redistribution-notice review. Bundled platform components require separate payload and license reconciliation.",
  "The Windows offline WebView2 installer is a redistributed input, distinct from the installed shared Evergreen runtime. AppImage can bundle native libraries and webview helpers; they are not all external system prerequisites. See desktop/SECURITY.md.",
  "",
);
async function licenseFiles(directory, relative = "") {
  const found = [];
  for (const item of await readdir(directory, { withFileTypes: true })) {
    if ([".git", "target", "node_modules"].includes(item.name)) continue;
    const name = relative + item.name;
    if (item.isDirectory())
      found.push(
        ...(await licenseFiles(path.join(directory, item.name), name + "/")),
      );
    else if (
      item.isFile() &&
      /^(?:licen[cs]e|copying|copyright|notice)(?:[._-].*)?$/i.test(item.name)
    )
      found.push(name);
  }
  return found.sort();
}
const components = [];
for (const pkg of packages) {
  if (!pkg.license)
    throw new Error("A dependency is missing its license expression.");
  const licenseExpression = cargoLicenseExpression(pkg.license);
  const component = {
    type: "library",
    "bom-ref": reference(pkg),
    name: pkg.name,
    version: pkg.version,
    purl: reference(pkg),
    licenses: [{ expression: licenseExpression }],
  };
  if (licenseExpression !== pkg.license)
    component.properties = [{ name: "lockedin:cargo-license-declaration", value: pkg.license }];
  const checksum = checksums.get(`${pkg.name}@${pkg.version}`);
  if (checksum) component.hashes = [{ alg: "SHA-256", content: checksum }];
  if (pkg.name === "glib") {
    if (path.dirname(pkg.manifest_path) !== path.join(root, "vendor", "glib"))
      throw new Error("The reviewed GLib backport is not selected.");
    component.properties = [
      ...(component.properties ?? []),
      {
        name: "lockedin:source-modification",
        value:
          "Upstream two-line RUSTSEC-2024-0429 backport; verified by scripts/verify-glib-backport.mjs",
      },
    ];
  }
  components.push(component);
  notices.push(
    `## ${pkg.name} ${pkg.version}`,
    "",
    `License: ${pkg.license}`,
    "",
  );
  const directory = path.dirname(pkg.manifest_path);
  const files = await licenseFiles(directory);
  if (pkg.license_file) {
    const relative = path.relative(
      directory,
      path.resolve(directory, pkg.license_file),
    );
    if (!files.includes(relative)) files.push(relative);
  }
  for (const file of files) {
    const resolved = path.resolve(directory, file);
    if (!resolved.startsWith(directory + path.sep))
      throw new Error("Dependency license escapes its package.");
    const bytes = await readFile(resolved);
    if (bytes.length > 2 * 1024 * 1024 || bytes.includes(0))
      throw new Error("Invalid dependency license text.");
    notices.forComponents([reference(pkg)],
      `### ${file.replaceAll("\\", "/")}`,
      "",
      bytes.toString("utf8"),
      "",
    );
  }
  const supplemental = await supplementalNotices(pkg, checksum);
  for (const notice of supplemental)
    notices.forComponents([reference(pkg)],
      `### Supplemental upstream ${notice.label}`,
      "",
      `Immutable source: ${notice.source}`,
      "",
      notice.text,
      "",
    );
  if (!files.length && !supplemental.length && pkg.source)
    notices.push(
      `Published source: https://crates.io/crates/${pkg.name}/${pkg.version}`,
      "",
    );
}
const nativePackage = packages.find((pkg) => pkg.name === "whisper-rs-sys");
const native = await nativeInventory(
  nativePackage,
  checksums.get(`${nativePackage?.name}@${nativePackage?.version}`),
);
components.push(...native.components);
for (let i = 0; i < native.notices.length;) {
  const association = native.noticeAssociations.find((entry) => entry.start === i);
  if (association) {
    notices.forComponents(association.refs, ...native.notices.slice(i, association.end));
    i = association.end;
  } else notices.push(native.notices[i++]);
}
const model = JSON.parse(
  await readFile(path.join(root, "models.json"), "utf8"),
);
components.push({
  type: "machine-learning-model",
  "bom-ref": model.id,
  name: model.name,
  version: model.sha256,
  licenses: [{ license: { id: model.license } }],
  hashes: [{ alg: "SHA-256", content: model.sha256 }],
  externalReferences: [{ type: "distribution", url: model.url }],
});
const ownedNoticeRefs = await workspaceNoticeReferences(metadata, root, readFile);
for (const [label, file, refs] of [
  ["LockedIn Flow", "LICENSE", ["lockedin-flow", ...ownedNoticeRefs]],
  ["Whisper model", "ThirdPartyLicenses/Whisper-MIT.txt", [model.id]],
  ["Whisper.cpp", "ThirdPartyLicenses/Whisper-cpp-MIT.txt", [nativeReferences.whisper]],
]) {
  notices.forComponents(refs,
    `## ${label}`,
    "",
    await readFile(path.join(root, "..", file), "utf8"),
    "",
  );
}
const revision = run("git", ["rev-parse", "HEAD"]).trim();
const sourceState = run("git", [
  "status",
  "--porcelain",
  "--untracked-files=all",
]).trim()
  ? "modified"
  : "clean";
// RFC 4122 URL-namespace UUIDv5: stable for the reviewed source/target/lockfile.
const identity = createHash("sha1")
  .update(Buffer.from("6ba7b8119dad11d180b400c04fd430c8", "hex"))
  .update(
    `https://github.com/LockedinLabs-AI/LockedIn-Flow/tree/${revision}/${target}/${hash(lock)}`,
  )
  .digest()
  .subarray(0, 16);
identity[6] = (identity[6] & 0x0f) | 0x50;
identity[8] = (identity[8] & 0x3f) | 0x80;
const identifier = identity
  .toString("hex")
  .replace(/^(.{8})(.{4})(.{4})(.{4})(.{12})$/, "$1-$2-$3-$4-$5");
const sbom = {
  $schema: "http://cyclonedx.org/schema/bom-1.6.schema.json",
  bomFormat: "CycloneDX",
  specVersion: "1.6",
  serialNumber: `urn:uuid:${identifier}`,
  version: 1,
  metadata: {
    timestamp: run("git", ["show", "-s", "--format=%cI", "HEAD"]).trim(),
    component: {
      type: "application",
      "bom-ref": "lockedin-flow",
      name: "LockedIn Flow",
      version: "0.5.0-alpha.1",
      licenses: [{ license: { id: "MIT" } }],
    },
    properties: [
      { name: "lockedin:source-revision", value: revision },
      { name: "lockedin:source-state", value: sourceState },
      { name: "lockedin:target", value: target },
      { name: "lockedin:cargo-lock-sha256", value: hash(lock) },
      {
        name: "lockedin:npm-lock-sha256",
        value: hash(await readFile(path.join(root, "package-lock.json"))),
      },
      { name: "lockedin:rustc", value: run("rustc", ["--version"]).trim() },
    ],
  },
  components,
  dependencies: [
    {
      ref: "lockedin-flow",
      dependsOn: [
        model.id,
        ...packages
          .filter((pkg) => pkg.name.startsWith("lockedin-flow-"))
          .map(reference),
      ],
    },
    ...packages.map((pkg) => ({
      ref: reference(pkg),
      dependsOn: [
        ...nodes.get(pkg.id).dependencies.map((id) => references.get(id)).filter(Boolean),
        ...(pkg.id === nativePackage.id ? [nativeReferences.whisper] : []),
      ].sort(),
    })),
    ...native.dependencies,
  ],
};
assertInventoryLicenses(sbom);
sbom.metadata.properties.push({ name: summaryProperty, value: JSON.stringify(notices.index([sbom.metadata.component, ...components])) });
const output = path.join(root, "app/resources/compliance");
await mkdir(output, { recursive: true });
await writeFile(
  path.join(output, "SBOM.cdx.json"),
  JSON.stringify(sbom, null, 2) + "\n",
);
await writeFile(
  path.join(output, "THIRD-PARTY-NOTICES.txt"),
  notices.bytes(),
);
await writeFile(
  path.join(output, "LICENSE.txt"),
  await readFile(path.join(root, "../LICENSE")),
);
await writeFile(
  path.join(output, "MODEL.json"),
  JSON.stringify(model, null, 2) + "\n",
);
process.stdout.write(
  `Generated ${target} build inventory: ${components.length} components; source ${sourceState}.\n`,
);
