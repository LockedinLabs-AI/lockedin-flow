import path from "node:path";

const fail = () => { throw new Error("Workspace notice ownership needs review; content withheld."); };

// Restrict root attribution to these two owned workspace members. Cargo metadata
// supplies the resolved license; the manifest confirms actual inheritance.
export async function workspaceNoticeReferences(metadata, root, readManifest) {
  if (metadata.workspace_root !== root || !Array.isArray(metadata.workspace_members)
      || !Array.isArray(metadata.packages)) fail();
  const refs = [];
  for (const [name, directory] of [["lockedin-flow-core", "core"], ["lockedin-flow-engine", "engine"]]) {
    const matches = metadata.packages.filter((pkg) => pkg.name === name);
    if (matches.length !== 1) fail();
    const pkg = matches[0];
    const expected = path.join(root, directory, "Cargo.toml");
    if (pkg.source !== null || pkg.license !== "MIT" || pkg.license_file != null
        || pkg.manifest_path !== expected || typeof pkg.id !== "string"
        || metadata.workspace_members.filter((id) => id === pkg.id).length !== 1
        || typeof pkg.version !== "string" || !/^\d+\.\d+\.\d+(?:-[a-z0-9.-]+)?$/.test(pkg.version)) fail();
    const bytes = await readManifest(expected);
    if (!Buffer.isBuffer(bytes) || bytes.length > 16384 || bytes.includes(0)) fail();
    // Deliberately accept only the existing simple package-header layout. A
    // multiline string or a more complex TOML spelling needs explicit review,
    // rather than interpreting a license-looking line inside unrelated text.
    const header = bytes.toString("utf8").split(/\r?\n\s*\[/, 1)[0];
    if (!header.startsWith("[package]\n") && !header.startsWith("[package]\r\n")) fail();
    if (header.includes('"""') || header.includes("'''")) fail();
    const licenseLines = header.split(/\r?\n/).filter((line) => /^\s*license(?:\s|\.|=)/.test(line));
    if (licenseLines.length !== 1 || !/^license\.workspace\s*=\s*true\s*$/.test(licenseLines[0])) fail();
    const names = header.split(/\r?\n/).filter((line) => /^\s*name\s*=/.test(line));
    if (names.length !== 1 || names[0] !== `name = "${name}"`) fail();
    refs.push(`pkg:cargo/${name}@${pkg.version}`);
  }
  return refs;
}
