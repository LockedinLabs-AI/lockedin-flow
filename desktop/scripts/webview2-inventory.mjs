import { createHash } from "node:crypto";
import path from "node:path";

const filename = "MicrosoftEdgeWebView2RuntimeInstallerX64.exe";
const uuid = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
const sha256 = /^[0-9a-f]{64}$/;

function one(matches) {
  if (matches.length !== 1) throw new Error("Expected one explicit offline WebView2 build input per installer.");
  return matches[0][1];
}

// These are the two generated formats in the pinned Tauri 2.12.0 templates,
// not general NSIS/XML parsers. A template change requires review, not guessing.
export function webviewBuildInputs(nsis, wix) {
  if (nsis.length > 2 * 1024 * 1024 || wix.length > 2 * 1024 * 1024
      || /<!DOCTYPE|<!ENTITY/i.test(wix)) throw new Error("Unexpected installer source format.");
  const mode = one([...nsis.matchAll(/^!define INSTALLWEBVIEW2MODE "([^"\r\n]+)"\r?$/gm)]);
  if (mode !== "offlineInstaller") throw new Error("Windows packaging must use the offline runtime installer.");
  const nsisPath = one([...nsis.matchAll(/^!define WEBVIEW2INSTALLERPATH "([^"\r\n]+)"\r?$/gm)]);
  // Only the dollar escape emitted by the pinned template is accepted.
  if (/\$(?!\$)/.test(nsisPath.replaceAll("$$", ""))) throw new Error("Unexpected NSIS path expression.");
  const wixPath = one([...wix.matchAll(/<Binary\s+Id="MicrosoftEdgeWebView2RuntimeInstaller\.exe"\s+SourceFile="([^"\r\n]+)"\s*\/>/g)]);
  if (/&(?!(?:amp|quot|apos|lt|gt);)/.test(wixPath)) throw new Error("Unexpected XML path entity.");
  const entities = { amp: "&", quot: '"', apos: "'", lt: "<", gt: ">" };
  const paths = { nsis: nsisPath.replaceAll("$$", "$"), msi: wixPath.replace(/&(amp|quot|apos|lt|gt);/g, (_, name) => entities[name]) };
  for (const input of Object.values(paths)) {
    if (!/^[A-Za-z]:\\/.test(input) || /[\r\n\0"<>|]/.test(input)
        || input.slice(2).includes(":") || path.win32.normalize(input) !== input
        || path.win32.basename(input) !== filename
        || !uuid.test(path.win32.basename(path.win32.dirname(input)))) {
      throw new Error("Unexpected offline WebView2 payload location or architecture.");
    }
  }
  return paths;
}

export function verifiedWebviewInput(bytes, facts) {
  const hash = createHash("sha256").update(bytes).digest("hex");
  if (bytes.length < 1024 || bytes.subarray(0, 2).toString("ascii") !== "MZ"
      || facts.sha256 !== hash || facts.bytes !== bytes.length
      || facts.signatureStatus !== "Valid" || facts.publisher !== "Microsoft Corporation"
      || !/^[A-Fa-f0-9]{40}$/.test(facts.signerThumbprint ?? "")
      || !/^[A-Fa-f0-9]{40}$/.test(facts.timestampThumbprint ?? "")
      || !/^\d{1,5}(?:\.\d{1,5}){3}$/.test(facts.fileVersion ?? "")) {
    throw new Error("Offline WebView2 input failed hash, version, publisher, or timestamped-signature verification.");
  }
  // Return an allowlisted record: never forward raw probe data or local paths.
  return {
    filename, bytes: bytes.length, sha256: hash, installerFileVersion: facts.fileVersion,
    publisher: "Microsoft Corporation", signatureStatus: "Valid",
    signerThumbprint: facts.signerThumbprint.toLowerCase(),
    timestampThumbprint: facts.timestampThumbprint.toLowerCase(),
  };
}

export function packagingEvidence(revision, payloads, installers) {
  if (!/^[0-9a-f]{40}$/.test(revision) || payloads.length !== 2
      || payloads[0].sha256 !== payloads[1].sha256) throw new Error("Windows packages do not share one verified runtime input.");
  if (installers.length !== 2 || installers.some((entry) =>
    !/^LockedIn Flow_\d+\.\d+\.\d+(?:-[A-Za-z0-9.]+)?_x64(?:-setup\.exe|_[A-Za-z-]+\.msi)$/.test(entry.filename)
    || !sha256.test(entry.sha256) || !Number.isSafeInteger(entry.bytes) || entry.bytes < 1024)
    || installers.filter((entry) => entry.filename.endsWith(".msi")).length !== 1) {
    throw new Error("Unexpected final Windows installer identity.");
  }
  return {
    schemaVersion: 1, product: "LockedIn Flow", sourceRevision: revision,
    scope: "verified-installer-build-inputs",
    coverage: "WebView2 build input and final NSIS/MSI hashes; not extracted-payload proof or a complete platform SBOM",
    webview2: payloads[0], installers,
    redistributionReview: "required-before-production-release",
    distributionReference: "https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution",
  };
}
