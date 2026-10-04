# Desktop security and deployment boundary

Report vulnerabilities through the project's [security policy](../SECURITY.md),
without attaching recordings, patient data, names from a real directory, or
device logs containing private paths. Tests use synthetic speech and terminology.

## Data handling

The app processes speech with a bundled local model. It has no runtime model
downloader, external inference client, telemetry adapter, updater, account, or
inbound listener. Source checks enforce this boundary; deployed-device traffic
tests remain part of release acceptance. Operating-system services, WebView2 or
WebKit, crash reporting, clipboard managers, and the destination app are separate
components and must be covered by enterprise endpoint policy.

The Windows package contains Microsoft's **Evergreen offline installer**. Offline
setup does not turn Evergreen into a fixed, network-disabled runtime: its shared
runtime has a separate update service. The endpoint owner must manage that
service and validate blocked-network behavior, including WebView2 child
processes. LockedIn Flow does not disable another application's shared security
updates or modify system-wide Microsoft policies. See Microsoft's
[distribution and servicing guidance](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution).

The native build explicitly disables Whisper's curl, FFmpeg and example-server
features, ggml RPC, and dynamic backend loading. Cargo forces these values so
ordinary shell settings from another local-model project cannot enable them.
This is a build safeguard, not protection against someone modifying the source
or distributing a different executable.

Release compilation remaps private build paths. Windows native code uses
clang-cl with source-macro remapping and Ninja; CI first compiles a synthetic
narrow/wide `__FILE__` fixture in a directory containing spaces and rejects any
retained private prefix. Rust mappings cover both Windows separator forms.
Windows also sets the
[linker's alternate symbol path](https://learn.microsoft.com/en-us/cpp/build/reference/pdbaltpath-use-alternate-pdb-path)
to a filename without a host directory. Artifact checks still fail on any
detected home or checkout path; diagnostics report only the class of finding,
never the path or surrounding binary contents.

Recordings, transcripts, and session vocabulary are not intentionally persisted
by the application. Owned sensitive buffers are cleared on drop where supported.
This is not a guarantee of forensic erasure: the native inference library,
renderer, OS swap, process dumps, and clipboard may hold copies. Use full-disk
encryption, appropriate dump policies, screen-lock controls, and an approved
clipboard/destination configuration. Clearing the transcript does not erase a
previously copied clipboard item. The app never reads existing clipboard data.

The explicit Copy action requests Windows' exclusion from cloud clipboard and
history processing, and Linux's history-exclusion convention. These requests
are not access controls against third-party clipboard readers. Manual keyboard
copy through the OS webview is outside this adapter; enterprise clipboard policy
is still necessary. The native Swift Mac app has its separate local-only
pasteboard control.

The review-before-copy workflow is intentional. No focused-field detection is
needed to start a recording, so the Mac product's historical target-field error
cannot block this path. The app does not inspect passwords in other windows or
send keystrokes to them. Copy only into an approved destination; a cloud coding
agent can transmit pasted text even though recognition was local.

## Threats and controls

| Threat | Implemented control | Remaining boundary |
| --- | --- | --- |
| Substituted speech model | Pinned digest and size; verify exact decoder input | Endpoint administrator or compromised executable can replace controls |
| Renderer compromise | Local-only resources, strict content policy, three narrow commands | Framework and OS webview require ongoing patching |
| Unbounded capture or transcript | Five-minute audio cap, validated formats, transcript and vocabulary limits | CPU/memory vary by device; no hard real-time guarantee |
| Lost or duplicated result after retry | Single owner, generation checks, original audio retained on conversion or recognition failure | Process crash or OS shutdown can still lose in-memory audio |
| Data in diagnostics | Fixed application errors; no transcript logging; inference print hooks disabled | Third-party/native crash handling must be validated on the endpoint |
| Unauthorized device control | Microphone plus explicit clipboard write only | OS microphone access is still required and must be explained |
| Supply-chain compromise | Locked dependencies, source comparison, model digest, advisories, notices and SBOM | Signing and artifact provenance are required before public binary release |

This design supports evaluation in controlled healthcare workflows; it does not
establish HIPAA compliance, a certification, or a guarantee of no vulnerabilities.
No PHI is needed for build tests or acceptance. Broader organizational controls
and the chosen destination remain part of an enterprise deployment decision.

## Dependency findings

The GTK3 stack currently selects GLib's Rust 0.18 API. The source includes the
exact upstream two-line fix for **RUSTSEC-2024-0429**, with a checksum-pinned
source comparison and optimized Linux regression. See the
[backport provenance](vendor/glib/LOCKEDIN-PATCH.md). A path dependency may not
be assessed by a version-only advisory scanner, so both checks are mandatory;
an empty scanner report alone does not validate the backport.
The source verifier also queries the upstream crate's current OSV advisories;
any finding other than the exact backported defect fails that gate. Thus the
path override does not hide future advisories on the upstream crate.

**RUSTSEC-2024-0370:** `proc-macro-error` 1.0.4 is unmaintained and enters through
the GTK3 build-time macro stack. It is not a speech network service, but this
maintenance finding remains open. Reassess before each release and remove the
dependency when the framework supports a maintained replacement. It is not
silenced in the advisory command. Unknown unsoundness and vulnerability findings
fail the build.

The generated CycloneDX inventory describes Cargo's target/build graph, nested
whisper.cpp and ggml sources, model digest, source revision/state, lockfile
hashes, and Rust version. Native versions are read from the exact bundled CMake
sources, with the carrier archive checksum and source-tree fingerprints. The
carrier's repository revision is not presented as a standalone ggml commit.
These native components do not gain independent advisory coverage from a Cargo
scan; inspect upstream native security changes during release review. It is not a
complete inventory of the host OS. License notices include published dependency
license files, with separate model, native speech-backend, and embedded CPU
implementation attribution.
Inventory generation and artifact verification validate SPDX license syntax.
The license parser is a locked build-time dependency, not application code.
Simple legacy Cargo slash-separated alternatives are exported as `OR`, with the
original declaration retained in metadata; ambiguous syntax fails instead of
guessing license obligations. See the [Cargo license declaration reference](https://doc.rust-lang.org/cargo/reference/manifest.html#the-license-and-license-file-fields).
Syntax validation is not license compatibility approval or notice closure.
Release review must close missing notices and inventory native/system libraries
and the bundled WebView2 installer separately.

Distinguish declared system prerequisites from redistributed files. DEB/RPM
dependency declarations do not enumerate their payloads. AppImage is different:
the [pinned Tauri bundler](https://github.com/tauri-apps/tauri/blob/447fa9f3f993fe77724189e355078b38ce20baea/crates/tauri-bundler/src/bundle/linux/appimage/linuxdeploy.rs)
copies AppRun, conditionally copies WebKit helpers from the build host, and runs
the GTK deployment plugin even when media-framework bundling is disabled.
Neither Cargo metadata nor a list of installed build prerequisites proves the
final set of redistributed libraries or their notices. Inventory each exact
package's extracted files, map bundled components to their source/version and
applicable license material, and reconcile that material with the shipped notices.
Include installer/runtime components as well as application files; do not label
downloaded build tools as redistributed solely because they appear in a build log.

Windows CI now checks the offline prerequisite **before executing either app
installer**. It reads the exact WebView2 paths from the pinned bundler's generated
NSIS/WiX sources, validates timestamped Microsoft Authenticode signatures,
cross-checks file hashes, and rejects differing runtime inputs between formats.
`WINDOWS-PACKAGING-INPUTS.json` binds those input bytes and installer file version
to the final NSIS/MSI hashes and source commit. No local paths or raw certificate
subjects are exported. The file version identifies the installer executable;
it is not asserted to be the installed browser-engine version.

This is a separate build-input record, not a modification of the already embedded
Cargo SBOM, extraction proof for final installer contents, a Microsoft license
grant, or full native dependency closure. WebView2 is governed by Microsoft's
terms, not this project's MIT license. Its redistribution terms and the actual
installed runtime version remain part of release review. Reproduce the check on
a fresh native Windows build with `node scripts/verify-windows-prerequisites.mjs`;
it does not run the prerequisite or replace an existing evidence report.

### Linux package evidence tooling

After a reviewed native Linux build and the existing artifact verifier, run
`node scripts/verify-linux-packages.mjs` from `desktop/`. The build host must
already provide Node 22.15+, `dpkg-deb` and `rpm`.
The checker does not install tools, fetch dependencies, run package scripts,
install packages or execute their binaries. Native DEB, RPM and AppImage payload
checks have passed for the candidate documented in [validation evidence](../docs/validation.md).
Payload checks do not establish signing, license or installed-device acceptance.

It requires a clean checkout matching the staged Linux inventory and lockfile
hashes. It reads private snapshots of the final archives and queries DEB/RPM metadata.
For DEB, it validates the complete original decompressed tar stream returned by
`dpkg-deb --fsys-tarfile` and hashes regular files without extracting them to disk.
It never normalizes that stream: rewriting can silently discard a second archive
or trailing data. Accepted headers are USTAR or the ordinary GNU shape emitted by
the [pinned Tauri producer](https://github.com/tauri-apps/tauri/blob/447fa9f3f993fe77724189e355078b38ce20baea/crates/tauri-bundler/src/bundle/linux/debian.rs).
Its locked tar 0.4.46 uses [GNU header layout and deterministic Unix metadata](https://github.com/composefs/tar-rs/blob/fc459c149f83bf4daceaa52e17d351989002e1a9/src/header.rs):
zero owner/device numbers, empty owner names and GNU extension area, and 0644/0755
permission modes (directories 0755), without file-type bits in the mode field.
GNU time/offset/sparse fields are never interpreted as a USTAR path prefix.
Long-name/link extensions, PAX, sparse records and other GNU metadata shapes
remain unsupported/unverified. This is a narrow producer-shape contract, not
general GNU-tar support; synthetic header tests do not establish native acceptance.
The application, model and four compliance resources must match staged digests.
Input/archive size, entry count, member size
and tool runtime/output limits are enforced. Traversal, duplicate paths, special
files, privilege bits and unsupported extensions are rejected conservatively.
DEB and RPM links are rejected. AppImage supports only relative links that resolve
to an existing file or directory within its in-memory tree; absolute, escaping,
dangling, cyclic and through-nondirectory links are rejected.

`target/release/bundle/LINUX-PACKAGE-EVIDENCE.json` is created exclusively with
private file permissions; existing reports are not overwritten. It binds archive
hashes to the actual built-source revision. Archive paths and dependency strings
are represented by SHA-256 identifiers rather than raw text. Only allowlisted
product identities, bounded declared versions/architectures and fixed resource
labels are displayed. Reconcile identifiers privately against the exact archive;
do not publish raw file lists, dependency text or tool diagnostics by default.
Requirements declared by a package are not evidence of bundled libraries.
File hashes and ELF magic do not identify component versions or license terms;
those mappings and notice obligations remain explicitly unresolved.

RPM inspection validates original header boundaries and the declared cpio/gzip
payload, bounded decompression, and original newc entries. It does not rewrite
the archive through a format converter.

AppImage inspection locates the filesystem from the x86-64 type-2 ELF structure,
then reads the original SquashFS 4.0 metadata and file blocks in memory. Supported
compression is gzip or zstd, with bounded decompression, entry counts, file sizes,
metadata, nesting and link traversal. Extended attributes and special files are
unsupported and fail closed. Inode reachability, directory indexes, data blocks,
fragments, hard links and resolved symbolic links are checked before resource
comparison. The application and AppRun launcher must be executable. Since
linuxdeploy can patch or strip ELF files, the application reference comes from
the separately staged AppDir binary; the model and four compliance files retain
their independent build references. This is a staged-output comparison, not a
claim of reproducible compilation or trusted launcher/library provenance.
Never substitute `--appimage-extract`, which runs the supplied executable.

Control scripts, signatures, installed-device behavior and Windows input/license
closure remain outside this check. Exit 2 records partial evidence, not acceptance;
exit 1 means no report was recorded. Exit 0 means payload inspection only, not
license or release approval.

### AppImage build-tool inputs

The supported `npm run build` entry point pins the three x86-64 executables
downloaded by [Tauri CLI 2.12.0's bundler](https://github.com/tauri-apps/tauri/blob/447fa9f3f993fe77724189e355078b38ce20baea/crates/tauri-bundler/src/bundle/linux/appimage/linuxdeploy.rs):
AppRun, linuxdeploy and its AppImage output plugin. The manifest records exact
upstream release-asset IDs, URLs, byte lengths and SHA-256 digests. Even though
the plugin URL contains `continuous`, changed bytes cannot silently pass.
Updating a pin requires reviewing the new input and native packaging results.

Each Linux build uses a new private XDG cache rather than an existing user cache
or local tools directory. Only bounded HTTPS downloads from GitHub and its
allowlisted asset hosts are accepted, with redirect limits and a deadline.
All three inputs must verify before the bundler starts; a failed download is
not converted into an older plugin fallback. Tools are rechecked after the build
and only that temporary cache is removed. The cache directories are owner-only;
executable files retain mode 0755 because AppRun is copied into the package.

The bundler zeroes bytes 8–10 of linuxdeploy's AppImage marker. The wrapper checks
the original digest first, applies only that transformation, and verifies the
resulting digest after packaging. It never treats arbitrary modified downloads
as equivalent. AppRun and the output plugin must remain byte-for-byte unchanged.

These checks pin particular build inputs, not the entire operating system or
transitive build-tool execution. They do not establish publisher signatures,
hermetic builds, AppRun/license provenance, or native library attribution.
The installed CLI and its embedded GTK/GStreamer scripts remain governed by the
npm lockfile. Calling the upstream CLI directly bypasses this wrapper and is not
the supported release build path. Native validation of the new wrapper is pending.

### Exact host-file references

The checker also collects a separate, optional `hostReferences` section for
inspected ELF files other than the verified application. It queries the native
build host's installed dpkg database using a fixed command and compares complete
file bytes, not filenames, ELF build IDs or inferred dependencies. Its bounded
search reads only package-owned regular files under `/usr/lib`, `/usr/libexec`
and `/lib`; it does not walk arbitrary directories or execute those files.
Symlink files and resolved paths outside those roots are not followed. The
database must remain unchanged across collection. Byte, record and time limits
prevent an unbounded scan. Unreadable-file counts are explicit.

Each exact match carries hashes of the binary package/version/architecture,
source package/version and canonical system path. Package identity hashes use
UTF-8 `JSON.stringify(["binary-dpkg-v1", binaryName, version, architecture])` and
`JSON.stringify(["source-dpkg-v1", sourceName, sourceVersion])`, without trimming
or normalization. The full query result has its own SHA-256 digest. Raw database
text, paths, package names, versions and tool errors are not retained in the
public report. These identifiers support private reconciliation; they are not
a human-readable component inventory or proof of trusted package provenance.

Zero exact matches remain unmatched; multiple matches remain ambiguous. A
modified library cannot inherit attribution merely because its name or build ID
matches. A build ID [is not a file-content checksum](https://sourceware.org/binutils/docs/ld/Options.html#index-build-id).
The dpkg ownership/source fields are [installed-database observations](https://manpages.debian.org/bookworm/dpkg/dpkg-query.1.en.html),
not verification of the originating repository or package archive.

Where present, the owner's bounded `/usr/share/doc/<package>/copyright` file is
hashed separately. This is explicitly `host-file-hashed-not-retained`: the text
has not thereby been added to the installer, mapped to every bundled component,
or approved for redistribution. Missing or redirected notices stay unavailable.
Collector failure records only `host-reference-collection-failed`; it cannot
reuse another run's evidence. Report validation binds every reference to the
actual package and file hashes. Existing `componentMapping`, `licenseReview`
and release disposition remain unresolved even when exact host bytes match.
The first native collection returned unavailable, despite passing payload checks;
see [validation evidence](../docs/validation.md). The full installed database is
now tested before compilation, with fixed-category diagnostics. Valid UTF-8
documentation filenames no longer invalidate the database; malformed encoding
is rejected. Package identities and eligible runtime paths keep ASCII allowlists;
non-ASCII runtime paths cannot supply matches. Native confirmation is pending.
Synthetic tests and a single-package dpkg format check do not establish complete
AppImage attribution.

CI retains only a schema-validated, fixed JSON report for pull requests, including
failed/partial inspection results. Its acceptance step fails unless all three
payloads pass and report validation/retention succeeds. Binary-upload restrictions
are unchanged. A passing inspection still does not close the release gates above.

## Coexistence and support

This port opens the default input device only during a requested recording.
It does not install an audio driver or intercept global keys. That reduces
conflict opportunities; it does not prove compatibility with every driver,
exclusive-mode client, conferencing app, or desktop session. Do not advertise
Windows 10, ARM devices, arbitrary Linux distributions, or Intel Macs as tested
without platform-specific evidence.
