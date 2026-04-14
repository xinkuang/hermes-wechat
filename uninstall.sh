#!/bin/bash
# Hermes 微信 iLink 卸载脚本
# 功能：撤销 install.sh 的所有操作

set -e

HERMES_DIR="$HOME/.hermes"
HERMES_AGENT_DIR="$HERMES_DIR/hermes-agent"
PLATFORMS_DIR="$HERMES_AGENT_DIR/gateway/platforms"
CONFIG_PY="$HERMES_AGENT_DIR/gateway/config.py"
RUN_PY="$HERMES_AGENT_DIR/gateway/run.py"
TOOLS_CONFIG="$HERMES_AGENT_DIR/hermes_cli/tools_config.py"
CONFIG_YAML="$HERMES_DIR/config.yaml"
ENV_FILE="$HERMES_DIR/.env"
SERVICE_FILE="/etc/systemd/system/hermes-wechat.service"

echo "=========================================="
echo "  Hermes 微信 iLink Bot 卸载脚本"
echo "=========================================="

# 1. 停止服务
if systemctl is-active --quiet hermes-wechat 2>/dev/null; then
    systemctl stop hermes-wechat
    echo "✓ hermes-wechat 服务已停止"
fi

# 2. 禁用/卸载 systemd 服务
if [ -f "$SERVICE_FILE" ]; then
    systemctl disable hermes-wechat 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    echo "✓ hermes-wechat systemd 服务已卸载"
fi

# 3. 删除适配器文件
if [ -f "$PLATFORMS_DIR/wechat_ilink.py" ]; then
    rm -f "$PLATFORMS_DIR/wechat_ilink.py"
    echo "✓ wechat_ilink.py 已删除"
fi

# 4. 恢复官方 weixin.py
if [ -f "$PLATFORMS_DIR/weixin.py.disabled.bak" ]; then
    mv "$PLATFORMS_DIR/weixin.py.disabled.bak" "$PLATFORMS_DIR/weixin.py"
    echo "✓ 官方 weixin.py 已恢复"
fi

# 5. 恢复 config.py（删除 .bak）
if [ -f "${CONFIG_PY}.bak" ]; then
    mv "${CONFIG_PY}.bak" "$CONFIG_PY"
    echo "✓ config.py 已恢复原始版本"
fi

# 6. 恢复 run.py（删除 .bak）
if [ -f "${RUN_PY}.bak" ]; then
    mv "${RUN_PY}.bak" "$RUN_PY"
    echo "✓ run.py 已恢复原始版本"
fi

# 7. 恢复 tools_config.py（删除 .bak）
if [ -f "${TOOLS_CONFIG}.bak" ]; then
    mv "${TOOLS_CONFIG}.bak" "$TOOLS_CONFIG"
    echo "✓ tools_config.py 已恢复原始版本"
fi

# 8. 恢复 config.yaml（删除 .bak，启用 weixin，删除 wechat_ilink）
if [ -f "${CONFIG_YAML}.bak" ]; then
    mv "${CONFIG_YAML}.bak" "$CONFIG_YAML"
    echo "✓ config.yaml 已恢复原始版本"
fi

# 9. 恢复 .env（删除 .bak）
if [ -f "${ENV_FILE}.bak" ]; then
    mv "${ENV_FILE}.bak" "$ENV_FILE"
    echo "✓ .env 已恢复原始版本"
fi

# 10. 清理 wechatbot 凭据
if [ -d "$HOME/.wechatbot" ]; then
    rm -rf "$HOME/.wechatbot"
    echo "✓ wechatbot 凭据已清理"
fi

echo ""
echo "=========================================="
echo "  ✓ 卸载完成！"
echo "=========================================="
echo ""
echo "如需恢复官方微信插件，请编辑 $CONFIG_YAML 启用 weixin 平台"
