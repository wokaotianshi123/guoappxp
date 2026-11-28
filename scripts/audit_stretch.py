# -*- coding: utf-8 -*-
"""找出 CrossAxisAlignment.stretch 用在无界交叉轴上的隐患。

原理（Flutter 的 RenderFlex）：
* Row 的交叉轴是**垂直**方向。若父级给的高度无界，stretch 会要求子项高度
  等于 infinity，触发布局断言，整块子树被丢弃（表现为界面空白）。
* Column 的交叉轴是**水平**方向。若父级给的宽度无界，同理。

哪些父级会造成无界？
* Column（作为 Row 的直接父级）：Column 给非 flex 子项传 maxHeight = infinity。
* Row（作为 Column 的直接父级）：同理传 maxWidth = infinity。
* 垂直滚动容器（ListView / SingleChildScrollView / CustomScrollView /
  GridView）：高度无界。
* 横向滚动容器（ListView.horizontal / PageView 默认横向 / SingleChildScrollView
  .horizontal）：宽度无界。

注意：中间若隔了 SizedBox / Expanded / Flexible / Container(height:) 等会把
尺寸收紧的组件，就不再是无界。所以只看**直接父级**，跨过这些就安全。

为什么不用「一路向上找滚动容器」：那需要跨函数边界（Row 在一个方法里、
ListView 在另一个方法里），纯文本分析做不到，会漏报。
"""
import io
import os
import re
import sys
from pathlib import Path

# 仓库根目录下的 lib/：不写死绝对路径，便于在 CI 与其他机器上运行。
ROOT = str(Path(__file__).resolve().parents[1] / 'lib')

VERTICAL_SCROLLERS = (
    'ListView', 'SingleChildScrollView', 'CustomScrollView', 'GridView',
    'ReorderableListView',
)
HORIZONTAL_SCROLLERS = ('ListView', 'SingleChildScrollView', 'PageView', 'GridView')

# 只做包装、不改变可用尺寸的组件：判断「直接父级」时要穿过它们。
_PASS_THROUGH = {
    'Padding', 'ExcludeSemantics', 'Semantics', 'SafeArea', 'Material', 'Theme',
    'DefaultTextStyle', 'GestureDetector', 'InkWell', 'Builder', 'AnimatedContainer',
    'ClipRect', 'ClipRRect', 'DecoratedBox', 'ColoredBox', 'Opacity',
    'AnimatedOpacity', 'AnimatedPadding', 'KeyedSubtree', 'RepaintBoundary',
    'Focus', 'MouseRegion', 'Tooltip', 'Visibility', 'AnimatedSwitcher',
    'FadeTransition', 'MediaQuery', 'Directionality', 'ListenableBuilder',
    'ValueListenableBuilder', 'AnimatedBuilder', 'InheritedTheme',
}


def match_paren(text, open_index):
    depth = 0
    i = open_index
    quote = None
    while i < len(text):
        ch = text[i]
        if quote:
            if ch == '\\':
                i += 2
                continue
            if ch == quote:
                quote = None
        elif ch in ('"', "'"):
            quote = ch
        elif ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def paren_pairs(text):
    """一次扫描算出所有括号的配对位置：{开括号下标: 闭括号下标}。

    逐个调用 `match_paren` 是 O(n²)：198 个文件里每个 `Xxx(` 都要从头扫
    一遍，大文件上会跑到内存溢出。这里用栈一次扫完，整体 O(n)。
    字符串与注释里的括号同样跳过，避免把 `Text('(')` 当成真括号。
    """
    pairs = {}
    stack = []
    i = 0
    length = len(text)
    quote = None
    while i < length:
        ch = text[i]
        if quote:
            if ch == '\\':
                i += 2
                continue
            if ch == quote:
                quote = None
            i += 1
            continue
        if ch == '/' and i + 1 < length and text[i + 1] == '/':
            newline = text.find('\n', i)
            i = length if newline < 0 else newline
            continue
        if ch == '/' and i + 1 < length and text[i + 1] == '*':
            end = text.find('*/', i + 2)
            i = length if end < 0 else end + 2
            continue
        if ch in ('"', "'"):
            quote = ch
        elif ch == '(':
            stack.append(i)
        elif ch == ')':
            if stack:
                pairs[stack.pop()] = i
        i += 1
    return pairs


_CALL_CACHE = {}


def all_calls(text, key=None):
    """返回 [(name, name_start, open_index, close_index)]，带缓存。

    [key] 必须能唯一标识这份文本（这里传文件路径）。**不能用 `id(text)`**：
    CPython 里字符串被回收后地址会复用，198 个文件里有近 50 对撞号，
    缓存会串到别的文件上，既误报（报出别人的行号）又漏报（本文件的
    结果被别人的覆盖）。
    """
    if key is not None and key in _CALL_CACHE:
        return _CALL_CACHE[key]
    pairs = paren_pairs(text)
    calls = []
    for match in re.finditer(r'(?<![A-Za-z0-9_.])([A-Z][A-Za-z0-9_]*)\s*\(', text):
        name = match.group(1)
        open_index = match.end() - 1
        close = pairs.get(open_index, -1)
        if close > 0:
            calls.append((name, match.start(), open_index, close))
    if key is not None:
        _CALL_CACHE[key] = calls
    return calls


def immediate_parent(text, position, key=None):
    """找包住 position 的最内层大写开头调用（即直接父 widget）。"""
    best = None
    for name, start, open_index, close in all_calls(text, key):
        if open_index < position < close:
            span = close - open_index
            if best is None or span < best[3]:
                best = (name, start, open_index, span)
    return best


def scroll_axis(name, body):
    """滚动容器的滚动方向。"""
    head = body[:400]
    if 'scrollDirection: Axis.horizontal' in head:
        return 'horizontal'
    if 'scrollDirection: Axis.vertical' in head:
        return 'vertical'
    if name == 'PageView':
        return 'horizontal'  # PageView 默认横向
    return 'vertical'


def flex_axis(name, body):
    head = body[:300]
    if 'direction: Axis.horizontal' in head:
        return 'horizontal'
    if 'direction: Axis.vertical' in head:
        return 'vertical'
    return 'vertical' if name == 'Column' else 'horizontal'


def analyse(path):
    text = io.open(path, encoding='utf-8').read()
    findings = []
    for name, start, open_index, close in all_calls(text, path):
        if name not in ('Row', 'Column'):
            continue
        body = text[open_index:close]
        # 只看该调用自身的构造参数（crossAxisAlignment 写在最前面）
        head = body[:400]
        if 'CrossAxisAlignment.stretch' not in head:
            continue
        line = text[:start].count('\n') + 1
        parent = immediate_parent(text, start, path)
        if parent is None:
            continue
        pname, pstart, popen, _span = parent
        pbody = text[popen:match_paren(text, popen) + 1]
        phead = pbody[:400]

        # 父级若把尺寸收紧（SizedBox / Expanded / Container 带 height 等），安全
        if pname in ('SizedBox', 'Expanded', 'Flexible', 'Container', 'ConstrainedBox',
                     'AspectRatio', 'IntrinsicHeight', 'IntrinsicWidth'):
            continue

        # 透明包装（只加 padding / 语义 / 主题 / 手势）：尺寸由更外层决定，
        # 往上再找一层真正的布局父级。以前这里直接放弃，`Padding > Row`
        # 这类会被漏报。
        wrapper = pname
        depth = 0
        while wrapper in _PASS_THROUGH and depth < 8:
            outer = immediate_parent(text, pstart, path)
            if outer is None:
                break
            wrapper, pstart, popen, _span = outer
            pbody = text[popen:match_paren(text, popen) + 1]
            phead = pbody[:400]
            depth += 1
            if wrapper in ('SizedBox', 'Expanded', 'Flexible', 'Container',
                           'ConstrainedBox', 'AspectRatio', 'IntrinsicHeight',
                           'IntrinsicWidth'):
                break
        pname = wrapper

        if pname in ('SizedBox', 'Expanded', 'Flexible', 'Container', 'ConstrainedBox',
                     'AspectRatio', 'IntrinsicHeight', 'IntrinsicWidth'):
            continue

        problem = ''
        if name == 'Row':
            # Row 交叉轴 = 垂直，需要父级给出有界高度
            if pname in ('Column', 'Flex') and flex_axis(pname, pbody) == 'vertical':
                problem = '父级是竖向 Column，给的高度无界'
            elif pname in VERTICAL_SCROLLERS and scroll_axis(pname, pbody) == 'vertical':
                problem = '父级是竖向滚动容器，高度无界'
        else:  # Column
            # Column 交叉轴 = 水平，需要父级给出有界宽度
            if pname in ('Row', 'Flex') and flex_axis(pname, pbody) == 'horizontal':
                problem = '父级是横向 Row，给的宽度无界'
            elif pname in HORIZONTAL_SCROLLERS and scroll_axis(pname, pbody) == 'horizontal':
                problem = '父级是横向滚动容器，宽度无界'

        if problem:
            findings.append((path, line, name, pname, problem))
    return findings


def main():
    findings = []
    for base, _dirs, files in os.walk(ROOT):
        for name in files:
            if name.endswith('.dart'):
                findings.extend(analyse(os.path.join(base, name)))

    if not findings:
        print('未发现 stretch 用在无界交叉轴上的情况。')
        return 0

    print('发现 %d 处可疑：' % len(findings))
    for path, line, widget, pname, problem in sorted(findings):
        print('')
        print('%s:%d' % (path.replace(ROOT, ''), line))
        print('  %s + CrossAxisAlignment.stretch' % widget)
        print('  直接父级：%s —— %s' % (pname, problem))
    return 1


if __name__ == '__main__':
    sys.exit(main())
