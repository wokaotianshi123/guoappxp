# iOS 发布：免费自用与 TestFlight

本文说明 guoappxp 在 iOS 上两种分发方式，以及各自的成本与限制。
结论先说：**TestFlight 没有免费路径**，但「免费 + 小范围自用」有可行的替代方案。

## 一、TestFlight 必须付费（Apple 规定，非操作问题）

TestFlight 应用本身对测试者免费，但**开发者上传构建必须持有付费
Apple Developer Program 会员（99 美元/年）**。原因：TestFlight 跑在
App Store Connect 上，而 App Store Connect 要求有效付费会员。

免费 Apple ID 得到的是 **Personal Team**，它与 TestFlight 是两套体系：

| 能力 | 免费 Apple ID | 付费会员（$99/年） |
| --- | --- | --- |
| 装到自己的设备 | 最多 3 台，需 USB 连 Mac | 最多 100 台/年 |
| 装到别人的设备 | 不可以 | TestFlight：100 内部 / 10000 外部 |
| 签名有效期 | 7 天，到期要重装 | 1 年 |
| 分发证书（distribution） | **不会签发** | 有 |
| 需要 Mac | 需要（签名） | 需要（签名与上传） |

关键限制：免费账号拿不到 **distribution 证书**，所以做不出能被别人
安装的包。这是硬性门槛，没有绕过方式。

## 二、免费方案：侧载未签名包

本项目 `scripts/build_ios.py` 默认产出 `dist/ios/guoapp-*-ios-unsigned.ipa`
（未签名包），配合下面的工具即可自签安装。

### 2.1 先确认 iOS 版本

设置 → 通用 → 关于本机，记下「版本」和「build 号」。这一步决定你能用哪个工具：

| 你的 iOS 版本 | 可用方案 |
| --- | --- |
| 14.0 beta 2 – 16.6.1 | TrollStore（永久） |
| 16.7 RC（build 20H18） | TrollStore（永久） |
| 17.0 | TrollStore（永久） |
| 16.7.x（非 RC）、17.0.1 及以上 | 只能用自签工具（7 天续签） |

TrollStore 的支持范围由官方 README 定死：16.7.x（除 RC）与 17.0.1 以上
**永远不会支持**，因为依赖的 CoreTrust 漏洞已被 Apple 修补，不存在替代方案。
网上流传的「iOS 18 / iOS 26 版 TrollStore」都是引流帖，不要安装。

### 2.2 iOS 17.0.1 及以上：SideStore（推荐）

以 iPhone 12 Pro + iOS 18.7.7 为例，这个组合**用不了 TrollStore**，
推荐 **SideStore**——它是 AltStore 的分支，最大优势是
**装好之后在手机上自己续签，不用每次连电脑**。

1. 电脑装 **iloader**（Windows / macOS / Linux 均可），手机 USB 连电脑并信任；
2. 在 iloader 里登录自己的 Apple ID，选「Install SideStore」；
3. 手机上：设置 → 通用 → VPN 与设备管理 → 信任该开发者证书；
4. 手机上：设置 → 隐私与安全性 → **开发者模式** → 打开并重启；
5. 打开 App Store 装 **LocalDevVPN**，连上它；
6. 打开 SideStore 登录 Apple ID，把 `guoapp-*-ios-unsigned.ipa` 导入安装；
7. 之后每隔 7 天，在 SideStore 里点一下「7 DAYS」计数器即可续签。

免费 Apple ID 的硬限制（任何自签工具都一样）：

- 应用 **7 天**过期，需续签；
- 同时最多 **3 个**自签应用（SideStore 自己占 1 个）；
- 每 7 天最多注册 **10 个 App ID**。

### 2.3 备用：Sideloadly（最直接）

如果不想折腾 SideStore 的配对文件与 VPN：

1. 电脑装 Sideloadly；
2. 手机连电脑，把 IPA 拖进去，填 Apple ID，点 Start；
3. 7 天后重连电脑再点一次 Start。

勾选 auto-refresh 后，Sideloadly 的守护进程会在检测到设备时自动续签——
但要求电脑开着且手机可达（同 Wi-Fi 或 USB）。

Sideloadly 官方声明支持 iOS 7 到 iOS 27+，是兼容性最广的选择。

### 2.4 想装多个应用时：LiveContainer

免费账号只能装 3 个应用。**LiveContainer** 是一个「应用容器」，
里面的应用不占 App ID 名额，可以塞多个。

- 用 **LiveContainer + SideStore** 合体版最省事：两者共占 1 个名额；
- 要求 iOS 15 以上（多任务需 iOS 16+）；
- 注意：容器内的应用**不支持小组件、扩展与远程推送**，
  且不同应用的数据隔离较弱；
- LiveContainer 官方明确**不支持用 Sideloadly 安装**，要用 iloader / Impactor / SideStore。

对只装小果影视一个应用来说，直接用 SideStore 就够，不需要 LiveContainer。


## 三、付费方案：TestFlight 内部测试

内部测试**不需要 App Review**，适合聚合类应用（正式上架 App Store 几乎
无法过审，但内部测试不涉及审核）。

### 3.1 前置条件

1. 付费 Apple Developer Program 会员；
2. 在 App Store Connect 创建 App 记录，bundle id 必须与代码一致
   （默认 `com.guoapp.app`，可用 workflow 变量 `PACKAGE_NAME` 覆盖）；
3. 一份绑定该 bundle id 的 **App Store 分发描述文件**；
4. 一张 **Apple Distribution 证书**（.p12）；
5. 一个 **App Store Connect API Key**（.p8 + Key ID + Issuer ID）。

### 3.2 需要配置的 Secrets

在仓库 Settings → Secrets and variables → Actions 里加：

| Secret | 内容 | 获取方式 |
| --- | --- | --- |
| `APPLE_CERTIFICATE_P12_BASE64` | Apple Distribution 证书的 base64 | 钥匙串导出 .p12 后 `base64 -i cert.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | 导出 .p12 时设的密码 | 自己设定 |
| `IOS_PROVISION_PROFILE_BASE64` | App Store 描述文件的 base64 | developer.apple.com 生成后 `base64 -i x.mobileprovision` |
| `APP_STORE_CONNECT_KEY_ID` | API Key 的 Key ID | App Store Connect → 用户和访问 → 密钥 |
| `APP_STORE_CONNECT_ISSUER_ID` | Issuer ID | 同上页面顶部 |
| `APP_STORE_CONNECT_PRIVATE_KEY` | .p8 文件全文（或 base64） | 创建 API Key 时只能下载一次 |

可选变量（Variables，非敏感）：

| 变量 | 用途 |
| --- | --- |
| `PACKAGE_NAME` | 覆盖 bundle id，默认 `com.guoapp.app` |
| `APPLE_TEAM_ID` | 描述文件里读不到 Team ID 时的兜底 |

### 3.3 触发发布

仓库 Actions → **Build app packages** → Run workflow：

- 勾选 `ios`：构建 iOS 包
- 勾选 `testflight`：构建后上传到 TestFlight

没配 Secrets 时流程不会失败，只会生成未签名 IPA（保持原有行为）。

### 3.4 内部测试专用开关

`ios/ExportOptions.plist` 里默认开着：

```xml
<key>testFlightInternalTestingOnly</key>
<true/>
```

含义：构建**只能分配给内部测试组**，永远不会被提交去 Beta App Review
或上架 App Store。个人自用正合适，也避免误操作把构建推到公开渠道。

想改成可对外分发时，把该值改为 `false`，并在 App Store Connect 里把
构建加入外部测试组（首个构建需要 Beta App Review）。

### 3.5 加测试者

App Store Connect → 你的 App → TestFlight → 内部测试：

1. 新建一个内部测试组；
2. 把朋友的 Apple ID 加进 **用户和访问**，角色给 `Marketing` 即可，
   并只授权这一个 App；
3. 邀请他们进组，他们用 TestFlight 应用接受邀请即可安装。

内部测试上限 100 人，每个构建可用 90 天。

## 四、脚本一览

| 脚本 | 作用 |
| --- | --- |
| `scripts/configure_ios_signing.py` | 导入证书、安装描述文件、生成 `ExportOptions.plist` |
| `scripts/build_ios.py` | 构建核心与 App；`--export-options` 走签名导出并校验签名 |
| `scripts/upload_testflight.py` | 上传 IPA；altool 失败自动退 iTMSTransporter |
| `scripts/set_testflight_notes.py` | 从 `CHANGELOG.md` 自动写 TestFlight 更新说明 |

`upload_testflight.py` 为什么要兜底：Xcode 26 的 altool 用 API Key 生成
JWT 时有已知回归（fastlane#29743），会报
`Failed to generate JWT token … NSCocoaErrorDomain Code=259`。所以先试
altool，失败自动改用 iTMSTransporter。

## 五、从侧载切到 TestFlight 要改什么

**结论：完全可逆，且不需要改动任何业务代码。** 侧载和 TestFlight 的区别只在
「怎么签名、怎么分发」，与 App 本身无关。

切换时只需要：

1. 买 Apple Developer Program 会员；
2. 在 App Store Connect 创建 App 记录（bundle id 用 `com.guoapp.app`
   或自己改）；
3. 在仓库配好 6 项 Secrets（见 3.2）；
4. 触发 workflow 时勾上 `ios` + `testflight`。

仓库里的脚本、workflow、`ExportOptions.plist` 都已就位，**不用再写代码**。
两者还能并存：不配 Secrets 时自动出未签名包走侧载，配了就出签名包传
TestFlight，同一套流程按凭据有无自动切换。

唯一需要留意的是 bundle id：一旦在 App Store Connect 建了 App 记录，
bundle id 就固定了，之后改它等于换一个新 App。所以第一次建记录时想清楚。

## 六、常见失败原因

| 现象 | 原因 |
| --- | --- |
| 签名失败、profile 不匹配 | 描述文件的 bundle id 与 `PACKAGE_NAME` 不一致 |
| 上传报 90161 Invalid Provisioning Profile | 用了开发描述文件，必须用 App Store 分发描述文件 |
| 上传报 JWT 错误 | Xcode 26 altool 回归，脚本会自动换 iTMSTransporter |
| 构建号重复 | App Store Connect 拒绝同版本同构建号，改 `pubspec.yaml` 的 `+N` |
| 构建不显示在 TestFlight | 还在处理中，通常几分钟到半小时 |
