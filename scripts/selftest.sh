#!/bin/bash
# End-to-end self-test: synthesize speech locally, transcribe it offline,
# and verify text insertion into TextEdit. No microphone required.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

WORK="$(mktemp -d)"
TEST_DOC_NAME=""

cleanup() {
    if [[ -n "$TEST_DOC_NAME" ]]; then
        osascript - "$TEST_DOC_NAME" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
    set testDocumentName to item 1 of argv
    tell application "TextEdit"
        repeat with candidateDocument in documents
            if (name of candidateDocument as text) is testDocumentName then
                set documentText to text of candidateDocument
                if documentText is "" or documentText is "LockedIn Flow insertion test" or documentText is "LockedIn Flow insertion test\n" then
                    close candidateDocument saving no
                end if
                exit repeat
            end if
        end repeat
    end tell
end run
APPLESCRIPT
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "==> Building diagnostic executable (debug-only commands)"
swift build -c debug --product lockedin-flow
BIN_DIR="$(swift build -c debug --show-bin-path)"
BIN="$BIN_DIR/lockedin-flow"

PHRASE="the quick brown fox jumps over the lazy dog"
echo "==> Synthesizing speech: \"$PHRASE\""
say -o "$WORK/test.aiff" "$PHRASE"
afconvert -f WAVE -d LEI16@16000 -c 1 "$WORK/test.aiff" "$WORK/test.wav"

echo "==> Transcribing offline (requires the reviewed model bundle to be provisioned first)"
TRANSCRIPT="$("$BIN" --selftest-stt "$WORK/test.wav" | tee /dev/stderr | awk '/^TRANSCRIPT:/{flag=1;next}flag' | tr 'A-Z' 'a-z')"

for word in quick brown fox lazy dog; do
    if [[ "$TRANSCRIPT" != *"$word"* ]]; then
        echo "SELFTEST FAIL: transcript missing '$word'"
        exit 1
    fi
done
echo "==> STT self-test passed"

echo "==> Insertion test (requires Accessibility permission for the terminal)"
TEST_DOC_NAME="$(osascript <<'APPLESCRIPT'
tell application "TextEdit"
    activate
    set testDocument to make new document
    return name of testDocument as text
end tell
APPLESCRIPT
)"

# TextEdit may be frontmost before its new editor exposes an AX focused element.
# Wait for the exact non-secure text area instead of racing launch with a fixed
# sleep; never retry insertion itself because an unverified first paste could
# otherwise be duplicated.
AX_READY=0
for readiness_attempt in {1..40}; do
    AX_ROLE="$(osascript <<'APPLESCRIPT' 2>/dev/null || true
tell application "System Events"
    tell process "TextEdit"
        if frontmost is false then return "not-frontmost"
        set focusedElement to value of attribute "AXFocusedUIElement"
        return role of focusedElement as text
    end tell
end tell
APPLESCRIPT
)"
    if [ "$AX_ROLE" = "AXTextArea" ]; then
        AX_READY=1
        break
    fi
    sleep 0.1
done
if [ "$AX_READY" != "1" ]; then
    echo "SELFTEST FAIL: TextEdit did not expose a focused text area for insertion"
    exit 1
fi
"$BIN" --insert-text "LockedIn Flow insertion test" || {
    echo "SELFTEST FAIL: insertion failed (Accessibility trust may be missing) — see output above"
    exit 1
}
sleep 1
CONTENT="$(osascript - "$TEST_DOC_NAME" <<'APPLESCRIPT'
on run argv
    set testDocumentName to item 1 of argv
    tell application "TextEdit"
        repeat with candidateDocument in documents
            if (name of candidateDocument as text) is testDocumentName then
                return text of candidateDocument
            end if
        end repeat
    end tell
    return ""
end run
APPLESCRIPT
)"
if [[ "$CONTENT" == *"LockedIn Flow insertion test"* ]]; then
    echo "==> Insertion self-test passed"
else
    echo "INSERTION FAILED: TextEdit did not contain the inserted text"
    exit 1
fi
