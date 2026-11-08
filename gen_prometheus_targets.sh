#!/bin/bash

set -euo pipefail

PID_DIR="${PID_DIR:-/pitaya/pids}"
CONFIG_FILE="${CONFIG_FILE:-/pitaya/tw_tools/rolling_services.conf}"
OUTPUT_DIR="${OUTPUT_DIR:-/etc/prometheus/file_sd}"
OUTPUT_FILE="${OUTPUT_FILE:-${OUTPUT_DIR}/tw_targets.json}"
TMP_FILE="${OUTPUT_FILE}.tmp.$$"

command -v jq >/dev/null 2>&1 || {
    echo "required command not found: jq" >&2
    exit 1
}
[[ -f "$CONFIG_FILE" ]] || {
    echo "rolling config not found: ${CONFIG_FILE}" >&2
    exit 1
}

mkdir -p "$OUTPUT_DIR"

slot_port() {
    local slot="$1" blue_port="$2" green_port="$3"
    if [[ "$slot" == "blue" ]]; then
        echo "$blue_port"
        return 0
    fi
    echo "$green_port"
}

unit_is_running() {
    local unit="$1" state
    state="$(systemctl show -p ActiveState --value "$unit" 2>/dev/null || echo inactive)"
    case "$state" in
        active|activating|deactivating) return 0 ;;
        *) return 1 ;;
    esac
}

entries='[]'

add_target() {
    local service="$1" slot="$2" port="$3" role="$4"
    [[ -n "$slot" && -n "$port" ]] || return 0
    entries="$(jq -c \
        --arg target "127.0.0.1:${port}" \
        --arg service "$service" \
        --arg slot "$slot" \
        --arg role "$role" \
        '. + [{
            targets: [$target],
            labels: {
                service: $service,
                slot: $slot,
                role: $role
            }
        }]' <<<"$entries")"
}

while read -r service blue_port green_port rest; do
    [[ -n "$service" ]] || continue

    active_slot=""
    slot_file="${PID_DIR}/${service}.slot"
    if [[ -f "$slot_file" ]]; then
        active_slot="$(cat "$slot_file")"
    fi
    case "$active_slot" in
        blue|green)
            if unit_is_running "${service}-${active_slot}.service"; then
                active_port="$(slot_port "$active_slot" "$blue_port" "$green_port")"
                add_target "$service" "$active_slot" "$active_port" active
            fi
            ;;
    esac

    drain_slot=""
    drain_unit=""
    drain_file="${PID_DIR}/${service}.drain"
    if [[ -f "$drain_file" ]]; then
        drain_slot="$(awk -F= '$1 == "old_slot" { print $2 }' "$drain_file")"
        drain_unit="$(awk -F= '$1 == "old_unit" { print $2 }' "$drain_file")"
    fi
    case "$drain_slot" in
        blue|green)
            if [[ "$drain_slot" != "$active_slot" ]] && [[ -n "$drain_unit" ]] &&
                unit_is_running "$drain_unit"; then
                drain_port="$(slot_port "$drain_slot" "$blue_port" "$green_port")"
                add_target "$service" "$drain_slot" "$drain_port" draining
            fi
            ;;
    esac
done < <(awk '$1 ~ /^tw_.*_svr$/ { print $1, $2, $3 }' "$CONFIG_FILE")

jq . <<<"$entries" >"$TMP_FILE"
chmod 0644 "$TMP_FILE"
mv -f "$TMP_FILE" "$OUTPUT_FILE"
