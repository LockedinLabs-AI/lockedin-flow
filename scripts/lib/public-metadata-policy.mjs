import { scanText } from "./public-content-policy.mjs";

// PR text is already public when GitHub sends the event. This is detection,
// not redaction or permission to put sensitive material in a pull request.
export function scanPullRequest(event) {
  const pr = event?.pull_request;
  if (!pr || typeof pr.title !== "string" || !pr.title.trim()
      || !(pr.body === null || typeof pr.body === "string")) {
    throw new Error("Invalid pull request metadata.");
  }
  const findings = [];
  for (const field of ["title", "body"]) {
    const text = pr[field] ?? "";
    const rules = scanText(text);
    // A narrow credential-pattern check complements repository secret scanning.
    // It deliberately does not contact a provider to validate a suspected secret.
    if (/-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----/.test(text)
        || /\bgh[pousr]_[A-Za-z0-9]{36,}\b/.test(text)
        || /\bgithub_pat_[A-Za-z0-9_]{20,}\b/.test(text)
        || /\bAKIA[A-Z0-9]{16}\b/.test(text)) {
      rules.push("credential-pattern");
    }
    for (const rule of new Set(rules)) findings.push({ field, rule });
  }
  return findings;
}
