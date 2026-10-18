#!/bin/bash
# Shared configuration and bounded Docker operations. Source from sibling scripts.
CONFIG_FILE=${HOMELAB_CONFIG:-/etc/homelab-alerts.conf}
ENABLED=true
WEBHOOK_URL=""
HC_URL=""
STATE_DIR=/var/lib/homelab-alerts
MC_CONTAINER=minecraft
MC_HOST=127.0.0.1
MC_PORT=25565
PIHOLE_CONTAINER=pihole
PIHOLE_DNS_HOST=127.0.0.1
DNS_TEST_NAME=example.com
SMART_DEVICES=(/dev/sda /dev/sdb)
POWER_SUPPLY_ROOT=/sys/class/power_supply
THERMAL_ROOT=/sys/class/thermal
BATTERY_WARN=30
BATTERY_SAVE=25
BATTERY_SHUTDOWN=20
TEMP_WARN=75
TEMP_SAVE=70
TEMP_SHUTDOWN=80
DISK_WARN=85
POLL_SECONDS=30
DOCKER_TIMEOUT=60
SAVE_TIMEOUT=15
STOP_TIMEOUT=30
[[ ! -f "$CONFIG_FILE" ]] || source "$CONFIG_FILE"

is_uint() { [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]; }
validate_config() {
    local name
    for name in MC_PORT BATTERY_WARN BATTERY_SAVE BATTERY_SHUTDOWN TEMP_WARN TEMP_SAVE TEMP_SHUTDOWN DISK_WARN POLL_SECONDS DOCKER_TIMEOUT SAVE_TIMEOUT STOP_TIMEOUT; do
        if ! is_uint "${!name}"; then
            echo "Invalid numeric setting: $name" >&2
            return 1
        fi
    done
    if (( MC_PORT < 1 || MC_PORT > 65535 || BATTERY_SHUTDOWN >= BATTERY_SAVE || BATTERY_SAVE > BATTERY_WARN || BATTERY_WARN > 100 || TEMP_SAVE >= TEMP_SHUTDOWN || TEMP_WARN >= TEMP_SHUTDOWN || DISK_WARN > 100 || POLL_SECONDS < 1 || SAVE_TIMEOUT < 1 || STOP_TIMEOUT < 1 || DOCKER_TIMEOUT <= STOP_TIMEOUT )); then
        echo 'Invalid thresholds or timeouts in configuration' >&2
        return 1
    fi
}
validate_config || return 1

max_temperature() {
    local zone raw maximum=0 found=false
    for zone in "$THERMAL_ROOT"/thermal_zone*/temp; do
        [[ -r "$zone" ]] || continue
        raw=$(cat "$zone") || continue
        is_uint "$raw" || continue
        found=true
        (( raw / 1000 <= maximum )) || maximum=$((raw / 1000))
    done
    [[ "$found" == true ]] || return 1
    printf '%s\n' "$maximum"
}

battery_path() {
    local path
    for path in "$POWER_SUPPLY_ROOT"/BAT*; do
        [[ -r "$path/capacity" && -r "$path/status" ]] || continue
        printf '%s\n' "$path"
        return 0
    done
    return 1
}

save_world() {
    timeout "$SAVE_TIMEOUT" docker exec "$MC_CONTAINER" rcon-cli save-all flush
}

safe_shutdown() {
    # Always attempt a fresh flush immediately before shutdown.
    save_world || echo 'Minecraft flush failed; continuing emergency shutdown' >&2
    local ids
    if ids=$(timeout "$DOCKER_TIMEOUT" docker ps -q); then
        if [[ -n "$ids" ]]; then
            local -a containers=()
            mapfile -t containers <<< "$ids"
            timeout "$DOCKER_TIMEOUT" docker stop --time "$STOP_TIMEOUT" "${containers[@]}" || echo 'Docker stop failed; continuing emergency shutdown' >&2
        fi
    else
        echo 'Cannot list running containers; continuing emergency shutdown' >&2
    fi
    shutdown -h now
}
