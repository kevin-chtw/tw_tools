#!/bin/bash

set -euo pipefail

usage() {
    echo "usage: $0 <service> <source_dir> <host> [build_target] [base|gamebase] [blocking|async]" >&2
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "required command not found: $1" >&2
        exit 1
    }
}

validate_host() {
    local host="$1"
    [[ "$host" =~ ^[A-Za-z0-9._:-]+$ ]] || {
        echo "invalid deploy host: ${host}" >&2
        exit 1
    }
}

remote_exec() {
    local host="$1"
    shift
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no "root@${host}" "$@"
}

remote_scp() {
    local source="$1" host="$2" target="$3"
    scp -o BatchMode=yes -o StrictHostKeyChecking=no "$source" "root@${host}:${target}"
}

remote_slot() {
    local host="$1" service="$2"
    remote_exec "$host" "cat /pitaya/pids/${service}.slot"
}

remote_metrics_port() {
    local host="$1" service="$2" slot="$3"
    remote_exec "$host" "awk -v service='${service}' -v slot='${slot}' '
        \$1 == service {
            print (slot == \"blue\" ? \$2 : \$3)
            found=1
            exit
        }
        END {
            exit(found ? 0 : 1)
        }
    ' /pitaya/tw_tools/rolling_services.conf"
}

remote_drain_slot() {
    local host="$1" service="$2"
    remote_exec "$host" "if [ -f /pitaya/pids/${service}.drain ]; then
        awk -F= '\$1 == \"old_slot\" { print \$2 }' /pitaya/pids/${service}.drain
    fi"
}

update_prometheus_target() {
    local service="$1" host="$2"
    local active_slot active_port drain_slot="" drain_port="" prometheus_host
    active_slot="$(remote_slot "$host" "$service")"
    active_port="$(remote_metrics_port "$host" "$service" "$active_slot")"
    drain_slot="$(remote_drain_slot "$host" "$service")"
    if [[ -n "$drain_slot" ]]; then
        drain_port="$(remote_metrics_port "$host" "$service" "$drain_slot")"
    fi

    prometheus_host="${PROMETHEUS_HOST:-192.168.0.64}"
    remote_exec "$prometheus_host" "test -x /pitaya/tw_tools/update_prod_target.sh"
    remote_exec "$prometheus_host" \
        "/pitaya/tw_tools/update_prod_target.sh '${service}' '${host}' '${active_port}' '${active_slot}' '${drain_port}' '${drain_slot}'"
}

require_remote_metric() {
    local body="$1" pattern="$2" label="$3"
    if ! grep -Eq "$pattern" <<<"$body"; then
        echo "metrics verification failed: ${label}" >&2
        exit 1
    fi
}

verify_remote_deployment() {
    local service="$1" host="$2" profile="$3"
    local slot port pending_file metrics
    slot="$(remote_slot "$host" "$service")"
    port="$(remote_metrics_port "$host" "$service" "$slot")"
    pending_file="/pitaya/pids/${service}.pending"
    remote_exec "$host" "test ! -f '${pending_file}'"

    remote_exec "$host" "curl -fsS --connect-timeout 2 --max-time 5 http://127.0.0.1:${port}/readyz >/dev/null"
    sleep 3
    metrics="$(remote_exec "$host" "curl -fsS --connect-timeout 2 --max-time 10 http://127.0.0.1:${port}/metrics")"
    require_remote_metric "$metrics" \
        '^pitaya_server_service_status(\{[^}]*\})?[[:space:]]+1$' \
        'pitaya_server_service_status=1'
    require_remote_metric "$metrics" \
        '^pitaya_etcd_lease_alive(\{[^}]*\})?[[:space:]]+1$' \
        'pitaya_etcd_lease_alive=1'

    if [[ "$profile" == "gamebase" ]]; then
        require_remote_metric "$metrics" \
            '^pitaya_gamebase_draining(\{[^}]*\})?[[:space:]]+0$' \
            'pitaya_gamebase_draining=0'
        require_remote_metric "$metrics" \
            '^pitaya_gamebase_active_tables(\{[^}]*\})?[[:space:]]+[0-9]+$' \
            'pitaya_gamebase_active_tables present'
        require_remote_metric "$metrics" \
            '^pitaya_gamebase_players(\{[^}]*\})?[[:space:]]+[0-9]+$' \
            'pitaya_gamebase_players present'
    fi

    update_prometheus_target "$service" "$host"
    echo "deployment verified: service=${service} host=${host} slot=${slot} metricsPort=${port} profile=${profile}"
}

deploy_artifact() {
    local target_service="$1" target_artifact
    target_artifact="/tmp/${target_service}.$$.new"
    remote_scp "$artifact" "$host" "$target_artifact"
    if [[ "$drain_mode" == "async" ]]; then
        remote_exec "$host" "chmod 0755 '${target_artifact}' && /pitaya/tw_tools/rolling_update.sh --async-drain '${target_service}' '${target_artifact}'"
    else
        remote_exec "$host" "chmod 0755 '${target_artifact}' && /pitaya/tw_tools/rolling_update.sh '${target_service}' '${target_artifact}'"
    fi
    verify_remote_deployment "$target_service" "$host" "$profile"
}

service="${1:-}"
source_dir="${2:-}"
host="${3:-}"
build_target="${4:-.}"
profile="${5:-base}"
drain_mode="${6:-blocking}"

[[ -n "$service" && -n "$source_dir" && -n "$host" ]] || {
    usage
    exit 1
}
case "$profile" in
    base|gamebase) ;;
    *)
        echo "invalid profile: ${profile}" >&2
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
require_command ssh
require_command scp
validate_host "$host"
[[ -d "$source_dir" ]] || {
    echo "source directory not found: ${source_dir}" >&2
    exit 1
}
remote_exec "$host" "test -x /pitaya/tw_tools/rolling_update.sh"
remote_exec "$host" "test -f /pitaya/tw_tools/rolling_services.conf"

artifact_dir="${ARTIFACT_DIR:-${WORKSPACE:-/tmp}/artifacts}"
artifact="${artifact_dir}/${service}"

mkdir -p "$artifact_dir"
cd "$source_dir"

echo "building ${service} from ${source_dir}, target=${build_target}, host=${host}"
go mod download
GOWORK=off CGO_ENABLED="${CGO_ENABLED:-0}" go build \
    -trimpath \
    -buildvcs=false \
    -ldflags="${GO_LDFLAGS:--s -w}" \
    -o "$artifact" \
    "$build_target"
test -x "$artifact"

deploy_artifact "$service"
for extra_service in ${DEPLOY_ALSO:-}; do
    [[ "$extra_service" =~ ^[A-Za-z0-9_]+$ ]] || {
        echo "invalid extra deploy service: ${extra_service}" >&2
        exit 1
    }
    deploy_artifact "$extra_service"
done
