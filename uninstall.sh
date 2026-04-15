#!/bin/bash
# Hermes 微信 iLink 卸载脚本 v2.0
# 功能：撤销 install.sh 的所有操作

set -e

HERMES_DIR="$HOME/.hermes"
HERMES_AGENT_DIR="$HERMES_DIR/hermes-agent"
PLATFORMS_DIR="$HERMES_AGENT_DIR/gateway/platforms"
CONFIG_YAML="$HERMES_DIR/config.yaml"
ENV_FILE="$HERMES_DIR/.env"
SERVICE_FILE="/etc/systemd/system/hermes-wechat.service"

# 定位 venv site-packages
if [ -d "$HERMES_AGENT_DIR/venv" ]; then
    VENV_SITE_PACKAGES=$("$HERMES_AGENT_DIR/venv/bin/python" -c "import site; print(site.getsitepackages()[0])" 2>/dev/null)
else
    VENV_SITE_PACKAGES=""
fi

echo "=========================================="
echo "  Hermes 微信 iLink Bot 卸载脚本 v2.0"
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

# 3b. 删除运行时补丁初始化文件
if [ -f "$PLATFORMS_DIR/wechat_ilink_init.py" ]; then
    rm -f "$PLATFORMS_DIR/wechat_ilink_init.py"
    echo "✓ wechat_ilink_init.py 已删除"
fi

# 4. 恢复官方微信 weixin.py
if [ -f "$PLATFORMS_DIR/weixin.py.disabled.bak" ]; then
    mv "$PLATFORMS_DIR/weixin.py.disabled.bak" "$PLATFORMS_DIR/weixin.py"
    echo "✓ 官方 weixin.py 已恢复"
fi

# 5. 删除运行时注入补丁（sitecustomize.py）
if [ -n "$VENV_SITE_PACKAGES" ] && [ -f "$VENV_SITE_PACKAGES/sitecustomize.py" ]; then
    rm -f "$VENV_SITE_PACKAGES/sitecustomize.py"
    echo "✓ sitecustomize.py（运行时补丁）已删除"
fi

# 6. 清理 config.yaml 中的 wechat_ilink 配置残留
if [ -f "$CONFIG_YAML" ]; then
    if grep -q "wechat_ilink:" "$CONFIG_YAML" 2>/dev/null; then
        python3 -c "
import yaml, re

with open('$CONFIG_YAML', 'r') as f:
    lines = f.readlines()

# Remove wechat_ilink block under platforms
result = []
skip = False
for line in lines:
    if re.match(r'\s+wechat_ilink:', line):
        skip = True
        continue
    if skip:
        if re.match(r'\s+\S', line) and not re.match(r'\s{6,}', line):
            skip = False
            result.append(line)
        continue
    result.append(line)

with open('$CONFIG_YAML', 'w') as f:
    f.writelines(result)
print('✓ config.yaml 已清理 wechat_ilink 配置')
"
    fi
    # 恢复 weixin 为 enabled: true
    if grep -A1 "weixin:" "$CONFIG_YAML" | grep -q "enabled: false" 2>/dev/null; then
        sed -i '/^  weixin:/,/^  [a-z]/{s/enabled: false/enabled: true/}' "$CONFIG_YAML"
        echo "✓ 官方 weixin 已重新启用"
    fi
fi

# 7. 清理 .env 中的 wechat_ilink 变量
if [ -f "$ENV_FILE" ]; then
    sed -i '/WECHAT_ILINK/d' "$ENV_FILE"
    sed -i '/微信 iLink/d' "$ENV_FILE"
    echo "✓ .env 已清理"
fi

# 8. 清理 wechatbot 凭据
if [ -d "$HOME/.wechatbot" ]; then
    rm -rf "$HOME/.wechatbot"
    echo "✓ wechatbot 凭据已清理"
fi

# 9. 最终验证
echo ""
echo "=== 残留检查 ==="
RESIDUE=false

# 检查 adapter 文件
if [ -f "$PLATFORMS_DIR/wechat_ilink.py" ]; then
    echo "⚠ wechat_ilink.py 仍存在"
    RESIDUE=true
fi

# 检查 sitecustomize.py
if [ -n "$VENV_SITE_PACKAGES" ] && [ -f "$VENV_SITE_PACKAGES/sitecustomize.py" ]; then
    echo "⚠ sitecustomize.py 仍存在"
    RESIDUE=true
fi

# 检查 config.yaml
if [ -f "$CONFIG_YAML" ] && grep -q "wechat_ilink:" "$CONFIG_YAML" 2>/dev/null; then
    echo "⚠ config.yaml 仍有 wechat_ilink 配置"
    RESIDUE=true
fi

if [ "$RESIDUE" = false ]; then
    echo "✓ 无残留"
fi

echo ""
echo "=========================================="
echo "  ✓ 卸载完成！"
echo "=========================================="
echo ""
echo "如需使用官方微信，请编辑 $CONFIG_YAML 确认 weixin 已启用"
