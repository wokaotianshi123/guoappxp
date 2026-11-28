import argparse
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path

from app_build import app

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--abi', action='append', choices=['arm64-v8a', 'armeabi-v7a', 'x86_64'])
options = parser.parse_args()
env = os.environ.copy()
if platform.system() == 'Darwin':
    env['LANG'] = 'en_US.UTF-8'
    env['LC_ALL'] = 'en_US.UTF-8'
env.setdefault('GOPROXY', 'https://goproxy.cn,direct')
env.setdefault('GOSUMDB', 'off')
flutter = shutil.which('flutter')
if not flutter:
    raise SystemExit('请先将 Flutter SDK 的 bin 目录加入 PATH。')
abi_args = [item for abi in options.abi or [] for item in ['--abi', abi]]
subprocess.run([sys.executable, str(root / 'scripts' / 'build_native.py'), '--platform', 'android', *abi_args],
               cwd=root, env=env, check=True)
subprocess.run([flutter, 'pub', 'get'], cwd=root, env=env, check=True)
# Chaquopy 要求 abiFilters，AGP 又不允许它和 --split-per-abi 共存；
# 改成每个 ABI 一个 flavor，分别构建（与 android/app/build.gradle.kts 对应）。
#
# 还必须关掉 Flutter 自己写入的默认 abiFilters（3.35 起会往 defaultConfig 塞
# armeabi-v7a + arm64-v8a + x86_64）。AGP 会把 defaultConfig 与 flavor 的过滤
# 集合取并集，于是「单 ABI flavor」的包里会出现别的 ABI 的 libpython3.11.so：
# 64 位机器据此按 arm64 启动，却找不到 arm64 的 libflutter.so，ReLinker 退回
# 从包里解出 32 位那份，报 libflutter.so is 32-bit instead of 64-bit 直接闪退。
# 官方给的开关就是 -Pdisable-abi-filtering=true。
flavors = {'arm64-v8a': 'arm64', 'armeabi-v7a': 'arm', 'x86_64': 'x64'}
targets = {'arm64-v8a': 'android-arm64', 'armeabi-v7a': 'android-arm', 'x86_64': 'android-x64'}
for abi in options.abi or ['arm64-v8a', 'armeabi-v7a', 'x86_64']:
    build_args = [
        flutter, 'build', 'apk', '--release', '--flavor', flavors[abi],
        '--no-pub', '--target-platform', targets[abi],
        '--android-project-arg=disable-abi-filtering=true', *app.flutter_arguments,
    ]
    subprocess.run(build_args, cwd=root, env=env, check=True)
subprocess.run([sys.executable, str(root / 'scripts' / 'package_release.py'), '--platform', 'android', *abi_args],
               cwd=root, env=env, check=True)
