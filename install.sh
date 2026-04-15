#!/bin/bash
# Hermes 微信 iLink 一键安装脚本
# 适用于 Linux/macOS
# 功能：
#   1. 禁用官方微信 weixin 插件
#   2. 安装我们的 wechat_ilink.py 适配器
#   3. 注册 Platform 枚举和 _create_adapter 分支
#   4. 注册 toolset 定义（toolsets.py）
#   5. 注册 cron 投递映射（cron/scheduler.py）
#   6. 补丁 base.py extract_markdown_images
#   7. 更新 config.yaml 和 .env
#   8. 安装依赖并重启 gateway

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=========================================="
echo "  Hermes 微信 iLink 一键安装脚本 v1.4"
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
TOOLS_CONFIG="$HERMES_AGENT_DIR/hermes_cli/tools_config.py"
TOOLSETS_PY="$HERMES_AGENT_DIR/toolsets.py"
SCHEDULER_PY="$HERMES_AGENT_DIR/cron/scheduler.py"
BASE_PY="$HERMES_AGENT_DIR/gateway/platforms/base.py"
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
# 7b. 注册 wechat_ilink 到 toolsets.py（工具集定义）
# 原因：如果没有 toolset，AI 拿到空工具列表，只能回答"我没有终端访问权限"
# ---------------------------------------------------------------------------
if [ -f "$TOOLSETS_PY" ]; then
    if ! grep -q "hermes-wechat-ilink" "$TOOLSETS_PY" 2>/dev/null; then
        echo "注册 wechat_ilink toolset（toolsets.py）..."
        # 在 hermes-wecom 之前插入 toolset 定义
        sed -i.bak '/"hermes-wecom": {/i\    "hermes-wechat-ilink": {\n        "description": "WeChat iLink bot toolset - personal WeChat messaging via iLink protocol (full access)",\n        "tools": _HERMES_CORE_TOOLS,\n        "includes": []\n    },\n' "$TOOLSETS_PY"
        echo "✓ toolset 定义已注册"
    else
        echo "  toolset 定义已注册（跳过）"
    fi

    # 添加到 hermes-gateway includes
    if ! grep -q '"hermes-wechat-ilink"' "$TOOLSETS_PY" 2>/dev/null; then
        if grep -q '"hermes-weixin", "hermes-webhook"' "$TOOLSETS_PY" 2>/dev/null; then
            sed -i.bak 's/"hermes-weixin", "hermes-webhook"/"hermes-weixin", "hermes-wechat-ilink", "hermes-webhook"/' "$TOOLSETS_PY"
            echo "✓ gateway includes 已注册"
        fi
    else
        echo "  gateway includes 已注册（跳过）"
    fi
else
    echo "⚠ $TOOLSETS_PY 不存在，跳过 toolsets.py 注册"
fi

# ---------------------------------------------------------------------------
# 7c. 补丁 cron/scheduler.py：添加 wechat_ilink 到 platform_map
# 原因：cron 自动投递时，_deliver_result() 通过 platform_map 查找 Platform 枚举
#       如果缺失，投递会被静默丢弃（last_delivery_error = None，但用户收不到消息）
# ---------------------------------------------------------------------------
if [ -f "$SCHEDULER_PY" ]; then
    if ! grep -q "WECHAT_ILINK" "$SCHEDULER_PY" 2>/dev/null; then
        echo "补丁 cron/scheduler.py: 添加 wechat_ilink 投递映射..."
        sed -i.bak '/"weixin": Platform.WEIXIN,/a\        "wechat_ilink": Platform.WECHAT_ILINK,' "$SCHEDULER_PY"
        echo "✓ cron 投递映射已注册"
    else
        echo "  cron 投递映射已注册（跳过）"
    fi
else
    echo "⚠ $SCHEDULER_PY 不存在，跳过 scheduler.py 注册"
fi

# ---------------------------------------------------------------------------
# 7d. 补丁 gateway/platforms/base.py：添加 extract_markdown_images 方法
# 原因：LLM 输出常用 ![alt]()path 或 ![alt](path) 引用本地图片
#       没有此补丁时，AI 生成的图片不会被提取发送
# ---------------------------------------------------------------------------
if [ -f "$BASE_PY" ]; then
    if ! grep -q "extract_markdown_images" "$BASE_PY" 2>/dev/null; then
        echo "补丁 base.py: 添加 extract_markdown_images 方法..."
        cat > /tmp/_patch_extract.py << 'PYEOF'
import re, sys

content = open(sys.argv[1]).read()

patch = """
    @staticmethod
    def extract_markdown_images(content: str) -> Tuple[List[str], str]:
        \"\"\"Detect markdown image syntax pointing to local file paths.

        Handles patterns like:
            ![alt]()path/to/image.png    (empty URL, then bare path after `)`)
            ![alt](path/to/image.png)    (path inside parentheses)

        Returns:
            Tuple of (list of file paths, cleaned content with full
            markdown image syntax removed).
        \"\"\"
        _LOCAL_MEDIA_EXTS = (
            '.png', '.jpg', '.jpeg', '.gif', '.webp',
            '.mp4', '.mov', '.avi', '.mkv', '.webm',
        )
        ext_part = '|'.join(e.lstrip('.') for e in _LOCAL_MEDIA_EXTS)
        md_re = re.compile(r'!\[([^\]]*)\]\(([^)]*)\)')
        found: list = []
        code_spans: list = []
        for m in re.finditer(r'```[^\n]*\n.*?```', content, re.DOTALL):
            code_spans.append((m.start(), m.end()))
        for m in re.finditer(r'`[^`\n]+`', content):
            code_spans.append((m.start(), m.end()))
        def _in_code(pos: int) -> bool:
            return any(s <= pos < e for s, e in code_spans)
        def _is_local_path(p: str) -> bool:
            if not p: return False
            p = p.strip()
            if p.startswith(('http://', 'https://', 'data:')): return False
            if not (p.startswith('/') or p.startswith('~')): return False
            ext_match = re.search(r'\.(' + ext_part + r')$', p, re.IGNORECASE)
            if not ext_match: return False
            return os.path.isfile(os.path.expanduser(p))
        def _find_path_in_text(text: str) -> Optional[str]:
            for ext_match in re.finditer(
                r'\.(' + ext_part + r')(?:\s|$|[,;:，；：\)）\]}])',
                text, re.IGNORECASE,
            ):
                end_pos = ext_match.start() + 1
                candidate = text[:end_pos]
                slash_pos = -1
                for i in range(len(candidate) - 1, -1, -1):
                    if candidate[i] == '/':
                        if i == 0 or candidate[i - 1] in (' ', '\n', '\r', '\t', ')'):
                            slash_pos = i
                            break
                if slash_pos >= 0:
                    candidate_path = candidate[slash_pos:].strip()
                    if candidate_path.startswith('/') or candidate_path.startswith('~'):
                        expanded = os.path.expanduser(candidate_path)
                        if os.path.isfile(expanded):
                            return candidate_path
            return None
        cleaned = content
        for match in md_re.finditer(content):
            if _in_code(match.start()): continue
            url_path = match.group(2).strip()
            file_path = None
            if _is_local_path(url_path):
                file_path = os.path.expanduser(url_path)
                cleaned = cleaned.replace(match.group(0), '')
            elif not url_path:
                after = content[match.end():]
                detected = _find_path_in_text(after)
                if detected:
                    file_path = os.path.expanduser(detected)
                    cleaned = cleaned.replace(match.group(0) + detected, '', 1)
            if file_path:
                found.append(file_path)
        seen: set = set()
        unique: list = []
        for p in found:
            if p not in seen:
                seen.add(p)
                unique.append(p)
        cleaned = re.sub(r'\n{3,}', '\n\n', cleaned).strip()
        return unique, cleaned

"""

# Insert before _keep_typing method
keep_typing_match = re.search(r'(\n    async def _keep_typing\()', content)
if keep_typing_match:
    content = content[:keep_typing_match.start()] + patch + content[keep_typing_match.start():]
    # Also update extract_local_files integration
    old_line = "local_files, text_content = self.extract_local_files(text_content)"
    new_lines = """md_images, text_content = self.extract_markdown_images(text_content)
                if md_images:
                    logger.info("[%s] extract_markdown_images found %d local image(s)", self.name, len(md_images))

                local_files, text_content = self.extract_local_files(text_content)"""
    content = content.replace(old_line, new_lines)
    open(sys.argv[1], 'w').write(content)
    print("OK")
else:
    print("FAIL: _keep_typing not found")
    sys.exit(1)
PYEOF
        if python3 /tmp/_patch_extract.py "$BASE_PY"; then
            echo "✓ base.py extract_markdown_images 已添加"
        else
            echo "⚠ base.py 补丁失败"
        fi
        rm -f /tmp/_patch_extract.py
    else
        echo "  base.py 已包含 extract_markdown_images（跳过）"
    fi
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
# 9. 更新 .env：注释官方 weixin 变量，添加 wechat_ilink 变量
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
if grep -q "wechat_ilink" "$TOOLS_CONFIG" 2>/dev/null; then
    echo "  ✓ tools_config.py 已注册"
else
    echo "  ✗ tools_config.py 未注册 wechat_ilink"
    VERIFY_OK=false
fi

# 检查 toolsets.py
if grep -q "hermes-wechat-ilink" "$TOOLSETS_PY" 2>/dev/null; then
    echo "  ✓ toolsets.py 已注册"
else
    echo "  ✗ toolsets.py 未注册 wechat_ilink toolset"
    VERIFY_OK=false
fi

# 检查 cron/scheduler.py
if grep -q "WECHAT_ILINK" "$SCHEDULER_PY" 2>/dev/null; then
    echo "  ✓ cron/scheduler.py 已注册"
else
    echo "  ✗ cron/scheduler.py 未注册 wechat_ilink"
    VERIFY_OK=false
fi

# 检查 base.py extract_markdown_images
if grep -q "extract_markdown_images" "$BASE_PY" 2>/dev/null; then
    echo "  ✓ base.py extract_markdown_images"
else
    echo "  ⚠ base.py extract_markdown_images 未添加（图片发送可能受限）"
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
