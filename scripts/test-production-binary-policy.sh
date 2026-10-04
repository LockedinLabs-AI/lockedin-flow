#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERIFY="$ROOT/scripts/verify-production-binary.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lockedin-binary-policy.XXXXXX")"
cleanup() {
    rm -rf -- "$WORK"
}
trap cleanup EXIT

pass_count=0
fail() {
    echo "FAIL: $1" >&2
    exit 1
}
pass() {
    pass_count=$((pass_count + 1))
}

# The production target owns an explicit compile-time condition that is only
# enabled for SwiftPM debug configuration.
/usr/bin/grep -Fq \
    '.define("LOCKEDIN_INTERNAL_DIAGNOSTICS", .when(configuration: .debug))' \
    "$ROOT/Package.swift" \
    || fail "internal diagnostics condition is not debug-only"
pass

first_source_line="$(/usr/bin/awk 'NF { print; exit }' "$ROOT/Sources/LockedInFlowApp/SelfTest.swift")"
[ "$first_source_line" = '#if LOCKEDIN_INTERNAL_DIAGNOSTICS' ] \
    || fail "SelfTest implementation is not fully compile-guarded"
last_source_line="$(/usr/bin/awk 'NF { line=$0 } END { print line }' "$ROOT/Sources/LockedInFlowApp/SelfTest.swift")"
[ "$last_source_line" = '#endif' ] \
    || fail "SelfTest compile guard does not cover the complete file"
pass

# NSWorkspace explicitly delivers application lifecycle notifications through
# its own notification center. Registering this event on the default center
# silently leaves the insertion target stuck on the app active at launch.
/usr/bin/awk '
    /NSWorkspace\.shared\.notificationCenter\.addObserver\(/ { workspace_center = NR }
    /forName: NSWorkspace\.didActivateApplicationNotification/ {
        if (workspace_center > 0 && NR - workspace_center <= 6) found = 1
    }
    END { exit(found ? 0 : 1) }
' "$ROOT/Sources/LockedInFlowApp/AppState.swift" \
    || fail "workspace activation is not observed on the NSWorkspace notification center"
pass

if /usr/bin/awk '
    /NotificationCenter\.default\.addObserver\(/ { default_center = NR }
    /forName: NSWorkspace\.didActivateApplicationNotification/ {
        if (default_center > 0 && NR - default_center <= 6) bad = 1
    }
    END { exit(bad ? 0 : 1) }
' "$ROOT/Sources/LockedInFlowApp/AppState.swift"; then
    fail "workspace activation incorrectly uses the default notification center"
fi
pass

/usr/bin/grep -Fq \
    '@Published private(set) var profileOverrideID' \
    "$ROOT/Sources/LockedInFlowApp/AppState.swift" \
    || fail "profile override can bypass the validated setter"
/usr/bin/grep -Fq \
    'ForEach(state.availableProfiles)' \
    "$ROOT/Sources/LockedInFlowApp/SettingsView.swift" \
    || fail "release profile picker does not use the gated profile list"
pass

/usr/bin/awk '
    /#if LOCKEDIN_INTERNAL_DIAGNOSTICS/ { guarded = 1; next }
    /#endif/ { guarded = 0; next }
    /SelfTest\.runIfRequested\(\)/ && guarded { found = 1 }
    END { exit(found ? 0 : 1) }
' "$ROOT/Sources/LockedInFlowApp/LockedInFlowApp.swift" \
    || fail "application diagnostic entry point is not compile-guarded"
pass

/usr/bin/grep -Fq \
    '"$ROOT/scripts/verify-production-binary.sh" "$EXECUTABLE"' \
    "$ROOT/scripts/package-app.sh" \
    || fail "application packaging does not invoke the production binary gate"
pass

/usr/bin/grep -Fq \
    '"$ROOT/scripts/verify-build-toolchain.sh"' \
    "$ROOT/scripts/package-app.sh" \
    || fail "application packaging does not enforce the pinned release toolchain"
pass

for expected_toolchain_value in \
    'EXPECTED_XCODE_VERSION="26.6"' \
    'EXPECTED_XCODE_BUILD="17F113"' \
    'EXPECTED_SWIFT_VERSION="6.3.3"' \
    'EXPECTED_MACOS_SDK_VERSION="26.5"'; do
    /usr/bin/grep -Fq "$expected_toolchain_value" \
        "$ROOT/scripts/verify-build-toolchain.sh" \
        || fail "release toolchain verifier is missing $expected_toolchain_value"
    pass
done

/usr/bin/grep -Fq \
    'run: scripts/verify-build-toolchain.sh' \
    "$ROOT/.github/workflows/ci.yml" \
    || fail "CI does not enforce the pinned release toolchain"
pass

# Operational STT checks rely on CLI entry points that are intentionally absent
# from production. They must build the debug target explicitly rather than
# silently launching a release app that cannot recognize the requested command.
for diagnostic_script in selftest.sh soak.sh; do
    /usr/bin/grep -Fq \
        'swift build -c debug --product lockedin-flow' \
        "$ROOT/scripts/$diagnostic_script" \
        || fail "$diagnostic_script does not build the debug diagnostics target"
    pass

    /usr/bin/grep -Fq \
        'swift build -c debug --show-bin-path' \
        "$ROOT/scripts/$diagnostic_script" \
        || fail "$diagnostic_script does not execute the debug diagnostics target"
    pass

    if /usr/bin/grep -Fq \
        'swift build -c release' \
        "$ROOT/scripts/$diagnostic_script"; then
        fail "$diagnostic_script requests diagnostics from a production build"
    fi
    pass
done

# Application source must not invoke FluidAudio's model-download APIs. The
# dependency still links general-purpose model-hub code, so its fallback must
# also stay offline in production.
if /usr/bin/grep -R -E \
    'AsrModels\.download|downloadAndLoad\(|loadModels\([[:space:]]*to:' \
    "$ROOT/Sources/SpeechEngine"; then
    fail "SpeechEngine references a mutable FluidAudio model-download API"
fi
pass

/usr/bin/grep -Fq \
    'ModelHub.offlineMode = true' \
    "$ROOT/Sources/SpeechEngine/SpeechModels.swift" \
    || fail "FluidAudio network fallback is not forced offline"
pass

if /usr/bin/grep -R -Fq 'Sparkle' "$ROOT/Package.swift" "$ROOT/Sources"; then
    fail "LockedIn Flow source unexpectedly links or references the updater framework"
fi
pass

# Unit-test every release signature, including marker strings that catch a
# compiler representation where an argument literal is not independently
# visible to strings(1).
FORBIDDEN_SIGNATURES=(
    "--render-marketing-preview"
    "--selftest-stt"
    "--selftest-stt-soak"
    "--selftest-stt-unified"
    "--selftest-vad"
    "--selftest-live-capture"
    "--selftest-capture-preflight"
    "--insert-text"
    "--insert-diagnostics"
    "--insert-from-home"
    "SELFTEST-ERROR:"
    "LIVE-CAPTURE:"
    "LIVE-TRANSCRIPT:"
    "MARKETING-PREVIEW:"
    "INSERT-ERROR:"
    "INSERTED:"
    "PREFLIGHT-ERROR:"
    "PREFLIGHT-OK:"
)
for signature in "${FORBIDDEN_SIGNATURES[@]}"; do
    fixture="$WORK/forbidden-$pass_count"
    /usr/bin/printf 'Mach-O fixture\n%s\n' "$signature" > "$fixture"
    if "$VERIFY" "$fixture" > /dev/null 2>&1; then
        fail "verifier accepted forbidden signature: $signature"
    fi
    pass
done

/usr/bin/printf 'Mach-O fixture\nordinary production content\n' > "$WORK/clean"
"$VERIFY" "$WORK/clean" > /dev/null \
    || fail "verifier rejected a clean fixture"
pass

echo "$pass_count production binary policy tests passed."
