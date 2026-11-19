"""校验每个出包平台都会内置站源模块。

用法：
    python scripts/check_bundled_platforms.py

退出码 0 表示全部平台都接入了 modules/，非 0 表示有平台漏掉。
"""

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'scripts'

# 每个出包平台都必须把仓库 modules/ 内置进二进制。App 端（Android、Windows、
# iOS、macOS）走 build_native.py 或直接调用 prepare_bundled_modules，本地服务版
# 曾经漏掉这一句，构建出的包一个站源都没有。
PLATFORM_SCRIPTS = {
    'android': 'build_android.py',
    'windows': 'build_windows.py',
    'ios': 'build_ios.py',
    'macos': 'build_macos.py',
    'webserver': 'build_web.py',
}


def script_calls_prepare(name):
    text = (SCRIPTS / name).read_text(encoding='utf-8')
    if 'prepare_bundled_modules' in text:
        return True
    # Android / Windows / macOS 通过 build_native.py 间接调用。
    return 'build_native.py' in text


class PlatformBundledModulesTest(unittest.TestCase):
    def test_every_platform_bundles_modules(self):
        missing = [platform for platform, script in PLATFORM_SCRIPTS.items()
                   if not script_calls_prepare(script)]
        self.assertEqual(missing, [], '这些平台没有内置站源模块：' + '、'.join(missing))

    def test_build_native_bundles_modules(self):
        text = (SCRIPTS / 'build_native.py').read_text(encoding='utf-8')
        self.assertIn('prepare_bundled_modules', text)

    def test_build_web_imports_prepare(self):
        text = (SCRIPTS / 'build_web.py').read_text(encoding='utf-8')
        self.assertIn('from app_build import app, prepare_bundled_modules', text)
        self.assertIn('prepare_bundled_modules()', text)

    def test_repository_modules_exist(self):
        modules = ROOT / 'modules'
        self.assertTrue(modules.is_dir(), '仓库缺少 modules/ 目录')
        ids = sorted(p.name for p in modules.iterdir() if p.is_dir())
        self.assertGreater(len(ids), 0, 'modules/ 下没有任何模块')
        self.assertNotIn('missav', ids, 'missav 不应内置')
        self.assertIn('guipian', ids, '鬼片应内置')


if __name__ == '__main__':
    unittest.main(verbosity=2)
