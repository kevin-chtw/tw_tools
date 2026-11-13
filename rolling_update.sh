#!/bin/bash

# 通用滚动发布脚本，与 tw_tools.sh 进程管理分离。
# 用法: ./rolling_update.sh [--async-drain] <service> /path/to/new/binary

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -d "${SCRIPT_DIR}/../bin" ]]; then
    PARENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
    BIN_DIR="${PARENT_DIR}/bin"
else
    BIN_DIR="${SCRIPT_DIR}"
    PARENT_DIR="$(dirname "$SCRIPT_DIR")"
fi

PID_DIR="${PARENT_DIR}/pids"
LOG_DIR="${BIN_DIR}/logs"
SYSTEMD_DIR="/etc/systemd/system"
CONFIG_FILE="${ROLLING_CONFIG:-${SCRIPT_DIR}/rolling_services.conf}"
NGINX_RELOAD_GRACE_SEC="${NGINX_RELOAD_GRACE_SEC:-5}"

mkdir -p "$PID_DIR" "$LOG_DIR"

usage() {
    echo "usage: $0 [--async-drain] <service> /path/to/new/binary" >&2
    echo "config: ${CONFIG_FILE}" >&2
}

has_systemd() {
    command -v systemctl >/dev/null 2>&1 || return 1
    [[ -r /proc/1/comm ]] || return 1
    [[ "$(cat /proc/1/comm 2>/dev/null || true)" == "systemd" ]]
}

require_systemd() {
    if [[ "$(id -u)" != "0" ]]; then
        echo "rolling-update requires root" >&2
        exit 1
    fi
    if ! has_systemd; then
        echo "rolling-update requires systemd" >&2
        exit 1
    fi
}

unit_name() {
    echo "$1.service"
}

slot_unit() {
    echo "$1-$2"
}

other_slot() {
    if [[ "$1" == "blue" ]]; then
        echo "green"
        return 0
    fi
    echo "blue"
}

current_slot() {
    local service="$1" slot_file="${PID_DIR}/$1.slot"
    if [[ -f "$slot_file" ]]; then
        cat "$slot_file"
        return 0
    fi
    echo "blue"
}

load_service_config() {
    local service="$1"
    [[ -f "$CONFIG_FILE" ]] || {
        echo "rolling config not found: ${CONFIG_FILE}" >&2
        return 1
    }
    awk -v service="$service" '
        $1 == service && $1 !~ /^#/ {
            if ($4 == "nginx" || $4 == "maintenance-process") {
                if (NF < 7) {
                    exit 2
                }
                print $2, $3, $4, $5, $6, $7
            } else {
                print $2, $3, $4
            }
            found=1
            exit
        }
        END {
            exit(found ? 0 : 1)
        }
    ' "$CONFIG_FILE"
}

slot_port() {
    local slot="$1" blue_port="$2" green_port="$3"
    if [[ "$slot" == "blue" ]]; then
        echo "$blue_port"
        return 0
    fi
    echo "$green_port"
}

upstream_name() {
    echo "$1_backend"
}

write_slot_unit() {
    local service="$1" slot="$2" exec_start="$3" metrics_port="$4" service_port="${5:-}"
    local name out service_port_env=""
    name="$(slot_unit "$service" "$slot")"
    out="${SYSTEMD_DIR}/$(unit_name "$name")"
    if [[ -n "$service_port" ]]; then
        service_port_env="Environment=TW_SERVICE_PORT=${service_port}"
    fi
    cat >"$out" <<EOF
[Unit]
Description=${service} ${slot}
After=network-online.target
Wants=network-online.target
OnFailure=tw-alert@%p.service
StartLimitIntervalSec=120
StartLimitBurst=5

[Service]
Type=simple
WorkingDirectory=${BIN_DIR}
Environment=PITAYA_METRICS_ENABLED=true
Environment=PITAYA_METRICS_PORT=${metrics_port}
Environment=PITAYA_HEALTH_ENABLED=true
Environment=PITAYA_HEALTH_PORT=${metrics_port}
Environment=PITAYA_DRAIN_ENABLED=true
Environment=PITAYA_DRAIN_UNLIMITED=true
${service_port_env}
ExecStart=${exec_start}
Restart=always
RestartSec=3
KillMode=mixed
TimeoutStopSec=infinity
StandardOutput=append:${LOG_DIR}/${service}-${slot}.out
StandardError=append:${LOG_DIR}/${service}-${slot}.err

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$out"
}

port_owned_by_pid() {
    local port="$1" pid="$2" output
    command -v ss >/dev/null 2>&1 || return 0
    output="$(ss -ltnp "sport = :${port}" 2>/dev/null || true)"
    [[ "$output" == *"pid=${pid},"* ]]
}

wait_ready() {
    local metrics_port="$1" unit="$2" app_port="${3:-}"
    local deadline=$(( $(date +%s) + 60 )) stable=0 pid
    command -v curl >/dev/null 2>&1 || {
        echo "rolling-update requires curl" >&2
        return 1
    }
    while (( $(date +%s) < deadline )); do
        if ! systemctl is-active --quiet "$(unit_name "$unit")"; then
            echo "candidate unit is not active: ${unit}" >&2
            return 1
        fi
        pid="$(systemctl show -p MainPID --value "$(unit_name "$unit")" 2>/dev/null || echo 0)"
        if [[ ! "$pid" =~ ^[0-9]+$ ]] || [[ "$pid" == "0" ]]; then
            echo "candidate unit has no active MainPID: ${unit}" >&2
            return 1
        fi
        if ! port_owned_by_pid "$metrics_port" "$pid"; then
            stable=0
            sleep 1
            continue
        fi
        if [[ -n "$app_port" ]] && ! port_owned_by_pid "$app_port" "$pid"; then
            stable=0
            sleep 1
            continue
        fi
        if [[ "$metrics_port" == "0" ]] || curl -fsS --connect-timeout 1 --max-time 3 \
            "http://127.0.0.1:${metrics_port}/readyz" >/dev/null 2>&1; then
            stable=$((stable + 1))
            if (( stable >= 3 )); then
                return 0
            fi
        else
            stable=0
        fi
        sleep 1
    done
    return 1
}

write_upstream_file() {
    local path="$1" name="$2" port="$3" tmp
    tmp="${path}.tmp.$$"
    cat >"$tmp" <<EOF
upstream ${name} {
    server 127.0.0.1:${port};
    keepalive 32;
}
EOF
    mv "$tmp" "$path"
}

switch_nginx_upstream() {
    local upstream_file="$1" service="$2" app_port="$3"
    local backup_file name
    name="$(upstream_name "$service")"
    backup_file="${upstream_file}.bak.$$"
    if [[ -f "$upstream_file" ]]; then
        cp "$upstream_file" "$backup_file"
    else
        backup_file=""
    fi
    if ! write_upstream_file "$upstream_file" "$name" "$app_port"; then
        echo "failed to write upstream file: ${upstream_file}" >&2
        if [[ -n "$backup_file" ]]; then
            mv "$backup_file" "$upstream_file"
        fi
        return 1
    fi
    if ! nginx -t; then
        echo "nginx -t failed after upstream update" >&2
        if [[ -n "$backup_file" ]]; then
            mv "$backup_file" "$upstream_file"
            nginx -t >/dev/null 2>&1 || true
        else
            rm -f "$upstream_file"
        fi
        return 1
    fi
    if ! nginx -s reload; then
        echo "nginx reload failed after upstream update" >&2
        if [[ -n "$backup_file" ]]; then
            mv "$backup_file" "$upstream_file"
            nginx -t >/dev/null 2>&1 || true
            nginx -s reload >/dev/null 2>&1 || true
        fi
        return 1
    fi
    rm -f "$backup_file"
}

stop_candidate_unit() {
    local unit="$1"
    systemctl stop "$(unit_name "$unit")" || true
    systemctl disable "$(unit_name "$unit")" >/dev/null 2>&1 || true
}

show_pending_recovery() {
    local service="$1" current="$2" candidate="$3" current_unit="$4" candidate_unit="$5"
    local pending_file="$6" upstream_file="$7" current_app="$8" candidate_app="$9"
    echo "pending rollout detected: service=${service} slot=${current} candidate=${candidate}" >&2
    echo "pending file: ${pending_file}" >&2
    echo "current unit: ${current_unit}, candidate unit: ${candidate_unit}" >&2
    if [[ -n "$upstream_file" ]]; then
        echo "nginx upstream file: ${upstream_file}; serving app port is likely ${candidate_app}" >&2
        echo "rollback upstream to ${current_app}, run nginx -t and nginx -s reload, then stop ${candidate_unit}" >&2
    fi
    echo "after confirming candidate health, stop ${current_unit}, write ${candidate} to ${PID_DIR}/${service}.slot, and remove ${pending_file}" >&2
}

has_legacy_process() {
    local service="$1" legacy_unit legacy_pid slot_file
    legacy_unit="$(unit_name "$service")"
    legacy_pid="${PID_DIR}/${service}.pid"
    slot_file="${PID_DIR}/${service}.slot"
    if systemctl is-active --quiet "$legacy_unit" 2>/dev/null; then
        return 0
    fi
    if [[ -f "${SYSTEMD_DIR}/${legacy_unit}" ]] && [[ ! -f "$slot_file" ]]; then
        return 0
    fi
    if [[ -f "$legacy_pid" ]] && ps -p "$(cat "$legacy_pid")" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

stop_legacy_process() {
    local service="$1" legacy_unit legacy_pid pid count
    legacy_unit="$(unit_name "$service")"
    legacy_pid="${PID_DIR}/${service}.pid"
    if [[ -f "${SYSTEMD_DIR}/${legacy_unit}" ]] ||
        systemctl is-active --quiet "$legacy_unit" 2>/dev/null; then
        systemctl stop "$legacy_unit"
        return 0
    fi
    if [[ -f "$legacy_pid" ]]; then
        pid="$(cat "$legacy_pid" 2>/dev/null || true)"
        if [[ -n "$pid" ]] && ps -p "$pid" >/dev/null 2>&1; then
            kill "$pid"
            count=0
            while (( count < 15 )) && ps -p "$pid" >/dev/null 2>&1; do
                sleep 1
                count=$((count + 1))
            done
            if ps -p "$pid" >/dev/null 2>&1; then
                echo "legacy nohup process did not stop: pid ${pid}" >&2
                return 1
            fi
        fi
    fi
}

restart_legacy_process() {
    local service="$1" legacy_unit legacy_pid binary
    legacy_unit="$(unit_name "$service")"
    legacy_pid="${PID_DIR}/${service}.pid"
    if [[ -f "${SYSTEMD_DIR}/${legacy_unit}" ]]; then
        systemctl start "$legacy_unit"
        return 0
    fi
    binary="${BIN_DIR}/${service}"
    if [[ ! -x "$binary" ]]; then
        echo "cannot restart legacy ${service}: binary not executable: ${binary}" >&2
        return 1
    fi
    (
        cd "$BIN_DIR"
        nohup "./${service}" >>"${LOG_DIR}/${service}.out" 2>>"${LOG_DIR}/${service}.err" &
        echo $! >"$legacy_pid"
    )
}

retire_legacy_unit() {
    local service="$1" legacy_unit legacy_path backup_path
    legacy_unit="$(unit_name "$service")"
    legacy_path="${SYSTEMD_DIR}/${legacy_unit}"
    if [[ ! -f "$legacy_path" ]]; then
        return 0
    fi
    systemctl disable "$legacy_unit" >/dev/null 2>&1 || true
    backup_path="${legacy_path}.migrated"
    if ! mv "$legacy_path" "$backup_path"; then
        echo "warning: failed to retire legacy unit ${legacy_path}" >&2
        return 0
    fi
    systemctl daemon-reload
}

check_existing_drain() {
    local service="$1" drain_file="${PID_DIR}/$1.drain"
    local old_unit old_slot new_slot started_at active_state
    if [[ ! -f "$drain_file" ]]; then
        return 0
    fi
    old_unit="$(awk -F= '$1 == "old_unit" { print $2 }' "$drain_file")"
    old_slot="$(awk -F= '$1 == "old_slot" { print $2 }' "$drain_file")"
    new_slot="$(awk -F= '$1 == "new_slot" { print $2 }' "$drain_file")"
    started_at="$(awk -F= '$1 == "started_at" { print $2 }' "$drain_file")"
    if [[ -z "$old_unit" || -z "$old_slot" || -z "$new_slot" || -z "$started_at" ]]; then
        echo "invalid drain state: ${drain_file}" >&2
        return 1
    fi
    active_state="$(systemctl show -p ActiveState --value "$old_unit" 2>/dev/null || echo inactive)"
    case "$active_state" in
        active|activating|deactivating)
            echo "service ${service} is still draining old slot ${old_slot}" >&2
            echo "activeSlot=${new_slot} drainingSlot=${old_slot} state=${active_state}" >&2
            echo "drainStartedAt=${started_at}" >&2
            echo "wait for ${old_unit} to exit before deploying again" >&2
            return 1
            ;;
    esac
    echo "removing stale drain state: ${drain_file}"
    rm -f "$drain_file"
}

begin_async_drain() {
    local service="$1" old_slot="$2" new_slot="$3" old_unit="$4"
    local drain_file="${PID_DIR}/${service}.drain"
    local tmp_file="${drain_file}.tmp.$$"
    cat >"$tmp_file" <<EOF
old_slot=${old_slot}
new_slot=${new_slot}
old_unit=$(unit_name "$old_unit")
started_at=$(date --iso-8601=seconds)
EOF
    if ! systemctl stop --no-block "$(unit_name "$old_unit")"; then
        rm -f "$tmp_file"
        echo "failed to queue async stop for ${old_unit}" >&2
        return 1
    fi
    mv "$tmp_file" "$drain_file"
}

start_candidate() {
    local service="$1" candidate="$2" metrics_port="$3" app_port="${4:-}"
    local candidate_unit
    candidate_unit="$(slot_unit "$service" "$candidate")"
    systemctl reset-failed "$(unit_name "$candidate_unit")" 2>/dev/null || true
    systemctl enable "$(unit_name "$candidate_unit")" >/dev/null
    if ! systemctl start "$(unit_name "$candidate_unit")"; then
        systemctl disable "$(unit_name "$candidate_unit")" >/dev/null 2>&1 || true
        return 1
    fi
    if ! wait_ready "$metrics_port" "$candidate_unit" "$app_port"; then
        stop_candidate_unit "$candidate_unit"
        return 1
    fi
}

rolling_update() {
    local async_drain="$1" service="${2:-}" new_bin="${3:-}"
    local config blue_metrics green_metrics mode blue_app green_app upstream_file
    local effective_mode current candidate candidate_unit current_unit
    local candidate_metrics candidate_app current_app release_dir release_bin pending_file
    local config_status=0 drain_mode="none"
    local legacy_active=0

    require_systemd
    [[ -n "$service" && -n "$new_bin" ]] || {
        usage
        return 1
    }
    [[ -x "$new_bin" ]] || {
        echo "new binary is not executable: ${new_bin}" >&2
        return 1
    }
    config="$(load_service_config "$service")" || config_status=$?
    if (( config_status != 0 )); then
        if (( config_status == 2 )); then
            echo "invalid nginx entry for ${service} in ${CONFIG_FILE}: expected 7 fields" >&2
        else
            echo "service is not configured in ${CONFIG_FILE}: ${service}" >&2
        fi
        return 1
    fi
    read -r blue_metrics green_metrics mode blue_app green_app upstream_file <<<"$config"
    case "$mode" in
        rolling|maintenance)
            blue_app=""
            green_app=""
            upstream_file=""
            ;;
        nginx)
            [[ -n "$blue_app" && -n "$green_app" && -n "$upstream_file" ]] || {
                echo "nginx mode requires blue/green app ports and upstream file" >&2
                return 1
            }
            if [[ ! "$NGINX_RELOAD_GRACE_SEC" =~ ^[0-9]+$ ]]; then
                echo "NGINX_RELOAD_GRACE_SEC must be a non-negative integer" >&2
                return 1
            fi
            ;;
        maintenance-process)
            [[ -n "$blue_app" && -n "$green_app" ]] || {
                echo "maintenance-process mode requires blue/green app ports" >&2
                return 1
            }
            upstream_file=""
            ;;
        *)
            echo "invalid mode for ${service}: ${mode}" >&2
            return 1
            ;;
    esac

    current="$(current_slot "$service")"
    case "$current" in
        blue|green) ;;
        *)
            echo "invalid ${service} slot: ${current}" >&2
            return 1
            ;;
    esac
    candidate="$(other_slot "$current")"
    candidate_unit="$(slot_unit "$service" "$candidate")"
    current_unit="$(slot_unit "$service" "$current")"
    candidate_metrics="$(slot_port "$candidate" "$blue_metrics" "$green_metrics")"
    if [[ "$mode" == "nginx" || "$mode" == "maintenance-process" ]]; then
        candidate_app="$(slot_port "$candidate" "$blue_app" "$green_app")"
        current_app="$(slot_port "$current" "$blue_app" "$green_app")"
    else
        candidate_app=""
        current_app=""
    fi
    pending_file="${PID_DIR}/${service}.pending"

    check_existing_drain "$service" || return 1
    if systemctl is-active --quiet "$(unit_name "$candidate_unit")" 2>/dev/null; then
        echo "candidate slot is already active: ${candidate_unit}" >&2
        if [[ -f "$pending_file" ]]; then
            show_pending_recovery "$service" "$current" "$candidate" "$current_unit" "$candidate_unit" \
                "$pending_file" "$upstream_file" "$current_app" "$candidate_app"
        fi
        return 1
    fi
    if has_legacy_process "$service"; then
        legacy_active=1
    fi
    effective_mode="$mode"
    if (( legacy_active == 1 )) && [[ "$mode" == "rolling" ]]; then
        effective_mode="maintenance"
        echo "first rollout for ${service} uses a one-time maintenance window" >&2
    fi
    if (( legacy_active == 1 )) && [[ "$mode" == "nginx" ]]; then
        echo "nginx first rollout keeps legacy process until upstream switch succeeds" >&2
    fi

    release_dir="${BIN_DIR}/releases/${service}/${candidate}"
    release_bin="${release_dir}/${service}"
    mkdir -p "$release_dir"
    cp "$new_bin" "$release_bin"
    chmod +x "$release_bin"
    write_slot_unit "$service" "$candidate" "$release_bin" "$candidate_metrics" "$candidate_app"
    systemctl daemon-reload

    if [[ "$effective_mode" == "maintenance" || "$effective_mode" == "maintenance-process" ]] && (( legacy_active == 1 )); then
        echo "maintenance stop: legacy ${service}..."
        stop_legacy_process "$service" || return 1
    elif [[ "$effective_mode" == "maintenance" || "$effective_mode" == "maintenance-process" ]] && [[ -f "${SYSTEMD_DIR}/$(unit_name "$current_unit")" ]]; then
        echo "maintenance stop: ${current_unit}..."
        systemctl stop "$(unit_name "$current_unit")" || {
            echo "failed to stop ${current_unit}" >&2
            return 1
        }
    fi

    if ! start_candidate "$service" "$candidate" "$candidate_metrics" "$candidate_app"; then
        echo "candidate ${candidate_unit} did not become ready" >&2
        if [[ "$effective_mode" == "maintenance" ]] && (( legacy_active == 1 )); then
            echo "attempting to restart legacy ${service}" >&2
            restart_legacy_process "$service" || true
        elif [[ "$effective_mode" == "maintenance" ]] && [[ -f "${SYSTEMD_DIR}/$(unit_name "$current_unit")" ]]; then
            echo "attempting to restart previous slot ${current_unit}" >&2
            systemctl start "$(unit_name "$current_unit")" || true
        fi
        return 1
    fi

    echo "$candidate" >"$pending_file"

    if [[ "$effective_mode" == "nginx" ]]; then
        echo "switching nginx upstream for ${service} to ${candidate_app}..."
        if ! switch_nginx_upstream "$upstream_file" "$service" "$candidate_app"; then
            echo "nginx switch failed; stopping candidate ${candidate_unit}" >&2
            stop_candidate_unit "$candidate_unit"
            rm -f "$pending_file"
            return 1
        fi
        if (( NGINX_RELOAD_GRACE_SEC > 0 )); then
            echo "waiting ${NGINX_RELOAD_GRACE_SEC}s for nginx reload and in-flight requests..."
            sleep "$NGINX_RELOAD_GRACE_SEC"
        fi
        if (( legacy_active == 1 )); then
            echo "draining legacy ${service} after nginx switch..."
            stop_legacy_process "$service" || {
                echo "failed to stop legacy ${service}; pending=${pending_file}" >&2
                show_pending_recovery "$service" "$current" "$candidate" "$current_unit" "$candidate_unit" \
                    "$pending_file" "$upstream_file" "$current_app" "$candidate_app"
                return 1
            }
        elif [[ -f "${SYSTEMD_DIR}/$(unit_name "$current_unit")" ]]; then
            echo "draining ${current_unit} after nginx switch..."
            if (( async_drain == 1 )); then
                if ! begin_async_drain "$service" "$current" "$candidate" "$current_unit"; then
                    echo "failed to start async drain; pending=${pending_file}" >&2
                    show_pending_recovery "$service" "$current" "$candidate" "$current_unit" "$candidate_unit" \
                        "$pending_file" "$upstream_file" "$current_app" "$candidate_app"
                    return 1
                fi
                drain_mode="async"
            elif ! systemctl stop "$(unit_name "$current_unit")"; then
                echo "failed to stop ${current_unit}; pending=${pending_file}" >&2
                show_pending_recovery "$service" "$current" "$candidate" "$current_unit" "$candidate_unit" \
                    "$pending_file" "$upstream_file" "$current_app" "$candidate_app"
                return 1
            else
                drain_mode="blocking"
            fi
        fi
    elif [[ "$effective_mode" == "rolling" ]] && [[ -f "${SYSTEMD_DIR}/$(unit_name "$current_unit")" ]]; then
        echo "draining ${current_unit}..."
        if (( async_drain == 1 )); then
            if ! begin_async_drain "$service" "$current" "$candidate" "$current_unit"; then
                echo "failed to start async drain; pending=${pending_file}" >&2
                return 1
            fi
            drain_mode="async"
        elif ! systemctl stop "$(unit_name "$current_unit")"; then
            echo "failed to stop ${current_unit}; pending=${pending_file}" >&2
            return 1
        else
            drain_mode="blocking"
        fi
    fi

    if [[ -f "${SYSTEMD_DIR}/$(unit_name "$current_unit")" ]]; then
        systemctl disable "$(unit_name "$current_unit")" >/dev/null 2>&1 || true
    fi

    echo "$candidate" >"${PID_DIR}/${service}.slot"
    retire_legacy_unit "$service"
    rm -f "$pending_file"
    echo "rolling update complete: ${service} ${candidate} active (${effective_mode}, drain=${drain_mode})"
}

async_drain=0
if [[ "${1:-}" == "--async-drain" ]]; then
    async_drain=1
    shift
fi

rolling_update "$async_drain" "$@"
