#!/usr/bin/env python3
"""准备 iOS 侧嵌入式 CPython（BeeWare Python-Apple-support 预编译包）。

钉死版本（2026-11-13 联网查证，3.13-b18）：
  - 发布仓：beeware/Python-Apple-support，标签规约 ``{PYTHON_VER}-b{BUILD}``；
    选 3.13-b18（CPython 3.13.18，OpenSSL 3.5.9-1，最低 iOS 13.0）。
  - 必须用 3.13、不能用 3.12 的原因（实测结论）：iOS 要求全部二进制模块
    以单个 framework 形式放在包内 Frameworks/ 下，包内其它位置不得有可执
    行二进制；CPython 官方的 .so 转 framework + .fwork 占位 +
    AppleFrameworkLoader 寻址机制只在 3.13 起才有（CPython 文档
    “Using Python on iOS”§7.1.4，BeeWare Briefcase 讨论 #1783）。3.12 包
    没有这套机制，旧脚本把 stdlib 的 lib/ 直接并入 Python.framework 的做法
    会让 _ssl/_socket/_ctypes 等 .so 以未签名状态留在框架内，真机上
    dlopen 必然失败，蜘蛛连 HTTPS 都发不出（框架二进制只静态链接了 26 个
    核心模块，ssl/socket 全靠动态加载，已用 strings 实测确认）。3.13 包
    自带 build/utils.sh，构建期由 Xcode Run Script 阶段调用 install_python
    完成标准库拷贝与 .so 转 framework+签名，运行时走官方布局。
  - 资产命名（该仓 release/publish 工作流规约）：
    ``Python-3.13-iOS-support.b18.tar.gz``，内含 ``Python.xcframework``、
    ``VERSIONS``、``testbed`` 与共享标准库 ``lib/python3.13/``。
  - 下载地址（先 GitHub Release，失败回退 BeeWare 官方 S3 镜像，二者为同一
    发布产物：publish 工作流把 Release 资产同步到 briefcase-support 桶；
    两源 sha256 已实测一致，脚本钉死哈希校验）：
      1. https://github.com/beeware/Python-Apple-support/releases/download/3.13-b18/Python-3.13-iOS-support.b18.tar.gz
      2. https://briefcase-support.s3.amazonaws.com/python/3.13/iOS/Python-3.13-iOS-support.b18.tar.gz

产物（均不进 git，.gitignore 已忽略 ios/Frameworks/）：
  - ios/Frameworks/Python.xcframework        解压出的 XCFramework 本体
        （不做任何合并修改：标准库由构建期 install_python 从包内原布局拷出）
  - ios/Runner.xcodeproj/project.pbxproj     备料后做幂等手术：给 Runner
        目标挂 Python.xcframework 文件引用 + Frameworks 链接条目 + Embed
        Frameworks 内嵌条目（链接不再经 podspec 的 user_target_xcconfig），
        并加一个“Process Python libraries”Run Script 阶段（位置在 Copy
        Bundle Resources 之后、Embed Frameworks 之前），构建期调用
        utils.sh 的 install_python 完成标准库与扩展模块的包内处理
  - ios/PythonBridge/Resources/py_spider_host.py
        宿主脚本的 iOS 侧副本，由本脚本从单一真源逐字同步：
        android/app/src/main/python/py_spider_host.py（安卓已验，禁止手改副本）
  - ios/PythonBridge/Resources/PythonVendor.bundle/
        requests 兼容包（requests/urllib3/certifi/charset_normalizer/idna/
        beautifulsoup4/soupsieve/chardet/typing_extensions，纯 Python wheel
        解包，备料时从 PyPI 下载，不进 git）：iOS 无 pip，安卓 Chaquopy
        预装 requests； iOS 侧由本脚本备料、JHPyBridge.c 起解释器时挂进
        sys.path，蜘蛛 import requests / bs4 与安卓同行为

运行时布局（构建产物内，PythonRuntime.swift 按此探测）：
  - 包内 python/lib/python3.13/os.py        标准库里程碑，PYTHONHOME=包内 python/
  - 包内 Frameworks/_ssl.framework/_ssl 等  扩展模块的单体 framework（已签名）
  - 包内 python/lib/python3.13/lib-dynload/*.fwork  扩展模块的占位寻址文件

CI 用法（最终轮 macOS job，pod install / 构建之前先跑）：
    python3 scripts/prepare_ios_python.py            # 下载+校验+同步宿主脚本+备 requests 兼容包
    python3 scripts/prepare_ios_python.py --check    # 只校验已准备产物，不下载
    cd ios && pod install                            # 再装 Pod（PythonBridge 以
                                                     # :path 引入，pod 侧只留 C 垫片
                                                     # 与头文件路径，框架由 Runner
                                                     # 工程引用/链接/内嵌）
本机（Linux）可跑 --sync-only 验证宿主脚本同步逻辑：
    python3 scripts/prepare_ios_python.py --sync-only
"""

import argparse
import hashlib
import plistlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

SUPPORT_TAG = "3.13-b18"
SUPPORT_ASSET = "Python-3.13-iOS-support.b18.tar.gz"
SUPPORT_URLS = [
    "https://github.com/beeware/Python-Apple-support/releases/download/"
    + SUPPORT_TAG + "/" + SUPPORT_ASSET,
    "https://briefcase-support.s3.amazonaws.com/python/3.13/iOS/" + SUPPORT_ASSET,
]
# GitHub 与 S3 两源实测同一文件（2026-11-13 各下载一次，哈希一致）。
EXPECTED_SHA256 = "d06acf2a9c7964a8689566353a0e707402eff822037de5e29ba0e16040f7047d"
EXPECTED_PYTHON_SERIES = "3.13"

FRAMEWORKS_DIR = ROOT / "ios" / "Frameworks"
XCFRAMEWORK_DIR = FRAMEWORKS_DIR / "Python.xcframework"
CACHE_DIR = FRAMEWORKS_DIR / ".cache"
HOST_SOURCE = ROOT / "android" / "app" / "src" / "main" / "python" / "py_spider_host.py"
HOST_DEST = ROOT / "ios" / "PythonBridge" / "Resources" / "py_spider_host.py"

VENDOR_PACKAGES = (
    ("requests", "2.34.2", "requests"),
    ("urllib3", "2.8.0", "urllib3"),
    ("certifi", "2026.10.23", "certifi"),
    ("charset_normalizer", "3.5.2", "charset_normalizer"),
    ("idna", "3.20", "idna"),
    ("beautifulsoup4", "4.15.0", "bs4"),
    ("soupsieve", "3.0.4", "soupsieve"),
    ("chardet", "7.7.0", "chardet"),
    ("typing_extensions", "4.15.0", "typing_extensions"),
    ("websocket-client", "1.9.2", "websocket"),
    ("httpx", "0.28.1", "httpx"),
    ("httpcore", "1.0.9", "httpcore"),
    ("h11", "0.16.0", "h11"),
    ("sniffio", "1.3.1", "sniffio"),
    ("anyio", "4.15.1", "anyio"),
)
VENDOR_BUNDLE_DIR = ROOT / "ios" / "PythonBridge" / "Resources" / "PythonVendor.bundle"
VENDOR_REQUIRED_FILES = (
    "requests/__init__.py",
    "urllib3/__init__.py",
    "certifi/__init__.py",
    "certifi/cacert.pem",
    "charset_normalizer/__init__.py",
    "idna/__init__.py",
    "bs4/__init__.py",
    "soupsieve/__init__.py",
    "chardet/__init__.py",
    "typing_extensions.py",
    "websocket/__init__.py",
    "httpx/__init__.py",
    "httpcore/__init__.py",
    "h11/__init__.py",
    "sniffio/__init__.py",
    "anyio/__init__.py",
)


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(urls, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    last_error = None
    for url in urls:
        try:
            print("下载：%s" % url)
            request = urllib.request.Request(
                url, headers={"User-Agent": "huoyi-prepare-ios-python/1.0"})
            with urllib.request.urlopen(request) as response, \
                    open(destination, "wb") as out:
                shutil.copyfileobj(response, out)
            digest = sha256_of(destination)
            print("已下载：%s（%d 字节，sha256=%s）"
                  % (destination, destination.stat().st_size, digest))
            if digest != EXPECTED_SHA256:
                raise ValueError(
                    "哈希与钉死值不符（期望 %s，实际 %s），拒绝使用"
                    % (EXPECTED_SHA256, digest))
            return
        except Exception as error:  # noqa: BLE001 逐个回退下载源
            last_error = error
            print("下载失败（%s）：%s" % (url, error), file=sys.stderr)
            destination.unlink(missing_ok=True)
    raise SystemExit("全部下载源失败：%s" % last_error)


def slice_dirs(xcframework):
    info_path = xcframework / "Info.plist"
    if not info_path.is_file():
        raise SystemExit("XCFramework 缺少 Info.plist：%s" % xcframework)
    info = plistlib.loads(info_path.read_bytes())
    libraries = info.get("AvailableLibraries") or []
    if not libraries:
        raise SystemExit("XCFramework Info.plist 无 AvailableLibraries")
    slices = []
    for library in libraries:
        identifier = library.get("LibraryIdentifier", "")
        # 3.12 包用 SupportedPlatforms（列表），3.13 包用 SupportedPlatform（单值）。
        platforms = library.get("SupportedPlatforms")
        if platforms is None:
            single = library.get("SupportedPlatform", "")
            platforms = [single] if single else []
        supported = " ".join(platforms)
        if supported and supported != "ios":
            continue
        path = xcframework / identifier / (library.get("LibraryPath") or "")
        slices.append((identifier, path))
    if not slices:
        raise SystemExit("XCFramework 无 iOS 切片")
    return slices


def validate_xcframework(xcframework):
    """校验版本与结构（3.13 官方布局，不做合并修改）。

    3.13 包布局（实测）：共享标准库在 XCFramework 根 ``lib/python3.13/``；
    各切片的扩展模块在 ``<slice>/lib-<arch>/python3.13/lib-dynload/``；
    构建期处理脚本在 ``build/utils.sh``。校验只认这些位置，不认旧的
    “框架内 lib/”布局。
    """
    if not xcframework.is_dir():
        raise SystemExit("未找到 Python.xcframework：%s" % xcframework)
    slices = slice_dirs(xcframework)
    print("XCFramework 切片：%s" % ", ".join(name for name, _ in slices))
    device = [path for name, path in slices if "simulator" not in name]
    if not device:
        raise SystemExit("XCFramework 缺少真机切片（ios-arm64）")
    stdlib_os = xcframework / ("lib/python%s/os.py" % EXPECTED_PYTHON_SERIES)
    if not stdlib_os.is_file():
        raise SystemExit("XCFramework 缺少共享标准库里程碑：%s" % stdlib_os)
    print("共享标准库：%s" % stdlib_os)
    utils = xcframework / "build" / "utils.sh"
    template = xcframework / "build" / "iOS-dylib-Info-template.plist"
    if not utils.is_file():
        raise SystemExit("XCFramework 缺少构建期处理脚本：%s" % utils)
    if not template.is_file():
        raise SystemExit("XCFramework 缺少 framework 模板：%s" % template)
    print("构建期处理脚本：%s" % utils)
    for name, path in slices:
        headers = list(path.rglob("Python.h"))
        print("切片 %s：Python.h=%s" % (name, headers[0] if headers else "缺失"))
    device_path = device[0]
    if not list(device_path.rglob("Python.h")):
        raise SystemExit("真机切片缺少 Python.h：%s" % device_path)
    # 真机切片扩展模块：lib-arm64/python3.13/lib-dynload/_ssl*.so 必须在，
    # 否则构建期转 framework 后蜘蛛仍无 HTTPS 能力。
    ssl_modules = sorted(device_path.parent.glob(
        "lib-*/python%s/lib-dynload/_ssl*.so" % EXPECTED_PYTHON_SERIES))
    if not ssl_modules:
        raise SystemExit(
            "真机切片缺少 _ssl 扩展模块（lib-*/python%s/lib-dynload/_ssl*.so）：%s"
            % (EXPECTED_PYTHON_SERIES, device_path.parent))
    print("真机切片 _ssl 扩展模块：%s" % ssl_modules[0])


def extract_support_package(archive):
    staging = CACHE_DIR / "extract"
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    with tarfile.open(archive, "r:gz") as tar:
        tar.extractall(staging)  # 官方发布包，可信来源
    versions = staging / "VERSIONS"
    if versions.is_file():
        text = versions.read_text(encoding="utf-8", errors="replace")
        print("发布包 VERSIONS：\n%s" % text.strip())
        if EXPECTED_PYTHON_SERIES not in text:
            raise SystemExit("VERSIONS 未标明 Python %s，与钉死版本不符"
                             % EXPECTED_PYTHON_SERIES)
    candidates = [staging / "Python.xcframework"]
    if not candidates[0].is_dir():
        # 兜底：顶层没有时才在包内搜索（3.13 包的 testbed/ 下还有一个
        # 同名引用，排序上顶层优先，此处显式取顶层避免误取）。
        candidates = sorted(p for p in staging.rglob("Python.xcframework") if p.is_dir())
    if not candidates:
        raise SystemExit("发布包内未找到 Python.xcframework")
    source = candidates[0]
    if XCFRAMEWORK_DIR.exists():
        shutil.rmtree(XCFRAMEWORK_DIR)
    shutil.copytree(source, XCFRAMEWORK_DIR)
    print("已安装：%s（原布局不做修改，标准库由构建期 install_python 处理）"
          % XCFRAMEWORK_DIR)
    others = sorted(p.name for p in staging.iterdir())
    print("发布包顶层条目（除 XCFramework 外仅记录、不安装）：%s" % ", ".join(others))
    validate_xcframework(XCFRAMEWORK_DIR)


PBXPROJ_PATH = ROOT / "ios" / "Runner.xcodeproj" / "project.pbxproj"
XCF_MAIN_GROUP_ID = "97C146E51CF9000F007C117D"
XCF_FRAMEWORKS_PHASE_ID = "97C146EB1CF9000F007C117D"
XCF_EMBED_PHASE_ID = "9705A1C41CF9048500538489"


def _stable_object_id(seed):
    digest = hashlib.md5(("jhyy-ios-python-" + seed).encode("utf-8")).hexdigest()
    return digest[:24].upper()


XCF_FILE_REF_ID = _stable_object_id("fileref")
XCF_LINK_BUILD_ID = _stable_object_id("buildfile-frameworks")
XCF_EMBED_BUILD_ID = _stable_object_id("buildfile-embed")

XCF_RUNNER_TARGET_ID = "97C146ED1CF9000F007C117D"
XCF_RESOURCES_PHASE_ID = "97C146EC1CF9000F007C117D"
XCF_SCRIPT_PHASE_ID = _stable_object_id("script-phase-install-python")
SCRIPT_PHASE_NAME = "Process Python libraries"
# Run Script phase body (raw shell; pbxproj-escaped when written).
# Order matters: this phase must run after Copy Bundle Resources and before
# Embed Frameworks, per the utils.sh header contract. The ad-hoc identity
# fallback keeps `flutter build ios --no-codesign` working: with no signing
# identity Xcode leaves EXPANDED_CODE_SIGN_IDENTITY empty and install_dylib
# would fail to codesign the extension frameworks.
SCRIPT_PHASE_SHELL = (
    "set -e\n"
    "if [ -z \"$EXPANDED_CODE_SIGN_IDENTITY\" ]; then\n"
    "  export EXPANDED_CODE_SIGN_IDENTITY=\"-\"\n"
    "fi\n"
    "source \"$PROJECT_DIR/Frameworks/Python.xcframework/build/utils.sh\"\n"
    "install_python Frameworks/Python.xcframework"
)


def _pbx_escape_shell(script):
    return (script.replace("\\", "\\\\")
            .replace('"', '\\"')
            .replace("\n", "\\n"))


def _script_phase_object():
    return (
        "\t\t%s /* %s */ = {\n"
        "\t\t\tisa = PBXShellScriptBuildPhase;\n"
        "\t\t\talwaysOutOfDate = 1;\n"
        "\t\t\tbuildActionMask = 2147483647;\n"
        "\t\t\tfiles = (\n"
        "\t\t\t);\n"
        "\t\t\tinputPaths = (\n"
        "\t\t\t);\n"
        "\t\t\tname = \"%s\";\n"
        "\t\t\toutputPaths = (\n"
        "\t\t\t);\n"
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        "\t\t\tshellPath = /bin/sh;\n"
        "\t\t\tshellScript = \"%s\";\n"
        "\t\t};"
        % (XCF_SCRIPT_PHASE_ID, SCRIPT_PHASE_NAME, SCRIPT_PHASE_NAME,
           _pbx_escape_shell(SCRIPT_PHASE_SHELL)))


def _script_phase_list_line():
    return "\t\t\t\t%s /* %s */,\n" % (XCF_SCRIPT_PHASE_ID, SCRIPT_PHASE_NAME)


def _pbx_block_span(text, object_id):
    header = text.find("\n\t\t" + object_id)
    if header < 0:
        raise SystemExit("pbxproj 找不到对象：%s" % object_id)
    end = text.find("\n\t\t};", header)
    if end < 0:
        raise SystemExit("pbxproj 对象未闭合：%s" % object_id)
    return header, end


def _pbx_block(text, object_id):
    start, end = _pbx_block_span(text, object_id)
    return text[start:end]


def _pbx_insert_into_list(text, object_id, list_key, line):
    start, end = _pbx_block_span(text, object_id)
    block = text[start:end]
    anchor_text = list_key + " = (\n"
    anchor = block.find(anchor_text)
    if anchor < 0:
        raise SystemExit("pbxproj 对象 %s 无 %s 列表" % (object_id, list_key))
    insert_at = start + anchor + len(anchor_text)
    return text[:insert_at] + line + text[insert_at:]


def _pbx_insert_before_marker(text, marker, line):
    if text.count(marker) != 1:
        raise SystemExit("pbxproj 标记不唯一或缺失：%s" % marker)
    at = text.find(marker)
    return text[:at] + line + text[at:]


def _pbx_replace_object(text, object_id, new_block):
    start, end = _pbx_block_span(text, object_id)
    # _pbx_block_span: start at the newline before the header, end at the
    # newline before the closing "\t\t};". Object text is [start+1, end+5).
    return text[:start + 1] + new_block + text[end + 5:]


def _pbx_script_phase_missing(text):
    missing = []
    if XCF_SCRIPT_PHASE_ID not in text:
        missing.append("Process Python libraries 阶段对象")
        return missing + ["Runner 目标阶段列表条目"]
    block = _pbx_block(text, XCF_SCRIPT_PHASE_ID)
    if "PBXShellScriptBuildPhase" not in block:
        raise SystemExit("pbxproj 脚本阶段对象 %s 不是 PBXShellScriptBuildPhase，拒绝手术"
                         % XCF_SCRIPT_PHASE_ID)
    expected = 'shellScript = "%s";' % _pbx_escape_shell(SCRIPT_PHASE_SHELL)
    if expected not in block:
        missing.append("Process Python libraries 阶段脚本内容")
    target = _pbx_block(text, XCF_RUNNER_TARGET_ID)
    line = _script_phase_list_line().rstrip("\n")
    if XCF_SCRIPT_PHASE_ID not in target:
        missing.append("Runner 目标阶段列表条目")
        return missing
    order = [target.find(XCF_RESOURCES_PHASE_ID),
             target.find(XCF_SCRIPT_PHASE_ID),
             target.find(XCF_EMBED_PHASE_ID)]
    if min(order) < 0 or not (order[0] < order[1] < order[2]):
        missing.append("Process Python libraries 阶段顺序（须在 Resources 之后、Embed 之前）")
    return missing


def _pbx_ensure_script_phase(text):
    """Ensure the Process Python libraries phase object + target list entry.

    Returns (new_text, fixed_items). Idempotent: a correct phase yields no change.
    """
    fixed = []
    if XCF_SCRIPT_PHASE_ID not in text:
        text = _pbx_insert_before_marker(
            text, "/* End PBXShellScriptBuildPhase section */",
            _script_phase_object() + "\n")
        fixed.append("阶段对象")
    else:
        expected = 'shellScript = "%s";' % _pbx_escape_shell(SCRIPT_PHASE_SHELL)
        if expected not in _pbx_block(text, XCF_SCRIPT_PHASE_ID):
            text = _pbx_replace_object(text, XCF_SCRIPT_PHASE_ID, _script_phase_object())
            fixed.append("阶段脚本内容")
    target = _pbx_block(text, XCF_RUNNER_TARGET_ID)
    line = _script_phase_list_line()
    if XCF_SCRIPT_PHASE_ID not in target:
        embed_line = "\t\t\t\t%s /* Embed Frameworks */,\n" % XCF_EMBED_PHASE_ID
        if text.count(embed_line) != 1:
            raise SystemExit("pbxproj Embed Frameworks 列表行不唯一或缺失，拒绝手术")
        text = text.replace(embed_line, line + embed_line, 1)
        fixed.append("目标阶段列表条目")
    else:
        target = _pbx_block(text, XCF_RUNNER_TARGET_ID)
        order = [target.find(XCF_RESOURCES_PHASE_ID),
                 target.find(XCF_SCRIPT_PHASE_ID),
                 target.find(XCF_EMBED_PHASE_ID)]
        if min(order) < 0 or not (order[0] < order[1] < order[2]):
            if text.count(line) != 1:
                raise SystemExit("pbxproj 脚本阶段列表行不唯一或缺失，拒绝手术")
            text = text.replace(line, "", 1)
            embed_line = "\t\t\t\t%s /* Embed Frameworks */,\n" % XCF_EMBED_PHASE_ID
            if text.count(embed_line) != 1:
                raise SystemExit("pbxproj Embed Frameworks 列表行不唯一或缺失，拒绝手术")
            text = text.replace(embed_line, line + embed_line, 1)
            fixed.append("阶段顺序")
    return text, fixed


def _pbx_wiring_missing(text):
    missing = []
    if XCF_FILE_REF_ID not in text:
        missing.append("PBXFileReference")
    if XCF_LINK_BUILD_ID not in text:
        missing.append("Frameworks 的 PBXBuildFile")
    if XCF_EMBED_BUILD_ID not in text:
        missing.append("Embed 的 PBXBuildFile")
    if XCF_FILE_REF_ID not in _pbx_block(text, XCF_MAIN_GROUP_ID):
        missing.append("主 group 子项")
    if XCF_LINK_BUILD_ID not in _pbx_block(text, XCF_FRAMEWORKS_PHASE_ID):
        missing.append("Runner Frameworks 阶段条目")
    if XCF_EMBED_BUILD_ID not in _pbx_block(text, XCF_EMBED_PHASE_ID):
        missing.append("Runner Embed Frameworks 阶段条目")
    return missing


def wire_python_into_xcode_project():
    """把 Python.xcframework 正经挂进 Runner 工程（定版修法）。

    五轮构建实证：podspec 的 user_target_xcconfig 只有 `-framework Python`
    没有搜索路径，链接期报 Framework 'Python' not found。按 BeeWare 模板
    的挂法在 App 工程里加文件引用 + Frameworks 链接条目 + Embed
    Frameworks 内嵌条目（动态框架不内嵌装上也闪退），再加一个
    “Process Python libraries”Run Script 阶段（Resources 之后、Embed
    之前），构建期调用 utils.sh 的 install_python。手术按条目粒度
    幂等：对象 ID 由固定种子 md5 派生、稳定可复现，缺哪条补哪条。
    """
    if not PBXPROJ_PATH.is_file():
        raise SystemExit("未找到 Xcode 工程文件：%s" % PBXPROJ_PATH)
    text = PBXPROJ_PATH.read_text(encoding="utf-8")
    for object_id, isa in ((XCF_MAIN_GROUP_ID, "PBXGroup"),
                           (XCF_FRAMEWORKS_PHASE_ID, "PBXFrameworksBuildPhase"),
                           (XCF_EMBED_PHASE_ID, "PBXCopyFilesBuildPhase"),
                           (XCF_RUNNER_TARGET_ID, "PBXNativeTarget"),
                           (XCF_RESOURCES_PHASE_ID, "PBXResourcesBuildPhase")):
        if isa not in _pbx_block(text, object_id):
            raise SystemExit("pbxproj 锚点对象 %s 不是 %s，拒绝手术" % (object_id, isa))
    if "name = Runner;" not in _pbx_block(text, XCF_RUNNER_TARGET_ID):
        raise SystemExit("pbxproj Runner 目标锚点名称不符，拒绝手术")
    missing_before = _pbx_wiring_missing(text) + _pbx_script_phase_missing(text)
    if not missing_before:
        print("Xcode 工程已挂接 Python.xcframework（含处理阶段），无变化")
        return
    if XCF_FILE_REF_ID not in text:
        text = _pbx_insert_before_marker(
            text, "/* End PBXFileReference section */",
            "\t\t%s /* Python.xcframework */ = {isa = PBXFileReference; "
            "lastKnownFileType = wrapper.xcframework; "
            "path = Frameworks/Python.xcframework; sourceTree = \"<group>\"; };\n"
            % XCF_FILE_REF_ID)
    if XCF_LINK_BUILD_ID not in text:
        text = _pbx_insert_before_marker(
            text, "/* End PBXBuildFile section */",
            "\t\t%s /* Python.xcframework in Frameworks */ = {isa = PBXBuildFile; "
            "fileRef = %s /* Python.xcframework */; };\n"
            % (XCF_LINK_BUILD_ID, XCF_FILE_REF_ID))
    if XCF_EMBED_BUILD_ID not in text:
        text = _pbx_insert_before_marker(
            text, "/* End PBXBuildFile section */",
            "\t\t%s /* Python.xcframework in Embed Frameworks */ = {isa = PBXBuildFile; "
            "fileRef = %s /* Python.xcframework */; "
            "settings = {ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }; };\n"
            % (XCF_EMBED_BUILD_ID, XCF_FILE_REF_ID))
    if XCF_FILE_REF_ID not in _pbx_block(text, XCF_MAIN_GROUP_ID):
        text = _pbx_insert_into_list(
            text, XCF_MAIN_GROUP_ID, "children",
            "\t\t\t\t%s /* Python.xcframework */,\n" % XCF_FILE_REF_ID)
    if XCF_LINK_BUILD_ID not in _pbx_block(text, XCF_FRAMEWORKS_PHASE_ID):
        text = _pbx_insert_into_list(
            text, XCF_FRAMEWORKS_PHASE_ID, "files",
            "\t\t\t\t%s /* Python.xcframework in Frameworks */,\n" % XCF_LINK_BUILD_ID)
    if XCF_EMBED_BUILD_ID not in _pbx_block(text, XCF_EMBED_PHASE_ID):
        text = _pbx_insert_into_list(
            text, XCF_EMBED_PHASE_ID, "files",
            "\t\t\t\t%s /* Python.xcframework in Embed Frameworks */,\n" % XCF_EMBED_BUILD_ID)
    text, script_fixed = _pbx_ensure_script_phase(text)
    PBXPROJ_PATH.write_text(text, encoding="utf-8")
    after = PBXPROJ_PATH.read_text(encoding="utf-8")
    missing_after = _pbx_wiring_missing(after) + _pbx_script_phase_missing(after)
    if missing_after:
        raise SystemExit("pbxproj 手术后仍缺：%s" % ", ".join(missing_after))
    print("Xcode 工程已挂接 Python.xcframework（补齐：%s）" % ", ".join(missing_before))


def verify_project_wiring():
    if not PBXPROJ_PATH.is_file():
        raise SystemExit("未找到 Xcode 工程文件：%s" % PBXPROJ_PATH)
    text = PBXPROJ_PATH.read_text(encoding="utf-8")
    missing = _pbx_wiring_missing(text) + _pbx_script_phase_missing(text)
    if missing:
        raise SystemExit("Xcode 工程未挂接 Python.xcframework（缺：%s），请先跑本脚本（不带 --check）"
                         % ", ".join(missing))
    print("校验通过：Xcode 工程已挂接 Python.xcframework（引用/链接/内嵌/处理阶段齐全）")


def sync_host_script():
    if not HOST_SOURCE.is_file():
        raise SystemExit("宿主脚本真源不存在：%s" % HOST_SOURCE)
    HOST_DEST.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(HOST_SOURCE, HOST_DEST)
    if sha256_of(HOST_SOURCE) != sha256_of(HOST_DEST):
        raise SystemExit("宿主脚本同步后哈希不一致：%s" % HOST_DEST)
    print("宿主脚本已同步（逐字一致，sha256=%s）：%s -> %s"
          % (sha256_of(HOST_DEST), HOST_SOURCE, HOST_DEST))


def verify_vendor_bundle():
    missing = [name for name in VENDOR_REQUIRED_FILES
               if not (VENDOR_BUNDLE_DIR / name).is_file()]
    if missing:
        raise SystemExit("requests 兼容包缺文件：%s" % ", ".join(missing))
    natives = [str(path) for path in VENDOR_BUNDLE_DIR.rglob("*.so")]
    if natives:
        raise SystemExit("requests 兼容包混入本机扩展（iOS 无法加载）：%s" % ", ".join(natives))
    print("校验通过：requests 兼容包齐全（%s）" % ", ".join(
        "%s==%s" % (package[0], package[1]) for package in VENDOR_PACKAGES))


def vendor_requests():
    if VENDOR_BUNDLE_DIR.exists():
        shutil.rmtree(VENDOR_BUNDLE_DIR)
    with tempfile.TemporaryDirectory() as temporary:
        download_dir = Path(temporary) / "wheels"
        download_dir.mkdir()
        for name, version, _dirname in VENDOR_PACKAGES:
            spec = "%s==%s" % (name, version)
            result = subprocess.run(
                [sys.executable, "-m", "pip", "download", "--quiet",
                 "--disable-pip-version-check", "--no-deps",
                 "--only-binary=:all:", "--platform", "any",
                 "--python-version", "313", "--abi", "none",
                 "--dest", str(download_dir), spec],
                capture_output=True, text=True)
            if result.returncode != 0:
                raise SystemExit("下载 %s 失败：%s" % (spec, result.stderr.strip()))
        wheels = sorted(download_dir.glob("*.whl"))
        if len(wheels) != len(VENDOR_PACKAGES):
            raise SystemExit("下载到的 wheel 数量不对：%d（期望 %d）"
                             % (len(wheels), len(VENDOR_PACKAGES)))
        staging = Path(temporary) / "unpacked"
        for wheel in wheels:
            with zipfile.ZipFile(wheel) as archive:
                archive.extractall(staging)
        VENDOR_BUNDLE_DIR.mkdir(parents=True)
        for _name, _version, dirname in VENDOR_PACKAGES:
            package_dir = staging / dirname
            package_file = staging / (dirname + ".py")
            if package_dir.is_dir():
                shutil.copytree(package_dir, VENDOR_BUNDLE_DIR / dirname)
            elif package_file.is_file():
                shutil.copy2(package_file, VENDOR_BUNDLE_DIR / package_file.name)
            else:
                raise SystemExit("wheel 内未找到包：%s" % dirname)
    verify_vendor_bundle()


def main():
    parser = argparse.ArgumentParser(description="准备 iOS 嵌入式 CPython 与宿主脚本")
    parser.add_argument("--check", action="store_true",
                        help="只校验 ios/Frameworks/Python.xcframework 与宿主脚本同步状态")
    parser.add_argument("--sync-only", action="store_true",
                        help="只同步宿主脚本（可在 Linux 上跑）")
    options = parser.parse_args()

    if options.sync_only:
        sync_host_script()
        return
    if options.check:
        validate_xcframework(XCFRAMEWORK_DIR)
        if not HOST_DEST.is_file() or sha256_of(HOST_SOURCE) != sha256_of(HOST_DEST):
            raise SystemExit("宿主脚本未同步或与真源不一致，请先跑本脚本（不带 --check）")
        verify_project_wiring()
        verify_vendor_bundle()
        print("校验通过：XCFramework 结构、宿主脚本同步状态与 requests 兼容包正常")
        return
    archive = CACHE_DIR / SUPPORT_ASSET
    if archive.is_file() and sha256_of(archive) == EXPECTED_SHA256:
        print("复用已下载发布包：%s（sha256=%s）" % (archive, sha256_of(archive)))
    else:
        if archive.is_file():
            print("缓存发布包哈希不符，重新下载：%s" % archive)
            archive.unlink()
        download(SUPPORT_URLS, archive)
    extract_support_package(archive)
    wire_python_into_xcode_project()
    sync_host_script()
    vendor_requests()


if __name__ == "__main__":
    main()
