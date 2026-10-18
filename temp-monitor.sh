#!/bin/bash
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/homelab-common.sh" || exit 1
SAVED_DONE=false
while true; do
    if ! TEMP=$(max_temperature); then
        echo 'No readable temperature sensor' >&2
        sleep "$POLL_SECONDS"
        continue
    fi
    if (( TEMP >= TEMP_SHUTDOWN )); then
        safe_shutdown && exit 0
        echo 'Shutdown failed; will retry' >&2
    elif (( TEMP >= TEMP_SAVE )) && [[ "$SAVED_DONE" == false ]]; then
        if save_world; then SAVED_DONE=true; fi
    fi
    if (( TEMP < TEMP_SAVE - 5 )); then SAVED_DONE=false; fi
    sleep "$POLL_SECONDS"
done
