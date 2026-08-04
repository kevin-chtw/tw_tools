#!/bin/bash

# tw_tools.sh - 单文件服务管理（可直接放在 /pitaya/bin/tw_tools.sh）
# 用法: ./tw_tools.sh <cmd> [service_name]
#
# start 时若未装 systemd unit 会自动安装（Restart=always + 飞书告警）
# 未装 unit 且非 root / 无 systemd：回退 nohup + pid

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 目录自适应：
# - 脚本在 /pitaya/bin 且旁边有 *_svr → BIN_DIR=脚本目录
# - 脚本在 /pitaya/tw_tools → BIN_DIR=/pitaya/bin
if compgen -G "${SCRIPT_DIR}/*_svr" > /dev/null; then
    BIN_DIR="${SCRIPT_DIR}"
    PARENT_DIR="$(dirname "$SCRIPT_DIR")"
elif [[ -d "${SCRIPT_DIR}/../bin" ]]; then
    PARENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
    BIN_DIR="${PARENT_DIR}/bin"
else
    BIN_DIR="${SCRIPT_DIR}"
    PARENT_DIR="$(dirname "$SCRIPT_DIR")"
fi

PID_DIR="${PARENT_DIR}/pids"
LOG_DIR="${BIN_DIR}/logs"
SYSTEMD_DIR="/etc/systemd/system"
ALERT_CONF="${SCRIPT_DIR}/alert.conf"
COOLDOWN_DIR="${SCRIPT_DIR}/.alert_cooldown"

# 默认飞书 webhook（可用 alert.conf / 环境变量覆盖）
DEFAULT_FEISHU_WEBHOOK="https://open.feishu.cn/open-apis/bot/v2/hook/bc57c822-8111-4262-b650-3f251246817d"
DEFAULT_ALERT_COOLDOWN_SEC=600

mkdir -p "$PID_DIR" "$LOG_DIR" "$COOLDOWN_DIR"

# ---------- 基础 ----------

has_systemd() {
    command -v systemctl >/dev/null 2>&1 || return 1
    [[ -r /proc/1/comm ]] || return 1
    [[ "$(cat /proc/1/comm 2>/dev/null || true)" == "systemd" ]]
}

unit_name() { echo "${1}.service"; }

unit_installed() {
    has_systemd || return 1
    [[ -f "${SYSTEMD_DIR}/$(unit_name "$1")" ]]
}

require_root_for_systemd() {
    if [[ "$(id -u)" != "0" ]]; then
        echo "systemd 操作需要 root（请用 sudo）" >&2
        exit 1
    fi
}

sync_pid_file() {
    local svr_name="$1" unit pid
    unit="$(unit_name "$svr_name")"
    pid="$(systemctl show -p MainPID --value "$unit" 2>/dev/null || echo 0)"
    if [[ -n "$pid" && "$pid" != "0" ]]; then
        echo "$pid" >"${PID_DIR}/${svr_name}.pid"
    else
        rm -f "${PID_DIR}/${svr_name}.pid"
    fi
}

get_services() {
    local f
    for f in "${BIN_DIR}"/*_svr; do
        [[ -f "$f" && -x "$f" ]] || continue
        basename "$f"
    done | sort -u
}

get_target_services() {
    local service_name="${1:-}"
    if [[ -n "$service_name" ]]; then
        if [[ -f "${BIN_DIR}/${service_name}" ]]; then
            echo "$service_name"
        else
            echo "Service $service_name not found in $BIN_DIR" >&2
            exit 1
        fi
    else
        get_services
    fi
}

# ---------- 飞书告警（内嵌） ----------

load_alert_conf() {
    FEISHU_WEBHOOK="${FEISHU_WEBHOOK:-$DEFAULT_FEISHU_WEBHOOK}"
    ALERT_COOLDOWN_SEC="${ALERT_COOLDOWN_SEC:-$DEFAULT_ALERT_COOLDOWN_SEC}"
    if [[ -f "$ALERT_CONF" ]]; then
        # shellcheck disable=SC1090
        source "$ALERT_CONF"
        FEISHU_WEBHOOK="${FEISHU_WEBHOOK:-$DEFAULT_FEISHU_WEBHOOK}"
        ALERT_COOLDOWN_SEC="${ALERT_COOLDOWN_SEC:-$DEFAULT_ALERT_COOLDOWN_SEC}"
    fi
}

feishu_alert() {
    local svr="${1:-unknown}"
    local reason="${2:-stopped}"
    svr="${svr%.service}"
    load_alert_conf

    local host ts now last cool_file text payload resp
    host="$(hostname -s 2>/dev/null || hostname)"
    ts="$(date '+%Y-%m-%d %H:%M:%S')"

    if [[ -z "${FEISHU_WEBHOOK:-}" ]]; then
        echo "FEISHU_WEBHOOK 未配置，跳过告警" >&2
        return 0
    fi
    if [[ -f "${PID_DIR}/${svr}.maint" ]]; then
        echo "maintenance flag set for $svr，跳过告警"
        return 0
    fi

    cool_file="${COOLDOWN_DIR}/${svr}.ts"
    now="$(date +%s)"
    if [[ -f "$cool_file" ]]; then
        last="$(cat "$cool_file" 2>/dev/null || echo 0)"
        if [[ "$last" =~ ^[0-9]+$ ]] && (( now - last < ALERT_COOLDOWN_SEC )); then
            echo "cooldown ${svr} $((ALERT_COOLDOWN_SEC - (now - last)))s left，跳过"
            return 0
        fi
    fi

    text="【服务告警】${svr} ${reason}
主机: ${host}
时间: ${ts}"

    if ! command -v python3 >/dev/null 2>&1 && ! command -v python >/dev/null 2>&1; then
        echo "需要 python3 发送飞书 JSON" >&2
        return 1
    fi
    local py=python3
    command -v python3 >/dev/null 2>&1 || py=python

    payload="$(ALERT_TEXT="$text" "$py" -c 'import json,os; print(json.dumps({"msg_type":"text","content":{"text":os.environ["ALERT_TEXT"]}}))')"
    if command -v curl >/dev/null 2>&1; then
        resp="$(curl -sS -X POST -H 'Content-Type: application/json' -d "$payload" "$FEISHU_WEBHOOK" || true)"
    else
        resp="$(ALERT_TEXT="$text" FEISHU_WEBHOOK="$FEISHU_WEBHOOK" "$py" - <<'PY' || true
import json, os, urllib.request
payload = {"msg_type": "text", "content": {"text": os.environ["ALERT_TEXT"]}}
req = urllib.request.Request(os.environ["FEISHU_WEBHOOK"], data=json.dumps(payload).encode(),
                             headers={"Content-Type": "application/json"}, method="POST")
print(urllib.request.urlopen(req, timeout=10).read().decode())
PY
)"
    fi
    echo "feishu resp: ${resp:-}"
    echo "$now" >"$cool_file"
}

# ---------- nohup 回退 ----------

start_service_nohup() {
    local svr_name="$1"
    local pid_file="${PID_DIR}/${svr_name}.pid"
    if [[ -f "$pid_file" ]] && ps -p "$(cat "$pid_file")" >/dev/null 2>&1; then
        echo "Service $svr_name is already running (pid: $(cat "$pid_file"))"
        return 0
    fi
    echo "Starting $svr_name (nohup)..."
    (
        cd "$BIN_DIR"
        nohup "./${svr_name}" >>"${LOG_DIR}/${svr_name}.out" 2>>"${LOG_DIR}/${svr_name}.err" &
        echo $! >"$pid_file"
    )
    echo "Started $svr_name (pid: $(cat "$pid_file"))"
}

stop_service_nohup() {
    local svr_name="$1"
    local pid_file="${PID_DIR}/${svr_name}.pid" pid count
    if [[ ! -f "$pid_file" ]]; then
        echo "Service $svr_name is not running (no pid file)"
        return 0
    fi
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [[ -z "$pid" ]]; then
        rm -f "$pid_file"
        return 0
    fi
    if ps -p "$pid" >/dev/null 2>&1; then
        echo "Stopping $svr_name (pid: $pid)..."
        kill "$pid" 2>/dev/null || true
        count=0
        while [[ $count -lt 5 ]] && ps -p "$pid" >/dev/null 2>&1; do
            sleep 1
            count=$((count + 1))
        done
        if ps -p "$pid" >/dev/null 2>&1; then
            kill -9 "$pid" 2>/dev/null || true
            echo "Force killed $svr_name"
        else
            echo "Stopped $svr_name gracefully"
        fi
    else
        echo "Service $svr_name is not running (stale pid file)"
    fi
    rm -f "$pid_file"
}

# ---------- systemd ----------

write_service_unit() {
    local svr_name="$1"
    local out="${SYSTEMD_DIR}/$(unit_name "$svr_name")"
    cat >"$out" <<EOF
[Unit]
Description=${svr_name}
After=network-online.target
Wants=network-online.target
OnFailure=tw-alert@%p.service

[Service]
Type=simple
WorkingDirectory=${BIN_DIR}
ExecStart=${BIN_DIR}/${svr_name}
Restart=always
RestartSec=3
StartLimitIntervalSec=120
StartLimitBurst=5
KillMode=mixed
TimeoutStopSec=15
StandardOutput=append:${LOG_DIR}/${svr_name}.out
StandardError=append:${LOG_DIR}/${svr_name}.err

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$out"
}

write_alert_unit() {
    local out="${SYSTEMD_DIR}/tw-alert@.service"
    # 用绝对路径调用本脚本发告警，单文件即可
    cat >"$out" <<EOF
[Unit]
Description=Feishu alert for %i
After=network-online.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_DIR}/tw_tools.sh alert %i failed
EOF
    chmod 0644 "$out"
}

start_service() {
    local svr_name="$1"

    # 有 systemd 时：未装 unit 则自动安装（需 root），已装则直接 start
    if has_systemd; then
        if ! unit_installed "$svr_name"; then
            if [[ "$(id -u)" == "0" ]]; then
                echo "$svr_name 未安装 systemd unit，自动安装并启动..."
                install_systemd_unit "$svr_name"
                return 0
            fi
            echo "警告: $svr_name 未装 unit 且非 root，无法自动安装，回退 nohup" >&2
            start_service_nohup "$svr_name"
            return 0
        fi
        echo "Starting $svr_name (systemd)..."
        systemctl start "$(unit_name "$svr_name")"
        sync_pid_file "$svr_name"
        rm -f "${PID_DIR}/${svr_name}.maint"
        echo "Started $svr_name via systemd (pid: $(cat "${PID_DIR}/${svr_name}.pid" 2>/dev/null || echo '?'))"
        return 0
    fi

    start_service_nohup "$svr_name"
}

stop_service() {
    local svr_name="$1"
    if unit_installed "$svr_name"; then
        echo "Stopping $svr_name (systemd)..."
        touch "${PID_DIR}/${svr_name}.maint"
        systemctl stop "$(unit_name "$svr_name")" || true
        systemctl reset-failed "$(unit_name "$svr_name")" 2>/dev/null || true
        rm -f "${PID_DIR}/${svr_name}.pid"
        echo "Stopped $svr_name via systemd (maint on)"
        return 0
    fi
    stop_service_nohup "$svr_name"
}

status_service() {
    local svr_name="$1" pid_file="${PID_DIR}/${svr_name}.pid"
    if unit_installed "$svr_name"; then
        local unit state pid
        unit="$(unit_name "$svr_name")"
        state="$(systemctl is-active "$unit" 2>/dev/null || echo inactive)"
        pid="$(systemctl show -p MainPID --value "$unit" 2>/dev/null || echo 0)"
        echo "Service $svr_name systemd=$state pid=${pid} unit=$unit"
        return 0
    fi
    if [[ -f "$pid_file" ]] && ps -p "$(cat "$pid_file")" >/dev/null 2>&1; then
        echo "Service $svr_name is running (pid: $(cat "$pid_file"), mode=nohup)"
    else
        echo "Service $svr_name is not running (mode=nohup)"
    fi
}

install_systemd_unit() {
    local svr_name="$1"
    require_root_for_systemd
    has_systemd || { echo "当前系统不是 systemd" >&2; exit 1; }
    [[ -x "${BIN_DIR}/${svr_name}" ]] || { echo "二进制不存在或不可执行: ${BIN_DIR}/${svr_name}" >&2; exit 1; }

    if ! unit_installed "$svr_name"; then
        stop_service_nohup "$svr_name" || true
    fi

    write_alert_unit
    write_service_unit "$svr_name"
    systemctl daemon-reload
    systemctl enable "$(unit_name "$svr_name")"
    systemctl restart "$(unit_name "$svr_name")"
    sync_pid_file "$svr_name"
    rm -f "${PID_DIR}/${svr_name}.maint"
    echo "Installed $(unit_name "$svr_name") (Restart=always + Feishu)"
    systemctl status "$(unit_name "$svr_name")" --no-pager -l || true
}

uninstall_systemd_unit() {
    local svr_name="$1" unit
    require_root_for_systemd
    unit="$(unit_name "$svr_name")"
    [[ -f "${SYSTEMD_DIR}/${unit}" ]] || { echo "Unit not installed: $unit"; return 0; }
    systemctl stop "$unit" 2>/dev/null || true
    systemctl disable "$unit" 2>/dev/null || true
    rm -f "${SYSTEMD_DIR}/${unit}"
    systemctl daemon-reload
    systemctl reset-failed "$unit" 2>/dev/null || true
    rm -f "${PID_DIR}/${svr_name}.pid"
    echo "Uninstalled $unit"
}

watch_alert() {
    local svr unit state
    for svr in $(get_services); do
        unit_installed "$svr" || continue
        unit="$(unit_name "$svr")"
        state="$(systemctl is-active "$unit" 2>/dev/null || echo inactive)"
        if [[ "$state" != "active" ]]; then
            echo "$svr is $state，发送告警"
            feishu_alert "$svr" "stopped(state=${state})" || true
        fi
    done
}

maint_on() {
    local svr
    for svr in $(get_target_services "${1:-}"); do
        touch "${PID_DIR}/${svr}.maint"
        echo "maint on: $svr"
    done
}

maint_off() {
    local svr
    for svr in $(get_target_services "${1:-}"); do
        rm -f "${PID_DIR}/${svr}.maint"
        echo "maint off: $svr"
    done
}

show_usage() {
    cat <<EOF
Usage: $0 <command> [service_name]

目录: BIN_DIR=${BIN_DIR}  PID_DIR=${PID_DIR}

Commands:
  start [svc]                 启动（未装 systemd unit 时自动安装并托管）
  stop [svc]                  停止（开 maint，避免告警误报）
  status [svc]                状态
  restart / restart-svc [svc] 重启（未装 unit 时同 start，会自动安装）
  uninstall-systemd [svc]     卸载 unit（一般不用）
  watch-alert                 巡检停服告警（建议 cron 每分钟）
  test-alert [name]           试发飞书
  alert <svc> <reason>        内部/OnFailure 调用
  maint-on|maint-off [svc]    维护静默
  help

Jenkins 发布（无需改命令）:
  $0 stop tw_mjsc_svr
  # 覆盖二进制...
  $0 start tw_mjsc_svr

首次上线也可直接:
  sudo $0 start               # 对本机全部 *_svr 自动装 unit 并启动
EOF
}

main() {
    local command="${1:-help}"
    local service_name="${2:-}"
    local reason="${3:-stopped}"
    local services svr

    case "$command" in
        start)
            for svr in $(get_target_services "$service_name"); do start_service "$svr"; done
            ;;
        stop)
            for svr in $(get_target_services "$service_name"); do stop_service "$svr"; done
            ;;
        status)
            for svr in $(get_target_services "$service_name"); do status_service "$svr"; done
            ;;
        restart-svc|restart)
            for svr in $(get_target_services "$service_name"); do
                # 未装 unit 时走 start（自动安装）；已装则 restart
                if unit_installed "$svr"; then
                    systemctl restart "$(unit_name "$svr")"
                    sync_pid_file "$svr"
                    rm -f "${PID_DIR}/${svr}.maint"
                    echo "Restarted $svr"
                else
                    start_service "$svr"
                fi
            done
            ;;
        uninstall-systemd)
            for svr in $(get_target_services "$service_name"); do uninstall_systemd_unit "$svr"; done
            ;;
        watch-alert)
            watch_alert
            ;;
        test-alert)
            feishu_alert "${service_name:-tw_tools_test}" "test"
            ;;
        alert)
            # OnFailure: tw_tools.sh alert %i failed
            feishu_alert "${service_name:-unknown}" "${reason}"
            ;;
        maint-on)
            maint_on "$service_name"
            ;;
        maint-off)
            maint_off "$service_name"
            ;;
        help|--help|-h)
            show_usage
            ;;
        build)
            echo "线上单文件模式不支持 build（请在 CI 编译后上传二进制）" >&2
            exit 1
            ;;
        *)
            echo "Unknown command: $command" >&2
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
