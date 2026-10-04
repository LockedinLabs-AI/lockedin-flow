# LockedIn Flow for Windows and Linux

Offline speech-to-text for your editor, local agent, and everyday work. Record,
review, and copy your words without an account, an external language model, or
a hosted transcription service. This workspace adds standard desktop packaging
without replacing the native [macOS application](../README.md).

**Status: 0.5.0-alpha.1, source evaluation.** Windows and Linux installers are
being validated. There is no signed, generally available desktop download yet.
Do not use an unsigned test build as a production healthcare deployment.

## What is implemented

- Real local English recognition using Whisper Base English and a CPU backend.
- A checksum-verified model bundled into the installer; no first-run download.
- Microphone capture that does not inspect or control other applications.
- Review before explicit Copy; no automatic clipboard replacement or typing.
- Session vocabulary, including engineering terms and names with Unicode.
- A bounded five-minute recording, partial-capture notice after an interruption,
  stalled-stream detection, and in-memory retry after a recognition error.
- No application telemetry, hosted inference, updater, account, or inbound server.

This port does not yet provide the Mac application's global shortcut, encrypted
history, or automatic insertion. It is dictation into its own window, not a voice
agent: commands in the transcript are text, never executable instructions.
Copying into a cloud agent does not make that agent local.

## Installation targets

| Platform | Standard package | Current boundary |
| --- | --- | --- |
| Windows x64 | Per-user NSIS `.exe`; MSI for managed deployment | Native build/install checks; Windows 11 device acceptance and signing remain release gates |
| Linux x64 | `.deb`, `.rpm`, `.AppImage` | Built against Ubuntu 22.04; other distributions and Wayland/X11 sessions require acceptance |
| macOS Apple silicon | Existing native app and PKG | Use the root Mac installation guide |
| Windows ARM, Linux ARM, Intel Mac | No validated download | Not advertised as supported until native build and device testing are recorded |
| iOS / iPadOS / Android | Not supported | This project ships desktop software, not a mobile app or keyboard |

The Windows installer includes the offline WebView2 installer. This makes it
larger, but it avoids downloading that prerequisite during setup. The speech
model is approximately 148 MB. Installed size and memory use are measured per
release, not described as negligible. Linux packages rely on distribution GTK,
WebKitGTK, and audio libraries; an air-gapped administrator must pre-stage those
prerequisites. AppImage is not a promise of support for every Linux distribution.

Offline WebView2 setup and the shared Evergreen runtime's ongoing update service
are separate boundaries. Managed environments must validate endpoint policy for
both. Windows packaging checks record the Microsoft-signed prerequisite's exact
identity and final installer hashes; see [the security boundary](SECURITY.md).

Normal use requires a microphone and the operating system's permission to use
it. There is no Accessibility, synthetic keyboard, remote-control, or shell
permission in this port. Another application can still select an exclusive
audio device or alter the default microphone; interoperability is tested rather
than assumed.

## Build from source

Use a native build host for the target OS, Node.js 22.15+, and Rust 1.94.1. Node is a
build tool, not an installed application dependency. These are repository npm
commands, not a claim that an end-user npm package has been published.

Windows needs Microsoft C++ Build Tools and its Windows SDK, CMake, Ninja, and
LLVM with `clang-cl` and libclang. The release wrapper selects clang-cl/Ninja
for native speech code while retaining the MSVC ABI and Rust target. Windows
C++ exception handling (`/EHsc`) is explicit in the release wrapper and the
target-scoped Cargo configuration, because the speech engine requires it.
The early compiler probe checks both exception support and source-path remapping.
Ubuntu 22.04
needs the packages recorded in [.github/workflows/desktop.yml](../.github/workflows/desktop.yml).
Start in the repository's `desktop` directory so Cargo reads the portable CPU
configuration.

```sh
npm ci --ignore-scripts --no-audit --no-fund
npm run icons
npm run provision:model
npm run inventory
npm test
cargo test --workspace --all-targets --locked
npm run build -- --ci
```

`provision:model` is the explicit, networked **build-time** step. It verifies an
immutable upstream revision, byte count, and SHA-256 digest. It never silently
replaces a mismatching model. A disconnected build can instead pre-stage the
exact reviewed model at `app/resources/models/ggml-base.en.bin` and run
`npm run verify:model`. No model download code is part of the application.

Linux x64 builds also fetch the three exact AppImage tool inputs pinned in
[`linux-packaging-tools.json`](linux-packaging-tools.json). The build verifies
their size, SHA-256 and architecture in a fresh private cache, then rechecks them
after packaging. It does not reuse or replace your existing Tauri tool cache.
An unavailable or changed upstream asset fails the build without accepting an
older fallback. This step requires build-time network access even with a
pre-staged model; it does not add an installed-app network dependency. See
[tool-input boundaries](SECURITY.md#appimage-build-tool-inputs).

Packages appear under `desktop/target/release/bundle`. Test packages are
unsigned: do not tell users to disable SmartScreen, Gatekeeper, or managed
endpoint policy. Public downloads require the release gates below.

MSI uses numeric installer version `0.5.0.1` for application preview
`0.5.0-alpha.1`, with a pinned upgrade code. Windows Installer compares only the
first three product-version fields for upgrades; do not assume a fourth-field
change provides upgrade ordering. The first production package must advance
that three-field version and pass upgrade/downgrade acceptance.

## Enterprise terminology

Open **Workspace terminology** and enter one correction per line:

```text
cube control = kubectl
jose = José
sri = Sree
```

These synthetic examples demonstrate explicit, whole-phrase corrections, not
model training or an automatic directory integration. Corrections are bounded,
applied once without cascading, and kept only for the current session. Import
only terms approved for the intended endpoint; there is no cloud vocabulary sync.

## Architecture and release evidence

See [architecture](ARCHITECTURE.md) and [security boundaries](SECURITY.md).
CI builds on native Windows and Linux runners, checks the dependency graph,
tests capture-state recovery, runs real synthetic recognition with network
access denied, and packages the app with its model, license notices, and
CycloneDX build inventory. A successful CI run is not physical-microphone or
supported-desktop acceptance.

For pull-request builds, record both the proposed head commit and the actual
checkout commit: CI normally tests GitHub's temporary merge with the base branch.
The embedded inventory and Windows input sidecar identify that actual checkout.
The current workflow retains packages and compliance files only for protected-main,
non-pull-request runs. A successful pull-request build log is therefore not a
retrievable package, checksum record, or completed payload/license reconciliation.
Release evidence must bind the retained package bytes and their inventories to
the source actually built.

Installer CI also performs silent NSIS/MSI and DEB installation/removal on
ephemeral native runners. It checks installed model and notice digests, Windows
executable branding, DEB executable integrity, and actual payload removal.
The DEB executable is checked against the independent build output with the
pinned packager's exact bundle-type marker substitution; all other bytes must
match. A successful package build alone does not satisfy this check.
These destructive test scripts
refuse ordinary local execution. They do not launch the app or grant microphone
access. MSI uses [standard Windows Installer quiet/no-restart options](https://learn.microsoft.com/en-us/windows/win32/msi/standard-installer-command-line-options);
its machine-wide deployment requires administrator rights, while NSIS defaults
to a per-user install.

For managed MSI deployments, supply an administrator-controlled `INSTALLDIR`
on installation and upgrades. The narrow [WiX fragment](app/windows/install-directory.wxs)
preserves that explicit destination across the upstream installer's remembered-path
lookup, including a directory retained after NSIS removal. It only sets installer
properties; it does not execute a script or change registry permissions. CI leaves
the NSIS preference intact and verifies that MSI uses the requested destination
without restoring payload into the former per-user folder. In-place changes
between installer formats and managed upgrade/rollback acceptance remain release
gates; do not deploy both formats side by side.

The developer-only `recognize_fixture` example accepts an optional repetition
count from 1 to 16. It reuses one loaded model, compares every result against a
synthetic expected-text fixture, and reports timing without printing transcripts.
This checks repeated inference, not microphone hardware or a production latency
guarantee. Do not use patient or other private recordings as test fixtures.

Before a public binary release, record:

1. Protected-branch review and all source, dependency, secret, and native build checks.
2. Windows Authenticode signing and timestamp verification; Linux package signatures
   and checksums, with an authenticated release manifest and artifact provenance.
3. Clean install, launch, upgrade, rollback policy, and uninstall on each supported OS.
4. Offline first launch and dictation with outbound traffic blocked, including
   operating-system webview behavior and missing-prerequisite handling.
5. Real microphones: built-in, USB, Bluetooth, permission denial, device removal,
   suspend/resume, and coexistence with Teams and another dictation application.
6. Long recordings, repeated start/stop, recognition failure and retry, no duplicate
   delivery, terminology, assistive technology, and measured latency/memory.
7. License-notice closure and package SBOM review, including native libraries and
   operating-system prerequisites beyond Cargo's dependency graph.

MIT permits individual and commercial use without a key or subscription.
Enterprise maintenance or deployment assistance can be separate services; they
do not revoke the open-source license. See [LICENSE](../LICENSE).
