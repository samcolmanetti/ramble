#!/bin/bash
# Probe what the Instamic exposes over BLE in a given device mode.
#
# Usage: Scripts/probe-mode.sh <mode-name> [seconds]
#
# Connects, dumps the full GATT inventory, and logs every notification for the
# duration. Run it once per device mode, then diff the logs to see which mode
# keeps the button events alive.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:?usage: probe-mode.sh <mode-name> [seconds]}"
SECS="${2:-45}"
LOG="captures/mode-${MODE}.log"

mkdir -p captures
swift build 2>&1 | tail -1

{
    echo "# mode: $MODE"
    echo "# date: $(date)"
    echo "# --- macOS audio devices ---"
    system_profiler SPAudioDataType 2>/dev/null | grep -E ':$|SampleRate|Transport|Default Input' | sed 's/^/# /'
    echo "# --- bluetooth classic ---"
    system_profiler SPBluetoothDataType 2>/dev/null | awk '/Connected:/,/Not Connected:/' | sed 's/^/# /'
    echo "# --- BLE ---"
} > "$LOG"

./.build/debug/ramble-sniff >> "$LOG" 2>&1 &
PID=$!
sleep "$SECS"
kill -INT $PID 2>/dev/null || true
wait $PID 2>/dev/null || true

echo "wrote $LOG"
