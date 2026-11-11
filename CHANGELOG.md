# 更新日志

每个版本一节，标题为 `pubspec.yaml` 中的完整版本号。发布工作流会把对应一节写入 GitHub Release 说明。

## 1.4.2+118

修虎牙直播播几秒就断流，并给本地服务版的直播播放页补上换台控制。

### 修复
- **虎牙直播几秒断流**：`mp.huya.com` 下发的取流地址带 `ctype=tars_mp` 的 anti-code，虎牙 CDN 会校验请求方身份——用浏览器 UA 请求照样返回 200，但只吐约 500 KB（≈3 秒画面）就主动断开；换成虎牙客户端的 UA 后同一条地址可连续拉流（实测 90 秒 9.4 MB 不断）。App 端新增 `huyaLiveUserAgent`，服务端新增 `liveHuyaUserAgent`，只作用于虎牙，斗鱼 / 哔哩哔哩 / 秀果不受影响。
- **mpv 会丢掉自定义 UA**：media_kit 只把媒体头写进 mpv 的 `http-header-fields`，mpv 自己还会按 `user-agent` 选项（默认 `libmpv`）另发一个 UA 并覆盖前者。现在每次开播前把媒体头里的 UA 同步给 mpv 的 `user-agent`，虎牙的客户端标识才能真正发出去。

### 新增
- **本地服务版直播换台控制**：播放器下方增加「◀ 上一台 / 暂停·播放 / 下一台 ▶」按钮，在当前频道列表里环绕切换（与 App 端 `switchBy` 一致），换台后播放列表自动滚到当前项；暂停按钮文案跟随真实播放状态，用 ArtPlayer 自带控件暂停时也会同步，没有频道时自动禁用。频道列表项补充 `data-index` 以便定位。

### 测试
- 新增 `test/live_rooms_test.dart`：虎牙取流头用客户端标识、其它源仍用浏览器标识、主线路与码率优先级、anti-code 已带 `?` 时不重复拼接。
- 新增 `native/server/livestream_rooms_test.go`：虎牙取流 UA / Referer 正确，斗鱼与哔哩哔哩不被改写，未知源不下发取流头。

## 1.4.1+117

修两个 1.4.0 遗留问题：缓存清理在磁力缓存下线后统计不到实际占用；本地服务版听书打不开带付费标记的章节。

### 修复
- **清理缓存失效**：`cacheInfo` / `clearCache` 只统计 `<dataDir>/playback-cache`、播放器缓存目录与临时文件，1.4.0 删掉磁力缓存后数据目录里真正占空间的三类文件都不在范围内，设置页长期显示「0 B / 没有需要清理的缓存」。
  - 封面缓存：`covers-v1/*.img` 以及 App 端把 HEIC 等格式转出来的 `covers-v1/compatible-v1/*.jpg`（这部分之前永远不会被回收）。
  - 目录缓存：`catalogs.json`（榜单 / 分类 / 推荐，内存中的目录不受影响，下一轮浏览会重新落盘）。
  - 日志：`logs/*.log`（含轮转出来的 `app.log.1` / `native_stderr.log.1`）；文件正被写入（Windows 句柄占用）时退化为清空，不再整体失败。
  - 新增 `coverBytes` / `catalogBytes` / `logBytes` 三个字段，设置页改为「播放缓存 / 封面缓存 / 目录缓存 / 日志与临时文件」四行分类。
  - 清理封面后调用 `nativeCoverCache.refresh()` 按磁盘重建索引，避免内存里留着已删除条目的尺寸、下次取封面拿到不存在的路径。
  - 仍然不动：`shared_preferences.json`、`sources.json`、`audiobooks/`（听书书架、进度与离线音频）、`downloads/`（已下载与断点续传分片）。
- **本地服务版「清理缓存」统计不到转码产物**：转码目录是系统临时目录下的 `duanjuweb-<slug>-live`，不在核心数据目录里，顶栏按钮只能看到 0。新增 `native/server/cache.go`，在 `cacheInfo` / `clearCache` 的回包里合并转码目录的占用与释放量，`clearCache` 跳过仍在播放的任务目录，删不掉的会写进 `warning`。
- **本地服务版听书打不开「可能付费」章节**：`abPlayChapter` 里对 `chapter.locked` 直接 `showNotice('这一章需要付费，暂时无法播放')` 并返回。实测这类章节的 `/api/audiobook/text` 与 `/api/audiobook/media` 都能正常返回（付费标记只代表可能收费，不阻断接口），因此去掉硬拦截、照常尝试播放，失败时再按接口原因提示；徽标文案与 App 端统一为「可能付费」。

### 测试
- `app_cache_clean_test.go` 新增 `TestClearCacheRemovesAppGeneratedCaches`：覆盖封面（含 `compatible-v1` 的 JPEG）、目录、日志与临时文件的统计 / 清理，并断言设置、站源、听书离线音频、已下载视频不被删除，封面索引随清理归零。
- `go vet ./core ./server`、`go test -count=1 ./core ./server`、`node --check native/server/web/app.js`、`dart analyze lib/ui/settings test` 全部通过。
- 实测（真实数据副本）：`cacheInfo` 报 13.1 MB / 160 文件，`clearCache` 后 `covers-v1` 清空、`catalogs.json` 删除、其余用户数据完好；转码临时目录 `2048 B` 能统计并释放；锁定章节的 `text` 返回逐句时间轴、`media` 返回音频地址与解密 key。

## 1.4.0+116

把 `guoapplu` 的听书与直播模块移植进本项目，并按需求把磁力板块整体下线。Windows / Android / iOS / macOS / 本地服务版同步生效。

### 新增
- **听书模块（一级导航）**：`发现` 右侧新增 `听书` 标签，完整移植番茄畅听链路——听书榜 / 女生听书榜单、在线搜索、书架与收听进度、章节目录、带逐句时间轴的正文跟读（点段落跳转、当前句高亮），支持上一章 / 下一章、倍速、睡眠定时与章节下载。书架与进度按用户隔离，走 `AudiobookStore`（`<dataDir>/audiobooks`），切换用户时重建。
  - Dart 侧：`lib/ui/audiobook/`（`audiobook_fanqie.dart`、`audiobook_store.dart`、`audiobook_download.dart`、`audiobook_session.dart`、`audiobook_screen.dart`、`audiobook_widgets.dart`）。
  - Go 侧：`provider_audiobook_device.go`（听书专用播放设备注册）、`provider_audiobook_fetch.go`（榜单 / 搜索 / 目录 / 网页正文，只放行番茄相关域名且仅支持 GET）、`provider_novelfm.go`（音频地址与 CENC key）、`provider_fqnovel_text.go`（正文解密与逐句时间轴）。
  - RPC：新增 `audiobookFetch` / `audiobookText` / `audiobookMedia` 三个动作，Flutter 与本地服务版共用同一套请求，代理、限流与超时跟现有设置一致。
  - 加密：章节音频带 CENC 时返回 `decryptionKey`，App 端交给 media_kit 的 `decryption_key` 解码。
- **本地服务版网页听书**：顶栏新增「听书」入口，页面为「左列目录 / 右列正文 / 底部播放条」。新增 `/api/audiobook/ranks|search|chapters|text|media|stream` 六个接口；CENC 加密音频复用红果那套 `-decryption_key` 链路，由 ffmpeg 解密后重编码成纯音频 HLS（`transcodeManager.startAudio()`），明文音频走 `/api/audiobook/stream` 代理并透传 Range。
- **直播接入斗鱼、哔哩哔哩、虎牙**：直播入口位置保持不变（Flutter 仍从发现 / 我的进入，网页仍是顶栏「直播」）。内置源顺序改为**斗鱼（默认）→ 哔哩哔哩 → 虎牙 → 秀果直播**，原「秀果」改名「秀果直播」并排在最后。
  - App 端：新增 `LiveProtocol.room` 与 `lib/live/live_rooms.dart`（分类、房间列表、点播解析；斗鱼 `getEncryption` + `getH5PlayV1` 的 md5 循环签名、哔哩哔哩 `getRoomPlayInfo` 选最高画质、虎牙 `profileRoom` 选主线路），`live_page.dart` 增加「加载更多」分页，`live_playback.dart` 的线路计数把房间型源按一条线路显示。
  - 网页端：新增 `native/server/livestream_rooms.go`（同一套逻辑的 Go 实现）与 `/api/livestream/play` 点播接口；房间列表只下发房间号，点播时才换取真实地址；直播流代理按平台补 Referer，避免 403。
  - 绿色模式：三个公开平台照常可见，只有成人源「秀果直播」整源隐藏。

### 移除
- **磁力板块整体下线**：删除 `provider_magnet*.go`、`magnet_sites.json`、`lib/magnet_models.dart`、`lib/ui/magnet/*`、`core_bridge.dart` 的磁力 RPC 与超时、`playback_loader.dart` 的磁力短路、设置与缓存页的磁力项、网页端约 960 行磁力实现，以及 CHANGELOG / README 里的磁力历史说明。
- **依赖与构建**：`go mod tidy` 后移除 `anacrolix/torrent`、`anacrolix/dht/v2`、`antchfx/htmlquery` 等 BT 相关依赖；`scripts/app_build.py` 的 `-tags=disable_libutp,nosqlite` 与 CI 里的 C++ 后端校验一并删除。
- **缓存口径**：`cacheInfo` / `clearCache` 不再统计磁力分片，只处理播放缓存与临时文件；`app_cache_clean_test.go` 的期望值同步改为 2 个文件 / 768 字节。

### 修复
- **缓存清理测试**：移除磁力夹具后，`TestClearCacheOnlyRemovesRegenerableFiles` 仍在断言删除 3 个文件，改为 2 个。

### 实现与约束
- **听书设备链**：源项目的 `provider_fqnovel_text.go` 依赖 `hongguoPlaybackDevice`，而本项目的红果设备注册结构是另一套。移植时新增 `audiobookPlaybackDevice` 与 `registerAudiobookPlaybackDevice()`，把听书正文与音频解析用到的查询串、内容密钥、设备注册独立出来，避免与红果主链路互相影响。
- **测试**：新增 `provider_novelfm_test.go`、`provider_fqnovel_text_test.go`、`test/audiobook_catalog_test.dart`、`test/audiobook_fanqie_test.dart`、`test/audiobook_store_test.dart`；`test/app_shell_tv_focus_test.dart` 的标签顺序改为「发现 / 听书 / 追剧 / 我的」。
- **未提交**：本轮改动全部留在工作区，未做 git 提交。

## 1.3.0+115

把 `guoappxpx` 里的 15 项体验与性能改进移植进本项目，并新增站源「笔盒」。Android / Windows / macOS / iOS / 本地服务版同步生效。

### 改进
- **发现页 / 下载页支持左右滑切换**：新增 `ui/widgets/swipe_switch.dart` 的 `SwipeSwitch`——内容跟手平移，松手按位移 + 速度判定翻页，未过阈值回弹；翻页后旧内容变暗停留 1.5 秒再换新内容，切换动画走统一曲线。发现页用它切换分类（分类栏跟着滚到选中项），下载页用它切换「下载中 / 已下载」（多选状态下手势关闭，避免和拖选抢事件）。看过的分类回来时仍是原来的列表与滚动位置。
- **详情页选集区支持左右滑切分组**：`detail_page.dart` 给分组内容套同一个 `SwipeSwitch`，切到下一组时把对应的分组按钮 `ensureVisible` 滚到可见；手机详情页另加下拉刷新（`RefreshIndicator` + `AlwaysScrollableScrollPhysics`）。
- **再点一次底部当前标签回到顶部 / 刷新**：`AppShell._tap` 不再只看「是否同标签」——同标签时先 `popUntil(isFirst)` 回到该标签首页，发现页交给 `ExplorePageState.reselect()`（不在顶部就回到顶部，已顶部则触发一次下拉刷新），其它标签用每标签独立的 `PrimaryScrollController` 回到 `minScrollExtent`。平板 / 桌面侧栏走同一条 `_tap`，电视顶栏行为不变。
- **长按 / 右键快速进入多选**：追剧、观看记录、已下载的剧、下载任务、剧集列表的每一集都支持长按直接进多选并选中该项（桌面右键等效，`onSecondaryTap`）。发现页与搜索结果的海报长按改成「快速追剧 / 取消追剧」，用 `SnackBar` 的「撤销」兜底；最近搜索的长按 / 右键删除单条（新增 `LocalStore.forgetSearch()`，按归一化文本去重删除）。
- **竖屏播放双指缩放铺满**：手机竖屏播放页支持双指张开把画面放大到去掉上下黑边（cover 比例线性插值，过半吸附到铺满），捏合还原，退出播放自动还原；换集会重置缩放。捏合期间 `PageView` 的滑动关掉、并加 300ms 的防误触窗口，不会顺手暂停或切集。
- **动画体系统一**：新增 `ui/theme/motion.dart`（`Motion.short / medium / long`、`enter / exit / standard`、`reduced()` 读系统「减弱动态效果」、`pageTransitions()`、`fadeRoute()`）与 `ui/widgets/motion/motion_widgets.dart`（`FadeSwitcher`、`ToggleIconSwitcher`、`fadeInFrameBuilder`、`EnterOnce`、`coverHeroTag`）；`AppTheme` 的 `pageTransitionsTheme` 改用这套：Android 上是「缩放 0.92 + 淡入」，电视端纯淡入。
- **新增站源「笔盒」（beabox.cc）**：默认关闭，可在站源管理里打开。站点域名经常更换，当前线路失效时会从发布页自动发现可用域名并记住上次可用的线路（落盘 `beabox-sites.json`，重启直接使用）；「全部」列出最新视频，分类取站点热门标签，支持翻页、详情、分集与在线搜索，`needParse` 的线路会自动向站点接口换取播放地址。

### 修复
- **修复 Android 返回键一次退两级**：`ui/app.dart` 的 `_escape` 原来同时处理 `LogicalKeyboardKey.goBack` 与系统 `popRoute`（`PopScope` → `Navigator.maybePop`），Android 手机上物理返回键、三键导航、侧滑手势、电视遥控器返回都会两路同时触发，一次退两层页面。现在键盘只处理 `Esc`，返回键统一交给系统路由；桌面 Esc 行为不变。`player_page.dart` 的同类分支一并收敛，`AndroidManifest.xml` 打开 `enableOnBackInvokedCallback` 以走预测返回。
- **修复电视连播换集时已隐藏的播控重新弹出（#83）**：播放状态监听改成「换集只重新计时隐藏，手动暂停或最后一集播完才显示」，自动连播不再每隔一集闪一次播控。#83
- **降低 Windows 播放显存占用（#81）**：新增 `ui/player/player_video.dart` 的 `PlayerVideo`，用 `LayoutBuilder` 量出画面实际显示的像素尺寸（不超过视频原始分辨率），窗口尺寸变化约 0.3 秒后重新 `setSize()`，不再按原始 4K 分辨率申请纹理。#81
- **消除播放时每 5 秒一次的卡顿**：定时保存进度只写记录、不通知监听者（`LocalStore.saveWatch(quiet: true)` / `PlaybackSession.saveProgress(quiet: true)`），被盖住的首页、详情、历史不再每次保存都整体重绘；换集、暂停、退出时照常刷新（`_savedQuietly` 标志保证 quiet 之后必定补刷一次）。
- **播控隐藏后进度条与时间不再刷新**：`player_surface.dart` 只在播控可见（或暂停 / 缓冲 / 未就绪）时监听 position / buffer 流，手机竖屏、横屏、平板、桌面与电视播放页共用这一层，隐藏后不再逐帧重建进度条。
- **降低弹幕耗电**：`danmaku_overlay.dart` 从「每帧重建整棵 widget 树」改成共用一个 `Ticker` 驱动 `ValueNotifier<double>`，由 `RenderProxyBox` 在 paint 阶段平移并裁剪窗口，界面树不再每帧重建。
- **下载记录多时降低后台开销**：核心侧新增 `snapshotSince(since)`，用 `sha256(任务 JSON)[:8]` 做指纹，列表没变化时只回一个指纹；Dart 侧 `NativeRepository.downloads()` 缓存上次解析结果，指纹未变直接复用，不再每 2 秒重新传输并解析全部记录。
- **亮色主题下播放页不再反复生成深色配色**：`playback_sheets.dart` 的 `playerTheme` 按源主题缓存生成的深色 `ThemeData`，主题没变就复用。
- **修复 Android 侧滑返回没有预览**：`motion.dart` 里的 `_FadeScalePageTransitionsBuilder` 在 Android 上接 `WidgetsBindingObserver.handleStartBackGesture`，拖动手势时页面跟手缩小 / 平移 / 露出上一页，松手淡出缩小完成返回，拖回则回弹；打开动画没播完也能侧滑。页面通过 `PageRoute.popGestureEnabled` / `isCurrent` 判断能不能接手势，不可返回时框架照常处理。
- **修复电视端「视频能播却反复切源，最后提示自动恢复未成功」**：`PlaybackSession` 的 900ms 错误复查原来要求「进度前进 300ms」才算自愈，但部分电视 / 硬解设备根本不上报 `position`（或起播几秒才发第一次），刚加载好的源因此被误判成故障，一次次切到备用线路，3 次后走到 `stop` 弹出「自动恢复未成功」。现在记录本轮是否收到过超过起播位置的进度：只有确认设备会上报进度、且进度确实停住了，才重新解析地址；真断流会进入缓冲或停止播放，仍照常自动恢复。
- **电视端按钮焦点更易辨认**：TV 主题里聚焦只叠 12% 的 `onSurface`，在已经是主色底的「播放」等实心按钮上几乎看不出颜色变化，遥控器移过去判断不了有没有选中。现在标准按钮聚焦时加主色描边与更明显的叠色，实心按钮直接反色（`onSurface` 底 + `surface` 图标文字）；非电视主题不变。

### 实现与约束
- **笔盒站源的取数与线路发现**：新增 `provider_beabox.go`。发布页的 `__ENC_DOMAINS` 是异或过的 base64 域名池、`__KEY` 是异或密钥，解析后按主机名白名单校验（https、无端口无路径）；接口返回的信封 `data` 是 `AES-128-CBC` 十六进制密文（固定 key + 前置 IV + PKCS#7），解码后才是业务 JSON。线路尝试顺序是「上次可用 → 内置线路 → 发布页发现」，发现结果 30 分钟内复用、失败 1 分钟后重试；站点状态写在 `<dataDir>/beabox-sites.json`，只接受 `https://host` 形式的地址，最多 256 条。
- **笔盒接入点**：`sourceBeabox` 常量与 `canonicalProviderSource` / `isHuangguoProviderSource`、`GetHuangguoDetail` 分发、`providerBaseURL`、`resolveBeaboxMedia`（播放地址解析）、`nativeCategories` / `validNativeCategory`、`app_cover_metadata`、`nativeCatalog`（分类 + 空列表不报错）、`nativeSourceSupportsSearch` / `nativeSearchSource`（在线搜索）逐处接入；Dart 侧只加一条 `SourceSite('beabox', '笔盒', ...)` 到 `restrictedValues`（默认关闭）与 `pagedSearch`。
- **笔盒封面是文本文件**：部分线路把封面存成 `.txt`，内容是异或 18 的 `data:image/...;base64` 文本。`app_covers.go` 的 `nativeDecodeCover` 增加 `nativeDecodeTextCover` 一步先试这类封面，失败再走原来的 AES / 异或兜底。
- **跨端一致**：本次改动只动 Flutter 与 Go 核心，本地服务版网页没有新增路由；侧滑返回、双指缩放、标签回顶这些手势只在前端实现，网页端不受影响。
- **未提交**：本轮改动全部留在工作区，未做 git 提交。

## 1.2.8+113

把 `一键写XBPQ源.py` 的站点探测算法移植进 Go 核心，给「新增自定义源」补上按网页 HTML 自动识别规则的能力。Flutter App 与本地服务版网页前端同步提供入口，Android / Windows / macOS / iOS / 本地服务版同步生效。原来的手工粘贴规则、MacCMS 运行时自动适配都保持不变。

### 改进
- **自定义源自动识别规则**：设置 › 自定义源 › 新增自定义源，填好网址后点「自动识别规则」，会依次抓取首页、分类页、搜索接口与详情页，反推 `分类url` / `分类`、`数组` / `标题` / `链接` / `图片` / `副标题`、`搜索url` 与搜索字段、`影片名称` / `简介`、`播放数组` / `线路数组` / `播放列表` / `播放标题` / `播放链接` / `跳转播放链接`，生成 XBPQ 规则 JSON 回填到规则框并自动切到「规则」模式。名称为空时用识别出的站名补上；下方显示诊断说明（命中站点预设、编码识别、列表字段实测抽样条数、识别失败原因等）。识别结果只回填表单，**不写盘**，是否保存仍由用户点「保存」决定，保存前可任意微调。
- **本地服务版同款入口**：网页前端新增自定义源弹窗里的「自动识别规则（抓取网页 HTML）」按钮，走新增的 `POST /api/custom-sources/analyze`，同样回填规则 / 名称 / 规则勾选并展示诊断信息；服务端 `customSourceAnalyze()` 通过 `core.NativeRequest` 调同一个 Go action，两端结果一致。

### 实现与约束
- 新增 `native/core/provider_site_analyzer.go`（抓取、预算、字段白名单、规则拼装、详情反推）与 `provider_site_analyzer_probe.go`（分类 URL 反推、列表 / 搜索 / 播放字段反推）。只移植 Python 脚本的站点分析算法，**不搬** TVBox / OK影视 的 py 源外壳、安卓 UI、落盘 / 剪贴板 / 一键配置接口，也不输出 jar 专属字段（`搜索模式`、`搜索后缀`、`链接前缀`、`嗅探词`、`图片代理`、`编码`、`站名` 等）。
- 输出字段受 `siteRuleKeyOrder` 白名单约束，且生成后必须过 `parseXBPQRule()` 校验，不通过就不写规则。**按 guoappxp 引擎语义做了关键适配**：`播放列表` 输出 `<li` / `<a` / `</a>` 这类**分集分隔符**（引擎内部是 `strings.Split`），绝不写成 `>&&</a>` 之类的 jar 截取串，否则整段分集会被塌成 1 集；JSON 搜索接口转成 `j:list` / `j:name` / `+j:id+` 这类引擎能消费的模式；列表数组与播放容器锚点都用真实 HTML 调 `xbpqList()` / `xbpqCutOnce()` 试截，截不出条目的字段**整组省略**，交给 `xbpqApplyTemplate()` 按 `分类url` 形态套模板家族兜底，避免写错字段覆盖模板备选链。GBK / GB2312 由 `xbpqDecodeBody()` 处理，不写 `编码` 字段。另有 `siteKnownRules` 站点预设（如 `dmdy3.com`），命中即直接套用实测规则。
- **识别不出就不生成坏规则**：抓不到首页、命中盾页 / 人机验证、SPA 前端渲染站（分类由 JS / 签名 API 加载）、未识别到分类链接、规则未通过解析校验时，返回 `mode: "网址"` 与空规则，保留普通网页源（引擎仍会自动适配 MacCMS 站点），用户也可以自己粘贴规则。诊断 `notes` 会说明具体原因。
- **安全预算**：分析器总预算 `siteAnalyzerBudget = 45s`、单次请求 `siteAnalyzerRequestTimeout = 4s`、最多 `siteAnalyzerMaxRequests = 26` 次请求；首页抓取会试手机 / 电脑 UA 与 http / https 兜底。Go 侧 RPC 超时给到 90s，Dart `_call()` 给到 100s，UI 期间按钮禁用并显示进度。抓取复用 `fetchProviderText()` + `xbpqDecodeBody()`，不新增网络栈。
- 接入点：Go `nativeDispatch()` 新增 `case "analyzeCustomSourceSite"`（`app_runtime.go`）；Dart `AppRepository.analyzeCustomSourceSite()` / `NativeRepository` override 与 `_call()` 超时（`core_bridge.dart`）；`custom_sources_view.dart` 的编辑器新增按钮、回填与诊断区；`native/server/main.go` 新增 `/api/custom-sources/analyze` handler，`native/server/web/app.js` 新增 `customSourceAnalyze()` 与按钮。`custom:` 前缀自定义源不受 `ALL_SOURCES` 变体限制，`nativeAuthorizeInput()` 对该 action 无需额外授权。权威持久化仍在 Go `custom_sources.json`，Dart `LocalStore` 只做镜像缓存，本次没有改动数据模型。

### 测试
- Go：新增 `provider_site_analyzer_test.go`，用 `httptest.NewServer` 搭本地 MacCMS 风格站点桩（首页分类导航 / 分类页影片卡片 / 详情页分集列表 / 搜索 JSON 接口），共 8 例覆盖分类 URL 反推、字段白名单、站点预设引擎兼容、JSON 键与盾页识别、RPC 接线、完整链路生成规则、盾页回落普通网页源、非法地址拒绝；断言 `分类url` 带 `{cateId}` / `{catePg}`、`搜索数组 == j:list`、`播放列表` 不含 `&&`、生成的 `数组` 用真实分类页能截出至少 2 条。全量 `go test ./... -count=1 -timeout 300s` 通过（core 20.9s），`go vet ./...`、`go build ./core ./server`、`gofmt -l` 通过。
- Dart：新增 `test/custom_source_analyze_test.dart`，用 `FakeRepository` 派生仓储覆盖「识别成功回填规则 / 名称 / 诊断并切到规则模式」「识别不出保留普通网页源」「识别失败显示错误并恢复按钮」3 例。`dart analyze lib test` 无问题，本轮改动文件通过 `dart format` 复检，`node --check native/server/web/app.js` 通过。全量 `flutter test --no-pub` **180 例全过**（`01:06 +180: All tests passed!`，含本次新增的 3 例）；收口后又补跑一次，结果一致。补跑用 `-j 1` 单并发并把输出重定向到日志文件，避免多份 `output.dill` 副本同时写入临时盘触发 errno 112。

> 未验证项：真实站点（尤其非 MacCMS 家族、需 Cookie / 签名 / 登录、Cloudflare 盾、SPA 站）的识别率、生成规则在真实站点上能否完整跑通分类 / 列表 / 详情 / 播放、`siteKnownRules` 预设站点当前可用性，以及本地服务版网页前端在浏览器里的实际交互，均需联网真机 / 真站验收。自动识别只做静态 HTML 反推，不执行站点 JS，也不解除任何源站授权限制。

## 1.2.7+112

把另一条分叉分支上的 6 项改动移植过来：真果鉴新增「黑桃 / 禁果短剧 / 禁果」三个站源、黄豆域名池与显示名修复、播放量为 0 时不显示、弹幕样式设置。仍然按功能最小合并，没有整仓覆盖——本分支独有的番茄源、直播、XBPQ / 自定义源、跨源聚合搜索、TV 播放器线路 / 选集、投屏、画质增强、青空账号链路与本地服务版全部保留。Android / Windows / macOS / iOS / 本地服务版同步生效。

### 改进
- **真果鉴新增站源「黑桃」**（`heitaodj.com`）：「全部」列出全站剧集，也可选站点分类，支持翻页、详情 / 分集与在线搜索。海报左下角照搬站点角标（如「6集」「完整版」），站点没给角标的剧看过详情后回落显示「共 N 集」。新增 `provider_heitao.go`，播放页取流用 `heitao://` 地址，`providerTextCookieKey{}` 给站点抓取附带 `heitao_age_confirmed=1` 年龄确认 Cookie；`Drama.Badge` / `nativeDrama.Badge` 贯通 Go ↔ Dart，`app_catalog_cache.go` 的 `mergeNativeDrama()` 保留旧角标，避免目录刷新冲掉站点角标。
- **真果鉴新增站源「禁果短剧」**（`jinguoduanju.app` 网页版，与同名「禁果」App 不是同一个产品，剧库不同）：目录、详情 / 分集、播放地址都走网页同一套 `/api/v1` 接口；可选推荐、热度、站点分类和题材，支持在线搜索与翻页。站点不分页，翻页时复用第一页取回的整份目录，不再每页重新下载。播放权限以站点接口返回为准（目前站点对会员 / 金币解锁剧集也直接放行），站点明确拒绝时提示需要会员或解锁，不会代为解锁。新增 `provider_jinguoduanju.go` / `provider_jinguoduanju_client.go` / `provider_jinguoduanju_test.go`，`jinguoDuanjuContentSite()` 负责 `jinguoduanju.app` / `jgdj.app` 线路。
- **真果鉴新增站源「禁果」**（禁果短剧 App，`com.hgaidj.ozThree`）：与黄果旧版是同一套后台的另一个部署、剧库不同。可选精选、最新和站点分类，支持在线搜索与翻页；访客会话自动注册并保存在本机，失效后自动重新登录；主线路不可用时自动切到同一部署的备用线路。付费集（需金币 / 会员）在分集列表标 VIP，播放时提示需要解锁，不代为解锁，也不会播放站点给未解锁分集的广告片花。新增 `provider_jinguo.go` / `provider_jinguo_client.go` / `provider_jinguo_test.go`，客户端用 `sync.Once` 缓存会话。站点不少剧本身只有 1 集。
- **弹幕样式设置（#74）**：入口在播放页 ›「播放设置」›「弹幕样式」（`ExpansionTile`），以及设置里新增的「弹幕」分组。字号改为 60%～200% 连续可调（`danmakuScaleMin = .6` / `danmakuScaleMax = 2.0`），原来的小 / 标准 / 大 / 特大档位照常生效（渲染仍走 `MediaQuery.textScalerOf(context)`，新 `scale` 是相对倍率）；另可调颜色、透明度、加粗、描边、阴影，以及 `DanmakuCoverage` 三档显示区域（顶部四分之一 / 一半 / 全部），改动立即生效。新增 `danmaku_style.dart`、`ui/player/danmaku_settings.dart`、`ui/widgets/slider_tile.dart`，`danmaku_overlay.dart` 按 `style` 计算字号、行数与描边 / 阴影双层文字；四个播放器页面（横屏、竖屏、TV、`PlayerSurface`）都把 `session.danmakuStyle` 传给 `DanmakuOverlay`。屏蔽词链路一并补齐：`normalizeDanmakuWords()` 规范化、`DanmakuController.setBlockedWords()` 过滤、`blockedCount` 在无弹幕但有屏蔽时显示「这段弹幕都被屏蔽了」，`PlaybackSession` 在初始化、存档变更与 `dispose()` 时同步。`playback_preferences.dart` 合并了新弹幕字段与本分支独有的 `adBlock` / `VideoEnhancementPreferences enhancement`，旧 JSON 自动回退默认值、越界值 clamp。

### 修复
- **黄豆站源打不开（#76）**：站点换了域名，原来写死的主域名 `tideember.cc` 已解析不到，唯一写死的备用 `xqjurgek.top` 证书过期且域名对不上，所以每次换线必然失败。`provider_huangdou.go` 改用当前可用域名池 `ferncider.cc` / `onyxripple.cc` / `reeflumen.cc` / `niniharbor.top` / `halomeadow.top` / `larksummit.icu`，主线路连不上按顺序换下一个、全部换完才报错；换域名属于换目标，`backoff = 0` 不再空等重试间隔，超时预算按剩余域名数分配。`providerSourceForURL()` / `nativeCoverReferer()` 改为 `isHuangdouHost()` 判断，封面 referer 跟随域名池当前域名。站点显示名由域名改为「黄豆」。
- **黄豆自制剧详情显示「播放 0」**：站点不给这类剧提供播放量，`detail_page.dart` 的统计行改为 `drama.views.isNotEmpty && drama.views != '0'` 才显示，其余站源同样处理。

### 接入与约束
- 三个新站源在 `SourceSite.restrictedValues` 中，默认关闭（`SourceSite.isRestricted(id)` + `LocalStore.sourceEnabled()` 默认 `!isRestricted`），红果鉴的 `SourceSite.values = [hongguo, fanqie]` 不变，因此只在真果鉴出现；开启后才进入目录、分类、详情与「全部源」聚合搜索。
- Go 侧接入点：`models.go`（`Drama.Badge`）、`provider_huangguo.go`（源常量、`isHuangguoProviderSource()`、`canonicalProviderSource()` 域名识别、`GetHuangguoDetail()` 分发）、`provider_web.go`（`providerTextCookieKey`）、`provider_media.go`（URL 基址 / 反查源 / 取流分发）、`app_categories.go`、`app_cover_metadata.go`、`app_runtime.go`（`JinguoDuanjuURL` / `HeitaoURL` 配置、client 缓存、`nativeDrama.Badge`、目录与详情分支）、`app_catalog_cache.go`、`app_search_across.go`（本分支独有的跨源聚合搜索增量接入 3 个源）。Dart 侧 `models.dart` 新增 `badge` / `score` 并保留 B 独有的 `peers`，`pagedSearch` 补上 4 个源。
- 付费 / VIP 集只提示、不代解锁；不分页站点的翻页复用第一页数据；换域名不算重试、不空等间隔。

### 测试
- Go：新增 `provider_jinguo_test.go`、`provider_jinguoduanju_test.go`、`provider_huangdou_domain_test.go`（域名池换线、不空等重试间隔、超时预算、封面 referer 跟随域名池）。定向 `go test ./core -run 'Heitao|Jinguo|Huangdou'` 通过，全量 `go test ./...` 通过（core 27.8s），`go vet ./...` 通过。
- Dart：新增 `test/playback_preferences_test.dart`（旧 JSON 回退、弹幕字段 round trip、越界 clamp、屏蔽词规范化、非法 speed 抛异常，5 例）与 `test/new_sources_and_danmaku_test.dart`（三个源默认关闭且支持在线搜索、`badge` / `score` JSON 与 merge、`DanmakuStyle.of()` 与三档 coverage、设置页包含全部可调项，4 例）。`dart analyze lib test` 无问题，全量 `flutter test --no-pub` 177 例全过，本轮改动文件通过 `gofmt` / `dart format`。

> 未验证项：黑桃 / 禁果短剧 / 禁果的真实站点可用性、禁果 App 访客会话与备用线路、黄豆 6 个域名的真实访问、VIP 付费集提示、弹幕样式在真机 TV / 横竖屏 / Windows 上的实际观感，均需在联网真机上验收。

## 1.2.6+111

把另一条分叉分支上的 10 项改动整体移植过来（青空登录、大屏缩放、野果 / 黄果 AI 接口改版、红果设备注册门禁、包名统一、Windows 辅助功能、Flutter 3.47.9、音量记忆）。合并时保留了本分支独有的番茄源、直播、XBPQ / 自定义源、TV 播放器线路 / 选集、投屏与本地服务版等能力，没有整仓覆盖。Android / Windows / macOS / iOS / 本地服务版同步生效。

> ⚠️ **包名已更换**：红果鉴 `com.guoapp.phoenix`、真果鉴 `com.guoapp.all`（Android / iPhone / iPad / macOS 统一）。旧版 `com.duanju.*` 不会被识别为同一个应用，需要手动卸载旧版再装；原有设置、追剧、观看与下载记录不会自动迁移。两个变体现在可以同时安装。

### 改进
- **青空次元登录后才能播放**：设置 › 站源新增「站源账号」，可用用户名或邮箱 + 密码登录，先拖动滑块完成安全验证，没有账号可点链接到浏览器注册。登录状态写在本机 `sorani-session.json`，访问令牌过期前用 refresh token 自动续期。登录状态对这台设备上的所有用户生效，登录 / 退出不限制管理员身份。`nativeInput.account` 新增 `soraniAccount` RPC（status / captcha / login / logout），Go 侧取流时带 `Authorization: Bearer`，接口明确要求登录时返回 `source_login` 错误码，播放页原来的「重试」变成「去登录」，登录成功自动重新取流播放。电视上可用遥控器左右键移动拼图块、确定键验证；输入用户名按「完成」或回车直接跳到密码框，进入账号页焦点落在青空账号上，退出登录后焦点不丢。Android 输入法桥补上 `password` / `url` / `maxLength` / `IME_ACTION_DONE` 参数，密码框不再显示明文、回车键显示「完成」。
- **4K~6K 大屏整体缩放（#73）**：Android 逻辑短边超过 `1000dp` 时，`attachBaseContext()` 用 `createConfigurationContext` 把 `densityDpi` 等比放大到接近平板尺寸（`TARGET_CANVAS_DP = 720`），布局仍按平板 / 电视排列；手机、平板不受影响。Manifest 的 `configChanges` 补 `density|uiMode`，保证运行中切换深色模式、字体大小、语言时不会重建 Activity 丢掉缩放。已在模拟大屏验证，未上真实车机 / 电视。
- **黄果 AI 改用站点接口**：分类列表、详情与分集、播放地址、热播 / 推荐 / 潜力榜都改读站点 `/api/edge/request` 包装的接口数据，不再解析 HTML；搜索改为在线全站搜索并支持翻页。已有追剧 / 下载记录照常可用。新增 `provider_huangguo_api.go` 统一封装 envelope（`method` / `path` / `body` / `content_type`），`fetchProviderRequest` 支持 POST JSON；`app_categories.go` / `app_cover_metadata.go` / `provider_rankings.go` / `provider_media.go` / `app_search_across.go` 分别接入，同时保留本分支独有的跨源聚合搜索分发。
- **黄果 AI 新线路（#7）**：主线路之外新增 `lbvrhyir.cc`、`xxbgwypx.cc`，与 `ediayikma.cc`、`agdkczeyx.cc` 一起组成镜像域名池；`providerURLCandidates()` 主站连不上时依次换线，随机备用线路在这几个域名间轮换，不再只用一个域名。这是开发快照里的改动，未在 App 内对真实站点验证。
- **Windows 辅助功能闪退（#67）**：`flutter_window.cpp` 用 `SetWindowSubclass` 拦下 `WM_GETOBJECT` 并交给 `DefWindowProc`，不再向输入法 / 划词翻译 / 读屏软件提供应用内控件信息，只能读到窗口本身；链接 `comctl32.lib`。各平台播放器的进度条 / 音量条统一改用 `ContainedSlider`（单一规范 `Semantics(slider: true)` + 内层 `ExcludeSemantics`），不再打乱系统辅助功能信息。
- **升级 Flutter 3.47.9**：CI 的 `flutter-version` 与本地 SDK 保持一致；HTTPS 不再信任已被攻破的 eMudhra 中间证书，Android 14+ 改用系统可更新根证书库，并带上官方修复的 Windows 正式版卡死问题。`ffmpeg_kit_flutter_new_min_gpl` 同步 `2.6.2` → `2.6.7`（`pubspec.lock` 的 sha256 一并更新）。
- **包名统一**：`BuildVariant.bundle_identifier` 成为单一来源，Android `applicationId` / `namespace`、iOS `AppVariant.xcconfig` + `Info.plist` 的 `$(APP_DISPLAY_NAME)`、macOS `AppInfo.xcconfig`、Windows `Runner.rc` 与打包脚本全部对齐到 `com.guoapp.phoenix` / `com.guoapp.all`；iPhone / iPad 上真果鉴桌面名称不再显示「红果鉴」。Kotlin 源码迁到 `com/guoapp/`，方法通道名（`duanju/cast`、`duanju/text_input`）保持不变，B 独有的 `FanqieEngine` / `libfanqie_shim.so` / `GeneratedPluginRegistrant` 引用保留。

### 修复
- **野果站点改版（#3）**：站点把接口地址写进脚本（「当前线路下的接口地址取数据」），新增 `yeguoScriptAPIBase()` 从脚本里按当前页面 origin 解析，不再只认固定 API 域名。线路改为 `attract.vgbyziuz.cc` → `as.vgbyziuz.cc` → `anyway.vgbyziuz.cc`，原 `analyze.buxefaex.cc` 留作最后备用，主线路连不上依次切换。
- **红果取流与设备注册**：去掉已失效的第三方备用取流接口，App 与网页两条取流都失败时直接报错，不再多等一次请求，报错里也不会再出现备用接口的连接错误。设备注册遇到网络波动 / 超时不再锁 10 分钟，下次请求直接重试；只有服务端明确拒绝注册时才暂停，并把被拒绝的原因带进提示。
- **首次启动设备门禁**：关掉检查更新提示后先弹「正在注册设备...」，红果主设备与辅助设备都注册成功才自动关闭，之后才加载推荐；失败时显示原因，可「重试」或「网络设置」改代理，不能跳过。已注册过的设备直接进；旧版升级后弹一次，只补注册辅助设备。`hongguoDevices` RPC（`command: register` 表示用户显式重试、忽略暂停窗口）与 `HelperRegistered` 状态一并落地。
- **播放器记住上次的音量（#61）**：电脑和手机全屏播放时调过的音量存到本机 `playerVolume`，换剧 / 重启后不再跳回 100%；写入做 500ms 防抖、`dispose()` 时补写。静音（0）不记档，下次恢复到 1% 而不是无声。电视与手机滑动调的是本次观看的临时音量（对应系统媒体音量），走 `setVolume(..., persist: false)`，不写存档。
- **青空播放报错**：未登录 / 登录失效不再笼统提示「暂无可用播放地址」，直接给出「需要登录 / 登录已失效」并引导去登录。

### 测试
- Go：`provider_sorani_account_test.go`（登录、滑块校验、自动续期、过期与退出）、`provider_huangguo_api_test.go`（线路覆盖、详情 / 取流走 edge envelope、搜索翻页）、`app_hongguo_devices_test.go`（双设备注册持久化、升级只补辅助设备、显式重试忽略暂停）、`provider_yeguo_client_test.go`（当前线路脚本识别、备用线路切换）。同时把 `app_cache_test.go` / `app_catalog_persistence_test.go` / `app_sources_test.go` 的 HTTP 桩改成解析 edge envelope 与 `{"status":1,"data":...}` 响应，避免新接口打到旧桩上。
- Dart：`test/playback_session_test.dart` 补音量记忆 4 例与 `source_login` 失败态 1 例（合计 34 例全通过），`test/local_store_test.dart` 补 `playerVolume` 存取（25 例全通过），`test/sorani_account_access_test.dart` 锁定「站源账号页不限制管理员、登录入口对所有用户可用」与「电视进入账号页焦点落在青空账号、退出登录后焦点不丢」；`TileFocus` / `SettingsTile` 新增仅电视模式生效的 `autofocus`，只有青空账号行使用，其它设置行不受影响。`dart analyze lib test` 无问题，全量 `flutter test --no-pub` 168 例全过，`go test ./...` / `go vet ./...` 通过。

## 1.2.5+110

本次补齐 Android TV / Windows TV 播放器的「线路」与「选集」入口，并修掉电视端明明已经加载成功却反复重新解析地址、最后判定播放失败的问题，Android / Windows / macOS / iOS / 本地服务版同步生效。

### 改进
- **电视播放器控制条新增「选集」与「线路 N/M」**：此前 TV 控制条只有上一集 / 播放 / 下一集、弹幕、去广告、倍速、清晰度，既没有线路切换也没有选集按钮，遇到坏线路只能等自动恢复。现在按「选集」打开右侧抽屉（按固定列数排布、当前集高亮、VIP 标记，遥控器左右一集 / 上下一行，确认键选集，返回键关闭），按「线路」打开菜单（上下换线路、左右按页翻、超出高度自动滚动，选中项自动滚进视野）；单线路也能打开确认状态。两个入口只在主动打开时出现，不占播放画面的常驻空间。
- 顺手修掉「去广告」按钮虽然在控制条上、却没登记进遥控器焦点顺序（也一直被判为禁用）的老问题；现在控制条所有按钮都能用左右键依次走到，上键回进度条、下键回按钮。

### 修复
- **播放成功后反复重试加载**：自动恢复的 900 毫秒观察窗口原本要求 `PlayerState.width > 0` 才认为「播放器已自愈」，但电视 / 硬件解码常常不上报视频尺寸，于是一次可忽略的播放器报错也会被当成致命错误，重新解析地址、重新 open；几次之后达到恢复上限就弹「自动恢复未成功」。现在只按「仍在播放、未在缓冲、进度确实前进」判定，与视频尺寸无关。
- 进度看门狗在缓冲中不再累计卡死时长：缓冲时进度本来就不动，旧逻辑会在缓冲结束后把这段时间算进 stalled 并触发一次无谓重载。`PlaybackHealth.stalled` 新增 `buffering` 参数，缓冲时重置计时；同时只有真正收到过进度变化的播放器才启用卡死判定——部分电视设备压根不发 `position` 事件，没有可信进度就不该反复重载。
- 电视端全屏切换 / 系统弹层 / 遥控器焦点变化会让 App 瞬间 `inactive`，旧代码立刻按「进入后台」暂停并清掉播放意图，回到前台后看门狗又把「被我们自己暂停的正常播放」判成卡死。现在 TV 生命周期与横屏 / 桌面一致（Windows 的 `inactive` 仍算前台），并对进入后台加 600 毫秒防抖；`PlaybackSession.setForeground` 只记录「系统让我们停的」，回到前台自动续播，用户手动暂停的情况保持暂停。

### 测试
- 新增 `test/television_player_page_test.dart`：控制条同时有线路与选集且方向键能依次到达、线路菜单列出并切换、选集抽屉方向键移动与点选、短暂失焦不打断播放（共 4 个 widget 用例）。为在无原生纹理的测试环境里渲染电视播放器，`TelevisionPlayerPage` 增加仅供测试的可选 `videoSurface` 替身。
- `test/playback_session_test.dart` 新增 4 个用例：无视频尺寸但画面继续前进时不重载、短暂后台切换不重载地续播、手动暂停跨后台仍保持暂停、缓冲重置看门狗计时。原有「真错误仍切备用线路」等恢复用例保持通过。

## 1.2.4+109

本次修复网页源 / XBPQ 自定义源 / 爱看机器人 / A123 在播放页与详情页看不到剧集详情，并给竖屏播放器补上「简介」入口，Android / Windows / macOS / iOS / 本地服务版同步生效。

### 改进
- **竖屏播放器也能看剧集简介，且不打断全屏观看**：不新增任何常驻控件，底部原有的「选集」条文案改为「选集 · 简介」，点开后仍是同一个 60% 高度的底部面板，只把两个页签（选集 / 简介）放进原有标题行——面板高度、播放层、上下滑切集、长按亮度 / 2 倍速手势一律没动，面板只在主动点开时出现。`_EpisodeSheet` 抽成公共 `PlaybackDetailsSheet`（支持 `initialTab`、切页签时清掉下载多选态），横屏 `_intro` 抽成公共 `PlayerIntro`，横竖屏共用同一份简介渲染（片名、站源、集数、分类、追剧按钮、剧情简介，无简介显示「暂无简介」）。新增 `test/playback_details_sheet_test.dart` 4 个 widget 用例覆盖默认页签、简介内容 / 空简介、直接打开简介、下载入口只属于选集页。

### 修复
- `nativeDetail` 的 default 分支（网页源 / XBPQ 自定义源 / 爱看机器人 / A123 / 短剧家族 / 红果 / 黄豆）原先只从 `GetHuangguoChapters` 取标题，详情层已解析好的简介、封面、类型、标签全部丢弃，导致详情页简介区整块不渲染、横屏播放器「简介」Tab 显示「暂无简介」。`provider_huangguo.go` 新增 `GetHuangguoDetail` 统一返回完整 `Drama`（`GetHuangguoChapters` 变成它的薄封装，取流侧行为不变），`nativeDetail` 把它合并进返回结果；XBPQ 规则的「简介 / 影片名称 / 封面 / 类型 / 导演 / 主演」由此能一路传到播放器显示。`fetchA123Detail` 另补详情正文 / `meta description` 的简介兜底（解析不到就留空，不拿站点口号冒充剧情）。新增 4 个 Go 回归用例覆盖网页源详情透传、爱看机器人简介透传、XBPQ「简介」字段落到 `Drama.Desc`、A123 简介提取；`ikanbotSiteBaseURL` 由常量改为变量，便于用本地样本站点做回归。

## 1.2.3+108

本次把首页默认站源恢复为红果，并带上安卓番茄播放与电视端顶栏焦点两处修复，Android / Windows / macOS / iOS / 本地服务版同步生效。

### 改进
- **红果鉴只保留红果 + 番茄两个内置源：红果是首页默认（主）站源，番茄仅作为内置源**。此前加入番茄时把它放在 `SourceSite.primaryValues` / `values` 的第一位，而 `LocalStore.source` 在没有存档时回落到「源列表第一个」，于是首页开场静默变成了番茄（也连累 6 个以红果为前提的首页测试失败）。现在两处清单都改成红果在前，并新增显式常量 `SourceSite.defaultSource`：`LocalStore.source` 优先取它，只有该源被用户在站源管理里关掉、或用户已保存过其它选择时才用别的源。用户手动切到番茄的选择照旧保留；番茄仍可在「全部站源」里切换、在站源管理里开关、参与「全部源」搜索。真果鉴（`--dart-define=ALL_SOURCES=true`）仍带全部站源，同样以红果开场。站源裁剪与本地服务版冒烟自检（`红果鉴 == {hongguo, fanqie}`）不变。

### 修复
- 安卓端番茄源「暂时无法播放 / 番茄内容引擎未就绪」：真机上引擎 `/health` 返回 200、Dart 直连也通，只有 Go 侧的统一传输（浏览器指纹 + CDN 择优 + 系统代理 + 连接池 + 限速重试）在进程内环境失败。`provider_fanqie.go` 新增 `fanqieLocalClient`（不查代理、`DisableKeepAlives`、5s 拨号 / 30s 总超时）与 `fanqieDirectText`；`fanqieFetchText` 先走统一传输，失败后直连重试一次，成功则用 `fanqieDirectPreferred` 记住「优先直连」，两条都失败时把两侧原始错误一起抛出。Dart 侧 `describeNow()` 现查端口与 `/health`，无论是否 200 都附 `fanqie_engine.log` 最后一行（Rust panic 只写这里，安卓无 logcat）；提示文案保留 Go 原始错误并带上失败的 `action`。
- 电视端顶栏遥控器走不到右上角「切换站源」「搜索」：原 `_televisionHeader()` 只在发现页渲染 `SourceBar`，焦点右移触发 `_followFocus` 切页后按钮就从树里消失。现在 TV 顶栏常驻，宿主持有 `_sourceFocus` / `_searchFocus`，顶栏接管左右键按「发现 → 追剧 → 我的 → 源 → 搜索」确定性移动，两端吃掉按键；新增 `_exitUpToHeader()`，从内容区按上键按水平中心就近回到当前标签 / 源 / 搜索。`bar_button.dart` / `source_bar.dart` 增加可选 `focusNode` 透传。Android TV 与 Windows TV 共用 `AppShell`，两端同时生效。

### 测试
- 新增 `test/app_shell_tv_focus_test.dart`（3 个 widget 用例：切页后按钮常驻、右键顺序、从内容连按上键回顶栏）与 `test/local_store_access_test.dart` 的「红果是首页默认站源，番茄仅作为可切换的内置源」；新增 4 个 Go 用例覆盖直连兜底、非 2xx、绕过代理。更新 `explore_feed_test.dart` 中「关掉红果后落到番茄」的旧断言（原先假设红果鉴关掉红果就无源），并修正 `local_store_access_test.dart` 的源清单顺序、`search_page_test.dart` 的注释。

## 1.2.2+107

本次只改出包流程，运行时代码零改动；Android / Windows / macOS / iOS / 本地服务版的行为与 1.2.1 完全一致。

### 修复
- 修复 iOS 构建失败 `Lexical or Preprocessor Issue (Xcode): 'ffmpegkit/FFmpegKitConfig.h' file not found`（`ffmpeg_kit_flutter_new_min_gpl/Sources/.../FFmpegKitFlutterPlugin.m:21`）。这个插件的 8 个预编译框架不在 pub 包里，而是由插件 podspec 的 `prepare_command` 在 `pod install` 时从 GitHub release 下载；而 `prepare_command` 只在「这个 pod 确实需要安装」时才执行——CI 把 `ios/Pods` 作为缓存还原、`Podfile.lock` 与已装清单一致时，CocoaPods 判定插件早就装好，直接跳过下载（日志里那次 `pod install` 只花 1.7 秒、没有任何 `Installing ...` 行），框架其实不在（它落在 pub 缓存里，与 `ios/Pods` 是两份独立缓存），于是 26 秒的 Xcode build 之后才在编译期报头文件找不到。macOS job 没有 Pods 缓存，所以现象上「只有 iOS 坏」。

### 改进
- 新增 `scripts/ffmpeg_frameworks.py`：出包前显式检查并准备 iOS / macOS 的 ffmpeg 原生框架，不再依赖 `pod install` 的副作用。下载失败会按 GitHub 直连 → `cfkua.wokaotianshi.eu.org` → `ghfast.top` → `gh-proxy.com` 的顺序换镜像重试，全部失败时直接以明确文案中止（而不是拖到编译期报头文件缺失）；八份框架逐项校验齐全才算装好。`build_ios.py`、`build_macos.py` 在 `pod install` 之前调用它。
- 两个 `Podfile` 增加 `pre_install` 钩子：生成 Pods 工程前再检查一次框架，因此单独执行 `pod install`、或在 Xcode 里直接构建也不会漏（幂等，框架已在则立即返回）。下载失败时抛的是可读的中文错误，并提示用 `FFMPEG_KIT_IOS_URL` / `FFMPEG_KIT_MACOS_URL` 指定镜像。
- 旧 `ios/Pods` / `macos/Pods` 若是「框架还缺失」时生成的，其 `FRAMEWORK_SEARCH_PATHS` 里不会有 ffmpegkit，事后补框架也没用：现在检测到这种情况会丢掉该 `Pods` 目录让 `pod install` 重新生成，避免继续沿用坏工程。
- `build_macos.py` 的 `package_path()` 挪进 `ffmpeg_frameworks.py` 共用（顺带修正 `file://` 前缀裁剪后 Windows 路径丢盘符的问题）。

### 出包减量
- 手动触发新增 `full_variants` 开关，`with_ios` / `with_macos` 改为**默认关闭**：日常发版一个 macOS 分钟都不花，只出 Android / Windows / 网页版；需要 IPA 勾 `with_ios`、需要 dmg 勾 `with_macos`（单平台单变体约 20 分钟墙钟 ≈ 200 账单分钟，正好是 Free 账号一个月的 macOS 额度），要红果鉴那套再加勾 `full_variants`（全勾约四倍开销）。只出单套包时 Release 说明会自动注明「本次只出了真果鉴」，不会让人以为包漏发。
- `ios` / `macos` 两个 job 的超时从 120 分钟压到 60 分钟：真卡住时最坏 600 账单分钟而不是 1200。
- 工作流打开 `concurrency.cancel-in-progress`：上一轮还卡在等 macOS runner 时，重新触发会直接取消旧运行，不再出现「新运行一直 pending、job 一个都不出现」的假象。

## 1.2.1+106

本次修复搜索相关的三处问题，Android / Windows / macOS / iOS / 本地服务版同步生效。

### 修复
- 修复桌面端搜索页看不到「全部源」开关：显示条件原先写死成「构建带 `ALL_SOURCES` 且已开启站源多于一个」，窗口模式下经常算不出多个站源，同一份安装包切到电视模式反而能看到，看上去就像跨源搜索被删了。现在只看构建能力或实际可搜站源数（`allSourcesEnabled || 站源数 > 1`）：真果鉴必定显示，红果鉴导入自定义源后也能跨源搜。开关只是入口，跨源本身一直按实际站源列表发起，不受影响。
- 修复 Windows / macOS 切到「电视」界面模式后搜索框点不开、输入没有任何反应：电视分支用的是 Android 的原生隐藏输入框（`NativeTextInput`），桌面端没有这条通道，点一下什么都不会发生。现在只有 Android 才走原生输入法，桌面端无论哪种界面模式都用普通输入框。
- 桌面端输入拼音首字母会弹出候选剧名：在搜索框敲 `BDZC` 时，先从追剧、观看记录、最近搜索里按原文 / 拼音首字母匹配（最多 8 条，分组显示「本地匹配（原文 / 拼音首字母）」），点一条即用完整标题去搜，站源建议接在下面。站源搜索接口只认原文，纯字母串发过去必然空手而归，所以拼音只能靠本地这几处索引。电视端字母键盘的候选也改成「本地拼音匹配 + 站源建议」合并，原先只查站源接口，敲拼音首字母基本返回空。

## 1.2.0+105

本次为电视端交互与平台支持更新，Android / Windows / macOS / iOS / 本地服务版同步生效。

### 新增
- 支持 macOS（Apple Silicon 与 Intel 通用包）：新增 `macos/` 工程与 `DuanjuCore` pod，Go 核心按 arm64 / x86_64 两片编成静态库再 `lipo` 成通用库、以 `DynamicLibrary.process()` 取符号（与 iOS 同一套做法），出包为 `*-macos-universal.dmg`（带拖拽安装布局、ad-hoc 签名并逐项验签：架构、FFI 入口、必需框架、dmg 内的应用与 Applications 快捷方式）。系统代理探测走 `CFNetworkCopySystemProxySettings`，界面按桌面形态（侧边栏 + 宽屏）工作。CI 新增 `macos` job（可用 `with_macos` 开关关闭），失败或被跳过不阻塞其它平台发布。
- 电视端搜索框改由原生输入框唤起系统输入法：Flutter 的 `TextField` 在部分电视（小米等）上按确认键唤不出输入法，现在用 1×1 隐藏 `EditText` 拉起键盘，输入过程中实时回传给 Dart 侧，确认键即提交、返回键即取消并收起键盘；手机 / 桌面端仍用原来的 `TextField`。
- 新增设置「搜索用字母键盘」（仅电视端显示）：开启后按确认键弹出内置 A-Z + 数字键盘，可按拼音首字母输入，右侧实时列出匹配条目，选中即搜索。默认关闭，用系统输入法。
- 追剧、观看记录、站源搜索都支持拼音首字母：`霸道总裁` 用 `BDZC` 即可命中（原文子串匹配仍然优先，拼音只是兜底）。
- 本地服务版（网页端）的收藏夹 / 播放记录支持拼音首字母搜索：这两个列表原先只能按剧名子串找，现在输入 `BDZC` 也能命中《霸道总裁》。首字母表由 `tool/gen_pinyin_table.dart` 用 lpinyin 生成成 `native/server/web/pinyin.js`（20992 个码位，约 21 KB）随包发出，网页端离线可用，同份字典与 App 的 `matchesTitle` 一致；搜索框旁会显示「匹配 N / M」，编辑态下的「全选」只覆盖过滤后可见的条目。

### 适配
- 首页按返回键不再直接退出应用：先提示「再按一次返回退出应用」，2 秒内再按一次才真正退出，避免遥控器 / 键盘按错一下就关掉。非首页、以及有子页面时行为不变（先返回上一层）。
- 本地服务版的出包流程加上冒烟自检（`scripts/check_web.py`，CI 的 `web` job 在 `build_web.py` 之后执行）：把两个版本的二进制实际启动，检查主页能打开、`go:embed` 的网页资源与仓库里的 `native/server/web` 逐字节一致（改了前端忘了重新编译会被抓住）、站源裁剪确实生效（红果鉴只有红果）、`/api/request` 等接口不返回 500、非法请求不会把进程打挂。任何一项不过就让 job 红掉，不再等用户解压之后才发现打不开。

## 1.1.2+104

本次为移动端适配与稳定性修复版本，Android / Windows / iOS / 本地服务版同步生效。

### 新增
- 补齐短剧家族内置源：芽果、猫果、饭果、观果、河果、星果、花果、牛果、网果、发果、伍果共 11 个源在「全剧视界」版可用（与 Go 侧 `duanjuProviderCatalog` 一一对齐）。原生核心本就已实现这些源的目录、搜索、详情与播放解析，缺的是 Dart 侧 `SourceSite` 未声明，导致站源管理、发现、搜索、追剧、观看记录、下载和用户权限里都看不到它们；本次补上 `duanjuValues` 及 `duanjuOnlineSearch` / `duanjuPaged` 能力判断。
- 播放器「播放设置」里新增播放线路（线路切换）：同一集有多条可用线路时，可逐条切换且保留当前进度。原生核心补齐 `selectRoute` 指令与 `nativeSelectRoute`，Dart 侧 `AppRepository` / `PlaybackLoader` / `PlaybackSession` 打通 `selectRoute`，播放设置面板在清晰度下方按线路数量渲染「线路 N」选项。
- Android 端新增 DLNA 投屏（移植自 V影 1.3.2 的投屏实现）：播放设置里多了「投屏」，搜索同一 Wi-Fi 下的电视 / 盒子 / 投影仪，选中即把当前集从当前进度投过去，面板里能暂停、继续、停止。核心为此把播放会话再挂一份到 `0.0.0.0` 并返回手机内网地址（电视拿不到手机的 `127.0.0.1`），播放列表里写回的分片地址改按请求 Host 生成，停止投屏即关掉该端口；投屏期间持有部分唤醒锁，屏幕熄灭也不会断流。本地下载的文件暂不支持投屏。

### 修复
- 修复桌面版播放器「播放线路」弹层点了完全没反应：分列排布时每列的 `Column` 用了 `CrossAxisAlignment.stretch`，而弹层挂在 `Positioned(left/top)` 上、拿到的宽度约束是无界的，stretch 会把每个格子撑成 `tightFor(width: ∞)`，整块弹层布局失败又不报错（release 下连断言都没有），表现为悬停/点击都没反应；只有一条线路或单列的清晰度、倍速不受影响。现在列宽用 `SizedBox` 钉死，并把选项网格抽成独立的 `OptionGrid` widget，补了按弹层真实条件（`Positioned` + 无界约束）挂载的 widget 测试，先用旧写法确认它会红。
- 修复切换集数、换清晰度后播放线路跳回第 1 条：现在会记住当前选中的线路，下一集继续用它，只有这一集没有这条线路时才改走别的线路（并在播放日志里注明「第 N 集没有线路 X，改用线路 Y/Z」）；手动切线、自动换备线之后也以实际生效的线路为准，不再每集重新跳一遍。核心 `resolve` / `preload` 支持传入线路序号（`nativeChoosePlayback` + 既有 `nativePreferredRoute`），Dart 侧 `PlaybackSession` 记住已选线路，预加载下一集时也用同一条线路，避免预载好的下一集与当前线路不一致。
- 投屏不再依赖手机：投屏时优先把站源返回的原始播放地址直接交给电视，电视自己上网拉流，投屏后可以退出 App、切后台或锁屏，电视上的播放不受影响，也不再占用手机上行带宽，转发模式的唤醒锁也不再无谓占用。现在只把真正解不开的 CENC 加密线路退回手机转发——播放列表被本机重写过、HLS AES-128 也都直接投原始地址，电视自己取清单和密钥，面板会明确标注「经手机转发，请留在 App」；直连被个别盒子拒绝时自动回退转发，投屏后电视实际播不出来还可一键「改用手机转发」；反过来，正在转发时也能一键「改用电视直连（可退出 App）」。原生核心在播放计划里新增 `directUrl`（仅可直连时非空），`PlaybackPlan` / `PlaybackSession` 一并透出。
- 修复 Android 端投屏能搜到设备却提示「当前没有可用的局域网地址，请先连接 Wi-Fi」：核心原先用 `net.Interfaces()` 枚举网卡来算投屏地址，部分机型 / 系统版本上枚举不到（SSDP 能搜到设备说明局域网其实是通的）。现在改为优先「朝电视地址连一个 UDP socket，再读内核选中的本地地址」——只依赖路由表、不发包，也不依赖网卡枚举；拿到候选地址后还会自连一次确认它确实属于本机网卡，避免把流量卡的地址当成 Wi-Fi 地址返回。投屏请求同时把电视地址一起传给核心（`peer`）用于选路。
- 修复爱看机器人（ikanbot）海报全部显示不出来：它的封面直接指向豆瓣图床（`imgN.doubanio.com`），豆瓣按 Referer 防盗链，缺 Referer 的请求全部返回 HTTP 403 或一张默认图；核心现在对该域名统一补豆瓣 Referer。另外豆瓣还会按 TLS 指纹做风控——即使 Referer 正确，标准 Go 传输拿到的仍是一段反爬脚本，此时自动换浏览器指纹传输重试一次（仅限 https）。本机实测同一页 24 张海报从 0/24 变 24/24 成功。
- 修复部分网页站点播报 `tls: failed to verify certificate: x509`（Android 端最多见）：以 FFI 嵌入时 Go 的 crypto/tls 不加载系统信任库，`SystemCertPool()` 为空，站源换成小众公共根证书后握手就失败。核心的传输现在使用「系统信任库 + 随包 CA 全集」作为信任锚（其他平台只是多追加一份，行为不变）。

### 适配
- Windows 桌面版播放器补上「播放线路」按钮：换线路原先只在手机端的播放设置抽屉里，桌面端工具栏只有清晰度和倍速，遇到某条线路取流失败只能干等。按钮放在清晰度与倍速之间，显示「线路 当前/总数」，鼠标悬停或点击展开线路列表，切换后从原进度继续；只有一条线路时置灰，本地文件播放不显示。
- 桌面版播放器的弹出菜单改为按播放器的真实可用宽高自适应：线路多的源一集能有几十上百条，菜单贴在控制条上方向上展开、本身不滚动。现在按「控制条以上还剩多少高、播放器有多宽」规划网格——整屏放得下就按列排（先竖后横），列数超过宽度能容纳的数量就把列数钉死、改成按行填充并套竖向滚动条（常显、浅色），线路再多每一条都点得到；多列时格子宽度统一，标签过长省略，弹层比按钮宽时按按钮位置横向挪回可视区域；清晰度、倍速这类短列表行为不变。
- 站源面板里的「管理站源」不再排在列表最底部，改到标题行右侧与「全部站源」同一水平线：原来手机上正好压在屏幕底部的手势条 / 虚拟按键区，容易点不到或误触。
- 直播全屏播放的控制条按屏幕安全区留白，上一台 / 暂停 / 下一台不再贴着屏幕底部的指示条与手势区域；横屏时也避开刘海所在的左右安全区。
- 全屏横屏播放器右上角的「播放设置」不再是占位提示，直接显示与竖屏一致的倍速、清晰度、去广告、弹幕设置，改动即时生效。

## 1.1.1+103

### 新增
- 搜索页支持「全部源」跨源搜索：一次并发搜索所有已开启的站源（含自定义源），核心按标题 / 年份 / 集数归一去重，同一部剧合并成一条，卡片上标出来源与其它可用站源。勾选状态按用户保存在本机；红果鉴只有一个站源时不显示该开关。
- 搜索结果边搜边出：搜索改为「启动 + 轮询快照」，哪个站源先返回就先显示，顶部实时显示「已搜索 3/12 个站源 · 已找到 24 条」和进度条，不再等最慢的站源全搜完；换关键词或离开页面会主动取消后台搜索。
- 本地服务版的「全部源」搜索同步改为流式：先显示进度条，命中结果分批追加。

### 修复
- A123、爱看机器人、短剧家族与自定义源的单源搜索此前实际走的是「本机缓存筛选」，搜不到在线结果；现在与全部源搜索共用同一套站源搜索实现（`native/core/app_search_across.go`），直接返回站源在线搜索结果。
- 修复 Android / Windows / iOS 端自定义源导入失败、提示「无效的本地配置字段」：自定义源列表是设备级配置，保存时用的键没有登记进本地快照的受管字段清单，写入被拒绝，连带导致 `SourceSite.customIds` 没同步，新导入的源在源栏、搜索、追剧里完全看不见。同一问题也影响「全部源搜索」开关的保存。本地服务版走的是自己的存储，不受影响。
- 本地快照写入失败时，内存里的自定义源列表仍会生效并同步给源栏，不至于刚导入的源一个都看不到；错误照常抛给界面提示。

## 1.1.0+102

本次为功能移植与稳定性修复版本，Android、Windows、iOS、本地服务版同步生效。

### 修复
- 修复所有站源点播报「本地核心处理失败，请重试」：移植自定义源时引擎的自定义源注册表没有实例化，解析播放地址时对空指针加锁导致 panic，被最外层兜成一句固定文案。红果、韩小圈、鬼片、A123、爱看机器人、剧果、野果以及短剧家族全部受影响，三端与本地服务版共用一个核心，因此同时修复。
- 核心内部 panic 现在会把完整堆栈写入日志（`<数据目录>/logs/native_stderr.log`），不再只有一句「处理失败」，便于后续定位。
- 修复自定义源与 XBPQ 源的自定义域名没有登记进浏览器指纹传输白名单，导致部分源页面请求被源站拒绝。
- 修复自定义源（网页源 / 采集源）点进详情、播放时报「当前版本不包含此站源」：自定义剧集 ID 形如 `custom:<hash>:<id>`，旧拆分只按第一个冒号切，源名被截成 `custom`，授权阶段判定失败。目录能出、一点就报错正是这个原因。

### 站源管理与自定义源
- 站源管理页可逐源开关内置站源，自定义源单独成组，同样可以开启或关闭。
- 新增自定义源管理：新增、编辑、删除，支持 MacCMS 地址与 XBPQ 规则、源类型（自动 / 网页 / JSON）、从本地文件或网址导入、导出 JSON、恢复默认源。
- **取消「仅管理员可编辑站源」的限制**，所有用户都能管理站源与自定义源；下载目录、系统代理等整机设置仍保留管理员限制。
- 自定义源在观看记录、追剧、下载里显示真实源名，不再统一显示「自定义源」。

### 播放器
- 新增左右滑动快进 / 快退（手机全屏与桌面、平板），滑动中只显示预览，抬手才跳转。
- 手机全屏支持左侧上下滑动调亮度（窗口级亮度，退出播放器还原）、右侧上下滑动调音量；竖屏信息流保持原样。
- 滑动与亮度手势的提示统一使用白色文字，深色遮罩下不再看不清。

### 新增
- 播放器去广告开关：设置页、播放内设置面板、电视端控制条都能切换，选择会记住，预加载缓存按开关区分。
- 直播：卫视与直播频道浏览、分类、收藏，全屏播放支持换台、换线路、暂停与收藏；入口在发现页与我的页（手机、宽屏、电视三种布局）。
- 本地服务版（`zhenguoweb.zip`）：随 Release 一起发布，解压后运行即可用浏览器访问，站源与 APP 一致。

## 1.0.1+101

- 修复红果搜索失效：改用红果 App 的剧集搜索，滑到底部继续加载下一页，不再频繁报错。

## 1.0.0+100

界面整体重建，手机、平板、电脑和电视分别适配。

### 界面与导航
- 新主题：跟随系统取色（Android 12 及以上跟随壁纸，Windows 跟随强调色）或 6 个预设色板，浅色 / 深色 / 跟随系统照旧；主题色随备份导出。
- 导航改为发现 / 追剧 / 我的：手机用底栏，平板和电脑用侧栏（可展开或收起，会记住选择），电视用顶部 Tab；宽屏的子页面在侧栏右侧打开。
- 界面模式分自动识别、电视、手机、平板、窗口（只有电脑提供）；手动选定后不再随窗口宽度切换。电视模式强制横屏，手机模式锁定竖屏（iPhone 上为开发快照，未在设备上验证）。
- 焦点导航只在电视端启用：按钮获焦放大加描边，长条只显示描边，外框在元素之间平滑移动；电视页面边距统一，避免被过扫描切掉，不再显示屏幕返回按钮。手机、平板和电脑不再显示焦点外框。
- 新应用图标：Android 改为自适应图标，支持主题图标；电视桌面横幅改为浅色底。

### 发现与搜索
- 站源切换放在站源名旁边；分类用文字 Tab：推荐 / 全部 / 各榜单 / 各题材。榜单并入分类，封面标出名次，不再显示热度。
- 第一个 Tab 顶部有大卡片，显示本站源最近看过的剧或推荐的第一部。
- 滑到底部自动加载下一页；下拉或点「刷新」重新拉取当前分类，不再触发整库更新。
- 修复剧库缓存越积越大，最后提示「剧库超过本地保存上限」、无法继续加载：每个分类的缓存最多保留前 5000 部，旧版整库更新留下的大缓存会自动缩减。
- 红果推荐改用「找剧」混排流，每次加载约 12 部；红果题材改用红果 App 的题材筛选。
- 新搜索页：只搜当前站源，保留最近搜索，红果有输入联想；黄豆和黄果的三个入口只能搜本机缓存。

### 详情
- 封面模糊作底，显示集数、完结状态、分类、播放量、标签和简介；选集每组 30 集，打开时落在续播那一集，看过的集变浅，VIP 集有标记。
- 平板和电脑分左右两栏；电视一屏放下，左栏是信息和按钮，右栏是 6 列选集。
- 打开详情页时在后台预先缓冲续播那一集，点「继续播放」立即开始。
- 红果多季切换和站源诊断入口暂未恢复。

### 播放
- 电脑：左边视频、右边选集栏，可宽屏、全屏；鼠标悬停弹出清晰度、倍速、音量；支持空格、Enter、方向键、M 等快捷键。
- 手机竖屏视频：沉浸式，上下翻页切集；长按画面打开「播放设置」，长按左侧 2 倍速，可锁定。
- 手机横屏视频：竖着拿时视频在上、简介 / 选集在下，转成横屏自动全屏；双击两侧快退 / 快进，长按 2 倍速。
- 平板：横着拿同电脑，竖着拿同手机，全屏期间锁定横屏。
- 电视：播控浮在画面上，隐藏时按左右键快退 / 快进 10 秒；返回键依次关闭选项、收起播控、退出。换集回详情页选。
- 选集栏可多选下载（点选或拖选）；下一集提前缓冲，翻页和自动连播直接接上；倍速、清晰度和弹幕开关会记住。
- 画中画和画质增强暂不提供。

### 追剧与观看记录
- 追剧只分追和不追，旧版的想看 / 在看 / 已看不再使用。追剧按钮在详情页和播放页（电视播放页没有）。
- 追剧页：有新集的剧排在「有更新」，标出「N 集更新」；可搜索、按站源筛选、多选取消追剧。后台每 30 分钟检查一批未完结的追剧。
- 观看记录页：按今天 / 昨天 / 更早分段；可搜索、按站源筛选，可多选删除，「清空」只清当前列出的记录。
- 「我的」页：用户卡、最近观看、下载概况和设置入口；底栏 / 侧栏的「我的」图标显示正在下载的集数。

### 下载
- 下载页分「下载中」「已下载」：单集可暂停、继续、重试，也可全部暂停 / 全部继续，或多选取消；「已下载」按剧显示，点进去可播放、删除、补齐缺集。
- 详情页「下载选集」打开选集页，可点选、拖选或全选。
- 每集下载完自动转成普通 mp4（红果先解密，m3u8 合成一个文件），保存为「下载目录 / 剧名 / 第 N 集.mp4」，可以直接拷出使用；转换失败可单独重试。Android 切到后台时，会等转换完成再退出。旧版下载的分集保持原样。
- 关闭站源时暂停它的下载，重新开启后要手动继续。
- 修复 Windows 上下载目录不能迁到其他盘，提示「新目录不能与原下载目录互相包含」。
- 电视端不再提供下载入口。

### 设置与用户
- 设置分外观、播放、下载、站源、代理、用户、关于、诊断 8 组；宽屏和电视左右分栏，改动立即保存；没有权限的项置灰并注明原因，不再隐藏。
- 「播放」组：默认倍速和默认清晰度（与播放器同步），解码方式可选默认 / 硬解 / 软解；Android 上有兼容渲染模式。
- 站源管理改为一层列表，11 个站源各有一个开关，只有管理员能改；红果鉴不显示这个入口。
- 用户管理：轻点即切换用户，管理员可添加、编辑、删除用户，并设置能访问的站源和是否允许下载。新增启动解锁页，本地配置损坏时可从备份恢复。
- 「关于」组新增 GitHub 和 Telegram 链接。

### 站源
- 修复红果推荐、分类、详情和播放提示「接口未返回有效数据」：补全播放签名，取流改用注册的设备号，被拒时自动换号。
- 黄果 AI 和黄果视频显示「已完结 / 连载中」。
- 精简播放诊断日志：只记录出错的情况，日记页显示为可读文字。

### 移除
- 设备互联（局域网同步、推送播放）和 Emby 导出；旧备份仍可导入。Android 不再申请组播权限，iOS 不再申请本地网络权限。
- 多集合并：每集已经是独立的 mp4；旧版合并出的文件留在下载目录，App 不再列出。
- 发现页的整部剧多选下载；剧果、野果、帝果与目录重复的榜单；站源管理里的更新剧库、连接检测等功能。暂时移除排序与筛选、黄豆 VIP 隐藏和剧集长按菜单。

## 0.2.78+88

- 修复红果播放、下载、剧集详情和推荐翻页全部提示「红果 App 接口未返回有效数据」，0.2.77 的换号也无效。原因是红果开始校验请求签名，播放签名现已补全设备号、授权号和机型信息。0.2.77 加入的设备号注册和被拒换号不再使用。

## 0.2.77+87

- 修复部分设备上红果播放、下载、剧集详情和推荐翻页一直提示「红果 App 接口未返回有效数据」：红果改用向官方注册的设备号，被拒绝时自动换一个新设备号重试（最多 3 次），能用的设备号会保留下来；注册失败时沿用原设备号，10 分钟内不再重复注册。接口偶发的空响应也会自动重试，不再直接报错。

## 0.2.76+86

- 修复剧集封面上的追剧标记挡住「共 N 集」、看不出是否更新：标记移到集数上方，两者同时可见。
- 修复电视端榜单页遥控器移到列表后焦点卡在第一项、无法继续上下移动或返回。
- 电视端播放页播控条显示时按返回键先收起播控条，播控条隐藏后再按返回才退出播放页。
- 修复电视端观看记录、追剧和下载页的搜索框获得焦点后无法移出、不弹输入法：遥控器上下键可移出搜索框，按确认键重新唤起输入法，按返回键收起输入法并移出搜索框。

## 0.2.75+85

- Android 最低系统版本从 8.0 降到 7.0，Android 7.x 设备可以安装。7.x 系统不支持画中画，该入口不会出现。（未实测）
- 电视端播放设置新增「兼容渲染模式」：开启后改用 Skia 渲染（关闭 Impeller），用于排查切换解码方式后仍有声音没画面的电视盒子；切换需确认后自动重启应用生效，播放日记首行记录当前渲染方式。
- 修复系统关闭动画（过渡动画缩放为 0）的设备上弹幕飞得极快、看不清：弹幕滚动不再受系统动画缩放影响，始终按 8 秒穿过画面。

## 0.2.74+84

- 电视端播放设置新增「解码方式」：硬解（默认）保持原有设置；硬解（兼容）和软解（兼容）关闭电视端的 PBO 上传与跳过去块滤波 / IDCT 等加速项，用于排查部分电视盒子有声音没画面的问题，切换后从当前位置重新加载。
- 播放日记新增视频输出诊断，记录实际使用的解码方式、视频输出和像素格式。

## 0.2.73+83

- 剧库启动更快：同一份站源缓存只读取一次，启动时不再因上一次已完成的更新而重复加载整个剧库，剧集数据的 JSON 解析移到后台 isolate，本地追剧数据也不再重复刷新。
- 海报加载更快：HEIC 海报改为最多 3 张同时转码，并优先处理当前屏幕上的海报；缓存清理改为后台节流执行，转码缓存上限调整为 1000 张 / 96MB；已加载过的海报再次出现时直接使用本地文件。
- 首页剧库改为每次展示 60 部，滚到底部再展开下一批；快速滑动或拖动滚动条时，只为停留在屏幕上的海报发起加载，划过的海报会撤销尚未开始的请求。
- 红果剧库首次加载（或清空缓存后）不再一次翻完几十页才显示，首屏只取约 160 部，其余随滚动继续加载；后台更新剧库仍按原来的页数补全。
- 红果剧库和推荐页每次请求从 18 部提高到 54 部，加载同样多的剧，请求数减为原来的三分之一。
- 追剧提醒不再依赖剧库是否完整：启动 30 秒后开始，每 30 分钟在后台检查一批在看或已看的追剧（每轮最多 10 部，同一部剧 6 小时内不重复检查，失败后间隔逐次加倍），发现新集会更新「N 集更新」提醒；想看、手动标记为已看和已完结的剧不检查，已关闭的站源不检查。（开发快照，未经真机验证）
- 播放页选集标题显示剧集状态（已完结 / 连载中），状态未知时不显示。
- 修复野果站源改版后无法加载（「野果页面未提供有效的接口入口」）：页面不再提供接口地址时，改从站点脚本中读取。
- 野果更新中转站地址并识别新的备用线路，主线路不可用时可自动切换。
- 修复版本号显示过时：诊断日志不再写死旧版本号，Windows 和 iOS 的「关于」页面也改为读取安装包里的实际版本。

## 0.2.72+82

- 修复红果源无法播放：红果 App 接口改用 Argus551 + Ladon 签名，并兼容新版播放信息的返回格式。
- Windows 切换到其他窗口时不再暂停播放、弹幕和画质增强，只有最小化或隐藏窗口时才暂停。

## 0.2.72+81

- 修复黄果 AI 剧集不对版：分集列表误把详情页的热门、推荐链接当作分集，导致不同剧的开头几集都是同一个视频、集数也与首页显示不一致。

## 0.2.72+80

- 修复发现页滑动加载更多时偶发的明显卡顿：剧集过滤不再对每一项重复计算站源分组，HEIC 海报缓存清理移到后台 isolate 执行。
- 修复 Windows 端部分剧集播放时画面右侧和底部出现绿边：硬件解码改为 d3d11va-copy 模式。
- 播放控制栏出现时不再整体压暗画面，只在顶栏和底栏处保留边缘渐变。
- 播放 / 暂停、上一集、下一集按钮从画面中间移到底部工具栏左侧（手机与桌面，TV 不变）。
- 修复 Windows 端画质增强始终保持原画：渲染环境判定不再依赖拿不到的 mpv 信息，增强着色器资源不再因换行符转换校验失败，着色器档在无法读取渲染 pass 时改用挂载状态确认生效。
- 修复关闭或切换画质增强时色度缩放设置无法还原导致增强被停用的问题。
- 移除 Windows 端「硬件增强」（d3d11vpp）档：硬解改为 d3d11va-copy 后该档已无法使用。

## 0.2.72+79

- 移除站源密码锁，以及连点「最近观看」打开密码锁的隐藏入口。
- 全站源版可在站源管理中逐个开关站源：黄豆、剧果、野果、帝果、黄果视频 / 黄果 AI / 黄果旧版默认关闭，其余站源默认开启。开关全局生效，仅管理员可以切换；关闭后等同当前用户没有该站源权限。
- 升级后原密码锁设置不迁移，敏感站源回到默认关闭；站源开关不包含在备份中。
- 修复站源管理页黄果分组内显示错误信息时页面构建失败的问题。
- 站源全部关闭时，发现页隐藏切换站源按钮，排序与筛选、多选下载、搜索按钮置灰。
