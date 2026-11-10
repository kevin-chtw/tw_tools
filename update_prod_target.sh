#!/bin/bash

set -euo pipefail

usage() {
    echo "usage: $0 <service> <host> <active_port> <active_slot> [drain_port drain_slot]" >&2
}

service="${1:-}"
host="${2:-}"
active_port="${3:-}"
active_slot="${4:-}"
drain_port="${5:-}"
drain_slot="${6:-}"
target_file="${TARGET_FILE:-/etc/prometheus/file_sd/prod_targets.json}"

if [[ "${1:-}" == "--delete" ]]; then
    delete_service="${2:-}"
    [[ -n "$delete_service" ]] || {
        echo "usage: $0 --delete <service>" >&2
        exit 1
    }
    command -v jq >/dev/null 2>&1 || {
        echo "required command not found: jq" >&2
        exit 1
    }
    command -v flock >/dev/null 2>&1 || {
        echo "required command not found: flock" >&2
        exit 1
    }
    mkdir -p "$(dirname "$target_file")"
    [[ -f "$target_file" ]] || printf '[]\n' >"$target_file"
    exec 9>"${target_file}.lock"
    flock -w 10 9 || {
        echo "failed to lock target file: ${target_file}" >&2
        exit 1
    }
    tmp_file="${target_file}.tmp.$$"
    jq --arg service "$delete_service" \
        '[.[] | select(.labels.service != $service)]' \
        "$target_file" >"$tmp_file"
    chmod 0644 "$tmp_file"
    chown prometheus:prometheus "$tmp_file"
    mv -f "$tmp_file" "$target_file"
    exit 0
fi

[[ -n "$service" && -n "$host" && -n "$active_port" && -n "$active_slot" ]] || {
    usage
    exit 1
}
[[ "$active_port" =~ ^[0-9]+$ ]] || {
    echo "invalid active port: ${active_port}" >&2
    exit 1
}
case "$active_slot" in
    blue|green) ;;
    *)
        echo "invalid active slot: ${active_slot}" >&2
        exit 1
        ;;
esac
if [[ -n "$drain_port" || -n "$drain_slot" ]]; then
    [[ -n "$drain_port" && -n "$drain_slot" ]] || {
        echo "drain port and slot must be provided together" >&2
        exit 1
    }
    [[ "$drain_port" =~ ^[0-9]+$ ]] || {
        echo "invalid drain port: ${drain_port}" >&2
        exit 1
    }
    case "$drain_slot" in
        blue|green) ;;
        *)
            echo "invalid drain slot: ${drain_slot}" >&2
            exit 1
            ;;
    esac
fi

command -v jq >/dev/null 2>&1 || {
    echo "required command not found: jq" >&2
    exit 1
}
command -v flock >/dev/null 2>&1 || {
    echo "required command not found: flock" >&2
    exit 1
}

mkdir -p "$(dirname "$target_file")"
[[ -f "$target_file" ]] || printf '[]\n' >"$target_file"

exec 9>"${target_file}.lock"
flock -w 10 9 || {
    echo "failed to lock target file: ${target_file}" >&2
    exit 1
}

tmp_file="${target_file}.tmp.$$"
jq \
    --arg service "$service" \
    --arg host "$host" \
    --arg active_slot "$active_slot" \
    --arg active_target "${host}:${active_port}" \
    --arg drain_slot "$drain_slot" \
    --arg drain_target "${host}:${drain_port}" \
    '
    [.[] | select(.labels.service != $service)]
    + [{
        targets: [$active_target],
        labels: {
            service: $service,
            host: $host,
            slot: $active_slot,
            role: "active"
        }
    }]
    + (if $drain_slot == "" then [] else [{
        targets: [$drain_target],
        labels: {
            service: $service,
            host: $host,
            slot: $drain_slot,
            role: "draining"
        }
    }] end)
    | sort_by([.labels.service, .labels.role])
    ' "$target_file" >"$tmp_file"

chmod 0644 "$tmp_file"
chown prometheus:prometheus "$tmp_file"
mv -f "$tmp_file" "$target_file"
