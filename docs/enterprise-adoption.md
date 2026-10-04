# Enterprise adoption and product boundary

LockedIn Flow is intended to be a small, reviewable endpoint capability rather
than another enterprise platform. It adds no inference tenant, account service,
usage-based API, daemon, or inbound listener. Speech recognition and cleanup run
on the managed Mac, and administrators can pre-stage the exact model set through
their existing software-delivery channel.

LockedIn Flow has no per-seat software license or inference
charge. That does not make deployment costless: the organization still owns
endpoint management, hardware capacity, validation, support, and model-license
obligations. LockedIn Flow is designed to reduce disclosure surface in regulated
workflows; it is not a compliance certification.

## The defensible promise

- Microphone audio and transcript content are not sent to a hosted inference service.
- The application opens no inbound network service and exposes no model-acquisition flow, telemetry client, or automatic updater; the linked dependency's general-purpose model hub is forced offline before loading.
- The source is designed to require no runtime network after verified model provisioning; blocked-network validation of the exact release artifact remains a promotion gate.
- Missing, corrupt, or unexpected recognition-model files prevent that model from loading and provide provisioning guidance; optional voice-activity detection can degrade to untrimmed audio without loading an unverified model.
- Password fields and unverifiable insertion targets fail closed; ambiguous delivery is never blindly repeated.
- The LockedIn Flow source can be inspected, built, tested, and deployed without an account or per-seat inference fee.

Do not shorten these statements to “certified,” “absolutely secure,” “zero cost,”
or “always works.” Enterprise confidence comes from an enforceable boundary and
measured release evidence, not an absolute claim.

## Delivery lanes

| Audience | Delivery | Network behavior | Status |
| --- | --- | --- | --- |
| Source evaluator | Clone the repository, run `npm ci --ignore-scripts --no-audit --no-fund`, then explicitly run `npm run setup:local` | Swift dependencies and pinned models are acquired during the explicit setup step | Implemented for local evaluation; app is ad-hoc signed |
| Individual user | Developer ID signed and notarized DMG or product PKG | Model acquisition is a separate, explicit step | Release pipeline still required |
| Managed enterprise | Signed/notarized app PKG, model PKG, managed policy, and PPPC profile through MDM | Models arrive through the approved deployment channel; application egress can be denied before first launch | Target production architecture; packages and profiles still require release validation |
| Air-gapped environment | Internally mirrored, reviewed app and model packages | No public network dependency on the endpoint | Requires organization-specific artifact transfer and acceptance |

npm is a developer convenience and a possible future bootstrap CLI, not the
enterprise control plane. A production npm bootstrapper should only fetch an
immutable, signed, notarized PKG; verify its version, byte count, SHA-256,
Developer ID Installer identity, and stapled ticket; then open the native macOS
installer. It must never ask for an administrator password or run a native
installer from an npm lifecycle hook.

## Terminology adaptation

The current product supports local spoken-to-written rules and scopes them to
General, Email, Chat, or Coding application profiles. CSV import accepts this
schema:

```csv
spoken,written,caseSensitive,profiles
jay wad,Jawad,false,email|chat
f h i r,FHIR,true,general|coding
```

Quoted commas and CRLF files are supported. Imports are limited to 2 MB, 10,000
rule rows, and 10,000 stored rules; reject control and bidirectional-override
characters and unknown scopes; and are encrypted after a successful explicit
import. The CSV itself remains plaintext at the administrator- or user-selected
location.

[`examples/terminology-template.csv`](../examples/terminology-template.csv) is a
synthetic, import-ready starting point. Keep generated employee or customer
terminology outside source control, and deliver it through the organization's
approved endpoint-management channel.

This is terminology adaptation, not model training. For a pilot, an authorized
administrator should export only approved display names, terms, and explicit
“heard as” aliases; remove email addresses, employee IDs, phone numbers,
reporting relationships, and other unused directory fields; then distribute a
minimized cohort file through the existing endpoint-management process. Never
commit a real employee directory or terminology export to this repository.

A production managed-terminology feature should add signed, versioned,
anti-rollback packs; MDM-enforced policy; read-only managed entries separated
from personal rules; last-known-good recovery; key rotation; and content-free
fleet health reporting. Live endpoint access to Entra ID, Active Directory,
LDAP, or an HR system is intentionally not the preferred architecture.

## Reliability program

The source is designed to work without runtime internet access after verified
provisioning. Exact-artifact blocked-network acceptance and “always works”
reliability remain release gates. Promotion should be based on repeated
installed evidence across representative native and renderer-driven editors,
including:

1. target remount, focus movement, and secure-field refusal;
2. microphone route changes, interruption, sleep/wake, and recovery;
3. exactly-once Accessibility and pasteboard delivery;
4. long dictation, crash/restart, explicit recovery, and retention behavior;
5. blocked-network startup with pre-staged models;
6. CPU, memory, model-load time, battery, and thermal measurements; and
7. update, rollback, and removal through the supported MDM path.

Publish the compatibility matrix and observed results for each release. A
failure that cannot be proven safe should preserve recoverable text and explain
the next action instead of guessing or repeating delivery.

## Enterprise roadmap, in order

1. Complete installed acceptance for the current target-remount and microphone-recovery fixes.
2. Produce Developer ID signed, notarized, stapled app and product PKGs with exact-artifact SBOM and provenance.
3. Resolve model redistribution terms, then ship separate default-model and optional-model packages for efficient MDM updates.
4. Add signed managed policy for offline mode, retention, clipboard behavior, learning, exports, allowed models, and terminology packs.
5. Publish Jamf, Microsoft Intune, and Kandji deployment recipes with rollback and uninstall guidance.
6. Commission an independent security assessment and publish remediation and support timelines.
7. Add an LTS release channel, fleet-compatible diagnostics containing no dictated content, and defined patch SLAs as an optional enterprise service.
8. Validate Windows demand before presenting the product as a general enterprise-fleet solution; the current product is a managed-Mac pilot.

## Pilot frame for a managed-workplace buyer

The initial proposal is deliberately narrow: deploy to a small managed-Mac
cohort in engineering, clinical operations, or another terminology-heavy team;
pre-stage models, distribute a minimized CSV for explicit user import, block
application egress, and measure accuracy, failed-delivery recovery, support
load, resource use, and time saved. It fits the workplace stack the organization
already operates instead of asking the buyer to approve a new inference cloud.

LockedIn Flow is free under MIT. A later commercial offer can cover
signed long-term-support releases, managed packaging, security maintenance,
terminology-pack lifecycle, compatibility validation, and enterprise support.
Those services are a business option, not a capability or service-level promise
in the current source release.
