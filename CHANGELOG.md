# Changelog

This project follows [Semantic Versioning](https://semver.org/). The first
LockedIn Flow source release will be tagged only after the candidate and release
evidence are approved.

## [Unreleased]

### Added

- Added content-redacted pull-request metadata checks and an evidence-linked
  engineering contract covering installation, offline behavior, reliability,
  permissions, supply-chain integrity, accessibility, and maintenance. Platform
  acceptance and production-download status are recorded separately from CI.
- Added a guarded Mac release-packaging command for reviewed source, Developer ID
  signing, app/DMG notarization and stapling, and exact-artifact evidence. It does
  not install or publish software; signed release-host and device acceptance
  remain separate from its automated orchestration tests.
- Added an evaluation-stage Windows/Linux desktop workspace with a real CPU
  speech engine, bundled verified model, explicit Copy, session terminology,
  and bounded capture with in-memory recovery. The native Mac app is unchanged.
- Added native Windows/Linux installer checks, a traceable GLib safety backport,
  dependency inventory and license notices, and documented supported-platform
  acceptance gates. Signed public Windows/Linux downloads are not yet available.

### Changed

- Added an in-app speech-model setup guide with separate source-build and
  managed-Mac instructions, explicit local rechecking, and keyboard-accessible
  controls that remain available in compact windows.
- Made in-app transcription the default, requiring only Microphone permission.
  Automatic typing is an explicit opt-in with a clear explanation of the broad
  macOS Accessibility permission. Recording never requests Accessibility access;
  incorrectly named and unbundled builds cannot request it through the app flow.
- Made first-run completion depend on a verified model and the permissions for
  the selected mode. Completion opens the home window without starting a recording.
- Standardized product labels and package names on LockedIn Flow, without an
  edition suffix. Existing storage and Keychain identifiers remain unchanged.
- Licensed the LockedIn Flow source under the MIT License for individual and
  commercial use, modification, and distribution, subject to its terms;
  enterprise deployment and support remain optional services rather than a
  usage-license requirement.
- Established a Mac-only LockedIn Flow source distribution with independent runtime
  identity and fresh release history.
- Replaced broad cloud claims with an explicit model-download network boundary
  and documented that LockedIn Flow builds contain no updater.
- Made LockedIn Flow builds unlimited, with no trial, usage cap, metered billing,
  purchase flow, or activation requirement.
- Added governance, contribution, disclosure, threat-model, CI, dependency,
  secret-scanning, and CodeQL configuration.
- Isolated the source-build bundle, storage, Keychain, and model cache from
  earlier proprietary builds, and removed the automatic updater dependency.
- Pinned all runtime model repositories and added exact byte-count and SHA-256
  verification before model activation.
- Made dictation History and Recovery session-only by default and prevented
  implicit clipboard export after failed LockedIn Flow insertions.
- Removed model acquisition from the application runtime. Models are now
  explicitly pre-provisioned, verified read-only from a managed or user cache,
  and FluidAudio is forced offline before loading.
- Added zero-dependency npm developer commands for diagnostics, recoverable
  local installation, and explicit pinned-model provisioning with transactional
  repair and interrupted-run recovery. npm installation has no lifecycle scripts.
- Hardened terminology CSV import with quoted-field and CRLF support, file and
  row limits, Unicode control rejection, application-profile scopes, conflict
  rejection for identical term/scope pairs, portable export limits, and verified
  encrypted persistence.

### Fixed

- Added recovery regressions covering 200 microphone-route-change cycles and
  100 stop/cancel-during-retry cycles, including retained audio, stale callbacks,
  and prevention of overlapping microphone sessions.
- Restrict all transcript clipboard writes and restoration to the current Mac
  using the operating system's cross-device clipboard exclusion option.
- Exclude test-mode Keychain and preferences hooks from release compilation and
  reject their markers during production-binary verification.
- Check exact dependency revisions against current OSV advisories in CI and on
  a recurring schedule, with failures treated as incomplete evidence.

- Reworked ordinary dynamic-editor capture to verify coherent observations of
  the focused text target instead of scanning a changing full-window
  Accessibility tree.
- Added bounded retries for transient renderer remounts while continuing to
  reject secure fields, different windows, different semantic paths, and
  unresolved target churn.
- Decoupled microphone capture from the concrete Accessibility field. Ordinary
  dictation now freezes the destination application when recording ends and
  resolves the current safe text field only at delivery, so routine renderer
  remounts during recording cannot invalidate the dictation.
- Expanded callback-starvation recovery to standard microphone capture as well
  as Voice Focus, with bounded progressive restart attempts that preserve audio
  already captured.
- Made interrupted partial dictations and meetings explicit in completion state
  and saved metadata instead of presenting truncated audio as a complete capture.
- Added non-retaining secure-field probes at recording start and stop while
  keeping the final delivery boundary fail closed.

### Security

- Removed transcript-length metadata from the dictation-completion diagnostic;
  it now emits only a fixed event, with a regression policy guarding that boundary.
- Replaced arbitrary-string logging with a typed, content-free interface. System
  error descriptions, local paths, and destination app identifiers are no longer
  included in application diagnostics.
- Added publication checks for private files, personal context, conversation
  exports, reviewed media hashes, and local documentation links, with a full
  reachable-history mode for publication review.
- Preserved exact-control behavior for protected workflows.
- Kept diagnostics compile-time excluded from release binaries.
- Added a source policy gate that rejects application networking primitives and
  requires the speech dependency's offline mode.
