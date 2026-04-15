#!/bin/bash
# Hermes 微信 iLink 一键安装脚本 v2.0
#
# 新架构：运行时注入（不再 sed 修改源码）
# 原理：sitecustomize.py 在 Python 启动时拦截模块导入并注入补丁
# 优势：Hermes 升级后无需重新安装，补丁自动重新应用
#
# 适用于 Linux/macOS

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=========================================="
echo "  Hermes 微信 iLink 一键安装脚本 v2.0"
echo "  运行时注入模式（不修改源码）"
echo "=========================================="

# ---------------------------------------------------------------------------
# 1. 系统检测
# ---------------------------------------------------------------------------
if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "✓ 检测到 macOS"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    echo "✓ 检测到 Linux"
else
    echo "⚠ 未知系统: $OSTYPE"
fi

if ! command -v python3 &> /dev/null; then
    echo "✗ 请先安装 Python 3.9+"
    exit 1
fi
echo "✓ Python: $(python3 --version)"

# ---------------------------------------------------------------------------
# 2. 定位 Hermes 目录
# ---------------------------------------------------------------------------
HERMES_DIR="$HOME/.hermes"
HERMES_AGENT_DIR="$HERMES_DIR/hermes-agent"

if [ ! -d "$HERMES_AGENT_DIR" ]; then
    echo ""
    echo "Hermes 未安装，正在安装..."
    pip install hermes-agent --break-system-packages 2>/dev/null || pip install hermes-agent
fi

PLATFORMS_DIR="$HERMES_AGENT_DIR/gateway/platforms"
CONFIG_YAML="$HERMES_DIR/config.yaml"
ENV_FILE="$HERMES_DIR/.env"

# 确定使用的 Python
if [ -f "$HERMES_AGENT_DIR/venv/bin/python" ]; then
    PYTHON="$HERMES_AGENT_DIR/venv/bin/python"
    VENV_SITE_PACKAGES="$HERMES_AGENT_DIR/venv/lib/python"*/site-packages
else
    PYTHON="python3"
    VENV_SITE_PACKAGES=""
fi
echo "✓ Python 路径: $PYTHON"

# ---------------------------------------------------------------------------
# 3. 安装依赖
# ---------------------------------------------------------------------------
echo ""
echo "安装依赖..."
$PYTHON -m pip install wechatbot-sdk qrcode --break-system-packages 2>/dev/null \
    || $PYTHON -m pip install wechatbot-sdk qrcode
echo "✓ 依赖已安装"

# ---------------------------------------------------------------------------
# 4. 安装适配器文件（唯一需要复制的文件）
# ---------------------------------------------------------------------------
echo ""
echo "安装 wechat_ilink 适配器..."

cp "$SCRIPT_DIR/wechat_ilink.py" "$PLATFORMS_DIR/"
echo "✓ wechat_ilink.py 已复制到 $PLATFORMS_DIR/"

# 备份官方微信 weixin 插件
if [ -f "$PLATFORMS_DIR/weixin.py" ] && [ ! -f "$PLATFORMS_DIR/weixin.py.disabled.bak" ]; then
    cp "$PLATFORMS_DIR/weixin.py" "$PLATFORMS_DIR/weixin.py.disabled.bak"
    echo "✓ 官方 weixin.py 已备份"
else
    echo "  官方 weixin.py 已备份（跳过）"
fi

# ---------------------------------------------------------------------------
# 5. 安装运行时注入补丁（sitecustomize.py）
# 核心机制：Python 启动时自动拦截模块导入并注入 wechat_ilink 支持
# 优势：Hermes 升级后自动重新应用，无需手动操作
# ---------------------------------------------------------------------------
echo ""
echo "安装运行时注入补丁..."

if [ -n "$VENV_SITE_PACKAGES" ] && [ -d "$VENV_SITE_PACKAGES" ]; then
    cp "$SCRIPT_DIR/sitecustomize.py" "$VENV_SITE_PACKAGES/"
    echo "✓ sitecustomize.py 已安装到 $VENV_SITE_PACKAGES/"
else
    # Fallback: 手动查找 site-packages
    VENV_SITE_PACKAGES=$($PYTHON -c "import site; print(site.getsitepackages()[0])" 2>/dev/null)
    if [ -n "$VENV_SITE_PACKAGES" ] && [ -d "$VENV_SITE_PACKAGES" ]; then
        cp "$SCRIPT_DIR/sitecustomize.py" "$VENV_SITE_PACKAGES/"
        echo "✓ sitecustomize.py 已安装到 $VENV_SITE_PACKAGES/"
    else
        echo "⚠ 无法定位 site-packages 目录，运行时补丁可能无法自动生效"
        echo "  补救：手动运行 bash install-runtime-patches.sh 安装补丁"
    fi
fi

# ---------------------------------------------------------------------------
# 6. 禁用官方微信 weixin，启用我们的 wechat_ilink（config.yaml）
# ---------------------------------------------------------------------------
if [ -f "$CONFIG_YAML" ]; then
    # 禁用 weixin
    if grep -q "platforms:" "$CONFIG_YAML" 2>/dev/null; then
        if grep -A1 "weixin:" "$CONFIG_YAML" | grep -q "enabled: true" 2>/dev/null; then
            echo "禁用官方微信 weixin..."
            sed -i.bak '/^  weixin:/,/^  [a-z]/{s/enabled: true/enabled: false/}' "$CONFIG_YAML"
            echo "✓ 官方 weixin 已禁用"
        else
            echo "  官方 weixin 已禁用或不存在（跳过）"
        fi
    fi

    # 添加 wechat_ilink 配置（如果还没有）
    if ! grep -q "wechat_ilink:" "$CONFIG_YAML" 2>/dev/null; then
        echo "添加 wechat_ilink 配置到 config.yaml..."
        python3 -c "
import re
with open('$CONFIG_YAML', 'r') as f:
    content = f.read()

wechat_ilink_block = '''  wechat_ilink:
    enabled: true
    extra:
      dm_policy: \"open\"
      storage_dir: \"~/.wechatbot\"
'''

pattern = r'(  weixin:[^\n]*(?:\n    [^\n]*)*)'
match = re.search(pattern, content)
if match:
    insert_pos = match.end()
    if content[insert_pos:insert_pos+1] != '\n':
        insert_pos += 1
    content = content[:insert_pos] + '\n' + wechat_ilink_block + content[insert_pos:]
else:
    platforms_match = re.search(r'(platforms:\n)', content)
    if platforms_match:
        insert_pos = platforms_match.end()
        content = content[:insert_pos] + wechat_ilink_block + content[insert_pos:]
    else:
        content += '\nplatforms:\n' + wechat_ilink_block

with open('$CONFIG_YAML', 'w') as f:
    f.write(content)
"
        echo "✓ wechat_ilink 配置已添加"
    else
        echo "  wechat_ilink 配置已存在（跳过）"
    fi
else
    echo "⚠ $CONFIG_YAML 不存在，跳过 config.yaml 配置"
fi

# ---------------------------------------------------------------------------
# 7. 更新 .env：注释官方 weixin 变量，添加 wechat_ilink 变量
# ---------------------------------------------------------------------------
if [ -f "$ENV_FILE" ]; then
    if grep -q "^WEIXIN_" "$ENV_FILE" 2>/dev/null; then
        echo "注释官方 weixin 环境变量..."
        sed -i.bak '/^WEIXIN_/s/^/# /' "$ENV_FILE"
        echo "✓ 官方 weixin 环境变量已注释"
    else
        echo "  官方 weixin 环境变量已注释或不存在（跳过）"
    fi

    if ! grep -q "WECHAT_ILINK_ALLOW_ALL_USERS" "$ENV_FILE" 2>/dev/null; then
        echo "添加 wechat_ilink 环境变量..."
        echo "" >> "$ENV_FILE"
        echo "# 微信 iLink 配置（自定义插件）" >> "$ENV_FILE"
        echo "WECHAT_ILINK_ALLOW_ALL_USERS=true" >> "$ENV_FILE"
        echo "✓ wechat_ilink 环境变量已添加"
    else
        echo "  wechat_ilink 环境变量已存在（跳过）"
    fi
else
    echo "⚠ $ENV_FILE 不存在，创建..."
    touch "$ENV_FILE"
    echo "# 微信 iLink 配置（自定义插件）" >> "$ENV_FILE"
    echo "WECHAT_ILINK_ALLOW_ALL_USERS=true" >> "$ENV_FILE"
    echo "✓ $ENV_FILE 已创建"
fi

# ---------------------------------------------------------------------------
# 8. 修正 systemd 服务：确保使用 venv Python
# ---------------------------------------------------------------------------
SERVICE_FILE="/etc/systemd/system/hermes-gateway.service"
if [ -f "$SERVICE_FILE" ]; then
    if grep -q "/uv/python" "$SERVICE_FILE" 2>/dev/null; then
        echo "修正 systemd 服务 Python 路径..."
        if [ -f "$HERMES_AGENT_DIR/venv/bin/python" ]; then
            sed -i "s|ExecStart=/root/.local/share/uv/python/cpython-3.11.15-linux-x86_64-gnu/bin/python3.11|ExecStart=$HERMES_AGENT_DIR/venv/bin/python|" "$SERVICE_FILE"
            systemctl daemon-reload
            echo "✓ 已修正为 venv Python"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 9. 验证安装
# ---------------------------------------------------------------------------
echo ""
echo "验证安装..."

VERIFY_OK=true

# 检查 adapter 文件
if [ -f "$PLATFORMS_DIR/wechat_ilink.py" ]; then
    echo "  ✓ wechat_ilink.py 已安装"
else
    echo "  ✗ wechat_ilink.py 未找到"
    VERIFY_OK=false
fi

# 检查 sitecustomize.py
if [ -n "$VENV_SITE_PACKAGES" ] && [ -f "$VENV_SITE_PACKAGES/sitecustomize.py" ]; then
    echo "  ✓ sitecustomize.py 已安装（运行时注入）"
else
    echo "  ⚠ sitecustomize.py 未找到，运行时补丁可能不生效"
fi

# Python 导入测试
if $PYTHON -c "
import sys
sys.path.insert(0, '$HERMES_AGENT_DIR')
from gateway.config import Platform
assert hasattr(Platform, 'WECHAT_ILINK'), 'WECHAT_ILINK not in Platform enum'
from toolsets import TOOLSETS
assert 'hermes-wechat-ilink' in TOOLSETS, 'toolset not registered'
from gateway.platforms.base import BasePlatformAdapter
assert hasattr(BasePlatformAdapter, 'extract_markdown_images'), 'extract_markdown_images missing'
from gateway.platforms.wechat_ilink import check_wechat_ilink_requirements
assert check_wechat_ilink_requirements(), 'wechatbot-sdk not installed'
print('  ✓ Python 导入测试通过 — 所有运行时补丁已生效')
" 2>&1; then
    true
else
    echo "  ✗ Python 导入测试失败"
    VERIFY_OK=false
fi

# ---------------------------------------------------------------------------
# 10. 重启 Gateway
# ---------------------------------------------------------------------------
echo ""
echo "重启 Hermes Gateway..."

if command -v hermes &> /dev/null; then
    if hermes gateway restart 2>/dev/null; then
        echo "✓ Gateway 已重启"
    else
        echo "⚠ gateway restart 失败，尝试 systemctl..."
        systemctl restart hermes-gateway 2>/dev/null && echo "✓ Gateway 已重启" || echo "⚠ 请手动重启: hermes gateway restart"
    fi
else
    systemctl restart hermes-gateway 2>/dev/null && echo "✓ Gateway 已重启" || echo "⚠ 请手动重启"
fi

# ---------------------------------------------------------------------------
# 完成
# ---------------------------------------------------------------------------
echo ""
echo "=========================================="
if [ "$VERIFY_OK" = true ]; then
    echo "  ✓ 安装完成！"
else
    echo "  ⚠ 安装完成，但部分验证未通过，请检查日志"
fi
echo "=========================================="
echo ""
echo "📌 技术说明："
echo "  本安装使用运行时注入模式（sitecustomize.py），不修改 Hermes 源码。"
echo "  Hermes 升级后，补丁会自动重新应用，无需重新安装。"
echo ""
echo "下一步："
echo "  1. 查看二维码: hermes gateway logs | grep 'Scan this URL' | tail -1"
echo "  2. 用微信扫码登录"
echo "  3. 发送消息测试"
echo ""
echo "管理命令："
echo "  hermes gateway status     # 查看状态"
echo "  hermes gateway logs       # 查看日志"
echo "  hermes gateway restart    # 重启服务"
echo "  hermes gateway stop       # 停止服务"
