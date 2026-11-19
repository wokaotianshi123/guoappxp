import json
import os
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUNDLED_DIRECTORY = ROOT / 'native' / 'core' / 'bundled'
# 仓库自带的站源模块目录：这里的每个子目录都会内置进安装包。
# 限制级模块（清单 adult=true）同样内置，但应用端默认关闭显示。
MODULE_SOURCE_DIRECTORY = ROOT / 'modules'
MODULE_FILES = ('manifest.json', 'main.js')
ENVIRONMENT_DEFINES = ['PROJECT_URL', 'TELEGRAM_GROUP_URL', 'TELEGRAM_CHANNEL_URL']


class AppBuild:
    slug = 'guoapp'
    display_name = '小果影视'

    @property
    def bundle_identifier(self):
        return os.environ.get('PACKAGE_NAME', '').strip() or 'com.guoapp.app'

    @property
    def flutter_arguments(self):
        arguments = []
        for name in ENVIRONMENT_DEFINES:
            value = os.environ.get(name, '').strip()
            if value:
                arguments.append(f'--dart-define={name}={value}')
        return arguments

    @property
    def go_arguments(self):
        return ['-ldflags=' + self.linker_flags]

    @property
    def linker_flags(self):
        return '-s -w'


app = AppBuild()


def repository_modules():
    """仓库 modules/ 下的站源模块目录，按标识排序，供构建时内置。"""
    if not MODULE_SOURCE_DIRECTORY.is_dir():
        return []
    return sorted(
        child for child in MODULE_SOURCE_DIRECTORY.iterdir()
        if child.is_dir() and (child / 'manifest.json').is_file()
    )


def prepare_bundled_modules(extra=()):
    BUNDLED_DIRECTORY.mkdir(parents=True, exist_ok=True)
    for child in BUNDLED_DIRECTORY.iterdir():
        if child.name != '.gitkeep':
            if child.is_dir():
                shutil.rmtree(child)
            else:
                child.unlink()
    sources = []
    for item in [*os.environ.get('BUNDLED_MODULES', '').split(','), *extra]:
        if not item.strip():
            continue
        source = Path(item.strip())
        if not source.is_absolute():
            source = ROOT / source
        sources.append(source)
    sources.extend(repository_modules())
    installed = {}
    for source in sources:
        missing = [name for name in MODULE_FILES if not (source / name).is_file()]
        if missing:
            raise SystemExit(f'内置模块 {source} 缺少 {"、".join(missing)}')
        manifest = json.loads((source / 'manifest.json').read_text(encoding='utf-8'))
        identifier = manifest['id']
        # 同一标识只内置一份：仓库里的副本优先于 CI 检出的外部副本，
        # 避免两个来源的版本互相覆盖。
        if identifier in installed:
            print(f'内置模块 {identifier} 已存在，跳过 {source}', flush=True)
            continue
        target = BUNDLED_DIRECTORY / identifier
        target.mkdir()
        for name in MODULE_FILES:
            shutil.copy2(source / name, target / name)
        installed[identifier] = manifest
        level = '限制级' if manifest.get('adult') else '非限制级'
        print(f'内置模块：{identifier} {manifest.get("version", "")} {level}', flush=True)
    return installed


# Go 核心已不含 BT 依赖，保留统一入口以便各平台构建脚本共用。
def go_build_tag_args():
    return []
