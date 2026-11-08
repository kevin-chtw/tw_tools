#!/bin/bash

set -euo pipefail

usage() {
    echo "usage: $0 <service> <source_dir> [build_target] [base|gamebase] [blocking|async]" >&2
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "required command not found: $1" >&2
        exit 1
    }
}

metrics_port() {
    local service="$1" slot="$2" config="$3"
    awk -v service="$service" -v slot="$slot" '
        $1 == service {
            print (slot == "blue" ? $2 : $3)
            found=1
            exit
        }
        END {
            exit(found ? 0 : 1)
        }
    ' "$config"
}

require_metric() {
    local body="$1" pattern="$2" label="$3"
    if ! grep -Eq "$pattern" <<<"$body"; then
        echo "metrics verification failed: ${label}" >&2
        exit 1
    fi
}

service="${1:-}"
source_dir="${2:-}"
build_target="${3:-.}"
metric_profile="${4:-base}"
drain_mode="${5:-blocking}"

rolling_script="${ROLLING_SCRIPT:-/pitaya/tw_tools/rolling_update.sh}"
rolling_config="${ROLLING_CONFIG:-/pitaya/tw_tools/rolling_services.conf}"
artifact_dir="${ARTIFACT_DIR:-${WORKSPACE:-/tmp}/artifacts}"
bin_name="${BIN_NAME:-$service}"
artifact="${artifact_dir}/${bin_name}"

[[ -n "$service" && -n "$source_dir" ]] || {
    usage
    exit 1
}
case "$metric_profile" in
    base|gamebase) ;;
    *)
        echo "invalid metrics profile: ${metric_profile}" >&2
        exit 1
        ;;
esac
case "$drain_mode" in
    blocking|async) ;;
    *)
        echo "invalid drain mode: ${drain_mode}" >&2
        exit 1
        ;;
esac

require_command go
require_command curl
require_command sudo
[[ -x "$rolling_script" ]] || {
    echo "rolling script is not executable: ${rolling_script}" >&2
    exit 1
}
[[ -f "$rolling_config" ]] || {
    echo "rolling config not found: ${rolling_config}" >&2
    exit 1
}
[[ -d "$source_dir" ]] || {
    echo "source directory not found: ${source_dir}" >&2
    exit 1
}

mkdir -p "$artifact_dir"
cd "$source_dir"

echo "building ${service} from ${source_dir}, target=${build_target}"
go mod download
GOWORK=off CGO_ENABLED="${CGO_ENABLED:-0}" go build \
    -trimpath \
    -buildvcs=false \
    -ldflags="${GO_LDFLAGS:--s -w}" \
    -o "$artifact" \
    "$build_target"
test -x "$artifact"

if [[ "$drain_mode" == "async" ]]; then
    sudo -n "$rolling_script" --async-drain "$service" "$artifact"
else
    sudo -n "$rolling_script" "$service" "$artifact"
fi

slot_file="/pitaya/pids/${service}.slot"
[[ -f "$slot_file" ]] || {
    echo "slot file not found after rollout: ${slot_file}" >&2
    exit 1
}
slot="$(cat "$slot_file")"
port="$(metrics_port "$service" "$slot" "$rolling_config")"
pending_file="/pitaya/pids/${service}.pending"

[[ ! -f "$pending_file" ]] || {
    echo "pending rollout file remains after successful rollout: ${pending_file}" >&2
    exit 1
}

echo "verifying ${service} slot=${slot} metricsPort=${port}"
curl -fsS --connect-timeout 2 --max-time 5 \
    "http://127.0.0.1:${port}/readyz" >/dev/null

sleep 3
metrics="$(curl -fsS --connect-timeout 2 --max-time 10 \
    "http://127.0.0.1:${port}/metrics")"
require_metric "$metrics" \
    '^pitaya_server_service_status(\{[^}]*\})?[[:space:]]+1$' \
    'pitaya_server_service_status=1'
require_metric "$metrics" \
    '^pitaya_etcd_lease_alive(\{[^}]*\})?[[:space:]]+1$' \
    'pitaya_etcd_lease_alive=1'

if [[ "$metric_profile" == "gamebase" ]]; then
    require_metric "$metrics" \
        '^pitaya_gamebase_draining(\{[^}]*\})?[[:space:]]+0$' \
        'pitaya_gamebase_draining=0'
    require_metric "$metrics" \
        '^pitaya_gamebase_active_tables(\{[^}]*\})?[[:space:]]+[0-9]+$' \
        'pitaya_gamebase_active_tables present'
    require_metric "$metrics" \
        '^pitaya_gamebase_players(\{[^}]*\})?[[:space:]]+[0-9]+$' \
        'pitaya_gamebase_players present'
fi

echo "deployment verified: service=${service} slot=${slot} metricsPort=${port} drainMode=${drain_mode}"
