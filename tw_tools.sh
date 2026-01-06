#!/bin/bash

# tw_tools - 统一的服务管理工具
# 用法: ./tw_tools.sh [stop|start|build|restart|status] [service_name]

set -euo pipefail

# 获取脚本所在目录的绝对路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR=$(dirname "$SCRIPT_DIR")
BIN_DIR="${PARENT_DIR}/bin"
PID_DIR="${PARENT_DIR}/pids"

# 确保pid目录存在
mkdir -p "$PID_DIR"

# 获取所有服务
get_services() {
    find "$BIN_DIR" -maxdepth 1 -type f -name '*_svr' -exec basename {} \;
}

# 获取指定服务或所有服务
get_target_services() {
    local service_name="${1:-}"
    if [ -n "$service_name" ]; then
        if [ -f "${BIN_DIR}/${service_name}" ]; then
            echo "$service_name"
        else
            echo "Service $service_name not found in $BIN_DIR" >&2
            exit 1
        fi
    else
        get_services
    fi
}

# 启动服务
start_service() {
    local svr_name="$1"
    local pid_file="${PID_DIR}/${svr_name}.pid"

    if [ -f "$pid_file" ] && ps -p $(cat "$pid_file") > /dev/null 2>&1; then
        echo "Service $svr_name is already running (pid: $(cat "$pid_file"))"
        return 0
    fi

    echo "Starting $svr_name..."
    cd "$BIN_DIR"
    nohup "./${svr_name}" > /dev/null 2>&1 &
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
        # 等待进程结束，最多等待10秒
        local count=0
        while [ $count -lt 10 ] && ps -p "$pid" > /dev/null 2>&1; do
            sleep 1
            ((count++))
        done
        if ps -p "$pid" > /dev/null 2>&1; then
            echo "Force killing $svr_name (pid: $pid)..."
            kill -9 "$pid"
        fi
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

# 构建服务
build_services() {
    echo "Building services..."
    if ! "$SCRIPT_DIR/gen_all.sh"; then
        echo "Build failed"
        exit 1
    fi
    echo "Build completed successfully"
}

# 显示使用帮助
show_usage() {
    echo "Usage: $0 [command] [service_name]"
    echo ""
    echo "Commands:"
    echo "  start [service]    Start all services or specific service"
    echo "  stop [service]     Stop all services or specific service"
    echo "  restart [service]  Restart all services or specific service (stop + build + start)"
    echo "  build              Build all services"
    echo "  status [service]   Show status of all services or specific service"
    echo "  help               Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 start           # Start all services"
    echo "  $0 stop tw_proxy_svr  # Stop specific service"
    echo "  $0 restart         # Restart all services"
    echo "  $0 build           # Build all services"
    echo "  $0 status          # Show status of all services"
}

# 主逻辑
main() {
    local command="${1:-help}"
    local service_name="${2:-}"

    case "$command" in
        start)
            local services=$(get_target_services "$service_name")
            for svr in $services; do
                start_service "$svr"
            done
            ;;
        stop)
            local services=$(get_target_services "$service_name")
            for svr in $services; do
                stop_service "$svr"
            done
            ;;
        restart)
            local services=$(get_target_services "$service_name")
            # 停止服务
            for svr in $services; do
                stop_service "$svr"
            done
            # 构建服务
            build_services
            # 清理日志
            rm -rf "${PARENT_DIR}/bin/logs/"
            # 启动服务
            for svr in $services; do
                start_service "$svr"
            done
            ;;
        build)
            if [ -n "$service_name" ]; then
                echo "Error: build command doesn't support specific service yet" >&2
                exit 1
            fi
            build_services
            ;;
        status)
            local services=$(get_target_services "$service_name")
            for svr in $services; do
                status_service "$svr"
            done
            ;;
        help|--help|-h)
            show_usage
            ;;
        *)
            echo "Unknown command: $command" >&2
            echo "" >&2
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
