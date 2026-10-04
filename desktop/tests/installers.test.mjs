import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const environment = { ...process.env };
delete environment.GITHUB_ACTIONS;
delete environment.RUNNER_OS;
delete environment.RUNNER_ENVIRONMENT;

test("destructive Linux package checks refuse a normal local environment", () => {
  const result = spawnSync("bash", ["scripts/test-linux-package.sh"], {
    cwd: root, encoding: "utf8", env: environment,
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /restricted to an ephemeral Linux CI runner/);
});

test("destructive Windows package checks refuse a normal local environment", {
  skip: process.platform !== "win32",
}, () => {
  const result = spawnSync("powershell.exe", ["-NoProfile", "-NonInteractive", "-File", "scripts/test-windows-installers.ps1"], {
    cwd: root, encoding: "utf8", env: environment,
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /restricted to an ephemeral Windows CI runner/);
});

test("installer workflow exercises both Windows formats and Linux removal", () => {
  const windows = readFileSync(path.join(root, "scripts/test-windows-installers.ps1"), "utf8");
  const linux = readFileSync(path.join(root, "scripts/test-linux-package.sh"), "utf8");
  const workflow = readFileSync(path.join(root, "../.github/workflows/desktop.yml"), "utf8");
  for (const name of ["test-windows-installers.ps1", "test-linux-package.sh"])
    assert.ok(workflow.includes(name));
  assert.match(windows, /\/i .*\/qn \/norestart INSTALLDIR=/);
  assert.match(windows, /\/x .*\/qn \/norestart/);
  assert.match(windows, /Assert-Payload \$msiDirectory/);
  assert.match(windows, /Assert-Removed \$msiDirectory/);
  assert.match(windows, /Assert-Removed \$nsisDirectory/);
  assert.match(linux, /sudo dpkg --install/);
  assert.match(linux, /sudo dpkg --remove/);
  assert.match(linux, /cmp --/);
});

test("MSI preserves an explicit destination across the upstream registry search", () => {
  const config = JSON.parse(readFileSync(path.join(root, "app/tauri.conf.json"), "utf8"));
  const wix = config.bundle.windows.wix;
  assert.deepEqual(wix.fragmentPaths, ["windows/install-directory.wxs"]);
  assert.deepEqual(wix.componentGroupRefs, ["LockedInInstallDirectoryPolicy"]);
  const schema = JSON.parse(readFileSync(path.join(root, "node_modules/@tauri-apps/cli/config.schema.json"), "utf8"));
  for (const key of Object.keys(wix)) assert.ok(Object.hasOwn(schema.definitions.WixConfig.properties, key), key);
  const fragment = readFileSync(path.join(root, "app/windows/install-directory.wxs"), "utf8");
  assert.match(fragment, /<ComponentGroup Id="LockedInInstallDirectoryPolicy"\s*\/>/);
  assert.match(fragment, /<Property Id="FLOW_REQUESTED_INSTALLDIR" Secure="yes"/);
  assert.match(fragment, /Action="CaptureLockedInInstallDir"\s+Value="\[INSTALLDIR\]" Before="AppSearch" Sequence="both"/);
  assert.match(fragment, /Action="RestoreLockedInInstallDir"\s+Value="\[FLOW_REQUESTED_INSTALLDIR\]" After="AppSearch" Sequence="both"/);
  assert.equal((fragment.match(/AND NOT Installed AND NOT REMOVE/g) ?? []).length, 2);
  assert.doesNotMatch(fragment, /ExeCommand|Script=|BinaryKey=|DllEntry=|RegistryValue/);
  const windows = readFileSync(path.join(root, "scripts/test-windows-installers.ps1"), "utf8");
  assert.match(windows, /Assert-Payload \$msiDirectory\s+Assert-Removed \$nsisDirectory/);
  assert.doesNotMatch(windows, /Remove-ItemProperty|Remove-Item.*HKCU/);
});
