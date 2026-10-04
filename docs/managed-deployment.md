# Managed deployment

This guide describes the LockedIn Flow build's implemented macOS boundary. It is a
deployment starting point, not a certification or a substitute for an
organization-specific risk assessment.

## Supported surface

- Base dictation requires Apple silicon and macOS 15 or later.
- Apple Foundation Models cleanup, translation, and Meeting notes require
  macOS 26 or later with Apple Intelligence available and enabled.
- The LockedIn Flow bundle identifier is `ai.lockedin.flow.community`.
- Existing internal identifiers and storage paths are retained for compatibility
  with earlier source evaluations. They do not designate a separate product edition.
- The application is not App-Sandboxed. It needs user-granted Microphone access.
  Accessibility is optional for automatic typing into other apps. It otherwise runs with the signed-in user's normal
  filesystem access.

## Build and provenance

Build only from an approved commit with a clean worktree and the checked-in
`Package.resolved`. Record `xcodebuild -version`, `swift --version`, the source
commit, the SHA-256 of `Package.resolved`, and the generated SBOM. The packaging
script writes this evidence to `Contents/Resources/BUILD-PROVENANCE.txt` before
signing.

For managed distribution, replace the local ad-hoc signature with a controlled
Developer ID signature, notarize and staple the artifact, verify Gatekeeper,
and retain the final artifact's SHA-256 and provenance evidence. When the
repository is public, CI attests its unsigned evaluation ZIP, unsigned
evaluation PKG, and packaged SBOM; those attestations do not cover a separately
signed or notarized artifact. Do not deploy a build whose recorded source state
is `modified`.

`npm run package:pkg` creates an unsigned, no-script component package only for
testing payload structure and the installation path. It is intentionally named
`evaluation-unsigned` and is not suitable for fleet deployment.

## Speech-model provisioning

The application searches a root-owned managed location first, then the current
user's evaluation location:

```text
/Library/Application Support/LockedIn Flow/Models
~/Library/Application Support/LockedInFlowCommunity/FluidAudio/Models
```

Expected folders and exact upstream revisions are:

| Folder | Revision | Bytes |
| --- | --- | ---: |
| `parakeet-tdt-0.6b-v3` | `7dd20fe6b1797d35f5e3307e8b1732d9a178edfe` | 483,105,645 |
| `parakeet-unified-en-0.6b` | `4252711f6f060f9a2f91e5f081a806d7f45eebd8` | 614,079,874 |
| `silero-vad` | `b419383c55c110e2c9271fa6ee0ea83d03c70d96` | 1,063,425 |

All three consume 1,098,248,944 bytes (about 1.02 GiB) before filesystem
overhead. The default multilingual model plus voice-activity model consumes
484,169,070 bytes.

LockedIn Flow exposes no model-acquisition flow and forces the linked
dependency's general-purpose model hub offline before loading. A missing or
invalid recognition model is not loaded and neither location is modified. The
optional voice-activity detector can degrade to untrimmed audio without loading
an unverified model. For local source evaluation, run the explicit provisioning
utility; it contacts only pinned Hugging Face revisions, limits every response
to its reviewed byte count, verifies every SHA-256, and atomically activates
complete model folders:

```bash
npm run provision:models
# Add -- --all only when the optional English Precision model is required.
# Add -- --repair to stage and atomically replace an existing invalid model.
```

The provisioner does not mutate an invalid active model unless `--repair` is
explicitly requested. It verifies the complete replacement before activation,
restores the prior directory if activation fails, and cleans or recovers its
recognized transaction directories after an interrupted run.

For managed deployment, acquire the artifacts on a controlled provisioning
workstation, complete the model-license review, verify the tree, and deliver it
to the fixed system location through the approved MDM/package channel. The
managed profile emits package-ready directories at `0755` and artifacts at
`0644`; the default profile keeps the per-user cache private at `0700` and
`0600`. Managed mode requires an explicit absolute staging destination:

```bash
npm run provision:models -- \
  --managed --destination "/absolute/path/to/staged/Models"
# Add --all to include the optional English Precision model.
# Add --repair only to replace an existing invalid staged model.
```

The destination must be a dedicated path whose final component is `Models`.
The provisioner rejects filesystem, system, and home roots, every descendant
of `/tmp`, `/private/tmp`, and `/var/tmp`, and paths traversing a
user-controlled symbolic link. It resolves the deepest existing ancestor and
validates again after creating the destination, before permission or model
state changes.

Provisioning holds an exclusive destination lock across interrupted-transaction
recovery, staging, activation, verification, and cleanup. Lock age alone is
never treated as proof that a transfer is stale. A lock left by a crashed
process, a malformed lock, or a cross-host lock must be inspected and removed
manually only after confirming that no provisioner is using the destination;
this avoids a check/remove race between concurrent recovery attempts.

The application package must install the app-owned parent and staged tree as
`root:wheel` while preserving `0755` directory and `0644` artifact modes, so
standard users can read models but cannot modify them. The provisioner
intentionally does not change ownership on the build workstation. Do not run
npm as root and do not enumerate user home directories from an installer.
Before packaging, verify either the exact default set or all three models. The
`--managed` staging mode checks content and modes while intentionally allowing
the staging tree to remain owned by the build user:

```bash
scripts/verify-model-cache.sh \
  --managed --default "/absolute/path/to/staged/Models"

scripts/verify-model-cache.sh \
  --managed --all "/absolute/path/to/staged/Models"
```

After installation, run the distinct system-tree check on the fixed managed
search root:

```bash
scripts/verify-model-cache.sh \
  --managed-installed --default "/Library/Application Support/LockedIn Flow/Models"
# Use --all when the optional English Precision model is installed.
```

Post-install verification requires `/`, `/Library`, and `/Library/Application
Support` to be real, root-owned directories that are not group- or
world-writable. It also requires the app-owned `LockedIn Flow` parent, the
`Models` root, every model directory, and every artifact to be owned by
`root:wheel`; the app-owned parent and model directories must be exactly `0755`,
and artifacts exactly `0644`. None of these system ancestors, app-owned
directories, model directories, or artifacts may carry an extended macOS ACL;
the verifier rejects every allow, deny, or inherited ACL entry rather than
trying to determine whether a particular entry is harmless. This restriction
is intentionally limited to the fixed managed path and does not apply to the
per-user evaluation cache. The broader `/Library/Application Support`
directory commonly uses the macOS `admin` group and is not incorrectly required
to use `wheel`.

Both verifier modes check reviewed byte counts and SHA-256 values and reject
symlinks, special files, missing files, and unexpected files. Before accepting
a managed model, the application independently enforces the system-ancestor,
`root:wheel`, exact-mode, and exact-content boundary. An existing unsafe
managed root fails closed and is not bypassed by the per-user evaluation
cache. The per-user cache remains user-owned and is subject to exact-content,
not system ownership, checks. Model delivery is an administrative acquisition
step, not application runtime traffic. Block application egress before first
launch and confirm the selected model reaches Ready.

## Permissions and policy

In-app transcription is the default and does not require Accessibility approval.
Automatic typing is an explicit opt-in; existing macOS permission alone does not
enable it. Keep that feature off where broad cross-application access is prohibited.

Use a signed, stable designated requirement before creating a Privacy
Preferences Policy Control (PPPC) profile. Scope Accessibility narrowly to the
LockedIn Flow bundle and its approved signature; do not approve arbitrary or
ad-hoc-signed builds. Microphone consent and PPPC behavior vary by macOS and
management platform, so validate the exact profile on the deployed OS release
against current Apple and MDM-vendor guidance.

Recommended host controls include FileVault, screen-lock policy, least-privilege
user accounts, endpoint detection, denied application egress, and reviewed
retention settings. The separate LockedIn Flow storage
names prevent accidental collision with another build but are not an OS sandbox.

## Acceptance

Before broad deployment:

1. Verify source, dependency lock, SBOM, provenance, code signature,
   notarization, Gatekeeper, and the installed model cache with
   `--managed-installed`.
2. Block outbound access and confirm the selected speech model reaches Ready.
3. Repeat record-to-exactly-once delivery in representative native and
   renderer-driven editors, including target remount and focus-change cases.
4. Confirm password fields and unverifiable targets fail closed.
5. Exercise microphone interruption/recovery, app restart, retention changes,
   explicit recovery, and clipboard-ownership changes.
6. Review content-free logs for subsystem `ai.lockedin.flow.community` and keep
   transcript, audio, and clipboard content out of support evidence.

## Removal

Quit the application before removal. Remove the application bundle through the
organization's software-management tool. If policy requires local-data removal,
separately remove the explicit
`~/Library/Application Support/LockedInFlowCommunity` directory, the
`ai.lockedin.flow.community` preferences domain, and the Keychain generic
password item whose service is `ai.lockedin.flow.community`. These actions erase
local configuration, models, history, recovery, meetings, vocabulary, snippets,
and usage totals and should follow the organization's retention and legal-hold
process.

Remove `/Library/Application Support/LockedIn Flow/Models` separately only when
retiring the managed model package for the device; that shared root may serve
more than one user.
