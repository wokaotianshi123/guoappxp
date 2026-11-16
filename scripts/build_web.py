"""构建小果影视本地服务版。

只出一个 Windows 包，不内置任何站源（站源从站源页的模块商店安装）：

    guoapp-<版本>-web-windows-amd64.zip
        解压后双击 start.bat，内含 guoapp-web.exe + ffmpeg.exe + README.txt

红果等加密 H.265 站源要靠服务端的 ffmpeg 解密转码才能播，而单文件装不下
ffmpeg（静态版约 90 MB），所以 Windows 用 zip 而不是裸 exe。
"""

import os
import platform
import re
import shutil
import subprocess
import urllib.request
import zipfile
from pathlib import Path

from app_build import app
from source_module import clean

root = Path(__file__).resolve().parents[1]
native = root / 'native'

# 本地服务版不内置任何站源：站源从站源页的模块商店安装，与 App 端一致。
# 这里顺手清掉可能残留的 go.work / sources_gen.go，残留的 workspace 会让
# go build 走进另一个模块图。
clean(native)

version = re.search(r'^version:\s*(\S+)', (root / 'pubspec.yaml').read_text(encoding='utf-8'), re.MULTILINE).group(1)

environment = os.environ.copy()
environment.setdefault('GOPROXY', 'https://goproxy.cn,direct')
environment.setdefault('GOSUMDB', 'off')
environment['CGO_ENABLED'] = '0'
go = shutil.which('go')
if not go:
    raise SystemExit('请先安装 Go 1.24.1 或更新版本。')
bootstrap = environment.copy()
bootstrap['GOSUMDB'] = os.environ.get('GOSUMDB', 'sum.golang.org')
toolchain = subprocess.check_output([go, 'env', 'GOROOT'], cwd=native, env=bootstrap, text=True).strip()
go = str(Path(toolchain) / 'bin' / ('go.exe' if platform.system() == 'Windows' else 'go'))

targets = [('windows', 'amd64')]


def artifact_name(goos, goarch):
    suffix = '.exe' if goos == 'windows' else ''
    return f'{app.slug}-{version}-web-{goos}-{goarch}{suffix}'


def build_binary(goos, goarch, output):
    output.parent.mkdir(parents=True, exist_ok=True)
    build_environment = dict(environment, GOOS=goos, GOARCH=goarch)
    flags = f'-s -w -X main.editionSlug={app.slug} -X main.appVersion={version}'
    print('Building ' + output.name, flush=True)
    subprocess.run([go, 'build', '-trimpath', '-ldflags=' + flags, '-o', str(output), './server'],
                   cwd=native, env=build_environment, check=True)
    return output


# Windows 静态版 ffmpeg（约 90 MB）。GitHub 直连在国内常常超时，
# 先走加速前缀（cfkua 为首选，实测可用），失败依次回退到其它镜像。
FFMPEG_MIRRORS = [
    'https://cfkua.wokaotianshi.eu.org/https://github.com/GyanD/codexffmpeg/releases/download/7.1/ffmpeg-7.1-essentials_build.zip',
    'https://ghfast.top/https://github.com/GyanD/codexffmpeg/releases/download/7.1/ffmpeg-7.1-essentials_build.zip',
    'https://gh-proxy.com/https://github.com/GyanD/codexffmpeg/releases/download/7.1/ffmpeg-7.1-essentials_build.zip',
    'https://github.com/GyanD/codexffmpeg/releases/download/7.1/ffmpeg-7.1-essentials_build.zip',
]


def windows_script(executable):
    mirror_lines = [line for url in FFMPEG_MIRRORS for line in ('  "' + url + '"', '')]
    return '\r\n'.join([
        '@echo off',
        'setlocal EnableDelayedExpansion',
        'cd /d "%~dp0"',
        'title ' + app.display_name + ' local service',
        'set "BIN=' + executable + '"',
        'set "FF=%~dp0ffmpeg.exe"',
        'set "ZIP=%~dp0ffmpeg-download.zip"',
        'set "FFTMP=%~dp0ffmpeg-temp"',
        'set "NEEDFF=1"',
        'if exist "!FF!" set "NEEDFF=0"',
        'if "!NEEDFF!"=="1" (',
        '  for /f "delims=" %%A in (\'where ffmpeg 2^>nul\') do set "NEEDFF=0"',
        ')',
        'if "!NEEDFF!"=="0" goto :RUN',
        'echo.',
        'echo ================================================================',
        'echo  没有检测到 ffmpeg',
        'echo ----------------------------------------------------------------',
        'echo  红果站源的视频是加密的 H.265，浏览器既不能解密也不能解码，',
        'echo  必须由 ffmpeg 在服务端解密转码后才能播放。',
        'echo  现在可以自动下载 ffmpeg（约 90 MB）并放到本目录：',
        'echo      %~dp0ffmpeg.exe',
        'echo ================================================================',
        'echo.',
        'set "ANSWER=Y"',
        'where choice >nul 2>nul',
        'if errorlevel 1 (',
        '  set /p "ANSWER=是否现在下载 ffmpeg？直接回车下载，输入 N 跳过："',
        ') else (',
        '  choice /c YN /n /t 30 /d Y /m "是否现在下载 ffmpeg？（Y=下载，N=跳过）"',
        '  if not errorlevel 2 set "ANSWER=Y"',
        '  if errorlevel 2 set "ANSWER=N"',
        ')',
        'if /i "!ANSWER!"=="N" goto :SKIP',
        'call :DOWNLOAD',
        'goto :RUN',
        '',
        ':SKIP',
        'echo.',
        'echo 已跳过下载。红果站源暂时无法播放。',
        'echo 之后可手动把 ffmpeg.exe 放到本目录，或执行 winget install ffmpeg。',
        'goto :RUN',
        '',
        ':DOWNLOAD',
        'set "OK=0"',
        'set "USECURL=0"',
        'where curl >nul 2>nul',
        'if not errorlevel 1 set "USECURL=1"',
        'echo.',
        'echo 正在下载 ffmpeg，视网络情况需要几分钟，请稍候...',
        'for %%U in (',
    ] + mirror_lines + [
        ') do (',
        '  if "!OK!"=="0" (',
        '    echo 下载地址：%%~U',
        '    if exist "!ZIP!" del /q "!ZIP!"',
        '    if "!USECURL!"=="1" (',
        '      curl.exe -L --retry 2 --retry-delay 2 --connect-timeout 20 --max-time 1800 -o "!ZIP!" "%%~U"',
        '    ) else (',
        '      powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri \'%%~U\' -OutFile \'!ZIP!\' -UseBasicParsing"',
        '    )',
        '    if exist "!ZIP!" (',
        '      for %%F in ("!ZIP!") do if %%~zF GTR 1000000 set "OK=1"',
        '    )',
        '  )',
        ')',
        'if "!OK!"=="0" (',
        '  echo 下载失败。可稍后手动下载 ffmpeg.exe 放到本目录，或执行 winget install ffmpeg。',
        '  echo 现在照常启动服务。',
        '  goto :EOF',
        ')',
        'echo 下载完成，正在解压...',
        'if exist "!FFTMP!" rd /s /q "!FFTMP!"',
        'md "!FFTMP!" 2>nul',
        'tar.exe -xf "!ZIP!" -C "!FFTMP!" >nul 2>&1',
        'if errorlevel 1 (',
        '  powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -LiteralPath \'!ZIP!\' -DestinationPath \'!FFTMP!\' -Force"',
        ')',
        'for /f "delims=" %%F in (\'dir /s /b "!FFTMP!\\ffmpeg.exe" 2^>nul\') do copy /y "%%F" "!FF!" >nul',
        'del /q "!ZIP!" 2>nul',
        'rd /s /q "!FFTMP!" 2>nul',
        'if exist "!FF!" (',
        '  for %%F in ("!FF!") do if %%~zF LSS 1000000 del /q "!FF!"',
        ')',
        'if exist "!FF!" (',
        '  echo ffmpeg 已放到本目录，红果站源现在可以正常播放。',
        ') else (',
        '  echo 解压后没有找到 ffmpeg.exe，请手动下载放到本目录。',
        ')',
        'goto :EOF',
        '',
        ':RUN',
        'if exist "!BIN!" goto :START',
        'echo.',
        'echo 没有找到 !BIN!，请确认压缩包已完整解压后再运行 start.bat。',
        'pause',
        'goto :END',
        '',
        ':START',
        'echo.',
        'echo 正在启动本地服务，浏览器会自动打开 http://127.0.0.1:8000/web/',
        'echo 同一局域网的其它设备可用启动时打印的局域网地址访问。',
        'echo 关闭本窗口或按 Ctrl+C 即可停止服务（换端口：start.bat 后加 -port 8001）。',
        'echo.',
        '"!BIN!" -open %*',
        'echo.',
        'echo 服务已退出。',
        'pause',
        ':END',
        'endlocal',
        '',
    ])


def readme():
    return '\n'.join([
        app.display_name + ' 本地服务版 ' + version,
        '',
        '使用方法：',
        '  双击 start.bat',
        '',
        '服务启动后浏览器打开：',
        '  http://127.0.0.1:8000/web/',
        '  同一局域网的其他设备打开：http://<本机局域网 IP>:8000/web/',
        '  启动时会打印所有可用地址；换端口运行：start.bat 后加 -port 8001。',
        '',
        '站源：',
        '  本版不内置站源，打开「我的 › 站源 › 模块」在模块商店里安装。',
        '',
        '收藏夹：',
        '  网页顶部右侧「收藏夹」里有播放记录与收藏，可单项删除、批量删除或清空。',
        '  播放页的「收藏」按钮可把当前剧加入收藏，再点一次取消。',
        '  播放记录与收藏保存在数据目录的 library.json，换浏览器、换设备都还在。',
        '',
        '说明：',
        '  数据保存在本目录下的 ' + app.slug + '-data，直接删除即可清空缓存。',
        '  关闭窗口即停止服务。',
        '',
        '关于 ffmpeg：',
        '  红果站源的视频是加密的 H.265，浏览器既不能解密也不能解码，',
        '  必须由服务端调用 ffmpeg 解密并转码成 H.264 才能播放。',
        '  本压缩包已内置 ffmpeg.exe，开箱即播；',
        '  若不慎删除，start.bat 会自动重新下载，或执行 winget install ffmpeg。',
        '',
    ])


def fetch_ffmpeg():
    """下载 GyanD 7.1 静态包并只取出 ffmpeg.exe，缓存到 build/web/ffmpeg/。

    依次尝试 FFMPEG_MIRRORS；同一版第二次打包直接复用缓存。取不到时退出并
    给出明确原因（ffmpeg.exe 要随 Windows 包一起发布，缺了它红果就没法播放）。
    """
    cache = root / 'build' / 'web' / 'ffmpeg'
    cache.mkdir(parents=True, exist_ok=True)
    exe = cache / 'ffmpeg.exe'
    if exe.exists() and exe.stat().st_size > 1_000_000:
        print('ffmpeg ready (cached) ' + str(exe), flush=True)
        return exe
    for url in FFMPEG_MIRRORS:
        print('Downloading ffmpeg ' + url, flush=True)
        blob = cache / 'ffmpeg-download.zip'
        try:
            blob.unlink(missing_ok=True)
            urllib.request.urlretrieve(url, blob)
            if blob.stat().st_size < 1_000_000:
                print('ffmpeg download too small, trying next mirror', flush=True)
                continue
            with zipfile.ZipFile(blob) as src:
                for name in src.namelist():
                    if name.lower().endswith('ffmpeg.exe'):
                        with src.open(name) as handle, open(exe, 'wb') as out:
                            shutil.copyfileobj(handle, out)
                        break
            blob.unlink(missing_ok=True)
            if exe.exists() and exe.stat().st_size > 1_000_000:
                print('ffmpeg ready ' + str(exe), flush=True)
                return exe
        except Exception as exc:
            print('ffmpeg mirror failed ' + url + ' (' + str(exc) + ')', flush=True)
    raise SystemExit('所有 ffmpeg 下载源都失败，无法把 ffmpeg.exe 打进 Windows 包。')


def package_windows(binary):
    """Windows 打成 zip：exe + ffmpeg.exe + start.bat + README.txt。

    红果没有 ffmpeg 就放不了，不能让用户自己去配环境；
    exe 用短名 guoapp-web.exe，平台信息已经在压缩包名里。
    """
    output = root / 'dist' / 'web'
    output.mkdir(parents=True, exist_ok=True)
    executable = app.slug + '-web.exe'
    staging = root / 'build' / 'web' / 'windows'
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    shutil.copy2(binary, staging / executable)
    shutil.copy2(fetch_ffmpeg(), staging / 'ffmpeg.exe')
    # start.bat 用 GBK：cmd.exe 按系统 ANSI 代码页读批处理，中文 Windows 上才不会乱码。
    (staging / 'start.bat').write_bytes(windows_script(executable).encode('gbk'))
    (staging / 'README.txt').write_text(readme(), encoding='utf-8')
    archive = output / (artifact_name('windows', 'amd64')[:-4] + '.zip')
    archive.unlink(missing_ok=True)
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as bundle:
        for item in sorted(staging.rglob('*')):
            if item.is_file():
                bundle.write(item, app.slug + '/' + item.relative_to(staging).as_posix())
    print(archive)
    return archive


output_directory = root / 'dist' / 'web'
if output_directory.exists():
    shutil.rmtree(output_directory)
output_directory.mkdir(parents=True)

for goos, goarch in targets:
    built = build_binary(goos, goarch, root / 'build' / 'web' / artifact_name(goos, goarch))
    package_windows(built)
    built.unlink(missing_ok=True)
