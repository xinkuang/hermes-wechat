#!/bin/bash
# Hermes 微信 iLink 一键安装脚本
# 适用于 Linux/macOS
# 功能：
#   1. 禁用官方微信 weixin 插件
#   2. 安装我们的 wechat_ilink.py 适配器
#   3. 注册 Platform 枚举和 _create_adapter 分支
#   4. 更新 config.yaml 和 .env
#   5. 安装依赖并重启 gateway

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=========================================="
echo "  Hermes 微信 iLink Bot 安装脚本 v1.3"
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
CONFIG_PY="$HERMES_AGENT_DIR/gateway/config.py"
RUN_PY="$HERMES_AGENT_DIR/gateway/run.py"
CONFIG_YAML="$HERMES_DIR/config.yaml"
ENV_FILE="$HERMES_DIR/.env"

# 确定使用的 Python
if [ -f "$HERMES_AGENT_DIR/venv/bin/python" ]; then
    PYTHON="$HERMES_AGENT_DIR/venv/bin/python"
else
    PYTHON="python3"
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
# 4. 安装适配器文件
# ---------------------------------------------------------------------------
echo ""
echo "安装 wechat_ilink 适配器..."

cp "$SCRIPT_DIR/wechat_ilink.py" "$PLATFORMS_DIR/"
echo "✓ wechat_ilink.py 已复制到 $PLATFORMS_DIR/"

# 备份官方 weixin 插件（不禁用，仅备份）
if [ -f "$PLATFORMS_DIR/weixin.py" ] && [ ! -f "$PLATFORMS_DIR/weixin.py.disabled.bak" ]; then
    cp "$PLATFORMS_DIR/weixin.py" "$PLATFORMS_DIR/weixin.py.disabled.bak"
    echo "✓ 官方 weixin.py 已备份为 .disabled.bak"
else
    echo "  官方 weixin.py 已备份（跳过）"
fi

# ---------------------------------------------------------------------------
# 5. 注册 Platform.WECHAT_ILINK 枚举
# ---------------------------------------------------------------------------
if [ -f "$CONFIG_PY" ]; then
    if ! grep -q "WECHAT_ILINK" "$CONFIG_PY" 2>/dev/null; then
        echo "注册 Platform.WECHAT_ILINK 枚举..."
        # 在 WEIXIN = "weixin" 之后添加
        sed -i.bak 's/WEIXIN = "weixin"/WEIXIN = "weixin"\n    WECHAT_ILINK = "wechat_ilink"/' "$CONFIG_PY"
        echo "✓ Platform.WECHAT_ILINK 已注册"
    else
        echo "  Platform.WECHAT_ILINK 已注册（跳过）"
    fi
fi

# ---------------------------------------------------------------------------
# 6. 注册 _create_adapter 分支（run.py）
# ---------------------------------------------------------------------------
if [ -f "$RUN_PY" ]; then
    if ! grep -q "Platform.WECHAT_ILINK" "$RUN_PY" 2>/dev/null; then
        echo "注册 _create_adapter 分支..."

        # 在 WEIXIN adapter case 之后添加 WECHAT_ILINK case
        # 找到 WeixinAdapter(config) 行，在其后插入新 case
        sed -i.bak '/return WeixinAdapter(config)/a\
\
        elif platform == Platform.WECHAT_ILINK:\
            from gateway.platforms.wechat_ilink import (\
                WeChatILinkAdapter,\
                check_wechat_ilink_requirements,\
            )\
            if not check_wechat_ilink_requirements():\
                logger.warning("WeChat iLink: wechatbot-sdk not installed")\
                return None\
            return WeChatILinkAdapter(config)
        ' "$RUN_PY"
        echo "✓ _create_adapter 分支已注册"
    else
        echo "  _create_adapter 分支已注册（跳过）"
    fi

    # 注册 allow-from 映射
    if ! grep -q "WECHAT_ILINK_ALLOWED_USERS" "$RUN_PY" 2>/dev/null; then
        echo "注册 allow-from 映射..."
        sed -i.bak 's/Platform.WEIXIN: "WEIXIN_ALLOWED_USERS"/Platform.WEIXIN: "WEIXIN_ALLOWED_USERS",\n            Platform.WECHAT_ILINK: "WECHAT_ILINK_ALLOWED_USERS"/' "$RUN_PY"
    fi

    if ! grep -q "WECHAT_ILINK_ALLOW_ALL_USERS" "$RUN_PY" 2>/dev/null; then
        sed -i.bak 's/Platform.WEIXIN: "WEIXIN_ALLOW_ALL_USERS"/Platform.WEIXIN: "WEIXIN_ALLOW_ALL_USERS",\n            Platform.WECHAT_ILINK: "WECHAT_ILINK_ALLOW_ALL_USERS"/' "$RUN_PY"
    fi
    echo "✓ allow-from 映射已注册"
else
    echo "⚠ $RUN_PY 不存在，跳过 run.py 注册"
fi

# ---------------------------------------------------------------------------
# 7. 注册 wechat_ilink 到 tools_config.py（PLATFORMS 字典）
# ---------------------------------------------------------------------------
TOOLS_CONFIG="$HERMES_AGENT_DIR/hermes_cli/tools_config.py"
if [ -f "$TOOLS_CONFIG" ]; then
    if ! grep -q "wechat_ilink" "$TOOLS_CONFIG" 2>/dev/null; then
        echo "注册 wechat_ilink 到 tools_config.py..."
        sed -i.bak '/"weixin": {"label": "💬 Weixin"/a\    "wechat_ilink": {"label": "💬 WeChat iLink", "default_toolset": "hermes-wechat-ilink"},' "$TOOLS_CONFIG"
        echo "✓ wechat_ilink 已注册到 tools_config.py"
    else
        echo "  wechat_ilink 已注册到 tools_config.py（跳过）"
    fi
else
    echo "⚠ $TOOLS_CONFIG 不存在，跳过 tools_config.py 注册"
fi

# ---------------------------------------------------------------------------
# 8. 禁用官方微信 weixin，启用我们的 wechat_ilink（config.yaml）
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

# 尝试在 weixin 块后插入（在 platforms: 下）
# 找到 weixin: 行，在其下一行同级 key 之前插入
pattern = r'(  weixin:[^\n]*(?:\n    [^\n]*)*)'
match = re.search(pattern, content)
if match:
    insert_pos = match.end()
    # 确保插入位置在新行
    if content[insert_pos:insert_pos+1] != '\n':
        insert_pos += 1
    content = content[:insert_pos] + '\n' + wechat_ilink_block + content[insert_pos:]
else:
    # 没找到 weixin，尝试在 platforms: 下直接插入
    platforms_match = re.search(r'(platforms:\n)', content)
    if platforms_match:
        insert_pos = platforms_match.end()
        content = content[:insert_pos] + wechat_ilink_block + content[insert_pos:]
    else:
        # 没有 platforms: 节，创建它
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
# 8b. 补丁 gateway/config.py：添加 wechat_ilink home_channel 支持
# ---------------------------------------------------------------------------
if [ -f "$CONFIG_PY" ]; then
    if ! grep -q "WECHAT_ILINK_HOME_CHANNEL" "$CONFIG_PY" 2>/dev/null; then
        echo "补丁 config.py: 添加 wechat_ilink home_channel 支持..."

        # 1. 在 load_gateway_config() 的 WhatsApp 块之后、Matrix 块之前添加 wechat_ilink 配置
        sed -i.bak '/# Matrix settings/a\
\
            # WeChat iLink settings → env vars\
            wechat_ilink_cfg = yaml_cfg.get("wechat_ilink", {})\
            if isinstance(wechat_ilink_cfg, dict):\
                allow_all = wechat_ilink_cfg.get("allow_all_users")\
                if allow_all is not None and not os.getenv("WECHAT_ILINK_ALLOW_ALL_USERS"):\
                    os.environ["WECHAT_ILINK_ALLOW_ALL_USERS"] = str(allow_all).lower()\
                dm_policy = wechat_ilink_cfg.get("dm_policy")\
                if dm_policy is not None and not os.getenv("WECHAT_ILINK_DM_POLICY"):\
                    os.environ["WECHAT_ILINK_DM_POLICY"] = str(dm_policy)\
                storage_dir = wechat_ilink_cfg.get("storage_dir")\
                if storage_dir is not None and not os.getenv("WECHAT_ILINK_STORAGE_DIR"):\
                    os.environ["WECHAT_ILINK_STORAGE_DIR"] = str(storage_dir)\
\
            # Handle root-level *_HOME_CHANNEL keys (written by /sethome)\
            for key, value in yaml_cfg.items():\
                if key.endswith("_HOME_CHANNEL") and isinstance(value, str) and value.strip():\
                    env_upper = key.upper().strip()\
                    if not os.getenv(env_upper):\
                        os.environ[env_upper] = value.strip()
' "$CONFIG_PY"

        # 2. 在 _apply_env_overrides() 的 BlueBubbles 之前添加 wechat_ilink home_channel
        sed -i.bak '/# BlueBubbles (iMessage)/i\
    # WeChat iLink home channel\
    wechat_ilink_home = os.getenv("WECHAT_ILINK_HOME_CHANNEL", "").strip()\
    if wechat_ilink_home and Platform.WECHAT_ILINK in config.platforms:\
        config.platforms[Platform.WECHAT_ILINK].home_channel = HomeChannel(\
            platform=Platform.WECHAT_ILINK,\
            chat_id=wechat_ilink_home,\
            name=os.getenv("WECHAT_ILINK_HOME_CHANNEL_NAME", "Home"),\
        )\
' "$CONFIG_PY"
        echo "✓ config.py 已补丁"
    else
        echo "  config.py 已包含 wechat_ilink home_channel 支持（跳过）"
    fi
fi

# ---------------------------------------------------------------------------
# 8. 更新 .env：注释官方 weixin 变量，添加 wechat_ilink 变量
# ---------------------------------------------------------------------------
if [ -f "$ENV_FILE" ]; then
    # 注释掉 WEIXIN_ 开头的变量
    if grep -q "^WEIXIN_" "$ENV_FILE" 2>/dev/null; then
        echo "注释官方 weixin 环境变量..."
        sed -i.bak '/^WEIXIN_/s/^/# /' "$ENV_FILE"
        echo "✓ 官方 weixin 环境变量已注释"
    else
        echo "  官方 weixin 环境变量已注释或不存在（跳过）"
    fi

    # 添加 wechat_ilink 变量
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

# 检查 Platform 枚举
if grep -q "WECHAT_ILINK" "$CONFIG_PY" 2>/dev/null; then
    echo "  ✓ Platform.WECHAT_ILINK 已注册"
else
    echo "  ✗ Platform.WECHAT_ILINK 未注册"
    VERIFY_OK=false
fi

# 检查 tools_config.py
TOOLS_CONFIG="$HERMES_AGENT_DIR/hermes_cli/tools_config.py"
if grep -q "wechat_ilink" "$TOOLS_CONFIG" 2>/dev/null; then
    echo "  ✓ tools_config.py 已注册"
else
    echo "  ✗ tools_config.py 未注册 wechat_ilink"
    VERIFY_OK=false
fi

# 检查 config.py home_channel
if grep -q "WECHAT_ILINK_HOME_CHANNEL" "$CONFIG_PY" 2>/dev/null; then
    echo "  ✓ config.py home_channel 支持"
else
    echo "  ⚠ config.py home_channel 未补丁（/sethome 将不生效）"
fi

# 检查 _create_adapter 分支
if grep -q "Platform.WECHAT_ILINK" "$RUN_PY" 2>/dev/null; then
    echo "  ✓ _create_adapter 分支已注册"
else
    echo "  ✗ _create_adapter 分支未注册"
    VERIFY_OK=false
fi

# Python 导入测试
if $PYTHON -c "
import sys
sys.path.insert(0, '$HERMES_AGENT_DIR')
from gateway.config import Platform
assert hasattr(Platform, 'WECHAT_ILINK')
from gateway.platforms.wechat_ilink import check_wechat_ilink_requirements
assert check_wechat_ilink_requirements()
print('  ✓ Python 导入测试通过')
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
    echo "⚠ hermes 命令不可用，请手动重启 gateway"
fi

# 修正 systemd 服务：确保使用 venv Python（hermes CLI 可能错误使用 uv Python）
SERVICE_FILE="/etc/systemd/system/hermes-gateway.service"
if [ -f "$SERVICE_FILE" ]; then
    if grep -q "/uv/python" "$SERVICE_FILE" 2>/dev/null; then
        echo "修正 systemd 服务 Python 路径..."
        if [ -f "$HERMES_AGENT_DIR/venv/bin/python" ]; then
            sed -i "s|ExecStart=/root/.local/share/uv/python/cpython-3.11.15-linux-x86_64-gnu/bin/python3.11|ExecStart=$HERMES_AGENT_DIR/venv/bin/python|" "$SERVICE_FILE"
            systemctl daemon-reload
            systemctl restart hermes-gateway
            echo "✓ 已修正为 venv Python 并重启"
        fi
    fi
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
