#!/bin/bash
# Hermes 微信 iLink 一键安装脚本
# 适用于 Linux/macOS

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=========================================="
echo "  Hermes 微信 iLink Bot 一键安装"
echo "=========================================="

# 检测系统
if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "✓ 检测到 macOS"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    echo "✓ 检测到 Linux"
else
    echo "⚠ 未知系统: $OSTYPE"
fi

# 检查 Python
if ! command -v python3 &> /dev/null; then
    echo "✗ 请先安装 Python 3.9+"
    exit 1
fi
echo "✓ Python: $(python3 --version)"

# 检查 Hermes
HERMES_DIR="$HOME/.hermes"
if [ ! -d "$HERMES_DIR" ]; then
    echo ""
    echo "Hermes 未安装，正在安装..."
    pip install hermes-agent --break-system-packages 2>/dev/null || pip install hermes-agent
fi

# 安装 wechatbot-sdk
echo ""
echo "安装微信 SDK..."
pip install wechatbot-sdk qrcode --break-system-packages 2>/dev/null || pip install wechatbot-sdk qrcode

# 安装 Hermes 适配器
echo ""
echo "安装 Hermes 微信适配器..."

HERMES_AGENT_DIR="$HERMES_DIR/hermes-agent"
if [ -d "$HERMES_AGENT_DIR" ]; then
    # 复制适配器文件
    cp wechat_ilink.py "$HERMES_AGENT_DIR/gateway/platforms/" 2>/dev/null || true

    # 修改 config.py 添加 Platform
    if ! grep -q "WECHAT_ILINK" "$HERMES_AGENT_DIR/gateway/config.py" 2>/dev/null; then
        sed -i.bak 's/WECOM = "wecom"/WECOM = "wecom"\n    WECHAT_ILINK = "wechat_ilink"/' "$HERMES_AGENT_DIR/gateway/config.py" 2>/dev/null || true
    fi

    echo "✓ 适配器已安装"
else
    echo "⚠ Hermes agent 目录不存在，请先运行 hermes 初始化"
fi

# 配置环境变量
ENV_FILE="$HERMES_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
    touch "$ENV_FILE"
fi

if ! grep -q "GATEWAY_ALLOW_ALL_USERS" "$ENV_FILE" 2>/dev/null; then
    echo "" >> "$ENV_FILE"
    echo "# 微信 iLink 配置" >> "$ENV_FILE"
    echo "GATEWAY_ALLOW_ALL_USERS=true" >> "$ENV_FILE"
    echo "WECHAT_ILINK_ALLOW_ALL_USERS=true" >> "$ENV_FILE"
    echo "✓ 环境变量已配置"
fi

# 创建启动脚本
START_SCRIPT="$HERMES_DIR/start-wechat.sh"
cat > "$START_SCRIPT" << 'STARTSCRIPT'
#!/bin/bash
# Hermes 微信启动脚本

cd ~/.hermes/hermes-agent
python3 -m gateway.run 2>&1 | while read line; do
    echo "$line"
    # 检测二维码URL并显示
    if [[ "$line" == *"liteapp.weixin.qq.com"* ]]; then
        echo ""
        echo "=========================================="
        echo "  📱 请用微信扫描下方二维码登录"
        echo "=========================================="
        URL=$(echo "$line" | grep -o 'https://[^ ]*')
        echo "链接: $URL"
        echo ""
        # 生成终端二维码
        if command -v qrcode &> /dev/null; then
            qrcode "$URL"
        fi
        echo "=========================================="
    fi
done
STARTSCRIPT

chmod +x "$START_SCRIPT"
echo "✓ 启动脚本已创建: $START_SCRIPT"

# 完成
echo ""
echo "=========================================="
echo "  ✓ 安装完成！"
echo "=========================================="
echo ""
echo "启动方式："
echo "  方式1 (手动):  python3 ~/.hermes/hermes-agent/start-wechat.py"
echo "  方式2 (服务):  bash $SCRIPT_DIR/hermes-wechat.sh install"
echo "                bash $SCRIPT_DIR/hermes-wechat.sh enable  # 开机自启"
echo "                bash $SCRIPT_DIR/hermes-wechat.sh start   # 立即启动"
echo ""
echo "管理命令："
echo "  bash hermes-wechat.sh status   # 查看状态"
echo "  bash hermes-wechat.sh logs     # 查看日志"
echo "  bash hermes-wechat.sh stop     # 停止服务"
echo ""