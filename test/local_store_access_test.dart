import 'dart:convert';

import 'package:duanju_app/app_build.dart';
import 'package:duanju_app/local_profiles.dart';
import 'package:duanju_app/local_snapshot.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

Map<String, Object> _viewer(List<String> sources) => {
  'profiles': jsonEncode([
    LocalProfile(
      id: 'default',
      name: '管理员',
      admin: true,
      salt: '0' * 32,
      pinHash: '1' * 64,
    ).toJson(),
    LocalProfile(
      id: 'viewer',
      name: '访客',
      sources: sources,
      download: false,
    ).toJson(),
  ]),
  'activeProfile': 'viewer',
};

Future<LocalStore> _withVisitor() async {
  final store = await openStore();
  await store.saveProfile(
    id: 'default',
    name: '管理员',
    sources: [],
    download: true,
    pin: 'abcdef12',
  );
  await store.saveProfile(name: '访客', sources: ['hongguo'], download: false);
  return store;
}

void main() {
  final hongguo = drama('1', title: '红果剧');
  final huangdou = drama('2', source: 'huangdou', title: '黄豆剧');

  group('profiles', () {
    test('users need an administrator password first', () async {
      final store = await openStore();
      await expectLater(
        store.saveProfile(name: '访客', sources: ['hongguo'], download: false),
        throwsStateError,
      );
      await store.saveProfile(
        id: 'default',
        name: '管理员',
        sources: [],
        download: true,
        pin: 'abcdef12',
      );
      await store.saveProfile(name: '访客', sources: [], download: false);
      expect(store.profiles, hasLength(2));
      expect(
        store.preferences.getString(LocalSnapshot.storageKey),
        isNot(contains('abcdef12')),
      );
    });

    test('each user sees only their own records and sources', () async {
      final store = await _withVisitor();
      await store.toggleFavorite(hongguo);
      final visitor = store.profiles.firstWhere((profile) => !profile.admin);
      await store.switchProfile(visitor.id);

      expect(store.favorites, isEmpty);
      expect(store.sources.map((site) => site.id), ['hongguo']);
      expect(store.canDownload, isFalse);
      await store.toggleFavorite(huangdou);
      expect(store.favorites, isEmpty);
      // 站源开关不再要求管理员：普通用户也能自己决定看哪些源。
      await store.setSourceEnabled('hongguo', false);
      expect(store.sourceEnabled('hongguo'), isFalse);
      await store.setSourceEnabled('hongguo', true);

      await expectLater(
        store.switchProfile('default', pin: 'wrong'),
        throwsStateError,
      );
      expect(store.profile.id, visitor.id);
      await store.switchProfile('default', pin: 'abcdef12');
      expect(store.favorites.single.id, hongguo.id);
    });

    test('a protected administrator is locked after restart', () async {
      final store = await _withVisitor();
      expect(store.forceLogin, isTrue);

      final restarted = restartStore(store);
      expect(restarted.locked, isTrue);
      expect(restarted.sources, isEmpty);
      expect(restarted.canDownload, isFalse);
      await restarted.switchProfile('default', pin: 'abcdef12');
      expect(restarted.canDownload, isTrue);
      await restarted.setForceLogin(false);

      final unlocked = restartStore(restarted);
      expect(unlocked.locked, isFalse);
      unlocked.lock();
      expect(unlocked.locked, isTrue);
    });

    test('repeated wrong passwords pause further attempts', () async {
      final store = await _withVisitor();
      store.lock();
      for (var attempt = 0; attempt < 3; attempt++) {
        await expectLater(
          store.switchProfile('default', pin: 'wrong'),
          throwsA(
            isA<StateError>().having((e) => e.message, 'message', '密码不正确'),
          ),
        );
      }
      await expectLater(
        store.switchProfile('default', pin: 'abcdef12'),
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', contains('频繁')),
        ),
      );
      expect(store.locked, isTrue);
    });
  });

  group('sources', () {
    test('restricted sources start switched off', () async {
      final store = await openStore();
      // 默认只显示不受限的站源；列表随版本增减（如新增 A123、爱看机器人），
      // 因此按 SourceSite 自己算，不要在测试里写死。
      final expected = [
        for (final site in SourceSite.values)
          if (!SourceSite.isRestricted(site.id)) site.id,
      ];
      expect(expected, isNotEmpty);
      expect(store.sources.map((site) => site.id), expected);
      for (final site in SourceSite.restrictedValues) {
        expect(store.sourceEnabled(site.id), isFalse, reason: site.id);
        expect(store.allowsSource(site.id), isFalse, reason: site.id);
      }
    });

    test('switches persist and follow the build edition', () async {
      final store = await openStore();
      await store.setSourceEnabled('hongguo', false);
      if (allSourcesEnabled) {
        await store.setSourceEnabled('dsd', true);
      } else {
        await expectLater(
          store.setSourceEnabled('dsd', true),
          throwsStateError,
        );
      }

      final restarted = restartStore(store);
      expect(restarted.allowsSource('hongguo'), isFalse);
      expect(restarted.allowsSource('dsd'), allSourcesEnabled);
      if (allSourcesEnabled) {
        expect(restarted.sources, isNotEmpty);
        expect(restarted.source, restarted.sources.first.id);
        expect(restarted.source, isNot('hongguo'));
      } else {
        // 红果鉴仍内置番茄源：关掉红果后应回落到番茄。
        expect(restarted.sources.map((site) => site.id), ['fanqie']);
        expect(restarted.source, 'fanqie');
      }
    });

    test('红果是首页默认站源，番茄仅作为可切换的内置源', () async {
      final store = await openStore();
      expect(SourceSite.defaultSource.id, 'hongguo');
      expect(store.source, 'hongguo');
      if (!allSourcesEnabled) {
        // 红果鉴只保留这两个源，红果排在前才不会被番茄抢走默认位。
        expect(store.sources.map((site) => site.id), ['hongguo', 'fanqie']);
      }

      // 番茄没有被删：切过去能用，重新读档后仍记得这次手动选择。
      await store.setCatalogSource('fanqie', allSources: false);
      expect(store.source, 'fanqie');
      expect(restartStore(store).source, 'fanqie');

      // 存档里的源失效时回落到默认主站源，而不是列表里随便一个。
      await store.setSourceEnabled('fanqie', false);
      expect(restartStore(store).source, 'hongguo');
    });

    for (final source in ['huangdou', 'dsd']) {
      test('a restored $source user keeps identity across editions', () async {
        final store = await openStore({
          ..._viewer([source]),
          'sourceSwitches': jsonEncode({source: true}),
          'profile.viewer.source': source,
        });
        expect(store.configurationError, isNull);
        expect(store.profile.id, 'viewer');
        expect(store.profile.sources, [source]);
        expect(store.allowsSource(source), allSourcesEnabled);
        expect(store.allowsSource('hongguo'), isFalse);
        expect(store.source, allSourcesEnabled ? source : '');
      });
    }
  });

  test('build edition names match the source list', () {
    expect(appSlug, allSourcesEnabled ? 'zhenguojian' : 'hongguojian');
    expect(appName, allSourcesEnabled ? '真果鉴' : '红果鉴');
    expect(
      SourceSite.values.map((site) => site.id),
      allSourcesEnabled
          ? SourceSite.allValues.map((site) => site.id)
          // 红果鉴只留红果与番茄两个源，红果在前（默认主站源）。
          : ['hongguo', 'fanqie'],
    );
    expect(SourceSite.isKnown('dsd'), isTrue);
    expect(SourceSite.isAvailable('dsd'), allSourcesEnabled);
  });
}
