#!/bin/bash

set -euo pipefail

usage() {
    echo "usage: $0 <service> <legacy_port> <upstream_file>" >&2
}

service="${1:-}"
legacy_port="${2:-}"
upstream_file="${3:-}"

[[ -n "$service" && -n "$legacy_port" && -n "$upstream_file" ]] || {
    usage
    exit 1
}
[[ "$legacy_port" =~ ^[0-9]+$ ]] || {
    echo "invalid legacy port: ${legacy_port}" >&2
    exit 1
}

legacy_unit="${service}.service"
slot_file="/pitaya/pids/${service}.slot"
pending_file="/pitaya/pids/${service}.pending"
drain_file="/pitaya/pids/${service}.drain"
legacy_path="/etc/systemd/system/${legacy_unit}"
migrated_path="${legacy_path}.migrated"

stop_slot_units() {
    local slot
    for slot in blue green; do
        systemctl stop "${service}-${slot}.service" 2>/dev/null || true
        systemctl disable "${service}-${slot}.service" 2>/dev/null || true
    done
}

restore_legacy_unit() {
    if [[ -f "$legacy_path" ]]; then
        return 0
    fi
    if [[ -f "$migrated_path" ]]; then
        mv "$migrated_path" "$legacy_path"
        systemctl daemon-reload
        return 0
    fi
    echo "legacy unit backup not found: ${migrated_path}" >&2
    return 1
}

write_legacy_upstream() {
    local tmp_file="${upstream_file}.tmp.$$"
    cat >"$tmp_file" <<EOF
upstream ${service}_backend {
    server 127.0.0.1:${legacy_port};
    keepalive 32;
}
EOF
    chmod 0644 "$tmp_file"
    mv -f "$tmp_file" "$upstream_file"
}

stop_slot_units
restore_legacy_unit
write_legacy_upstream

nginx -t
nginx -s reload
systemctl enable "$legacy_unit"
systemctl reset-failed "$legacy_unit" 2>/dev/null || true
systemctl start "$legacy_unit"

for _ in $(seq 1 30); do
    if systemctl is-active --quiet "$legacy_unit" &&
        ss -ltn "sport = :${legacy_port}" | grep -q LISTEN; then
        rm -f "$slot_file" "$pending_file" "$drain_file"
        echo "rollback complete: ${service} legacy port=${legacy_port}"
        exit 0
    fi
    sleep 1
done

echo "rollback did not become ready: ${service} port=${legacy_port}" >&2
exit 1
