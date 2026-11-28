# -*- coding: utf-8 -*-
"""校验 lib/ 与 test/ 里所有相对 import 的目标文件是否存在。

为什么需要：相对路径少写一层（`../x.dart` 应为 `../../x.dart`）或同目录
文件名写错，编译器会直接拒掉，但本地没有 Dart 工具链时完全看不见，只能
等 CI 跑到 `flutter build` 才发现。纯文本校验能在提交前拦住。

用法：
    python scripts/audit_imports.py
退出码：0 全部存在，1 有错误。
"""
import os
import re
import sys
from pathlib import Path

# 仓库根目录：不写死绝对路径，便于在 CI 与其他机器上运行。
ROOT = Path(__file__).resolve().parents[1]

IMPORT = re.compile(r"""^\s*(?:import|export)\s+['"]([^'"]+)['"]""", re.M)


def check_dir(base):
    """返回 [(文件, 行号, 导入目标, 解析后的绝对路径)]。"""
    problems = []
    for dirpath, _dirs, files in os.walk(str(base)):
        for name in files:
            if not name.endswith('.dart'):
                continue
            path = Path(dirpath) / name
            try:
                text = path.read_text(encoding='utf-8')
            except OSError:
                continue
            for match in IMPORT.finditer(text):
                target = match.group(1)
                # dart: 与 package: 交给 pub 解析。
                if target.startswith('dart:') or target.startswith('package:'):
                    continue
                # 以 / 开头的是绝对路径，不是本项目写法。
                if target.startswith('/'):
                    continue
                # 同目录导入（`'focus_ring.dart'`）同样是相对导入，也要校验。
                resolved = (path.parent / target).resolve()
                if not resolved.is_file():
                    line = text[: match.start()].count('\n') + 1
                    problems.append((path, line, target, resolved))
    return problems


def main():
    problems = []
    for sub in ('lib', 'test'):
        base = ROOT / sub
        if base.is_dir():
            problems.extend(check_dir(base))

    if not problems:
        print('所有相对 import 目标都存在。')
        return 0

    print('发现 %d 处导入路径错误：' % len(problems))
    for path, line, target, resolved in sorted(problems):
        print('')
        print('%s:%d' % (path.relative_to(ROOT), line))
        print('  import %r' % target)
        try:
            print('  解析为：%s（不存在）' % resolved.relative_to(ROOT))
        except ValueError:
            print('  解析为：%s（不存在）' % resolved)
    return 1


if __name__ == '__main__':
    sys.exit(main())
