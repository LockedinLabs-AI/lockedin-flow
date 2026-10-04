#!/bin/bash
# Create an unsigned, no-script component PKG for deployment-path evaluation.
# This is not a Developer ID signed/notarized production installer.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${LOCKEDIN_EVALUATION_PKG_OUTPUT:-$ROOT/build/LockedIn-Flow-evaluation-unsigned.pkg}"
SKIP_BUILD=0

if [ "${1:-}" = "--skip-build" ]; then
    SKIP_BUILD=1
    shift
fi
if [ "$#" -ne 0 ]; then
    echo "Usage: scripts/package-evaluation-pkg.sh [--skip-build]" >&2
    exit 64
fi
case "$OUTPUT" in
    /*.pkg) ;;
    *)
        echo "ERROR: LOCKEDIN_EVALUATION_PKG_OUTPUT must be an absolute .pkg path." >&2
        exit 64
        ;;
esac

if [ "$SKIP_BUILD" -eq 0 ]; then
    "$ROOT/scripts/package-app.sh"
fi

APP="$ROOT/build/LockedIn Flow.app"
if [ ! -d "$APP" ]; then
    echo "ERROR: packaged app not found: $APP" >&2
    exit 1
fi
codesign --verify --deep --strict --verbose=2 "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
if [ "$IDENTIFIER" != "ai.lockedin.flow.community" ]; then
    echo "ERROR: unexpected bundle identifier: $IDENTIFIER" >&2
    exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lockedin-evaluation-pkg.XXXXXX")"
cleanup() {
    rm -rf -- "$WORK"
}
trap cleanup EXIT

PAYLOAD_ROOT="$WORK/root"
mkdir -p "$PAYLOAD_ROOT/Applications" "$(dirname "$OUTPUT")"
ditto --noextattr --norsrc "$APP" "$PAYLOAD_ROOT/Applications/LockedIn Flow.app"
codesign --verify --deep --strict --verbose=2 \
    "$PAYLOAD_ROOT/Applications/LockedIn Flow.app"

pkgbuild \
    --root "$PAYLOAD_ROOT" \
    --component-plist "$ROOT/distribution/app-component.plist" \
    --identifier "ai.lockedin.flow.community.pkg" \
    --version "$VERSION" \
    --install-location / \
    --ownership recommended \
    "$OUTPUT"

EXPANDED="$WORK/expanded"
pkgutil --expand "$OUTPUT" "$EXPANDED"
if find "$EXPANDED" -type d -name Scripts -print -quit | grep -q .; then
    echo "ERROR: evaluation package unexpectedly contains installer scripts." >&2
    exit 1
fi
PAYLOAD_FILES="$WORK/payload-files"
pkgutil --payload-files "$OUTPUT" > "$PAYLOAD_FILES"
grep -Fq 'Applications/LockedIn Flow.app/Contents/MacOS/LockedInFlow' \
    "$PAYLOAD_FILES"

echo "Unsigned, no-script evaluation package: $OUTPUT"
echo "Production release still requires Developer ID Installer signing, notarization, stapling, and installed acceptance."
