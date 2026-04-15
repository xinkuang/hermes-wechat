"""
sitecustomize.py — Hermes WeChat iLink Auto-Patch Hook

Placed in venv's site-packages. Runs automatically when Python starts,
BEFORE any Hermes modules are imported.

Registers a sys.meta_path finder that injects wechat_ilink support into
Hermes modules as they are first imported.

This replaces the need for sed-based source file patches.
Hermes upgrades won't break wechat_ilink — the patch is re-applied
at runtime on every gateway start.
"""

import sys
import logging
import os
from types import ModuleType

# We can't import Hermes modules yet (they haven't been loaded).
# We'll patch them as they're imported via sys.meta_path.

_patch_state = {}


class WeChatILinkImportHook:
    """sys.meta_path finder that patches Hermes modules on import."""

    def find_spec(self, fullname, path, target=None):
        """Intercept module imports and apply patches."""
        if fullname == "gateway.config":
            return self._make_spec(fullname, path)
        if fullname == "gateway.run":
            return self._make_spec(fullname, path)
        if fullname == "gateway.platforms.base":
            return self._make_spec(fullname, path)
        if fullname == "cron.scheduler":
            return self._make_spec(fullname, path)
        if fullname == "toolsets":
            return self._make_spec(fullname, path)
        if fullname == "hermes_cli.tools_config":
            return self._make_spec(fullname, path)
        return None

    def _make_spec(self, fullname, path):
        """Let the normal import machinery load the module, then patch it."""
        # Find the real spec using the default finder
        for finder in sys.meta_path:
            if isinstance(finder, WeChatILinkImportHook):
                continue
            try:
                spec = finder.find_spec(fullname, path, None)
                if spec is not None:
                    # Wrap the loader to patch after loading
                    orig_loader = spec.loader
                    if orig_loader is not None and hasattr(orig_loader, 'exec_module'):
                        _fullname = fullname
                        spec.loader = _PatchingLoader(orig_loader, _fullname)
                    return spec
            except (ImportError, AttributeError):
                continue
        return None


class _PatchingLoader:
    """Wraps the original module loader and applies patches after exec_module."""

    def __init__(self, orig_loader, module_name):
        self._orig_loader = orig_loader
        self._module_name = module_name

    def create_module(self, spec):
        return self._orig_loader.create_module(spec)

    def exec_module(self, module):
        # First, let the original loader execute
        self._orig_loader.exec_module(module)
        # Then apply our patches
        try:
            _apply_patch(self._module_name, module)
        except Exception as e:
            # Log to stderr since logging may not be configured yet
            print(f"[wechat_ilink] patch failed for {self._module_name}: {e}", file=sys.stderr)

    def module_repr(self, module):
        return self._orig_loader.module_repr(module)


def _apply_patch(module_name, module):
    """Apply the appropriate patch based on module name."""

    if module_name == "gateway.config":
        _patch_platform_enum(module)
        _patch_config_loader(module)

    elif module_name == "gateway.run":
        _patch_create_adapter(module)
        _patch_allowed_users_maps(module)

    elif module_name == "gateway.platforms.base":
        _patch_base_adapter(module)

    elif module_name == "cron.scheduler":
        _patch_scheduler_deliver(module)

    elif module_name == "toolsets":
        _patch_toolsets(module)

    elif module_name == "hermes_cli.tools_config":
        _patch_tools_config(module)


def _patch_platform_enum(module):
    """Inject WECHAT_ILINK into Platform enum."""
    from enum import Enum

    Platform = getattr(module, "Platform", None)
    if Platform is None:
        return

    if hasattr(Platform, "WECHAT_ILINK"):
        return  # Already present (e.g. from source patch)

    # Create the enum member
    member = object.__new__(Platform)
    member._name_ = "WECHAT_ILINK"
    member._value_ = "wechat_ilink"

    Platform._member_map_["WECHAT_ILINK"] = member
    Platform._member_names_.append("WECHAT_ILINK")
    Platform._value2member_map_["wechat_ilink"] = member
    setattr(Platform, "WECHAT_ILINK", member)

    _log("Platform.WECHAT_ILINK injected")


def _patch_create_adapter(module):
    """Wrap GatewayRunner._create_adapter to handle WECHAT_ILINK."""
    GatewayRunner = getattr(module, "GatewayRunner", None)
    if GatewayRunner is None:
        return

    orig = getattr(GatewayRunner, "_create_adapter", None)
    if orig is None:
        return

    from functools import wraps

    @wraps(orig)
    def _create_adapter_patched(self, platform, *args, **kwargs):
        # Check for WECHAT_ILINK first
        Platform = getattr(module, "Platform", None)
        if Platform is not None:
            wechat_ilink = getattr(Platform, "WECHAT_ILINK", None)
            if platform is wechat_ilink:
                return _create_wechat_ilink_adapter(*args, **kwargs)

        # Check by string value too (for enum comparison edge cases)
        if str(platform) == "Platform.WECHAT_ILINK" or str(platform) == "wechat_ilink":
            return _create_wechat_ilink_adapter(*args, **kwargs)

        return orig(self, platform, *args, **kwargs)

    GatewayRunner._create_adapter = _create_adapter_patched
    _log("GatewayRunner._create_adapter wrapped")


def _create_wechat_ilink_adapter(config):
    """Create WeChat iLink adapter instance."""
    from gateway.platforms.wechat_ilink import (
        WeChatILinkAdapter,
        check_wechat_ilink_requirements,
    )
    if not check_wechat_ilink_requirements():
        logging.getLogger(__name__).warning("WeChat iLink: wechatbot-sdk not installed")
        return None
    return WeChatILinkAdapter(config)


def _patch_allowed_users_maps(module):
    """Add WECHAT_ILINK to allowed users env var maps in GatewayRunner."""
    GatewayRunner = getattr(module, "GatewayRunner", None)
    if GatewayRunner is None:
        return

    # These are class-level dicts in GatewayRunner
    platform_env_map = getattr(GatewayRunner, None)

    # The maps are defined inside the run() method as local dicts.
    # We can't easily patch local variables. But the WECHAT_ILINK check
    # in _create_adapter (above) handles the critical path.
    # The allowed_users maps are used for runtime permission checks.
    # We'll handle this at the adapter level instead.
    pass


def _patch_config_loader(module):
    """Wrap load_gateway_config and _apply_env_overrides for wechat_ilink."""
    load_func = getattr(module, "load_gateway_config", None)
    if load_func is None:
        return

    import functools

    @functools.wraps(load_func)
    def _load_gateway_config_patched(*args, **kwargs):
        config = load_func(*args, **kwargs)
        Platform = getattr(module, "Platform", None)
        PlatformConfig = getattr(module, "PlatformConfig", None)
        if Platform is None or PlatformConfig is None:
            return config

        wechat_ilink = getattr(Platform, "WECHAT_ILINK", None)
        if wechat_ilink is None:
            return config

        if wechat_ilink not in config.platforms:
            # Check if wechat_ilink is configured in config.yaml
            try:
                import yaml
                from pathlib import Path
                hermes_home = os.environ.get("HERMES_HOME", os.path.expanduser("~/.hermes"))
                config_path = Path(hermes_home) / "config.yaml"
                if config_path.exists():
                    with open(config_path, encoding="utf-8") as f:
                        yaml_cfg = yaml.safe_load(f) or {}
                    wcfg = yaml_cfg.get("wechat_ilink", {})
                    if isinstance(wcfg, dict) and wcfg.get("enabled", False):
                        pconfig = PlatformConfig(
                            enabled=True,
                            extra=wcfg.get("extra", {}),
                        )
                        config.platforms[wechat_ilink] = pconfig
                        _log("wechat_ilink platform config loaded from config.yaml")
            except Exception:
                pass

        # Set home_channel from env
        home = os.environ.get("WECHAT_ILINK_HOME_CHANNEL", "").strip()
        if home and wechat_ilink in config.platforms:
            HomeChannel = getattr(module, "HomeChannel", None)
            if HomeChannel:
                config.platforms[wechat_ilink].home_channel = HomeChannel(
                    platform=wechat_ilink,
                    chat_id=home,
                    name=os.environ.get("WECHAT_ILINK_HOME_CHANNEL_NAME", "Home"),
                )

        return config

    module.load_gateway_config = _load_gateway_config_patched
    _log("load_gateway_config wrapped")


def _patch_base_adapter(module):
    """Inject extract_markdown_images into BasePlatformAdapter."""
    BasePlatformAdapter = getattr(module, "BasePlatformAdapter", None)
    if BasePlatformAdapter is None:
        return

    if hasattr(BasePlatformAdapter, "extract_markdown_images"):
        return  # Already present

    import re
    from typing import List, Tuple

    @staticmethod
    def extract_markdown_images(content: str) -> Tuple[List[str], str]:
        """Detect markdown image syntax pointing to local file paths."""
        _LOCAL_MEDIA_EXTS = (
            '.png', '.jpg', '.jpeg', '.gif', '.webp',
            '.mp4', '.mov', '.avi', '.mkv', '.webm',
        )
        ext_part = '|'.join(e.lstrip('.') for e in _LOCAL_MEDIA_EXTS)
        md_re = re.compile(r'!\[([^\]]*)\]\(([^)]*)\)')
        found = []
        code_spans = []
        for m in re.finditer(r'```[^\n]*\n.*?```', content, re.DOTALL):
            code_spans.append((m.start(), m.end()))
        for m in re.finditer(r'`[^`\n]+`', content):
            code_spans.append((m.start(), m.end()))

        def _in_code(pos):
            return any(s <= pos < e for s, e in code_spans)

        def _is_local_path(p):
            if not p:
                return False
            p = p.strip()
            if p.startswith(('http://', 'https://', 'data:')):
                return False
            if not (p.startswith('/') or p.startswith('~')):
                return False
            ext_match = re.search(r'\.(' + ext_part + r')$', p, re.IGNORECASE)
            if not ext_match:
                return False
            return os.path.isfile(os.path.expanduser(p))

        def _find_path_in_text(text):
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
            if _in_code(match.start()):
                continue
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

        seen = set()
        unique = []
        for p in found:
            if p not in seen:
                seen.add(p)
                unique.append(p)

        cleaned = re.sub(r'\n{3,}', '\n\n', cleaned).strip()
        return unique, cleaned

    BasePlatformAdapter.extract_markdown_images = extract_markdown_images
    _log("BasePlatformAdapter.extract_markdown_images injected")


def _patch_toolsets(module):
    """Inject hermes-wechat-ilink toolset definition."""
    TOOLSETS = getattr(module, "TOOLSETS", None)
    if TOOLSETS is None:
        return

    if "hermes-wechat-ilink" not in TOOLSETS:
        TOOLSETS["hermes-wechat-ilink"] = {
            "description": "WeChat iLink bot toolset - personal WeChat messaging via iLink protocol (full access)",
            "tools": _HERMES_CORE_TOOLS,
            "includes": []
        }
        _log("toolset hermes-wechat-ilink registered")

    # Add to gateway includes
    gw = TOOLSETS.get("hermes-gateway", {})
    includes = gw.get("includes", [])
    if "hermes-wechat-ilink" not in includes:
        includes.append("hermes-wechat-ilink")
        gw["includes"] = includes
        _log("added to gateway includes")


_HERMES_CORE_TOOLS = [
    "send_message", "session_search", "session_messages",
    "search_memory", "save_memory", "forget_memory", "clear_memory",
    "list_skills", "get_skill", "sethome", "gethome",
    "resolve_chat_id", "get_user_profile", "update_user_profile",
    "get_context", "update_context", "list_contexts",
    "list_toolsets", "get_toolset", "update_toolset",
    "list_mcp_servers", "add_mcp_server", "remove_mcp_server",
    "run_python", "run_shell", "web_search", "web_fetch",
    "list_cron_jobs", "add_cron_job", "remove_cron_job",
    "tick_cron",
]


def _patch_tools_config(module):
    """Inject wechat_ilink into PLATFORMS dict."""
    PLATFORMS = getattr(module, "PLATFORMS", None)
    if PLATFORMS is None:
        return

    if "wechat_ilink" not in PLATFORMS:
        PLATFORMS["wechat_ilink"] = {
            "label": "💬 WeChat iLink",
            "default_toolset": "hermes-wechat-ilink"
        }
        _log("tools_config PLATFORMS registered")


def _patch_scheduler_deliver(module):
    """Wrap _deliver_result to handle wechat_ilink delivery."""
    orig = getattr(module, "_deliver_result", None)
    if orig is None:
        return

    import functools

    @functools.wraps(orig)
    def _deliver_result_patched(job, content, adapters=None, loop=None):
        target = module._resolve_delivery_target(job)
        if target and target["platform"].lower() == "wechat_ilink":
            return _deliver_wechat_ilink(module, job, content, target)
        return orig(job, content, adapters=adapters, loop=loop)

    module._deliver_result = _deliver_result_patched
    _log("scheduler._deliver_result wrapped")


def _deliver_wechat_ilink(mod, job, content, target):
    """Deliver cron job output to wechat_ilink platform."""
    from gateway.config import Platform
    from gateway.config import load_gateway_config
    from tools.send_message_tool import _send_to_platform

    platform = Platform.WECHAT_ILINK
    pconfig = load_gateway_config().platforms.get(platform)
    if not pconfig or not pconfig.enabled:
        msg = "platform 'wechat_ilink' not configured/enabled"
        mod.logger.warning("Job '%s': %s", job["id"], msg)
        return msg

    chat_id = target["chat_id"]
    thread_id = target.get("thread_id")

    # Wrap response
    wrap_response = True
    try:
        from hermes_cli.config import load_config
        wrap_response = load_config().get("cron", {}).get("wrap_response", True)
    except Exception:
        pass

    if wrap_response:
        task_name = job.get("name", job["id"])
        delivery_content = (
            f"Cronjob Response: {task_name}\n"
            f"-------------\n\n"
            f"{content}\n\n"
            f"Note: The agent cannot see this message, and therefore cannot respond to it."
        )
    else:
        delivery_content = content

    # Send via standalone path
    try:
        import asyncio
        coro = _send_to_platform(platform, pconfig, chat_id, delivery_content, thread_id=thread_id)
        result = asyncio.run(coro)
    except Exception as e:
        msg = f"delivery to wechat_ilink:{chat_id} failed: {e}"
        mod.logger.error("Job '%s': %s", job["id"], msg)
        return msg

    if result and result.get("error"):
        msg = f"delivery error: {result['error']}"
        mod.logger.error("Job '%s': %s", job["id"], msg)
        return msg

    mod.logger.info("Job '%s': delivered to wechat_ilink:%s", job["id"], chat_id)
    return None


def _log(msg):
    """Log a patch success message."""
    print(f"[wechat_ilink] ✓ {msg}", file=sys.stderr)


# Register the import hook
sys.meta_path.insert(0, WeChatILinkImportHook())
