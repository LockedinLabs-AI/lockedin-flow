#!/bin/bash
# Build the ad-hoc signed LockedIn Flow bundle for source evaluation.
# This is not the official Developer ID signed and notarized release path.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

"$ROOT/scripts/verify-build-toolchain.sh"

OUTPUT_DIR="${LOCKEDIN_PACKAGE_OUTPUT_DIR:-$ROOT/build}"
case "$OUTPUT_DIR" in
    /*) ;;
    *)
        echo "ERROR: LOCKEDIN_PACKAGE_OUTPUT_DIR must be absolute." >&2
        exit 1
        ;;
esac

CURRENT_HEAD="$(git rev-parse HEAD)"
SOURCE_STATE="clean"
if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
    SOURCE_STATE="modified"
fi

echo "==> Building release executable from resolved dependencies"
swift build -c release --product lockedin-flow --force-resolved-versions
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="$OUTPUT_DIR/LockedIn Flow.app"
EXECUTABLE="$APP/Contents/MacOS/LockedInFlow"
mkdir -p "$OUTPUT_DIR"
rm -rf -- "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/lockedin-flow" "$EXECUTABLE"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
PLIST="$APP/Contents/Info.plist"
test "$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$PLIST")" \
    = "ai.lockedin.flow.community"
test "$(/usr/libexec/PlistBuddy -c "Print :CFBundleName" "$PLIST")" \
    = "LockedIn Flow"
test "$(/usr/libexec/PlistBuddy -c "Print :CFBundleDisplayName" "$PLIST")" \
    = "LockedIn Flow"
test "$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$PLIST")" \
    = "LockedInFlow"
for updater_key in SUEnableAutomaticChecks SUFeedURL SUPublicEDKey; do
    if /usr/libexec/PlistBuddy -c "Print :$updater_key" "$PLIST" >/dev/null 2>&1; then
        echo "ERROR: LockedIn Flow bundle must not contain $updater_key." >&2
        exit 1
    fi
done

echo "==> Creating icon"
ICONSET="$OUTPUT_DIR/AppIcon.iconset"
rm -rf -- "$ICONSET"
mkdir -p "$ICONSET"
cp "$ROOT/branding/raster/icon-16.png" "$ICONSET/icon_16x16.png"
cp "$ROOT/branding/raster/icon-32.png" "$ICONSET/icon_16x16@2x.png"
cp "$ROOT/branding/raster/icon-32.png" "$ICONSET/icon_32x32.png"
cp "$ROOT/branding/raster/icon-64.png" "$ICONSET/icon_32x32@2x.png"
cp "$ROOT/branding/raster/icon-128.png" "$ICONSET/icon_128x128.png"
cp "$ROOT/branding/raster/icon-256.png" "$ICONSET/icon_128x128@2x.png"
cp "$ROOT/branding/raster/icon-256.png" "$ICONSET/icon_256x256.png"
cp "$ROOT/branding/raster/icon-512.png" "$ICONSET/icon_256x256@2x.png"
cp "$ROOT/branding/raster/icon-512.png" "$ICONSET/icon_512x512.png"
cp "$ROOT/branding/raster/icon-1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf -- "$ICONSET"

echo "==> Copying runtime frameworks and notices"
shopt -s nullglob
for framework in "$BIN_DIR"/*.framework; do
    framework_name="$(basename "$framework" .framework)"
    if otool -L "$EXECUTABLE" | grep -Fq "/$framework_name.framework/"; then
        cp -R "$framework" "$APP/Contents/Frameworks/"
    fi
done
for localization in "$ROOT"/Vendor/KeyboardShortcuts/Sources/KeyboardShortcuts/Localization/*.lproj; do
    cp -R "$localization" "$APP/Contents/Resources/"
done
shopt -u nullglob

LICENSES_DIR="$APP/Contents/Resources/Licenses"
mkdir -p "$LICENSES_DIR/FluidAudio-ThirdParty"
cp "$ROOT/.build/checkouts/FluidAudio/LICENSE" "$LICENSES_DIR/FluidAudio-Apache-2.0.txt"
cp -R "$ROOT/.build/checkouts/FluidAudio/ThirdPartyLicenses/." "$LICENSES_DIR/FluidAudio-ThirdParty/"
cp "$ROOT/Vendor/KeyboardShortcuts/LICENSE" "$LICENSES_DIR/KeyboardShortcuts-MIT.txt"
cp "$ROOT/ThirdPartyLicenses/Silero-VAD-MIT.txt" "$LICENSES_DIR/Silero-VAD-MIT.txt"
cp "$ROOT/docs/model-licenses.md" "$LICENSES_DIR/Model-Attributions.md"
cp "$ROOT/LICENSE" "$LICENSES_DIR/LockedIn-Flow-MIT.txt"
cp "$ROOT/NOTICE" "$LICENSES_DIR/NOTICE.txt"

echo "==> Generating CycloneDX SBOM"
SBOM="$APP/Contents/Resources/SBOM.cdx.json"
"$ROOT/scripts/generate-sbom.sh" \
    --root "$ROOT" \
    --output "$SBOM" \
    --source-revision "$CURRENT_HEAD" \
    --source-state "$SOURCE_STATE"
"$ROOT/scripts/validate-sbom.sh" "$SBOM"
"$ROOT/scripts/verify-production-binary.sh" "$EXECUTABLE"

echo "==> Recording build provenance"
PROVENANCE="$APP/Contents/Resources/BUILD-PROVENANCE.txt"
PACKAGE_RESOLVED_SHA="$(shasum -a 256 "$ROOT/Package.resolved" | awk '{print $1}')"
SBOM_SHA="$(shasum -a 256 "$SBOM" | awk '{print $1}')"
MODEL_ARTIFACTS_SHA="$(shasum -a 256 "$ROOT/security/model-artifacts.tsv" | awk '{print $1}')"
MODEL_SOURCES_SHA="$(shasum -a 256 "$ROOT/security/model-sources.tsv" | awk '{print $1}')"
{
    printf 'source-revision: %s\n' "$CURRENT_HEAD"
    printf 'source-state: %s\n' "$SOURCE_STATE"
    printf 'package-resolved-sha256: %s\n' "$PACKAGE_RESOLVED_SHA"
    printf 'sbom-sha256: %s\n' "$SBOM_SHA"
    printf 'model-artifacts-sha256: %s\n' "$MODEL_ARTIFACTS_SHA"
    printf 'model-sources-sha256: %s\n' "$MODEL_SOURCES_SHA"
    printf 'runner-image-os: %s\n' "${ImageOS:-local}"
    printf 'runner-image-version: %s\n' "${ImageVersion:-local}"
    printf 'built-at-utc: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    xcodebuild -version
    swift --version
} > "$PROVENANCE"

echo "==> Applying local ad-hoc signature"
codesign --force --options runtime --sign - --entitlements "$ROOT/entitlements.plist" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Isolated local evaluation bundle: $APP"
