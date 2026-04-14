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

# 5. 通过 git checkout 恢复官方 Hermes 文件（最可靠）
if [ -d "$HERMES_AGENT_DIR/.git" ]; then
    echo "通过 git 恢复官方文件..."
    if git -C "$HERMES_AGENT_DIR" checkout HEAD -- "$CONFIG_PY" "$RUN_PY" "$TOOLS_CONFIG" 2>/dev/null; then
        echo "✓ config.py、run.py、tools_config.py 已恢复（git）"
        # git 已恢复，跳过 .bak 恢复并清理残留 .bak
        rm -f "${CONFIG_PY}.bak" "${RUN_PY}.bak" "${TOOLS_CONFIG}.bak"
    else
        echo "⚠ git checkout 部分失败，尝试 .bak 恢复..."
        for f in "$CONFIG_PY" "$RUN_PY" "$TOOLS_CONFIG"; do
            [ -f "${f}.bak" ] && mv "${f}.bak" "$f" && echo "✓ $(basename "$f") 已恢复（.bak）"
        done
    fi
else
    echo "⚠ 非 git 安装，使用 .bak 恢复..."
    for f in "$CONFIG_PY" "$RUN_PY" "$TOOLS_CONFIG"; do
        [ -f "${f}.bak" ] && mv "${f}.bak" "$f" && echo "✓ $(basename "$f") 已恢复（.bak）"
    done
fi

# 7. 清理 config.yaml 中的 wechat_ilink 配置残留
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

# 8. 清理 .env 中的 wechat_ilink 变量
if [ -f "$ENV_FILE" ]; then
    sed -i '/WECHAT_ILINK/d' "$ENV_FILE"
    sed -i '/微信 iLink/d' "$ENV_FILE"
    echo "✓ .env 已清理"
fi

# 9. 清理 wechatbot 凭据
if [ -d "$HOME/.wechatbot" ]; then
    rm -rf "$HOME/.wechatbot"
    echo "✓ wechatbot 凭据已清理"
fi

# 10. 最终验证
echo ""
echo "=== 残留检查 ==="
RESIDUE=false
for f in "$CONFIG_PY" "$RUN_PY" "$TOOLS_CONFIG"; do
    if [ -f "$f" ] && grep -q "WECHAT_ILINK\|wechat_ilink" "$f" 2>/dev/null; then
        echo "⚠ $(basename "$f") 仍有 wechat_ilink 残留"
        RESIDUE=true
    fi
done
if [ "$RESIDUE" = false ]; then
    echo "✓ 无残留"
fi

echo ""
echo "=========================================="
echo "  ✓ 卸载完成！"
echo "=========================================="
echo ""
echo "如需使用官方微信，请编辑 $CONFIG_YAML 确认 weixin 已启用"
