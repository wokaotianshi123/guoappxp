import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph, ScrollDirection;
import 'package:flutter/services.dart';

import 'audiobook_download.dart';
import 'audiobook_fanqie.dart';
import 'audiobook_session.dart';
import 'audiobook_store.dart';
import '../../core_bridge.dart';
import 'audiobook_widgets.dart';
import '../widgets/category_tabs.dart';
import '../widgets/choice_panel.dart';

export 'audiobook_session.dart' show AudiobookSession, AudiobookSleep;

const fanqieSearchWords = ['评书', '玄幻', '都市', '悬疑', '武侠'];

/// 每页固定条数：列数随页宽变化，但每页条数不变，翻页页码才不会乱跳。
const _pageSize = 10;

enum _AudiobookPane { search, shelf, history }

class AudiobookScreen extends StatefulWidget {
  const AudiobookScreen({
    super.key,
    required this.repository,
    this.api,
    this.store,
    this.profileId = 'default',
  });

  final AppRepository repository;
  final FanqieAudiobookApi? api;
  final AudiobookStore? store;

  /// 当前本地用户 ID：书架、收听进度和离线音频按用户隔离。
  final String profileId;

  @override
  State<AudiobookScreen> createState() => _AudiobookScreenState();
}

class _AudiobookScreenState extends State<AudiobookScreen> {
  late final FanqieAudiobookApi _api =
      widget.api ?? FanqieAudiobookApi(repository: widget.repository);
  final _search = TextEditingController();
  AudiobookStore? _store;
  _AudiobookPane _pane = _AudiobookPane.search;

  /// 男 / 女两个榜的**全量**书池：分类过滤、翻页与全库搜索都基于它们。
  /// 榜单固定每页 30 条、has_more 恒 false，靠「继续」按钮翻不到底，因此
  /// 抓取时按批次回吐，书池逐渐增长到榜单的全部书目（合计约 2040 本）。
  List<FanqieBook> _malePool = const [];
  List<FanqieBook> _femalePool = const [];

  /// 官方书城（fanqie.apk 反编译所得）实时抓到的书与分类。每次进页面/刷新
  /// 都重新请求，按 book_id 与榜单去重，只做补充，不固化成静态清单。
  List<String> _officialCategories = const [];

  /// 搜索结果的完整列表（本地全库匹配 + 服务端听书补充），翻页在本地切分。
  List<FanqieBook> _searchResults = const [];
  List<FanqieBook> _remoteBooks = const [];

  bool _poolLoading = false;
  bool _poolDone = false;
  bool _searchLoading = false;
  int _page = 1;
  String _query = '';
  FanqieAudiobookBoard _board = fanqieAudiobookBoards.first;

  /// 当前书源：0 = 红果听书（默认），1 = 番茄听书。
  int _origin = fanqieAudiobookOrigins.first.type;

  /// 空串表示「全部」，否则按番茄畅听的真实分类标签过滤。
  String _category = '';
  String? _error;
  String? _storeError;

  /// 书池后台加载与搜索请求分别用独立的代号，切换分类不会打断书池加载。
  int _poolGeneration = 0;
  int _searchGeneration = 0;

  /// 红果听书按需加载状态：每个频道（listen / novel）已取到第几页、
  /// 上游是否还有更多、当前是否正在取下一页。
  ///
  /// 这里不再有「后台全量翻页 + 定时轮询」：点开书源只取第 1 页即停，
  /// 用户主动翻页时才按页补一次，取完立刻释放，不长期占用限流与 IPC。
  final Map<String, int> _hongguoLoadedPages = {};
  final Map<String, bool> _hongguoHasMore = {};
  bool _hongguoPageLoading = false;

  /// 某个红果频道正在补首屏：切书源 / 切频道时避免连点打出一串请求。
  bool _hongguoChannelLoading = false;

  /// 红果听书当前频道：tab 0 是听书，tab 1 是小说。
  String get _hongguoChannel =>
      _board.type == fanqieAudiobookBoards.first.type ? 'listen' : 'novel';

  /// 只有红果听书、且不在搜索结果里时才走按需分页。
  bool get _hongguoPaging => _origin == 0 && _query.isEmpty;

  @override
  void initState() {
    super.initState();
    _prepare();
    unawaited(_loadPools());
  }

  @override
  void dispose() {
    _store?.removeListener(_onStore);
    _search.dispose();
    super.dispose();
  }

  Future<void> _prepare() async {
    try {
      final store =
          widget.store ??
          await AudiobookStore.open(profileId: widget.profileId);
      if (!mounted) return;
      store.addListener(_onStore);
      setState(() {
        _store = store;
        _storeError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _storeError = '$error');
    }
  }

  void _onStore() {
    if (mounted) setState(() {});
  }

  /// 红果听书走官方书城的听书专辑，番茄听书走畅听男女榜；两个书源各自独立，
  /// 不再互相混入，切换书源时列表和分类一起换掉。
  Future<void> _loadPools() async {
    final token = ++_poolGeneration;
    final origin = _origin;
    if (mounted) {
      setState(() {
        _poolLoading = true;
        _poolDone = false;
        _hongguoPageLoading = false;
        _error = null;
      });
    }
    try {
      if (origin == 0) {
        // 红果听书：按需加载。只取「当前频道」的第 1 页就立刻可用，另一个
        // 频道等用户切到那个 tab 时再补。以前一次并发两个频道的书城请求，
        // 两次都要走设备签名并挤同一个 host 限流队列，Android 上切换书源
        // 时表现为明显卡顿甚至假死；番茄命中本地缓存则是 0 请求，所以只有
        // 红果这一侧慢。现在切书源最多一个前台请求，用完即停。
        final channel = _hongguoChannel;
        final first = await _api.hongguoCatalogPage(channel);
        if (!mounted || token != _poolGeneration) return;
        setState(() {
          _officialCategories = const [];
          if (channel == 'listen') {
            _malePool = first.books;
          } else {
            _femalePool = first.books;
          }
          _poolLoading = false;
          _poolDone = true;
          _hongguoPageLoading = false;
          _hongguoLoadedPages[channel] = 1;
          _hongguoHasMore[channel] = first.hasMore;
          _rebuildSearch();
          _error = _pool.isEmpty ? '红果听书暂时没有书' : null;
        });
        _rememberPool(origin);
        // 没有 stillLoading，也没有轮询：书库首到这里就静止，等用户翻页。
        return;
      }

      final results = await Future.wait([
        _api.rankAll(
          fanqieAudiobookBoards[0],
          onProgress: (pool) {
            if (mounted && token == _poolGeneration) {
              setState(() {
                _malePool = pool;
                _rebuildSearch();
              });
            }
          },
        ),
        _api.rankAll(
          fanqieAudiobookBoards[1],
          onProgress: (pool) {
            if (mounted && token == _poolGeneration) {
              setState(() {
                _femalePool = pool;
                _rebuildSearch();
              });
            }
          },
        ),
      ]);
      if (!mounted || token != _poolGeneration) return;
      setState(() {
        _officialCategories = const [];
        _malePool = results[0];
        _femalePool = results[1];
        _poolLoading = false;
        _poolDone = true;
        _rebuildSearch();
        _error = _pool.isEmpty ? '番茄畅听榜单暂时没有书' : null;
      });
      _rememberPool(origin);
    } catch (error) {
      if (!mounted || token != _poolGeneration) return;
      setState(() {
        _poolLoading = false;
        // 首屏尝试已结束，不再有后台任务；保留手动刷新 / 重试入口。
        _poolDone = true;
        _hongguoPageLoading = false;
        _error = _pool.isEmpty ? '$error' : null;
      });
    }
  }

  /// 两个书源各自缓存一份书池：来回切换时直接复用，不重新翻页。
  ///
  /// 红果听书现在按需加载，切回去时立刻显示已加载的那几页，不做后台刷新；
  /// 番茄榜单全量抓一次也缓存下来，避免每次切书源都重抓一遍。
  final Map<int, _AudiobookPoolCache> _poolCaches = {};

  /// 切书源：有缓存就立刻显示，没有才加载首屏；两种情况都不做后台刷新。
  void _switchOrigin(int type) {
    if (_origin == type) return;
    final cached = _poolCaches[type];
    // 立刻作废在途的加载，避免旧书源的数据回写到新书源。
    ++_poolGeneration;
    setState(() {
      _origin = type;
      _officialCategories = const [];
      _searchResults = const [];
      _remoteBooks = const [];
      _category = '';
      _query = '';
      _page = 1;
      _board = fanqieAudiobookBoards.first;
      _error = null;
      _hongguoPageLoading = false;
      _hongguoChannelLoading = false;
      if (cached != null && cached.hasBooks) {
        _malePool = cached.male;
        _femalePool = cached.female;
        _officialCategories = cached.categories;
        _poolLoading = false;
        _poolDone = cached.done;
        // 恢复红果按需分页状态，否则切回去后翻页会以为一页都没取过，
        // 又重新发一遍书城请求（旧版切书源卡顿的来源之一）。
        if (type == 0) {
          _hongguoLoadedPages
            ..clear()
            ..addAll(cached.loadedPages);
          _hongguoHasMore
            ..clear()
            ..addAll(cached.hasMore);
        }
      } else {
        _malePool = const [];
        _femalePool = const [];
        _poolLoading = true;
        _poolDone = false;
        if (type == 0) {
          _hongguoLoadedPages.clear();
          _hongguoHasMore.clear();
        }
      }
    });
    _search.text = '';
    // 有缓存：直接复用，不发任何请求。未命中时也只跑一个前台单页请求，
    // 不并发、不后台翻页、不轮询；切书源这一帧不会阻塞用户操作。
    if (cached == null || !cached.hasBooks) {
      unawaited(_loadPools());
    }
  }

  /// 红果听书某个频道还没取过首屏时补一次（只发一个请求）。
  ///
  /// 切书源、切频道都走这里：已经加载过的频道直接用本地书池，不重复请求；
  /// 同一频道在途时直接跳过，避免连点打出一串设备签名请求把界面拖住。
  Future<void> _ensureHongguoChannel(String channel) async {
    if (_origin != 0 || _hongguoLoadedPages.containsKey(channel)) return;
    if (_hongguoChannelLoading) return;
    final token = _poolGeneration;
    _hongguoChannelLoading = true;
    try {
      final first = await _api.hongguoCatalogPage(channel);
      if (!mounted ||
          token != _poolGeneration ||
          _origin != 0 ||
          _hongguoLoadedPages.containsKey(channel)) {
        return;
      }
      setState(() {
        if (channel == 'listen') {
          _malePool = first.books;
        } else {
          _femalePool = first.books;
        }
        _hongguoLoadedPages[channel] = 1;
        _hongguoHasMore[channel] = first.hasMore;
        _rebuildSearch();
      });
      _rememberPool(0);
    } catch (_) {
      // 单频道失败不影响另一个频道与已显示内容，不重试、不后台续抓。
    } finally {
      _hongguoChannelLoading = false;
    }
  }

  /// 红果听书按需加载下一页：只取当前频道的一页，去重追加到书池后立即结束。
  ///
  /// 仅在用户主动翻页、且已加载数据不够显示目标页时调用；不启动后台任务、
  /// 不轮询、不并发翻页，因此不会与其他书源或短剧请求争抢资源，也不会把
  /// 上千本书含封面 / 简介反复序列化过 IPC。
  Future<bool> _loadNextHongguoPage() async {
    if (_hongguoPageLoading || !_hongguoPaging) return false;
    final channel = _hongguoChannel;
    final origin = _origin;
    final token = _poolGeneration;
    final next = (_hongguoLoadedPages[channel] ?? 1) + 1;
    _hongguoPageLoading = true;
    if (mounted) setState(() => _poolLoading = true);
    try {
      final result = await _api.hongguoCatalogPage(channel, page: next);
      // 请求期间用户切了书源 / 榜单：丢弃回包，不回写旧书源的数据。
      if (!mounted || token != _poolGeneration || _origin != origin) {
        return false;
      }
      _hongguoLoadedPages[channel] = next;
      _hongguoHasMore[channel] = result.hasMore;
      final known = <String>{for (final book in _boardPool) book.id};
      final fresh = <FanqieBook>[
        for (final book in result.books)
          if (known.add(book.id)) book,
      ];
      setState(() {
        if (channel == 'listen') {
          _malePool = [..._malePool, ...fresh];
        } else {
          _femalePool = [..._femalePool, ...fresh];
        }
        _poolLoading = false;
        _poolDone = true;
        _rebuildSearch();
      });
      _rememberPool(origin);
      return result.hasMore;
    } catch (_) {
      // 单页失败不影响已显示的内容，也不重试、不后台续抓；
      // 加载态统一交给 finally 清理，避免请求作废时残留「正在加载」。
      return false;
    } finally {
      _hongguoPageLoading = false;
      // 请求作废（切书源 / 页面卸载）或单页失败时，别把「正在加载」
      // 留在界面上。只在仍是同一代请求时清，避免覆盖新书源刚设置的加载态。
      if (mounted &&
          _poolLoading &&
          token == _poolGeneration &&
          _origin == origin) {
        setState(() => _poolLoading = false);
      }
    }
  }

  /// 把当前书池记到对应书源的缓存里。
  void _rememberPool(int origin) {
    _poolCaches[origin] = _AudiobookPoolCache(
      male: _malePool,
      female: _femalePool,
      categories: _officialCategories,
      done: _poolDone,
      loadedPages: Map<String, int>.of(_hongguoLoadedPages),
      hasMore: Map<String, bool>.of(_hongguoHasMore),
    );
  }

  /// 派生数据缓存。
  ///
  /// 书池有近千本，而 [_categories] / [_allPool] / [_pool] 都要遍历全部书。
  /// 这些 getter 在 build 里被调用多次（分类条、列表、翻页按钮各一次），
  /// 如果每次现算，滑动时每帧都要跑几千次字符串比较——Android 上表现为
  /// 上下滑动直接卡住。这里按「书池 + 分类 + 频道」做一次缓存，
  /// 只有真正影响结果的输入变了才重算。
  List<String>? _categoriesCache;
  List<FanqieBook>? _allPoolCache;
  List<FanqieBook>? _poolCache;
  Object? _derivedKey;

  /// 缓存键：书池引用 + 频道 + 分类。用 identical 判引用，
  /// 书池是整体替换（不是原地改），引用变了就说明内容变了。
  void _ensureDerived() {
    final key = (
      _malePool,
      _femalePool,
      _board.type,
      _category,
      _officialCategories,
      _origin,
    );
    if (_derivedKey != null && _sameDerivedKey(_derivedKey!, key)) return;
    _derivedKey = key;
    _allPoolCache = null;
    _poolCache = null;
    _categoriesCache = null;
  }

  bool _sameDerivedKey(Object previous, Object next) {
    final a = previous as (List, List, int, String, List, int);
    final b = next as (List, List, int, String, List, int);
    return identical(a.$1, b.$1) &&
        identical(a.$2, b.$2) &&
        a.$3 == b.$3 &&
        a.$4 == b.$4 &&
        identical(a.$5, b.$5) &&
        a.$6 == b.$6;
  }

  /// 分类只展示书池里确实有书的：高频基线标签 + 官方书城实时学到的分类。
  /// 分类条：红果听书按**当前频道**书池里的真实题材统计（听书只出听书的题材、
  /// 小说只出小说的题材，两者不混），番茄沿用固定分类表的顺序。
  List<String> get _categories {
    _ensureDerived();
    return _categoriesCache ??= _origin == 0
        ? fanqieHongguoCategoriesFrom(_boardPool)
        : fanqieCategoriesFrom(_allPool, preferred: _officialCategories);
  }

  /// 当前频道（听书 / 小说 或 男 / 女榜）自己的书池。
  /// 按 tab 索引取而不是按 board.type：红果的两个频道是「听书 / 小说」，
  /// 与番茄「男生榜 / 女生榜」的 type 语义不同，按索引才不会错位。
  List<FanqieBook> get _boardPool {
    final index = fanqieAudiobookBoards.indexWhere(
      (board) => board.type == _board.type,
    );
    return index <= 0 ? _malePool : _femalePool;
  }

  /// 男女榜合并去重后的完整听书书库。
  List<FanqieBook> get _allPool {
    _ensureDerived();
    return _allPoolCache ??= () {
      final seen = <String>{};
      return [
        for (final book in [..._malePool, ..._femalePool])
          if (seen.add(book.id)) book,
      ];
    }();
  }

  /// 当前数据源：选分类时按真实标签过滤，否则只看选中的榜。
  /// 红果听书的两个频道内容完全不同（听书 / 小说），分类过滤只在当前频道内做，
  /// 否则选「都市高武」会把听书里的同名题材也带进来。
  List<FanqieBook> get _pool {
    _ensureDerived();
    return _poolCache ??= () {
      if (_origin == 0) {
        final base = _boardPool;
        if (_category.isEmpty) return base;
        return [
          for (final book in base)
            if (_matchesCategory(book, _category)) book,
        ];
      }
      if (_category.isEmpty) {
        return _boardPool;
      }
      return [
        for (final book in _allPool)
          if (_matchesCategory(book, _category)) book,
      ];
    }();
  }

  bool _matchesCategory(FanqieBook book, String category) => book.category
      .split(RegExp(r'[·,，、/\s|]+'))
      .any((tag) => tag.trim() == category);

  /// 搜索以本地全量书库匹配为主（覆盖全部书目、命中的都是可播放的听书），
  /// 再叠加服务端 genre=4 的结果补到书池之外的听书。书池在后台继续加载时
  /// 会自动重算，搜索结果随之补全，不再局限在榜单前几页。
  void _rebuildSearch() {
    if (_query.isEmpty) return;
    final local = fanqieSearchInPool(_allPool, _query);
    // 两个书源都有远程搜索：番茄打畅听接口，红果打红果书城接口。
    final remote = _remoteBooks;
    final seen = <String>{};
    _searchResults = [
      for (final book in [...local, ...remote])
        if (seen.add(book.id)) book,
    ];
  }

  List<FanqieBook> get _currentList => _query.isEmpty ? _pool : _searchResults;

  List<FanqieBook> get _visibleBooks {
    final list = _currentList;
    final start = (_page - 1) * _pageSize;
    if (start >= list.length) return const [];
    final end = start + _pageSize;
    return list.sublist(start, end > list.length ? list.length : end);
  }

  int get _totalPages {
    final count = _currentList.length;
    return count == 0 ? 1 : (count / _pageSize).ceil();
  }

  bool get _canPrev => _page > 1;

  /// 红果听书按需加载时，只要上游还有更多就允许继续翻（数据不够会现取）；
  /// 正在取下一页时先禁用，避免连点重复发请求。用 [_poolLoading] 判断，
  /// 它由 setState 维护，按钮状态才能随请求结束及时恢复。
  bool get _canNext {
    if (_hongguoPaging) {
      if (_poolLoading) return false;
      if (_hongguoHasMore[_hongguoChannel] ?? false) return true;
    }
    return _page < _totalPages;
  }

  /// 翻页：往回翻或已加载的页直接用本地数据，不产生任何请求；
  /// 红果听书往后翻且数据不够时，才按页取一次下一页，取完立刻停。
  Future<void> _changePage(int delta) async {
    final next = _page + delta;
    if (next < 1) return;
    if (delta > 0 && _hongguoPaging) {
      // 相邻页有重叠，一次补页不一定凑够 10 本，最多补 3 页；
      // 上游到底或请求失败就收手，不空转、不后台续抓。
      var guard = 0;
      while (guard++ < 3 &&
          (next - 1) * _pageSize >= _currentList.length &&
          (_hongguoHasMore[_hongguoChannel] ?? false)) {
        if (!await _loadNextHongguoPage()) break;
      }
      if (!mounted) return;
      // 补页后仍不够：按现有数据能切到的末页显示，不把用户留在空白页。
      final reachable = _totalPages;
      final target = next > reachable ? reachable : next;
      if (target < _page) return;
      setState(() => _page = target);
      return;
    }
    if (next > _totalPages) return;
    setState(() => _page = next);
  }

  void _loadBoard(FanqieAudiobookBoard board) {
    ++_searchGeneration;
    _search.clear();
    setState(() {
      _board = board;
      _query = '';
      _category = '';
      _page = 1;
      _searchResults = const [];
      _remoteBooks = const [];
      _searchLoading = false;
      _error = null;
    });
    // 红果听书按频道懒加载：切到尚未取过首屏的频道时才发一次请求，
    // 不与切书源、短剧首页抢同一个 host 的限流队列。
    if (_origin == 0) unawaited(_ensureHongguoChannel(_hongguoChannel));
  }

  void _selectCategory(String category) {
    ++_searchGeneration;
    _search.clear();
    setState(() {
      _category = category;
      _query = '';
      _page = 1;
      _searchResults = const [];
      _remoteBooks = const [];
      _searchLoading = false;
      _error = null;
    });
  }

  /// 榜单 tab 的文案：红果听书是「听书 / 小说」两个频道，番茄是男女听书榜。
  String _boardLabel(int index) {
    if (_origin == 0) return index == 0 ? '听书' : '小说';
    return fanqieAudiobookBoards[index].name;
  }

  String get _searchHint =>
      _origin == 0 ? '搜索红果听书 / 小说' : '搜索番茄畅听全库';

  /// 分类条与「发现」页视频分类共用同一套横向 tab：榜单是「全部」入口，
  /// 其后是书池里真实存在的分类，再后面是搜索热词。三者用前缀区分，
  /// 保证 selected 只有一个值，切换时内容区与选中项位置一起跟随。
  String get _selectedTab {
    if (_query.isNotEmpty) {
      return fanqieSearchWords.contains(_query) ? 'w:$_query' : '';
    }
    if (_category.isNotEmpty) return 'c:$_category';
    final index = fanqieAudiobookBoards.indexWhere(
      (board) => board.type == _board.type,
    );
    return 'b:${index < 0 ? 0 : index}';
  }

  void _onTabSelected(String value) {
    if (value.startsWith('b:')) {
      final index = int.tryParse(value.substring(2)) ?? 0;
      if (index >= 0 && index < fanqieAudiobookBoards.length) {
        _loadBoard(fanqieAudiobookBoards[index]);
      }
    } else if (value.startsWith('c:')) {
      _selectCategory(value.substring(2));
    } else if (value.startsWith('w:')) {
      unawaited(_run(value.substring(2)));
    }
  }

  /// 分类多到横向放不下时，右侧「全部分类」入口打开与视频分类一致的网格
  /// 面板；这里把书池里所有真实分类一次列全，选中后直接回到分类条加载。
  Future<void> _pickCategory(BuildContext anchor) async {
    final boardIndex = fanqieAudiobookBoards.indexWhere(
      (board) => board.type == _board.type,
    );
    final value = await showChoicePanel<String>(
      context: anchor,
      title: '全部分类',
      options: [
        ChoiceOption('b:${boardIndex < 0 ? 0 : boardIndex}', '全部'),
        for (final category in _categories)
          ChoiceOption('c:$category', category),
      ],
      selected: _selectedTab,
      grid: ChoiceGrid.categories,
    );
    if (value != null) _onTabSelected(value);
  }

  Future<void> _run([String? word]) async {
    final query = (word ?? _search.text).trim();
    if (query.isEmpty) return;
    if (word != null) _search.text = word;
    final token = ++_searchGeneration;
    setState(() {
      _searchLoading = true;
      _error = null;
      _query = query;
      _category = '';
      _page = 1;
      _remoteBooks = const [];
      _rebuildSearch(); // 本地书池匹配先出结果，不等网络
    });
    try {
      // 红果听书：听书与小说两个频道各查一遍，合并去重后补进搜索结果。
      if (_origin == 0) {
        final results = await Future.wait([
          _api
              .hongguoSearch('listen', query)
              .catchError(
                (Object _) => const FanqieSearchPage(books: [], hasMore: false),
              ),
          _api
              .hongguoSearch('novel', query)
              .catchError(
                (Object _) => const FanqieSearchPage(books: [], hasMore: false),
              ),
        ]);
        if (!mounted || token != _searchGeneration) return;
        final seen = <String>{};
        _remoteBooks = [
          for (final result in results)
            for (final book in result.books)
              if (seen.add(book.id)) book,
        ];
        setState(() {
          _searchLoading = false;
          _rebuildSearch();
          _error = _searchResults.isEmpty ? '没有找到听书' : null;
        });
        return;
      }
      // 服务端搜索里听书（genre=4）很稀疏，单页常常 0～2 本，取前几页作为
      // 书池之外的补充即可；主体结果来自本地全量书库。
      final results = await Future.wait([
        for (var page = 1; page <= 3; page++)
          _api
              .search(query, page: page)
              .catchError(
                (Object _) => const FanqieSearchPage(books: [], hasMore: false),
              ),
      ]);
      if (!mounted || token != _searchGeneration) return;
      final seen = <String>{};
      _remoteBooks = [
        for (final result in results)
          for (final book in result.books)
            if (seen.add(book.id)) book,
      ];
      setState(() {
        _searchLoading = false;
        _rebuildSearch();
        _error = _searchResults.isEmpty ? '没有找到听书' : null;
      });
    } catch (error) {
      if (!mounted || token != _searchGeneration) return;
      setState(() {
        _searchLoading = false;
        _error = _searchResults.isEmpty ? '$error' : null;
      });
    }
  }

  void _open(FanqieBook book, {bool resume = false}) {
    final store = _store;
    if (store == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AudiobookCatalogScreen(
          api: _api,
          repository: widget.repository,
          store: store,
          book: book,
          resumeOnOpen: resume,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    if (_storeError != null) {
      return StatusPanel(
        title: '听书记录没有打开',
        message: _storeError!,
        icon: Icons.headphones_rounded,
        onRetry: _prepare,
      );
    }
    if (store == null) return const Center(child: CircularProgressIndicator());
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: SegmentedButton<_AudiobookPane>(
            key: const ValueKey('audiobook-pane'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: _AudiobookPane.search, label: Text('找书')),
              ButtonSegment(value: _AudiobookPane.shelf, label: Text('书架')),
              ButtonSegment(value: _AudiobookPane.history, label: Text('历史')),
            ],
            selected: {_pane},
            onSelectionChanged: (value) => setState(() => _pane = value.first),
          ),
        ),
        if (_pane == _AudiobookPane.search) ...[
          // 书源：红果听书吃官方书城的听书专辑（带主播录制与 AI 朗读标注），
          // 番茄听书吃畅听男女榜，两者内容与分类各自独立。
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                for (final origin in fanqieAudiobookOrigins)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(origin.name),
                      selected: _origin == origin.type,
                      onSelected: (_) => _switchOrigin(origin.type),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              key: const ValueKey('audiobook-search'),
              controller: _search,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: _searchHint,
                prefixIcon: const Icon(Icons.search_rounded),
              ),
              onSubmitted: (_) => unawaited(_run()),
            ),
          ),
          // 与「发现」页视频分类同一套横向 tab：点击后内容区跟随刷新，
          // 选中项自动滚到中间、露出右侧后续分类；溢出时右侧出现
          // 「全部分类」入口，点开是列出所有真实分类的网格面板。
          CategoryTabs<String>(
            options: [
              for (var index = 0;
                  index < fanqieAudiobookBoards.length;
                  index++)
                ChoiceOption('b:$index', _boardLabel(index)),
              for (final category in _categories)
                ChoiceOption('c:$category', category),
              for (final word in fanqieSearchWords)
                ChoiceOption('w:$word', word),
            ],
            selected: _selectedTab,
            onSelected: _onTabSelected,
            onShowAll: _pickCategory,
            // 分类来自实时书池，首屏可能只有几个；常驻入口避免按钮时有时无。
            alwaysShowAll: true,
          ),
        ],
        Expanded(child: _body(store)),
        // 上一页 / 下一页固定在列表下方，不随列表滚动消失。
        if (_pane == _AudiobookPane.search) _pager(),
        const AudiobookNowPlayingBar(),
      ],
    );
  }

  Widget _pager() {
    final total = _totalPages;
    final count = _currentList.length;
    final loading = _poolLoading && _query.isEmpty ? ' · 正在加载' : '';
    // 按需加载没有固定的「总页数」：页数随翻页增长，只报已加载本数。
    final label = _hongguoPaging
        ? '第 $_page 页 · 已加载 $count 本$loading · 翻页继续加载'
        : '第 $_page / $total 页 · 共 $count 本$loading';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        spacing: 8,
        children: [
          IconButton(
            tooltip: '上一页',
            onPressed: _canPrev ? () => unawaited(_changePage(-1)) : null,
            icon: const Icon(Icons.chevron_left_rounded),
          ),
          Flexible(
            child: Text(
              label,
              style: const TextStyle(fontSize: 13),
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            tooltip: '下一页',
            onPressed: _canNext ? () => unawaited(_changePage(1)) : null,
            icon: const Icon(Icons.chevron_right_rounded),
          ),
          // 手动刷新：只有用户主动点才重新取首屏，不占用后台资源。
          if (_poolDone && !_poolLoading && _query.isEmpty)
            IconButton(
              tooltip: '刷新书库',
              onPressed: () => unawaited(_loadPools()),
              icon: const Icon(Icons.refresh_rounded, size: 18),
            ),
        ],
      ),
    );
  }

  Widget _body(AudiobookStore store) {
    switch (_pane) {
      case _AudiobookPane.shelf:
        if (store.shelf.isEmpty) {
          return const StatusPanel(
            title: '书架是空的',
            message: '打开一本书，在目录页加入书架。',
            icon: Icons.bookmark_border_rounded,
          );
        }
        return ListView.builder(
          itemCount: store.shelf.length,
          itemBuilder: (context, index) {
            final book = store.shelf[index];
            final latest = store.latest(book.id);
            return ListTile(
              key: ValueKey('audiobook-shelf-${book.id}'),
              title: Text(book.title),
              subtitle: Text(
                latest == null
                    ? _bookLine(book)
                    : '${latest.chapterTitle} · ${formatAudiobookClock(latest.seconds)}',
              ),
              onTap: () => _open(book),
            );
          },
        );
      case _AudiobookPane.history:
        if (store.history.isEmpty) {
          return const StatusPanel(
            title: '还没有听过',
            message: '打开一章之后，这里会记下章节和听到的秒数。',
            icon: Icons.history_rounded,
          );
        }
        return ListView.builder(
          itemCount: store.history.length,
          itemBuilder: (context, index) {
            final entry = store.history[index];
            return ListTile(
              key: ValueKey('audiobook-history-${entry.book.id}'),
              title: Text(entry.book.title),
              subtitle: Text(
                '${entry.chapterTitle} · ${formatAudiobookClock(entry.seconds)}',
              ),
              onTap: () => _open(entry.book, resume: true),
            );
          },
        );
      case _AudiobookPane.search:
        break;
    }
    // 书池首批还没回来时转圈；之后列表边加载边显示，不再整页等待。
    if (_pool.isEmpty && _poolLoading && _query.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_searchLoading && _visibleBooks.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _visibleBooks.isEmpty) {
      return StatusPanel(
        title: '没有听书结果',
        message: _error!,
        icon: Icons.headphones_rounded,
        onRetry: () {
          if (_query.isNotEmpty) {
            unawaited(_run(_query));
          } else {
            unawaited(_loadPools());
          }
        },
      );
    }
    if (_visibleBooks.isEmpty) {
      return const StatusPanel(
        title: '挑个分类开始',
        message: '点上面的分类或榜单，也可以搜索全库书名；用下方的按钮翻页。',
        icon: Icons.headphones_rounded,
      );
    }
    return _bookGrid();
  }

  /// 每行是「封面 | 标题 + 简介」的卡片；列数、封面宽度和简介行数随页宽变化。
  Widget _bookGrid() => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final columns = width >= 1080
          ? 3
          : width >= 640
          ? 2
          : 1;
      final introLines = width >= 1080 ? 3 : 2;
      final coverWidth = width >= 640 ? 78.0 : 66.0;
      final books = _visibleBooks;
      return GridView.builder(
        key: ValueKey('audiobook-grid-$columns-$_page-$_query-$_category'),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisExtent: 132,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
        ),
        itemCount: books.length,
        itemBuilder: (context, index) => _BookCard(
          book: books[index],
          introLines: introLines,
          coverWidth: coverWidth,
          onTap: () => _open(books[index]),
        ),
      );
    },
  );

  String _bookLine(FanqieBook book) =>
      [book.author, book.category].where((item) => item.isNotEmpty).join(' · ');
}

/// 封面 + 标题 + 作者/分类 + 简介的书籍卡片。封面直接取番茄畅听返回的
/// thumb_url（带签名），加载失败或没有封面时退回占位图。
class _BookCard extends StatelessWidget {
  const _BookCard({
    required this.book,
    required this.introLines,
    required this.coverWidth,
    required this.onTap,
  });

  final FanqieBook book;
  final int introLines;
  final double coverWidth;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final placeholder = ColoredBox(
      color: colors.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.headphones_rounded,
          color: colors.onSurfaceVariant,
          size: 28,
        ),
      ),
    );
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: coverWidth,
                  height: coverWidth * 4 / 3,
                  child: book.cover.isEmpty
                      ? placeholder
                      : Image.network(
                          book.cover,
                          fit: BoxFit.cover,
                          cacheWidth: 240,
                          headers: const {
                            'User-Agent': 'Mozilla/5.0',
                            'Referer': 'https://fanqienovel.com/',
                          },
                          errorBuilder: (_, _, _) => placeholder,
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      [
                        book.author,
                        book.category,
                      ].where((item) => item.isNotEmpty).join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      book.intro.isEmpty ? '暂无简介' : book.intro,
                      maxLines: introLines,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.35,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AudiobookCatalogScreen extends StatefulWidget {
  const AudiobookCatalogScreen({
    super.key,
    required this.api,
    required this.repository,
    required this.store,
    required this.book,
    this.resumeOnOpen = false,
  });

  final FanqieAudiobookApi api;
  final AppRepository repository;
  final AudiobookStore store;
  final FanqieBook book;
  final bool resumeOnOpen;

  @override
  State<AudiobookCatalogScreen> createState() => _AudiobookCatalogScreenState();
}

class _AudiobookCatalogScreenState extends State<AudiobookCatalogScreen> {
  final List<FanqieChapter> _chapters = [];
  final _chapterScroll = ScrollController();
  bool _loading = true;
  bool _busy = false;
  bool _stopDownload = false;
  bool _didResume = false;
  String? _error;
  String _status = '';

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_onStore);
    _load();
  }

  @override
  void dispose() {
    _stopDownload = true;
    widget.store.removeListener(_onStore);
    _chapterScroll.dispose();
    super.dispose();
  }

  void _onStore() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    setState(() {
      _loading = _chapters.isEmpty;
      _error = null;
    });
    try {
      final chapters = await widget.api.allChapters(widget.book.id);
      if (!mounted) return;
      setState(() {
        _chapters
          ..clear()
          ..addAll(chapters);
        _loading = false;
      });
      if (widget.resumeOnOpen && !_didResume) {
        _didResume = true;
        final latest = widget.store.latest(widget.book.id);
        if (latest == null) return;
        for (final chapter in _chapters) {
          if (chapter.id == latest.chapterId) {
            await _play(chapter);
            break;
          }
        }
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  Future<void> _play(FanqieChapter chapter) async {
    final index = _chapters.indexWhere((item) => item.id == chapter.id);
    if (index < 0 || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AudiobookPlayerScreen(
          repository: widget.repository,
          api: widget.api,
          store: widget.store,
          book: widget.book,
          chapters: List<FanqieChapter>.of(_chapters),
          index: index,
        ),
      ),
    );
  }

  Future<void> _download(
    String kind, {
    String chapterId = '',
    int fromOrder = 0,
    int toOrder = 0,
  }) async {
    if (_busy) return;
    final selected = selectAudiobookDownloads(
      chapters: _chapters,
      kind: kind,
      bookId: widget.book.id,
      store: widget.store,
      chapterId: chapterId,
      fromOrder: fromOrder,
      toOrder: toOrder,
    );
    if (selected.isEmpty) {
      _toast(_emptyDownload(kind));
      return;
    }
    setState(() {
      _busy = true;
      _stopDownload = false;
      _status = '准备下载 ${selected.length} 章';
    });
    try {
      final report = await downloadAudiobookChapters(
        media: (bookId, chapterId) {
          final repository = widget.repository;
          // 红果听书的 ID 带 hg: 前缀，桥接层会统一剥掉。
          if (bookId.startsWith(fanqieHongguoPrefix)) {
            return repository.audiobookHongguoMedia(bookId, chapterId);
          }
          return repository.audiobookMedia(bookId, chapterId);
        },
        store: widget.store,
        book: widget.book,
        chapters: selected,
        cancelled: () => _stopDownload,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() {
            _status = progress.currentTitle.isEmpty
                ? ''
                : '正在下载 ${progress.completed + progress.failed + 1}/${progress.total} ${progress.currentTitle}';
          });
        },
      );
      if (!mounted) return;
      setState(() => _status = '');
      if (_stopDownload) {
        _toast('已停止下载，完成 ${report.completed} 章');
      } else {
        _toast(
          report.failed > 0
              ? '已下载 ${report.completed} 章，${report.failed} 章失败'
              : '已下载 ${report.completed} 章',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = '';
        });
      }
    }
  }

  Future<void> _downloadRange() async {
    final picked = await showDialog<({int start, int end})>(
      context: context,
      builder: (_) => const _RangeDialog(),
    );
    if (picked == null || !mounted) return;
    await _download('range', fromOrder: picked.start, toOrder: picked.end);
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _scrollToChapter(int index) {
    if (!_chapterScroll.hasClients || _chapters.isEmpty) return;
    final position = _chapterScroll.position;
    final target = audiobookChapterOffset(
      index,
      _chapters.length,
      position.maxScrollExtent,
    );
    _chapterScroll.jumpTo(target);
  }

  Future<void> _pickChapter() async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (_) => _ChapterJumpSheet(chapters: _chapters),
    );
    if (picked == null || !mounted) return;
    _scrollToChapter(picked);
  }

  Widget _chapterTile(AudiobookStore store, FanqieChapter chapter) {
    final reason = store.missingReason(widget.book.id, chapter.id);
    final heard = store.heardSeconds(widget.book.id, chapter.id);
    final local = store.hasLocal(widget.book.id, chapter.id);
    return ListTile(
      key: ValueKey('audiobook-chapter-${chapter.id}'),
      title: Text(chapter.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          '第 ${chapter.order} 章',
          if (chapter.locked) '可能需要付费',
          if (local) '已离线',
          if (heard > 1) '听到 ${formatAudiobookClock(heard)}',
          ?reason,
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => _play(chapter),
      trailing: IconButton(
        tooltip: '下载这一章',
        onPressed: _busy
            ? null
            : () => _download('single', chapterId: chapter.id),
        icon: Icon(
          local ? Icons.download_done_rounded : Icons.download_outlined,
        ),
      ),
    );
  }

  String _emptyDownload(String kind) {
    switch (kind) {
      case 'single':
        return '这一章已经在本地';
      case 'range':
        return '这个范围里没有要下载的章节';
      case 'unfinished':
        return '没有还没听完的章节';
      case 'missing':
        return '没有需要补齐的章节';
      case 'all':
        return '整本已经在本地';
    }
    return '没有要下载的章节';
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final missing = store.missingFor(widget.book.id);
    final latest = store.latest(widget.book.id);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.book.title),
        actions: [
          IconButton(
            tooltip: store.onShelf(widget.book.id) ? '移出书架' : '加入书架',
            onPressed: () => store.toggleShelf(widget.book),
            icon: Icon(
              store.onShelf(widget.book.id)
                  ? Icons.bookmark_rounded
                  : Icons.bookmark_border_rounded,
            ),
          ),
          IconButton(
            key: const ValueKey('audiobook-chapter-jump'),
            tooltip: '跳到章节',
            onPressed: _chapters.length > 1 ? _pickChapter : null,
            icon: const Icon(Icons.format_list_numbered_rounded),
          ),
          PopupMenuButton<String>(
            tooltip: '下载',
            enabled: !_busy && _chapters.isNotEmpty,
            onSelected: (value) {
              switch (value) {
                case 'unfinished':
                  _download('unfinished');
                case 'range':
                  _downloadRange();
                case 'all':
                  _download('all');
                case 'missing':
                  _download('missing');
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'unfinished', child: Text('下载未听完')),
              const PopupMenuItem(value: 'range', child: Text('下载范围')),
              const PopupMenuItem(value: 'all', child: Text('下载整本')),
              PopupMenuItem(
                value: 'missing',
                enabled: missing.isNotEmpty,
                child: const Text('补齐缺章'),
              ),
            ],
          ),
        ],
      ),
      bottomNavigationBar: const AudiobookNowPlayingBar(),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _chapters.isEmpty
          ? StatusPanel(
              title: '目录没有打开',
              message: _error!,
              icon: Icons.menu_book_rounded,
              onRetry: _load,
            )
          : Column(
              children: [
                // 有声书来源标签：真人录制还是 AI 音色朗读，一眼能看出来。
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: Row(
                    children: [
                      Chip(
                        visualDensity: VisualDensity.compact,
                        avatar: Icon(
                          widget.book.voiceMode == '真人录音'
                              ? Icons.mic_rounded
                              : Icons.graphic_eq_rounded,
                          size: 16,
                        ),
                        label: Text(widget.book.voiceMode),
                      ),
                      if (widget.book.anchor.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '主播 ${widget.book.anchor}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (_status.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Row(
                      children: [
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 12),
                        Expanded(child: Text(_status)),
                        TextButton(
                          onPressed: () => _stopDownload = true,
                          child: const Text('停止'),
                        ),
                      ],
                    ),
                  ),
                if (missing.isNotEmpty)
                  ListTile(
                    title: Text('${missing.length} 章没有下完'),
                    subtitle: const Text('原来的进度和书签还在，可以只补这些章'),
                    trailing: FilledButton(
                      onPressed: _busy ? null : () => _download('missing'),
                      child: const Text('补齐'),
                    ),
                  ),
                if (latest != null)
                  ListTile(
                    leading: const Icon(Icons.play_circle_rounded),
                    title: Text('继续 ${latest.chapterTitle}'),
                    subtitle: Text(formatAudiobookClock(latest.seconds)),
                    onTap: () {
                      for (final chapter in _chapters) {
                        if (chapter.id == latest.chapterId) {
                          _play(chapter);
                          return;
                        }
                      }
                      _toast('上次的章节不在目录里');
                    },
                  ),
                Expanded(
                  child: _chapters.isEmpty
                      ? const StatusPanel(
                          title: '这本书没有章节',
                          message: '上游目录是空的。',
                          icon: Icons.menu_book_rounded,
                        )
                      : Scrollbar(
                          key: const ValueKey('audiobook-chapter-scrollbar'),
                          controller: _chapterScroll,
                          interactive: true,
                          thumbVisibility: _chapters.length > 30,
                          thickness: 10,
                          radius: const Radius.circular(5),
                          child: ListView.builder(
                            controller: _chapterScroll,
                            itemExtent: audiobookChapterRowExtent,
                            itemCount: _chapters.length,
                            itemBuilder: (context, index) =>
                                _chapterTile(store, _chapters[index]),
                          ),
                        ),
                ),
              ],
            ),
    );
  }
}

class AudiobookPlayerScreen extends StatefulWidget {
  const AudiobookPlayerScreen({
    super.key,
    required this.repository,
    required this.api,
    required this.store,
    required this.book,
    required this.chapters,
    required this.index,
  });

  final AppRepository repository;
  final FanqieAudiobookApi api;
  final AudiobookStore store;
  final FanqieBook book;
  final List<FanqieChapter> chapters;
  final int index;

  @override
  State<AudiobookPlayerScreen> createState() => _AudiobookPlayerScreenState();
}

class _AudiobookPlayerScreenState extends State<AudiobookPlayerScreen> {
  final _session = AudiobookSession.instance;
  final _textScroll = ScrollController();
  List<GlobalKey> _lineKeys = const [];
  bool _dragging = false;
  double _drag = 0;
  bool _reading = true;
  bool _following = true;
  bool _timed = false;
  Object? _timedText;
  bool _textLoading = false;
  int _line = -1;
  int _shownLine = -1;
  int _textGeneration = 0;
  String? _textChapterId;
  String? _textError;
  List<String> _texts = const [];
  List<AudiobookLine> _lines = const [];
  double _linesDuration = -1;

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSession);
    if (widget.chapters.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(
          _session.start(
            repository: widget.repository,
            api: widget.api,
            store: widget.store,
            book: widget.book,
            chapters: widget.chapters,
            index: widget.index,
          ),
        );
      });
    }
  }

  @override
  void dispose() {
    _session.removeListener(_onSession);
    // 只关界面，不停播放：播放器归全局会话所有，离开后继续在后台朗读。
    // 记进度会通知目录页刷新，放到这一帧拆树之后，避免在锁定期间 setState。
    scheduleMicrotask(() => unawaited(_session.persist()));
    _textScroll.dispose();
    super.dispose();
  }

  List<FanqieChapter> get _chapters =>
      _session.active && _session.book?.id == widget.book.id
      ? _session.chapters
      : widget.chapters;

  FanqieChapter get _chapter =>
      _session.chapter ??
      widget.chapters[widget.index.clamp(0, widget.chapters.length - 1)];

  double get _position => _session.position;
  double get _duration => _session.duration;

  void _onSession() {
    if (!mounted) return;
    final current = _session.chapter;
    if (current != null &&
        current.id != _textChapterId &&
        _session.ready &&
        _reading) {
      unawaited(_loadText());
    }
    if ((_texts.isNotEmpty || _timedText != null) &&
        _linesDuration != _duration) {
      _refreshLines();
    }
    _followLine(_position);
    if (!_dragging) setState(() {});
  }

  void _refreshLines() {
    _linesDuration = _duration;
    final timed = _timedText == null
        ? const <AudiobookLine>[]
        : audiobookTimedLines(_timedText, _duration);
    _lines = timed.isNotEmpty ? timed : paceAudiobookLines(_texts, _duration);
    if (_lineKeys.length != _lines.length) {
      _lineKeys = [for (var i = 0; i < _lines.length; i++) GlobalKey()];
    }
    _line = audiobookLineAt(_lines, _position);
  }

  void _followLine(double seconds, {bool force = false}) {
    final next = audiobookLineAt(_lines, seconds);
    if (next == _line && !force) return;
    _line = next;
    if (!_reading || !_following || next < 0) return;
    if (next == _shownLine && !force) return;
    _shownLine = next;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (next >= _lineKeys.length) return;
      final target = _lineKeys[next].currentContext;
      if (target == null || !mounted) return;
      Scrollable.ensureVisible(
        target,
        alignment: 0.35,
        duration: const Duration(milliseconds: 220),
      );
    });
  }

  Future<void> _loadText() async {
    final itemId = _chapter.id;
    final generation = ++_textGeneration;
    _textChapterId = itemId;
    // 红果听书没有逐句正文，章节 ID 带 hg: 前缀，直接跳过正文请求：
    // 拿红果 item_id 去查番茄正文必然失败，白等一次网络。
    if (itemId.startsWith(fanqieHongguoPrefix)) {
      setState(() {
        _textLoading = false;
        _texts = const [];
        _timedText = null;
        _timed = false;
        _lines = const [];
        _line = -1;
        _shownLine = -1;
        _textError = null;
      });
      return;
    }
    setState(() {
      _textLoading = true;
      _textError = null;
      _texts = const [];
      _timedText = null;
      _timed = false;
      _lines = const [];
      _line = -1;
      _shownLine = -1;
    });
    try {
      // 先取带逐句时间轴的听书正文；失败再退回网页正文，按字数比例对齐。
      Object? timedText;
      try {
        timedText = await widget.repository.audiobookText(itemId);
      } catch (_) {
        timedText = null;
      }
      if (!mounted || generation != _textGeneration) return;
      var texts = const <String>[];
      if (audiobookTimedLines(timedText, 1).isEmpty) {
        timedText = null;
        texts = await widget.api.chapterText(itemId);
      }
      if (!mounted || generation != _textGeneration) return;
      setState(() {
        _timedText = timedText;
        _timed = timedText is Map && timedText['timed'] == true;
        _texts = texts;
        _textLoading = false;
        _textError = timedText == null && texts.isEmpty ? '这一章暂时没有原文' : null;
        _refreshLines();
      });
      _followLine(_position, force: true);
    } catch (error) {
      if (!mounted || generation != _textGeneration) return;
      setState(() {
        _textLoading = false;
        _textError = '$error';
      });
    }
  }

  Future<void> _jumpLine(AudiobookLine line, [double? at]) async {
    final target = at ?? line.start;
    _following = true;
    await _session.seekTo(target);
    _followLine(target, force: true);
  }

  /// 双击某段：按双击处的字符落在哪一句，跳到那一句的时间。
  void _doubleTapLine(int index, Offset? local) {
    if (index < 0 || index >= _lines.length) return;
    final line = _lines[index];
    var at = line.start;
    final render = _lineKeys[index].currentContext?.findRenderObject();
    if (local != null && render is RenderBox) {
      RenderParagraph? paragraph;
      void visit(RenderObject child) {
        if (paragraph != null) return;
        if (child is RenderParagraph) {
          paragraph = child;
          return;
        }
        child.visitChildren(visit);
      }

      render.visitChildren(visit);
      final found = paragraph;
      if (found != null) {
        final global = render.localToGlobal(local);
        final offset = found
            .getPositionForOffset(found.globalToLocal(global))
            .offset;
        at = audiobookSeekForOffset(line, offset);
      }
    }
    unawaited(_jumpLine(line, at));
  }

  void _resumeFollow() {
    setState(() => _following = true);
    _followLine(_position, force: true);
  }

  Future<void> _addBookmark() async {
    await widget.store.addBookmark(
      widget.book,
      _chapter,
      _session.secondsToSave(),
    );
    if (mounted) _toast('已加书签');
  }

  Future<void> _showBookmarks() async {
    final marks = widget.store.bookmarks(widget.book.id);
    if (marks.isEmpty) {
      _toast('还没有书签');
      return;
    }
    final picked = await showModalBottomSheet<AudiobookBookmark>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          children: [
            for (final mark in marks)
              ListTile(
                title: Text(mark.chapterTitle),
                subtitle: Text(formatAudiobookClock(mark.seconds)),
                onTap: () => Navigator.pop(context, mark),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final index = _chapters.indexWhere((item) => item.id == picked.chapterId);
    if (index < 0) {
      _toast('这一章不在当前目录里');
      return;
    }
    await _session.jumpToChapter(index, at: picked.seconds);
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    if (_chapters.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.book.title)),
        body: const StatusPanel(
          title: '没有可以播放的章节',
          message: '先回到目录再选一章。',
          icon: Icons.headphones_rounded,
        ),
      );
    }
    final chapter = _chapter;
    final max = _duration > 1 ? _duration : 1.0;
    final value = (_dragging ? _drag : _position).clamp(0.0, max).toDouble();
    final marks = widget.store.bookmarks(widget.book.id);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.book.title),
        actions: [
          IconButton(
            tooltip: _reading ? '收起原文' : '原文',
            onPressed: () {
              setState(() => _reading = !_reading);
              if (_reading && _texts.isEmpty && !_textLoading) {
                unawaited(_loadText());
              }
            },
            icon: Icon(
              _reading
                  ? Icons.close_fullscreen_rounded
                  : Icons.menu_book_rounded,
            ),
          ),
          IconButton(
            tooltip: '加书签',
            onPressed: _addBookmark,
            icon: const Icon(Icons.bookmark_add_outlined),
          ),
          IconButton(
            tooltip: '书签',
            onPressed: _showBookmarks,
            icon: Badge(
              isLabelVisible: marks.isNotEmpty,
              label: Text('${marks.length}'),
              child: const Icon(Icons.bookmarks_outlined),
            ),
          ),
        ],
      ),
      body: _reading
          ? _manuscript(chapter)
          : Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    chapter.title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _session.loading
                        ? '正在打开'
                        : _session.error != null
                        ? _session.error!
                        : _session.local
                        ? '离线播放'
                        : '在线播放',
                  ),
                  if (_session.loading) const LinearProgressIndicator(),
                  if (_session.error != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () => _session.open(),
                        child: const Text('重试'),
                      ),
                    ),
                  const Spacer(),
                  Row(
                    children: [
                      Text(formatAudiobookClock(_dragging ? _drag : _position)),
                      Expanded(
                        child: Slider(
                          value: value,
                          max: max,
                          onChanged: _duration > 1
                              ? (next) => setState(() {
                                  _dragging = true;
                                  _drag = next;
                                })
                              : null,
                          onChangeEnd: _duration > 1
                              ? (next) async {
                                  setState(() => _dragging = false);
                                  await _session.seekTo(next);
                                }
                              : null,
                        ),
                      ),
                      Text(formatAudiobookClock(_duration)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final speed in const [0.75, 1.0, 1.25, 1.5, 2.0])
                        ChoiceChip(
                          label: Text(speed == 1 ? '1x' : '${speed}x'),
                          selected: _session.speed == speed,
                          onSelected: (_) async {
                            await _session.setSpeed(speed);
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final sleep in AudiobookSleep.values)
                        ChoiceChip(
                          label: Text(sleep.label),
                          selected: _session.sleep == sleep,
                          onSelected: (_) => _session.armSleep(sleep),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton(
                        tooltip: '上一章',
                        onPressed: _session.hasPrevious
                            ? () => _session.step(-1)
                            : null,
                        icon: const Icon(Icons.skip_previous_rounded),
                      ),
                      IconButton(
                        tooltip: '后退 15 秒',
                        onPressed: () => _session.seekBy(-15),
                        icon: const Icon(CupertinoIcons.gobackward_15),
                      ),
                      IconButton(
                        tooltip: _session.playing ? '暂停' : '播放',
                        onPressed: () => _session.playOrPause(),
                        icon: Icon(
                          _session.playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                        ),
                      ),
                      IconButton(
                        tooltip: '前进 15 秒',
                        onPressed: () => _session.seekBy(15),
                        icon: const Icon(CupertinoIcons.goforward_15),
                      ),
                      IconButton(
                        tooltip: '下一章',
                        onPressed: _session.hasNext
                            ? () => _session.step(1)
                            : null,
                        icon: const Icon(Icons.skip_next_rounded),
                      ),
                    ],
                  ),
                ],
              ),
            ),
    );
  }

  Widget _manuscript(FanqieChapter chapter) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _textLoading
              ? const Center(child: CircularProgressIndicator())
              : _lines.isEmpty
              ? StatusPanel(
                  title: '没有原文',
                  message: _textError ?? '这一章暂时没有原文',
                  icon: Icons.menu_book_rounded,
                  onRetry: () => unawaited(_loadText()),
                )
              : Stack(
                  children: [
                    NotificationListener<UserScrollNotification>(
                      onNotification: (notification) {
                        if (notification.direction != ScrollDirection.idle &&
                            _following) {
                          setState(() => _following = false);
                        }
                        return false;
                      },
                      child: SingleChildScrollView(
                        controller: _textScroll,
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 72),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (var index = 0; index < _lines.length; index++)
                              _manuscriptLine(theme, index),
                          ],
                        ),
                      ),
                    ),
                    if (!_following)
                      Positioned(
                        right: 16,
                        bottom: 12,
                        child: FloatingActionButton.extended(
                          key: const ValueKey('audiobook-follow'),
                          heroTag: null,
                          onPressed: _resumeFollow,
                          icon: const Icon(Icons.my_location_rounded),
                          label: const Text('跟随朗读'),
                        ),
                      ),
                  ],
                ),
        ),
        _miniControls(theme),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Text(
            _timed
                ? '${chapter.title} · 双击句子跳到这里 · 逐句时间轴'
                : '${chapter.title} · 双击段落跳到这里 · 按字数估算位置',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  Widget _manuscriptLine(ThemeData theme, int index) {
    final line = _lines[index];
    final current = index == _line;
    final style = theme.textTheme.bodyLarge?.copyWith(height: 1.65);
    final segment = current ? audiobookSegmentAt(line, _position) : -1;
    Offset? tapAt;
    return Padding(
      key: _lineKeys[index],
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: current
            ? theme.colorScheme.primaryContainer
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: GestureDetector(
          key: ValueKey('audiobook-line-$index'),
          behavior: HitTestBehavior.opaque,
          onDoubleTapDown: (details) => tapAt = details.localPosition,
          onDoubleTap: () => _doubleTapLine(index, tapAt),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: line.segments.isEmpty
                ? Text(
                    line.text,
                    style: style?.copyWith(
                      fontWeight: current ? FontWeight.w600 : null,
                    ),
                  )
                : Text.rich(
                    TextSpan(
                      children: [
                        for (var i = 0; i < line.segments.length; i++)
                          TextSpan(
                            text: line.segments[i].text,
                            style: i == segment
                                ? TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: theme.colorScheme.primary,
                                  )
                                : null,
                          ),
                      ],
                    ),
                    style: style,
                  ),
          ),
        ),
      ),
    );
  }

  Widget _miniControls(ThemeData theme) {
    final max = _duration > 0 ? _duration : 1.0;
    final value = (_dragging ? _drag : _position).clamp(0, max).toDouble();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          IconButton(
            tooltip: '后退 15 秒',
            onPressed: () => _session.seekBy(-15),
            icon: const Icon(CupertinoIcons.gobackward_15),
          ),
          IconButton(
            key: const ValueKey('audiobook-mini-play'),
            tooltip: _session.playing ? '暂停' : '播放',
            onPressed: () => _session.playOrPause(),
            icon: Icon(
              _session.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            ),
          ),
          IconButton(
            tooltip: '前进 15 秒',
            onPressed: () => _session.seekBy(15),
            icon: const Icon(CupertinoIcons.goforward_15),
          ),
          Expanded(
            child: Slider(
              value: value,
              max: max,
              onChanged: _duration > 1
                  ? (next) => setState(() {
                      _dragging = true;
                      _drag = next;
                    })
                  : null,
              onChangeEnd: _duration > 1
                  ? (next) async {
                      setState(() {
                        _dragging = false;
                        _following = true;
                      });
                      await _session.seekTo(next);
                      _followLine(next, force: true);
                    }
                  : null,
            ),
          ),
          Text(
            '${formatAudiobookClock(value)} / ${formatAudiobookClock(_duration)}',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _RangeDialog extends StatefulWidget {
  const _RangeDialog();

  @override
  State<_RangeDialog> createState() => _RangeDialogState();
}

class _RangeDialogState extends State<_RangeDialog> {
  final _from = TextEditingController();
  final _to = TextEditingController();

  @override
  void dispose() {
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('下载范围'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _from,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(labelText: '起始章节号'),
          ),
          TextField(
            controller: _to,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(labelText: '结束章节号'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final start = int.tryParse(_from.text.trim());
            final end = int.tryParse(_to.text.trim());
            if (start == null || end == null || start < 1 || end < 1) return;
            Navigator.pop(context, (start: start, end: end));
          },
          child: const Text('下载'),
        ),
      ],
    );
  }
}

/// 目录每行固定高度，滚动条拖动和“跳到章节”才能精确落到某一章。
const audiobookChapterRowExtent = 72.0;

/// 第 [index] 章在目录里的滚动位置（夹在可滚动范围内）。
double audiobookChapterOffset(int index, int count, double maxExtent) {
  if (count <= 0) return 0;
  final target = index.clamp(0, count - 1) * audiobookChapterRowExtent;
  return target.clamp(0.0, maxExtent < 0 ? 0.0 : maxExtent).toDouble();
}

/// 按章节号快速定位：拖动滑条或直接输入第几章。
class _ChapterJumpSheet extends StatefulWidget {
  const _ChapterJumpSheet({required this.chapters});

  final List<FanqieChapter> chapters;

  @override
  State<_ChapterJumpSheet> createState() => _ChapterJumpSheetState();
}

class _ChapterJumpSheetState extends State<_ChapterJumpSheet> {
  double _value = 0;

  @override
  Widget build(BuildContext context) {
    final count = widget.chapters.length;
    final index = _value.round().clamp(0, count - 1);
    final chapter = widget.chapters[index];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('第 ${index + 1} / $count 章'),
            Text(
              chapter.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Slider(
              key: const ValueKey('audiobook-chapter-jump-slider'),
              value: _value,
              max: (count - 1).toDouble(),
              divisions: count > 1 ? count - 1 : null,
              label: '${index + 1}',
              onChanged: (next) => setState(() => _value = next),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, index),
              child: const Text('跳到这一章'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 听书迷你播放条：离开播放页后仍在后台朗读时显示，可暂停、关掉或回到播放页。
class AudiobookNowPlayingBar extends StatelessWidget {
  const AudiobookNowPlayingBar({super.key});

  @override
  Widget build(BuildContext context) {
    final session = AudiobookSession.instance;
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final book = session.book;
        final chapter = session.chapter;
        final repository = session.repository;
        final api = session.api;
        final store = session.store;
        if (book == null ||
            chapter == null ||
            repository == null ||
            api == null ||
            store == null) {
          return const SizedBox.shrink();
        }
        final theme = Theme.of(context);
        return Material(
          key: const ValueKey('audiobook-now-playing'),
          color: theme.colorScheme.surfaceContainerHigh,
          child: SafeArea(
            top: false,
            child: ListTile(
              leading: const Icon(Icons.headphones_rounded),
              title: Text(
                book.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                session.loading
                    ? '${chapter.title} · 正在打开'
                    : '${chapter.title} · ${formatAudiobookClock(session.position)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => AudiobookPlayerScreen(
                    repository: repository,
                    api: api,
                    store: store,
                    book: book,
                    chapters: session.chapters,
                    index: session.index,
                  ),
                ),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: session.playing ? '暂停' : '播放',
                    onPressed: session.playOrPause,
                    icon: Icon(
                      session.playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                    ),
                  ),
                  IconButton(
                    tooltip: '停止听书',
                    onPressed: session.stop,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 单个书源的书池快照，供切换书源时直接复用。
class _AudiobookPoolCache {
  const _AudiobookPoolCache({
    required this.male,
    required this.female,
    required this.categories,
    required this.done,
    this.loadedPages = const {},
    this.hasMore = const {},
  });

  final List<FanqieBook> male;
  final List<FanqieBook> female;
  final List<String> categories;
  final bool done;

  /// 红果按需分页状态随书池一起缓存，切回书源时原样恢复。
  final Map<String, int> loadedPages;
  final Map<String, bool> hasMore;

  bool get hasBooks => male.isNotEmpty || female.isNotEmpty;
}
