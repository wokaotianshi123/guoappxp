# 官方源签名参数与构建设置

官方短剧脚本 `assets/sources/hongguo.js` 的 App 接口需要一组签名密钥。脚本源码里只保留占位符
`__THL_HONGGUO_SIGNING_ID_BASE64__` / `__THL_HONGGUO_SIGNING_MATERIAL_BASE64__`，
真参数在**构建时**通过环境变量 `HONGGUO_SIGNING_CONFIG` 注入：

```json
{"id":"NjQ2NjM3Nzk0","material":"sjwqRwog0QXcP4xEOPgnLtRtbIn/3N7dUQhpjSbpSJ0="}
```

`id` 解码后为 9 字节、`material` 为 32 字节，脚本据此校验。仓库里不再保存这份明文。

## 一、GitHub 上部署 / 出包

1. 打开仓库 `Settings → Secrets and variables → Actions`。
2. 在 **Secrets** 页点 `New repository secret`：
   - Name：`HONGGUO_SIGNING_CONFIG`
   - Value：上面那整行 JSON（一行，不要换行、不要多余引号）
3. 在 `Actions → Build app packages → Run workflow` 勾选需要出包的平台并运行。

工作流会把 Secret 传给各个构建脚本：

- Flutter 端：`--dart-define=HONGGUO_SIGNING_CONFIG=…`，签名编译进 App；
  `assets/sources/hongguo.js` 的占位符在脚本装载时自动替换，用户不必在
  「我的 › JS 沙箱 › 签名参数」里填写。用户自己填的参数仍然可以覆盖内置值。
- 本地服务版：`go build -ldflags "-X main.builtInSigningID=… -X main.builtInSigningMaterial=…"`，
  签名直接写进 `guoapp-web.exe`，不落盘 `js_sources/signing.json`，网页端也不显示密钥。

> 未设置该 Secret 时出包仍会成功，但内置官方源会因缺签名无法出片（会给出明确提示）。
> Secret 只在构建步骤里使用，不会写进 Release 说明或日志。

## 二、本地自行构建

### Windows（PowerShell）

```powershell
$env:HONGGUO_SIGNING_CONFIG = '{"id":"NjQ2NjM3Nzk0","material":"sjwqRwog0QXcP4xEOPgnLtRtbIn/3N7dUQhpjSbpSJ0="}'
python scripts/build_windows.py          # Flutter App
python scripts/build_web.py              # 本地服务版（签名写进 exe）
```

### macOS / Linux（bash）

```bash
export HONGGUO_SIGNING_CONFIG='{"id":"NjQ2NjM3Nzk0","material":"sjwqRwog0QXcP4xEOPgnLtRtbIn/3N7dUQhpjSbpSJ0="}'
python3 scripts/build_android.py
python3 scripts/build_ios.py
python3 scripts/build_macos.py
```

### 开发时热运行

```bash
flutter run --dart-define='HONGGUO_SIGNING_CONFIG={"id":"NjQ2NjM3Nzk0","material":"sjwqRwog0QXcP4xEOPgnLtRtbIn/3N7dUQhpjSbpSJ0="}'
```

本地服务版也可在**运行时**用同名环境变量临时提供签名（仅限开发调试）：

```bash
HONGGUO_SIGNING_CONFIG='{"id":"…","material":"…"}' ./guoapp-web.exe -open
```

发布包不需要也不应该设置它——签名已经在 exe 里。

## 三、站源列表与「管理JS源」按钮

内置 `hongguo.js`（源名「官方免费短剧」，标识 `js:hongguo`）已列入主页「全部站源」
面板的 **JS 沙箱** 分组：首次进入沙箱自动安装，与内核站源同权出现在站源菜单里。

站源面板右上角现有三个入口：

- 管理模块项（管理员）：跳「我的 › 自定义模块」
- 管理XBPQ（管理员）：跳「我的 › 自定义XBPQ」
- **管理JS源**：跳「我的 › JS 沙箱」，可在其中管理内置与导入的脚本源

「管理JS源」对所有用户可见，因为 JS 沙箱本身不参与用户站源权限判定。

## 四、安全提示

- 这是一组签名密钥，任何拿到它的人都能以该身份访问官方接口；不要提交进仓库、
  不要写进公开 Issue / 群组，只在构建机的 Secret / 环境变量里保存。
- 仓库已通过 `.gitignore` 忽略 `**/js_sources/signing.json`，旧的明文文件已从仓库删除。
- 换密钥时只需更新 GitHub Secret 重新出包，或本地改环境变量后重建，无需改脚本源码。
