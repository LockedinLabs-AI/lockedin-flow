# Security and data flow

This document describes the implemented source boundary. It is not a
certification, penetration-test report, or deployment-specific risk assessment.

## Data flow

```text
Microphone -> in-memory capture -> on-device VAD -> on-device Parakeet ASR
           -> local cleanup -> validated current-target insertion

Disk: verified model cache; preferences; encrypted usage totals and opted-in content
Application network: none required; no listener, updater, telemetry, or app-owned acquisition flow; dependency model hub forced offline
Provisioning utility: pinned model acquisition only when an administrator or developer runs it
```

## Data inventory

| Data | Stored | Protection |
| --- | --- | --- |
| Raw microphone audio | The application does not intentionally persist it | process memory; cleared after success, discard, replacement, or exit |
| Dictation history | Current session by default | memory only by default; optional AES-GCM persistence with configurable retention |
| Recovery text | Current session by default after a completed delivery attempt | memory only by default; follows the optional encrypted History retention policy |
| Meeting transcripts and notes | Only when Meeting notes is enabled; retained until manually deleted | AES-GCM; device-bound Keychain key |
| Vocabulary, learned correction rules, and snippets | At user request or after an enabled correction-learning event | AES-GCM; device-bound Keychain key |
| Local usage totals | After successful dictation, until the user resets them or removes app data | AES-GCM; word and dictation counts, speaking seconds, and first-use date; no dictated content |
| Preferences | As settings change | unencrypted macOS preferences; configuration values, not dictated content |
| Speech models | Before first use | unencrypted managed `root:wheel` tree with exact `0755`/`0644` modes, or user-owned evaluation cache; exact path, size, and SHA-256 manifest verified before use |
| Manual exports | Only when the user chooses Export | plaintext CSV or Markdown at the user-selected location |
| Explicit or enabled clipboard copies | Only when the user copies or enables Auto-copy | macOS system pasteboard; visible to other local clipboard readers |
| Logs | Local unified logging | fixed messages, numbers, booleans, and numeric error codes; the logging interface excludes arbitrary interpolated strings, error descriptions, paths, and dictated content |

## Permissions

- **Microphone** captures audio only.
- **Accessibility** identifies the focused editable target, refuses secure
  fields, and performs text insertion.
- An optional, off-by-default correction-learning feature can briefly re-read
  only the exact field that received the user's dictation. It refuses secure
  fields, compares values in memory, and does not store or transmit the field
  value.
- The app does not request Contacts, Calendar, Location, Camera, Screen
  Recording, or Full Disk Access.

## Network boundary

Microphone audio and transcript text are not sent to a remote transcription or
large-language-model service. LockedIn Flow exposes no model-acquisition flow
and has no automatic updater, telemetry client, or inbound listener. The linked
FluidAudio dependency contains general-purpose model-hub networking code, so
LockedIn Flow forces that hub offline before every local Core ML load. Missing,
corrupt, partial, or unexpected recognition-model content prevents that model
from loading without mutating the cache. The optional voice-activity detector
degrades to untrimmed audio when unavailable; it never loads an unverified
model.

The fixed managed search root is accepted only when its system ancestors are
real, root-owned directories without group/world write access, its app-owned
parent and complete model tree are `root:wheel`, and its directories and files
use exact `0755` and `0644` modes. Every system ancestor, app-owned parent,
model directory, and artifact on this narrow trust path must also have no
extended macOS ACL entries; ACLs can grant access beyond the POSIX mode bits or
introduce inherited policy that the app cannot safely interpret.
`/Library/Application Support` may retain its standard macOS group; only the
app-owned parent and model tree require `wheel`.
The app-owned parent and model directories must be exactly `0755` so standard
users can traverse and read the verified model files. An existing managed root
that fails this boundary stops model selection rather than falling back to a
user-controlled cache. These ownership requirements do not apply to the
per-user evaluation cache.

The separate source provisioning utility is an explicit non-content network
path. When run, it retrieves speech and voice-activity artifacts from immutable,
40-character Hugging Face revisions. It rejects redirects outside the reviewed
host boundary, enforces each expected byte count, and compares every SHA-256
before atomically activating a complete model directory. It sends no microphone
or transcript content. Enterprise endpoints can omit that tool and receive the
same verified tree through an approved package or MDM channel.

The LockedIn Flow app is not sandboxed, and the FluidAudio dependency is a general
library that may contain network-capable code even though its model hub is forced
offline here. Endpoint firewall or EDR policy remains the enforceable network
boundary for regulated deployment.

Source, release, and license links in the interface are explicit user actions
that ask macOS to open the default browser. They create no background request
from LockedIn Flow; any resulting browser traffic follows the browser and
endpoint policies.

## Text delivery

Accessibility insertion is preferred because it avoids clipboard exposure.
When a target requires paste, the application snapshots the existing pasteboard,
stages the text, posts one event only after target revalidation, verifies the
expected receipt, and restores the prior pasteboard only while it still owns the
transaction. Another application's newer clipboard write is preserved.

LockedIn Flow builds do not copy text to the clipboard automatically after a failed
insertion. A recoverable non-sensitive transcript remains in local
History/Recovery under the selected retention policy for an explicit retry or
copy. Secure or security-unverifiable target failures discard the transcript
instead of persisting it. The separate Auto-copy option is off by default and
intentionally leaves successful dictation text on the clipboard when enabled.

As soon as insertion begins, the destination application controls the text and
may transmit or sync it according to that application's configuration and
privacy policy.

Password and other secure fields are refused. Missing or conflicting security
metadata fails closed. Ambiguous post-event delivery is not repeated because a
blind retry could duplicate or misroute content.

## Local storage

Content stores are encrypted with AES-GCM. Keys are created in macOS Keychain
with a device-bound accessibility class. This protects normal at-rest access;
it does not protect against a compromised administrator, root process, malicious
device-management profile, or unlocked user session.

The source-built LockedIn Flow application has a distinct bundle identifier,
Application Support directory, preferences domain, log subsystem, and Keychain
service. Those namespaces prevent accidental collision and the application does
not intentionally access or migrate another build's stores. They are not an
operating-system isolation boundary: the LockedIn Flow app is not App-Sandboxed and
runs with the signed-in user's ordinary filesystem access in addition to the
Microphone and Accessibility permissions the user grants.

## Supply chain

- Swift dependency requirements are exact and commits are recorded in
  `Package.resolved`.
- GitHub Actions are pinned to immutable commits and use least-privilege job
  permissions.
- Release builds exclude internal diagnostics through compile guards and an
  independent binary-string gate.
- The packaging path generates and validates a CycloneDX 1.6 software bill of
  materials from reviewed repository evidence.
- Runtime model repositories are pinned to reviewed commits, and every deployed
  file is verified against the compiled SHA-256 manifest before Core ML loads it.

## Regulated deployments

Local processing and encrypted storage can reduce disclosure surface, but a
compliant deployment also depends on device encryption, screen-lock policy,
identity and endpoint controls, retention policy, target-system review,
workforce procedures, incident response, support access, and organizational
risk analysis. LockedIn Flow claims no HIPAA, SOC 2, FedRAMP, or similar
certification.

Current source does not expose a signed fleet policy that enforces retention,
learning, exports, or allowed models across managed devices. Offline runtime is
implemented by removing the app-owned acquisition flow and forcing the
dependency's model hub offline, while network denial remains an endpoint
control. The other controls must be applied through the deployment environment
until a reviewed in-product policy surface exists.
