> ⚠️ **免责声明**：本项目源码来自网上大名鼎鼎的**鱼佬**（原作者，[GitHub 主页](https://github.com/fish2018)）。我只是把它拿来打包、测试着玩，方便自己用。

# 红果鉴 / 真果鉴

Flutter 多端独立短剧 / 影视应用

## 最近更新（1.6.0+123）

完整历史见 [CHANGELOG.md](CHANGELOG.md)。

> ⚠️ **包名已更换**：红果鉴 `com.guoapp.phoenix`、真果鉴 `com.guoapp.all`（Android / iPhone / iPad / macOS 统一）。旧版需手动卸载后重装，原有设置、追剧与下载记录不会自动迁移；两个变体现在可以同时安装。

- **听书双书源：红果听书 / 番茄听书**：听书页顶部可切书源，默认「红果听书」。红果听书走红果 App 官方书城（听书 / 小说两个频道，带题材小分类、在线搜索、目录与加密音频播放），番茄听书是畅听男女榜与官方书城听书专辑的合并书池（原「红果听书」的真人剧内容已并入，书源名保持「番茄听书」）。两源书籍 ID 用 `hg:` 前缀隔离，书架、进度、下载互不干扰。详情页保留「真人录音 / AI 朗读」标签与主播名，网页端同步支持 `origin` 参数与同样的书源切换。
- **黄果 AI 取流修复**：播放地址改为宽松解析（字段改名、嵌套、多线路、base64 / hex 混淆都能还原）；会话失效自动换镜像重建一次，业务失败不重试；配置成镜像域名时也会展开全部备选域名。
- **红果系列剧**：详情页选集上方新增「系列多季」卡片条，显示各季集数 / 观看进度 / 上线日期，点击切换，本季播完自动接下一季；季列表按归一化基础名 + 季单位分组，同名不同剧不会混在一起。
- **画面比例与播放设置**：新增「自动 / 拉伸 / 裁切 / 等宽 / 等高 / 原始 / 4:3 / 16:9」八档画面比例，全局记住；手机在播放设置面板、横屏全屏与平板电脑在播放条比例按钮、电视在「比例」菜单里切换，弹幕区域跟随画面；手机竖屏双指张合在「裁切」和「自动」之间切换。设置 › 播放新增「上下滑动切换剧集」「横屏底部进度线」，设置 › 弹幕新增「显示弹幕」总开关。
- **导航与发现**：手机底栏 / 平板侧栏新增「历史」（可在 设置 › 外观 关闭，电视不变）；发现页再点当前分类标签回到顶部。
- **设备注册与平台修复**：域名被解析到 0.0.0.0 或系统 DNS 报不存在时改用 DoH 真实地址重连；Intel Mac 改用 Skia 渲染；Windows 便携版程序旁有 `userdata` 文件夹时数据全部存在这里。
- **听书分类对齐视频分类交互**：App 端与本地服务版网页端的听书分类条改成与「发现」页一致的横向 tab，点击后内容跟随刷新、分类条自动滚到选中项并露出右侧后续分类；右侧常驻「全部分类」按钮，点开网格面板一次列出书池里全部真实分类（含「全部」）并可直接选中加载。分类仍来自实时书池与官方书城，未引入静态清单。
- **听书接入番茄畅听官方书城（实时书库 + 官方分类）**：从 `fanqie.apk` 反编译出 `api.novelfm.com` 的书城接口（`aid=3040`，6 个一级分类 tab），App 端与本地服务版都改为在线拉取，不做静态快照。服务端每 10 分钟、App 端每次进听书页重新取数，书目按 `book_id` 累积去重，分类取官方 `popular_tags` 与书籍内嵌 `category_info`；官方书与原有番茄畅听榜单书池合并，实测合并后 2098 本、分类条从 24 个扩到 65 个且全部有书。请求仍由 Go 核心代发（白名单加 `api.novelfm.com`），单个源失败不影响其它源。
- **本地服务版听书补齐分类与完整书库**：榜单接口固定每页 30 条且 `has_more` 恒 false，网页旧逻辑只能显示第一页 20 本；现在服务端后台抓全男/女两榜并缓存成一份全量书池（实测 2039 本，多个页面共享），支持按总页数翻页。新增 24 个来自 `category_v2` 的真实分类（选分类时跨男女两榜过滤），搜索改为在全量书库里按书名 / 分类 / 作者 / 简介匹配并排序，不再只覆盖榜单前几项；卡片补上真实封面与简介，列表上方显示分类条、分页控件与书库加载进度。
- **旧接口同步修正**：`/api/audiobook/ranks` 的 offset 步长改为 30（不再重叠漏书）、`hasMore` 改为按书池总数计算；`/api/audiobook/search` 也走同一书池。新增 `/api/audiobook/library` 供网页使用，其余目录 / 正文 / 音频接口不变。

**上一版（1.4.2+118 及之前）**

- **修复「清理缓存」失效**：磁力缓存下线后，设置页的缓存统计长期显示 0——真正占空间的封面缓存（`covers-v1`，含 App 转换出的 `compatible-v1` JPEG）、目录缓存（`catalogs.json`）与运行日志（`logs/*.log`）都没被算进去。现在这些都会统计并清理，页面按「播放缓存 / 封面缓存 / 目录缓存 / 日志与临时文件」分类显示；清理封面后会同步重建封面索引，日志被占用时退化为清空。本地服务版顶栏的「清理缓存」同时把转码临时目录 `duanjuweb-*-live` 计入，并跳过正在播放的任务目录。
- **修复本地服务版听书无法打开「可能付费」章节**：网页端之前对带付费标记的章节直接提示「这一章需要付费，暂时无法播放」，而正文与音频接口对这类章节其实都能返回内容。现在照常尝试播放，徽标文案与 App 统一为「可能付费」。

**更早（1.4.0+116 及之前）**

- **新增「听书」**：一级导航「发现」右侧新增「听书」，完整移植番茄畅听链路——听书榜 / 女生听书榜单、在线搜索、书架与收听进度、章节目录、带逐句时间轴的正文跟读（点段落跳转、当前句高亮），支持上一章 / 下一章、倍速、睡眠定时与章节下载；书架、进度按用户分别保存。榜单 / 搜索 / 目录 / 正文都由本机 Go 核心代发（复用现有代理与限流设置），章节音频若是 CENC 加密则由 ffmpeg 解密后播放，与红果加密视频同一条链路。Windows / iOS / macOS / Android 与本地服务版网页全部可用，网页版入口在顶栏「听书」。
- **直播接入斗鱼、哔哩哔哩、虎牙**：直播入口位置不变（Flutter 仍从发现 / 我的进入，网页仍是顶栏「直播」）。内置源顺序改为**斗鱼（默认）→ 哔哩哔哩 → 虎牙 → 秀果直播**，原「秀果」改名为「秀果直播」并排在最后；三个公开平台的分类、房间列表支持「加载更多」，点播时才解析真实播放地址。绿色模式下三个公开平台照常可见，秀果直播整源隐藏。
- **磁力板块整体下线**：磁力搜索、播放、缓存统计、站点管理与相关依赖全部移除，Go 核心不再引入 BT / DHT 相关库，构建脚本与 CI 里为 BT 加的后端标签一并删除。
- **使用限制**：站源、直播与听书资源均来自第三方公开接口，可用性取决于第三方，本项目不提供、不托管任何资源，请仅用于合法内容。本地服务版的加密音频 / 视频需要可用的 `ffmpeg`（随安装包附带）。

**上一版（1.2.8+113）**

- **自定义源可以「自动识别规则」了**：设置 › 自定义源 › 新增自定义源，填好网址点「自动识别规则」，会抓取网页 HTML 反推分类、列表、搜索、详情与播放字段，生成 XBPQ 规则回填到规则框并自动切到「规则」模式，名称为空时顺手补上站名，下面还会列出识别过程说明。生成结果只回填表单、不会直接写盘，保存前可以自己微调，最后仍由用户点「保存」决定。本地服务版网页前端的新增自定义源弹窗里也有同样的「自动识别规则（抓取网页 HTML）」按钮。
- **识别不出不会硬凑坏规则**：抓不到首页、遇到盾页 / 人机验证、纯前端渲染（SPA）站、未识别到分类链接或规则没通过引擎解析校验时，会保留普通网页源（引擎照常自动适配 MacCMS 站点）并说明原因，也可以继续手工粘贴规则。识别总预算 45 秒、单次请求 4 秒、最多 26 次请求，不会卡住界面。生成规则按本项目的 XBPQ 引擎字段字典输出（`播放列表` 是分集分隔符、JSON 搜索转成 `j:` 模式），测不出来的字段宁可省略，交给引擎模板兜底。

**更早（1.2.7+112）**

- **真果鉴新增三个站源（默认关闭）**：「黑桃」（`heitaodj.com` 黑桃短剧）、「禁果短剧」（`jinguoduanju.app` 网页版）、「禁果」（禁果短剧 App `com.hgaidj.ozThree`）。黑桃可看全站剧集或站点分类、支持翻页与在线搜索，海报左下角沿用站点角标（如「6集」「完整版」），站点没角标的剧看过详情后显示「共 N 集」；禁果短剧可选推荐 / 热度 / 站点分类 / 题材，站点不分页，翻页时复用第一页取回的整份目录，不再每页重新下载；禁果可选精选 / 最新 / 站点分类，访客会话自动注册并保存、失效后自动重新登录，主线路不可用自动切到同一部署的备用线路。三个源都只在真果鉴出现、默认关闭，在设置 › 站源管理里打开。付费集（金币 / 会员）只标 VIP、播放时提示需要解锁，不代解锁，也不会播放站点给未解锁分集的广告片花；站点接口放行会员剧时按站点返回为准。不少剧本身只有 1 集。
- **黄豆站源打不开修好了（#76）**：站点换了域名，原来写死的 `tideember.cc` 已解析不到、唯一备用 `xqjurgek.top` 证书过期且域名对不上，所以每次换线必然失败。现在按 `ferncider.cc` → `onyxripple.cc` → `reeflumen.cc` → `niniharbor.top` → `halomeadow.top` → `larksummit.icu` 依次换域名，全部试完才报错；换域名属于换目标、不空等重试间隔，封面 referer 也跟随当前域名。站点显示名由域名改为「黄豆」。站点自制剧不给播放量时不再显示「播放 0」，其它站源同样处理。
- **弹幕样式可以自己调（#74）**：入口在播放页 ›「播放设置」›「弹幕样式」，以及设置里新增的「弹幕」分组。字号改为 60%～200% 连续可调（原来的小 / 标准 / 大 / 特大档位照常生效），另可调颜色、透明度、加粗、描边、阴影，还能选弹幕占画面顶部四分之一 / 一半 / 全部；屏蔽词也在同一处管理，改动立即生效。

**更早（1.2.6+111）**

- **青空次元要登录才能播放**：设置 › 站源新增「站源账号」，用户名 / 邮箱 + 密码 + 拖动滑块验证登录，可点链接去注册；登录状态存在本机并过期前自动续期，所有用户都能登录 / 退出，不限制管理员。未登录或失效时播放页「重试」变「去登录」，登录成功自动重播。电视上左右键移动拼图、确定键验证，输完用户名按「完成」直接跳密码框；进入账号页焦点直接落在青空账号上，退出登录后不丢。
- **4K~6K 大屏不再字小到看不清（#73）**：Android 逻辑短边超过 1000dp 时整体等比放大到接近平板尺寸，手机 / 平板不受影响，运行中切深色、字体、语言照常生效（模拟大屏验证，未上真实车机 / 电视）。
- **野果 / 黄果 AI 改版修复**：野果改为从站点脚本识别「当前线路下的接口地址」，线路换成 `attract.vgbyziuz.cc` 等三条，旧 `analyze.buxefaex.cc` 留作最后备用；黄果 AI 的分类、详情分集、播放地址、榜单与在线全站搜索全部改读站点接口，新增 `lbvrhyir.cc` / `xxbgwypx.cc` 线路并在多个镜像域名间轮换（开发快照，未在 App 内对真实站点验证）。
- **红果取流与首启设备注册**：去掉失效的第三方备用取流接口，网络波动 / 超时不再锁 10 分钟；首次启动先弹「正在注册设备...」，主设备与辅助设备都成功才继续加载推荐，失败可重试或改代理、不能跳过，升级用户只补注册辅助设备。
- **Windows 辅助功能闪退（#67）与 Flutter 3.47.9**：Windows 不再向输入法 / 划词翻译 / 读屏软件暴露应用内控件；各平台进度条 / 音量条的辅助功能信息不再互相打乱。Flutter 升到 3.47.9（不受信任的 eMudhra 中间证书、Android 14+ 系统根证书库、Windows 正式版卡死修复），FFmpeg 组件同步到 2.6.7。
- **播放器记住上次的音量（#61）**：电脑 / 手机全屏调过的音量换剧后不再跳回 100%，静音不记档；电视与手机滑动调的仍是临时 / 系统媒体音量，不受影响。

更早的 1.2.5+110 补齐了电视播放器的「选集 / 线路」入口并修掉 TV 播放成功后反复重试加载，1.2.4+109 给竖屏播放器补了「简介」；详见 CHANGELOG。

## 使用

| 功能 | 操作 |
| --- | --- |
| 浏览 | 标题栏依次提供排序与筛选、榜单和展开搜索。分类保持独立一行，内容区左右滑动切类；支持默认、名称、自然季号、上线日期、热度、播放量排序及连载状态筛选。列表下滑接近底部自动加载下一页，底部「加载更多」为兜底 |
| 搜索 | 红果合并官网与名称索引，输入停顿 300 毫秒显示最多 10 条联想；韩小圈、剧果、野果、鬼片、A123、爱看机器人调用各自的在线搜索并按分页继续加载。部分失败保留有效结果；最近 20 次搜索按用户保存。输入拼音首字母（`BDZC`）时，会先从追剧、观看记录、最近搜索里列出本地匹配的剧名，点一条即用完整标题去搜 |
| 全部源搜索 | 搜索页可勾选「全部源」，同时并发搜索所有已开启的站源（含自定义源），结果按标题 / 年份 / 集数归一去重、同一部剧合并成一条并标出可切换的其它站源。搜索是分批返回的：哪个站源先出结果就先显示，不等最慢的那个；勾选偏好按用户保存在本机。只要当前可搜的站源多于一个（或这份构建本来就是全站源版）就会显示这个开关；红果鉴内置红果与番茄两个短剧源（番茄听书等听书书源独立保留），不用导入自定义源就能用 |
| 电视搜索 | 电视端搜索框按确认键由原生输入框唤起系统输入法（解决小米等电视唤不出输入法的问题）。设置里可开「搜索用字母键盘」：弹出内置 A-Z / 数字键盘，按拼音首字母输入并实时列出匹配条目。追剧、观看记录、站源搜索都支持拼音首字母（`霸道总裁` → `BDZC`） |
| 返回键 | 首页按返回键先提示「再按一次返回退出应用」，2 秒内再按一次才退出；在其它页或有子页面时仍是返回上一层 |
| 推荐 | 仅红果分类栏在「全部」后显示「推荐」，可切换真人剧、漫剧、AI 剧并分别记住位置 |
| 详情 | 普通点剧直接进入播放；下载和兜底入口保留详情页。详情页浏览封面、资料、追剧状态与可展开简介；底部固定「立即播放 / 继续播放」和下载入口。选集默认折叠，展开后每组 50 集，可切换范围、定位当前或输入集数跳转；宽屏与电视采用资料、选集分栏 |
| 追剧与历史 | 按想看 / 在看 / 已看 / 有更新筛选；红果已追剧发现新季后进入「有更新」。追剧和历史均可搜索。每个用户独立保存，每 5 秒及退出播放时记录真实进度 |
| 卡片菜单 | 卡片「更多」提供收藏、状态和下载选集；电脑右键，电视菜单键 |
| VIP | 全站源版浏览黄豆或全部站源时显示 VIP 图标，仅过滤黄豆；默认隐藏已确认的 VIP。未知、免费、VIP 分别保存，未知不会覆盖已知状态 |
| 手机播放 | 竖屏上滑下一集、下滑上一集（左右两侧都可用）；左侧长按后上下滑动调亮度、左右滑动快进快退，与横屏播放器一致；长按 350 毫秒临时 3 倍速（最左侧）。竖屏轻点播放 / 暂停，横屏轻点控制条，双击播放 / 暂停，竖屏长按右侧打开播放设置。视频下方为「选集 / 简介 / 下载」Tab |
| 电视播放 | 界面模式切到「电视」后，控制条从左到右为上一集、播放 / 暂停、下一集、弹幕、去广告、选集、线路、倍速、清晰度；遥控器左右键依次移动，上键回进度条、下键回控制条。按「选集」开右侧抽屉（方向键按网格移动、确认键选集、返回键关闭），按「线路 N/M」换线路（上下逐条、左右翻页，线路多时滚动）；本地视频和单线路也能打开对应面板确认状态。播放已成功但短暂失焦不会再触发重新加载 |
| 画中画 | Android 手机 / 平板播放器接入画中画按钮；进入前隐藏自绘控制层与弹幕，小窗只保留画面。Android TV、Windows、iOS 暂未接入 |
| 投屏 | Android 端播放设置里的「投屏」（DLNA）：自动搜索同一 Wi-Fi 下的电视 / 盒子 / 投影仪，按当前进度投放，可在面板里暂停、继续、停止。流由手机经局域网转发，投屏期间不要退出播放器；本地下载文件不支持 |
| 画质增强 | 仅 Windows 桌面端显示并运行增强链路（关闭 / 自动 / 省电增强 / 清晰优先）；移动端与电视端隐藏 |
| 弹幕 | 红果在线播放默认开启；播放器侧边圆形「弹」字按钮可关闭、查看状态及失败重试，本地播放不加载弹幕。播放页 ›「播放设置」›「弹幕样式」或设置 ›「弹幕」可连续调字号（60%～200%）、颜色、透明度、加粗、描边、阴影与显示区域（顶部四分之一 / 一半 / 全部），也能管理屏蔽词，改动立即生效 |
| 下载 | 播放页「下载」Tab 和详情页下载入口均可选择分集与画质；支持批量暂停、继续、重试、删除及清理任务但保留视频。「更新本剧」补新增或缺失分集 |
| 自定义源 | 设置 › 自定义源新增：填网址 + 名称，可选源类型（MacCMS / 网页源等），也能直接粘贴 XBPQ 规则 JSON（勾选「规则」后优先于源类型）。填好网址可点「自动识别规则」抓取网页 HTML 反推分类 / 列表 / 搜索 / 详情 / 播放字段并回填；识别失败会保留普通网页源并说明原因。规则只做静态 HTML 反推、不执行站点 JS，盾页与 SPA 站需手工写规则 |
| 听书 | 发现右侧的「听书」标签：听书榜 / 女生听书、搜索、书架与收听进度、章节目录、带逐句时间轴的正文跟读（点段落跳转、当前句高亮），支持上一章 / 下一章、倍速、睡眠定时与章节下载。网页版在顶栏「听书」，左列目录、右列正文、底部播放条 |
| 直播 | 从发现 / 我的进入（网页版在顶栏「直播」）。内置斗鱼（默认）、哔哩哔哩、虎牙、秀果直播四个源；分类与房间列表可分页续载，点房间时才解析播放地址。绿色模式下只显示三个公开平台 |
| 更多 | 站源管理（全站源版可逐个开关站源）、用户管理、设置与备份、界面模式、关于 |

两版包内置的站源不同：**红果鉴（默认包）保留红果与番茄两个 core 内置短剧源，首页默认红果**；番茄短剧实现已回迁 `native/core`（`provider_fanqie.go`），不依赖外置站源模块、不随全站源门控，两版都能用（番茄**听书**是独立书源，同样两版保留）。真果鉴（`--dart-define=ALL_SOURCES=true`）再叠加外置仓库的 21 个站源，同样以红果开场。两版都能另外导入自定义源。

| 站源 | 浏览与播放 | 搜索 |
| --- | --- | --- |
| 红果 | 真人剧、漫剧、AI 剧及分集 | 联网搜索与官网搜索联想 |
| 番茄 | 看剧 / 漫剧两个频道、全集分集与多清晰度档位；内容由本机番茄内容引擎（`127.0.0.1:18921`，上游 GPL-3.0 项目 [ch6vip/fqapp](https://github.com/ch6vip/fqapp) 的 Rust 核心）承担。Android / iOS 把引擎编进应用，Windows / macOS / 本地服务版随包带一个独立引擎程序并自动拉起 | 站源在线搜索（引擎 `tab_type=11`） |
| 韩小圈 | MacCMS 模板：最新韩剧 / 韩国电影 / 韩国综艺 / 韩国动漫，多线路分集 | 站源在线搜索 |
| 鬼片 | MacCMS 站点：鬼片 / 电视剧 / 动漫，多线路分集 | RSS 最新条目标题匹配（站点搜索已停用） |
| 青空 | 番剧、剧场动画、特摄及分集 | 站源在线搜索 |
| 黄豆 | 列表、VIP 标记及分集；当前域名池 6 个域名依次换线，显示名固定为「黄豆」 | 筛选已加载短剧 |
| 剧果 | 热门、最新、接口分类、详情及可播放分集；签名 Cookie 接入在线播放、预加载和下载 | 站源在线搜索，支持继续加载 |
| 野果 | 接口实际分类、目录、详情及真实分集；按分集重新取流，保留 H.264 / H.265 地址 | 站源在线分页搜索 |
| 帝果 | 网页分类、目录、详情及分集；vplayer 签名解析 | 站源在线分页搜索 |
| 黄果视频 / 黄果 AI / 黄果旧版 | 列表、分类、详情及分集 | 筛选已加载短剧 |
| 禁果短剧（真果鉴，默认关闭） | `jinguoduanju.app` 网页版：推荐 / 热度 / 站点分类 / 题材、详情分集与播放；站点不分页，翻页复用第一页整份目录；付费集只提示不解锁 | 站源在线搜索，支持翻页 |
| 禁果（真果鉴，默认关闭） | 禁果短剧 App `com.hgaidj.ozThree`：精选 / 最新 / 站点分类、详情分集；访客会话自动注册并续期，主线路故障自动换备用线路；VIP 付费集只提示不解锁 | 站源在线搜索，支持翻页 |
| 笔盒（真果鉴，默认关闭） | `beabox.cc`：「全部」列出最新视频、分类取站点热门标签，支持翻页、详情与分集；域名经常更换，当前线路失效时从发布页自动发现可用域名并记住上次可用线路（重启直接用）；需要解析的线路自动向站点接口换取播放地址 | 站源在线搜索，支持翻页 |

禁果短剧 / 禁果 / 笔盒是本次新增的站源，**默认关闭且只在真果鉴出现**，需要在设置 › 站源管理里手动打开；禁果短剧（网页版）与「禁果」App 不是同一个产品，剧库不同，不少剧只有 1 集。笔盒的线路是站点动态下发的，可能随发布页变化。
黑桃（`heitaodj.com`）、观果、发果、伍果因站点长期不可达 / 采集接口关闭，已整体移除（旧收藏与播放记录仍可识别其 ID，但不再显示或请求）。

站源可用性、清晰度和区域限制取决于源站及网络；应用不解除源站 VIP 或其他授权限制。

## 安装包与平台状态

| 平台 | 包与状态 |
| --- | --- |
| Android 7.0+ | 三架构（arm64-v8a / armeabi-v7a / x86_64）APK；同一签名可覆盖升级，旧证书版本需卸载重装 |
| Windows 10/11 x64 | 完整 ZIP 解压后运行 `hongguojian.exe` / `zhenguojian.exe`，保留所有 DLL 与 `data` |
| macOS 12+ | `*-macos-universal.dmg`，同一份包同时支持 Apple 芯片与 Intel（universal 二进制）；拖进 Applications 即可。未公证，首次打开前在终端执行 `xattr -dr com.apple.quarantine /Applications/红果鉴.app`（真果鉴为 `真果鉴.app`） |
| iOS 15.1+ | 已加入工程、Go 核心链接、媒体依赖、文件管理与构建脚本；iOS 播放页禁用 media_kit_video 硬件纹理加速以规避 libmpv 渲染崩溃；`CFBundleDisplayName` 使用英文 `HongGuoJian` / `ZhenGuoJian` 以通过 iloader 等侧载工具注册 App ID 时的名称校验，中文名写入 `zh-Hans.lproj/InfoPlist.strings`（开发快照，未经 Xcode 构建验证）；待 Xcode 构建与真机验收，无已签名 IPA |
| 本地服务版（Windows / macOS / Linux） | `native/server` 提供 Go HTTP 服务并内嵌网页前端（HLS / FLV / artplayer），由 `scripts/build_web.py` 交叉编译出四份二进制。解压后双击 `start.bat`（Windows）或执行 `sh start.sh`（macOS / Linux），浏览器打开 `http://127.0.0.1:8000/web/`，同一局域网的其它设备可用启动时打印的地址访问。Windows 包内置 `ffmpeg.exe`（加密 H.265 站源需要服务端转码），macOS / Linux 需本机装 ffmpeg |

`INSTALL_FAILED_NO_MATCHING_ABIS` 表示 APK 与设备架构不匹配，请更换对应架构安装包。

### GitHub Actions

工作流只能手动触发，推送和 PR 不再自动运行检查。

发布流程：在 `CHANGELOG.md` 写好同名版本一节（标题如 `## 1.2.0+105`，会写入 Release 说明），推送到 `master`（`main` 也接受），再在 Actions 中手动运行 **Build app packages**。工作流读取 `pubspec.yaml` 的 `version`，得到 tag `app-v{version}`（`+` 替换为 `-`）。同一版本可以重复发布：默认勾选 `republish`，会先删掉同名的旧 Release 与 tag、再按当前提交重建并覆盖同名资产；取消勾选则该版本已存在时直接报错停止，此时应提升 `pubspec.yaml` 的 `version`。然后同时构建各平台的两版（默认与 `--all-sources`），再加上本地服务版：

| 产物 | 内容 |
| --- | --- |
| `*-android` | 三种架构 APK；配好发布证书时用它签名并通过指纹校验，未配置时退回 debug 签名（仅测试用，不能覆盖已安装的正式签名版本） |
| `*-windows` | Windows x64 ZIP |
| `macos` | 两个版本的 `*-macos-universal.dmg`（`hongguojian-…` / `zhenguojian-…`），Apple 芯片与 Intel 通用 |
| `ios-unsigned` | 两个版本的 arm64 iPhone 未签名 IPA（`hongguojian-…` / `zhenguojian-…`），下载后自行签名安装 |
| `web` | `zhenguoweb.zip`：本地服务版合集，内含 `hongguojian.zip` / `zhenguojian.zip` 与 `SHA256SUMS.txt`，两个 zip 都带 Windows 版 `ffmpeg.exe` |

触发时可以勾选/取消 `with_ios`、`with_macos`、`full_variants` 与 `republish`。**默认三个构建开关全不勾**，只出 Android / Windows / 网页版（全在免费的 Linux runner 上跑）；需要 IPA 才勾 `with_ios`，需要 dmg 再勾 `with_macos`，要两套包（红果鉴 + 真果鉴）再加勾 `full_variants`。单平台单变体约 20 分钟墙钟 ≈ 200 账单分钟，正好是 Free 账号一个月的 macOS 额度，所以**默认不勾**、要用时再花。只出单套包时，Release 说明里会自动写一行「本次只出了真果鉴」，不会让人以为包漏发了。

Android、Windows、web 全部成功后才创建 tag 和 Release；iOS 与 macOS 不阻塞发布（见下文）。勾选 `republish` 时同名旧 Release 会被覆盖并重新指向当前提交；不勾选则不会动已有 Release。

#### 发布时报 `HTTP 403: Resource not accessible by integration`

创建 Release 那一步用的令牌没有写权限。release job 里已经声明了 `permissions: contents: write` 却仍然 403，说明**仓库/组织设置把默认令牌压成了只读**（job 里的声明并不总能盖过这个仓库级默认值）。

处理按顺序试：

1. **Settings → Actions → General → Workflow permissions** 选 **Read and write permissions**（仓库级；组织托管的仓库还要看组织同名设置，组织级是硬上限）；
2. 或者在本仓库 **Settings → Secrets and variables → Actions** 新建 Secret `RELEASE_TOKEN`，放一个带 `repo` 权限的个人访问令牌（工作流会优先用它：`secrets.RELEASE_TOKEN || github.token`）；
3. **改完后必须重新手动触发一次新的运行**（Actions → Run workflow），点 Re-run 重跑不生效——重跑会沿用原运行当时的令牌权限。

跑起来后可以看 job 日志开头 Actions 打印的 `GITHUB_TOKEN Permissions:` 块确认这次实际拿到的权限；工作流里也加了一步专门打印「该仓库 Release 接口要求的权限」。手动发布流程为开发快照，尚未完成首次运行验证。

Android 签名优先使用仓库 Secrets：`ANDROID_KEYSTORE_BASE64`、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`，以及仓库变量 `ANDROID_CERT_SHA256`（证书 SHA-256，冒号和大小写不限）。Secrets 缺失时工作流输出 warning 并改用 debug 签名出包、跳过指纹校验；证书指纹只在发布签名模式下校验。CI 通过环境变量把签名传给 Gradle；本机构建使用 `android/key.properties`。`key.properties` 和证书文件不入库。

#### iOS / macOS 经常「不参与构建」的原因

整条发布流里只有 ios 和 macos 两个 job 用 GitHub 的 macOS runner，而 **macOS 分钟按 10 倍计费**：Free 计划每月 2000 分钟折合 macOS 只有约 200 分钟，一次完整 iOS 构建（Flutter 环境 + Go cgo 交叉编译 + `flutter build ios`）往往就要 20～30 分钟墙钟、200～300 分钟账单；macOS 出包是两个版本、两片架构（arm64 + x86_64），同样不便宜。额度用完后：

- Free 账号默认 spending limit 为 0，**不含信用卡时 job 直接不会启动**（Actions 里显示为跳过/「This job was not started because recent account payments have failed or your spending limit needs to be increased」），而不是报构建错误；
- 这也解释了为什么「老是」发生——每月基本只够跑一次。

排查与处理：

1. 打开 `Settings → Billing and plans → Plans and usage`，看 Actions 用量里 macOS 那一行的剩余；
2. 运行详情页顶部的黄色横幅会写明是账单问题（job 日志本身不会写）；
3. 额度不够时：追加信用卡并提高 spending limit，或改用自托管 macOS runner（不计费）；
4. 只想先出 Android / Windows / 网页版：手动运行时**取消勾选 `with_ios` 与 `with_macos`**，Release 会照常发布，只缺 IPA 与 dmg。

##### 「iOS / macOS 没分到 runner」要看是哪一种

这四个字下面其实是三种完全不同的状态，处理方式也不一样：

| 运行页面看到的样子 | 真正的原因 | 怎么处理 |
| --- | --- | --- |
| job 灰掉，顶部黄色横幅写「This job was not started because recent account payments have failed or your spending limit needs to be increased」 | **macOS 分钟额度用完 / spending limit 为 0**。macOS 按 10 倍计费，Free 账号 2000 分钟折合约 200 分钟，一次完整 iOS 出包就能吃掉 200～300 分钟 | 到 `Settings → Billing and plans` 里追加支付方式并调高 spending limit；额度不够就先取消勾选 `with_ios` / `with_macos` |
| job 显示 skipped（灰色，没有日志） | ① `with_ios` / `with_macos` 没勾；② 前置的 `prepare` job 失败（这两个 job 都 `needs: prepare`） | 勾选后重跑；先点开 `prepare` 看它为什么红 |
| 一直「Waiting for a runner to pick up this job」，或整条运行停在 pending 排队 | 已经排进 macOS 队列，等 GitHub 分机器（macOS 池高峰时常见）；或者同一分支上有旧运行还没结束，新运行得排在它后面 | 工作流已开 `cancel-in-progress`，重新触发会直接取消旧运行、不必等它跑完；纯排队的话等几分钟再看 |

另外注意：`ios` 与 `macos` 两个 job 都是 `continue-on-error: true`，它们失败或被跳过**不会**让整条运行变红，所以「工作流成功了但没 IPA」是正常现象，别把它当成「没跑」。

为降低开销，做了四件事：① iOS / macOS 各自的两个版本合在同一个 macOS job 里顺序构建（环境初始化、`pub get`、`pod install` 只付一次，Pods 有缓存）；② `with_ios` / `with_macos` / `full_variants` **默认全不勾**，日常发版一个 macOS 分钟都不花，只在需要 IPA / dmg 时手动勾（单平台单变体约 20 分钟墙钟 ≈ 200 账单分钟，正好是 Free 额度）；③ 这两个 job 的超时从 120 分钟压到 60 分钟（真卡住时最坏 600 账单分钟，而不是 1200）；④ 它们失败或被跳过都**不会**拦住其它平台的发布——Release 说明里会写明本次未包含 IPA / dmg。

#### iOS / macOS 的 ffmpeg 原生框架，以及 `FFmpegKitConfig.h` file not found

播放器把下载完的视频转封装成 mp4 用的是 `ffmpeg_kit_flutter_new_min_gpl`，它的预编译框架（8 个，iOS 约 100 MB）**不在 pub 包里**，而是由插件 podspec 的 `prepare_command` 在 `pod install` 时从 GitHub release 下载。这里有个坑：`prepare_command` 只在「这个 pod 需要安装」时才执行——`ios/Pods` 被 CI 缓存还原、`Podfile.lock` 与已装清单一致时，CocoaPods 认为插件早就装好了，整段跳过，框架就永远补不上，最后在编译期报 `'ffmpegkit/FFmpegKitConfig.h' file not found`（1.2.2 之前 iOS 就栽在这上面；macOS job 没有 Pods 缓存，所以看上去「只有 iOS 坏」）。

现在有三道保险：

1. `build_ios.py` / `build_macos.py` 在 `pod install` 之前先把框架备好（`scripts/ffmpeg_frameworks.py`），下载失败会明确报错并依次尝试镜像，不再把问题拖到编译期；
2. 两个 `Podfile` 都加了 `pre_install` 钩子，生成工程前再检查一次，所以单独跑 `pod install`（或 Xcode 里构建）也不会漏；
3. 框架刚下载完，或者发现旧 `Pods` 的搜索路径里根本没有 ffmpegkit（说明这份工程是框架缺失时生成的，补上框架也没用），会丢掉 `ios/Pods` / `macos/Pods` 让 `pod install` 重新生成。

网络受限时用 `FFMPEG_KIT_IOS_URL` / `FFMPEG_KIT_MACOS_URL` 指向可达的镜像；只查状态不动手：`python3 scripts/ffmpeg_frameworks.py [ios|macos]`，加 `--download` 立即下载。

## 日志与排障

「我的 → 设置 → 播放调试日记」会汇总应用事件、播放器事件与**原生核心日志**，可一键复制。原生核心（`native/core`）内部出错时对外只回「本地核心处理失败，请重试」，真正的 panic 堆栈写在：

| 平台 | 位置 |
| --- | --- |
| Android | 应用数据目录 `files/logs/native_stderr.log`（应用内日记页可直接看到） |
| Windows | `%APPDATA%` 下应用数据目录 `logs\native_stderr.log`，也可在应用内日记页复制 |
| iOS | 沙盒 `Library/Application Support/logs/native_stderr.log` |
| macOS | `~/Library/Application Support/com.duanju.hongguojian/logs/`（真果鉴为 `com.duanju.zhenguojian`）；同样不做 stderr 重定向，排障看应用内日记页 |
| 本地服务版 | 直接打印在启动终端，不写文件 |

stderr 重定向由 bridge 的 `DuanjuInstallStderrLog` 完成：Windows 用 `SetStdHandle`（**不能**用 `_dup2`，`os.File.Fd()` 返回的是 HANDLE，传进去会触发 `__fastfail` 直接退出），其它平台不重定向，避免架构相关的编译风险。

遇到「某个源点播就报处理失败」时，先看这里有没有 `native core panic: ...` 与随后的 Goroutine 调用链，再判断是哪个 provider 的哪一行。

其它两个高频问题：

| 现象 | 原因与处理 |
| --- | --- |
| 某个站源的海报全部不显示 | 图床（如豆瓣 `imgN.doubanio.com`）按 Referer 防盗链，并按 TLS 指纹做风控。核心已内置对应 Referer，并在返回内容不是图片时自动换浏览器指纹传输重试；仍拿不到就是源站侧限流或已下架图 |
| 播放报 `tls: failed to verify certificate: x509` | FFI 嵌入时 Go 的 `crypto/tls` 不加载系统信任库，核心现已改用「系统信任库 + 随包 `cacert.pem`」作信任锚。若某个源仍如此，说明它用了其它私有根，需要在核心的信任锚里追加 |

## 开发与构建

Flutter `3.47.4`、Dart `3.12+`、Go `1.24.1+`、Python `3.10+`。
Android 需要 JDK 17、SDK 36、NDK `28.2.13676358`；
Windows 需要 Visual Studio C++ 桌面组件及 MinGW-w64 x64；
iOS 需要 macOS、完整 Xcode 和 CocoaPods；macOS 同样需要 macOS 12+、完整 Xcode 和 CocoaPods（`dmgbuild` + `Pillow` 可选，用于 dmg 的拖拽安装布局）。

构建脚本对子进程默认设置 `GOPROXY=https://goproxy.cn,direct`、`GOSUMDB=off`，同名环境变量可覆盖。

### 番茄内容引擎

番茄短剧源是 core 内置源（`provider_fanqie.go`），**红果鉴与真果鉴都保留**：
两版首页开场都是红果，番茄要切到「全部站源」手动选择、或用「全部源」搜索时才会用到引擎
（番茄听书是独立书源，走 `audiobook_*` action，不受此影响）。
它的内容不在本站抓取，而是由本机的 Rust 核心（上游 GPL-3.0 的
[ch6vip/fqapp](https://github.com/ch6vip/fqapp)）提供，监听 `127.0.0.1:18921`。
Android 用的是仓库里预编译的 `jniLibs/arm64-v8a/libfanqie_shim.so`；
其余平台的产物由 `scripts/build_fanqie_engine.py` 按固定提交号拉源码现编：

~~~sh
python scripts/build_fanqie_engine.py --out build/fanqie/windows
python scripts/build_fanqie_engine.py --out build/fanqie/linux
python scripts/build_fanqie_engine.py --out build/fanqie/macos --macos-universal
python scripts/build_fanqie_engine.py --out ios/FanqieEngine --target aarch64-apple-ios
~~~

产物有两种形态：`fanqie_engine`（可执行，Windows / macOS / Linux 由宿主进程
拉起）与 `libfanqie_shim`（Android 的 `.so`、iOS 的静态库）。CI 里的 `engines`
job 会把三个桌面平台的引擎编好上传，Windows / macOS / 本地服务版的打包脚本
再把它放进安装包；没编出产物的平台番茄源照样显示，只是播放时会提示引擎未就绪。

Go 侧跟引擎只走 loopback：`fanqieGetJSON` 先用应用统一传输（带限速、诊断、系统
代理与浏览器指纹），失败后用 `fanqieLocalClient` 重试一次——那是一个不查代理、
不复用连接的干净直连客户端，一旦救回来就记住「优先直连」。Android 真机上出现过
「Dart 直连 `/health` 拿到 200、Go 走统一传输却报连接层错误」的组合，靠这条兜底
自愈；两边都失败时，提示里会同时带两条原始错误和 `fanqie_engine.log` 的最后一行
（Rust 的 panic 只写这里，安卓没有 logcat），排障直接看那句提示。

### 两套包与外置站源

站源已经外置到私有仓库 `guoapp-sources`（`module guoapp/sources`），因此每次出包分两种：

| 版本 | 内容 | 构建参数 |
| --- | --- | --- |
| 红果鉴（默认） | 只用 `native/core` 里的内置源：**红果、番茄短剧、XBPQ、红果听书、番茄听书、直播** | 不加 `--sources` |
| 真果鉴（全站源） | 内置源 + 外置仓库里的全部站源（26 个） | `--all-sources --sources ../guoapp-sources` |

`--all-sources` 只决定「这是全站源版本」（界面开关、`buildAllSources` 标记、站源可见性），
外置站源本身要靠 `--sources` 编进来；两个参数要一起给，否则真果鉴会只剩内置源。

实际出包走 GitHub Actions（本机不需要装 Xcode / NDK）：

- 仓库 Secrets 增加 `SOURCES_DEPLOY_KEY`：给**当前账号/组织下的 `guoapp-sources` 私有仓库**
  （CI 用 `github.repository_owner` 动态拼仓库地址，无需手填）配一个**只读 Deploy Key**，
  把私钥整段贴进去。若主仓库不在该组织/账号下，改把站源仓库也放到同一 owner 即可。
  **只需配一次**，详细步骤见下方「一次性配置 `SOURCES_DEPLOY_KEY`」。
- 手动运行 **Build app packages**，用 `with_ios` / `with_macos` / `full_variants` 控制平台与版本数量。
  红果鉴与真果鉴在 Android / Windows 上是矩阵里的两个条目；iOS / macOS 在同一 job 内顺序构建；
  本地服务版一次出两个 zip（`hongguojian.zip` / `zhenguojian.zip`，合集 `zhenguoweb.zip`）。
- 工作流按变体决定是否检出站源仓库：红果鉴那一路完全不碰私有仓库，真果鉴那一路检出到
  `guoapp-sources/` 并传 `--sources guoapp-sources`；缺 Secret 时直接给出明确报错。
- `scripts/check_web.py` 会分别校验：红果鉴只有 `hongguo` 一个源，真果鉴至少 10 个源。

#### 一次性配置 `SOURCES_DEPLOY_KEY`（只读 Deploy Key）

站源仓库是私有的，CI 靠这把只读密钥以 SSH 检出。要点是**公钥挂在站源仓库、私钥存在主仓库**。
配一次即可长期生效：之后每次构建真果鉴会自动从 Secrets 读取，不用再动。

1. **生成无口令密钥对**（密码短语必须留空，CI 非交互无法输入）。Git Bash：

   ~~~sh
   ssh-keygen -t ed25519 -f "$HOME/guoapp-sources-deploy" -N "" -C "guoappxp-ci"
   ~~~

   PowerShell（`ssh-keygen` 会把 `-N '""'` 里的引号当成密码，故省略 `-N`，提示时连按两次回车留空）：

   ~~~powershell
   ssh-keygen -t ed25519 -f "$env:USERPROFILE\guoapp-sources-deploy" -C "guoappxp-ci"
   ~~~

   产出 `guoapp-sources-deploy`（私钥）与 `guoapp-sources-deploy.pub`（公钥）。

2. **公钥挂到站源仓库**：打开站源仓库（当前为 `wokaotianshi123/guoapp-sources`）→
   **Settings → Deploy keys → Add deploy key**，Title 随意（如 `guoappxp-ci`），
   Key 贴 `.pub` 的**整段内容**，**不要勾** "Allow write access"（只读即可，最小权限）。
   CI 里仓库地址是 `${{ github.repository_owner }}/guoapp-sources`，动态取主仓库的 owner，
   因此站源仓库要与主仓库放在**同一账号/组织**下；改名或迁组织时公钥要重新挂。

3. **私钥存进主仓库 Secrets**：打开主仓库（当前为 `wokaotianshi123/guoappxp`）→
   **Settings → Secrets and variables → Actions → New repository secret**，
   Name 必须一字不差填 `SOURCES_DEPLOY_KEY`，Secret 贴**私钥全文**（含
   `-----BEGIN OPENSSH PRIVATE KEY-----` / `-----END OPENSSH PRIVATE KEY-----` 两行，
   `END` 行后要带一个换行，否则 `actions/checkout` 偶发解析失败）。

4. **验证**：**Actions → Build app packages → Run workflow** 跑一次真果鉴平台，
   「检出外置站源」这步成功即配置完成。报 SSH / 403 多半是公钥挂错仓库，或私钥缺末尾换行。

**红果鉴不用管**：它是编译期裁剪，根本不检出站源仓库、不读这个 Secret，任何情况下都能直接构建。
红果鉴与真果鉴只是同一个仓库里的两个构建变体，共用这一个 Secret，无需分别配置。
若有其它项目（如 `guoappxpx`）也检出同一个站源仓库，把**同一把公钥**留在站源仓库、
**同一份私钥**再存一份到那个项目仓库的 `SOURCES_DEPLOY_KEY` 即可。

只有以下情况才需要重新配：① 主动换 / 删 Deploy Key；② 站源仓库改名或迁组织；
③ 要向站源仓库 push（需重新生成并勾选写权限）；④ 私钥泄露需吊销。日常出包、发版一律不用碰。

本地复现同样的包（需要对应平台工具链）：

~~~sh
# Android：红果鉴 / 真果鉴
python3 scripts/build_android.py
python3 scripts/build_android.py --all-sources --sources ../guoapp-sources
python3 scripts/build_android.py --abi arm64-v8a

# Windows：红果鉴 / 真果鉴
python scripts/build_windows.py
python scripts/build_windows.py --all-sources --sources ../guoapp-sources
~~~

~~~sh
python3 scripts/build_ios.py
python3 scripts/build_ios.py --all-sources --sources ../guoapp-sources
python3 scripts/build_ios.py --core-only [--simulator]
python3 scripts/build_ios.py --export-options /path/to/ExportOptions.plist
~~~

~~~sh
python3 scripts/build_macos.py                   # 红果鉴（arm64 + x86_64 通用 dmg）
python3 scripts/build_macos.py --all-sources --sources ../guoapp-sources
python3 scripts/build_native.py --platform darwin --sources ../guoapp-sources  # 只编 macOS 核心
~~~

~~~sh
python3 scripts/build_web.py --sources ../guoapp-sources   # 两版都构建（站源只进真果鉴）
python3 scripts/build_web.py --edition hongguojian
python3 scripts/build_web.py --edition zhenguojian --sources ../guoapp-sources
python3 scripts/check_web.py                     # 出包前自检：真跑起来打一遍接口
~~~

产物在 `dist/android`、`dist/windows`、`dist/ios`、`dist/macos`、`dist/web`，红果版以 `hongguojian-` 开头，全站源版以 `zhenguojian-` 开头；本地服务版输出 `dist/web/hongguojian.zip`、`dist/web/zhenguojian.zip` 与合集 `dist/web/zhenguoweb.zip`。

`scripts/check_web.py` 是本地服务版的冒烟自检：把编出来的二进制实际启动，检查主页能打开、内嵌网页与 `native/server/web` 逐字节一致、站源裁剪生效、接口不返回 500、非法请求打不挂服务。默认自动找 `build/web/*/*-linux`（`build_web.py` 的暂存产物），Windows 本机调试时用 `--binary` 指到 exe，`--slug` 指定版本。


首次 Android 调试先编译对应架构核心，再运行：

~~~sh
python3 scripts/build_native.py --platform android --abi arm64-v8a
flutter pub get --enforce-lockfile
flutter run
~~~

调试全站源版：先给 `build_native.py` 加 `--all-sources`，再 `flutter run --dart-define=ALL_SOURCES=true`；iOS 对应 `build_ios.py --core-only --all-sources`。脚本会同步设置 Dart 常量和 Go 编译参数，应用启动时校验二者一致，避免混装原生库。

播放器使用 [media_kit](https://github.com/media-kit/media-kit) / libmpv，下载完成后转成单个 mp4 使用 [FFmpegKit min-gpl](https://github.com/sk3llo/ffmpeg_kit_flutter)（含 GPL 媒体组件），只换封装、不重新编码。FFmpegKit 不参与正常播放。

### 集中检查

~~~sh
dart format --output=none --set-exit-if-changed lib test
dart analyze --fatal-infos lib test
flutter test --dart-define=DISABLE_REMOTE_IMAGES=true
flutter test --dart-define=DISABLE_REMOTE_IMAGES=true --dart-define=ALL_SOURCES=true
cd native
go test -race ./...
go test -race -ldflags="-X duanjuapp/native/core.buildAllSources=true" ./...
~~~

## 目录结构

| 目录 | 内容 |
| --- | --- |
| `lib` | 页面、播放器、本地用户、FFI、下载和媒体处理 |
| `native/core`、`native/bridge` | 站源运行时（接口、缓存、下载、目录迁移）及 C ABI |
| `../guoapp-sources` | 外置站源模块（不入库，`--sources` 接入；示例见上文站源模块） |
| `native/server` | 本地服务版（Go HTTP 服务 + 内嵌网页前端，含直播代发），由 `scripts/build_web.py` 构建 |
| `android`、`windows`、`ios` | 平台工程与必要资源 |
| `assets/video_enhancement`、`packages/media_kit_libs_windows_video` | 增强 Shader 与许可、固定 Windows 媒体依赖插件 |
| `scripts`、`.github/workflows` | 构建与发布 |
| `test` | 自动化测试 |

## 站源开发约定

### 站源模块（外置）

站源可以外置成独立 Go 模块，编译期接入，不进本仓库：

~~~bash
# 本机约定：站源仓库与 guoappxp 平级
python scripts/build_native.py --platform windows --sources ../guoapp-sources
# 可多次指定，同时接入多个站源模块
python scripts/build_native.py --platform windows --sources ../guoapp-sources --sources ../my-sources
~~~

脚本会生成两个**不入库**的文件：`native/go.work`（工作区，列出本仓库与站源模块）和 `native/bridge/sources_gen.go`（空导入站源模块，带 `sources` 编译标签）。不传 `--sources` 时这两个文件会被删除，构建出的是不含站源的版本，站源调用返回「该站源未编入当前版本」。

站源模块的写法：

- 任意路径的 Go 模块，`go.mod` 里 `module` 自取（如 `guoapp/sources`），**不要** `require duanjuapp/native`；构建脚本生成的 `go.work` 负责解析。
- 实现 `core.Provider`：`Descriptor()`、`Categories(ctx, force)`、`CatalogPage(ctx, page, category)`、`Detail(ctx, id)`、`ResolveMedia(ctx, task)`；在 `init` 里用 `core.Register(描述符, 工厂)` 登记，工厂签名是 `func(core.Host) core.Provider`。
- 搜索是独立能力：实现可选接口 `core.Searcher`（`Search(ctx, page, query)`）或 `core.WarningSearcher`（多返回一条「结果被截断」之类的警告）。目录接口不再接收 query。
- 分类校验写在描述符的 `ValidCategory` 里，必须是纯函数：core 用一个不带 Host 的探针调它，不能访问网络或运行时状态。
- 只能经 `core.Host` 访问运行时：`Fetch` / `FetchText` / `FetchPlaylist`（统一请求，限流、超时、拦截判定都在运行时）、`BaseURL` / `PreferredSite` / `RememberSite`（站点地址与换线）、`LoadState` / `SaveState`（落盘登录态/访客会话）、`PrepareWebMedia` / `FinishMedia`（网页源播放地址校验与收尾）、`Reserve` / `Retries` / `MaxPages`（重试与翻页上限）；不要自建 `http.Client`。
- 需要短剧 / MacCMS / legacy 引擎时，用 `core.AsRuntime(host)` 取 `core.RuntimeHost`：`DuanjuBaseURL` / `DuanjuJSON` / `DuanjuDo`、`MaccmsCatalogPage` / `MaccmsDetail` / `MaccmsSearch`、`DuanjuResolveMedia`、`LegacySettings` / `APIEndpoint` / `ResetAPIEndpoint`、`FetchPage` / `FetchTextFinal` / `PostJSON` / `BrowserPostJSON` / `DoPrepared`、`HTTPClient` / `Limiter` / `CatalogResponseError`、`ConfigURL` / `ConfigAPIURL`、`StateDir` / `RememberHost` / `ForgetHost`、`FetchMediaPlaylist`。这些是 guoappxp 在 guoappxpx 契约之外补的运行时能力，上游源不感知。
- 可选接口：`core.SourceAccount`（账号登录）、`core.SourceRankings`（榜单，名次按位置算）、`core.SourceRankingEntries`（榜单，站点自带名次与指标文案，如黄果）、`core.SourceCategoryLess`（本来就没有分类，如黄豆 / 番茄）。
- **上游 guoappxpx 源可直接编译**：`native/sources_example/provider_example.go` 原样放进站源仓库即可用，实测分类 / 目录 / 翻页 / 搜索 / 详情全通。为此对齐了这些公开面：
  - 可选能力接口（运行时用类型断言调用，站源按需实现）：`CoverRepairer`、`CoverResolver`、`CoverRefererProvider`、`MediaAuthorizer`、`MetadataEnricher`、`SeasonProvider`、`DeviceProvider`、`DanmakuProvider`、`Recommender`、`Suggester`、`CatalogStateful`。
  - 类型与常量：`LibraryDrama`（= `nativeDrama`）、`LibraryMoreKey`、`Season`、`DanmakuItem` / `DanmakuPage`、`RecommendationPage`、`ErrCategoriesIncomplete`、`DanmakuMaxDurationMS`、`MediaCredentialsKey`。
  - `MediaCredentials` 与 `ProviderMedia.Credentials` 的字段全部导出（上游源直接赋值）。
  - helper 导出：`ExtractPageTitle` / `ExtractDescription` / `ExtractAttr` / `ExtractTags` / `FirstMatchText` / `NormalizeDate` / `EpisodeIndex` / `Pkcs7Pad` / `Pkcs7Unpad` / `MergeDramaMetadata` / `RehostProviderURL` / `ProviderSourceForURL` / `M3u8Duration` / `ProviderHTMLAttr` / `ProviderHTMLClass` / `ProviderHTMLNodes` / `ProviderHTMLFirstClass` / `ProviderHTMLText` / `FetchHostPage` / `CoverPathFromAny` / `ProviderCoverAddress` / `ProviderChinaTime` / `ReDateText` / `ReViewsText`。
  - 版本裁剪：站源模块可用 `core.RegisterFlavor("zhenguojian", []string{...})` 声明自己属于哪个版本（配合 `//go:build zhenguojian`），注册后以它为准，未注册时回落到 `-X buildAllSources`。
  - 新增的通用 action：`sourceDevices`（站源设备注册，未实现时回 `available:false`）。
  - **示例源不进产品列表**：上游 `sources_example` 可以编进来验证契约，但 `example` 等示例源一律判定为不可用——不出现在站源下拉框、聚合搜索，直接请求也返回「当前版本不包含此站源」。判定同时看 ID 与描述符特征（名称/简介含「示例」「假数据」，或无 `BaseURL` 却声明 `AllowEmptyCatalog`），不依赖示例源自己声明 `DefaultOff`。
  - `source_upstream_compat_test.go` 锁定以上公开面，改动导出时会先红。
- 需要账号的站源额外实现 `core.SourceAccount`（`Account(ctx, command, input json.RawMessage)`）；「需要登录 / 登录失效」用 `core.ErrSourceLoginRequired` / `core.ErrSourceLoginExpired` 包装，运行时会把错误码回成 `source_login`。
- legacy 家族（黄果 / 云栈 / 禁果）的 AES 协议与宽松解码由 core 导出：`LegacyCipher`、`LegacyEnvelope`、`LegacyDetail`、`LegacyTabList`、`LegacyCoverURL`、`IsLegacySessionExpired`。
- 站源自己的状态（线路缓存、会话、令牌、详情缓存）放在站源结构体里，不要往 `Downloader` 加字段。
- 目前已外置（共 21 个）：A123、鬼片网、爱看机器人、XChina、饭果、花果、网果、韩小圈、Theporny、剧果、野果、禁果、禁果短剧、青空、帝果、笔盒、黄豆、番茄、黄果旧版（legacy）、黄果视频、黄果 AI。（黑桃、观果、发果、伍果因站点失效移除；芽果、猫果、河果、星果、牛果因接口与内容质量下线；红果听书改为听书页的独立书源，不再作为短剧站源。）其中番茄在 `native/core` 另有内置实现（`provider_fanqie.go`）：注册表优先用外置版本，未编入外置模块时回落到 core 内置，让红果鉴也能用。
- 尚未外置（仍在 `native/core`）：红果。红果的剧库缓存、推荐流、弹幕与设备库都在 `nativeEngine` 里，要先抽 `SourceCatalogState` / `SourceDanmaku` / `SourceDevices` 三类运行态接口。
- 黄果家族的 HTML 解析（卡片 / 详情 / 分集 / data-hls）仍留在 `native/core/source_huangguo_parsers.go`：黄果 AI 与「排序详情」模块共用同一套正则，站源通过 `core.ParseHuangguoVideoCards` 等入口调用，不复制私有助手。
- XBPQ 规则源、自定义 MacCMS 源的导入与设置、站点分析器，以及它们共用的 MacCMS 解析引擎保留在 `native/core`（外置站源经 `core.RuntimeHost` 调用这套引擎）。
- 编译标签为 `sources`，所以站源模块里的测试用 `go test guoapp/sources`（在 `native/` 目录、生成 go.work 之后执行）。

### 内嵌站源（尚未外置）

站源是 Go 原生 provider（`native/core/provider_*.go`），不是运行期加载的 Python 源。新增站源需接入：`provider_huangguo.go`（常量 / 白名单 / `canonicalProviderSource` / `GetHuangguoChapters`）、`provider_media.go`（baseURL / host 反查 / 播放分派）、`app_categories.go`、`app_cover_metadata.go`、`app_runtime.go`（Config 字段 + 目录 / 搜索 / 详情分派 + 空页放行），并在 `lib/models.dart` 登记 `SourceSite`。

注意：Go RE2 正则**不支持 lookahead**。解析多线路播放列表时不能用 `(?=...)` 做分段，否则非捕获组会消耗下一段开头；应改用显式字符串截断（从容器标记之后查找下一段标记）。
