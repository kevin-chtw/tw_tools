#!/bin/bash

# 设置严格模式
set -euo pipefail

# 定义变量
build_output_file="output.txt"

# 获取脚本所在目录的绝对路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR=$(dirname "$SCRIPT_DIR")

# 配置参数
TARGET_BIN_DIR="${PARENT_DIR}/bin"
TARGET_ETC_DIR="${TARGET_BIN_DIR}/etc"
BUILD_TAGS="" # 可以根据需要设置编译标签
# 限制并行任务数为CPU核心数的一半或最大8个，取较小值
MAX_PROCS=$(( $(nproc) / 2 > 8 ? 8 : $(nproc) / 2 ))
CLEAN_FLAG=false
MIN_GO_VERSION="1.16" # 最低需要的Go版本

# 日志函数
log_info() {
    echo "[INFO] $1" >&2
}

log_warn() {
    echo "[WARN] $1" >&2
}

log_error() {
    echo "[ERROR] $1" >&2
}

# 版本比较函数
version_gt() {
    test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"
}

# 检查Go版本
check_go_version() {
    if ! command -v go &> /dev/null; then
        log_error "Go is not installed"
        exit 1
    fi
    
    local current_version=$(go version | grep -oP 'go\K[0-9]+\.[0-9]+')
    if version_gt "$MIN_GO_VERSION" "$current_version"; then
        log_error "Go version $current_version is too old. Minimum required version is $MIN_GO_VERSION"
        exit 1
    fi
}

# 检查必要的命令是否存在
check_requirements() {
    local required_cmds=("go" "find" "cp" "mkdir" "grep" "sort")
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "Required command not found: $cmd"
            exit 1
        fi
    done
}

# 清理函数
clean_build() {
    log_info "Cleaning build artifacts..."
    find "${PARENT_DIR}" -type f -name "*.exe" -delete
    find "${PARENT_DIR}" -type f -name "*.test" -delete
    rm -rf "$TARGET_BIN_DIR"/*
    log_info "Clean completed"
}

# 创建目标目录
create_dirs() {
    mkdir -p "$TARGET_BIN_DIR"
    mkdir -p "$TARGET_ETC_DIR"
    log_info "Created target directories"
}

# 编译单个服务
build_service() {
    local dir="$1"
    local dir_name=$(basename "$dir")
    local start_time=$(date +%s)
    local build_output_file=$(mktemp)
    local build_status=0

    # 确保退出时清理临时文件
    trap 'rm -f "$build_output_file"' EXIT

    # 进入目标目录
    if ! cd "$dir"; then
        log_error "Failed to enter directory: $dir"
        return 1
    fi

    # 检查Go文件是否存在
    if ! find . -maxdepth 1 -name "*.go" | grep -q .; then
        log_warn "No .go files found in $dir"
        cd - > /dev/null
        return 0
    fi

    # 编译服务
    log_info "Building $dir_name..."
    if CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -tags="$BUILD_TAGS" -o "$dir_name" 2>"$build_output_file"; then
        # 复制可执行文件
        if ! mv "$dir_name" "$TARGET_BIN_DIR/"; then
            log_error "Failed to copy binary $dir_name to $TARGET_BIN_DIR"
            build_status=1
        fi

        # 复制配置文件
        if [ -d "etc" ]; then
            if find etc -maxdepth 1 -name "*.yaml" | grep -q .; then
                if ! cp etc/*.yaml "$TARGET_ETC_DIR/"; then
                    log_warn "Failed to copy YAML files for $dir_name"
                else
                    log_info "Copied YAML files for $dir_name"
                fi
            fi
        fi
    else
        log_error "Failed to build $dir_name"
        log_error "Build output: $(cat "$build_output_file")"
        build_status=1
    fi

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    if [ $build_status -eq 0 ]; then
        log_info "Built $dir_name in ${duration}s"
    fi

    cd - > /dev/null
    return $build_status
}

# 构建所有服务
build_all_services() {
    local build_count=0
    local failed_count=0
    local start_time=$(date +%s)
    local temp_file=$(mktemp)
    
    # 确保退出时清理临时文件
    trap 'rm -f "$temp_file" 2>/dev/null || true' EXIT
    
    # 查找所有包含main.go文件的子目录
    find "${PARENT_DIR}" -mindepth 1 -maxdepth 2 -type d -exec test -f {}/main.go \; -print > "$temp_file"
    
    # 计算总服务数
    local total_services=$(wc -l < "$temp_file")
    log_info "Found $total_services services to build"

    # 读取每个服务目录并串行构建
    while IFS= read -r dir; do
        if build_service "$dir"; then
            ((build_count++))
        else
            ((failed_count++))
            log_error "Build failed for $dir"
        fi
    done < "$temp_file"

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    log_info "Build Summary:"
    log_info "Total services: $total_services"
    log_info "Successfully built: $build_count"
    if [ "$failed_count" -gt 0 ]; then
        log_error "Failed builds: $failed_count"
    else
        log_info "Failed builds: $failed_count"
    fi
    log_info "Total time: ${duration}s"
    
    [ "$failed_count" -eq 0 ]
    return $?
}

# 主函数
main() {
    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            --clean)
                CLEAN_FLAG=true
                shift
                ;;
            --tags=*)
                BUILD_TAGS="${1#*=}"
                shift
                ;;
            --jobs=*)
                local requested_jobs="${1#*=}"
                if [[ "$requested_jobs" =~ ^[0-9]+$ ]]; then
                    MAX_PROCS=$requested_jobs
                else
                    log_error "Invalid number of jobs: $requested_jobs"
                    exit 1
                fi
                shift
                ;;
            *)
                log_error "Unknown parameter: $1"
                echo "Usage: $0 [--clean] [--tags=<build-tags>] [--jobs=<number>]"
                exit 1
                ;;
        esac
    done

    # 检查环境
    check_requirements
    check_go_version

    # 如果指定了clean标志，执行清理
    if [ "$CLEAN_FLAG" = true ]; then
        clean_build
    fi

    # 创建必要的目录
    create_dirs

    # 编译所有服务
    log_info "Starting build process..."
    if ! build_all_services; then
        log_error "Some services failed to build"
        exit 1
    fi

    log_info "Build completed successfully"
}

# 执行主函数
main "$@"