#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: root,
    encoding: "utf8",
    stdio: options.capture ? "pipe" : "inherit",
    shell: false,
  });
  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    if (options.capture && result.stderr) process.stderr.write(result.stderr);
    process.exit(result.status ?? 1);
  }
  return options.capture ? result.stdout.trim() : "";
}

function requireSupportedMac() {
  if (process.platform !== "darwin" || process.arch !== "arm64") {
    console.error("LockedIn Flow currently requires an Apple-silicon Mac.");
    process.exit(1);
  }
}

function versionAtLeast(actual, requiredMajor) {
  const major = Number.parseInt(actual.split(".")[0], 10);
  return Number.isInteger(major) && major >= requiredMajor;
}

function doctor() {
  requireSupportedMac();
  const macOS = run("/usr/bin/sw_vers", ["-productVersion"], { capture: true });
  if (!versionAtLeast(macOS, 15)) {
    console.error(`macOS 15 or later is required; found ${macOS}.`);
    process.exit(1);
  }

  const toolchain = run(path.join(root, "scripts", "verify-build-toolchain.sh"), [], {
    capture: true,
  });
  const developerDirectory = run("/usr/bin/xcode-select", ["-p"], { capture: true });
  console.log(`OK  macOS ${macOS} (${process.arch})`);
  console.log(`OK  ${toolchain}`);
  console.log(`OK  developer tools: ${developerDirectory}`);

  const app = path.join(homedir(), "Applications", "LockedIn Flow.app");
  console.log(`${existsSync(app) ? "OK " : "-- "} local app: ${app}`);
  const models = path.join(
    homedir(),
    "Library",
    "Application Support",
    "LockedInFlowCommunity",
    "FluidAudio",
    "Models",
  );
  console.log(`${existsSync(models) ? "OK " : "-- "} model root: ${models}`);
  console.log("Doctor checks only local prerequisites; it sends no telemetry.");
}

function help() {
  console.log(`LockedIn Flow developer utility

Usage: lockedin-flow <command> [options]

Commands:
  doctor               Check the exact local evaluation prerequisites
  build                Build with the locked Swift dependency graph
  test-swift           Run the Swift test suite with locked dependencies
  package              Create an ad-hoc-signed local evaluation app
  package-pkg          Create an unsigned, no-script evaluation PKG
  install              Build and install to ~/Applications
  provision-models     Explicitly download and verify local speech models
  setup                Install the app and provision the default model set

Setup options:
  --replace            Preserve and replace an existing evaluation app
  --repair             Replace an invalid model after staging a verified copy
  --all                Also provision the optional English Precision model
  --launch             Open the app after models have been provisioned

The npm tooling has no install lifecycle scripts and is not used by the app at
runtime. Managed deployment should use a signed, notarized PKG through MDM.`);
}

function setup(args) {
  const installerArgs = [];
  const modelArgs = [];
  let launch = false;
  for (const arg of args) {
    switch (arg) {
      case "--replace":
        installerArgs.push(arg);
        break;
      case "--repair":
      case "--all":
        modelArgs.push(arg);
        break;
      case "--launch":
        launch = true;
        break;
      case "--help":
      case "-h":
        help();
        return;
      default:
        console.error(`Unknown setup option: ${arg}`);
        process.exit(64);
    }
  }

  doctor();
  console.log("\nInstalling the local evaluation app…");
  run(path.join(root, "scripts", "install-app.sh"), installerArgs);
  console.log("\nProvisioning the default local models (~484 MB)…");
  run(process.execPath, [path.join(root, "scripts", "provision-models.mjs"), ...modelArgs]);

  const app = path.join(homedir(), "Applications", "LockedIn Flow.app");
  console.log(
    "\nSetup complete. Models are provisioned; apply your egress policy and run acceptance."
  );
  if (launch) {
    run("/usr/bin/open", [app]);
  } else {
    console.log(`Open the app when ready: ${app}`);
  }
}

const [command = "help", ...args] = process.argv.slice(2);

switch (command) {
  case "help":
  case "--help":
  case "-h":
    help();
    break;
  case "doctor":
    doctor();
    break;
  case "build":
    requireSupportedMac();
    run("/usr/bin/swift", ["build", "--force-resolved-versions"]);
    break;
  case "test-swift":
    requireSupportedMac();
    run("/usr/bin/swift", ["test", "--force-resolved-versions"]);
    break;
  case "package":
    requireSupportedMac();
    run(path.join(root, "scripts", "package-app.sh"), args);
    break;
  case "package-pkg":
    requireSupportedMac();
    run(path.join(root, "scripts", "package-evaluation-pkg.sh"), args);
    break;
  case "install":
    requireSupportedMac();
    run(path.join(root, "scripts", "install-app.sh"), args);
    break;
  case "provision-models":
    requireSupportedMac();
    run(process.execPath, [path.join(root, "scripts", "provision-models.mjs"), ...args]);
    break;
  case "setup":
    setup(args);
    break;
  default:
    console.error(`Unknown command: ${command}\n`);
    help();
    process.exit(64);
}
