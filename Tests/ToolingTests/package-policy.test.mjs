import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import test from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const packageJSON = JSON.parse(readFileSync(path.join(repositoryRoot, "package.json"), "utf8"));
const packageLock = JSON.parse(readFileSync(path.join(repositoryRoot, "package-lock.json"), "utf8"));

test("product display names use LockedIn Flow without an edition suffix", () => {
  const infoPlist = readFileSync(path.join(repositoryRoot, "Info.plist"), "utf8");
  for (const key of ["CFBundleName", "CFBundleDisplayName"]) {
    const value = infoPlist.match(new RegExp(`<key>${key}</key>\\s*<string>([^<]+)</string>`))?.[1];
    assert.equal(value, "LockedIn Flow");
  }
  for (const file of ["README.md", "Sources/LockedInFlowApp/MenuBarView.swift", "Sources/LockedInFlowApp/SettingsView.swift"]) {
    const text = readFileSync(path.join(repositoryRoot, file), "utf8");
    assert.doesNotMatch(text, /LockedIn Flow Community|Community edition|Text\("Community"\)/);
  }
  // Storage identity is compatibility state, not a product edition.
  const identity = readFileSync(path.join(repositoryRoot, "Sources/VoiceCore/AppPaths.swift"), "utf8");
  assert.match(identity, /supportDirectoryName = "LockedInFlowCommunity"/);
  assert.match(identity, /keychainService = "ai\.lockedin\.flow\.community"/);
});

test("release and repository metadata stay aligned", () => {
  const infoPlist = readFileSync(path.join(repositoryRoot, "Info.plist"), "utf8");
  const version = infoPlist.match(
    /<key>CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/,
  )?.[1];
  const provisioner = readFileSync(
    path.join(repositoryRoot, "scripts", "lib", "model-provisioning.mjs"),
    "utf8",
  );
  assert.equal(packageJSON.version, version);
  assert.equal(packageLock.version, version);
  assert.equal(packageLock.packages[""].version, version);
  assert.match(provisioner, new RegExp(`LockedIn-Flow-Provisioner/${version}`));
  assert.equal(packageJSON.repository.url, "git+https://github.com/LockedinLabs-AI/lockedin-flow.git");
  assert.equal(packageJSON.homepage, "https://github.com/LockedinLabs-AI/lockedin-flow#readme");
  assert.equal(packageJSON.license, "MIT");
  assert.equal(packageLock.packages[""].license, "MIT");
  for (const document of ["README.md", "docs/getting-started.md"]) {
    const text = readFileSync(path.join(repositoryRoot, document), "utf8");
    assert.match(text, /git clone https:\/\/github\.com\/LockedinLabs-AI\/lockedin-flow\.git\ncd lockedin-flow\n/);
  }
});

test("npm developer tooling is a single zero-dependency package with no lifecycle execution", () => {
  for (const field of ["dependencies", "devDependencies", "optionalDependencies", "peerDependencies"]) {
    assert.deepEqual(packageJSON[field] ?? {}, {});
  }
  assert.equal(packageJSON.workspaces, undefined);
  assert.equal(packageLock.lockfileVersion, 3);
  assert.deepEqual(Object.keys(packageLock.packages ?? {}), [""]);
  assert.equal(packageLock.packages[""].workspaces, undefined);
  for (const field of ["dependencies", "devDependencies", "optionalDependencies", "peerDependencies"]) {
    assert.deepEqual(packageLock.packages[""][field] ?? {}, {});
  }
  for (const hook of [
    "preinstall",
    "install",
    "postinstall",
    "prepublish",
    "preprepare",
    "prepare",
    "postprepare",
    "predependencies",
    "dependencies",
    "postdependencies",
  ]) {
    assert.equal(packageJSON.scripts?.[hook], undefined);
  }
  assert.equal(existsSync(path.join(repositoryRoot, "binding.gyp")), false);
  assert.equal(packageJSON.private, true);
  assert.deepEqual(packageJSON.os, ["darwin"]);
  assert.deepEqual(packageJSON.cpu, ["arm64"]);
});

test("local installer exposes help without building or changing the machine", () => {
  const script = readFileSync(
    path.join(repositoryRoot, "scripts", "install-app.sh"),
    "utf8",
  );
  assert.match(script, /--replace/);
  assert.match(script, /previous-\$TIMESTAMP/);
  assert.match(script, /codesign --verify --deep --strict/);
  assert.doesNotMatch(script, /sudo/);
});

test("the LockedIn Flow bundle includes the project MIT license", () => {
  const packagingScript = readFileSync(
    path.join(repositoryRoot, "scripts", "package-app.sh"),
    "utf8",
  );
  assert.match(packagingScript, /LockedIn-Flow-MIT\.txt/);
  assert.doesNotMatch(packagingScript, /LockedIn-Flow-Apache-2\.0\.txt/);
});

test("doctor enforces the same pinned toolchain used by packaging", () => {
  const utility = readFileSync(path.join(repositoryRoot, "scripts", "lockedin-flow.mjs"), "utf8");
  const readme = readFileSync(path.join(repositoryRoot, "README.md"), "utf8");

  assert.match(utility, /verify-build-toolchain\.sh/);
  assert.match(readme, /Xcode 26\.6 build\s+17F113/);
  assert.match(readme, /Apple Swift 6\.3\.3/);
  assert.match(readme, /macOS 26\.5 SDK/);
});

test("evaluation ZIP excludes host extended-attribute metadata", () => {
  const workflow = readFileSync(
    path.join(repositoryRoot, ".github", "workflows", "ci.yml"),
    "utf8",
  );

  assert.match(workflow, /ditto -c -k --keepParent --noextattr --norsrc/);
});

test("setup validates its options before running diagnostics or installation", () => {
  const command = path.join(repositoryRoot, "scripts", "lockedin-flow.mjs");
  const help = spawnSync(process.execPath, [command, "setup", "--help"], {
    encoding: "utf8",
  });
  assert.equal(help.status, 0, help.stderr);
  assert.match(help.stdout, /Setup options:/);
  assert.doesNotMatch(help.stdout, /Installing the local evaluation app/);

  const result = spawnSync(process.execPath, [command, "setup", "--not-an-option"], {
    encoding: "utf8",
  });
  assert.equal(result.status, 64);
  assert.match(result.stderr, /Unknown setup option/);
  assert.doesNotMatch(result.stdout, /Installing the local evaluation app/);
});
