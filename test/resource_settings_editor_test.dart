import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/resource_settings.dart';
import 'package:duanju_app/resource_settings_editor.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _FailingRepository extends FakeRepository {
  @override
  Future<ResourceSettings> saveResourceSettings(ResourceSettings settings) =>
      Future.error(AppFailure('保存失败'));
}

void main() {
  test('admins load and save, the saved copy replaces the local one', () async {
    final repository = FakeRepository()
      ..resource = const ResourceSettings(catalogConcurrency: 4);
    final editor = ResourceSettingsEditor(repository, await openStore());
    addTearDown(editor.dispose);

    await editor.load();
    expect(editor.settings?.catalogConcurrency, 4);

    await editor.save(editor.settings!.copyWith(catalogIntervalMs: 1000));
    expect(repository.savedResources.single.catalogIntervalMs, 1000);
    expect(editor.settings?.catalogIntervalMs, 1000);
    expect(editor.saving, isFalse);
  });

  test('other users never load the settings', () async {
    final editor = ResourceSettingsEditor(
      FakeRepository(),
      await openStore(viewerPreferences),
    );
    addTearDown(editor.dispose);

    await editor.load();
    expect(editor.allowed, isFalse);
    expect(editor.settings, isNull);
  });

  test('a failed save keeps the old settings and reports the error', () async {
    final editor = ResourceSettingsEditor(
      _FailingRepository(),
      await openStore(),
    );
    addTearDown(editor.dispose);
    await editor.load();

    await expectLater(
      editor.save(editor.settings!.copyWith(downloadConcurrency: 5)),
      throwsA(isA<AppFailure>()),
    );
    expect(editor.settings?.downloadConcurrency, 2);
    expect(editor.saving, isFalse);
  });

  test('magnet cloud cache is on by default and survives a round trip', () {
    const defaults = ResourceSettings();
    expect(defaults.magnetMetaFetch, isTrue);
    expect(defaults.toJson()['magnetMetaFetch'], isTrue);

    final disabled = defaults.copyWith(magnetMetaFetch: false);
    expect(disabled.magnetMetaFetch, isFalse);
    expect(disabled.toJson()['magnetMetaFetch'], isFalse);
    expect(
      disabled.copyWith(proxyMode: 'direct').magnetMetaFetch,
      isFalse,
      reason: '改其它设置不能把这个开关偷偷打开',
    );

    // 老版本核心不返回该字段，按默认开启；明确 false 则必须尊重。
    expect(ResourceSettings.fromJson({}).magnetMetaFetch, isTrue);
    expect(
      ResourceSettings.fromJson({'magnetMetaFetch': false}).magnetMetaFetch,
      isFalse,
    );
  });
}
