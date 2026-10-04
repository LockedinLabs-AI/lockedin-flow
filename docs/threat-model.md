# Threat model

## Scope

This model covers the macOS dictation path, local content storage, validated
current-target text insertion, and model acquisition. It assumes the macOS user
session and operating-system security boundary are trustworthy.

## Assets

- microphone audio and transcript content;
- destination-field identity and delivery integrity;
- local history, recovery text, vocabulary, and snippets;
- release-artifact and model integrity;
- release and model trust roots; and
- the user's existing clipboard contents.

## Threats and controls

| Threat | Implemented control | Residual risk |
| --- | --- | --- |
| Unexpected control permission | in-app transcription is the default and needs no Accessibility access; automatic typing requires an explicit explanation and opt-in; recording never raises an Accessibility prompt; legacy and unbundled identities are rejected by the request policy | macOS Accessibility remains a broad grant, not typing-only; disabling the feature does not revoke an existing OS permission |
| Audio or transcript exfiltration | no remote inference adapter; no telemetry SDK; content prohibited in logs | a compromised host or modified build is outside this guarantee |
| Insertion into the wrong editor | destination application and activation generation freeze when recording ends; the current field is resolved and checked only at delivery; focus, secure-state, semantic-path, range, and receipt checks surround the single write | changing fields within the same application before delivery intentionally changes the current destination; hostile or defective Accessibility implementations can provide misleading metadata |
| Insertion into a password field | secure-role and subrole refusal; unknown security state fails closed | an application that falsely reports a normal field remains a platform risk |
| Duplicate insertion after an uncertain event | one-event transaction; ambiguous outcomes are not retried | the user may need to inspect the target and manually recover text |
| Clipboard disclosure | direct AX insertion preferred; device-local pasteboard preparation prevents eligibility for Apple's cross-device clipboard; verified save/stage/restore ownership protocol; failed LockedIn Flow insertions never auto-copy; persistent auto-copy is explicit and off by default | other local clipboard readers can still access or transmit the text; managed deployments must control clipboard utilities and destination apps |
| Transcript exposure at rest | AES-GCM content stores with a device-bound Keychain key | root, malicious MDM, or an unlocked session can cross the platform boundary |
| Transcript leakage through logs | typed logging interface accepts fixed messages and numeric/boolean diagnostics; error descriptions, domains, user information, and app identities are excluded | dependencies and OS diagnostics have their own logging implementations and require separate review; developer transcription tools must use synthetic inputs |
| Malicious update | LockedIn Flow builds contain no automatic updater; source releases are explicit administrator or user actions | users must verify the source revision and signature/provenance of any downloaded artifact |
| Model substitution | application is read-only toward model roots; immutable repository revisions; exact path, byte-count, and SHA-256 manifest; explicit provisioner stages atomically; FluidAudio network fallback forced offline | a malicious artifact accepted during the explicit review that updates the manifest remains a supply-chain risk |
| Unexpected runtime network dependency | no app-owned acquisition flow, updater, telemetry, or listener; linked dependency model hub forced offline; managed deployments can deny application egress | the dependency retains general-purpose networking code, the app is not sandboxed, and OS or endpoint policy remains the enforceable network boundary |
| LockedIn Flow build collision | separate bundle ID, preferences, support directory, Keychain service, and updater policy | a deliberately modified build can remove these boundaries |
| Overbroad local process access | documented non-sandboxed runtime; no arbitrary-file discovery in the product path | the process has the signed-in user's ordinary filesystem access, and Accessibility permission is powerful |
| Dependency or workflow compromise | resolved Swift versions, immutable Action SHAs, SBOM, CI and CodeQL | an accepted malicious upstream release or compromised build host remains possible |
| Prompt manipulation | optional cleanup is on-device, form-limited, has no tools, and falls back to deterministic rules | model output can still be wrong and must remain user-reviewable |

## Out of scope

- a fully compromised Mac, administrator, root process, or device-management
  authority;
- content intentionally copied into a cloud destination application after local
  transcription;
- organization-specific compliance certification;
- unsupported operating systems or unsigned modified distributions; and
- availability of Hugging Face or GitHub.

## Security invariants

1. No microphone audio or transcript content is sent to a remote model.
2. Secure or unverifiable fields do not receive text.
3. A delivery is never called successful without exact post-event evidence.
4. An ambiguous delivery is never blindly repeated.
5. Release binaries do not contain diagnostic insertion commands.
6. Secrets, customer data, and protected health information are not accepted in
   public issues, tests, or fixtures.
7. The application never downloads, repairs, or mutates a speech-model cache.
8. In-app transcription never resolves an external text target, interprets
   cross-app editing commands, or automatically writes the clipboard. The
   delivery mode is frozen at capture start and preserved for retry.
