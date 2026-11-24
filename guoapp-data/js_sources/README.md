# JS 沙箱数据目录

此目录是本地服务版的数据目录（`<程序目录>/guoapp-data/js_sources`），运行时由程序创建。

官方源签名参数**不再写进本目录的 `signing.json`**：

- GitHub Actions 构建时通过仓库 Secret `HONGGUO_SIGNING_CONFIG` 把参数编译进 App
  （`--dart-define`）和本地服务版 exe（Go `-ldflags -X`）。
- App 出厂即带官方源签名，「我的 › JS 沙箱」不需要粘贴密钥。
- 本地服务版把签名写进 exe，不落盘、网页端也不显示密钥。

`signing.json` 已被加入 `.gitignore`，仅用于旧版兼容读取；请勿在此提交密钥。
自行构建时设置环境变量的方法见仓库根目录 `SIGNING_SETUP.md`。
