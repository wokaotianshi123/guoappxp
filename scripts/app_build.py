from dataclasses import dataclass


@dataclass(frozen=True)
class BuildVariant:
    all_sources: bool = False

    @property
    def slug(self):
        return 'zhenguojian' if self.all_sources else 'hongguojian'

    @property
    def bundle_identifier(self):
        return 'com.guoapp.all' if self.all_sources else 'com.guoapp.phoenix'

    @property
    def arguments(self):
        return ['--all-sources'] if self.all_sources else []

    @property
    def flutter_arguments(self):
        return ['--dart-define=ALL_SOURCES=' + str(self.all_sources).lower()]

    @property
    def linker_flags(self):
        return '-s -w -X duanjuapp/native/core.buildAllSources=' + str(self.all_sources).lower()


def add_variant_argument(parser):
    parser.add_argument('--all-sources', action='store_true',
                        help='构建包含全部站源的真果鉴；默认构建仅红果的红果鉴')


# github.com/anacrolix/torrent 在 CGO_ENABLED=1 时默认启用两个 C/C++ 后端：
#   * utp_libutp.go（cgo && !disable_libutp）引入 C++ 版 go-libutp；
#   * storage/sqlite-piece-completion.go（cgo && !nosqlite）引入 C 版 sqlite。
# CI 交叉编译里这两个都会炸：Android 上 Go 链接器一见到 C++ 目标文件就改用
# CXX（脚本只设了 CC，于是落到宿主机 x86_64 的 g++），拿它去链 aarch64 的
# go.o 报 "Relocations in generic ELF (EM: 183)"；Windows/MinGW 上 go-libutp
# 的 utp_types.h 里 `typedef uint8 bool;` 与 C++ 的 bool 关键字冲突。
# 用库自带的标签切到纯 Go UTP + bbolt 后端，BT 的 TCP / DHT / 元数据 / Range
# 流能力不变，五端 c-shared / c-archive 都不再需要外部 C++ 工具链。
GO_BUILD_TAGS = 'disable_libutp,nosqlite'


def go_build_tag_args():
    """所有 Go 构建与测试入口统一带上，避免只修一个平台、漏掉其它平台。"""
    return ['-tags=' + GO_BUILD_TAGS]
