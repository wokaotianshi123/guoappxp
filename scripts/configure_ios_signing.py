#!/usr/bin/env python3
"""配置 iOS 发布签名（CI 用，本地也可复用）。

做三件事：

1. 把 `APPLE_CERTIFICATE_P12_BASE64` 解出的发布证书导入临时钥匙串；
2. 把 `IOS_PROVISION_PROFILE_BASE64` 解出的描述文件放进
   `~/Library/MobileDevice/Provisioning Profiles/`，并额外按
   `ios_appstore.mobileprovision` 存一份固定文件名，供 xcodebuild 按名字匹配；
3. 按证书与描述文件里的实际信息生成 `ios/ExportOptions.plist`
   （teamID / 签名身份 / bundle id / 描述文件名）。

任何一项缺失都只是跳过并给出提示，不会让构建失败——这样仓库在没有配置
Secrets 时仍然能跑「未签名」构建，与原来的行为一致。

用法：
    python scripts/configure_ios_signing.py            # 导入证书与描述文件
    python scripts/configure_ios_signing.py --export-options   # 只生成 plist
    python scripts/configure_ios_signing.py --clean    # 清理钥匙串
"""
import argparse
import base64
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
keychain = 'guoapp-build.keychain'
keychain_password = 'guoapp_ci_temporal'
profile_dir = Path.home() / 'Library' / 'MobileDevice' / 'Provisioning Profiles'
export_options = root / 'ios' / 'ExportOptions.plist'


def run(arguments, **kwargs):
    return subprocess.run(arguments, check=True, **kwargs)


def decode(value):
    """Secrets 既可能是纯 base64，也可能是被拆成多行带空白的 base64。"""
    raw = ''.join(value.split())
    if not raw:
        return b''
    return base64.b64decode(raw, validate=True)


def secret(*names):
    for name in names:
        value = os.environ.get(name, '').strip()
        if value:
            return value
    return ''


def import_certificate():
    """把发布证书导入临时钥匙串；没有配置就返回 False。"""
    certificate = secret('APPLE_CERTIFICATE_P12_BASE64', 'IOS_CERTIFICATE_P12_BASE64')
    password = secret('APPLE_CERTIFICATE_PASSWORD', 'IOS_CERTIFICATE_PASSWORD')
    if not certificate or not password:
        print('[签名] 未配置 APPLE_CERTIFICATE_P12_BASE64 / _PASSWORD，跳过证书导入。')
        return False
    try:
        data = decode(certificate)
    except ValueError as error:
        raise SystemExit('APPLE_CERTIFICATE_P12_BASE64 不是有效的 Base64：%s' % error)
    if not data:
        raise SystemExit('APPLE_CERTIFICATE_P12_BASE64 解出来是空的。')

    # 已存在同名钥匙串时先删掉，避免上一次残留的锁或旧证书。
    subprocess.run(['security', 'delete-keychain', keychain],
                   capture_output=True, text=True)
    run(['security', 'create-keychain', '-p', keychain_password, keychain])
    run(['security', 'set-keychain-settings', '-lut', '21600', keychain])
    run(['security', 'unlock-keychain', '-p', keychain_password, keychain])
    # 把临时钥匙串加进搜索列表，否则 codesign 找不到刚导入的证书。
    existing = subprocess.run(['security', 'list-keychains', '-d', 'user'],
                              capture_output=True, text=True).stdout
    paths = [line.strip().strip('"') for line in existing.splitlines() if line.strip()]
    if keychain not in paths:
        paths.insert(0, keychain)
    run(['security', 'list-keychains', '-d', 'user', '-s', *paths])

    p12 = Path(os.environ.get('RUNNER_TEMP', '/tmp')) / 'guoapp-release.p12'
    p12.write_bytes(data)
    try:
        run(['security', 'import', str(p12), '-k', keychain,
             '-P', password, '-T', '/usr/bin/codesign'])
        run(['security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:',
             '-s', '-k', keychain_password, keychain],
            capture_output=True)
    finally:
        p12.unlink(missing_ok=True)
    print('[签名] 发布证书已导入临时钥匙串 %s。' % keychain)
    return True


def install_profile():
    """安装描述文件；返回装进去的文件名（供 ExportOptions 引用）。"""
    profile = secret('IOS_PROVISION_PROFILE_BASE64', 'APPLE_PROVISION_PROFILE_BASE64')
    if not profile:
        print('[签名] 未配置 IOS_PROVISION_PROFILE_BASE64，跳过描述文件安装。')
        return ''
    try:
        data = decode(profile)
    except ValueError as error:
        raise SystemExit('IOS_PROVISION_PROFILE_BASE64 不是有效的 Base64：%s' % error)
    if not data:
        raise SystemExit('IOS_PROVISION_PROFILE_BASE64 解出来是空的。')

    profile_dir.mkdir(parents=True, exist_ok=True)
    # 固定文件名：ExportOptions.plist 里按名字引用，避免依赖随机 UUID。
    target = profile_dir / 'ios_appstore.mobileprovision'
    target.write_bytes(data)

    # 同时按描述文件自带的 UUID 存一份，Xcode 自动签名时靠它匹配。
    decoded = subprocess.run(['security', 'cms', '-D', '-i', str(target)],
                             capture_output=True)
    if decoded.returncode == 0:
        match = re.search(rb'<key>UUID</key>\s*<string>([^<]+)</string>', decoded.stdout)
        if match:
            uuid = match.group(1).decode().strip()
            (profile_dir / ('%s.mobileprovision' % uuid)).write_bytes(data)
            print('[签名] 描述文件已安装（UUID %s）。' % uuid)
    print('[签名] 描述文件已安装为 ios_appstore.mobileprovision。')
    return target.name


def profile_info(name):
    """读出描述文件里的 team id / 名称 / bundle id，用来生成 ExportOptions。"""
    if not name:
        return {}
    path = profile_dir / name
    if not path.is_file():
        return {}
    decoded = subprocess.run(['security', 'cms', '-D', '-i', str(path)],
                             capture_output=True)
    if decoded.returncode != 0:
        return {}
    try:
        return plistlib.loads(decoded.stdout)
    except Exception:
        return {}


def write_export_options(profile_name):
    """生成 ExportOptions.plist：优先用描述文件里的真实信息，缺失则用变量。"""
    info = profile_info(profile_name)
    team = (info.get('TeamIdentifier') or [''])[0]
    team = team or secret('APPLE_TEAM_ID')
    bundle = secret('PACKAGE_NAME') or 'com.guoapp.app'
    profile_name_attr = info.get('Name', '')

    if not team:
        print('[签名] 没有 Team ID（既无描述文件也无 APPLE_TEAM_ID），'
              '保留仓库里的 ExportOptions.plist 模板不动。')
        return False

    config = {
        'method': 'app-store-connect',
        'destination': 'export',
        'signingStyle': 'manual',
        'teamID': team,
        'signingCertificate': 'Apple Distribution',
        'stripSwiftSymbols': True,
        'uploadSymbols': True,
        'manageAppVersionAndBuildNumber': False,
        'compileBitcode': False,
        'provisioningProfiles': {bundle: profile_name_attr or profile_name},
        # 内部测试专用：只能进内部测试组，不会被提交去审核或上架。
        # 个人自用 / 小范围分发正合适，也避免误操作把构建推到公开渠道。
        'testFlightInternalTestingOnly': True,
    }
    export_options.write_bytes(plistlib.dumps(config))
    print('[签名] 已生成 ExportOptions.plist（team %s，bundle %s）。' % (team, bundle))
    return True


def clean():
    subprocess.run(['security', 'delete-keychain', keychain],
                   capture_output=True, text=True)
    print('[签名] 已删除临时钥匙串。')


def main():
    parser = argparse.ArgumentParser(description='配置 iOS 发布签名')
    parser.add_argument('--export-options', action='store_true',
                        help='只根据描述文件 / 变量生成 ExportOptions.plist')
    parser.add_argument('--clean', action='store_true', help='清理临时钥匙串')
    options = parser.parse_args()

    if sys.platform != 'darwin':
        raise SystemExit('iOS 签名只能在 macOS 上配置。')

    if options.clean:
        clean()
        return

    if options.export_options:
        install_profile()
        write_export_options('ios_appstore.mobileprovision')
        return

    import_certificate()
    profile_name = install_profile()
    write_export_options(profile_name or 'ios_appstore.mobileprovision')


if __name__ == '__main__':
    main()
