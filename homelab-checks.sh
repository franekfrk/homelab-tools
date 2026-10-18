#!/bin/bash
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/homelab-common.sh" || exit 1
umask 077
mkdir -p -- "$STATE_DIR" || exit 1
# Avoid overlapping cron executions and races in state files.
exec 9>"$STATE_DIR/checks.lock"
flock -n 9 || exit 0
ALERT="$SCRIPT_DIR/discord-alert.sh"
RESULT=0
alert_once() {
    local flag="$STATE_DIR/$1"
    [[ ! -f "$flag" ]] || return 0
    if "$ALERT" "$2"; then touch "$flag"; else RESULT=1; fi
}
clear_flag() { rm -f -- "$STATE_DIR/$1"; }
state_alert() {
    local key="$1" current="$2" down_msg="$3" up_msg="$4"
    local file="$STATE_DIR/state_$key" previous=ok message
    [[ ! -f "$file" ]] || previous=$(cat "$file")
    [[ "$current" != "$previous" ]] || return 0
    if [[ "$current" == bad ]]; then message="$down_msg"; else message="$up_msg"; fi
    if "$ALERT" "$message"; then printf '%s\n' "$current" > "$file"; else RESULT=1; fi
}
# Detect AC adapters by type, rather than a machine-specific AC path.
AC_FOUND=false
AC_ONLINE=0
for supply in "$POWER_SUPPLY_ROOT"/*; do
    [[ -r "$supply/type" && -r "$supply/online" ]] || continue
    [[ $(cat "$supply/type") == Mains ]] || continue
    value=$(cat "$supply/online")
    [[ "$value" == 0 || "$value" == 1 ]] || continue
    AC_FOUND=true
    [[ "$value" != 1 ]] || AC_ONLINE=1
done
if [[ "$AC_FOUND" == true ]]; then
    if [[ "$AC_ONLINE" == 1 ]]; then ac=ok; else ac=bad; fi
    state_alert power "$ac" '🔴 Zanik zasilania. Laptop pracuje na baterii.' '✅ Zasilanie przywrócone.'
fi
if BAT_PATH=$(battery_path); then
    CAPACITY=$(cat "$BAT_PATH/capacity")
    STATUS=$(cat "$BAT_PATH/status")
    if is_uint "$CAPACITY" && (( CAPACITY <= 100 )); then
        if [[ "$STATUS" == Discharging ]] && (( CAPACITY <= BATTERY_WARN )); then
            alert_once battery_warn "⚠️ Bateria ${CAPACITY}%."
        elif [[ "$STATUS" != Discharging ]] || (( CAPACITY > BATTERY_WARN + 5 )); then
            clear_flag battery_warn
        fi
    else
        RESULT=1
        echo 'Invalid battery capacity' >&2
    fi
fi
if TEMP=$(max_temperature); then
    clear_flag temp_sensor
    if (( TEMP >= TEMP_WARN )); then alert_once temp_warn "⚠️ Temperatura ${TEMP}°C."; fi
    if (( TEMP < TEMP_WARN - 5 )); then clear_flag temp_warn; fi
else
    alert_once temp_sensor '🔴 Brak odczytu czujników temperatury.'
    RESULT=1
fi
DISK_USAGE=$(LC_ALL=C df -P / | awk 'NR==2 {gsub("%", "", $5); print $5}')
if is_uint "$DISK_USAGE"; then
    if (( DISK_USAGE >= DISK_WARN )); then alert_once disk_warn "⚠️ Dysk / zajęty w ${DISK_USAGE}%."; fi
    if (( DISK_USAGE < DISK_WARN - 5 )); then clear_flag disk_warn; fi
else
    echo 'Cannot read root filesystem usage' >&2
    RESULT=1
fi
for svc in battery-monitor.service temp-monitor.service; do
    if systemctl is-active --quiet "$svc"; then
        clear_flag "svc_down_$svc"
    else
        alert_once "svc_down_$svc" "🔴 Usługa $svc nie działa."
    fi
done
if running=$(timeout 10 docker inspect -f '{{.State.Running}}' "$PIHOLE_CONTAINER" 2>/dev/null) && [[ "$running" == true ]]; then
    health=$(timeout 10 docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$PIHOLE_CONTAINER" 2>/dev/null)
    if [[ "$health" == healthy || "$health" == none ]]; then
        state_alert pihole_container ok '' '✅ Kontener DNS ponownie działa.'
    else
        state_alert pihole_container bad "🔴 Kontener DNS: healthcheck ${health:-unavailable}." ''
    fi
else
    state_alert pihole_container bad '🔴 Kontener DNS nie działa, nie istnieje lub Docker jest niedostępny.' ''
fi
# A successful transport alone is insufficient: require NOERROR and an A answer.
if dns=$(dig @"$PIHOLE_DNS_HOST" +time=3 +tries=1 "$DNS_TEST_NAME" A 2>/dev/null) &&
    [[ "$dns" == *'status: NOERROR,'* ]] &&
    awk '$0 !~ /^;/ && $4 == "A" {found=1} END {exit !found}' <<< "$dns"; then
    state_alert pihole_dns ok '' '✅ DNS ponownie rozwiązuje nazwy.'
else
    state_alert pihole_dns bad '🔴 Test DNS nie zwrócił poprawnego rekordu A.' ''
fi
if [[ -f /run/reboot-required ]]; then alert_once reboot_required '⚠️ System wymaga restartu.'; else clear_flag reboot_required; fi
if timeout 5 bash -c 'exec 3<>/dev/tcp/$1/$2' _ "$MC_HOST" "$MC_PORT" 2>/dev/null; then
    state_alert minecraft_port ok '' '✅ Port Minecraft ponownie odpowiada.'
    hc_suffix=''
else
    state_alert minecraft_port bad '🔴 Port Minecraft nie odpowiada.' ''
    hc_suffix=/fail
fi
# Optional external heartbeat; never embed a private ping URL in source control.
if [[ -n "$HC_URL" ]]; then
    curl --fail --silent --show-error --connect-timeout 5 --max-time 10 "${HC_URL%/}$hc_suffix" >/dev/null || RESULT=1
fi
exit "$RESULT"
