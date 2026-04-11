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

---
## 问题诊断 (2026-04-11)

### 症状
- 过去 48 小时内 350+ 次发送失败，错误码 `ret=-2`（/ilink/bot/sendmessage failed）
- 几乎所有 outbound 消息都失败：Agent 回复、Cron 简报、Session 重置通知
- Gateway 频繁重启（一天 6+ 次），但不是根因

### 根因分析
iLink 协议的 `context_token` 是发送消息的必要凭证。它有两个特点：
1. **必须从用户发来的消息中提取**（`_on_message` 时保存到 `_message_handlers`）
2. **有时效性** — 长时间无交互后可能过期

旧代码的问题：
- `send()` 在没有 context_token 时直接调用 `_bot.send(chat_id, content)`，
  该 SDK 方法内部查不到 token 就发给空 token，API 返回 ret=-2
- `_send_long_message()` 同理
- 没有任何重试或 token 刷新机制

### 修复方案
1. 新增 `_ensure_context_token()`：优先使用缓存的 token；
   如果没有，通过 `_api.get_config()` 主动获取新的 token
2. `send()` 和 `_send_long_message()` 都先调用 `_ensure_context_token()`
3. 增加 ret=-2 自动重试：刷新 token 后重发一次
4. 分片间隔从 0.5s 增加到 1s，降低频率限制触发概率
"""

import asyncio
import logging
import os
import uuid
from datetime import datetime
from typing import Any, Dict, Optional

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

MAX_MESSAGE_LENGTH = 4096
RECONNECT_BACKOFF = [2, 5, 10, 30, 60]
# iLink 协议消息长度限制，超过此长度需要分片
MAX_WECHAT_MSG_LENGTH = 1500


def check_wechat_ilink_requirements() -> bool:
    """Check if WeChat iLink dependencies are available."""
    return WECHATBOT_AVAILABLE


class WeChatILinkAdapter(BasePlatformAdapter):
    """WeChat iLink Bot adapter for personal WeChat.

    Uses the wechatbot-sdk which implements the iLink protocol.
    - QR code scanning for login (credentials persisted)
    - Long polling for message reception
    - context_token management for replies
    """

    MAX_MESSAGE_LENGTH = MAX_MESSAGE_LENGTH

    def __init__(self, config: PlatformConfig):
        super().__init__(config, Platform.WECHAT_ILINK)

        extra = config.extra or {}
        self._storage_dir: str = extra.get("storage_dir") or os.path.expanduser("~/.wechatbot")

        self._bot: Optional["WeChatBot"] = None
        self._poll_task: Optional[asyncio.Task] = None
        self._message_handlers: Dict[str, Any] = {}

        # QR code callback for displaying login QR
        self._qr_callback: Optional[callable] = None

    def set_qr_callback(self, callback: callable) -> None:
        """Set a callback for QR code display.
        Callback receives: (qr_url: str, qr_base64: str)
        """
        self._qr_callback = callback

    # -- Connection lifecycle -----------------------------------------------

    async def connect(self) -> bool:
        """Connect to WeChat via iLink protocol."""
        if not WECHATBOT_AVAILABLE:
            logger.warning("[%s] wechatbot-sdk not installed. Run: pip install wechatbot-sdk", self.name)
            return False

        try:
            # Create bot instance
            self._bot = WeChatBot()

            # Login with QR code
            logger.info("[%s] Initiating QR code login...", self.name)
            login_result = await self._bot.login()

            if not login_result:
                logger.error("[%s] Login failed", self.name)
                return False

            # Start message polling in background
            self._poll_task = asyncio.create_task(self._run_poll_loop())
            self._mark_connected()
            logger.info("[%s] Connected successfully", self.name)
            return True

        except Exception as e:
            logger.error("[%s] Failed to connect: %s", self.name, e)
            return False

    async def _run_poll_loop(self) -> None:
        """Run the message polling loop."""
        backoff_idx = 0

        # Register message handler ONCE before polling
        @self._bot.on_message
        async def handle_message(msg):
            await self._on_message(msg)

        while self._running:
            try:
                # Start polling (blocking async) - use start() not run()
                await self._bot.start()

            except asyncio.CancelledError:
                return
            except Exception as e:
                if not self._running:
                    return
                logger.warning("[%s] Poll loop error: %s", self.name, e)

                # Check for session expired (-14)
                if "-14" in str(e) or "expired" in str(e).lower():
                    logger.info("[%s] Session expired, re-login required", self.name)
                    try:
                        await self._bot.login()
                    except Exception as login_err:
                        logger.error("[%s] Re-login failed: %s", self.name, login_err)

            if not self._running:
                return

            delay = RECONNECT_BACKOFF[min(backoff_idx, len(RECONNECT_BACKOFF) - 1)]
            logger.info("[%s] Reconnecting in %ds...", self.name, delay)
            await asyncio.sleep(delay)
            backoff_idx += 1

    async def disconnect(self) -> None:
        """Disconnect from WeChat."""
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

    # -- Inbound message processing -----------------------------------------

    async def _on_message(self, message: Any) -> None:
        """Process an incoming WeChat message."""
        try:
            # Extract message data
            user_id = getattr(message, "user_id", "") or ""
            text = getattr(message, "text", "") or ""
            msg_type = getattr(message, "msg_type", "text") or "text"

            if not text:
                logger.debug("[%s] Empty message, skipping", self.name)
                return

            # Generate unique message ID
            msg_id = getattr(message, "msg_id", None) or uuid.uuid4().hex

            # Determine message type
            if msg_type == "image":
                event_type = MessageType.IMAGE
            elif msg_type == "file":
                event_type = MessageType.DOCUMENT
            elif msg_type == "voice":
                event_type = MessageType.VOICE
            else:
                event_type = MessageType.TEXT

            # Build session source
            source = self.build_source(
                chat_id=user_id,
                chat_type="dm",  # iLink is primarily DM
                user_id=user_id,
                user_name=user_id,  # WeChat doesn't provide names in iLink
            )

            # Create and dispatch message event
            event = MessageEvent(
                text=text,
                message_type=event_type,
                message_id=msg_id,
                timestamp=datetime.now(),
                source=source,
                raw_message=message,
            )

            # Store context_token for reply routing
            # NOTE: SDK stores it as _context_token (private attribute with underscore)
            context_token = getattr(message, "_context_token", None) or getattr(message, "context_token", None)
            # DEBUG: print raw and resolved values to stderr (visible in gateway.log)
            print(f"[wechat_ilink DEBUG] _context_token='{getattr(message, '_context_token', '<MISSING>')}' | resolved='{context_token}' | user_id='{user_id}'", flush=True)
            if context_token:
                self._message_handlers[user_id] = {
                    "context_token": context_token,
                    "message": message,
                }
                logger.debug("[%s] Stored context_token for %s", self.name, user_id)
            else:
                logger.warning("[%s] No context_token in inbound message from %s", self.name, user_id)

            # Dispatch to gateway
            await self.handle_message(event)

        except Exception as e:
            logger.error("[%s] Error processing message: %s", self.name, e)

    # -- Outbound messaging -------------------------------------------------

    async def _ensure_context_token(self, chat_id: str) -> Optional[str]:
        """确保拥有有效的 context_token。

        【变更点】旧代码直接使用缓存的 token，过期后导致 ret=-2。
        新方法：优先用缓存 → 缓存失效时通过 getconfig API 主动获取新 token。

        iLink context_tokens 会过期。如果我们没有缓存的 token，
        或者存储的 token 已过期，尝试通过 getconfig API 获取新的。
        """
        handler_info = self._message_handlers.get(chat_id, {})
        original_msg = handler_info.get("message")
        context_token = handler_info.get("context_token")

        if context_token:
            return context_token

        # No context_token stored — try to get a fresh one via getconfig.
        # This works as long as the bot session is still valid.
        if self._bot and hasattr(self._bot, "_credentials") and self._bot._credentials:
            creds = self._bot._credentials
            try:
                config = await self._bot._api.get_config(
                    creds.base_url, creds.token, chat_id, ""
                )
                new_token = config.get("context_token")
                if new_token:
                    logger.info("[%s] Acquired fresh context_token for %s", self.name, chat_id)
                    self._message_handlers[chat_id] = {
                        "context_token": new_token,
                        "message": None,
                    }
                    return new_token
            except Exception as e:
                logger.debug("[%s] getconfig failed for %s: %s", self.name, chat_id, e)

        return None

    async def send(
        self,
        chat_id: str,
        content: str,
        reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
        **kwargs,
    ) -> SendResult:
        """发送文本消息到微信用户。

        【变更点】修复 ret=-2 发送失败问题（根因：context_token 过期/缺失）：
        1. 发送前确保 context_token 有效（通过 _ensure_context_token）
        2. 将 token 注入 SDK 的 _context_tokens 字典，再用 SDK 高层方法发送
        3. 失败时自动重试一次（刷新 token 后重发）
        """
        if not self._bot:
            return SendResult(success=False, error="Not connected")

        try:
            # 分片发送长消息
            if len(content) > MAX_WECHAT_MSG_LENGTH:
                return await self._send_long_message(chat_id, content)

            # 确保有有效的 context_token
            context_token = await self._ensure_context_token(chat_id)
            if not context_token:
                return SendResult(success=False, error="No context_token available")

            # 将 token 注入 SDK，使用 SDK 高层方法发送（有正确的超时/重试处理）
            self._bot._context_tokens[chat_id] = context_token
            await self._bot.send(chat_id, content)
            return SendResult(success=True)

        except Exception as e:
            error_str = str(e)
            # 遇到 ret=-2 时重试：刷新 token 后重发一次
            if "ret=-2" in error_str or "ret\": -2" in error_str:
                try:
                    self._message_handlers.pop(chat_id, None)
                    context_token = await self._ensure_context_token(chat_id)
                    if not context_token:
                        return SendResult(success=False, error="No context_token after retry")
                    self._bot._context_tokens[chat_id] = context_token
                    await self._bot.send(chat_id, content)
                    return SendResult(success=True)
                except Exception as retry_err:
                    error_str = str(retry_err)

            logger.error("[%s] Send failed: %s", self.name, error_str)
            return SendResult(success=False, error=error_str)

    async def _send_long_message(
        self, chat_id: str, content: str
    ) -> SendResult:
        """分片发送长消息。

        【变更点】使用 SDK 高层方法，分片间隔 1s 降低频率限制风险。
        """
        chunks = []
        for i in range(0, len(content), MAX_WECHAT_MSG_LENGTH):
            chunks.append(content[i:i + MAX_WECHAT_MSG_LENGTH])

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
                logger.error("[%s] Chunk %d/%d failed: %s", self.name, i+1, len(chunks), e)

        if success_count == len(chunks):
            return SendResult(success=True)
        elif success_count > 0:
            return SendResult(success=True, error=f"Partial send: {success_count}/{len(chunks)} chunks")
        else:
            return SendResult(success=False, error="All chunks failed")

    async def send_typing(self, chat_id: str, metadata=None) -> None:
        """Send typing indicator."""
        if not self._bot:
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
        """Send an image to a WeChat user."""
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

    async def send_document(
        self,
        chat_id: str,
        file_path: str,
        caption: Optional[str] = None,
        **kwargs,
    ) -> SendResult:
        """Send a file to a WeChat user."""
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

    # -- Chat info ----------------------------------------------------------

    async def get_chat_info(self, chat_id: str) -> Dict[str, Any]:
        """Get chat information (limited in iLink)."""
        return {
            "name": chat_id,  # iLink uses user_id as identifier
            "type": "dm",
            "chat_id": chat_id,
        }


# -- Platform registration helper --------------------------------------------

def get_wechat_ilink_adapter(config: PlatformConfig) -> Optional[WeChatILinkAdapter]:
    """Factory function to create WeChat iLink adapter."""
    if not check_wechat_ilink_requirements():
        logger.warning("WeChat iLink: wechatbot-sdk not available")
        return None
    return WeChatILinkAdapter(config)