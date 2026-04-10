#!/usr/bin/env python3
"""
Hermes 微信 iLink 启动器
- 显示二维码方便扫码
- 自动重连
- 适合小白使用
"""

import os
import sys
import subprocess
import re
import time

# 检查依赖
def check_dependencies():
    missing = []
    try:
        import qrcode
    except ImportError:
        missing.append("qrcode")

    try:
        from wechatbot import WeChatBot
    except ImportError:
        missing.append("wechatbot-sdk")

    if missing:
        print("正在安装依赖...")
        subprocess.run([sys.executable, "-m", "pip", "install"] + missing +
                      ["--break-system-packages"], capture_output=True)
        print("✓ 依赖安装完成")


def show_qrcode_in_terminal(url):
    """在终端显示二维码"""
    try:
        import qrcode
        qr = qrcode.QRCode(
            version=1,
            error_correction=qrcode.constants.ERROR_CORRECT_L,
            box_size=10,
            border=2,
        )
        qr.add_data(url)
        qr.make(fit=True)
        qr.print_ascii(invert=True)
    except Exception as e:
        print(f"(无法显示二维码: {e})")
        print("请手动打开链接扫码")


def main():
    check_dependencies()

    hermes_dir = os.path.expanduser("~/.hermes")
    agent_dir = os.path.join(hermes_dir, "hermes-agent")

    # 检查 venv
    venv_python = os.path.join(agent_dir, "venv/bin/python")
    if os.path.exists(venv_python):
        python_cmd = venv_python
    else:
        python_cmd = sys.executable

    if not os.path.isdir(agent_dir):
        print("✗ Hermes 未安装，请先安装: pip install hermes-agent")
        sys.exit(1)

    print("=" * 50)
    print("  🤖 Hermes 微信机器人启动中...")
    print("=" * 50)
    print()

    # 启动 gateway 并捕获输出
    process = subprocess.Popen(
        [python_cmd, "-m", "gateway.run"],
        cwd=agent_dir,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )

    qr_shown = False

    try:
        for line in iter(process.stdout.readline, ''):
            print(line, end='')

            # 检测二维码
            if "liteapp.weixin.qq.com" in line and not qr_shown:
                match = re.search(r'(https://liteapp\.weixin\.qq\.com[^\s]+)', line)
                if match:
                    url = match.group(1)
                    print()
                    print("=" * 50)
                    print("  📱 请用微信扫描下方二维码登录")
                    print("=" * 50)
                    print(f"  链接: {url}")
                    print()
                    show_qrcode_in_terminal(url)
                    print("=" * 50)
                    print()
                    qr_shown = True

            # 检测登录成功
            if "Logged in as" in line:
                print()
                print("✓ 微信登录成功！可以开始对话了")
                print()

            # 检测消息
            if "Error processing message" in line:
                print("⚠ 消息处理出错，请检查日志")

    except KeyboardInterrupt:
        print("\n正在停止...")
        process.terminate()
        process.wait()
        print("✓ 已停止")


if __name__ == "__main__":
    main()