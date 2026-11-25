#!/usr/bin/env python3
"""给 TestFlight 构建写「更新说明」（What to Test）。

从 CHANGELOG.md 里取最新一段（第一个 `## ` 标题及其下的条目），转成
TestFlight 的纯文本格式，再用 App Store Connect API 写到对应构建上。

刚上传的构建要几十秒才在 API 里可见，所以这里会轮询等待；找不到就只提示，
不让整个发布流程失败（构建本身已经传上去了）。

用法：
    python scripts/set_testflight_notes.py
    python scripts/set_testflight_notes.py --build-number 133
    python scripts/set_testflight_notes.py --notes "自定义说明"
"""
import argparse
import json
import os
import ssl
import sys
import time
import urllib.request
from pathlib import Path

root = Path(__file__).resolve().parents[1]


def load_dependencies():
    """pyjwt / cryptography / certifi 只在 CI 用，缺失时自动装。"""
    try:
        import certifi
        import jwt
        return certifi, jwt
    except ImportError:
        import subprocess
        print('[说明] 正在安装 pyjwt / cryptography / certifi……', flush=True)
        subprocess.run([sys.executable, '-m', 'pip', 'install', '--quiet',
                        'pyjwt', 'cryptography', 'certifi'], check=True)
        import certifi
        import jwt
        return certifi, jwt


def secret(*names):
    for name in names:
        value = os.environ.get(name, '').strip()
        if value:
            return value
    return ''


def credentials():
    key_id = secret('APP_STORE_CONNECT_KEY_ID', 'KEY_ID')
    issuer = secret('APP_STORE_CONNECT_ISSUER_ID', 'ISSUER_ID')
    private = secret('APP_STORE_CONNECT_PRIVATE_KEY', 'PRIVATE_KEY_B64', 'API_KEY_P8')
    if not (key_id and issuer and private):
        return '', '', ''
    if 'BEGIN PRIVATE KEY' not in private:
        import base64
        try:
            private = base64.b64decode(''.join(private.split())).decode('utf-8')
        except Exception:
            return '', '', ''
    return key_id, issuer, private


def latest_notes():
    """取 CHANGELOG 最新一段，转成 TestFlight 能显示的纯文本。"""
    changelog = root / 'CHANGELOG.md'
    if not changelog.is_file():
        return ''
    lines = changelog.read_text(encoding='utf-8').splitlines()
    header = ''
    items = []
    inside = False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith('## '):
            if not inside:
                inside = True
                header = stripped[3:].strip()
                continue
            break
        if not inside:
            continue
        if stripped.startswith('# '):
            break
        if stripped.startswith('- ') or stripped.startswith('* '):
            items.append('• ' + stripped[2:].strip())
        elif stripped and not items:
            # 段落导语也带上，否则只有一串条目看不出这版做了什么。
            items.append(stripped)
    if not items:
        return ''
    body = '\n'.join(items)
    return ('【%s】\n%s' % (header, body)) if header else body


def api_request(url, token, method='GET', data=None, cafile=''):
    context = ssl.create_default_context(cafile=cafile)
    headers = {
        'Authorization': 'Bearer %s' % token,
        'Content-Type': 'application/json',
        'Accept': 'application/json',
    }
    payload = json.dumps(data).encode('utf-8') if data else None
    request = urllib.request.Request(url, data=payload, headers=headers, method=method)
    with urllib.request.urlopen(request, context=context) as response:
        body = response.read().decode('utf-8')
        return json.loads(body) if body else {}


def make_jwt(jwt, key_id, issuer, private):
    now = int(time.time())
    payload = {'iss': issuer, 'exp': now + 1200, 'aud': 'appstoreconnect-v1'}
    return jwt.encode(payload, private, algorithm='ES256', headers={'kid': key_id})


def main():
    parser = argparse.ArgumentParser(description='设置 TestFlight 更新说明')
    parser.add_argument('--notes', help='直接给说明文本')
    parser.add_argument('--build-number', help='目标构建号；留空取最新')
    parser.add_argument('--bundle-id', help='默认取 PACKAGE_NAME 或 com.guoapp.app')
    parser.add_argument('--locale', default='zh-Hans')
    options = parser.parse_args()

    key_id, issuer, private = credentials()
    if not key_id:
        print('[说明] 未配置 App Store Connect 凭据，跳过。')
        return 0

    notes = (options.notes or '').strip() or latest_notes()
    if not notes:
        notes = '本版本优化了播放稳定性与使用体验。'

    bundle = (options.bundle_id or secret('PACKAGE_NAME') or 'com.guoapp.app').strip()
    certifi, jwt = load_dependencies()
    token = make_jwt(jwt, key_id, issuer, private)
    cafile = certifi.where()

    apps = api_request(
        'https://api.appstoreconnect.apple.com/v1/apps?filter[bundleId]=%s' % bundle,
        token, cafile=cafile).get('data', [])
    if not apps:
        print('[说明] App Store Connect 里没有 bundle id 为 %s 的应用，跳过。' % bundle)
        return 0
    app_id = apps[0]['id']

    build = None
    for attempt in range(6):
        rows = api_request(
            'https://api.appstoreconnect.apple.com/v1/builds?filter[app]=%s'
            '&sort=-uploadedDate&limit=10' % app_id,
            token, cafile=cafile).get('data', [])
        if options.build_number:
            build = next((row for row in rows
                          if row['attributes'].get('version') == options.build_number), None)
        else:
            build = rows[0] if rows else None
        if build:
            break
        print('[说明] 等待构建出现在 App Store Connect（%d/6）……' % (attempt + 1), flush=True)
        time.sleep(10)

    if not build:
        print('[说明] 还没查到构建记录，稍后可在 App Store Connect 手动补说明。')
        return 0

    build_id = build['id']
    localizations = api_request(
        'https://api.appstoreconnect.apple.com/v1/builds/%s/betaBuildLocalizations' % build_id,
        token, cafile=cafile).get('data', [])
    existing = next((row for row in localizations
                     if row['attributes'].get('locale') == options.locale), None)
    if existing:
        api_request(
            'https://api.appstoreconnect.apple.com/v1/betaBuildLocalizations/%s' % existing['id'],
            token, method='PATCH', cafile=cafile,
            data={'data': {'type': 'betaBuildLocalizations', 'id': existing['id'],
                           'attributes': {'whatsNew': notes}}})
        print('[说明] 已更新 %s 的更新说明。' % options.locale)
    else:
        api_request(
            'https://api.appstoreconnect.apple.com/v1/betaBuildLocalizations',
            token, method='POST', cafile=cafile,
            data={'data': {'type': 'betaBuildLocalizations',
                           'attributes': {'locale': options.locale, 'whatsNew': notes},
                           'relationships': {'build': {'data': {'type': 'builds',
                                                                'id': build_id}}}}})
        print('[说明] 已创建 %s 的更新说明。' % options.locale)
    print(notes)
    return 0


if __name__ == '__main__':
    sys.exit(main())
