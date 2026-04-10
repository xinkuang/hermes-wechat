#!/bin/bash
# Hermes WeChat 服务管理脚本
# 用法: hermes-wechat.sh [start|stop|status|restart|logs|enable|disable|install]

set -e

SERVICE_NAME="hermes-wechat"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USER_NAME=$(whoami)
USER_HOME=$(eval echo "~$USER_NAME")
PYTHON_PATH="${USER_HOME}/.hermes/hermes-agent/venv/bin/python"

# 如果没有 venv，使用系统 python
if [ ! -f "$PYTHON_PATH" ]; then
    PYTHON_PATH=$(which python3)
fi

show_help() {
    echo "Hermes WeChat 服务管理"
    echo ""
    echo "用法: $0 <命令>"
    echo ""
    echo "命令:"
    echo "  install   - 安装 systemd 服务"
    echo "  start     - 启动服务"
    echo "  stop      - 停止服务"
    echo "  restart   - 重启服务"
    echo "  status    - 查看状态"
    echo "  logs      - 查看日志"
    echo "  enable    - 开机自启"
    echo "  disable   - 禁用自启"
    echo "  uninstall - 卸载服务"
    echo ""
}

install_service() {
    echo "安装 Hermes WeChat 服务..."

    # 检查 systemd
    if ! command -v systemctl &> /dev/null; then
        echo "✗ systemd 不可用，请使用 start-wechat.py 手动启动"
        exit 1
    fi

    # 生成 service 文件（使用 | 作为分隔符避免路径中的 / 冲突）
    cat "$SCRIPT_DIR/hermes-wechat.service" | \
        sed "s|%USER%|$USER_NAME|g" | \
        sed "s|%HOME%|$USER_HOME|g" | \
        sed "s|%PYTHON%|$PYTHON_PATH|g" > "$SERVICE_FILE"

    # 重新加载 systemd
    systemctl daemon-reload

    echo "✓ 服务文件已安装: $SERVICE_FILE"
    echo ""
    echo "下一步:"
    echo "  $0 enable   # 开机自启"
    echo "  $0 start    # 立即启动"
}

uninstall_service() {
    echo "卸载 Hermes WeChat 服务..."

    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload

    echo "✓ 服务已卸载"
}

start_service() {
    if [ -f "$SERVICE_FILE" ]; then
        systemctl start "$SERVICE_NAME"
        echo "✓ 服务已启动"
    else
        echo "服务未安装，请先运行: $0 install"
        echo ""
        echo "或手动启动: python3 ~/.hermes/hermes-agent/start-wechat.py"
    fi
}

stop_service() {
    if [ -f "$SERVICE_FILE" ]; then
        systemctl stop "$SERVICE_NAME"
        echo "✓ 服务已停止"
    else
        # 手动停止
        pkill -f "gateway.run" 2>/dev/null || true
        echo "✓ 已停止 gateway 进程"
    fi
}

restart_service() {
    if [ -f "$SERVICE_FILE" ]; then
        systemctl restart "$SERVICE_NAME"
        echo "✓ 服务已重启"
    else
        stop_service
        start_service
    fi
}

show_status() {
    if [ -f "$SERVICE_FILE" ]; then
        systemctl status "$SERVICE_NAME" --no-pager
    else
        echo "服务未安装"
        echo ""
        # 检查是否有手动运行的进程
        if pgrep -f "gateway.run" > /dev/null; then
            echo "当前有 gateway 进程正在运行:"
            ps aux | grep "gateway.run" | grep -v grep
        else
            echo "无 gateway 进程运行"
        fi
    fi
}

show_logs() {
    LOG_FILE="${USER_HOME}/.hermes/logs/gateway.log"
    if [ -f "$LOG_FILE" ]; then
        echo "最近 50 行日志:"
        echo "---"
        tail -50 "$LOG_FILE"
    else
        echo "日志文件不存在: $LOG_FILE"
    fi
}

enable_service() {
    if [ -f "$SERVICE_FILE" ]; then
        systemctl enable "$SERVICE_NAME"
        echo "✓ 已设置开机自启"
    else
        echo "服务未安装，请先运行: $0 install"
    fi
}

disable_service() {
    if [ -f "$SERVICE_FILE" ]; then
        systemctl disable "$SERVICE_NAME"
        echo "✓ 已禁用开机自启"
    else
        echo "服务未安装"
    fi
}

# 主逻辑
case "$1" in
    install)
        install_service
        ;;
    uninstall)
        uninstall_service
        ;;
    start)
        start_service
        ;;
    stop)
        stop_service
        ;;
    restart)
        restart_service
        ;;
    status)
        show_status
        ;;
    logs)
        show_logs
        ;;
    enable)
        enable_service
        ;;
    disable)
        disable_service
        ;;
    -h|--help|help)
        show_help
        ;;
    "")
        show_help
        ;;
    *)
        echo "未知命令: $1"
        echo ""
        show_help
        exit 1
        ;;
esac