#!/usr/bin/env node
import path from "node:path";
import { fileURLToPath } from "node:url";
import { MacReleaseError, packageMacRelease, parseOptions } from "./lib/mac-release.mjs";

const args = process.argv.slice(2);
if (args.length === 1 && args[0] === "--help") {
  console.log(`Usage: node scripts/package-mac-release.mjs \\
  --commit <approved-main-sha> --identity <certificate-sha1> --team <apple-team-id> \\
  --notary-profile <keychain-profile> --output <new-absolute-directory> [--check-only]

Builds, signs, and notarizes an isolated Mac release candidate. Never installs,
publishes, grants permissions, or changes the source release stage. Signing and
notarization use existing Keychain credentials; never pass passwords or keys.
Run only after source review. Full packaging contacts Apple; --check-only contacts
GitHub and reads the local toolchain and identity but does not sign or upload.
Device acceptance and publication approval remain separate gates.`);
} else {
  try {
    await packageMacRelease(parseOptions(args), {
      root: path.resolve(path.dirname(fileURLToPath(import.meta.url)), ".."),
    });
  } catch (error) {
    // Only controlled messages are printable: parsers/filesystem errors may
    // contain paths or raw external tool output.
    const safe = error instanceof MacReleaseError;
    console.error(safe ? error.message : "Mac release packaging stopped. Inspect the failed step privately; nothing was published.");
    process.exitCode = 1;
  }
}
