#!/bin/bash
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/homelab-common.sh" || exit 1
command -v smartctl >/dev/null || { echo 'smartctl is required' >&2; exit 1; }
result=0
for dev in "${SMART_DEVICES[@]}"; do
    # smartctl uses a bit mask: nonzero may indicate health problems or I/O errors.
    output=$(timeout 30 smartctl -H -j "$dev" 2>&1)
    rc=$?
    if ! python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("smart_status",{}).get("passed") is True else 1)' <<< "$output" 2>/dev/null || (( rc != 0 )); then
        result=1
        "$SCRIPT_DIR/discord-alert.sh" "🔴 SMART: $dev — health check failed or unavailable (exit $rc). Inspect: smartctl -a $dev" || echo "SMART alert delivery failed: $dev" >&2
    fi
done
exit "$result"
