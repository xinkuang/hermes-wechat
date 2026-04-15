# Hermes 微信 iLink Bot

让 Hermes AI 助手通过微信与你对话，扫码即用。

## 功能特点

- 📱 **扫码登录** - 微信扫码即可使用，凭据自动保存
- 🤖 **AI 对话** - 连接 Hermes AI，支持 Claude、GPT、国产模型
- 💬 **消息收发** - 支持文本、图片、文件
- 🔄 **自动重连** - 断线自动重连
- ⚡ **开机自启** - 支持 systemd 服务管理
- 📝 **Markdown 格式化** - AI 回复自动转换为微信友好格式
- 🛡️ **消息去重** - 防止网络重试导致重复回复
- 🔐 **Token 持久化** - 重启后 context_token 自动恢复
- 🏠 **SetHome 支持** - 通过 `/sethome` 命令设置 Home 频道
- 🔧 **运行时注入** - 不修改 Hermes 源码，升级不受影响

## 系统要求

- Python 3.9+
- Linux（推荐 Ubuntu/Debian，支持 systemd）
- 或 macOS（手动启动模式）

## 快速开始

### 前置条件

确保已安装 [Hermes Agent](https://github.com/nickyangtc/hermes)：

```bash
pip install hermes-agent
```

安装后可通过 `hermes gateway status` 验证。

### 一键安装

```bash
# 下载项目
git clone https://github.com/xinkuang/hermes-wechat.git
cd hermes-wechat

# 运行安装脚本
bash install.sh
```

安装脚本自动完成以下操作：
1. 安装依赖（wechatbot-sdk、qrcode）
2. 复制 wechat_ilink.py 适配器到 Hermes gateway
3. 备份官方微信 weixin 插件
4. **安装运行时注入补丁（sitecustomize.py）**
5. 更新 config.yaml 和 .env
6. 修正 systemd 服务 Python 路径
7. 重启 Hermes Gateway

### 运行时注入原理

v2.0 采用 **运行时注入** 架构，不再修改 Hermes 源码文件：

```
Python 启动
  → sitecustomize.py 自动加载
    → 注册 sys.meta_path 导入钩子
      → 当 gateway.config 被导入时
        → 自动注入 Platform.WECHAT_ILINK 枚举
      → 当 gateway.run 被导入时
        → 自动包装 _create_adapter 方法
      → 当 toolsets 被导入时
        → 自动注册 hermes-wechat-ilink 工具集
      → 当 cron.scheduler 被导入时
        → 自动包装 _deliver_result 投递函数
```

**优势**：Hermes 升级后，补丁会在下次 Python 启动时自动重新应用，无需重新运行 install.sh。

### 获取登录二维码

安装完成后，查看日志获取二维码：

```bash
hermes gateway logs | grep 'Scan this URL' | tail -1
```

复制输出的 URL 到手机浏览器打开，然后用微信扫码。

### 测试

扫码登录成功后，在微信中给机器人发一条消息，AI 会自动回复。

### 卸载

```bash
cd hermes-wechat
bash hermes-wechat.sh uninstall    # 或 bash uninstall.sh，两者等价
```

卸载脚本会完成以下操作：
1. 停止并卸载 systemd 服务
2. 删除 wechat_ilink.py 适配器
3. 恢复官方微信 weixin.py
4. **删除 sitecustomize.py（运行时补丁）**
5. 清理 config.yaml 和 .env 中的 wechat_ilink 配置
6. 清理 wechatbot 登录凭据

## 服务管理

| 命令 | 说明 |
|------|------|
| `hermes gateway status` | 查看 Hermes 服务状态 |
| `hermes gateway logs` | 查看 Hermes 运行日志 |
| `hermes gateway stop` | 停止 Hermes 服务 |
| `hermes gateway restart` | 重启 Hermes 服务 |
| `bash hermes-wechat.sh start` | 启动 systemd 服务 |
| `bash hermes-wechat.sh stop` | 停止 systemd 服务 |
| `bash hermes-wechat.sh restart` | 重启 systemd 服务 |
| `bash hermes-wechat.sh status` | 查看 systemd 服务状态 |
| `bash hermes-wechat.sh logs` | 查看 systemd 服务日志 |
| `bash hermes-wechat.sh uninstall` | 卸载微信插件（完全恢复） |

## 配置

### 设置模型

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

### 设置 API Key

编辑 `~/.hermes/.env`：

```env
# 阿里云 GLM
DASHSCOPE_API_KEY=sk-xxx

# OpenAI
OPENAI_API_KEY=sk-xxx

# Claude
ANTHROPIC_API_KEY=sk-ant-xxx

# Gateway 配置
GATEWAY_ALLOW_ALL_USERS=true
WECHAT_ILINK_ALLOW_ALL_USERS=true
```

**⚠️ 重要：.env 文件格式要求**

systemd 的 `EnvironmentFile` 不处理 shell 语法：

| 写法 | 是否正确 |
|------|:-------:|
| `KEY=value` | ✅ 正确 |
| `KEY="value"` | ❌ 引号会变成值的一部分 |
| `KEY=${OTHER}` | ❌ 变量引用不会展开 |

### 平台配置

`install.sh` 已自动在 `~/.hermes/config.yaml` 中添加：

```yaml
platforms:
  wechat_ilink:
    enabled: true
    extra:
      dm_policy: "open"        # open | allowlist | disabled
      storage_dir: "~/.wechatbot"
```

| 配置项 | 说明 |
|--------|------|
| `dm_policy` | 私聊策略：`open` 所有人可私聊，`allowlist` 仅白名单，`disabled` 禁用私聊 |
| `allow_from` | 私聊白名单（dm_policy=allowlist 时生效） |
| `storage_dir` | 登录凭据保存路径 |

### 设置 Home 频道

在 Hermes 中运行 `/sethome` 命令即可设置 Home 频道，运行时补丁已自动支持。

## 常见问题

### Q: 二维码看不清怎么办？
A: 终端会同时显示链接，复制链接到手机浏览器打开，然后用微信扫码。

### Q: 首次登录后下次还需要扫码吗？
A: 不需要。凭据保存在 `~/.wechatbot/` 目录，自动登录。

### Q: 登录失败怎么办？
A: 删除凭据后重试：
```bash
rm -rf ~/.wechatbot/
hermes gateway restart
```

### Q: 发消息没反应？
A: 按以下步骤排查：
```bash
# 1. 检查 gateway 状态
hermes gateway status

# 2. 查看日志
hermes gateway logs | grep -i error

# 3. 检查 wechat_ilink 是否注册
hermes gateway logs | grep -i "wechat_ilink"
```

### Q: 提示 API Key 无效？
A: 检查 `~/.hermes/.env` 中的 API Key，注意不要加引号。

### Q: 以服务方式运行，搜索等功能不工作？
A: systemd 不读取 `~/.bashrc`。所有环境变量必须写在 `~/.hermes/.env` 中。

验证：
```bash
cat /proc/$(pgrep -f gateway.run)/environ | tr '\0' '\n' | grep SERPER
```

### Q: 如何查看登录的微信账号？
A: 查看日志：
```bash
hermes gateway logs | grep "Logged in"
```

### Q: install.sh 修改了 Hermes 官方文件吗？
A: **v2.0 不修改任何源码文件。**

我们使用 Python 的 `sitecustomize.py` 机制，在 Python 启动时通过 `sys.meta_path` 导入钩子动态注入补丁。所有修改仅在内存中进行，Hermes 源码文件保持原始状态。

### Q: Hermes 升级后需要重新安装吗？
A: **不需要。** 运行时补丁在每次 Python 启动时自动应用，与源码版本无关。只要 wechat_ilink.py 适配器文件仍在 `gateway/platforms/` 目录中，就能正常工作。

唯一需要重新安装的情况：Hermes 的 Python venv 被完全删除重建（此时 sitecustomize.py 会被清除）。重新运行 `bash install.sh` 即可恢复。

### Q: 如何回退到官方微信 weixin？
A: 运行 `uninstall.sh`，然后编辑 `~/.hermes/config.yaml` 启用 `weixin` 平台。

## 版本历史

### v2.0 - 2026-04-15: 运行时注入架构

**架构重构：从 sed 补丁到运行时注入**

| 之前（v1.4） | 现在（v2.0） |
|-------------|-------------|
| sed 修改 6 个源码文件 | 仅安装 sitecustomize.py |
| Hermes 升级后全部失效 | 自动重新应用，无需操作 |
| 卸载需恢复 6 个文件 | 删除 1 个文件即可 |

**补丁注入点：**

| 注入目标 | 注入内容 |
|---------|---------|
| Platform 枚举 | 注入 WECHAT_ILINK 成员 |
| _create_adapter | 包装方法，处理 WECHAT_ILINK case |
| TOOLSETS 字典 | 注册 hermes-wechat-ilink 工具集 |
| cron scheduler | 包装 _deliver_result 投递函数 |
| BasePlatformAdapter | 注入 extract_markdown_images 方法 |
| load_gateway_config | 包装方法，加载 wechat_ilink 配置 |

### v1.4 - 2026-04-15: 补全核心改造

**问题修复：**

| 问题 | 根因 | 修复 |
|------|------|------|
| AI 回答"我没有终端访问权限" | toolsets.py 缺少 hermes-wechat-ilink 工具集定义 | install.sh 自动注册 toolset |
| Cron 任务执行成功但收不到消息 | cron/scheduler.py 缺少 wechat_ilink 投递映射 | install.sh 补丁 platform_map |
| AI 生成的图片不发送 | base.py 缺少 extract_markdown_images 方法 | install.sh 补丁 base.py |

**改造文件：**
- `install.sh` → v1.4，新增 3 个补丁步骤 + 验证检查
- `uninstall.sh` → 同步更新清理范围

### v1.3 - 2026-04-14: 一键安装/卸载脚本

**新增功能：**

| 功能 | 说明 |
|------|------|
| `install.sh` | 一键安装，自动注册所有配置 |
| `uninstall.sh` | 一键卸载，完全恢复原始状态 |
| SDK Bug 修复 | 修复 wechatbot-sdk errcode:-14 检测问题 |
| /sethome 支持 | 补丁 config.py 支持 home_channel 配置 |

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
| 微信会话过期 (errcode=-14) | 中 | 二维码过期后需重新扫码，iLink 协议限制 |
| asyncio.run() 冲突 | 低 | SDK 内部可能与 Gateway 事件循环冲突 |
| 数据库 memory/user_profile 为空 | 低 | 可能影响持久化功能 |

**已解决：**
- ~~Cron 投递静默丢弃~~ → v1.4 运行时注入 scheduler 补丁
- ~~AI 无工具可用~~ → v1.4 运行时注入 toolset
- ~~图片不发送~~ → v1.4 运行时注入 extract_markdown_images
- ~~systemd 路径错误~~ → 修正为 venv/bin/python
- ~~Hermes 升级后失效~~ → v2.0 运行时注入架构

## 文件说明

```
hermes-wechat/
├── install.sh            # 一键安装脚本（v2.0 运行时注入）
├── uninstall.sh          # 一键卸载脚本
├── sitecustomize.py      # 运行时注入补丁（核心）
├── start-wechat.py       # 手动启动脚本（适合测试）
├── hermes-wechat.sh      # systemd 服务管理脚本
├── hermes-wechat.service # systemd 服务配置
├── wechat_ilink.py       # Hermes 适配器（核心）
└── README.md             # 本文档
```

## 技术原理

```
手机微信 ←→ iLink 协议 ←→ wechatbot-sdk ←→ Hermes Gateway ←→ AI 模型
         (扫码登录)      (Python SDK)      (消息路由)       (响应)

运行时注入：
Python 启动 → sitecustomize.py → sys.meta_path 钩子 → 动态注入补丁
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

## 📱 关注公众号

扫码关注公众号，获取更多教程和更新：

![公众号二维码](asserts/qrcode_for_logo.jpg)

---

> 基于 [wechatbot-sdk](https://wechatbot.dev) 和 [Hermes](https://github.com/nickyangtc/hermes) 构建
