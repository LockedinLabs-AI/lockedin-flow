import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { isDeepStrictEqual, promisify } from "node:util";
import {
  copyFileSync, existsSync, lstatSync, mkdirSync, readFileSync, readdirSync,
  realpathSync, statSync, symlinkSync, writeFileSync,
} from "node:fs";
import path from "node:path";

const execute = promisify(execFile);
const upstream = "https://github.com/LockedinLabs-AI/LockedIn-Flow.git";
const uuid = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
export class MacReleaseError extends Error {}
const fail = (message) => { throw new MacReleaseError(message); };
const hash = (file) => createHash("sha256").update(readFileSync(file)).digest("hex");

export function parseOptions(args) {
  const options = {};
  const names = new Set(["commit", "identity", "team", "notary-profile", "output"]);
  for (let index = 0; index < args.length; index++) {
    const name = args[index].replace(/^--/, "");
    if (args[index] === "--check-only" && !options.checkOnly) {
      options.checkOnly = true;
    } else if (args[index].startsWith("--") && names.has(name) && !options[name]) {
      const value = args[++index];
      if (!value || value.startsWith("--")) fail("Every release option needs a value.");
      options[name] = value;
    } else {
      fail("Unknown or duplicate release option.");
    }
  }
  if (!/^[0-9a-f]{40}$/.test(options.commit ?? "")) fail("A full approved source commit is required.");
  if (!/^[0-9A-Fa-f]{40}$/.test(options.identity ?? "")) fail("Use the signing certificate fingerprint, not a name or password.");
  if (!/^[A-Z0-9]{10}$/.test(options.team ?? "")) fail("A ten-character Apple team identifier is required.");
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$/.test(options["notary-profile"] ?? "")) fail("A Keychain notary profile name is required; never supply a password.");
  if (!options.output || !path.isAbsolute(options.output) || /[\r\n\0]/.test(options.output)) fail("Use an absolute, new output directory.");
  options.output = path.resolve(options.output);
  return options;
}

// The current Swift bundle has one statically linked executable. Fail closed if
// a future dependency adds nested code: it needs its own reviewed signing plan.
export function verifyBundleLayout(app) {
  const appInfo = lstatSync(app);
  if (!appInfo.isDirectory() || appInfo.isSymbolicLink()) fail("The app must be a real directory, not a link.");
  const executable = path.join(app, "Contents/MacOS/LockedInFlow");
  const macho = new Set(["feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca"]);
  let executableFound = false;
  function visit(directory) {
    for (const name of readdirSync(directory)) {
      const entry = path.join(directory, name);
      const info = lstatSync(entry);
      if (info.isSymbolicLink() || (!info.isFile() && !info.isDirectory())) fail("Unexpected bundle link or special file.");
      if (info.isDirectory()) {
        if (/\.(?:app|framework|xpc|appex|bundle)$/.test(name)) fail("Nested code needs an explicit signing plan.");
        visit(entry);
      } else {
        const isMachO = macho.has(readFileSync(entry).subarray(0, 4).toString("hex"));
        if (entry === executable) {
          if (!isMachO) fail("The app executable is not Mach-O.");
          executableFound = true;
        } else if (isMachO || (info.mode & 0o111) !== 0) {
          fail("Unexpected executable code in the app bundle.");
        }
      }
    }
  }
  visit(app);
  if (!executableFound) fail("The app executable is missing.");
}

export function acceptedNotarization(result, log) {
  if (result.status !== "Accepted" || !uuid.test(result.id ?? "")) fail("Apple has not accepted this notarization submission.");
  if (log.jobId?.toLowerCase() !== result.id.toLowerCase() || log.status !== "Accepted"
      || (log.issues !== null && (!Array.isArray(log.issues) || log.issues.length !== 0))) {
    fail("The notarization log is missing, mismatched, or contains issues requiring review.");
  }
  return { id: result.id, status: "Accepted", issues: 0 };
}

export async function packageMacRelease(options, { root, platform = process.platform, run, progress = console.log } = {}) {
  if (platform !== "darwin") fail("Mac release packaging requires macOS.");
  root = realpathSync(root);
  const command = async (stage, program, args, extra = {}) => {
    try {
      const result = await (run ?? execute)(program, args, {
        cwd: root, encoding: "utf8", maxBuffer: 16 * 1024 * 1024,
        timeout: 30 * 60 * 1000, ...extra,
      });
      return `${result.stdout ?? ""}${result.stderr ?? ""}`.trim();
    } catch {
      // Tool errors can contain certificate names, credentials, or host paths.
      fail(`${stage} failed. No release was published; inspect this step privately.`);
    }
  };
  const git = (...args) => command("Source verification", "git", args);
  const checkSource = async () => {
    if (await git("rev-parse", "HEAD") !== options.commit) fail("HEAD is not the approved source commit.");
    if (await git("status", "--porcelain", "--untracked-files=all")) fail("Release packaging requires a clean source tree.");
  };
  await checkSource();
  const remote = await git("ls-remote", "--exit-code", upstream, "refs/heads/main");
  if (remote !== `${options.commit}\trefs/heads/main`) fail("The approved commit is not the current protected corporate main branch.");
  const parent = realpathSync(path.dirname(options.output));
  const output = path.join(parent, path.basename(options.output));
  if (existsSync(output)) fail("Output already exists; use a new directory. Nothing was overwritten.");
  if (output === root || output.startsWith(`${root}${path.sep}`)) fail("Keep signed artifacts outside the source checkout.");
  await command("Toolchain verification", path.join(root, "scripts/verify-build-toolchain.sh"), []);
  const identities = await command("Signing identity verification", "/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"]);
  const identity = options.identity.toUpperCase();
  const matchingIdentity = identities.split("\n").some((line) =>
    new RegExp(`^\\s*\\d+\\) ${identity} "Developer ID Application: [^\\r\\n]+ \\(${options.team}\\)"$`, "i").test(line));
  if (!matchingIdentity) fail("The requested Developer ID Application identity and team are not available.");
  if (options.checkOnly) {
    progress("Source, toolchain, and signing-identity preflight passed. No build, signature, or upload performed.");
    return { checkOnly: true };
  }

  // Exclusive creation: no cleanup or recursive deletion of caller-owned paths.
  mkdirSync(output, { mode: 0o700 });
  const staging = path.join(output, "staging");
  mkdirSync(staging, { mode: 0o700 });
  progress("Building the reviewed Mac source into isolated release staging.");
  await command("App packaging", path.join(root, "scripts/package-app.sh"), [], {
    env: { ...process.env, LOCKEDIN_PACKAGE_OUTPUT_DIR: staging },
  });
  await checkSource();
  const app = path.join(staging, "LockedIn Flow.app");
  verifyBundleLayout(app);
  const resources = path.join(app, "Contents/Resources");
  const plist = async (file) => JSON.parse(await command("Property-list verification", "/usr/bin/plutil", ["-convert", "json", "-o", "-", file]));
  const info = await plist(path.join(app, "Contents/Info.plist"));
  const sourceInfo = await plist(path.join(root, "Info.plist"));
  if (!isDeepStrictEqual(info, sourceInfo)) fail("Packaged app metadata differs from the reviewed source.");
  if (info.CFBundleName !== "LockedIn Flow" || info.CFBundleDisplayName !== "LockedIn Flow"
      || info.CFBundleExecutable !== "LockedInFlow" || info.CFBundleIdentifier !== "ai.lockedin.flow.community"
      || !/^\d+\.\d+\.\d+$/.test(info.CFBundleShortVersionString) || !/^\d+$/.test(info.CFBundleVersion)) {
    fail("Unexpected app identity or version.");
  }
  const entitlements = path.join(root, "entitlements.plist");
  const permission = await plist(entitlements);
  if (Object.keys(permission).length !== 1 || permission["com.apple.security.device.audio-input"] !== true) fail("Release entitlements exceed the reviewed microphone-only policy.");
  const sbom = path.join(resources, "SBOM.cdx.json");
  const provenance = readFileSync(path.join(resources, "BUILD-PROVENANCE.txt"), "utf8").split("\n");
  for (const expected of [
    `source-revision: ${options.commit}`, "source-state: clean",
    `package-resolved-sha256: ${hash(path.join(root, "Package.resolved"))}`,
    `sbom-sha256: ${hash(sbom)}`,
    `model-artifacts-sha256: ${hash(path.join(root, "security/model-artifacts.tsv"))}`,
    `model-sources-sha256: ${hash(path.join(root, "security/model-sources.tsv"))}`,
  ]) {
    if (provenance.filter((line) => line === expected).length !== 1) fail("Build provenance does not match the approved source and SBOM.");
  }
  await command("SBOM verification", path.join(root, "scripts/validate-sbom.sh"), [sbom]);
  const executable = path.join(app, "Contents/MacOS/LockedInFlow");
  await command("Production binary verification", path.join(root, "scripts/verify-production-binary.sh"), [executable]);
  if (await command("Architecture verification", "/usr/bin/lipo", ["-archs", executable]) !== "arm64") fail("The Mac release must contain the supported arm64 executable.");
  const requirement = `anchor apple generic and certificate leaf[subject.OU] = "${options.team}" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists`;
  const verifySignature = async (file) => {
    await command("Signature verification", "/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", requirement, file]);
  };
  progress("Signing the isolated app; credentials remain in Keychain.");
  await command("App signing", "/usr/bin/codesign", ["--force", "--timestamp", "--options", "runtime", "--sign", identity, "--entitlements", entitlements, app]);
  await verifySignature(app);
  const signature = await command("App signature metadata", "/usr/bin/codesign", ["--display", "--verbose=4", app]);
  if (!/flags=.*\bruntime\b/.test(signature) || !/^Timestamp=.+$/m.test(signature)
      || !signature.split("\n").includes(`TeamIdentifier=${options.team}`)) fail("The app is missing its hardened runtime, timestamp, or expected team identity.");

  const notarize = async (file) => {
    const result = JSON.parse(await command("Notarization submission", "/usr/bin/xcrun", [
      "notarytool", "submit", file, "--keychain-profile", options["notary-profile"],
      "--wait", "--timeout", "20m", "--output-format", "json",
    ]));
    if (result.status !== "Accepted" || !uuid.test(result.id ?? "")) fail("Apple has not accepted this notarization submission.");
    const log = JSON.parse(await command("Notarization log verification", "/usr/bin/xcrun", ["notarytool", "log", result.id, "--keychain-profile", options["notary-profile"]]));
    return acceptedNotarization(result, log);
  };
  const staple = async (file) => {
    await command("Ticket stapling", "/usr/bin/xcrun", ["stapler", "staple", file]);
    await command("Stapled ticket verification", "/usr/bin/xcrun", ["stapler", "validate", file]);
    await verifySignature(file);
  };
  const zip = path.join(staging, "notarization-upload.zip");
  await command("Notarization archive", "/usr/bin/ditto", ["-c", "-k", "--keepParent", "--noextattr", "--norsrc", app, zip]);
  progress("Submitting the app to Apple and verifying its notarization log and ticket.");
  const appNotarization = await notarize(zip);
  await staple(app);
  await command("App Gatekeeper assessment", "/usr/sbin/spctl", ["--assess", "--type", "execute", "--verbose=2", app]);

  const imageRoot = path.join(staging, "image");
  mkdirSync(imageRoot);
  await command("Disk image staging", "/usr/bin/ditto", ["--noextattr", "--norsrc", app, path.join(imageRoot, "LockedIn Flow.app")]);
  // Recheck the copied ticket before making an immutable disk image.
  await command("Copied app ticket verification", "/usr/bin/xcrun", ["stapler", "validate", path.join(imageRoot, "LockedIn Flow.app")]);
  symlinkSync("/Applications", path.join(imageRoot, "Applications"));
  const filename = `LockedIn-Flow-${info.CFBundleShortVersionString}-${info.CFBundleVersion}-macos-arm64.dmg`;
  const dmg = path.join(output, filename);
  await command("Disk image creation", "/usr/bin/hdiutil", ["create", "-volname", "LockedIn Flow", "-srcfolder", imageRoot, "-format", "UDZO", dmg]);
  await command("Disk image integrity", "/usr/bin/hdiutil", ["verify", dmg]);
  await command("Disk image signing", "/usr/bin/codesign", ["--timestamp", "--sign", identity, dmg]);
  progress("Submitting the signed disk image to Apple and checking Gatekeeper.");
  const dmgNotarization = await notarize(dmg);
  await staple(dmg);
  await command("Disk image Gatekeeper assessment", "/usr/sbin/spctl", ["--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=2", dmg]);
  await checkSource();
  copyFileSync(sbom, path.join(output, "SBOM.cdx.json"));
  const manifest = {
    schemaVersion: 1, product: "LockedIn Flow", sourceRevision: options.commit,
    version: info.CFBundleShortVersionString, build: info.CFBundleVersion,
    releaseStage: info.LockedInReleaseStage,
    publicationStatus: "pending-installed-acceptance-and-approval",
    signing: { certificateSHA1: identity, teamIdentifier: options.team, hardenedRuntime: true },
    notarization: { app: appNotarization, diskImage: dmgNotarization },
    artifact: { filename, bytes: statSync(dmg).size, sha256: hash(dmg) },
    sbomSHA256: hash(sbom), executableSHA256: hash(executable),
    createdAt: new Date().toISOString(),
  };
  writeFileSync(path.join(output, "release-evidence.json"), `${JSON.stringify(manifest, null, 2)}\n`, { flag: "wx", mode: 0o600 });
  progress("Signed candidate prepared. Nothing installed or published. Device acceptance, attestation, and publication approval remain required.");
  return manifest;
}
