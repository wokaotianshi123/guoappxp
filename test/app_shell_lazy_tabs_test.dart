import 'package:duanju_app/ui/shell/app_shell.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('启动默认「发现」时听书页不进树，避免提前加载红果听书', () {
    final mounted = initialMountedTabs();
    // 发现页必须立刻可用。
    expect(mounted.contains(AppTab.explore), isTrue);
    // 关键：听书页要等用户第一次切过去才挂载。IndexedStack 会构建所有
    // children，听书页若在树里就会 initState → _loadPools()，和发现页抢资源。
    expect(mounted.contains(AppTab.audiobook), isFalse);
    // 其余标签保持原有行为，占位数量始终与标签数对齐。
    expect(mounted.length, AppTab.values.length - 1);
  });

  test('切到听书后再切回，挂载集合幂等，不会重建页面重复加载', () {
    final mounted = initialMountedTabs();
    expect(mounted.add(AppTab.audiobook), isTrue);
    final count = mounted.length;
    expect(mounted.add(AppTab.audiobook), isFalse);
    expect(mounted.length, count);
    expect(mounted.contains(AppTab.audiobook), isTrue);
  });
}
