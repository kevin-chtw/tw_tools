#!/bin/bash

set -euo pipefail

usage() {
    echo "usage: $0 <service> [backup_dir]" >&2
}

service="${1:-}"
backup_dir="${2:-}"

[[ -n "$service" ]] || {
    usage
    exit 1
}

bin_dir="/pitaya/bin"
pid_dir="/pitaya/pids"
legacy_binary="${bin_dir}/${service}"
legacy_unit="${service}.service"
legacy_path="/etc/systemd/system/${legacy_unit}"
migrated_path="${legacy_path}.migrated"
slot_file="${pid_dir}/${service}.slot"
pending_file="${pid_dir}/${service}.pending"
drain_file="${pid_dir}/${service}.drain"

stop_slot_units() {
    local slot
    for slot in blue green; do
        systemctl stop "${service}-${slot}.service" 2>/dev/null || true
        systemctl disable "${service}-${slot}.service" 2>/dev/null || true
    done
}

restore_snapshot() {
    [[ -n "$backup_dir" ]] || return 0
    [[ -f "${backup_dir}/${service}" ]] || {
        echo "backup binary not found: ${backup_dir}/${service}" >&2
        return 1
    }
    [[ -f "${backup_dir}/${legacy_unit}" ]] || {
        echo "backup unit not found: ${backup_dir}/${legacy_unit}" >&2
        return 1
    }
    install -m 0755 "${backup_dir}/${service}" "$legacy_binary"
    install -m 0644 "${backup_dir}/${legacy_unit}" "$legacy_path"
}

restore_legacy_unit() {
    if [[ -f "$legacy_path" ]]; then
        return 0
    fi
    [[ -f "$migrated_path" ]] || {
        echo "legacy unit backup not found: ${migrated_path}" >&2
        return 1
    }
    mv "$migrated_path" "$legacy_path"
}

wait_for_legacy_process() {
    local deadline=$(( $(date +%s) + 30 )) pid
    while (( $(date +%s) < deadline )); do
        pid="$(systemctl show -p MainPID --value "$legacy_unit" 2>/dev/null || echo 0)"
        if systemctl is-active --quiet "$legacy_unit" &&
            [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 0 )); then
            return 0
        fi
        sleep 1
    done
    return 1
}

stop_slot_units
restore_snapshot
restore_legacy_unit
systemctl daemon-reload
systemctl enable "$legacy_unit"
systemctl reset-failed "$legacy_unit" 2>/dev/null || true
systemctl start "$legacy_unit"

if ! wait_for_legacy_process; then
    echo "rollback did not become ready: ${service}" >&2
    exit 1
fi

rm -f "$slot_file" "$pending_file" "$drain_file"
echo "rollback complete: ${service} legacy unit active"
