# Hermes 微信 iLink Bot

让 Hermes AI 助手通过微信与你对话，扫码即用。

## 功能特点

- 📱 **扫码登录** - 微信扫码即可使用，凭据自动保存
- 🤖 **AI 对话** - 连接 Hermes AI，支持 Claude、GPT、国产模型
- 💬 **消息收发** - 支持文本、图片、文件
- 🔄 **自动重连** - 断线自动重连
- ⚡ **开机自启** - 支持 systemd 服务管理

## 系统要求

- Python 3.9+
- Linux（推荐 Ubuntu/Debian，支持 systemd）
- 或 macOS（手动启动模式）

## 快速开始

### 一键安装

```bash
# 下载安装包
git clone https://github.com/xinkuang/hermes-wechat.git
cd hermes-wechat

# 运行安装
bash install.sh
```

### 启动方式

**方式一：手动启动（适合测试）**

```bash
python3 start-wechat.py
```

终端会显示二维码，用微信扫码登录。

**方式二：开机自启（推荐服务器部署）**

```bash
# 安装 systemd 服务
bash hermes-wechat.sh install

# 设置开机自启
bash hermes-wechat.sh enable

# 立即启动
bash hermes-wechat.sh start
```

### 服务管理命令

| 命令 | 说明 |
|------|------|
| `bash hermes-wechat.sh status` | 查看服务状态 |
| `bash hermes-wechat.sh logs` | 查看运行日志 |
| `bash hermes-wechat.sh stop` | 停止服务 |
| `bash hermes-wechat.sh restart` | 重启服务 |
| `bash hermes-wechat.sh disable` | 禁用开机自启 |
| `bash hermes-wechat.sh uninstall` | 卸载服务 |

## 使用方法

1. 启动后会自动登录（首次需扫码）
2. 在微信中给机器人发消息
3. AI 会自动回复

## 配置模型

编辑 `~/.hermes/config.yaml`：

```yaml
model:
  default: glm-5
  provider: custom
  base_url: https://coding.dashscope.aliyuncs.com/v1
```

或使用 Claude：

```yaml
model:
  default: claude-sonnet-4.6
  provider: anthropic
```

## 环境变量

在 `~/.hermes/.env` 中配置 API Key：

```env
# API Key（根据使用的模型配置）
DASHSCOPE_API_KEY=sk-xxx        # 阿里云 GLM
OPENAI_API_KEY=sk-xxx           # OpenAI
ANTHROPIC_API_KEY=sk-ant-xxx    # Claude

# 搜索技能（可选）
SERPER_API_KEY=xxx
TAVILY_API_KEY=xxx

# Gateway 配置
GATEWAY_ALLOW_ALL_USERS=true
WECHAT_ILINK_ALLOW_ALL_USERS=true
```

**⚠️ 重要：.env 文件格式要求**

systemd 的 `EnvironmentFile` 不像 shell 那样处理变量：

| 写法 | 是否正确 |
|------|:-------:|
| `KEY=value` | ✅ 正确 |
| `KEY="value"` | ❌ 引号会变成值的一部分 |
| `KEY=${OTHER}` | ❌ 变量引用不会展开 |

**注意**：以服务方式运行时，`~/.bashrc` 中的环境变量不会被 systemd 读取，必须写在 `.env` 文件中。

## 常见问题

### Q: 二维码看不清怎么办？
A: 终端会同时显示链接，复制链接到手机浏览器打开，然后用微信扫码。

### Q: 首次登录后下次还需要扫码吗？
A: 不需要。凭据保存在 `~/.wechatbot/` 目录，自动登录。

### Q: 登录失败怎么办？
A: 删除 `~/.wechatbot/` 目录后重试：
```bash
rm -rf ~/.wechatbot/
```

### Q: 发消息没反应？
A: 检查服务状态：
```bash
bash hermes-wechat.sh status
bash hermes-wechat.sh logs
```

### Q: 提示 API Key 无效？
A: 检查 `~/.hermes/.env` 中的 API Key 是否正确配置，注意不要加引号。

### Q: 以服务方式运行，搜索等功能不工作？
A: systemd 服务不会读取 `~/.bashrc` 中的环境变量。所有变量必须写在 `~/.hermes/.env` 中，格式为 `KEY=value`（无引号）。

验证服务是否加载了环境变量：
```bash
cat /proc/$(pgrep -f gateway.run)/environ | tr '\0' '\n' | grep SERPER
```

### Q: 如何查看登录的微信账号？
A: 查看日志：
```bash
bash hermes-wechat.sh logs | grep "Logged in"
```

## Bug 修复历史

### v1.2 - 2026-04-11: 修复 `send_media` 参数错误

**问题**：发送图片/文件时报错 `unexpected keyword argument 'media_type'`

**根因**：SDK 的 `send_media()` 和 `reply_media()` 不接受 `media_type` 参数，
而是通过 dict key（如 `{"image": bytes}`）或 URL 字符串区分类型

**修复**：移除不支持的 `media_type` 参数，直接传递 URL 字符串

### v1.1 - 2026-04-11: 修复 `ret=-2` 发送失败

**问题**：大量消息发送失败（48 小时 350+ 次），错误 `ret=-2`

**根因**：`context_token`（iLink 协议的发送凭证）过期后未刷新

**修复**：
- 新增 token 主动获取机制（`_ensure_context_token()`）
- 修复 token 读取路径（SDK 用 `_context_token` 私有属性）
- 增加 `ret=-2` 自动重试（刷新 token 后重发）
- 长消息分片间隔从 0.5s 增加到 1s

### v1.0 - 初始版本

初始实现，支持基本的消息收发功能。

## 待修复问题

| 问题 | 严重度 | 说明 |
|------|--------|------|
| asyncio.run() 冲突 | 低 | SDK 内部可能与 Gateway 事件循环冲突 |
| 数据库 memory/user_profile 为空 | 低 | 可能影响持久化功能 |
| 非回复场景无法发送消息 | 中 | Cron/主动消息时无 context_token，需探索替代方案 |

## 文件说明

```
wechat-ilink-installer/
├── install.sh            # 一键安装脚本
├── start-wechat.py       # 启动脚本（带二维码显示）
├── hermes-wechat.sh      # 服务管理脚本
├── hermes-wechat.service # systemd 服务配置
├── wechat_ilink.py       # Hermes 适配器
└── README.md             # 本文档
```

## 技术原理

```
手机微信 ←→ iLink 协议 ←→ wechatbot-sdk ←→ Hermes Gateway ←→ AI 模型
         (扫码登录)      (Python SDK)      (消息路由)       (响应)
```

## ⚠️ 风险提示

**微信个人号机器人存在封号风险**，请知悉：

1. 建议使用**小号**测试，不要使用主账号
2. 控制消息发送频率，避免高频操作
3. 避免发送敏感内容
4. 如需稳定生产环境，建议使用**企业微信**或**微信公众号**

## 许可证

MIT License

---

> 基于 [wechatbot-sdk](https://wechatbot.dev) 和 [Hermes](https://github.com/nickyangtc/hermes) 构建
