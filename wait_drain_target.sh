#!/bin/bash

set -euo pipefail

usage() {
    echo "usage: $0 <service> <host> <active_port> <active_slot> <drain_slot>" >&2
}

remote_exec() {
    local host="$1"
    shift
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no "root@${host}" "$@"
}

service="${1:-}"
host="${2:-}"
active_port="${3:-}"
active_slot="${4:-}"
drain_slot="${5:-}"
prometheus_host="${PROMETHEUS_HOST:-192.168.0.64}"
poll_seconds="${DRAIN_TARGET_POLL_SEC:-15}"

[[ -n "$service" && -n "$host" && -n "$active_port" && -n "$active_slot" && -n "$drain_slot" ]] || {
    usage
    exit 1
}
[[ "$service" =~ ^[A-Za-z0-9_]+$ ]] || {
    echo "invalid service: ${service}" >&2
    exit 1
}
[[ "$host" =~ ^[A-Za-z0-9._:-]+$ ]] || {
    echo "invalid host: ${host}" >&2
    exit 1
}
[[ "$active_port" =~ ^[0-9]+$ ]] || {
    echo "invalid active port: ${active_port}" >&2
    exit 1
}
[[ "$active_slot" =~ ^(blue|green)$ ]] || {
    echo "invalid active slot: ${active_slot}" >&2
    exit 1
}
[[ "$drain_slot" =~ ^(blue|green)$ ]] || {
    echo "invalid drain slot: ${drain_slot}" >&2
    exit 1
}
[[ "$poll_seconds" =~ ^[0-9]+$ ]] || {
    echo "invalid poll seconds: ${poll_seconds}" >&2
    exit 1
}

drain_unit="${service}-${drain_slot}.service"
drain_file="/pitaya/pids/${service}.drain"

while true; do
    state="$(remote_exec "$host" "systemctl show -p ActiveState --value '${drain_unit}' 2>/dev/null" || true)"
    case "$state" in
        active|activating|deactivating)
            sleep "$poll_seconds"
            ;;
        *)
            break
            ;;
    esac
done

current_slot="$(remote_exec "$host" "cat '/pitaya/pids/${service}.slot' 2>/dev/null" || true)"
current_drain_unit="$(remote_exec "$host" "awk -F= '\$1 == \"old_unit\" { print \$2 }' '${drain_file}' 2>/dev/null" || true)"
if [[ "$current_slot" != "$active_slot" || "$current_drain_unit" != "$drain_unit" ]]; then
    echo "skip stale drain target cleanup: service=${service} activeSlot=${current_slot} drainUnit=${current_drain_unit}"
    exit 0
fi

remote_exec "$prometheus_host" \
    "/pitaya/tw_tools/update_prod_target.sh '${service}' '${host}' '${active_port}' '${active_slot}'"
remote_exec "$host" "rm -f '${drain_file}'"
echo "drain target cleaned: service=${service} host=${host} slot=${active_slot}"
