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
| 16.7.x（非 RC）、17.0.1 及以上 | 只能用 Sideloadly（7 天） |

TrollStore 的支持范围由官方 README 定死：16.7.x（除 RC）与 17.0.1 以上
**永远不会支持**，因为依赖的 CoreTrust 漏洞已被 Apple 修补，不存在替代方案。

### 2.2 TrollStore（推荐，永久有效）

1. 先按 ios.cfw.guide 的对应机型教程装好 TrollStore；
2. 把 `*-ios-unsigned.ipa` 传到手机「文件」；
3. 在「文件」里点该 IPA → 分享 → 用 TrollStore 打开，或直接在
   TrollStore 里点 `+` 选择文件；
4. 安装完成，重启设备也不会掉。

注意：装好后**不要升级 iOS**，跨大版本升级会让 TrollStore 失效。

### 2.3 Sideloadly（通用，7 天有效）

1. 电脑装 Sideloadly（Windows / macOS）；
2. 手机连电脑，把 IPA 拖进 Sideloadly；
3. 填自己的 Apple ID，点 Start 自签安装；
4. 7 天后应用打不开，重连电脑再点一次 Start 续签。

免费 Apple ID 的限制：最多同时 3 个自签应用、7 天到期、需要
在设置 → 隐私与安全性 里信任开发者证书。

### 2.4 一个省事的技巧

如果频繁续签嫌麻烦，可以用 **LiveContainer**：它让 IPA 跑在自己的容器里，
只占一个应用位，可以塞进多个应用，缓解免费账号 3 个应用的限制。
要求 iOS 15 以上，配合 AltStore / SideStore 使用。


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
