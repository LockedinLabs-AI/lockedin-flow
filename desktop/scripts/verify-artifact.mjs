#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { rustHost } from "./build-platform.mjs";
import { nativeReferences } from "./native-inventory.mjs";
import { privatePathFindings } from "./build-path-privacy.mjs";
import { assertInventoryLicenses } from "./inventory-licenses.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const run = (command, args) =>
  execFileSync(command, args, { cwd: root, encoding: "utf8" }).trim();
const host = rustHost(run("rustc", ["-vV"]));
if (run("git", ["status", "--porcelain", "--untracked-files=all"]))
  throw new Error("Artifact verification requires a clean source tree.");
const read = (relative) => readFile(path.join(root, relative));
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
const sbom = JSON.parse(await read("app/resources/compliance/SBOM.cdx.json"));
const properties = Object.fromEntries(
  sbom.metadata.properties.map((item) => [item.name, item.value]),
);
const expected = {
  "lockedin:source-state": "clean",
  "lockedin:source-revision": run("git", ["rev-parse", "HEAD"]),
  "lockedin:target": host,
  "lockedin:cargo-lock-sha256": hash(await read("Cargo.lock")),
  "lockedin:npm-lock-sha256": hash(await read("package-lock.json")),
};
for (const [key, value] of Object.entries(expected)) {
  if (properties[key] !== value)
    throw new Error(
      "Artifact provenance does not match the clean native build.",
    );
}
if (
  sbom.bomFormat !== "CycloneDX" ||
  sbom.specVersion !== "1.6" ||
  !/^urn:uuid:[a-f0-9]{8}-[a-f0-9]{4}-5[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/.test(
    sbom.serialNumber,
  )
)
  throw new Error("Invalid inventory identity.");
const references = new Set([
  sbom.metadata.component["bom-ref"],
  ...sbom.components.map((item) => item["bom-ref"]),
]);
if (references.size !== sbom.components.length + 1)
  throw new Error("Duplicate component identity.");
for (const entry of sbom.dependencies) {
  if (
    !references.has(entry.ref) ||
    entry.dependsOn.some((id) => !references.has(id))
  )
    throw new Error("Incomplete dependency graph.");
}
const model = JSON.parse(await read("models.json"));
if (hash(await read(`app/resources/models/${model.file}`)) !== model.sha256)
  throw new Error("Staged model bytes differ from the pinned inventory.");
const modelComponent = sbom.components.find(
  (item) => item["bom-ref"] === model.id,
);
if (modelComponent?.hashes?.[0]?.content !== model.sha256)
  throw new Error("Model inventory differs.");
assertInventoryLicenses(sbom);
for (const ref of Object.values(nativeReferences)) {
  const component = sbom.components.find((entry) => entry["bom-ref"] === ref);
  if (
    !component ||
    !component.properties?.some((entry) =>
      entry.name === "lockedin:source-tree-sha256" && /^[a-f0-9]{64}$/.test(entry.value))
  )
    throw new Error("Missing nested native source provenance.");
}
const binary = await read(
  `target/release/lockedin-flow-desktop${process.platform === "win32" ? ".exe" : ""}`,
);
const findings = privatePathFindings(binary, [
  { scope: "home", prefix: os.homedir() + path.sep },
  { scope: "checkout", prefix: path.dirname(root) + path.sep },
]);
if (findings.length) {
  process.stderr.write(`Private build-path classifications (contents withheld): ${JSON.stringify(findings)}\n`);
  throw new Error("Artifact contains a private build path.");
}
if (binary.length < 1024) throw new Error("Application binary is incomplete.");
process.stdout.write(
  `Verified clean ${host} artifact, inventory graph, model identity, and build-path privacy.\n`,
);
