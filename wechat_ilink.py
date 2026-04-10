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
            context_token = getattr(message, "context_token", None)
            if context_token:
                self._message_handlers[user_id] = {
                    "context_token": context_token,
                    "message": message,
                }

            # Dispatch to gateway
            await self.handle_message(event)

        except Exception as e:
            logger.error("[%s] Error processing message: %s", self.name, e)

    # -- Outbound messaging -------------------------------------------------

    async def send(
        self,
        chat_id: str,
        content: str,
        reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
        **kwargs,
    ) -> SendResult:
        """Send a text message to a WeChat user."""
        if not self._bot:
            return SendResult(success=False, error="Not connected")

        try:
            # Get stored message context for this user
            handler_info = self._message_handlers.get(chat_id, {})
            original_msg = handler_info.get("message")

            # 分片发送长消息
            if len(content) > MAX_WECHAT_MSG_LENGTH:
                return await self._send_long_message(chat_id, content, original_msg)

            if original_msg:
                # Use reply method which handles context_token automatically
                await self._bot.reply(original_msg, content)
            else:
                # Fallback to direct send (may not work without context)
                await self._bot.send(chat_id, content)

            return SendResult(success=True)

        except Exception as e:
            logger.error("[%s] Send failed: %s", self.name, e)
            return SendResult(success=False, error=str(e))

    async def _send_long_message(
        self, chat_id: str, content: str, original_msg: Any
    ) -> SendResult:
        """分片发送长消息"""
        chunks = []
        for i in range(0, len(content), MAX_WECHAT_MSG_LENGTH):
            chunks.append(content[i:i + MAX_WECHAT_MSG_LENGTH])

        logger.info("[%s] Splitting long message (%d chars) into %d chunks",
                    self.name, len(content), len(chunks))

        success_count = 0
        for i, chunk in enumerate(chunks):
            try:
                if original_msg:
                    await self._bot.reply(original_msg, chunk)
                else:
                    await self._bot.send(chat_id, chunk)
                success_count += 1
                # 分片之间稍微延迟，避免频率限制
                if i < len(chunks) - 1:
                    await asyncio.sleep(0.5)
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
                await self._bot.reply_media(original_msg, image_url, media_type="image")
                if caption:
                    await self._bot.reply(original_msg, caption)
            else:
                await self._bot.send_media(chat_id, image_url, media_type="image")

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
                await self._bot.reply_media(original_msg, file_path, media_type="file")
                if caption:
                    await self._bot.reply(original_msg, caption)
            else:
                await self._bot.send_media(chat_id, file_path, media_type="file")

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