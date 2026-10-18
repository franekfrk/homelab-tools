#!/bin/bash
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/homelab-common.sh" || exit 1
BAT_PATH=$(battery_path) || { echo 'No readable battery found' >&2; exit 1; }
SAVED_DONE=false
while true; do
    CAPACITY=$(cat "$BAT_PATH/capacity")
    STATUS=$(cat "$BAT_PATH/status")
    if ! is_uint "$CAPACITY" || (( CAPACITY > 100 )) || [[ -z "$STATUS" ]]; then
        echo 'Cannot read valid battery status' >&2
        sleep "$POLL_SECONDS"
        continue
    fi
    if [[ "$STATUS" == Discharging ]]; then
        if (( CAPACITY <= BATTERY_SHUTDOWN )); then
            safe_shutdown && exit 0
            echo 'Shutdown failed; will retry' >&2
        elif (( CAPACITY <= BATTERY_SAVE )) && [[ "$SAVED_DONE" == false ]]; then
            if save_world; then SAVED_DONE=true; fi
        fi
    else
        SAVED_DONE=false
    fi
    sleep "$POLL_SECONDS"
done
