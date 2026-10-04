# Validation evidence

This page records what the current LockedIn Flow candidate has actually passed and
keeps source validation separate from installed-product acceptance.

## Package validation: 3 October 2026

[Native run 37157855255](https://github.com/LockedinLabs-AI/LockedIn-Flow/actions/runs/37157855255)
passed Windows and Linux installer checks for corrected source
`3b6251226b9e13705b23655de0a9b887fb087f8e` at merge checkout
`303bd3d65a5c5a5e2a1da51221e691cdf8a81f0f`. The strict validated report digest is
`ab9870ed313c4e0b731f4e3931cafafb3faaac482373dd8d4eda401dd903ec30`.
Its host-file collector completed, considering 122,223 runtime paths and hashing
10 ELF files with zero read failures. All 173 non-application AppImage ELF files
remain without exact host matches; **collection success is not attribution**.
No source, component or notice identity was assigned to those files.

The subsequent build wrapper pins the three AppImage tool downloads and verifies
a new isolated cache before and after packaging. Local tests cover tampering,
unsafe redirects, bounded downloads, exact marker mutation, permissions and
cleanup. Actual pinned downloads were verified on a Mac without execution; this
is not native Linux wrapper or installer acceptance. That native result is pending.

### Earlier host-reference parser diagnosis

[Native run 37155075227](https://github.com/LockedinLabs-AI/LockedIn-Flow/actions/runs/37155075227)
passed Windows and Linux installer checks for source
`f4ad6755d1b8f20f19a9b7a40b7f4f8fac2efc07`, tested at merge checkout
`0027db171da80d812f56784c8c4871ed808ef12f`. Its retained report passes strict
schema and execution-identity validation, with SHA-256
`2e657b13449d6a7fdc7241a69fba05fff8e6510cd415fd01a1e2f6fec5f0d981`.
However, its optional host-file reference collector returned **unavailable**.
The green payload checks do not establish library-source or notice mapping.
A full installed-database regression now runs before native compilation; its
failure diagnostics use fixed categories without raw paths or package data.
That regression reproduced `database-encoding` on the native Ubuntu runner in
[run 37157672454](https://github.com/LockedinLabs-AI/LockedIn-Flow/actions/runs/37157672454),
before compilation. The parser now accepts valid UTF-8 filenames in the database
while retaining ASCII package-identity and runtime-path allowlists. Malformed
UTF-8, control characters and unsafe paths remain rejected or excluded. Native
confirmation of the corrected full-database check and collector is recorded above.

[Native run 37148286084](https://github.com/LockedinLabs-AI/LockedIn-Flow/actions/runs/37148286084)
passed on Windows and Linux for source
`be2d2a75e8150e51980f2c1351161a6e043334d7` at actual merge checkout
`8aa9a7a10ba0ffebfa76853135bdc7120a239524`. Its schema-validated retained report
verifies original DEB (26 entries), RPM (11 entries) and AppImage (537 entries)
payloads. Each contains the exact application, pinned model and four compliance
resources compared with independent staged references. The report SHA-256 is
`36d5a63d5a423ccb77019fcb7a958bf53ab5fc2001dfc0d7f82f3903bfc60520`.

Windows passed NSIS/MSI installation, branding, integrity and removal, plus
matching Microsoft-signed offline WebView2 input checks. Linux passed installed
DEB window/process launch without an external network interface, integrity and
removal. Both passed synthetic offline recognition. General CI, Security,
dependency review and public-metadata checks passed; evaluation attestation and
installer uploads were skipped. RPM/AppImage installation, physical microphone,
rendered-content and user-device acceptance are not established by these checks.

The AppImage contains 174 ELF files. Its Cargo source inventory still has 349
components, with 346 retained-text and three source-reference-only records;
these are different inventory scopes, not equivalent component counts. File
hashes do not close native source/version or license mapping. The subsequent
exact host-file reference collector is locally tested, but its first native
collection was unavailable as recorded above. It preserves unmatched/ambiguous
files and does not turn a host copyright hash into a shipped notice or license
approval. See [security boundaries](../desktop/SECURITY.md#exact-host-file-references).

### Earlier RPM and AppImage implementation evidence

The candidate now reads the original RPM framing and bounded gzip payload,
validates its newc CPIO archive without extraction or execution, and compares
the application, model and compliance files with independent build references.
The executable reference includes the RPM-specific marker written by pinned
Tauri CLI 2.12.0. Malformed headers, unsafe archive entries, corrupted compressed
data, missing resources and altered file digests remain rejected.

[Native run 37135860470](https://github.com/LockedinLabs-AI/LockedIn-Flow/actions/runs/37135860470)
tested source `595273845eabcbcc49960da731c4ee30c63988f9` at merge checkout
`65be42a21eede9ca0dbefdead65a42d3b4f4a685`. DEB (26 entries) and RPM (11 entries)
both passed payload inspection, including exact application, model and four
compliance-file hashes. Windows native validation passed. Linux synthetic offline
recognition and installed-DEB launch, integrity and removal checks passed; the
overall Linux job failed only its final incomplete AppImage payload gate.
General CI, security, dependency review and public-metadata checks passed.

The subsequent AppImage reader locates the original SquashFS filesystem without
executing the AppImage. It checks bounded gzip/zstd metadata and file blocks,
directory/index consistency, inode reachability, fragments, hard links and safe
relative links, then verifies required resources against staged references.
Unit tests use synthetic inputs. A separate cross-check with the official
SquashFS writer exercises real filesystem encoding; it is not an installed
AppImage, microphone or device test. Native AppImage payload validation is now
recorded above. Component/license reconciliation, signing and installed-device
acceptance remain separate requirements; a retained payload report does not
authorize release.

## Installed Linux launch gate

The desktop workflow now includes an installed-DEB launch check, in addition to
file-integrity and uninstall checks. It runs as the ordinary ephemeral runner
user inside a network namespace with only loopback, using an isolated X/DBus
session. The exact installed process must expose a visible LockedIn Flow window
continuously for five seconds within a 45-second startup window. Early exits,
crashes, disappearing windows and failed probes fail the check. It does not
request microphone access or disable the webview sandbox.

[Native run 36515302800](https://github.com/LockedinLabs-AI/LockedIn-Flow/actions/runs/36515302800)
passed this installed launch check, resource integrity and removal for source
`f588fbb04fbae6c98c882cf961bb6134a0d8c829`. Windows installer validation also
passed. The overall run still failed the incomplete Linux payload acceptance
gate; these results do not waive RPM/AppImage or redistribution requirements.
Window/process liveness does not establish rendered UI, recording, transcription
accuracy, accessibility or physical-device acceptance.

The subsequent recording-control correction waits for worker completion before
unlocking commands, rejects stale pre-command status updates, and preserves the
visible transcript while controls are disabled after a lost status connection.
Its regression tests cover duplicate Stop/vocabulary requests, stale polls,
and lost status. The native run below includes this correction.

## Earlier cross-platform validation: 29 September 2026

Source `83b1ec79cbdc48307fbaf4c78e1bd43e2d6c65fb` completed
[native validation](https://github.com/LockedinLabs-AI/LockedIn-Flow/actions/runs/36554089355)
in the open desktop pull request. The tested merge checkout was
`b57ae07e9ccb9a9ab38dc3aeaf3d6fcfa16e24b2`.

- Windows passed native tests, synthetic offline recognition, and NSIS/MSI
  installation, branding, resource-integrity and removal checks.
- Linux passed synthetic offline recognition, installed DEB window/process
  launch without an external network interface, resource integrity and removal.
  **Overall native validation still failed** the incomplete RPM/AppImage
  payload-acceptance gate. No requirement was waived.
- [General CI](https://github.com/LockedinLabs-AI/LockedIn-Flow/actions/runs/36554089442),
  [security](https://github.com/LockedinLabs-AI/LockedIn-Flow/actions/runs/36554089379),
  [dependency review](https://github.com/LockedinLabs-AI/LockedIn-Flow/actions/runs/36554089333)
  and [public metadata](https://github.com/LockedinLabs-AI/LockedIn-Flow/actions/runs/36554089431)
  passed. Evaluation attestation was skipped; this is not signing evidence.
- The Mac capture change rejects non-finite audio, preserves earlier valid
  samples, and prevents callbacks from a failed or obsolete session from
  contaminating a recording. Its reproducer failed before the fix; the full
  local Swift suite then passed 550 tests. Ten consecutive synthetic Parakeet
  transcriptions also returned consistent words with networking denied.
  This does not establish physical microphone reliability or resolution of
  every historical target-field error. Memory usage was not measured.

The preceding notice-only source `1382ad036b3740d3b9dae0c095ea10ff9f2d021c`
has a validated [native report](https://github.com/LockedinLabs-AI/LockedIn-Flow/actions/runs/36548548555)
with 349 inventory components: 346 retain notice text and three remain
source-reference-only (`audio-core`, `selectors`, `realfft`). The supplemental
`dlopen2` and `dlopen2_derive` notices reached the generated native inventory.
Retained text does not establish complete redistribution approval or runtime
linkage; the short `dasp_sample` Apache reference remains a separate concern.

These are candidate results, not a production release or signed-device
acceptance. Independent review, remaining payload and redistribution checks,
trusted signing, physical microphone/coexistence testing, and upgrade/rollback
acceptance remain required. No production installer was published by this run.

## Earlier cross-platform validation: 28 September 2026

This earlier completed native validation covers source
`b0235f94804477cb5ab9a5bba7e9fb04e3ec18af` in the open
[desktop pull request](https://github.com/LockedinLabs-AI/LockedIn-Flow/pull/10),
not a merged or published production release. The actual CI checkout was
`cbf36f986f575081e13570ebf5461b2d276eec6f`; its tree matches that source.

- [Native desktop validation](https://github.com/LockedinLabs-AI/LockedIn-Flow/actions/runs/36371173666):
  Windows passed NSIS/MSI installation, branding, resource integrity and removal,
  including offline WebView2 input identity and signature checks. Linux passed
  DEB original-payload inspection (26 entries), installed integrity and removal.
  **Overall native validation failed:** RPM payload verification is unavailable
  and the AppImage payload reader is not implemented. These gates were not waived.
- [General CI](https://github.com/LockedinLabs-AI/LockedIn-Flow/actions/runs/36371173644),
  [Security](https://github.com/LockedinLabs-AI/LockedIn-Flow/actions/runs/36371173729),
  [dependency review](https://github.com/LockedinLabs-AI/LockedIn-Flow/actions/runs/36371173630)
  and [public metadata](https://github.com/LockedinLabs-AI/LockedIn-Flow/actions/runs/36372916620)
  passed. The assembled Node 22 tooling suite passed 179 tests with two
  Windows-only tests skipped on the local Mac.
- The validated Linux report records 349 inventory components: 344 with retained
  notice text and five source-reference-only entries. The remaining entries are
  `dlopen2`, `dlopen2_derive`, `audio-core`, `selectors` and `realfft`.
  Retained text is not complete license approval or proof of runtime linkage;
  the short `dasp_sample` Apache reference is not a full license text.

Installer binaries were not uploaded or released by this pull-request run.
Real-device microphone, cross-application delivery, conferencing coexistence,
upgrade/rollback, signing and remaining redistribution review still require
acceptance. Successful synthetic offline recognition does not establish those
results. A later source revision must receive its own relevant validation.

## Earlier cross-platform baseline: 27 September 2026

The repository is public source; the work below is in the review branch, not a
production download. This earlier baseline is
`5cad8e42def1dec9333d8cd37b7193ea397502e0`:

| Evidence | Observed result | Scope |
| --- | --- | --- |
| [Mac CI](https://github.com/LockedinLabs-AI/LockedIn-Flow/actions/runs/36321325520) | Passed | Pinned-toolchain builds, source/tooling tests, publication checks, evaluation packaging; not Developer ID signing or physical microphone acceptance |
| [Native desktop CI](https://github.com/LockedinLabs-AI/LockedIn-Flow/actions/runs/36321325362) | Windows and Linux passed | Native builds and tests, synthetic offline recognition, package verification, Windows EXE/MSI and Linux DEB installation/removal checks |
| [Security](https://github.com/LockedinLabs-AI/LockedIn-Flow/actions/runs/36321325378) | Passed | Configured static-analysis and secret-scanning gates, not an independent penetration test |
| [Dependency review](https://github.com/LockedinLabs-AI/LockedIn-Flow/actions/runs/36321325495) | Passed | Dependency changes covered by the configured review, not proof of no unknown vulnerabilities |

Subsequent commits must receive their own relevant checks. The newer Windows
WebView2 prerequisite-signature verification is additional work and is **not**
covered by this baseline. Follow the exact commit's workflow checks in
[the desktop pull request](https://github.com/LockedinLabs-AI/LockedIn-Flow/pull/10).

The native Mac candidate is v0.4.17/build 19. The separate Windows/Linux port is
v0.5.0-alpha.1; its own-window record/review/Copy workflow does not yet provide
the Mac automatic-typing, shortcut, or encrypted-history feature set. A native
installer test does not establish hardware microphone, GUI, screen-reader,
meeting-app coexistence, upgrade/rollback, or enterprise fleet acceptance.

### Remaining release decisions and evidence

| Gate | What remains | Responsible role |
| --- | --- | --- |
| Source approval | Independent review of the exact naming, permission, and desktop changes; merge through the existing protections | Maintainer other than the author |
| Trusted packages | Mac Developer ID signing/notarization, Windows signing, and approved Linux distribution artifacts with exact-artifact provenance and checksums | Release maintainer with controlled signing access |
| Model distribution | Review each bundled model's redistribution terms and notices; verify offline provisioning on a clean endpoint | Model/dependency and release maintainers |
| Real-device acceptance | Complete the [compatibility matrix](compatibility.md), including the affected microphone/focus scenarios and keyboard/screen-reader use | Device testers and release maintainer |
| Privacy and performance | Observe the exact installed artifact with networking denied; measure latency, resource cost, accuracy, and terminology quality on a declared corpus | Security reviewer and pilot owner |
| Enterprise operations | Test managed installation, update, rollback, removal, retention, permissions, and endpoint policy; assign support/security-response ownership | Endpoint administrator and service owner |
| Public availability | Publish only accepted artifacts; test website/README download paths against those exact bytes and synchronize supported-platform claims | Release maintainer |

These are the remaining delivery gates, not reasons to add unrelated features.
A platform can launch once its own requirements pass; it must not inherit
another platform's acceptance. The dated local evidence below remains useful
history, not the latest test count or coverage for every later commit.

## Current review candidate

The v0.4.17/build 19 source candidate completed the local checks below on
26 September 2026. The [CI workflow](../.github/workflows/ci.yml) and
[security workflow](../.github/workflows/security.yml) record hosted results
against each tested revision. A later commit must run the relevant checks again.

| Gate | Result |
| --- | --- |
| Swift tests | 538 passed, 0 failed, including content-free logging regressions |
| npm tooling tests | 46 passed, including provisioning, macOS ACL cases, history privacy, clipboard and logging policies, advisory-service failures, and analysis-result gating |
| Formatting | Strict `swift-format` lint passed |
| Builds | Debug and release builds passed with the pinned toolchain |
| Binary diagnostic | Production-binary diagnostic passed |
| SBOM | 12 generation and validation tests passed, including document identity required by attestation |
| Binary policy | 41 checks passed |
| Runtime network source policy | Passed |
| Dependency advisories | OSV returned no matching advisories for the exact FluidAudio and vendored KeyboardShortcuts revisions on 26 September 2026; see the limited coverage in [Third-party risk](third-party-risk.md) |
| Publication content | Candidate-tree checks pass; full reachable-history review is required on the final publication repository |
| Secret scan | TruffleHog is required with verified, unknown, and unverified results enabled; consult the exact revision's Security check |
| Evaluation packaging | CI builds and verifies an ad-hoc app and unsigned, no-script PKG; consult the exact revision's build check |

CodeQL, dependency review, and public artifact attestation must have recorded
results on the published repository before the first binary release. A skipped
job is not passing evidence. The latest CI run identifies which checks ran for
each candidate.

The pinned source-evaluation toolchain is Xcode 26.6 build 17F113, Apple Swift
6.3.3, and the macOS 26.5 SDK. The package records the source revision,
dependency-lock hash, SBOM hash, and model-manifest hashes in its build
provenance. The approved public tree must be built and accepted as its own
artifact before release.

## Additional first-use and recovery checks

The least-privilege first-dictation candidate completed additional local checks on
27 September 2026:

- All 548 Swift tests passed, including delivery-mode and permission-identity
  regressions plus two added recovery stress tests.
  The new tests exercise 200 route-change cycles and 100 stop/cancel-during-retry
  cycles using the production capture manager with synthetic engine callbacks.
  They do not substitute for physical-device interruption testing.
- All 54 npm tooling tests passed, including first-use permission, model-setup,
  and no-implicit-recording policies.
- Five synthetic speech recordings passed a local-recognizer smoke test with
  process networking denied. Every normalized word matched; punctuation varied.
  This is not an accuracy benchmark, microphone test, or whole-device traffic
  assessment.
- Native checks of the packaged application verified Microphone-only first-use
  guidance, automatic typing off by default, a correctly branded explanation
  before the optional Accessibility request, and cancellation that leaves
  automatic typing disabled without raising an OS permission request.
  No Microphone or Accessibility permission was granted during these checks.
- The packaged application opened and loaded the provisioned Parakeet model.
  Real-microphone capture and cross-application insertion acceptance remain
  outstanding. Prior compact-layout and window-lifecycle checks used synthetic
  application state; they are not microphone evidence.
- Evaluation app packaging, strict bundle-signature verification, SBOM validation,
  and unsigned, no-script installer packaging passed. These are local evaluation
  artifacts, not Developer ID signed or notarized releases.

Public workflow results must cover the exact proposed commit before merge;
earlier CI results do not cover these later changes.

## What this does not prove

The evidence above does not prove that the candidate is ready for general
availability. It has not yet completed:

- Developer ID Application and Installer signing, notarization, and stapling;
- repeated installed record-to-exactly-once acceptance across the published
  target-application matrix;
- affected-hardware microphone route, interruption, and recovery testing;
- managed install, upgrade, rollback, removal, and permission remediation;
- blocked-network packet-capture validation of the exact release artifact;
- representative CPU, memory, battery, thermal, and latency measurement; or
- independent security assessment and model-redistribution approval.

Until those gates pass, describe the project as a source release candidate or
managed-Mac pilot candidate—not an enterprise-ready production release.

## Evidence rules

Release evidence must identify the exact source revision and artifact. A later
commit, rebuilt binary, different model tree, or changed signing identity is a
new candidate and cannot inherit an earlier result. Rejected candidates remain
rejected; their version/build identifiers are never reused for different bytes.

See [Compatibility](compatibility.md), [Enterprise evaluation](enterprise-evaluation.md),
and [Release process](release-process.md) for the remaining matrix and promotion
path.
