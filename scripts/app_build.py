import json
import os
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUNDLED_DIRECTORY = ROOT / 'native' / 'core' / 'bundled'
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


def prepare_bundled_modules(extra=()):
    BUNDLED_DIRECTORY.mkdir(parents=True, exist_ok=True)
    for child in BUNDLED_DIRECTORY.iterdir():
        if child.name != '.gitkeep':
            if child.is_dir():
                shutil.rmtree(child)
            else:
                child.unlink()
    for item in [*os.environ.get('BUNDLED_MODULES', '').split(','), *extra]:
        if not item.strip():
            continue
        source = Path(item.strip())
        if not source.is_absolute():
            source = ROOT / source
        missing = [name for name in MODULE_FILES if not (source / name).is_file()]
        if missing:
            raise SystemExit(f'内置模块 {source} 缺少 {"、".join(missing)}')
        manifest = json.loads((source / 'manifest.json').read_text(encoding='utf-8'))
        target = BUNDLED_DIRECTORY / manifest['id']
        target.mkdir()
        for name in MODULE_FILES:
            shutil.copy2(source / name, target / name)
        print(f'内置模块：{manifest["id"]} {manifest.get("version", "")}', flush=True)


def add_variant_argument(parser):
    parser.add_argument('--all-sources', action='store_true',
                        help='构建包含全部站源的真果鉴；默认构建仅红果的红果鉴')


# Go 核心已不含 BT 依赖，保留统一入口以便各平台构建脚本共用。
def go_build_tag_args():
    return []
