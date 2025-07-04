#!/bin/bash

# 服务管理脚本
# 用法: ./svr_manager.sh [start|stop|restart|status]

set -euo pipefail

# 获取脚本所在目录的绝对路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR=$(dirname "$SCRIPT_DIR")
BIN_DIR="${PARENT_DIR}/bin"
LOG_DIR="${PARENT_DIR}/logs"
PID_DIR="${PARENT_DIR}/pids"

# 确保日志和pid目录存在
mkdir -p "$LOG_DIR"
mkdir -p "$PID_DIR"

# 获取所有服务
get_services() {
    find "$BIN_DIR" -maxdepth 1 -type f -name '*_svr' -exec basename {} \;
}

# 启动服务
start_service() {
    local svr_name="$1"
    local pid_file="${PID_DIR}/${svr_name}.pid"
    local log_file="${LOG_DIR}/${svr_name}.log"
    
    if [ -f "$pid_file" ] && ps -p $(cat "$pid_file") > /dev/null 2>&1; then
        echo "Service $svr_name is already running (pid: $(cat "$pid_file"))"
        return 0
    fi
    
    echo "Starting $svr_name..."
    cd "$BIN_DIR"
    nohup "./${svr_name}" >> "$log_file" 2>&1 &
    local pid=$!
    cd - > /dev/null
    echo "$pid" > "$pid_file"
    echo "Started $svr_name (pid: $pid)"
}

# 停止服务
stop_service() {
    local svr_name="$1"
    local pid_file="${PID_DIR}/${svr_name}.pid"
    
    if [ ! -f "$pid_file" ]; then
        echo "Service $svr_name is not running (no pid file)"
        return 0
    fi
    
    local pid=$(cat "$pid_file")
    if ps -p "$pid" > /dev/null 2>&1; then
        echo "Stopping $svr_name (pid: $pid)..."
        kill "$pid"
        rm -f "$pid_file"
        echo "Stopped $svr_name"
    else
        echo "Service $svr_name is not running (stale pid file)"
        rm -f "$pid_file"
    fi
}

# 检查服务状态
status_service() {
    local svr_name="$1"
    local pid_file="${PID_DIR}/${svr_name}.pid"
    
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        if ps -p "$pid" > /dev/null 2>&1; then
            echo "Service $svr_name is running (pid: $pid)"
        else
            echo "Service $svr_name is not running (stale pid file)"
        fi
    else
        echo "Service $svr_name is not running"
    fi
}

# 主逻辑
main() {
    local action="${1:-status}"
    local services=$(get_services)
    
    if [ -z "$services" ]; then
        echo "No services found in $BIN_DIR"
        return 1
    fi
    
    case "$action" in
        start)
            for svr in $services; do
                start_service "$svr"
            done
            ;;
        stop)
            for svr in $services; do
                stop_service "$svr"
            done
            ;;
        restart)
            for svr in $services; do
                stop_service "$svr"
                sleep 1
                start_service "$svr"
            done
            ;;
        status)
            for svr in $services; do
                status_service "$svr"
            done
            ;;
        *)
            echo "Usage: $0 [start|stop|restart|status]"
            exit 1
            ;;
    esac
}

main "$@"
