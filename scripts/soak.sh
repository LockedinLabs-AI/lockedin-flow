#!/bin/bash
# Soak test: N consecutive offline STT transcriptions in one long-lived process
# plus an RSS growth check. Catches model reload bugs, leaks, and instability.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RUNS="${1:-20}"
MAX_RSS_GROWTH_KB="${SOAK_MAX_RSS_GROWTH_KB:-262144}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if ! [[ "$RUNS" =~ ^[1-9][0-9]*$ ]]; then
    echo "SOAK ERROR: runs must be a positive integer"
    exit 2
fi
if ! [[ "$MAX_RSS_GROWTH_KB" =~ ^[0-9]+$ ]]; then
    echo "SOAK ERROR: SOAK_MAX_RSS_GROWTH_KB must be a non-negative integer"
    exit 2
fi

echo "==> Building diagnostic executable (debug-only commands)"
swift build -c debug --product lockedin-flow >/dev/null
BIN="$(swift build -c debug --show-bin-path)/lockedin-flow"

say -o "$WORK/test.aiff" "the quick brown fox jumps over the lazy dog"
afconvert -f WAVE -d LEI16@16000 -c 1 "$WORK/test.aiff" "$WORK/test.wav"

echo "==> Soak: $RUNS consecutive offline transcriptions in one app process"
set +e
OUT="$("$BIN" --selftest-stt-soak "$WORK/test.wav" "$RUNS" 2>&1)"
STATUS=$?
set -e
printf '%s\n' "$OUT"

if [ "$STATUS" -ne 0 ]; then
    echo "SOAK FAILED: long-lived app process exited with status $STATUS"
    exit 1
fi

FAILURES=0
BASELINE_RSS=""
FINAL_RSS=""
PEAK_RSS=0
for i in $(seq 1 "$RUNS"); do
    LINE="$(printf '%s\n' "$OUT" | awk -F: -v run="$i" '$1 == "SOAK-RUN" && $2 == run { print; exit }')"
    LOWER_LINE="$(printf '%s' "$LINE" | tr '[:upper:]' '[:lower:]')"
    RSS="$(printf '%s\n' "$LINE" | awk -F: '{ print $4 }')"

    if [[ "$LOWER_LINE" != *"quick brown fox"* ]]; then
        echo "  run $i FAILED: expected phrase was not transcribed"
        FAILURES=$((FAILURES + 1))
    fi

    if ! [[ "$RSS" =~ ^[1-9][0-9]*$ ]]; then
        echo "  run $i FAILED: app RSS measurement is unavailable"
        FAILURES=$((FAILURES + 1))
        continue
    fi

    if [ -z "$BASELINE_RSS" ]; then BASELINE_RSS="$RSS"; fi
    FINAL_RSS="$RSS"
    if [ "$RSS" -gt "$PEAK_RSS" ]; then PEAK_RSS="$RSS"; fi
    printf "  run %d/%d ok (app rss: %s KB)\n" "$i" "$RUNS" "$RSS"
done

if [ -n "$BASELINE_RSS" ] && [ -n "$FINAL_RSS" ]; then
    GROWTH_RSS=$((FINAL_RSS - BASELINE_RSS))
    printf "==> App RSS: first=%s KB peak=%s KB final=%s KB growth=%+d KB\n" \
        "$BASELINE_RSS" "$PEAK_RSS" "$FINAL_RSS" "$GROWTH_RSS"
    if [ "$GROWTH_RSS" -gt "$MAX_RSS_GROWTH_KB" ]; then
        echo "SOAK FAILED: app RSS growth exceeded ${MAX_RSS_GROWTH_KB} KB"
        FAILURES=$((FAILURES + 1))
    fi
fi

if [ "$FAILURES" -gt 0 ]; then
    echo "SOAK FAILED: $FAILURES check(s) failed"
    exit 1
fi
echo "==> Soak passed: $RUNS/$RUNS consecutive offline transcriptions"
