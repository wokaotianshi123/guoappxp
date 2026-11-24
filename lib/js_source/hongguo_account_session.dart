/// 沙箱运行时内部的账号钩子。
///
/// thlredguo 的 JS 沙箱与它自己的红果账号体系（扫码登录、Cookie 续期、
/// PlaybackProfile 签名）是一体的；本项目没有移植那套账号页面，因此这里
/// 只保留运行时需要的几个接口，且恒定「未登录」——沙箱脚本走到的账号分支
/// 因此全部跳过，游客会话与内置签名路径不受影响。
///
/// 需要账号能力的脚本会在 `spider.accountRequest` 处收到明确错误，而不是
/// 静默拿到半个账号。
class HongguoAccountFailure implements Exception {
  const HongguoAccountFailure(this.message, [this.code = 'ACCOUNT_UNAVAILABLE']);
  final String message;
  final String code;
  @override
  String toString() => message;
}

class HongguoAccountSession {
  HongguoAccountSession._();
  static final shared = HongguoAccountSession._();

  /// 账号代次。登录 / 退出会让它自增，运行时据此丢弃旧会话缓存的运行时池。
  /// 本移植没有账号入口，恒为 0。
  int revision = 0;

  String? deviceSession;
  bool get loggedIn => false;

  /// 是否属于需要携带账号 Cookie 的业务接口。
  static bool businessUrl(Uri uri) => false;

  /// 该地址要附带的 Cookie；未登录恒为空串。
  String headerFor(Uri uri) => '';
}
