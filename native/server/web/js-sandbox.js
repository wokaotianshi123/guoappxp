'use strict';

// JS 沙箱（本地服务版）的前端控制层。
//
// 脚本在 js-sandbox-worker.js 里执行，这里负责：
//   1. 与服务端交换脚本列表（/api/js/sources）；
//   2. 把脚本的 fetch 转给 /api/js/fetch（服务端代发，绕开 CORS 并带站源 UA）；
//   3. 把 CatPawOpen 的目录 / 详情 / 取流结果翻译成核心同形状的 JSON，
//      这样发现页、搜索页、观看页都不需要为脚本源改一行；
//   4. 提供「JS 沙箱」管理页。

var JsSandbox = (function () {
  var DEVICE_KEY = 'duoapp:jsSandbox:device';

  var state = {
    sources: [],
    active: '',
    entries: null,
    worker: null,
    scriptId: '',
    meta: {},
    ready: null,
    seq: 0,
    waiters: {},
    initError: '',
  };

  function readDevice() {
    try {
      return window.localStorage.getItem(DEVICE_KEY) || '';
    } catch (error) {
      return '';
    }
  }

  function writeDevice(json) {
    try {
      window.localStorage.setItem(DEVICE_KEY, json);
    } catch (error) {
      /* 隐私模式写不了，只在当前会话生效 */
    }
  }

  function request(url, options) {
    return fetch(url, options || {}).then(function (response) {
      if (!response.ok) {
        return response.text().then(function (text) {
          throw new Error(text || '请求失败（HTTP ' + response.status + '）');
        });
      }
      return response;
    });
  }

  // ---------------------------------------------------------------- 脚本管理

  function refresh() {
    return request('/api/js/sources')
      .then(function (response) {
        return response.json();
      })
      .then(function (data) {
        state.sources = (data && data.items) || [];
        state.active = (data && data.active) || '';
        state.entries = ownEntries();
        return state.sources;
      })
      .catch(function () {
        state.sources = [];
        state.entries = [];
        return [];
      });
  }

  /// 列表里的站源条目，与 /api/sources 的字段对齐（loadSources 直接拼）。
  function ownEntries() {
    return state.sources.map(function (item) {
      return {
        id: 'js:' + item.id,
        name: item.name || item.id,
        group: 'js',
        groupName: 'JS 沙箱',
        visible: true,
        module: false,
      };
    });
  }

  function sourceEntries() {
    if (state.entries) return Promise.resolve(state.entries);
    return refresh().then(function () {
      return state.entries || [];
    });
  }

  function sourceNames() {
    var names = {};
    state.sources.forEach(function (item) {
      names['js:' + item.id] = item.name || item.id;
    });
    return names;
  }

  function importSource(payload) {
    return request('/api/js/sources', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    })
      .then(function (response) {
        return response.json();
      })
      .then(function (data) {
        return refresh().then(function () {
          return data;
        });
      });
  }

  function importZip(file) {
    return file.arrayBuffer()
      .then(function (buffer) {
        return request('/api/js/sources', {
          method: 'POST',
          headers: { 'Content-Type': 'application/zip' },
          body: buffer,
        });
      })
      .then(function (response) {
        return response.json();
      })
      .then(function (data) {
        return refresh().then(function () {
          return data;
        });
      });
  }

  // 批量导入后的提示：导入几个、失败几条（含原因）。
  function importSummary(data, fallback) {
    var imported = (data && data.imported) || [];
    var failed = (data && data.failed) || [];
    var lines = [];
    if (imported.length) {
      lines.push('已导入 ' + imported.length + ' 个脚本源：' +
        imported.map(function (item) {
          return (item && item.name) || (item && item.id) || '未命名';
        }).join('、'));
    }
    if (failed.length) {
      lines.push('失败 ' + failed.length + ' 个：' + failed.join('；'));
    }
    return lines.length ? lines.join('\n') : (fallback || '导入完成');
  }

  function removeSource(id) {
    return request('/api/js/sources?id=' + encodeURIComponent(id), { method: 'DELETE' }).then(function () {
      return refresh();
    });
  }

  function activate(id) {
    return request('/api/js/active', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ id: id }),
    })
      .then(function () {
        state.active = id;
        return true;
      })
      .catch(function () {
        return false;
      });
  }

  // ---------------------------------------------------------------- Worker

  function handles(source) {
    return typeof source === 'string' && source.indexOf('js:') === 0;
  }

  function scriptIdOf(source) {
    return String(source || '').replace(/^js:/, '');
  }

  function ensureWorker(source) {
    var id = scriptIdOf(source);
    if (!id) return Promise.reject(new Error('不是脚本源'));
    if (state.worker && state.scriptId === id && state.ready) {
      return state.ready;
    }
    if (state.worker) {
      state.worker.terminate();
      state.worker = null;
      state.ready = null;
      state.scriptId = '';
    }
    state.initError = '';
    var worker;
    try {
      worker = new Worker('/web/js-sandbox-worker.js');
    } catch (error) {
      return Promise.reject(new Error('当前浏览器不支持 Web Worker，无法运行脚本源'));
    }
    state.worker = worker;
    state.scriptId = id;
    worker.onmessage = function (event) {
      routeMessage(event.data || {});
    };
    worker.onerror = function (event) {
      state.initError = (event && event.message) || '脚本线程崩溃';
      if (state.ready) state.ready = null;
    };
    state.ready = new Promise(function (resolve, reject) {
      state.resolveReady = { resolve: resolve, reject: reject };
      request('/api/js/source?id=' + encodeURIComponent(id))
        .then(function (response) {
          return response.text();
        })
        .then(function (script) {
          worker.postMessage({
            type: 'init',
            script: script,
            device: readDevice(),
          });
        })
        .catch(function (error) {
          state.ready = null;
          reject(error);
        });
    });
    return state.ready;
  }

  function routeMessage(data) {
    if (data.type === 'ready') {
      var ready = state.resolveReady;
      state.resolveReady = null;
      if (data.ok) {
        state.meta = data.meta || {};
        if (ready) ready.resolve(state.meta);
      } else {
        state.initError = data.error || '脚本加载失败';
        if (ready) ready.reject(new Error(state.initError));
      }
      return;
    }
    if (data.type === 'result') {
      var waiter = state.waiters[data.id];
      if (!waiter) return;
      delete state.waiters[data.id];
      if (data.ok) {
        waiter.resolve(data.value);
      } else {
        var failure = new Error(data.error || '脚本执行失败');
        failure.code = data.code || 'JS_EXECUTION';
        waiter.reject(failure);
      }
      return;
    }
    if (data.type === 'fetch') {
      relayFetch(data);
      return;
    }
    if (data.type === 'device') {
      writeDevice(String(data.json || ''));
    }
  }

  /// 脚本里的 fetch → 服务端代发。Worker 拿不到 Cookie，也不该拿；
  /// 站源需要的 UA / Referer 由脚本自己放在 headers 里。
  function relayFetch(message) {
    var worker = state.worker;
    if (!worker) return;
    fetch('/api/js/fetch', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        url: message.url,
        method: message.method,
        headers: message.headers,
        body: message.body,
        timeoutMs: message.timeoutMs,
      }),
    })
      .then(function (response) {
        return response.json();
      })
      .then(function (data) {
        worker.postMessage({
          type: 'fetchResult',
          id: message.id,
          status: data.status || 0,
          headers: data.headers || {},
          body: data.body == null ? '' : data.body,
          error: data.error || '',
          errorDetail: data.errorDetail || '',
        });
      })
      .catch(function (error) {
        worker.postMessage({
          type: 'fetchResult',
          id: message.id,
          status: 0,
          body: '',
          error: 'NETWORK',
          errorDetail: error.message || '网络请求失败',
        });
      });
  }

  function call(method, args) {
    return new Promise(function (resolve, reject) {
      var worker = state.worker;
      if (!worker) {
        reject(new Error('脚本尚未加载'));
        return;
      }
      var id = ++state.seq;
      state.waiters[id] = { resolve: resolve, reject: reject };
      worker.postMessage({ type: 'call', id: id, method: method, args: args || [] });
    });
  }

  function invoke(source, method, args) {
    return ensureWorker(source).then(function () {
      return call(method, args);
    });
  }

  // ---------------------------------------------------------------- 协议映射

  function cleanCover(raw) {
    var value = String(raw || '').trim();
    if (!value) return '';
    if (value.indexOf('//') === 0) return 'https:' + value;
    if (!/^https?:\/\//i.test(value)) return '';
    return value;
  }

  function tagsOf(vod) {
    var raw = vod.vod_tag || vod.tags;
    var rows = [];
    if (typeof raw === 'string') {
      rows = raw.split(',');
    } else if (Array.isArray(raw)) {
      rows = raw.map(String);
    }
    var junk = ['vip', '付费', '付费短剧', 'vip专享', '预告'];
    return rows
      .map(function (item) {
        return String(item).trim();
      })
      .filter(function (item) {
        return item && junk.indexOf(item.toLowerCase()) === -1;
      })
      .slice(0, 12);
  }

  /// 分类名归一，与 App 端 `categoryNameOf` 同一套口径。
  ///
  /// 脚本源会给出 `app:discover:*`、`find_drama` 这类内部标识，直接显示在
  /// 界面上就是「app:discover:playlet」或者干脆空着，所以统一翻成人话。
  function categoryNameOf(raw) {
    var value = String(raw == null ? '' : raw).trim();
    if (value.indexOf('app:discover:') === 0) {
      var genre = value.split(':').pop();
      if (genre === 'playlet') return '真人剧';
      if (genre === 'motion_comic') return '漫剧';
      if (genre === 'ai_playlet') return 'AI 剧';
      return '短剧';
    }
    if (value.indexOf('app:') === 0 || value.indexOf('hongguo-app:') === 0) {
      return '短剧';
    }
    if (value === 'find_drama') return '短剧';
    var compact = value.replace(/\s+/g, '');
    switch (compact) {
      case 'AI成人短剧':
      case 'AI短剧':
        return 'AI 短剧';
      case 'AI成人漫剧':
      case 'AI漫剧':
        return 'AI 漫剧';
      case 'AI换脸':
        return 'AI 换脸';
      case 'AI魔改':
        return 'AI 魔改';
      case 'AI剧':
        return 'AI 剧';
      case 'real-drama':
      case 'real_series':
        return '真人剧';
      case 'comic-drama':
      case 'comic_series':
      case 'comic':
        return '漫剧';
      case 'ai-drama':
      case 'ai_series':
        return 'AI 剧';
      case '':
        return '未分类';
      default:
        return value;
    }
  }

  function toDrama(source, vod, fallbackCategory) {
    var rawId = String(vod.vod_id || '').trim();
    var remarks = String(vod.vod_remarks || '');
    var counted = /(\d+)/.exec(remarks);
    var title = String(vod.vod_name || '').trim();
    return {
      id: source + ':' + (rawId || Date.now()),
      source: source,
      sourceId: rawId,
      title: title || '短剧',
      description: String(vod.vod_content || '').trim(),
      cover: cleanCover(vod.vod_pic),
      episodes: Number(vod.vod_episodes) || (counted ? Number(counted[1]) : 0),
      category: categoryNameOf(
        String(vod.vod_category || fallbackCategory || '').trim(),
      ),
      vip: vod.vip === true,
      heat: String(vod.vod_heat || ''),
      views: String(vod.vod_views || ''),
      score: String(vod.vod_score || ''),
      tags: tagsOf(vod),
      releaseStatus: String(vod.vod_release_status || ''),
    };
  }

  /// CatVod 的 vod_play_url：多线路用 $$$ 分隔，集用 #，每集「标题$编号」。
  /// `vod_play_from` 用 $$$ 给出对应线路名。返回全部线路，供详情页做线路切换。
  function routesOf(vod) {
    var raw = String((vod && vod.vod_play_url) || '').trim();
    if (!raw) return [];
    var names = String((vod && vod.vod_play_from) || '')
      .split('$$$')
      .map(function (item) {
        return item.trim();
      });
    var routes = [];
    raw.split('$$$').forEach(function (line, position) {
      var chapters = chaptersOfLine(line);
      if (!chapters.length) return;
      var name =
        position < names.length && names[position]
          ? names[position]
          : '线路 ' + (routes.length + 1);
      routes.push({ name: name, chapters: chapters });
    });
    return routes;
  }

  /// 只取第一条线路（单线路源的常规情况）。
  function chaptersOf(playUrl) {
    return chaptersOfLine(playUrl);
  }

  function chaptersOfLine(line) {
    var value = String(line || '').trim();
    if (!value) return [];
    var chapters = [];
    var index = 0;
    value.split('#').forEach(function (item) {
      var trimmed = item.trim();
      if (!trimmed) return;
      index += 1;
      var title = '第 ' + index + ' 集';
      var playId = trimmed;
      if (trimmed.indexOf('$') !== -1) {
        var parts = trimmed.split('$');
        if (parts[0].trim()) title = parts[0].trim();
        playId = parts.slice(1).join('$').trim();
      }
      chapters.push({
        id: playId || String(index),
        title: title,
        index: index,
      });
    });
    return chapters;
  }

  /// 把单集编号规整成脚本认识的形式：纯数字 / 下划线编号前补 seriesId。
  function playTarget(sourceId, chapter, episodeIndex) {
    var target = '';
    if (chapter && typeof chapter === 'object') {
      target = String(chapter.raw || chapter.id || chapter.url || '');
    } else if (typeof chapter === 'string') {
      target = chapter;
    }
    target = target.trim() || String(episodeIndex || 1);
    if (
      target.indexOf('http://') !== 0 &&
      target.indexOf('https://') !== 0 &&
      target.indexOf('/') === -1 &&
      target.indexOf('_') === -1 &&
      sourceId
    ) {
      target = sourceId + '_' + target;
    }
    return target;
  }

  function errorMessage(error) {
    var code = String((error && error.code) || '');
    var map = {
      MISSING_EPISODE: '这一集还没有可播放的分集',
      MEDIA_URL_EXPIRED: '播放地址已过期，请重新获取',
      MEDIA_REJECTED: '播放地址暂不可用，请重试',
      NO_STREAM: '站源没有返回播放地址',
      GUEST_REGISTRATION_FAILED: '官方会话初始化失败，请重试',
      DRM_PROTECTED: '这一集的片源是 DRM 加密的，没有播放器密钥解不出来，本源只能浏览；官方源需内置签名参数才能播放',
      SOURCE_CONFIGURATION_MISSING: '这个脚本需要签名参数：内置官方源已随安装包配置好；自定义脚本请在 JS 沙箱 › 签名参数里填密钥后重试',
      CANCELLED: '请求已取消',
    };
    return map[code] || (error && error.message ? String(error.message) : '脚本执行失败');
  }

  // ---------------------------------------------------------------- 请求拦截

  /// /api/request 的脚本源分支。返回 null 表示不认识，交回核心。
  function handleRequest(payload) {
    var action = payload && payload.action;
    var source = payload && payload.source;
    if (!source && payload && payload.drama) source = sourceOfDrama(payload.drama);
    if (!handles(source)) return null;
    var scriptId = scriptIdOf(source);
    var sourceIdFallback = payload && payload.drama ? String(payload.drama.sourceId || '') : '';
    switch (action) {
      case 'catalog':
        return scriptCatalog(source, payload).catch(function (error) {
          throw new Error(errorMessage(error));
        });
      case 'cached':
        return Promise.resolve({ items: [], page: 1, hasMore: false, fresh: false });
      case 'categories':
        return scriptCategories(source).catch(function () {
          return { items: [] };
        });
      case 'detail':
        return scriptDetail(source, payload.drama || {}).catch(function (error) {
          throw new Error(errorMessage(error));
        });
      case 'seasons': {
        var drama = payload.drama || {};
        var seasonId = String(drama.sourceId || '').trim();
        if (!seasonId && drama.id && String(drama.id).indexOf(':') !== -1) {
          seasonId = String(drama.id).split(':').pop();
        }
        return scriptSeasons(source, seasonId).then(function (rows) {
          return { items: rows };
        });
      }
      case 'suggestions':
        if (!scriptId || !payload.query) return Promise.resolve({ items: [] });
        return invoke(source, 'suggestions', [String(payload.query)])
          .then(function (rows) {
            return { items: Array.isArray(rows) ? rows.filter(function (item) {
              return typeof item === 'string' && item.trim();
            }).slice(0, 10) : [] };
          })
          .catch(function () {
            return { items: [] };
          });
      case 'metadata':
      case 'followCheck':
        return Promise.resolve({ drama: payload.drama, items: [] });
      case 'preload':
        return Promise.reject(new Error('脚本源不支持预缓冲'));
      default:
        return null;
    }
  }

  function scriptCatalog(source, payload) {
    var page = Number(payload.page || 1) || 1;
    var query = String(payload.query || '').trim();
    var category = String(payload.category || '');
    if (query) {
      return invoke(source, 'search', [query, false, page]).then(function (result) {
        var list = Array.isArray(result) ? result : (result && result.list) || [];
        var pageCount = result && Number(result.pagecount || result.pageCount) || page;
        return {
          items: list.map(function (vod) {
            return toDrama(source, vod, category);
          }),
          page: page,
          hasMore: page < pageCount,
          fresh: true,
        };
      });
    }
    return invoke(source, 'category', [category, page, false, {}]).then(function (result) {
      var list = (result && result.list) || [];
      var pageCount = Number((result && result.pagecount) || 1) || 1;
      return {
        items: list.map(function (vod) {
          return toDrama(source, vod, category);
        }),
        page: page,
        hasMore: page < pageCount,
        fresh: true,
      };
    });
  }

  function scriptCategories(source) {
    return invoke(source, 'home', [scriptIdOf(source) === 'hongguo']).then(function (home) {
      var classes = (home && (home.class || home.classes)) || [];
      return {
        items: classes
          .map(function (item) {
            return {
              id: String(item.type_id || ''),
              name: String(item.type_name || ''),
            };
          })
          .filter(function (item) {
            return item.id && item.name;
          }),
      };
    });
  }

  /// 系列多季：脚本的 `seriesSeasons` 返回同一系列各季的完整 vod。
  /// 没有该能力的源直接返回空列表，不影响详情页。
  function scriptSeasons(source, sourceId) {
    if (!sourceId) return Promise.resolve([]);
    return invoke(source, 'seriesSeasons', [sourceId])
      .then(function (result) {
        var rows = (result && result.list) || [];
        var seasons = [];
        var seen = {};
        rows.forEach(function (vod) {
          if (!vod) return;
          var id = String(vod.vod_id || '').trim();
          var title = String(vod.vod_name || '').trim();
          var number = Number(vod.season) || 0;
          if (!id || !title || number <= 0 || seen[number]) return;
          seen[number] = true;
          seasons.push({
            number: number,
            drama: toDrama(source, vod, ''),
            playable: vod.playable !== false,
            status: String(vod.status || ''),
          });
        });
        seasons.sort(function (a, b) {
          return a.number - b.number;
        });
        return seasons;
      })
      .catch(function () {
        return [];
      });
  }

  function scriptDetail(source, drama) {
    var sourceId = String(drama.sourceId || '').trim();
    if (!sourceId && drama.id && String(drama.id).indexOf(':') !== -1) {
      sourceId = String(drama.id).split(':').pop();
    }
    if (!sourceId) return Promise.reject(new Error('这部剧缺少源内编号'));
    return invoke(source, 'detail', [sourceId]).then(function (result) {
      var vod = (result && result.vod) || (result && result.list && result.list[0]) || result || {};
      var routes = routesOf(vod);
      var chapters = routes.length ? routes[0].chapters : [];
      if (!chapters.length) {
        var failure = new Error('这个脚本源没有返回可播放的分集');
        failure.code = 'MISSING_EPISODE';
        throw failure;
      }
      // 详情页只展示第一条线路的分集，不把其他线路合并进来（标题不带前缀）；
      // 线路总数通过 routeCount 带到播放页，切线路时按 route 重新解析。
      var episodes = [];
      var primary = routes[0];
      primary.chapters.forEach(function (chapter, position) {
        episodes.push({
          id: chapter.id,
          title: chapter.title,
          index: episodes.length + 1,
          routeName: primary.name,
          routeIndex: 0,
          routeCount: routes.length,
        });
      });
      var merged = Object.assign({}, drama, {
        id: drama.id || source + ':' + sourceId,
        source: source,
        sourceId: sourceId,
        title: String(vod.vod_name || drama.title || '短剧').trim(),
        cover: cleanCover(vod.vod_pic) || drama.cover || '',
        description: String(vod.vod_content || drama.description || '').trim(),
        episodes: episodes.length,
        vip: false,
        tags: tagsOf(vod).length ? tagsOf(vod) : drama.tags || [],
      });
      return { drama: merged, chapters: episodes };
    });
  }

  /// /api/play 的脚本源分支，返回与核心 playPlan 同形状的对象。
  function handlePlay(payload) {
    var drama = (payload && payload.drama) || {};
    var source = sourceOfDrama(drama);
    if (!handles(source)) return null;
    var sourceId = String(drama.sourceId || '').trim();
    if (!sourceId && drama.id && String(drama.id).indexOf(':') !== -1) {
      sourceId = String(drama.id).split(':').pop();
    }
    var index = Number(payload.index || 0) + 1;
    var chapter = payload.chapter || {};
    var route = Number(payload.route || 0) || 0;
    var routeCount = Number(chapter.routeCount) || 1;
    var flags = [{ quality: Number(payload.quality || 0), seriesId: sourceId }];

    // 初始播放走详情页第一条线路；切线路时重新拉详情，按 route 取对应线路的同一集。
    var prepare =
      route > 0 && sourceId
        ? invoke(source, 'detail', [sourceId]).then(function (result) {
            var vod =
              (result && result.vod) ||
              (result && result.list && result.list[0]) ||
              result ||
              {};
            var routes = routesOf(vod);
            if (!routes.length) return null;
            routeCount = routes.length;
            var at = Math.min(route, routes.length - 1);
            var line = routes[at];
            var target = line.chapters[index - 1];
            if (!target) return null;
            return {
              flag: line.name || 'flag',
              target: String(target.id || ''),
              route: at,
            };
          })
        : Promise.resolve({
            flag: String(chapter.routeName || '').trim() || 'flag',
            target: playTarget(sourceId, chapter, index),
            route: 0,
          });

    return prepare
      .then(function (ctx) {
        if (!ctx) {
          var missing = new Error('这条线路没有这一集');
          missing.code = 'MISSING_EPISODE';
          throw missing;
        }
        return invoke(source, 'play', [ctx.flag, ctx.target, flags]).then(function (play) {
          return { play: play, ctx: ctx };
        });
      })
      .catch(function (error) {
        // 编号可能是旧详情里的：重建一次目标再试。
        if (error && error.code === 'MISSING_EPISODE' && sourceId) {
          return invoke(source, 'detail', [sourceId]).then(function (result) {
            var vod = (result && result.vod) || {};
            var routes = routesOf(vod);
            if (!routes.length) throw error;
            var at = Math.min(route, routes.length - 1);
            var chapters = routes[at].chapters;
            if (index > 0 && index <= chapters.length) {
              return invoke(source, 'play', [
                routes[at].name || 'flag',
                chapters[index - 1].id,
                flags,
              ]).then(function (play) {
                return { play: play, ctx: { route: at } };
              });
            }
            throw error;
          });
        }
        throw error;
      })
      .then(function (pair) {
        var play = pair.play;
        if (!play || !play.url) {
          var failure = new Error(errorMessage({ code: (play && play.error) || 'NO_STREAM' }));
          failure.code = (play && play.error) || 'NO_STREAM';
          throw failure;
        }
        var url = String(play.url);
        var headers = play.header || play.headers || {};
        var agent = headers['User-Agent'] || headers['user-agent'] || '';
        var referer = headers['Referer'] || headers['referer'] || '';
        // 浏览器不能给 <video> 加请求头，带头的直链一律走服务端代理。
        if (agent || referer) {
          var proxy = '/api/js/stream?u=' + encodeURIComponent(url);
          if (agent) proxy += '&ua=' + encodeURIComponent(agent);
          if (referer) proxy += '&r=' + encodeURIComponent(referer);
          url = proxy;
        }
        var detected = /\/(2160|1080|720|480|360)p[./]/.exec(String(play.url));
        var quality = Number(play.quality) || (detected ? Number(detected[1]) : 0);
        return {
          url: url,
          mode: 'direct',
          quality: quality,
          qualities: quality ? [quality] : [],
          routeIndex: pair.ctx.route,
          routeCount: routeCount,
          session: '',
          danmakuId: String(play.danmakuId || ''),
        };
      })
      .catch(function (error) {
        throw new Error(errorMessage(error));
      });
  }

  function handlesDrama(drama) {
    return !!handles(sourceOfDrama(drama));
  }

  /// 详情页只带 drama.id（形如 `js:hongguo:7704...`），没有 source 字段。
  /// 站源标识取最后一个冒号前的部分；脚本 id 里不含冒号，这样切分是安全的。
  function sourceOfDrama(drama) {
    if (!drama) return '';
    if (drama.source) return String(drama.source);
    var id = String(drama.id || '');
    var cut = id.lastIndexOf(':');
    return cut > 0 ? id.slice(0, cut) : '';
  }

  // ---------------------------------------------------------------- 管理页

  function signingStatus() {
    return request('/api/js/signing')
      .then(function (response) {
        return response.json();
      })
      .catch(function () {
        return { configured: false };
      });
  }

  function resetWorker() {
    if (state.worker) {
      state.worker.terminate();
    }
    state.worker = null;
    state.ready = null;
    state.scriptId = '';
    state.meta = {};
  }

  function editSigning(container) {
    signingStatus().then(function (status) {
      var current = status && status.configured ? '已配置。' : '未配置。';
      var raw = window.prompt(
        '官方源的 App 接口需要签名参数（id 9 字节 / material 32 字节的 base64）。\n' +
          '粘贴 {"id":"…","material":"…"}；留空并确定表示清除。\n当前：' + current,
        '',
      );
      if (raw === null) return;
      var payload = {};
      if (raw.trim()) {
        try {
          payload = JSON.parse(raw);
        } catch (error) {
          window.alert('不是合法的 JSON');
          return;
        }
      }
      request('/api/js/signing', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      })
        .then(function (response) {
          if (!response.ok) {
            return response.text().then(function (text) {
              throw new Error(text || '保存失败');
            });
          }
          resetWorker();
          render(container);
        })
        .catch(function (error) {
          window.alert(error.message || '保存签名参数失败');
        });
    });
  }

  function render(container) {
    return Promise.all([refresh(), signingStatus()]).then(function (results) {
      var items = results[0];
      var signing = results[1] || { configured: false };
      var rows = items
        .map(function (item) {
          var features = (item.features || [])
            .slice(0, 6)
            .map(function (feature) {
              return '<span class="js-chip">' + escapeHTML(feature) + '</span>';
            })
            .join('');
          return (
            '<div class="js-source' + (item.active ? ' active' : '') + '" data-id="' + escapeHTML(item.id) + '">' +
            '<div class="js-source-head">' +
            '<div class="js-source-title">' + escapeHTML(item.name || item.id) +
            '<span class="js-version">v' + escapeHTML(item.version || '') + '</span></div>' +
            '<div class="js-source-actions">' +
            (item.active
              ? '<span class="js-badge">当前启用</span>'
              : '<button type="button" class="btn" data-activate="' + escapeHTML(item.id) + '">启用</button>') +
            '<button type="button" class="btn danger" data-remove="' + escapeHTML(item.id) + '">删除</button>' +
            '</div>' +
            '</div>' +
            '<div class="js-source-meta">' + escapeHTML(item.fileName || item.id + '.js') +
            (item.author ? ' · ' + escapeHTML(item.author) : '') + '</div>' +
            (item.description ? '<div class="js-source-desc">' + escapeHTML(item.description) + '</div>' : '') +
            (features ? '<div class="js-chips">' + features + '</div>' : '') +
            '</div>'
          );
        })
        .join('');
      container.innerHTML =
        '<div class="lib">' +
        '<div class="lib-tabs">' +
        '<span class="lib-tab active">JS 沙箱（' + items.length + '）</span>' +
        '<span class="spacer"></span>' +
        '<input type="file" id="js-import-file" accept=".js,.json,.zip,application/zip,application/json,text/javascript" style="display:none" />' +
        '<button type="button" class="btn" id="js-import-preset">导入内置源</button>' +
        '<button type="button" class="btn" id="js-import-file-btn">导入文件</button>' +
        '<button type="button" class="btn" id="js-import-url">导入网络地址</button>' +
        '<button type="button" class="btn" id="js-import-code">粘贴源码</button>' +
        '<button type="button" class="btn" id="js-export-btn">导出订阅包</button>' +
        (signing.embedded
          ? '<span class="js-badge">签名参数已内置</span>'
          : '<button type="button" class="btn" id="js-signing">签名参数' +
            (signing.configured ? '（已配置）' : '（未配置）') + '</button>') +
        '</div>' +
        '<div class="js-hint">' +
        '脚本源在浏览器 Worker 里执行：目录、搜索、详情、取流都由脚本自己完成，' +
        '网络请求经本服务代发（绕开跨域限制）。切换脚本即切换整套解析逻辑，不影响内置站源。' +
        '导入支持单个 .js、订阅 JSON，以及带 xiaoguo.json 的订阅包（zip）。' +
        '</div>' +
        (rows || '<div class="empty">还没有脚本源。可以导入内置的官方源，或选择 .js / 订阅 JSON / 订阅包（zip）。</div>') +
        '</div>';
      bind(container);
    });
  }

  function bind(container) {
    var preset = document.getElementById('js-import-preset');
    if (preset) {
      preset.addEventListener('click', function () {
        preset.disabled = true;
        importSource({ preset: 'hongguo' })
          .then(function () {
            render(container);
          })
          .catch(function (error) {
            window.alert(error.message || '导入内置源失败');
            preset.disabled = false;
          });
      });
    }
    var fileButton = document.getElementById('js-import-file-btn');
    var fileInput = document.getElementById('js-import-file');
    if (fileButton && fileInput) {
      fileButton.addEventListener('click', function () {
        fileInput.value = '';
        fileInput.click();
      });
      fileInput.addEventListener('change', function () {
        var file = fileInput.files && fileInput.files[0];
        if (!file) return;
        var lower = (file.name || '').toLowerCase();
        if (lower.endsWith('.zip')) {
          if (file.size > 16 * 1024 * 1024) {
            window.alert('压缩包超过 16MB');
            return;
          }
          importZip(file)
            .then(function (data) {
              return render(container).then(function () {
                window.alert(importSummary(data, '导入完成'));
              });
            })
            .catch(function (error) {
              window.alert(error.message || '导入压缩包失败');
            });
          return;
        }
        var reader = new FileReader();
        reader.onload = function () {
          var text = String(reader.result || '');
          var task = lower.endsWith('.json')
            ? importSource({ config: text })
            : importSource({ fileName: file.name, script: text });
          task
            .then(function (data) {
              return render(container).then(function () {
                window.alert(importSummary(data, '导入完成'));
              });
            })
            .catch(function (error) {
              window.alert(error.message || '导入失败');
            });
        };
        reader.readAsText(file);
      });
    }
    var exportButton = document.getElementById('js-export-btn');
    if (exportButton) {
      exportButton.addEventListener('click', function () {
        exportButton.disabled = true;
        request('/api/js/sources?export=1')
          .then(function (response) {
            return response.blob();
          })
          .then(function (blob) {
            var url = URL.createObjectURL(blob);
            var link = document.createElement('a');
            var stamp = new Date().toISOString().slice(0, 10);
            link.href = url;
            link.download = 'guoapp-js-' + stamp + '.zip';
            document.body.appendChild(link);
            link.click();
            document.body.removeChild(link);
            setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
          })
          .catch(function (error) {
            window.alert(error.message || '导出订阅包失败');
          })
          .then(function () {
            exportButton.disabled = false;
          });
      });
    }
    var urlButton = document.getElementById('js-import-url');
    if (urlButton) {
      urlButton.addEventListener('click', function () {
        var address = window.prompt(
          '脚本直链，或订阅 JSON 地址（里面列着若干脚本名与地址）'
        );
        if (!address) return;
        importSource({ url: address })
          .then(function (data) {
            return render(container).then(function () {
              window.alert(importSummary(data, '导入完成'));
            });
          })
          .catch(function (error) {
            window.alert(error.message || '导入失败');
          });
      });
    }
    var signingButton = document.getElementById('js-signing');
    if (signingButton) {
      signingButton.addEventListener('click', function () {
        editSigning(container);
      });
    }
    var codeButton = document.getElementById('js-import-code');
    if (codeButton) {
      codeButton.addEventListener('click', function () {
        var script = window.prompt('粘贴脚本源码（需含 id / name 的 meta）');
        if (!script) return;
        var name = window.prompt('文件名（以 .js 结尾）', 'custom_source.js');
        if (!name) return;
        importSource({ fileName: name, script: script })
          .then(function () {
            render(container);
          })
          .catch(function (error) {
            window.alert(error.message || '导入失败');
          });
      });
    }
    Array.prototype.forEach.call(container.querySelectorAll('[data-activate]'), function (button) {
      button.addEventListener('click', function () {
        activate(button.getAttribute('data-activate')).then(function () {
          return loadSources().then(function () {
            render(container);
          });
        });
      });
    });
    Array.prototype.forEach.call(container.querySelectorAll('[data-remove]'), function (button) {
      button.addEventListener('click', function () {
        var id = button.getAttribute('data-remove');
        if (!window.confirm('删除脚本源「' + id + '」？本机的 .js 文件会被移除。')) return;
        removeSource(id).then(function () {
          return loadSources().then(function () {
            render(container);
          });
        });
      });
    });
  }

  return {
    refresh: refresh,
    sourceEntries: sourceEntries,
    sourceNames: sourceNames,
    handles: handles,
    handlesDrama: handlesDrama,
    handleRequest: handleRequest,
    handlePlay: handlePlay,
    render: render,
    activate: activate,
  };
})();
