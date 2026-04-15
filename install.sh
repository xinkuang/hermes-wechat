#!/bin/bash
# Hermes 微信 iLink 一键安装脚本
# 适用于 Linux/macOS
# 功能：
#   1. 禁用官方微信 weixin 插件（如存在）
#   2. 安装我们的 wechat_ilink.py 适配器
#   3. 注册 Platform 枚举和 _create_adapter 分支
#   4. 更新 config.yaml 和 .env
#   5. 安装依赖并重启 gateway

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=========================================="
echo "  Hermes 微信 iLink Bot 安装脚本 v1.4"
echo "=========================================="

# ---------------------------------------------------------------------------
# 1. 系统检测
# ---------------------------------------------------------------------------
IS_MACOS=false
if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "✓ 检测到 macOS"
    IS_MACOS=true
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
# Helper: 跨平台 sed -i
#   macOS BSD sed 要求 sed -i '' '...'
#   Linux  GNU sed 要求 sed -i '...'
# ---------------------------------------------------------------------------
sed_i() {
    if $IS_MACOS; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

# ---------------------------------------------------------------------------
# Helper: 在文件中某行之后插入多行文本
#   用法: insert_after FILE PATTERN TEXT
#   在匹配 PATTERN 的行之后插入 TEXT（可含换行符）
# ---------------------------------------------------------------------------
insert_after() {
    local file="$1" pattern="$2" text="$3"
    if $IS_MACOS; then
        # macOS: 使用 awk 避免 BSD sed 多行插入的兼容性问题
        awk -v pat="$pattern" -v txt="$text" '
            { print }
            index($0, pat) > 0 { printf "%s\n", txt }
        ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    else
        # Linux: 使用 sed a\ 命令
        sed -i "a\\$text" "$file"
    fi
}

# ---------------------------------------------------------------------------
# Helper: 在文件中某行之前插入多行文本
#   用法: insert_before FILE PATTERN TEXT
# ---------------------------------------------------------------------------
insert_before() {
    local file="$1" pattern="$2" text="$3"
    if $IS_MACOS; then
        awk -v pat="$pattern" -v txt="$text" '
            index($0, pat) > 0 { printf "%s\n", txt }
            { print }
        ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    else
        sed -i "i\\$text" "$file"
    fi
}

# ---------------------------------------------------------------------------
# Helper: 替换文件中的文本（简单字符串替换）
#   用法: replace_in_file FILE OLD NEW
# ---------------------------------------------------------------------------
replace_in_file() {
    local file="$1" old="$2" new="$3"
    if $IS_MACOS; then
        # 使用 awk 处理含特殊字符的替换（避免 sed 转义地狱）
        awk -v old="$old" -v new="$new" '
            { gsub(old, new); print }
        ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    else
        sed -i "s|${old}|${new}|" "$file"
    fi
}

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

# 备份官方 weixin 插件（如存在）
if [ -f "$PLATFORMS_DIR/weixin.py" ] && [ ! -f "$PLATFORMS_DIR/weixin.py.disabled.bak" ]; then
    cp "$PLATFORMS_DIR/weixin.py" "$PLATFORMS_DIR/weixin.py.disabled.bak"
    echo "✓ 官方 weixin.py 已备份为 .disabled.bak"
else
    echo "  官方 weixin.py 不存在或已备份（跳过）"
fi

# ---------------------------------------------------------------------------
# 5. 注册 Platform.WECHAT_ILINK 枚举
# ---------------------------------------------------------------------------
if [ -f "$CONFIG_PY" ]; then
    if ! grep -q "WECHAT_ILINK" "$CONFIG_PY" 2>/dev/null; then
        echo "注册 Platform.WECHAT_ILINK 枚举..."
        # 寻找合适的锚点：优先用 BLUEBUBBLES，其次 WEIXIN，最后 WEBHOOK
        if grep -q "BLUEBUBBLES" "$CONFIG_PY" 2>/dev/null; then
            ANCHOR="BLUEBUBBLES"
        elif grep -q "WEIXIN" "$CONFIG_PY" 2>/dev/null; then
            ANCHOR="WEIXIN"
        else
            ANCHOR="WEBHOOK"
        fi
        insert_after "$CONFIG_PY" "${ANCHOR} =" '    WECHAT_ILINK = "wechat_ilink"'
        echo "✓ Platform.WECHAT_ILINK 已注册（锚点: $ANCHOR）"
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

        # 寻找合适的锚点 adapter
        ADAPTER_LINE=""
        if grep -q "WeixinAdapter(config)" "$RUN_PY" 2>/dev/null; then
            ADAPTER_LINE="return WeixinAdapter(config)"
        elif grep -q "BlueBubblesAdapter(config)" "$RUN_PY" 2>/dev/null; then
            ADAPTER_LINE="return BlueBubblesAdapter(config)"
        fi

        if [ -n "$ADAPTER_LINE" ]; then
            NEW_CASE="
        elif platform == Platform.WECHAT_ILINK:
            from gateway.platforms.wechat_ilink import (
                WeChatILinkAdapter,
                check_wechat_ilink_requirements,
            )
            if not check_wechat_ilink_requirements():
                logger.warning(\"WeChat iLink: wechatbot-sdk not installed\")
                return None
            return WeChatILinkAdapter(config)"
            insert_after "$RUN_PY" "$ADAPTER_LINE" "$NEW_CASE"
            echo "✓ _create_adapter 分支已注册（锚点: $ADAPTER_LINE）"
        else
            echo "  ⚠ 未找到合适的锚点 adapter，请手动添加 _create_adapter 分支"
        fi
    else
        echo "  _create_adapter 分支已注册（跳过）"
    fi

    # 注册 platform_allowed_users_map
    if ! grep -q "WECHAT_ILINK_ALLOWED_USERS" "$RUN_PY" 2>/dev/null; then
        echo "注册 allowed_users 映射..."
        # 找到合适的锚点
        if grep -q "WEIXIN_ALLOWED_USERS" "$RUN_PY" 2>/dev/null; then
            OLD='Platform.WEIXIN: "WEIXIN_ALLOWED_USERS"'
            NEW='Platform.WEIXIN: "WEIXIN_ALLOWED_USERS",
            Platform.WECHAT_ILINK: "WECHAT_ILINK_ALLOWED_USERS",'
            replace_in_file "$RUN_PY" "$OLD" "$NEW"
        elif grep -q "BLUEBUBBLES_ALLOWED_USERS" "$RUN_PY" 2>/dev/null; then
            OLD='Platform.BLUEBUBBLES: "BLUEBUBBLES_ALLOWED_USERS"'
            NEW='Platform.BLUEBUBBLES: "BLUEBUBBLES_ALLOWED_USERS",
            Platform.WECHAT_ILINK: "WECHAT_ILINK_ALLOWED_USERS",'
            replace_in_file "$RUN_PY" "$OLD" "$NEW"
        fi
    fi

    # 注册 platform_allow_all_map
    if ! grep -q "WECHAT_ILINK_ALLOW_ALL_USERS" "$RUN_PY" 2>/dev/null; then
        echo "注册 allow_all 映射..."
        if grep -q "WEIXIN_ALLOW_ALL_USERS" "$RUN_PY" 2>/dev/null; then
            OLD='Platform.WEIXIN: "WEIXIN_ALLOW_ALL_USERS"'
            NEW='Platform.WEIXIN: "WEIXIN_ALLOW_ALL_USERS",
            Platform.WECHAT_ILINK: "WECHAT_ILINK_ALLOW_ALL_USERS",'
            replace_in_file "$RUN_PY" "$OLD" "$NEW"
        elif grep -q "BLUEBUBBLES_ALLOW_ALL_USERS" "$RUN_PY" 2>/dev/null; then
            OLD='Platform.BLUEBUBBLES: "BLUEBUBBLES_ALLOW_ALL_USERS"'
            NEW='Platform.BLUEBUBBLES: "BLUEBUBBLES_ALLOW_ALL_USERS",
            Platform.WECHAT_ILINK: "WECHAT_ILINK_ALLOW_ALL_USERS",'
            replace_in_file "$RUN_PY" "$OLD" "$NEW"
        fi
    fi

    # 注册 _any_allow_all 检查中的变量名
    if ! grep -q '"WECHAT_ILINK_ALLOW_ALL_USERS"' "$RUN_PY" 2>/dev/null; then
        echo "注册 _any_allow_all 变量..."
        if grep -q '"WEIXIN_ALLOW_ALL_USERS"' "$RUN_PY" 2>/dev/null; then
            OLD='"WEIXIN_ALLOW_ALL_USERS"'
            NEW='"WEIXIN_ALLOW_ALL_USERS",
                       "WECHAT_ILINK_ALLOW_ALL_USERS"'
            replace_in_file "$RUN_PY" "$OLD" "$NEW"
        elif grep -q '"BLUEBUBBLES_ALLOW_ALL_USERS"' "$RUN_PY" 2>/dev/null; then
            OLD='"BLUEBUBBLES_ALLOW_ALL_USERS"'
            NEW='"BLUEBUBBLES_ALLOW_ALL_USERS",
                       "WECHAT_ILINK_ALLOW_ALL_USERS"'
            replace_in_file "$RUN_PY" "$OLD" "$NEW"
        fi
    fi
    echo "✓ run.py 映射已注册"
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
        # 寻找锚点
        if grep -q '"weixin"' "$TOOLS_CONFIG" 2>/dev/null; then
            ANCHOR_LINE='\"weixin\"'
        else
            ANCHOR_LINE='\"webhook\"'
        fi
        insert_after "$TOOLS_CONFIG" "$ANCHOR_LINE" '    "wechat_ilink": {"label": "💬 WeChat iLink", "default_toolset": "hermes-wechat-ilink"},'
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
    # 禁用 weixin（如存在）
    if grep -q "platforms:" "$CONFIG_YAML" 2>/dev/null; then
        if grep -A1 "weixin:" "$CONFIG_YAML" | grep -q "enabled: true" 2>/dev/null; then
            echo "禁用官方微信 weixin..."
            # 使用 python3 做 YAML 感知的替换（避免 sed 跨行替换问题）
            python3 -c "
import re
with open('$CONFIG_YAML', 'r') as f:
    content = f.read()
# 匹配 weixin: 下面的 enabled: true
content = re.sub(r'(  weixin:\n\s+enabled:\s+)true', r'\1false', content)
with open('$CONFIG_YAML', 'w') as f:
    f.write(content)
"
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
pattern = r'(  weixin:[^\n]*(?:\n    [^\n]*)*)'
match = re.search(pattern, content)
if match:
    insert_pos = match.end()
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

        # 1. 在 _apply_env_overrides() 的 BlueBubbles 块之后添加 wechat_ilink 配置块
        # 使用 python3 处理多行插入（避免 sed 跨平台问题）
        python3 -c "
import sys

with open('$CONFIG_PY', 'r') as f:
    content = f.read()

# 添加 wechat_ilink 到 _apply_env_overrides
ilink_block = '''
    # WeChat iLink
    wechat_ilink_enabled = os.getenv(\"WECHAT_ILINK_ENABLED\", \"\").lower() in (\"true\", \"1\", \"yes\")
    wechat_ilink_allow_all = os.getenv(\"WECHAT_ILINK_ALLOW_ALL_USERS\", \"\").lower() in (\"true\", \"1\", \"yes\")
    if wechat_ilink_enabled or wechat_ilink_allow_all:
        if Platform.WECHAT_ILINK not in config.platforms:
            config.platforms[Platform.WECHAT_ILINK] = PlatformConfig()
        config.platforms[Platform.WECHAT_ILINK].enabled = True
        config.platforms[Platform.WECHAT_ILINK].extra.update({
            \"allow_all_users\": wechat_ilink_allow_all,
            \"dm_policy\": os.getenv(\"WECHAT_ILINK_DM_POLICY\", \"open\"),
        })
        wechat_ilink_storage = os.getenv(\"WECHAT_ILINK_STORAGE_DIR\", \"\")
        if wechat_ilink_storage:
            config.platforms[Platform.WECHAT_ILINK].extra[\"storage_dir\"] = wechat_ilink_storage

    # WeChat iLink home channel
    wechat_ilink_home = os.getenv(\"WECHAT_ILINK_HOME_CHANNEL\", \"\").strip()
    if wechat_ilink_home and Platform.WECHAT_ILINK in config.platforms:
        config.platforms[Platform.WECHAT_ILINK].home_channel = HomeChannel(
            platform=Platform.WECHAT_ILINK,
            chat_id=wechat_ilink_home,
            name=os.getenv(\"WECHAT_ILINK_HOME_CHANNEL_NAME\", \"Home\"),
        )
'''

# 找到 BlueBubbles 块结尾作为锚点
import re
# 在 BlueBubbles home_channel 块之后插入
bb_match = re.search(r'(BLUEBUBBLES_HOME_CHANNEL.*?name=.*?\"Home\".*?\n)', content)
if bb_match:
    insert_pos = bb_match.end()
    content = content[:insert_pos] + ilink_block + content[insert_pos:]
else:
    # 找 Session settings 注释作为锚点
    session_match = re.search(r'(\n    # Session settings)', content)
    if session_match:
        insert_pos = session_match.start()
        content = content[:insert_pos] + '\n' + ilink_block + content[insert_pos:]
    else:
        print('WARNING: Could not find insertion point for wechat_ilink in config.py', file=sys.stderr)

with open('$CONFIG_PY', 'w') as f:
    f.write(content)
"
        echo "✓ config.py 已补丁"
    else
        echo "  config.py 已包含 wechat_ilink home_channel 支持（跳过）"
    fi
fi

# ---------------------------------------------------------------------------
# 9. 更新 .env：注释官方 weixin 变量，添加 wechat_ilink 变量
# ---------------------------------------------------------------------------
if [ -f "$ENV_FILE" ]; then
    # 注释掉 WEIXIN_ 开头的变量
    if grep -q "^WEIXIN_" "$ENV_FILE" 2>/dev/null; then
        echo "注释官方 weixin 环境变量..."
        sed_i 's/^WEIXIN_/# WEIXIN_/' "$ENV_FILE"
        echo "✓ 官方 weixin 环境变量已注释"
    else
        echo "  官方 weixin 环境变量已注释或不存在（跳过）"
    fi

    # 添加 wechat_ilink 变量
    if ! grep -q "WECHAT_ILINK_ALLOW_ALL_USERS" "$ENV_FILE" 2>/dev/null; then
        echo "添加 wechat_ilink 环境变量..."
        echo "" >> "$ENV_FILE"
        echo "# WeChat iLink" >> "$ENV_FILE"
        echo "WECHAT_ILINK_ENABLED=true" >> "$ENV_FILE"
        echo "WECHAT_ILINK_ALLOW_ALL_USERS=true" >> "$ENV_FILE"
        echo "✓ wechat_ilink 环境变量已添加"
    else
        echo "  wechat_ilink 环境变量已存在（跳过）"
    fi
else
    echo "⚠ $ENV_FILE 不存在，创建..."
    touch "$ENV_FILE"
    echo "# WeChat iLink" >> "$ENV_FILE"
    echo "WECHAT_ILINK_ENABLED=true" >> "$ENV_FILE"
    echo "WECHAT_ILINK_ALLOW_ALL_USERS=true" >> "$ENV_FILE"
    echo "✓ $ENV_FILE 已创建"
fi

# ---------------------------------------------------------------------------
# 10. 验证安装
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
# 11. 重启 Gateway
# ---------------------------------------------------------------------------
echo ""
echo "重启 Hermes Gateway..."

if command -v hermes &> /dev/null; then
    if hermes gateway restart 2>/dev/null; then
        echo "✓ Gateway 已重启"
    else
        if ! $IS_MACOS; then
            echo "⚠ gateway restart 失败，尝试 systemctl..."
            systemctl restart hermes-gateway 2>/dev/null && echo "✓ Gateway 已重启" || echo "⚠ 请手动重启: hermes gateway restart"
        else
            echo "⚠ 请手动重启: hermes gateway restart"
        fi
    fi
else
    echo "⚠ hermes 命令不可用，请手动重启 gateway"
fi

# 修正 systemd 服务（仅 Linux）
if ! $IS_MACOS; then
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
