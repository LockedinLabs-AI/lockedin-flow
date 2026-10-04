# Compatibility status

LockedIn Flow currently targets Apple-silicon Macs running macOS 15 or later.
Base dictation uses local Core ML speech recognition. Optional Foundation Models
cleanup, translation, and meeting notes require macOS 26 with Apple Intelligence
available and enabled.

## Current publication status

No application is listed as accepted for the v0.4.17 LockedIn Flow candidate yet.
The source test suite covers capture recovery, delivery-time target resolution,
secure-field refusal, at-most-once insertion policy, local storage, terminology,
cleanup, and model integrity, but source tests are not a substitute for the
installed matrix.

## Required installed matrix

Each release must publish an exact result for representative applications in
these classes:

| Class | Representative targets | Required scenarios | v0.4.17 status |
| --- | --- | --- | --- |
| Native editors | TextEdit, Notes, Mail | Empty field, selection replacement, focus change, undo | Not yet accepted |
| Browsers | Safari, Chrome | Native fields, renderer replacement, tab/window change, secure field | Not yet accepted |
| Renderer-driven AI clients | Codex, Claude Desktop | Immediate start, active renderer churn, field remount, long dictation | Not yet accepted |
| Collaboration | Outlook, Teams | Message composer, route change, interruption, recovery | Not yet accepted |
| Engineering | Xcode and a supported terminal/editor | Code profile, symbols, multiline insertion, cancellation | Not yet accepted |
| Remote or virtual workspace | Approved VDI/remote-desktop configuration | Focus, clipboard policy, latency, disconnect/reconnect | Not yet accepted |

The matrix must name the Mac model, microphone, macOS build, application
version, repetition count, successful insertions, safe refusals, duplicates,
recoverable-text events, and unresolved failures. Unknown outcomes are not
counted as success.

## Known scope

- The native Mac candidate targets Apple silicon. A separate Windows x64 and
  Linux x64 source preview is described in the [desktop guide](../desktop/README.md).
  Neither preview packaging nor a passing hosted build establishes a supported
  production release; use each platform's installed acceptance record.
- An external destination application may sync or transmit inserted text under
  its own policy; LockedIn Flow cannot change that application's boundary.
- A destination app can sync draft text before the user presses Submit. Local
  speech recognition does not make a cloud AI client an offline/private AI.
- The default workflow records into LockedIn Flow for review and explicit Copy;
  it does not depend on identifying another application's input field.
- Optional automatic typing inserts into the current safe field in the destination
  application at delivery. Keep the intended editor focused until insertion
  finishes; changing fields within that application changes the destination.

## Acceptance record requirements

Use synthetic speech and label each result **passed**, **failed**, or **not
tested**. Record the source revision, final artifact SHA-256, model hashes,
OS/app versions, device/microphone, date, test procedure, repetitions, and
observed outcome. Remove account names, device identifiers, paths, and dictated
private content before publishing a summary.

For each supported configuration, cover clean offline first launch with
pre-staged models, normal short/long dictation, cancel/retry, device disconnect,
sleep/wake, and a concurrent meeting/transcription application. Add secure
fields, editor replacement, focus movement, and clipboard contention when
automatic typing is enabled. Include keyboard-only and platform screen-reader
use of setup, recording, transcript review, Copy, errors, and recovery.

Set the repetition count and latency/resource/accuracy acceptance budgets before
running the pilot, based on its target hardware and workload. Record every
attempt, including safe refusals and interruptions. Any lost completed text,
duplicate delivery, wrong-target insertion, unexplained network activity, or
unrecoverable crash rejects the affected configuration until corrected and
retested. A bounded successful test run does not imply a zero-failure guarantee.

See [Validation evidence](validation.md) for the hosted source-gate status and
the installed-product evidence that remains pending.
