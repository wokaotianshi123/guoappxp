"""本地 Web 服务版冒烟自检：把编出来的二进制真的跑起来，逐个打接口。

`scripts/build_web.py` 只保证「能编过 + 打进 zip」，编出来能不能用没人验过。
这个脚本补上那一步，在发布前抓这几类问题：

- 二进制起不来，或者端口上根本不是本服务；
- `go:embed` 的网页资源没跟着更新（和仓库里的 `native/server/web` 对不上）；
- 站源裁剪（`-X duanjuapp/native/core.buildAllSources`）没生效，
  红果鉴里冒出别的站源，或者真果鉴只剩红果；
- 接口不返回 JSON、返回 500，或者非法请求把进程打挂。

用法：

    python scripts/check_web.py                      # 自动找 build/web/*/*-linux
    python scripts/check_web.py --binary native/server.exe --slug hongguojian

退出码非 0 表示有检查项失败，CI 里直接让 web job 红掉。
"""

import argparse
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

root = Path(__file__).resolve().parents[1]
web_dir = root / 'native' / 'server' / 'web'

parser = argparse.ArgumentParser(description='本地 Web 服务版冒烟自检')
parser.add_argument('--binary', action='append', default=[],
                    help='要检查的可执行文件，可重复；默认自动找 build/web/*/*-linux')
parser.add_argument('--slug', help='该二进制的版本标识（hongguojian / zhenguojian），'
                    '只在只有一个 --binary 时用得上；不传则读 /api/info')
parser.add_argument('--timeout', type=float, default=40.0, help='等待服务起来的秒数')
options = parser.parse_args()

slugs = {'hongguojian': '红果鉴', 'zhenguojian': '真果鉴'}

# 局域网里挂着代理时 urllib 会绕去代理，本机自检必须直连。
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(('127.0.0.1', 0))
        return probe.getsockname()[1]


def guess_slug(binary):
    name = binary.name.lower()
    for slug in slugs:
        if slug in name:
            return slug
    if 'hongguojian' in str(binary).lower():
        return 'hongguojian'
    return None


def http(port, path, body=None, method=None):
    """返回 (状态码, 字节内容)；连接失败原样抛出，由调用方判时间。"""
    url = 'http://127.0.0.1:' + str(port) + path
    data = None
    if body is not None:
        data = json.dumps(body).encode('utf-8')
    request = urllib.request.Request(url, data=data, method=method or ('POST' if data else 'GET'))
    if data is not None:
        request.add_header('Content-Type', 'application/json')
    try:
        with opener.open(request, timeout=15) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


def wait_ready(port, proc, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if proc.poll() is not None:
            return False
        try:
            status, _ = http(port, '/api/info')
            if status == 200:
                return True
        except OSError:
            pass
        time.sleep(0.2)
    return False


class Failure(Exception):
    pass


def check(condition, message):
    if not condition:
        raise Failure(message)


def run_case(binary, slug_hint):
    port = free_port()
    with tempfile.TemporaryDirectory(prefix='duanju-check-') as data_dir:
        command = [str(binary), '-host', '127.0.0.1', '-port', str(port), '-data', data_dir]
        proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, encoding='utf-8', errors='replace')

        def stop():
            """先收掉进程再读它的输出：进程还活着时 read() 会一直等 EOF。"""
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=5)
            try:
                return proc.stdout.read() or ''
            except ValueError:
                return ''

        results = []
        try:
            check(wait_ready(port, proc, options.timeout),
                  '服务没有在 %s 秒内起来（端口 %d）' % (options.timeout, port))

            info_status, info_body = http(port, '/api/info')
            check(info_status == 200, '/api/info 返回 %d' % info_status)
            info = json.loads(info_body)
            check(info.get('slug') in slugs, '/api/info 的 slug 异常：%r' % info.get('slug'))
            check(info.get('name') == slugs[info['slug']],
                  '/api/info 的名称与 slug 不匹配：%r' % info.get('name'))
            check(int(info.get('port') or 0) == port,
                  '/api/info 回报的端口是 %r，应为 %d' % (info.get('port'), port))
            if slug_hint:
                check(info['slug'] == slug_hint,
                      '二进制是 %s 版本，实际跑出来是 %s' % (slug_hint, info['slug']))
            slug = info['slug']
            results.append('版本 %s（%s）' % (info['name'], slug))

            # 根路径要跳到 /web/，否则浏览器打开就是 404。
            status = 0
            try:
                status, _ = http(port, '/')
            except urllib.error.HTTPError:
                pass
            check(status in (200, 301, 302, 303, 307, 308), '/ 返回 %d，没有跳转到 /web/' % status)

            status, page = http(port, '/web/')
            check(status == 200, '/web/ 返回 %d' % status)
            check(b'id="view"' in page, '/web/ 不是本地服务版的页面（找不到 id="view"）')
            results.append('主页 %d 字节' % len(page))

            # 内嵌资源和仓库里的文件必须逐字节一致：改了前端却忘了重新编译时，
            # 这里就是唯一能发现的地方（浏览器看到的是旧页面）。
            for name in sorted(os.listdir(web_dir)):
                local = web_dir / name
                if not local.is_file():
                    continue
                status, served = http(port, '/web/' + name)
                check(status == 200, '/web/%s 返回 %d' % (name, status))
                local_bytes = local.read_bytes()
                check(served == local_bytes,
                      '/web/%s 与仓库里的文件不一致（内嵌资源是旧版本，需要重新编译）' % name)
            results.append('内嵌网页 %d 个文件与仓库一致' % len(os.listdir(web_dir)))

            status, body = http(port, '/api/sources')
            check(status == 200, '/api/sources 返回 %d' % status)
            sources = json.loads(body).get('items') or []
            ids = [item.get('id') for item in sources]
            check(ids, '/api/sources 一个站源都没有')
            if slug == 'hongguojian':
                # 红果鉴 = 红果 + 番茄：红果是主站源，番茄是内置源（目录/详情/取流由本机
                # 番茄内容引擎承担），两者都与 buildAllSources 无关，裁剪版必须都带着。
                check(set(ids) == {'hongguo', 'fanqie'},
                      '红果鉴只该有红果 / 番茄两个站源，实际是 %r（-X buildAllSources 没生效？）' % ids)
            else:
                check(len(ids) >= 10,
                      '真果鉴的站源只有 %d 个（%r），不像全站源版本' % (len(ids), ids))
            results.append('站源 %d 个：%s' % (len(ids), '、'.join(str(i) for i in ids[:5])
                                          + ('…' if len(ids) > 5 else '')))

            for path in ('/api/source-visibility', '/api/library'):
                status, body = http(port, path)
                check(status == 200, '%s 返回 %d' % (path, status))
                json.loads(body)
                results.append('%s 正常' % path)

            # 未知站源必须被拒，不能悄悄返回一个空列表——前端据此判断「版本不包含此站源」。
            status, body = http(port, '/api/request', {'action': 'categories', 'source': '__check__'})
            check(status == 200, '/api/request 返回 %d' % status)
            reply = json.loads(body)
            check(reply.get('ok') is False, '未知站源没有被拒绝：%r' % reply)
            results.append('未知站源被拒：%s' % reply.get('error'))

            if slug == 'hongguojian':
                status, body = http(port, '/api/request', {'action': 'categories', 'source': 'ikanbot'})
                reply = json.loads(body)
                check(reply.get('ok') is False, '红果鉴不该能用爱看机器人：%r' % reply)
                check('不包含' in (reply.get('error') or ''),
                      '红果鉴拒绝其它站源的提示异常：%r' % reply.get('error'))
                results.append('裁剪版拒绝非红果站源')

            # GET 打 POST 接口要 405，而不是 500。
            status, _ = http(port, '/api/request', method='GET')
            check(status == 405, 'GET /api/request 返回 %d，应为 405' % status)

            # 非法请求不能把进程打挂。
            status, _ = http(port, '/api/play', {'action': 'resolve', 'source': '__check__'})
            check(status < 500, '/api/play 非法请求返回 %d' % status)
            check(proc.poll() is None, '非法请求之后进程已经退出')
            status, _ = http(port, '/api/info')
            check(status == 200, '非法请求之后服务不再响应')
            results.append('非法请求不影响服务')

        except Failure as error:
            results.append('失败：' + str(error))
            output = stop()[-1500:].strip()
            if output:
                results.append('服务端输出末尾：\n' + output)
            return False, results
        finally:
            stop()
        return True, results


def discover():
    binaries = []
    for candidate in sorted((root / 'build' / 'web').glob('*/*-linux')):
        if is_engine_binary(candidate):
            continue
        binaries.append(candidate)
    return binaries


def discover_engines():
    """暂存目录里平铺着的各平台番茄引擎，这里只看本机能跑的那份。"""
    return sorted((root / 'build' / 'web').glob('*/fanqie_engine-linux'))


def is_engine_binary(path):
    """番茄引擎和版本主程序长得一样，但命令行完全不同。

    打包时引擎和主程序平铺在同一个目录，文件名叫 fanqie_engine-linux / -windows.exe
    之类，`*-linux` 这个通配会把它一起捞出来；再拿主程序的 -host/-port/-data
    去跑，引擎只会回一句「未知参数：-host」然后退出。所以这里必须分开认，
    引擎另走 run_engine_case 单独验。
    """
    return path.name.startswith('fanqie_engine')


def run_engine_case(binary):
    """引擎的轻量自检：确认这个二进制在本机真能执行、参数解析正常。

    真拉起来跑一次会去连上游、写设备池，慢且依赖外网，不适合当发布门禁；
    而「架构不对（Exec format error）」「缺动态库」「打包时丢了可执行位」
    这三类事故，一条 --help 就能抓住。
    """
    lines = ['番茄引擎 %s' % binary.name]
    if not os.access(str(binary), os.X_OK):
        lines.append('失败：文件没有可执行权限（解压后 start.sh 也拉不起来）')
        return False, lines
    try:
        proc = subprocess.run([str(binary), '--help'], stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, timeout=30, text=True,
                              encoding='utf-8', errors='replace')
    except OSError as error:
        lines.append('失败：引擎无法执行：%s' % error)
        return False, lines
    except subprocess.TimeoutExpired:
        lines.append('失败：--help 30 秒内没有返回')
        return False, lines
    output = (proc.stdout or '').strip()
    if proc.returncode != 0:
        lines.append('失败：--help 退出码 %d' % proc.returncode)
        if output:
            lines.append('输出末尾：\n' + output[-600:])
        return False, lines
    if 'fanqie_engine' not in output:
        lines.append('失败：--help 输出里没有 fanqie_engine，可能打进了别的文件：%r' % output[:200])
        return False, lines
    lines.append('引擎可执行（--help 正常）')
    return True, lines


requested = [Path(item) for item in options.binary]
binaries = ([item for item in requested if not is_engine_binary(item)]
            if requested else discover())
engines = ([item for item in requested if is_engine_binary(item)]
           if requested else discover_engines())
if not binaries and not engines:
    print('没有找到可检查的二进制：先跑 python scripts/build_web.py，'
          '或用 --binary 指定一个', file=sys.stderr)
    raise SystemExit(1)

failed = 0
for binary in binaries:
    if not binary.is_file():
        print('%s：文件不存在' % binary, file=sys.stderr)
        failed += 1
        continue
    hint = options.slug if len(binaries) == 1 and options.slug else guess_slug(binary)
    print('检查 %s …' % binary, flush=True)
    ok, lines = run_case(binary, hint)
    for line in lines:
        print('    ' + str(line), flush=True)
    print('    ' + ('通过' if ok else '未通过'), flush=True)
    if not ok:
        failed += 1

for engine in engines:
    print('检查 %s …' % engine, flush=True)
    ok, lines = run_engine_case(engine)
    for line in lines:
        print('    ' + str(line), flush=True)
    print('    ' + ('通过' if ok else '未通过'), flush=True)
    if not ok:
        failed += 1

print()
if failed:
    print('%d 项未通过自检。' % failed, file=sys.stderr)
    raise SystemExit(1)
print('全部通过：%d 个版本 + %d 个番茄引擎。' % (len(binaries), len(engines)))
