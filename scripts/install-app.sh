#!/bin/bash
# Build and install LockedIn Flow for local evaluation with an ad-hoc signature.
# Official and managed distribution must use the Developer ID signed,
# notarized package described in docs/managed-deployment.md.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="$HOME/Applications/LockedIn Flow.app"
REPLACE=0
LAUNCH=0
SKIP_BUILD=0

usage() {
    cat <<'EOF'
Usage: scripts/install-app.sh [options]

Options:
  --destination <absolute.app>  Install location (default: ~/Applications)
  --replace                     Preserve the existing app as a timestamped backup
  --launch                      Open the app after verification
  --skip-build                  Install the existing build/ app bundle
  --help                        Show this help
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --destination)
            [ "$#" -ge 2 ] || { echo "ERROR: --destination needs a value." >&2; exit 64; }
            DESTINATION="$2"
            shift 2
            ;;
        --replace)
            REPLACE=1
            shift
            ;;
        --launch)
            LAUNCH=1
            shift
            ;;
        --skip-build)
            SKIP_BUILD=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown option: $1" >&2
            usage >&2
            exit 64
            ;;
    esac
done

case "$DESTINATION" in
    /*.app) ;;
    *)
        echo "ERROR: destination must be an absolute path ending in .app." >&2
        exit 64
        ;;
esac

if [ "$SKIP_BUILD" -eq 0 ]; then
    "$ROOT/scripts/package-app.sh"
fi

SOURCE_APP="$ROOT/build/LockedIn Flow.app"
if [ ! -d "$SOURCE_APP" ]; then
    echo "ERROR: packaged app not found: $SOURCE_APP" >&2
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "$SOURCE_APP"
SOURCE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_APP/Contents/Info.plist")"
if [ "$SOURCE_ID" != "ai.lockedin.flow.community" ]; then
    echo "ERROR: unexpected bundle identifier: $SOURCE_ID" >&2
    exit 1
fi

DESTINATION_PARENT="$(dirname "$DESTINATION")"
mkdir -p "$DESTINATION_PARENT"
STAGING_DIRECTORY="$(mktemp -d "$DESTINATION_PARENT/.lockedin-flow-install.XXXXXX")"
STAGED_APP="$STAGING_DIRECTORY/LockedIn Flow.app"
BACKUP=""

cleanup() {
    rm -rf -- "$STAGING_DIRECTORY"
}
trap cleanup EXIT

ditto "$SOURCE_APP" "$STAGED_APP"
codesign --verify --deep --strict --verbose=2 "$STAGED_APP"

if [ -e "$DESTINATION" ]; then
    if [ "$REPLACE" -ne 1 ]; then
        echo "ERROR: an app already exists at $DESTINATION" >&2
        echo "Re-run with --replace to preserve it as a backup before installing." >&2
        exit 1
    fi
    TIMESTAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
    BACKUP="${DESTINATION%.app}.previous-$TIMESTAMP.app"
    if [ -e "$BACKUP" ]; then
        echo "ERROR: backup destination already exists: $BACKUP" >&2
        exit 1
    fi
    mv "$DESTINATION" "$BACKUP"
fi

if ! mv "$STAGED_APP" "$DESTINATION"; then
    if [ -n "$BACKUP" ] && [ ! -e "$DESTINATION" ]; then
        mv "$BACKUP" "$DESTINATION"
    fi
    echo "ERROR: app installation failed." >&2
    exit 1
fi

if ! codesign --verify --deep --strict --verbose=2 "$DESTINATION"; then
    mv "$DESTINATION" "$STAGED_APP"
    if [ -n "$BACKUP" ]; then
        mv "$BACKUP" "$DESTINATION"
    fi
    echo "ERROR: installed app did not pass signature verification." >&2
    exit 1
fi

echo "Installed local evaluation app: $DESTINATION"
if [ -n "$BACKUP" ]; then
    echo "Preserved previous app: $BACKUP"
fi
if [ "$LAUNCH" -eq 1 ]; then
    open "$DESTINATION"
fi
