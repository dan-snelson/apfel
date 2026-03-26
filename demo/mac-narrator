#!/bin/bash
# mac-narrator — your Mac's inner monologue, powered by Apple Intelligence
#
# One-shot:  mac-narrator
# Watch:     mac-narrator --watch
#            mac-narrator --watch --interval 30
#
# Requires: apfel installed (https://github.com/Arthur-Ficial/apfel)

INTERVAL=60
WATCH=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --watch|-w)    WATCH=true; shift ;;
        --interval|-i) INTERVAL="$2"; shift 2 ;;
        -h|--help)
            echo "mac-narrator — your Mac's inner monologue"
            echo ""
            echo "Usage: mac-narrator [--watch [--interval N]]"
            echo ""
            echo "  --watch, -w        Continuous mode (default: every 60s)"
            echo "  --interval N, -i N  Seconds between narrations"
            echo ""
            echo "Requires: apfel (Apple Intelligence CLI)"
            exit 0
            ;;
        *) echo "Unknown option: $1. Use --help."; exit 1 ;;
    esac
done

# Check apfel is installed
if ! command -v apfel &>/dev/null; then
    echo "Error: apfel not found. Install from https://github.com/Arthur-Ficial/apfel"
    exit 1
fi

PROMPT="You narrate this computer's life like a nature documentary. Given system data, respond with EXACTLY 1-2 short sentences. Be specific about process names and numbers. Dry British humor. No bullet points, no lists."

narrate() {
    local snapshot
    snapshot=$(
        ps -eo pid,%cpu,%mem,comm -r 2>/dev/null | head -8
        echo "---"
        memory_pressure 2>/dev/null | head -3
        echo "---"
        df -h / 2>/dev/null | tail -1
        echo "---"
        pmset -g batt 2>/dev/null | tail -1
        echo "---"
        uptime 2>/dev/null
    )

    # Collapse to single line for clean argument passing
    local oneline
    oneline=$(echo "$snapshot" | tr '\n' '; ')

    local comment
    if comment=$(apfel -q --max-tokens 150 -s "$PROMPT" "System snapshot: $oneline"); then
        echo -e "\033[90m[$(date +%H:%M:%S)]\033[0m $comment"
    else
        echo -e "\033[90m[$(date +%H:%M:%S)]\033[0m \033[33m(model busy, skipping)\033[0m"
    fi
}

if $WATCH; then
    echo -e "\033[36m🍎 mac-narrator\033[0m watching every ${INTERVAL}s (Ctrl+C to stop)"
    echo ""
    while true; do
        narrate
        echo ""
        sleep "$INTERVAL"
    done
else
    narrate
fi
