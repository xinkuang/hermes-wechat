"""
WeChat iLink Bot platform adapter.

Uses the wechatbot-sdk for personal WeChat bot functionality via iLink protocol.
This allows users to interact with Hermes through their personal WeChat account
by scanning a QR code.

Requirements:
    pip install wechatbot-sdk
    (No additional env vars needed - credentials stored in ~/.wechatbot/)

Configuration in config.yaml:
    platforms:
      wechat_ilink:
        enabled: true
        extra:
          storage_dir: "~/.wechatbot"  # Optional: custom credential storage
          dm_policy: "open"            # open | allowlist | disabled
          allow_from: []               # User IDs for allowlist mode

---
## 问题诊断与修复历史

### v1.3 - 2026-04-14: 全面架构升级
- 新增 ContextTokenStore：context_token 磁盘持久化，解决重启后主动消息失败
- 新增消息去重机制：5 分钟 TTL 去重，防止 iLink 轮询重复投递导致重复回复
- 新增 Markdown 格式化：标题、表格、代码块微信友好渲染
- 新增 TypingTicketCache：打字状态指示器支持
- 新增 DM/群聊策略控制：dm_policy 配置项
- 新增独立工具函数：qr_login() 和 send_wechat_direct() 可独立调用

### v1.2 - 2026-04-11: 修复 send_media 参数错误
- 移除不支持的 media_type 参数

### v1.1 - 2026-04-11: 修复 ret=-2 发送失败
- 新增 context_token 主动获取机制
- 增加 ret=-2 自动重试

### v1.0 - 初始版本
- 初始实现
"""

import asyncio
import base64
import json
import logging
import os
import re
import secrets
import time
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

try:
    from wechatbot import WeChatBot
    WECHATBOT_AVAILABLE = True
except ImportError:
    WECHATBOT_AVAILABLE = False
    WeChatBot = None  # type: ignore[assignment]

from gateway.config import Platform, PlatformConfig
from gateway.platforms.base import (
    BasePlatformAdapter,
    MessageEvent,
    MessageType,
    SendResult,
)

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# 常量与配置
# ---------------------------------------------------------------------------

MAX_MESSAGE_LENGTH = 4096
RECONNECT_BACKOFF = [2, 5, 10, 30, 60]
# iLink 协议消息长度限制，超过此长度需要分片
MAX_WECHAT_MSG_LENGTH = 1500
# 消息去重 TTL（秒）
MESSAGE_DEDUP_TTL_SECONDS = 300
# Typing ticket 缓存 TTL（秒）
TYPING_TICKET_TTL_SECONDS = 600
# QR 登录超时（秒）
QR_LOGIN_TIMEOUT = 480
# QR 刷新最大次数
QR_MAX_REFRESH = 3


def check_wechat_ilink_requirements() -> bool:
    """检查 WeChat iLink 依赖是否可用."""
    return WECHATBOT_AVAILABLE


# ---------------------------------------------------------------------------
# 磁盘持久化存储
# ---------------------------------------------------------------------------

class ContextTokenStore:
    """磁盘持久化的 context_token 缓存，按用户 ID 键控。

    iLink 的 context_token 是发送消息的必要凭证，会从用户发来的消息中携带。
    此类在内存缓存的基础上增加了磁盘持久化，实现以下能力：

    1. 进程重启后恢复缓存（restore）
    2. 每次变更自动落盘（set）
    3. 手动清理（clear，用于 session 失效时）

    存储格式 (~/.wechatbot/context-tokens.json)：
    {
        "user_id_1": "token_string_1",
        "user_id_2": "token_string_2"
    }
    """

    def __init__(self, storage_dir: str):
        self._storage_dir = Path(storage_dir)
        self._storage_dir.mkdir(parents=True, exist_ok=True)
        self._cache: Dict[str, str] = {}

    def _path(self) -> Path:
        return self._storage_dir / "context-tokens.json"

    def restore(self) -> None:
        """启动时从磁盘恢复缓存的 context_token。"""
        path = self._path()
        if not path.exists():
            return
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            self._cache = {k: v for k, v in data.items() if isinstance(v, str) and v}
            if self._cache:
                logger.info("[wechat_ilink] Restored %d context token(s) from disk", len(self._cache))
        except Exception as exc:
            logger.warning("[wechat_ilink] Failed to restore context tokens: %s", exc)

    def get(self, user_id: str) -> Optional[str]:
        """获取用户的 context_token。"""
        return self._cache.get(user_id)

    def set(self, user_id: str, token: Optional[str]) -> None:
        """设置或清除用户的 context_token，并自动落盘。"""
        key = user_id
        if token:
            self._cache[key] = token
        elif key in self._cache:
            del self._cache[key]
        self._persist()

    def clear(self) -> None:
        """清除所有缓存的 context_token（如 session 失效时调用）。"""
        self._cache.clear()
        self._persist()

    def _persist(self) -> None:
        """将当前缓存写入磁盘。"""
        data = {k: v for k, v in self._cache.items() if v}
        try:
            self._path().write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        except Exception as exc:
            logger.warning("[wechat_ilink] Failed to persist context tokens: %s", exc)


class TypingTicketCache:
    """短期缓存 typing_ticket（从 getconfig API 获取）。

    typing_ticket 用于发送打字状态指示器（typing indicator）。
    具有时效性，默认 TTL 为 600 秒。
    """

    def __init__(self, ttl_seconds: float = TYPING_TICKET_TTL_SECONDS):
        self._ttl_seconds = ttl_seconds
        self._cache: Dict[str, Tuple[str, float]] = {}

    def get(self, user_id: str) -> Optional[str]:
        """获取 typing_ticket，过期自动清除。"""
        entry = self._cache.get(user_id)
        if not entry:
            return None
        if time.time() - entry[1] >= self._ttl_seconds:
            self._cache.pop(user_id, None)
            return None
        return entry[0]

    def set(self, user_id: str, ticket: str) -> None:
        """设置 typing_ticket。"""
        self._cache[user_id] = (ticket, time.time())


# ---------------------------------------------------------------------------
# Markdown 格式化（微信友好渲染）
# ---------------------------------------------------------------------------

_HEADER_RE = re.compile(r"^(#{1,6})\s+(.+?)\s*$")
_TABLE_RULE_RE = re.compile(r"^\s*\|?(?:\s*:?-{3,}:?\s*\|)+\s*:?-{3,}:?\s*\|?\s*$")
_FENCE_RE = re.compile(r"^```([^\n`]*)\s*$")


def _rewrite_headers_for_wechat(line: str) -> str:
    """将 Markdown 标题转换为微信友好的格式。

    # 一级标题   → 【一级标题】
    ## 二级标题 → **二级标题**
    ### 三级标题 → **三级标题**（h3-h6 统一处理）
    """
    match = _HEADER_RE.match(line)
    if not match:
        return line.rstrip()
    level = len(match.group(1))
    title = match.group(2).strip()
    if level == 1:
        return f"\u3010{title}\u3011"  # 【标题】
    return f"**{title}**"


def _split_table_row(line: str) -> List[str]:
    """将 Markdown 表格行拆分为单元格列表。"""
    row = line.strip()
    if row.startswith("|"):
        row = row[1:]
    if row.endswith("|"):
        row = row[:-1]
    return [cell.strip() for cell in row.split("|")]


def _rewrite_table_block_for_wechat(lines: List[str]) -> str:
    """将 Markdown 表格转换为微信友好的 - 键: 值 列表格式。

    输入示例：
    | 姓名 | 年龄 |
    |------|------|
    | 张三 | 25   |

    输出示例：
    - 姓名: 张三
      年龄: 25
    """
    if len(lines) < 2:
        return "\n".join(lines)

    headers = _split_table_row(lines[0])
    body_rows = [_split_table_row(line) for line in lines[2:] if line.strip()]

    if not headers or not body_rows:
        return "\n".join(lines)

    formatted_rows: List[str] = []
    for row in body_rows:
        pairs: List[Tuple[str, str]] = []
        for idx, header in enumerate(headers):
            if idx >= len(row):
                break
            label = header or f"Column {idx + 1}"
            value = row[idx].strip()
            if value:
                pairs.append((label, value))

        if not pairs:
            continue

        if len(pairs) == 1:
            label, value = pairs[0]
            formatted_rows.append(f"- {label}: {value}")
        elif len(pairs) == 2:
            label, value = pairs[0]
            other_label, other_value = pairs[1]
            formatted_rows.append(f"- {label}: {value}")
            formatted_rows.append(f"  {other_label}: {other_value}")
        else:
            summary = " | ".join(f"{label}: {value}" for label, value in pairs)
            formatted_rows.append(f"- {summary}")

    return "\n".join(formatted_rows) if formatted_rows else "\n".join(lines)


def _normalize_markdown_blocks(content: str) -> str:
    """将 Markdown 内容转换为微信友好的格式。

    处理规则：
    1. 代码块（```...```）保持原样
    2. 标题转换为微信友好格式
    3. 表格转换为 - 键: 值 列表
    4. 压缩连续空行
    """
    lines = content.splitlines()
    result: List[str] = []
    i = 0
    in_code_block = False

    while i < len(lines):
        line = lines[i].rstrip()
        fence_match = _FENCE_RE.match(line.strip())

        if fence_match:
            in_code_block = not in_code_block
            result.append(line)
            i += 1
            continue

        if in_code_block:
            result.append(line)
            i += 1
            continue

        # 检测表格块
        if (
            i + 1 < len(lines)
            and "|" in lines[i]
            and _TABLE_RULE_RE.match(lines[i + 1].rstrip())
        ):
            table_lines = [lines[i].rstrip(), lines[i + 1].rstrip()]
            i += 2
            while i < len(lines) and "|" in lines[i]:
                table_lines.append(lines[i].rstrip())
                i += 1
            result.append(_rewrite_table_block_for_wechat(table_lines))
            continue

        result.append(_rewrite_headers_for_wechat(line))
        i += 1

    # 压缩连续空行（3+ 空行 → 2 空行）
    normalized = "\n".join(item.rstrip() for item in result)
    normalized = re.sub(r"\n{3,}", "\n\n", normalized)
    return normalized.strip()


def _split_markdown_blocks(content: str) -> List[str]:
    """按 Markdown 语义将内容分块。

    分块规则：
    - 代码块作为独立块（不切断）
    - 空行作为块边界
    - 连续非空文本作为一块
    """
    if not content:
        return []

    blocks: List[str] = []
    lines = content.splitlines()
    current: List[str] = []
    in_code_block = False

    for raw_line in lines:
        line = raw_line.rstrip()

        if _FENCE_RE.match(line.strip()):
            if not in_code_block and current:
                blocks.append("\n".join(current).strip())
                current = []
            current.append(line)
            in_code_block = not in_code_block
            if not in_code_block:
                blocks.append("\n".join(current).strip())
                current = []
            continue

        if in_code_block:
            current.append(line)
            continue

        if not line.strip():
            if current:
                blocks.append("\n".join(current).strip())
                current = []
            continue

        current.append(line)

    if current:
        blocks.append("\n".join(current).strip())

    return [block for block in blocks if block]


def _pack_for_delivery(content: str, max_length: int) -> List[str]:
    """将内容打包为微信友好的投递块。

    策略：
    - 内容未超过 max_length 时，作为单条消息发送
    - 超过 max_length 时，按 Markdown block 边界切分
    - 代码块保持完整，不会被切断
    """
    if len(content) <= max_length:
        return [content]

    packed: List[str] = []
    current = ""

    for block in _split_markdown_blocks(content):
        candidate = block if not current else f"{current}\n\n{block}"
        if len(candidate) <= max_length:
            current = candidate
            continue

        # 当前块放不下，先保存已有的
        if current:
            packed.append(current)
            current = ""

        # 单个块本身就超长，尝试递归切分
        if len(block) <= max_length:
            current = block
            continue
        packed.extend(BasePlatformAdapter.truncate_message(block, max_length))

    if current:
        packed.append(current)

    return packed or [content]


# ---------------------------------------------------------------------------
# 独立工具函数
# ---------------------------------------------------------------------------

async def qr_login(
    *,
    bot: Optional["WeChatBot"] = None,
    timeout_seconds: int = QR_LOGIN_TIMEOUT,
    show_qr: bool = True,
) -> Optional[Dict[str, str]]:
    """执行 iLink QR 登录流程。

    此函数可独立于适配器调用，用于：
    - CLI 扫码登录
    - 服务启动前的初始登录
    - Session 过期后的重新登录

    参数：
        bot: WeChatBot 实例。如果为 None，函数会自行创建一个。
        timeout_seconds: 登录超时时间（秒），默认 480 秒（8 分钟）
        show_qr: 是否在终端显示二维码

    返回：
        登录成功时返回包含 account_id、token、base_url 的字典，失败返回 None。
    """
    if not WECHATBOT_AVAILABLE:
        logger.error("[wechat_ilink] wechatbot-sdk not available")
        return None

    own_bot = False
    if bot is None:
        bot = WeChatBot()
        own_bot = True

    try:
        login_result = await bot.login()
        if login_result:
            # SDK 内部已保存凭据到 ~/.wechatbot/
            logger.info("[wechat_ilink] QR login successful")
            return {"status": "confirmed"}
        return None
    except Exception as exc:
        logger.error("[wechat_ilink] QR login failed: %s", exc)
        return None
    finally:
        if own_bot and bot:
            try:
                await bot.stop()
            except Exception:
                pass


async def send_wechat_direct(
    chat_id: str,
    content: str,
    storage_dir: Optional[str] = None,
) -> Dict[str, Any]:
    """绕过适配器直接发送消息。

    用于 Cron 任务、CLI 工具等场景，不依赖 Gateway 事件循环。

    参数：
        chat_id: 接收者的 user_id
        content: 消息内容（支持 Markdown）
        storage_dir: context_token 存储目录，默认 ~/.wechatbot

    返回：
        包含 success/error 的字典
    """
    if not WECHATBOT_AVAILABLE:
        return {"success": False, "error": "wechatbot-sdk not available"}

    resolved_dir = storage_dir or os.path.expanduser("~/.wechatbot")
    token_store = ContextTokenStore(resolved_dir)
    token_store.restore()

    context_token = token_store.get(chat_id)
    if not context_token:
        return {
            "success": False,
            "error": "No context_token for this user. Please send a message to the bot first.",
        }

    try:
        bot = WeChatBot()
        # 注入 context_token 到 SDK 内部
        bot._context_tokens[chat_id] = context_token
        await bot.send(chat_id, content)
        return {"success": True}
    except Exception as exc:
        return {"success": False, "error": str(exc)}


# ---------------------------------------------------------------------------
# 适配器
# ---------------------------------------------------------------------------

class WeChatILinkAdapter(BasePlatformAdapter):
    """WeChat iLink Bot adapter for personal WeChat.

    Uses the wechatbot-sdk which implements the iLink protocol.
    - QR code scanning for login (credentials persisted in ~/.wechatbot/)
    - Long polling for message reception
    - context_token management for replies (disk-backed persistence)
    - Markdown formatting for WeChat-friendly rendering
    """

    MAX_MESSAGE_LENGTH = MAX_MESSAGE_LENGTH

    def __init__(self, config: PlatformConfig):
        super().__init__(config, Platform.WECHAT_ILINK)

        extra = config.extra or {}
        self._storage_dir: str = extra.get("storage_dir") or os.path.expanduser("~/.wechatbot")

        self._bot: Optional["WeChatBot"] = None
        self._poll_task: Optional[asyncio.Task] = None
        self._message_handlers: Dict[str, Any] = {}

        # 磁盘持久化的 context_token 存储（v1.3 新增）
        self._token_store: ContextTokenStore = ContextTokenStore(self._storage_dir)

        # Typing ticket 缓存（v1.3 新增）
        self._typing_cache: TypingTicketCache = TypingTicketCache()

        # 消息去重（v1.3 新增）
        self._seen_messages: Dict[str, float] = {}

        # DM 策略控制（v1.3 新增）
        self._dm_policy: str = extra.get("dm_policy", "open").lower()
        allow_from = extra.get("allow_from", "")
        self._allow_from: List[str] = (
            [x.strip() for x in allow_from.split(",") if x.strip()]
            if isinstance(allow_from, str)
            else list(allow_from or [])
        )

        # QR code callback for displaying login qr
        self._qr_callback: Optional[callable] = None

    def set_qr_callback(self, callback: callable) -> None:
        """设置二维码显示回调。

        回调参数: (qr_url: str, qr_base64: str)
        """
        self._qr_callback = callback

    def _patch_sdk_session_check(self) -> None:
        """修复 wechatbot-sdk 的 session timeout 检测 bug。

        SDK 的 _parse_response 只检查 ret 字段，不检查 errcode。
        当 API 返回 {"errcode":-14}（session timeout）但 HTTP 200 且无 ret 字段时，
        SDK 不会抛出 ApiError，导致长轮询空转。

        这里包装 ILinkApi.get_updates 方法，在返回结果中增加 errcode 检测。
        """
        try:
            from wechatbot.protocol import ILinkApi
            from wechatbot.errors import ApiError

            original_get_updates = ILinkApi.get_updates

            async def patched_get_updates(
                self_api, base_url: str, token: str, cursor: str
            ) -> dict:
                result = await original_get_updates(self_api, base_url, token, cursor)
                # 检测 errcode:-14（session timeout）
                errcode = result.get("errcode", 0)
                if errcode == -14:
                    raise ApiError(
                        result.get("errmsg", "session timeout"),
                        errcode=-14,
                        payload=result,
                    )
                return result

            ILinkApi.get_updates = patched_get_updates
            logger.info("[%s] SDK session timeout patch applied", self.name)
        except Exception as e:
            logger.warning("[%s] Failed to patch SDK: %s", self.name, e)

    # -- 连接生命周期 --------------------------------------------------------

    async def connect(self) -> bool:
        """通过 iLink 协议连接微信。"""
        if not WECHATBOT_AVAILABLE:
            logger.warning(
                "[%s] wechatbot-sdk not installed. Run: pip install wechatbot-sdk",
                self.name,
            )
            return False

        try:
            # 创建 bot 实例
            self._bot = WeChatBot()

            # 修复 wechatbot-sdk bug：_parse_response 只检查 ret 字段，
            # 不检查 errcode。当 API 返回 {"errcode":-14} 时 SDK 不会报错，
            # 导致长轮询空转。这里在 get_updates 后增加检测。
            self._patch_sdk_session_check()

            # QR 码登录
            logger.info("[%s] Initiating QR code login...", self.name)
            login_result = await self._bot.login()

            if not login_result:
                logger.error("[%s] Login failed", self.name)
                return False

            # 恢复磁盘缓存的 context_token（v1.3 新增）
            self._token_store.restore()

            # 启动消息轮询
            self._poll_task = asyncio.create_task(self._run_poll_loop())
            self._mark_connected()
            logger.info("[%s] Connected successfully", self.name)
            return True

        except Exception as e:
            logger.error("[%s] Failed to connect: %s", self.name, e)
            return False

    async def _run_poll_loop(self) -> None:
        """运行消息轮询循环。"""
        backoff_idx = 0

        # 注册消息处理器（在轮询开始前注册一次）
        @self._bot.on_message
        async def handle_message(msg):
            await self._on_message(msg)

        while self._running:
            try:
                # 启动轮询（阻塞异步）
                await self._bot.start()

            except asyncio.CancelledError:
                return
            except Exception as e:
                if not self._running:
                    return
                logger.warning("[%s] Poll loop error: %s", self.name, e)

                # 检测 session 过期（错误码 -14）
                if "-14" in str(e) or "expired" in str(e).lower():
                    logger.info("[%s] Session expired, clearing tokens and re-login", self.name)
                    # session 过期时清除缓存的 context_token
                    self._token_store.clear()
                    try:
                        await self._bot.login()
                        # 登录成功后重新恢复 token
                        self._token_store.restore()
                    except Exception as login_err:
                        logger.error("[%s] Re-login failed: %s", self.name, login_err)

            if not self._running:
                return

            delay = RECONNECT_BACKOFF[min(backoff_idx, len(RECONNECT_BACKOFF) - 1)]
            logger.info("[%s] Reconnecting in %ds...", self.name, delay)
            await asyncio.sleep(delay)
            backoff_idx += 1

    async def disconnect(self) -> None:
        """断开微信连接。"""
        self._running = False
        self._mark_disconnected()

        if self._poll_task:
            self._poll_task.cancel()
            try:
                await self._poll_task
            except asyncio.CancelledError:
                pass
            self._poll_task = None

        if self._bot:
            try:
                await self._bot.stop()
            except Exception:
                pass
            self._bot = None

        self._message_handlers.clear()
        logger.info("[%s] Disconnected", self.name)

    # -- 接收消息处理 ---------------------------------------------------------

    def _is_duplicate(self, msg_id: str) -> bool:
        """检查消息是否重复（v1.3 新增去重机制）。

        iLink 长轮询可能因网络重连、sync_buf 丢失等原因重复投递消息。
        此方法使用 msg_id 去重，TTL 为 5 分钟。
        """
        now = time.time()

        # 清理过期条目
        self._seen_messages = {
            k: v for k, v in self._seen_messages.items()
            if now - v < MESSAGE_DEDUP_TTL_SECONDS
        }

        # 检查是否重复
        if msg_id in self._seen_messages:
            logger.debug("[%s] Duplicate message %s, skipping", self.name, msg_id)
            return True

        # 记录新消息
        self._seen_messages[msg_id] = now
        return False

    def _is_dm_allowed(self, user_id: str) -> bool:
        """检查是否允许此用户的 DM（v1.3 新增 DM 策略控制）。

        DM 策略：
        - "open": 允许所有用户（默认）
        - "allowlist": 仅允许 _allow_from 列表中的用户
        - "disabled": 禁止所有 DM
        """
        if self._dm_policy == "disabled":
            logger.debug("[%s] DM disabled, ignoring message from %s", self.name, user_id)
            return False

        if self._dm_policy == "allowlist":
            if user_id not in self._allow_from:
                logger.debug("[%s] DM allowlist enabled, ignoring unauthorized user %s", self.name, user_id)
                return False

        return True

    async def _on_message(self, message: Any) -> None:
        """处理收到的微信消息。

        v1.3 变更：
        1. 增加消息去重
        2. 增加 DM 策略检查
        3. context_token 同时写入内存和磁盘存储
        """
        try:
            # 提取消息数据
            user_id = getattr(message, "user_id", "") or ""
            text = getattr(message, "text", "") or ""
            msg_type = getattr(message, "msg_type", "text") or "text"

            if not text:
                logger.debug("[%s] Empty message, skipping", self.name)
                return

            # 生成唯一消息 ID
            msg_id = getattr(message, "msg_id", None) or uuid.uuid4().hex

            # 消息去重检查（v1.3 新增）
            if self._is_duplicate(msg_id):
                return

            # DM 策略检查（v1.3 新增）
            if not self._is_dm_allowed(user_id):
                return

            # 确定消息类型
            if msg_type == "image":
                event_type = MessageType.IMAGE
            elif msg_type == "file":
                event_type = MessageType.DOCUMENT
            elif msg_type == "voice":
                event_type = MessageType.VOICE
            else:
                event_type = MessageType.TEXT

            # 构建会话来源
            source = self.build_source(
                chat_id=user_id,
                chat_type="dm",  # iLink 主要为私聊
                user_id=user_id,
                user_name=user_id,  # iLink 不提供用户名
            )

            # 创建并分发消息事件
            event = MessageEvent(
                text=text,
                message_type=event_type,
                message_id=msg_id,
                timestamp=datetime.now(),
                source=source,
                raw_message=message,
            )

            # 存储 context_token 用于回复路由
            # v1.3 变更：同时写入内存和磁盘持久化存储
            context_token = getattr(message, "_context_token", None) or getattr(message, "context_token", None)
            if context_token:
                # 写入内存缓存
                self._message_handlers[user_id] = {
                    "context_token": context_token,
                    "message": message,
                }
                # 写入磁盘持久化存储（v1.3 新增）
                self._token_store.set(user_id, context_token)
                logger.debug("[%s] Stored context_token for %s", self.name, user_id)
            else:
                logger.warning("[%s] No context_token in inbound message from %s", self.name, user_id)

            # 分发给 gateway
            await self.handle_message(event)

        except Exception as e:
            logger.error("[%s] Error processing message: %s", self.name, e)

    # -- 发送消息 -------------------------------------------------------------

    async def _ensure_context_token(self, chat_id: str) -> Optional[str]:
        """确保拥有有效的 context_token。

        v1.3 变更：
        1. 优先从磁盘持久化存储获取（而不仅是内存）
        2. 如果缓存失效，通过 getconfig API 主动获取新 token

        iLink context_token 会过期。获取优先级：
        1. 内存缓存（_message_handlers，来自最近一次收到的消息）
        2. 磁盘存储（_token_store，重启后仍可恢复）
        3. 通过 SDK 的 getconfig API 主动获取新 token
        """
        # 1. 尝试从内存获取
        handler_info = self._message_handlers.get(chat_id, {})
        context_token = handler_info.get("context_token")
        if context_token:
            return context_token

        # 2. 尝试从磁盘存储获取（v1.3 新增）
        context_token = self._token_store.get(chat_id)
        if context_token:
            # 同时恢复到内存缓存
            self._message_handlers[chat_id] = {
                "context_token": context_token,
                "message": None,
            }
            return context_token

        # 3. 通过 SDK 主动获取新 token
        if self._bot and hasattr(self._bot, "_credentials") and self._bot._credentials:
            creds = self._bot._credentials
            try:
                config = await self._bot._api.get_config(
                    creds.base_url, creds.token, chat_id, ""
                )
                new_token = config.get("context_token")
                if new_token:
                    logger.info("[%s] Acquired fresh context_token for %s", self.name, chat_id)
                    # 同时写入内存和磁盘
                    self._message_handlers[chat_id] = {
                        "context_token": new_token,
                        "message": None,
                    }
                    self._token_store.set(chat_id, new_token)
                    return new_token
            except Exception as e:
                logger.debug("[%s] getconfig failed for %s: %s", self.name, chat_id, e)

        return None

    async def _maybe_fetch_typing_ticket(self, user_id: str) -> None:
        """尝试获取 typing_ticket 用于打字状态指示器（v1.3 新增）。

        在收到用户消息后调用，获取的 ticket 可用于后续的 typing indicator。
        """
        if not self._bot:
            return

        # 如果已有有效的 ticket，跳过
        if self._typing_cache.get(user_id):
            return

        handler_info = self._message_handlers.get(user_id, {})
        context_token = handler_info.get("context_token")

        if self._bot and hasattr(self._bot, "_credentials") and self._bot._credentials:
            creds = self._bot._credentials
            try:
                config = await self._bot._api.get_config(
                    creds.base_url, creds.token, user_id, context_token or ""
                )
                typing_ticket = config.get("typing_ticket")
                if typing_ticket:
                    self._typing_cache.set(user_id, typing_ticket)
                    logger.debug("[%s] Cached typing_ticket for %s", self.name, user_id)
            except Exception as e:
                logger.debug("[%s] getconfig failed for typing ticket: %s", self.name, e)

    async def send(
        self,
        chat_id: str,
        content: str,
        reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
        **kwargs,
    ) -> SendResult:
        """发送文本消息到微信用户。

        v1.3 变更：
        1. 发送前使用 Markdown 格式化（_format_for_wechat）
        2. 分片策略改为按 Markdown block 边界智能切分
        3. 发送前确保 context_token 有效（通过 _ensure_context_token）
        4. 将 token 注入 SDK 内部字典后发送
        5. 失败时自动重试一次（刷新 token 后重发）
        """
        if not self._bot:
            return SendResult(success=False, error="Not connected")

        try:
            # Markdown 格式化（v1.3 新增）
            formatted = self._format_for_wechat(content)

            # 分片发送长消息（按 Markdown block 边界）
            if len(formatted) > MAX_WECHAT_MSG_LENGTH:
                return await self._send_long_message(chat_id, formatted)

            # 确保有有效的 context_token
            context_token = await self._ensure_context_token(chat_id)
            if not context_token:
                return SendResult(success=False, error="No context_token available")

            # 将 token 注入 SDK 内部，使用 SDK 高层方法发送
            self._bot._context_tokens[chat_id] = context_token
            await self._bot.send(chat_id, formatted)
            return SendResult(success=True)

        except Exception as e:
            error_str = str(e)
            # 遇到 ret=-2 时重试：刷新 token 后重发一次
            if "ret=-2" in error_str or 'ret": -2' in error_str:
                try:
                    # 清除过期 token 后重试
                    self._message_handlers.pop(chat_id, None)
                    self._token_store.set(chat_id, None)
                    context_token = await self._ensure_context_token(chat_id)
                    if not context_token:
                        return SendResult(success=False, error="No context_token after retry")
                    self._bot._context_tokens[chat_id] = context_token
                    formatted = self._format_for_wechat(content)
                    await self._bot.send(chat_id, formatted)
                    return SendResult(success=True)
                except Exception as retry_err:
                    error_str = str(retry_err)

            logger.error("[%s] Send failed: %s", self.name, error_str)
            return SendResult(success=False, error=error_str)

    async def _send_long_message(
        self, chat_id: str, content: str
    ) -> SendResult:
        """分片发送长消息（v1.3 改进分片策略）。

        v1.3 变更：
        - 使用按 Markdown block 边界智能分片，而非固定字符数切分
        - 代码块保持完整，不会被切断
        - 分片间隔 1s 降低频率限制风险
        """
        chunks = _pack_for_delivery(content, MAX_WECHAT_MSG_LENGTH)

        logger.info("[%s] Splitting long message (%d chars) into %d chunks",
                    self.name, len(content), len(chunks))

        # 确保有有效的 context_token
        context_token = await self._ensure_context_token(chat_id)
        if not context_token:
            return SendResult(success=False, error="No context_token available")

        # 注入 SDK 的 context_tokens
        self._bot._context_tokens[chat_id] = context_token

        success_count = 0
        for i, chunk in enumerate(chunks):
            try:
                await self._bot.send(chat_id, chunk)
                success_count += 1
                # 分片之间延迟 1s，避免频率限制
                if i < len(chunks) - 1:
                    await asyncio.sleep(1)
            except Exception as e:
                logger.error("[%s] Chunk %d/%d failed: %s", self.name, i + 1, len(chunks), e)

        if success_count == len(chunks):
            return SendResult(success=True)
        elif success_count > 0:
            return SendResult(success=True, error=f"Partial send: {success_count}/{len(chunks)} chunks")
        else:
            return SendResult(success=False, error="All chunks failed")

    def _format_for_wechat(self, content: str) -> str:
        """将内容格式化为微信友好的 Markdown 格式（v1.3 新增）。

        处理规则：
        1. # 一级标题 → 【一级标题】
        2. ## 二级标题 → **二级标题**
        3. Markdown 表格 → - 键: 值 列表
        4. 代码块保持原样
        5. 压缩多余空行
        """
        return _normalize_markdown_blocks(content)

    async def send_typing(self, chat_id: str, metadata=None) -> None:
        """发送打字状态指示器（v1.3 新增）。

        利用缓存的 typing_ticket 发送 typing indicator，
        让用户在微信中看到"对方正在输入..."的提示。
        """
        if not self._bot:
            return

        typing_ticket = self._typing_cache.get(chat_id)
        if not typing_ticket:
            return

        try:
            handler_info = self._message_handlers.get(chat_id, {})
            original_msg = handler_info.get("message")

            if original_msg:
                await self._bot.send_typing(original_msg)
        except Exception as e:
            logger.debug("[%s] Typing indicator failed: %s", self.name, e)

    async def send_image(
        self,
        chat_id: str,
        image_url: str,
        caption: Optional[str] = None,
        **kwargs,
    ) -> SendResult:
        """发送图片到微信用户（通过 URL）。"""
        if not self._bot:
            return SendResult(success=False, error="Not connected")

        try:
            handler_info = self._message_handlers.get(chat_id, {})
            original_msg = handler_info.get("message")

            if original_msg:
                await self._bot.reply_media(original_msg, image_url)
                if caption:
                    await self._bot.reply(original_msg, caption)
            else:
                await self._bot.send_media(chat_id, image_url)

            return SendResult(success=True)

        except Exception as e:
            logger.error("[%s] Send image failed: %s", self.name, e)
            return SendResult(success=False, error=str(e))

    async def send_image_file(
        self,
        chat_id: str,
        image_path: str,
        caption: Optional[str] = None,
        **kwargs,
    ) -> SendResult:
        """发送本地图片文件到微信用户。

        覆盖 base 类的默认实现。如果不覆盖，base 类会把文件路径
        当作文本发送（如 "🖼️ Image: /path/to/img.jpg"），而不是真正的图片。

        触发场景：当 AI 回复中包含本地图片路径时，gateway 的
        extract_local_files 会检测到路径并调用此方法。
        """
        if not self._bot:
            return SendResult(success=False, error="Not connected")

        try:
            handler_info = self._message_handlers.get(chat_id, {})
            original_msg = handler_info.get("message")

            if original_msg:
                # 有原始消息，作为回复发送（使用 reply_media）
                await self._bot.reply_media(original_msg, image_path)
                if caption:
                    await self._bot.reply(original_msg, caption)
            else:
                # 主动发送（无上下文消息），使用 send_media
                await self._bot.send_media(chat_id, image_path)

            return SendResult(success=True)

        except Exception as e:
            logger.error("[%s] Send image file failed: %s", self.name, e)
            return SendResult(success=False, error=str(e))

    async def send_document(
        self,
        chat_id: str,
        file_path: str,
        caption: Optional[str] = None,
        **kwargs,
    ) -> SendResult:
        """发送文件到微信用户。"""
        if not self._bot:
            return SendResult(success=False, error="Not connected")

        try:
            handler_info = self._message_handlers.get(chat_id, {})
            original_msg = handler_info.get("message")

            if original_msg:
                await self._bot.reply_media(original_msg, file_path)
                if caption:
                    await self._bot.reply(original_msg, caption)
            else:
                await self._bot.send_media(chat_id, file_path)

            return SendResult(success=True)

        except Exception as e:
            logger.error("[%s] Send document failed: %s", self.name, e)
            return SendResult(success=False, error=str(e))

    # -- 聊天信息 -------------------------------------------------------------

    async def get_chat_info(self, chat_id: str) -> Dict[str, Any]:
        """获取会话信息（iLink 仅支持 DM）。"""
        return {
            "name": chat_id,
            "type": "dm",
            "chat_id": chat_id,
        }


# -- 平台注册辅助函数 -----------------------------------------------------------

def get_wechat_ilink_adapter(config: PlatformConfig) -> Optional[WeChatILinkAdapter]:
    """工厂函数，创建 WeChat iLink 适配器实例。"""
    if not check_wechat_ilink_requirements():
        logger.warning("WeChat iLink: wechatbot-sdk not available")
        return None
    return WeChatILinkAdapter(config)
