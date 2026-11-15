import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class LocalSnapshot {
  LocalSnapshot(this.preferences) {
    reloadValues();
  }
  LocalSnapshot.empty(this.preferences);

  static const storageKey = 'localSnapshot.v1';
  static const libraryKeys = {
    'history',
    'favorites',
    'followStates',
    'seriesCandidates',
    'mediaHistory',
    'source',
    'hideVip',
    // 「全部源搜索」开关：按本地用户保存。
    'searchAllSources',
    'playback',
    'downloadPreferences',
    'catalogView',
    'recentSearches',
  };
  static const globalKeys = {
    'profiles',
    'activeProfile',
    'displayMode',
    'themeMode',
    'autoExport',
    'exportPosters',
    'sourceSwitches',
    'forceLogin',
    // 自定义源是设备级配置，所有本地用户共用；必须列入受管字段，否则保存自定义源
    // 时 _commit 会因为 owns() 不成立而抛 StateError('无效的本地配置字段')。
    'customSources',
    // 站源模块提供的站源列表同理：装上模块属于这台设备，所有本地用户共用，
    // 也必须列入受管字段。
    'moduleSources',
  };
  static const _retiredKeys = {
    'sourceGateEnabled',
    'sourceGateOff',
    'sourceGateSalt',
    'sourceGateHash',
  };
  static final _retiredLibraryKey = RegExp(
    r'^(profile\.[a-zA-Z0-9_-]{1,64}\.)?(lanRecords|lanSettings|lanReceipts)$',
  );
  final SharedPreferences preferences;
  Map<String, Object> _values = {};

  static bool owns(String key) =>
      globalKeys.contains(key) ||
      libraryKeys.contains(key) ||
      RegExp(
        r'^profile\.[a-zA-Z0-9_-]{1,64}\.(history|favorites|followStates|seriesCandidates|mediaHistory|source|hideVip|searchAllSources|playback|downloadPreferences|catalogView|recentSearches)$',
      ).hasMatch(key);

  Map<String, Object> get values => Map.of(_values);
  String? getString(String key) => _values[key] as String?;
  bool? getBool(String key) => _values[key] as bool?;

  void reloadValues() {
    final raw = preferences.getString(storageKey);
    if (raw == null) {
      _values = {
        for (final key in preferences.getKeys().where(owns))
          key: preferences.get(key)!,
      };
      _validate(_values);
      return;
    }
    final decoded = jsonDecode(raw) as Map;
    if (decoded['version'] != 1 || decoded['values'] is! Map) {
      throw const FormatException('本地配置快照无效');
    }
    final values = Map<String, Object>.from(decoded['values'] as Map)
      ..removeWhere(
        (key, _) =>
            _retiredKeys.contains(key) || _retiredLibraryKey.hasMatch(key),
      );
    if (!values.containsKey('profiles')) {
      throw const FormatException('本地配置快照无效');
    }
    _validate(values);
    _values = values;
  }

  void _validate(Map<String, Object> values) {
    for (final entry in values.entries) {
      final boolean = {
        'hideVip',
        'autoExport',
        'exportPosters',
        'forceLogin',
        // setSearchAllSources 存的是布尔值，必须和上面的集合保持一致，
        // 否则读到含该键的快照会被判「本地配置字段无效」而整包锁死。
        'searchAllSources',
      }.contains(entry.key.split('.').last);
      if (!owns(entry.key) ||
          (boolean ? entry.value is! bool : entry.value is! String)) {
        throw const FormatException('本地配置字段无效');
      }
    }
  }

  Future<bool> _restore(Object? value) => switch (value) {
    null => preferences.remove(storageKey),
    String value => preferences.setString(storageKey, value),
    bool value => preferences.setBool(storageKey, value),
    int value => preferences.setInt(storageKey, value),
    double value => preferences.setDouble(storageKey, value),
    List<String> value => preferences.setStringList(storageKey, value),
    _ => Future.value(false),
  };

  Future<void> commit(Map<String, Object> values) async {
    if (values.keys.any((key) => !owns(key))) throw StateError('无效的本地配置字段');
    final content = jsonEncode({'version': 1, 'values': values});
    if (utf8.encode(content).length > 16 * 1024 * 1024) {
      throw StateError('本地记录超过保存上限，请先导出备份并清理记录');
    }
    final previous = preferences.get(storageKey);
    try {
      if (!await preferences.setString(storageKey, content)) {
        throw StateError('本地配置未能保存');
      }
    } catch (_) {
      try {
        await preferences.reload();
        if (preferences.get(storageKey) != previous) {
          final restored = await _restore(previous);
          if (!restored) throw StateError('无法恢复原配置');
          await preferences.reload();
          if (preferences.get(storageKey) != previous) {
            throw StateError('无法恢复原配置');
          }
        }
      } catch (_) {
        throw const SnapshotRecoveryRequired();
      }
      throw StateError('未能保存，原有记录已保留；请检查存储空间和权限后重试');
    }
    _values = Map.of(values);
  }
}

class SnapshotRecoveryRequired implements Exception {
  const SnapshotRecoveryRequired();
  @override
  String toString() => '无法确认本地配置保存结果，已锁定访问；请重新读取配置或恢复备份';
}
