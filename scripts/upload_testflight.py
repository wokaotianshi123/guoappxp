#!/usr/bin/env python3
"""把已签名的 IPA 上传到 App Store Connect（TestFlight）。

为什么不用 `xcrun altool` 一把梭：

* Xcode 26 的 altool 有个已知回归——用 App Store Connect API Key 生成 JWT 时
  会报 `Failed to generate JWT token … NSCocoaErrorDomain Code=259`，直接传不上去
  （fastlane#29743）。所以这里先试 altool，失败后自动改用 iTMSTransporter。
* 两者都用同一套 API Key，凭据只有一份，不用维护两套密码。

凭据（缺任意一项就跳过上传，不报错，保持「没配 Secrets 也能构建」）：

    APP_STORE_CONNECT_KEY_ID        / KEY_ID
    APP_STORE_CONNECT_ISSUER_ID     / ISSUER_ID
    APP_STORE_CONNECT_PRIVATE_KEY   / PRIVATE_KEY_B64 / API_KEY_P8

私钥既可以是完整的 PEM（含 BEGIN PRIVATE KEY），也可以是它的 base64。
"""
import argparse
import base64
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


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
        try:
            private = base64.b64decode(''.join(private.split())).decode('utf-8')
        except Exception as error:
            print('[上传] 私钥既不是 PEM 也不是有效 base64：%s' % error)
            return '', '', ''
    return key_id.strip(), issuer.strip(), private


def run(arguments, **kwargs):
    print('[上传] $ ' + ' '.join(str(item) for item in arguments), flush=True)
    return subprocess.run(arguments, **kwargs)


def upload_with_altool(ipa, key_id, issuer, key_dir):
    environment = os.environ.copy()
    environment['API_PRIVATE_KEYS_DIR'] = str(key_dir)
    result = run(['xcrun', 'altool', '--upload-app', '-f', str(ipa), '-t', 'ios',
                  '--apiKey', key_id, '--apiIssuer', issuer],
                 env=environment, capture_output=True, text=True)
    output = (result.stdout or '') + (result.stderr or '')
    print(output.strip(), flush=True)
    # Xcode 26 的 JWT 回归与网络类错误都值得换 iTMSTransporter 再试一次。
    return result.returncode == 0, output


def upload_with_transporter(ipa, key_id, issuer, key_dir):
    """iTMSTransporter：Xcode 14+ 随 Xcode 提供，绕开 altool 的 JWT 回归。"""
    tool = Path('/Applications/Xcode.app/Contents/SharedFrameworks/'
                'ContentDelivery.framework/Versions/A/Resources/bin/iTMSTransporter')
    if not tool.is_file():
        found = shutil.which('iTMSTransporter')
        if not found:
            print('[上传] 找不到 iTMSTransporter，无法兜底。')
            return False
        tool = Path(found)
    result = run([str(tool), '-m', 'upload',
                  '-u', key_id, '-p', issuer,
                  '-f', str(ipa),
                  '-k', '100000',
                  '-itc_provider', issuer],
                 env=os.environ | {'API_PRIVATE_KEYS_DIR': str(key_dir)},
                 capture_output=True, text=True)
    print(((result.stdout or '') + (result.stderr or '')).strip(), flush=True)
    return result.returncode == 0


def main():
    parser = argparse.ArgumentParser(description='上传 IPA 到 TestFlight')
    parser.add_argument('ipa', type=Path, help='已签名的 .ipa')
    parser.add_argument('--build-number', help='仅用于日志与后续说明同步')
    options = parser.parse_args()

    ipa = options.ipa.expanduser().resolve()
    if not ipa.is_file():
        raise SystemExit('找不到 IPA：%s' % ipa)
    if 'unsigned' in ipa.name:
        raise SystemExit('这是未签名 IPA，不能上传到 TestFlight。')

    key_id, issuer, private = credentials()
    if not key_id:
        print('[上传] 未配置 App Store Connect 凭据，跳过上传。')
        print('[上传] 需要 APP_STORE_CONNECT_KEY_ID / _ISSUER_ID / _PRIVATE_KEY。')
        return 0

    key_dir = Path.home() / '.appstoreconnect' / 'private_keys'
    key_dir.mkdir(parents=True, exist_ok=True)
    key_file = key_dir / ('AuthKey_%s.p8' % key_id)
    key_file.write_text(private)
    key_file.chmod(0o600)
    try:
        ok, output = upload_with_altool(ipa, key_id, issuer, key_dir)
        if not ok:
            print('[上传] altool 失败，改用 iTMSTransporter 重试……')
            ok = upload_with_transporter(ipa, key_id, issuer, key_dir)
        if not ok:
            raise SystemExit('上传失败，请检查签名、bundle id 与凭据。')
        print('[上传] IPA 已上传，等待 App Store Connect 处理。')
    finally:
        key_file.unlink(missing_ok=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
