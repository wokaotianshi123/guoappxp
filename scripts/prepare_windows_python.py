#!/usr/bin/env python3
"""Windows 版 PY 沙箱备料：把可嵌入的 CPython 放进 windows/runner/python/。

用法（在能联网的 Windows 构建机上跑，产物随仓库/安装包分发）：
    python scripts/prepare_windows_python.py

产物：
    windows/runner/python/python.exe
    windows/runner/python/py_spider_host.py
    windows/runner/python/Lib/site-packages/{requests,bs4,crypto,lxml,...}

Dart 侧 ProcessPyBackend 会启动 <exe目录>/python/python.exe py_spider_host.py --rpc，
通过 stdin/stdout 的 JSON-RPC 调用蜘蛛。CMake 会把该目录拷到 exe 旁。
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TARGET = ROOT / "windows" / "runner" / "python"
HOST_SCRIPT = ROOT / "android" / "app" / "src" / "main" / "python" / "py_spider_host.py"
PYTHON_VERSION = "3.11.9"
EMBED_URL = f"https://www.python.org/ftp/python/{PYTHON_VERSION}/python-{PYTHON_VERSION}-embed-amd64.zip"
GET_PIP_URL = "https://bootstrap.pypa.io/get-pip.py"
PACKAGES = ["requests", "pycryptodome", "beautifulsoup4", "lxml", "pyquery"]


def download(url: str, dest: Path) -> None:
    print(f"下载 {url}")
    with urllib.request.urlopen(url, timeout=120) as response, dest.open("wb") as fh:
        shutil.copyfileobj(response, fh)


def main() -> int:
    if TARGET.exists():
        shutil.rmtree(TARGET)
    TARGET.mkdir(parents=True)
    with tempfile.TemporaryDirectory() as temp:
        archive = Path(temp) / "python-embed.zip"
        download(EMBED_URL, archive)
        with zipfile.ZipFile(archive) as zf:
            zf.extractall(TARGET)

    # 允许 import site，并把 Lib/site-packages 加进搜索路径。
    pth = next(TARGET.glob("python*._pth"), None)
    if pth is None:
        raise SystemExit("未找到 python*._pth，可嵌入包结构异常")
    lines = pth.read_text(encoding="utf-8").splitlines()
    for required in ("Lib\\site-packages", "import site"):
        if required not in lines:
            lines.append(required)
    pth.write_text("\n".join(lines) + "\n", encoding="utf-8")

    # get-pip 后用内置解释器安装依赖。
    with tempfile.TemporaryDirectory() as temp:
        get_pip = Path(temp) / "get-pip.py"
        download(GET_PIP_URL, get_pip)
        python = TARGET / "python.exe"
        subprocess.check_call([str(python), str(get_pip), "--no-warn-script-location"])
        subprocess.check_call(
            [str(python), "-m", "pip", "install", "--no-warn-script-location", *PACKAGES]
        )

    if HOST_SCRIPT.exists():
        shutil.copy2(HOST_SCRIPT, TARGET / "py_spider_host.py")
    else:
        print(f"警告：未找到宿主脚本 {HOST_SCRIPT}", file=sys.stderr)

    print(f"完成：{TARGET}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
