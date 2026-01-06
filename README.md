# tw_tools

统一的服务管理工具，用于管理项目的各种服务。

## 使用方法

```bash
./tw_tools.sh [command] [service_name]
```

## 命令说明

- `start [service]` - 启动所有服务或指定服务
- `stop [service]` - 停止所有服务或指定服务
- `restart [service]` - 重启所有服务或指定服务（停止 + 构建 + 启动）
- `build` - 构建所有服务
- `status [service]` - 查看所有服务或指定服务的状态
- `help` - 显示帮助信息

## 使用示例

```bash
# 启动所有服务
./tw_tools.sh start

# 停止所有服务
./tw_tools.sh stop

# 重启所有服务
./tw_tools.sh restart

# 构建所有服务
./tw_tools.sh build

# 查看所有服务状态
./tw_tools.sh status

# 启动指定服务
./tw_tools.sh start tw_proxy_svr

# 停止指定服务
./tw_tools.sh stop tw_proxy_svr

# 查看指定服务状态
./tw_tools.sh status tw_proxy_svr
```

## 旧版脚本

- `svr_restart.sh` - 旧的重启脚本（已废弃，请使用新版 `tw_tools.sh restart`）
- `gen_all.sh` - 构建脚本（仍可用，也可使用 `tw_tools.sh build`）