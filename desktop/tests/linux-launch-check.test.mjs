import assert from "node:assert/strict";
import test from "node:test";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { waitForStableWindow } from "../scripts/linux-launch-check.mjs";

function fixture(visible) {
  let time = 0;
  const child = { exitCode: null, signalCode: null };
  return { child, now: () => time, sleep: async (ms) => { time += ms; },
    timeoutMs: 2000, stableMs: 500, findWindow: async () => visible(time, child) };
}

test("accepts only a continuously visible live application", async () => {
  const options = fixture((time) => time >= 500);
  await waitForStableWindow(options);
  assert.equal(options.now(), 1000);
});
test("resets stability when the window disappears", async () => {
  const options = fixture((time) => time === 0 || time >= 750);
  await waitForStableWindow(options);
  assert.equal(options.now(), 1250);
});
test("missing and flickering windows time out", async () => {
  for (const visible of [() => false, (time) => time % 500 === 0]) {
    await assert.rejects(waitForStableWindow(fixture(visible)), /did not remain visible/);
  }
});
test("early normal exit, crash, and signal are failures", async () => {
  for (const status of [{ exitCode: 0 }, { exitCode: 1 }, { signalCode: "SIGSEGV" }]) {
    const options = fixture((time, child) => { if (time >= 250) Object.assign(child, status); return true; });
    await assert.rejects(waitForStableWindow(options), /exited during launch/);
  }
});
test("window probe failures fail closed", async () => {
  await assert.rejects(waitForStableWindow(fixture(() => { throw new Error("synthetic probe failure"); })), /probe failure/);
});
test("an exit during the last window probe cannot be accepted", async () => {
  const options = fixture((time, child) => { if (time === 500) child.exitCode = 0; return true; });
  await assert.rejects(waitForStableWindow(options), /exited during launch/);
});
test("installed launch is isolated, unprivileged, and precedes package removal", () => {
  const script = readFileSync(new URL("../scripts/test-linux-package.sh", import.meta.url), "utf8");
  const launch = script.indexOf("sudo unshare --net -- runuser");
  assert.ok(launch > script.indexOf("Installed application integrity check failed"));
  assert.ok(launch < script.lastIndexOf('sudo dpkg --remove "$package_name"'));
  assert.match(script, /dbus-run-session -- xvfb-run -a node scripts\/test-linux-launch\.mjs/);
  const checker = readFileSync(new URL("../scripts/test-linux-launch.mjs", import.meta.url), "utf8");
  assert.match(checker, /"search", "--all", "--onlyvisible", "--pid"/);
  assert.doesNotMatch(checker, /WEBKIT_DISABLE_SANDBOX|--no-sandbox/);
});
test("native launcher refuses ordinary developer machines without starting an app", () => {
  const result = spawnSync(process.execPath, [fileURLToPath(new URL("../scripts/test-linux-launch.mjs", import.meta.url))], {
    env: { ...process.env, GITHUB_ACTIONS: "false" }, encoding: "utf8",
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /Installed Linux launch check failed/);
  assert.equal(result.stdout, "");
});
