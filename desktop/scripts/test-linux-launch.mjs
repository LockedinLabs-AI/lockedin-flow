#!/usr/bin/env node
import { spawn, spawnSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { setTimeout as sleep } from "node:timers/promises";
import { performance } from "node:perf_hooks";
import { waitForStableWindow } from "./linux-launch-check.mjs";

async function main() {
  if (process.platform !== "linux" || process.argv.length !== 2
      || process.env.GITHUB_ACTIONS !== "true" || process.env.RUNNER_OS !== "Linux"
      || process.env.RUNNER_ENVIRONMENT !== "github-hosted" || process.getuid() === 0) throw new Error();
  // A fresh network namespace exposes loopback only. No firewall relaxation or
  // application/webview sandbox override is permitted for this test.
  // /proc/self/net reflects this process's namespace; an inherited sysfs mount
  // can still describe the host namespace.
  const interfaces = (await readFile("/proc/self/net/dev", "utf8")).trim().split("\n").slice(2)
    .map((line) => line.split(":")[0].trim());
  if (interfaces.length !== 1 || interfaces[0] !== "lo") throw new Error();
  const child = spawn("/usr/bin/lockedin-flow-desktop", [], {
    detached: true, stdio: "ignore", env: { ...process.env, GDK_BACKEND: "x11" },
  });
  let launchError = false;
  child.on("error", () => { launchError = true; });
  try {
    await waitForStableWindow({
      child, now: () => performance.now(), sleep,
      findWindow: async () => {
        if (launchError || !child.pid) throw new Error();
        const result = spawnSync("/usr/bin/xdotool", ["search", "--all", "--onlyvisible", "--pid", String(child.pid), "--name", "^LockedIn Flow$"], {
          encoding: "utf8", timeout: 2000, maxBuffer: 4096,
        });
        if (result.error || result.signal || ![0, 1].includes(result.status)) throw new Error();
        return result.status === 0 && /^\d+(\n\d+)*\n?$/.test(result.stdout);
      },
    });
  } finally {
    // Terminate only this test's new process group, including webview helpers.
    if (child.pid) {
      const signalGroup = (signal) => {
        try { process.kill(-child.pid, signal); } catch (error) { if (error.code !== "ESRCH") throw error; }
      };
      signalGroup("SIGTERM");
      await sleep(500);
      signalGroup("SIGKILL");
    }
  }
  console.log("Installed DEB window/process launch passed with no external network interface; audio and rendered-content acceptance remain separate.");
}

main().catch(() => {
  console.error("Installed Linux launch check failed; no application output or user data retained.");
  process.exitCode = 1;
});
