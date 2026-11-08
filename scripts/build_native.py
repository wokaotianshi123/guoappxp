import argparse
import os
import platform
import shutil
import subprocess
from pathlib import Path

from app_build import BuildVariant, add_variant_argument, go_build_tag_args

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--platform', choices=['android', 'windows', 'darwin'], required=True)
parser.add_argument('--abi', action='append', choices=['arm64-v8a', 'armeabi-v7a', 'x86_64'])
add_variant_argument(parser)
options = parser.parse_args()
variant = BuildVariant(options.all_sources)

environment = os.environ.copy()
# CI 的默认值是 proxy.golang.org（偶发流中断）；setdefault 不覆盖已设值，
# 手动设了 GOPROXY 时以手动值为准。多代理轮换：前一个下载失败就切下一个。
if 'GOPROXY' not in os.environ:
    environment['GOPROXY'] = 'https://goproxy.cn,https://proxy.golang.org,direct'
environment.setdefault('GOSUMDB', 'off')
environment['CGO_ENABLED'] = '1'
go = shutil.which('go')
if not go:
    raise SystemExit('请先安装 Go 1.24.1 或更新版本。')
bootstrap_env = environment.copy()
bootstrap_env['GOSUMDB'] = os.environ.get('GOSUMDB', 'sum.golang.org')
if bootstrap_env['GOSUMDB'] == 'off':
    bootstrap_env['GOSUMDB'] = 'sum.golang.org'
toolchain_root = subprocess.check_output([go, 'env', 'GOROOT'], cwd=root / 'native',
    env=bootstrap_env, text=True).strip()
go = str(Path(toolchain_root) / 'bin' / ('go.exe' if platform.system() == 'Windows' else 'go'))

def build(goos, architecture, compiler, output, extra=None):
    output.parent.mkdir(parents=True, exist_ok=True)
    build_env = environment.copy()
    build_env.update(GOOS=goos, GOARCH=architecture, CC=str(compiler))
    if extra:
        build_env.update(extra)
    print('Building ' + str(output.relative_to(root)), flush=True)
    args = [go, 'build', '-trimpath', '-buildmode=c-shared', *go_build_tag_args(),
            '-ldflags=' + variant.linker_flags, '-o', str(output), './bridge']
    attempt = 0
    while True:
        attempt += 1
        try:
            subprocess.run(args, cwd=root / 'native', env=build_env, check=True)
            return
        except subprocess.CalledProcessError as error:
            # 只处理编译失败；其它错误（如 NDK 缺失）直接抛出。
            if error.returncode != 1 or attempt >= 5:
                raise
            # 先补齐依赖再重试：Go 模块代理（proxy.golang.org）偶发 HTTP/2
            # 流中断（stream error: INTERNAL_ERROR），go build 本身没有自动重试。
            if subprocess.run([go, 'mod', 'download'], cwd=root / 'native',
                              env=build_env, check=False).returncode:
                print('依赖下载失败，重试…（第 ' + str(attempt) + ' 次）', flush=True)
                continue
            print('编译失败，重试…（第 ' + str(attempt) + ' 次）', flush=True)

if options.platform == 'android':
    sdk = os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT')
    if not sdk:
        raise SystemExit('请设置 ANDROID_HOME 为 Android SDK 目录。')
    ndk = Path(os.environ.get('ANDROID_NDK_HOME', Path(sdk) / 'ndk' / '28.2.13676358'))
    host = {'Darwin': 'darwin-x86_64', 'Linux': 'linux-x86_64', 'Windows': 'windows-x86_64'}[platform.system()]
    compilers = ndk / 'toolchains' / 'llvm' / 'prebuilt' / host / 'bin'
    mappings = {
        'arm64-v8a': ('arm64', 'aarch64-linux-android24-clang'),
        'armeabi-v7a': ('arm', 'armv7a-linux-androideabi24-clang'),
        'x86_64': ('amd64', 'x86_64-linux-android24-clang'),
    }
    for abi in options.abi or list(mappings):
        architecture, name = mappings[abi]
        compiler = compilers / (name + ('.cmd' if platform.system() == 'Windows' else ''))
        if not compiler.exists():
            raise SystemExit('缺少 Android NDK 编译器：' + str(compiler))
        output = root / 'android' / 'app' / 'src' / 'main' / 'jniLibs' / abi / 'libduanju_core.so'
        extra = {'CGO_LDFLAGS': '-Wl,-z,max-page-size=16384'}
        # 防御：Go 见到 C++ 目标文件会改用 CXX 做外部链接，只设 CC 会落到宿主机
        # g++（x86_64），链 aarch64 的 go.o 直接报 "EM: 183 / file in wrong format"。
        cxx = compilers / (name + '++' + ('.cmd' if platform.system() == 'Windows' else ''))
        if cxx.exists():
            extra['CXX'] = str(cxx)
        if architecture == 'arm':
            extra['GOARM'] = '7'
        build('android', architecture, compiler, output, extra)
elif options.platform == 'windows':
    compiler = shutil.which('x86_64-w64-mingw32-gcc') or (shutil.which('gcc') if platform.system() == 'Windows' else None)
    if not compiler:
        raise SystemExit('请安装 MinGW-w64，并将其 bin 目录加入 PATH。')
    build('windows', 'amd64', compiler, root / 'windows' / 'runner' / 'duanju_core.dll',
          {'CGO_LDFLAGS': '-static-libgcc'})
else:
    # macOS：编成静态库（c-archive）再由 DuanjuCore pod 链进主程序，
    # Dart 侧用 DynamicLibrary.process() 取符号（和 iOS 同一套做法）。
    # 同时编 arm64 与 x86_64 两片再 lipo 成通用库，Apple 芯片和 Intel 都能跑。
    if platform.system() != 'Darwin':
        raise SystemExit('macOS 核心需要在 macOS 上构建。')
    compiler = shutil.which('clang')
    if not compiler:
        raise SystemExit('需要安装 Xcode Command Line Tools。')
    output = root / 'macos' / 'DuanjuCore' / 'libDuanjuCore.a'
    slices = []
    for architecture, triple in [('arm64', 'arm64-apple-macos12.0'),
                                 ('amd64', 'x86_64-apple-macos12.0')]:
        library = root / 'native' / 'build' / 'macos' / architecture / 'libDuanjuCore.a'
        library.parent.mkdir(parents=True, exist_ok=True)
        print('Building ' + str(library.relative_to(root)), flush=True)
        build_env = environment | {'GOOS': 'darwin', 'GOARCH': architecture, 'CC': str(compiler),
                                   'CGO_CFLAGS': '-target ' + triple,
                                   'CGO_LDFLAGS': '-target ' + triple}
        subprocess.run([go, 'build', '-trimpath', '-buildmode=c-archive', *go_build_tag_args(),
                        '-ldflags=' + variant.linker_flags, '-o', str(library), './bridge'],
                       cwd=root / 'native', env=build_env, check=True)
        slices.append(str(library))
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['lipo', '-create', *slices, '-output', str(output)], check=True)
