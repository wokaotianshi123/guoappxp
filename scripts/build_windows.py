import argparse
import filecmp
import os
import shutil
import subprocess
import sys
from pathlib import Path

from app_build import app

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--refresh-python', action='store_true',
                    help='强制重新下载并安装内置 CPython（默认在已就绪时跳过）')
options = parser.parse_args()
env = os.environ.copy()
env.setdefault('GOPROXY', 'https://goproxy.cn,direct')
env.setdefault('GOSUMDB', 'off')
flutter = shutil.which('flutter')
if not flutter:
    raise SystemExit('请先将 Flutter SDK 的 bin 目录加入 PATH。')


def python_ready():
    """内置 CPython 已就绪、依赖齐全，且宿主脚本是最新的，就不必重新下载几十 MB。"""
    runtime = root / 'windows' / 'runner' / 'python'
    executable = runtime / 'python.exe'
    host = runtime / 'py_spider_host.py'
    source = root / 'android' / 'app' / 'src' / 'main' / 'python' / 'py_spider_host.py'
    if not executable.is_file() or not host.is_file() or not source.is_file():
        return False
    site = runtime / 'Lib' / 'site-packages'
    for package in ('requests', 'bs4', 'lxml', 'pyquery', 'Crypto'):
        if not (site / package).is_dir():
            return False
    return filecmp.cmp(host, source, shallow=False)


if options.refresh_python or not python_ready():
    # PY 沙箱：Windows 侧靠 exe 旁的内置 CPython 跑蜘蛛。
    # 之前漏了这一步，CMake 的 if(EXISTS) 直接跳过，装完打开就是
    # 「Python 运行时不可用」。
    subprocess.run([sys.executable, str(root / 'scripts' / 'prepare_windows_python.py')],
                   cwd=root, env=env, check=True)
else:
    print('内置 CPython 已就绪，跳过下载（需要重装时加 --refresh-python）')

subprocess.run([sys.executable, str(root / 'scripts' / 'build_native.py'), '--platform', 'windows'],
               cwd=root, env=env, check=True)
subprocess.run([flutter, 'pub', 'get', '--enforce-lockfile'], cwd=root, env=env, check=True)
subprocess.run([flutter, 'build', 'windows', '--release', '--no-pub', *app.flutter_arguments], cwd=root, env=env, check=True)
subprocess.run([sys.executable, str(root / 'scripts' / 'package_release.py'), '--platform', 'windows'],
               cwd=root, env=env, check=True)
