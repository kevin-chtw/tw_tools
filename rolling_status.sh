#!/bin/bash

set -euo pipefail

service="${1:-}"
pid_dir="${PID_DIR:-/pitaya/pids}"
slot_file="${pid_dir}/${service}.slot"
drain_file="${pid_dir}/${service}.drain"

[[ -n "$service" ]] || {
    echo "usage: $0 <service>" >&2
    exit 1
}
[[ -f "$slot_file" ]] || {
    echo "slot file not found: ${slot_file}" >&2
    exit 1
}

active_slot="$(cat "$slot_file")"
echo "service=${service}"
echo "activeSlot=${active_slot}"
echo "activeUnit=${service}-${active_slot}.service"

if [[ ! -f "$drain_file" ]]; then
    echo "drainingSlot="
    echo "drainState=none"
    exit 0
fi

old_slot="$(awk -F= '$1 == "old_slot" { print $2 }' "$drain_file")"
old_unit="$(awk -F= '$1 == "old_unit" { print $2 }' "$drain_file")"
started_at="$(awk -F= '$1 == "started_at" { print $2 }' "$drain_file")"
active_state="$(systemctl show -p ActiveState --value "$old_unit" 2>/dev/null || echo inactive)"

echo "drainingSlot=${old_slot}"
echo "drainState=${active_state}"
echo "drainStartedAt=${started_at}"
echo "drainingUnit=${old_unit}"
