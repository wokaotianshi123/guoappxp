'use strict';

var view = document.getElementById('view');
var sourceSelect = document.getElementById('source');
var searchInput = document.getElementById('search-input');
var searchForm = document.getElementById('search-form');
var allSourcesInput = document.getElementById('all-sources');

// 自动连播的开关存在浏览器本地，换浏览器重开也保留上次的选择。
var AUTO_NEXT_KEY = 'duanjuweb:autoNext';
// 倍速同样记在本地：切集会重建 <video>，不记下来就会被打回 1 倍速。
var PLAY_RATE_KEY = 'duanjuweb:playbackRate';
// 去广告开关默认开，记在本地；关闭后播放加载原画。
var AD_BLOCK_KEY = 'duanjuweb:adBlock';
// 「全部源」勾选偏好记在本地：跨刷新保留，避免切源/翻页时被 URL 参数清掉。
var ALL_SOURCES_KEY = 'duanjuweb:allSources';
// 画质档（原画/锐化）偏好记在本地：切集/换线/刷新后保留选择。
var PICTURE_QUALITY_KEY = 'duanjuweb:pictureQuality';
// 选集倒序开关记在本地：刷新/换剧后仍按上次的排列习惯展示选集。
var EPISODES_REVERSED_KEY = 'duanjuweb:episodesReversed';

function readPictureQuality() {
  var value = { mode: 'original', strength: 50 };
  try {
    var raw = window.localStorage.getItem(PICTURE_QUALITY_KEY);
    if (raw) {
      var parsed = JSON.parse(raw);
      if (parsed && ['original', 'sharpen'].indexOf(parsed.mode) !== -1) {
        value.mode = parsed.mode;
      }
      if (parsed && Number(parsed.strength) === parsed.strength) {
        value.strength = Math.max(0, Math.min(100, parsed.strength | 0));
      }
    }
  } catch (error) {
    // 解析失败回退默认（原画）。
  }
  return value;
}

function writePictureQuality(value) {
  try {
    window.localStorage.setItem(
      PICTURE_QUALITY_KEY,
      JSON.stringify({ mode: value.mode, strength: value.strength | 0 }),
    );
  } catch (error) {
    // 隐私模式写不了本地存储，只在当前会话生效。
  }
}

function readAllSources() {
  try {
    return window.localStorage.getItem(ALL_SOURCES_KEY) === 'on';
  } catch (error) {
    return false;
  }
}

function writeAllSources(value) {
  try {
    window.localStorage.setItem(ALL_SOURCES_KEY, value ? 'on' : 'off');
  } catch (error) {
    // 隐私模式读不了本地存储，只在当前会话生效。
  }
}

function readAdBlock() {
  try {
    return window.localStorage.getItem(AD_BLOCK_KEY) !== 'off';
  } catch (error) {
    return true;
  }
}

function writeAdBlock(value) {
  try {
    window.localStorage.setItem(AD_BLOCK_KEY, value ? 'on' : 'off');
  } catch (error) {
    // 隐私模式下写不了本地存储，只在当前会话生效。
  }
}

var playbackRate = readPlaybackRate();
var resumeFullscreen = false;
var suppressHashRender = false;
var mountToken = 0;

function readPlaybackRate() {
  try {
    var value = Number(window.localStorage.getItem(PLAY_RATE_KEY));
    if (value >= 0.25 && value <= 4) {
      return value;
    }
  } catch (error) {
    // 隐私模式读不到本地存储时用默认倍速。
  }
  return 1;
}

function writePlaybackRate(value) {
  try {
    window.localStorage.setItem(PLAY_RATE_KEY, String(value));
  } catch (error) {
    // 写不进去只在当前会话生效，不影响播放。
  }
}

function readAutoNext() {
  try {
    return window.localStorage.getItem(AUTO_NEXT_KEY) !== 'off';
  } catch (error) {
    return true;
  }
}

function writeAutoNext(value) {
  try {
    window.localStorage.setItem(AUTO_NEXT_KEY, value ? 'on' : 'off');
  } catch (error) {
    // 隐私模式下写不了本地存储，只在当前会话生效。
  }
}

function readEpisodesReversed() {
  try {
    return window.localStorage.getItem(EPISODES_REVERSED_KEY) === 'on';
  } catch (error) {
    return false;
  }
}

function writeEpisodesReversed(value) {
  try {
    window.localStorage.setItem(EPISODES_REVERSED_KEY, value ? 'on' : 'off');
  } catch (error) {
    // 隐私模式下写不了本地存储，只在当前会话生效。
  }
}

var state = {
  // 首页默认源：JS 沙箱里的官方免费短剧。脚本在端侧跑，不依赖商店模块是否
  // 安装；模块红果在下面 loadSources 里作为兜底。
  source: 'js:hongguo',
  categories: [],
  categoriesSource: '',
  category: '',
  page: 1,
  query: '',
  allSources: readAllSources(),
  pictureQuality: readPictureQuality(),
  hasMore: false,
  drama: null,
  chapters: [],
  // 脚本源的多季列表；内核源与单季剧保持空数组。
  seasons: [],
  plan: null,
  index: 0,
  quality: 0,
  route: 0,
  // 详情页选中的线路名（多线路源才有），换剧时清空。
  routeName: '',
  sourceNames: {},
  ffmpeg: true,
  autoNext: readAutoNext(),
  adBlock: readAdBlock(),
  episodesReversed: readEpisodesReversed(),
  library: { history: [], favorites: [] },
  libraryTab: 'history',
  libraryEditing: false,
  librarySelected: {},
  // 收藏夹 / 播放记录搜索框的内容，切标签时不重置，方便同一关键词两边找。
  libraryQuery: '',
  // 跨源聚合搜索得到的同名剧副本（按剧 id 缓存），供详情页「切换播放源」使用。
  crossPeers: {},
};

var hlsInstance = null;
var blackWatchdog = null;
var lastProgressSave = 0;
var autoNextTimer = null;

// 播放失败自动换线（对齐 Flutter 端 fallback 机制）：
// hls.js 出现致命网络/媒体错误时，自动请求下一条线路重建播放，
// 全部线路试完才提示播放失败。
var routeTried = {};
var routeTotal = 1;
var failoverBusy = false;
// 换线前先给当前线路一次原地重试的机会：网络抖动、瞬时限流多数重试即恢复，
// 避免一次抖动就误判死线路。每条线路在一条"连续失败链"里只享受一次这种宽容。
var sameLineRetried = false;
var sameLineRetryTimer = null;
var lastMountUrl = '';

function markRouteTried(route) {
  routeTried[route] = true;
}

function resetRouteTried(route, total) {
  routeTried = {};
  routeTotal = total || 1;
  sameLineRetried = false;
  markRouteTried(route || 0);
}

function nextRouteToTry() {
  for (var route = 0; route < routeTotal; route += 1) {
    if (!routeTried[route]) {
      return route;
    }
  }
  return -1;
}

function failoverRoute(reasonText, skipSameLineRetry) {
  var drama = state.drama;
  var chapters = state.chapters || [];
  var plan = state.plan;
  var video = document.getElementById('player');
  if (!drama || !plan || !video || failoverBusy) {
    return;
  }
  // 宽容第一层：换线前先在当前线路上原地重试一次。
  // 网络抖动、瞬时限流大多重试即恢复，不该因此放弃一条本来能播的线路。
  // skipSameLineRetry 用于确定性故障（如编码不支持），重试也不会变，直接换线。
  if (!sameLineRetried && !skipSameLineRetry) {
    sameLineRetried = true;
    var retryToken = mountToken;
    var resumePos = video.currentTime || 0;
    showNotice('当前线路加载异常，正在原线路重试…', 'switching');
    if (hlsInstance && lastMountUrl) {
      // 只重拉清单，复用同一个 <video>：播放位置由 hls.js 按当前时间续上。
      hlsInstance.loadSource(lastMountUrl);
    } else if (lastMountUrl) {
      video.src = lastMountUrl;
      if (resumePos > 0) {
        video.addEventListener(
          'loadedmetadata',
          function () {
            try {
              video.currentTime = resumePos;
            } catch (error) {
              // 个别流不允许跳转，忽略即可。
            }
          },
          { once: true },
        );
      }
      video.play().catch(function () {});
    }
    // 重试后既没报错也没恢复时（如错误只触发一次的场景），25 秒后兜底继续换线。
    if (sameLineRetryTimer) {
      clearTimeout(sameLineRetryTimer);
    }
    sameLineRetryTimer = setTimeout(function () {
      sameLineRetryTimer = null;
      if (retryToken !== mountToken) {
        return; // 已重建播放（换线/换集），旧兜底作废
      }
      if (video.videoWidth > 0 && !video.paused) {
        return; // 已恢复播放，不需要换线
      }
      failoverRoute(reasonText, true);
    }, 25000);
    return;
  }
  // 宽容第二层：重试仍失败才真正换线。
  var mountAt = mountToken;
  var route = nextRouteToTry();
  if (route < 0) {
    hideVideoBackdrop();
    // 全部线路都失败时给出排查方向：最常见的两个原因是「该走代理的走了直连」
    // 或反过来，用户往往不知道去哪儿改。
    showNotice(
      '播放失败：' + (reasonText || '未知错误') + '（已尝试全部 ' + routeTotal + ' 条线路）。' +
      '国内站源请在站源面板设为「直连」，海外站源（如 Hanime1 / MissAV / 青空）请检查代理或设为「代理」。',
      'error'
    );
    return;
  }
  failoverBusy = true;
  markRouteTried(route);
  showNotice('当前线路无法播放，正在自动切换到线路 ' + (route + 1) + '/' + routeTotal + '…', 'switching');
  apiPlay({
    drama: drama,
    chapter: chapters[state.index],
    index: state.index,
    quality: state.quality || 0,
    route: route,
  })
    .then(function (next) {
      if (mountAt !== mountToken) {
        return; // 用户已手动切线路/换集，放弃这次迟到的换线结果
      }
      state.plan = next;
      state.route = route;
      routeTotal = next.routeCount || routeTotal;
      var routeBox = document.getElementById('route-select');
      if (routeBox) {
        routeBox.value = String(route);
      }
      // 新线路也享有同等的"先原线重试"宽容，mountVideo 里会重置计数。
      // 新线路是新的播放会话，沿用同一 <video> 就地重建，倍速/全屏都不丢。
      mountVideo(next.url, 0);
    })
    .catch(function () {
      if (mountAt !== mountToken) {
        return;
      }
      showNotice('线路 ' + (route + 1) + ' 解析失败，正在尝试其它线路…');
      setTimeout(function () {
        failoverBusy = false;
        if (mountAt === mountToken) {
          // 线路解析失败没有可重试的会话，直接试下一条
          failoverRoute(reasonText, true);
        }
      }, 1500);
    })
    .finally(function () {
      failoverBusy = false;
    });
}

function escapeHTML(value) {
  return String(value === undefined || value === null ? '' : value).replace(/[&<>"']/g, function (char) {
    return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[char];
  });
}

// 全角 ASCII 折成半角、转小写、去掉空白与标点，规则与 App 侧
// catalog_sort.dart 的 normalizedSearchText 一致，两端搜同样的词结果才一样。
function normalizeSearchText(value) {
  var text = String(value === undefined || value === null ? '' : value);
  text = text.replace(/[\uFF01-\uFF5E]/g, function (char) {
    return String.fromCharCode(char.charCodeAt(0) - 0xfee0);
  });
  return text.toLowerCase().replace(/[\s\u3000，。！？、：；·「」『』（）【】《》“”‘’.,!?:;\-_/()\[\]{}]+/g, '');
}

// 汉字取拼音首字母（霸道总裁 → bdzc）。首字母表在 pinyin.js，由
// tool/gen_pinyin_table.dart 用 lpinyin 生成，和 App 侧同一份拼音数据；
// 表没加载时返回空串，退化成只按原文匹配。
function pinyinInitials(text) {
  var table = window.DUANJU_PINYIN_INITIALS || '';
  var letters = '';
  for (var index = 0; index < text.length; index += 1) {
    var code = text.charCodeAt(index);
    if (code >= 0x4e00 && code <= 0x9fff && table) {
      var letter = table.charAt(code - 0x4e00);
      if (letter && letter !== '_') {
        letters += letter;
      }
      continue;
    }
    if ((code >= 0x30 && code <= 0x39) || (code >= 0x61 && code <= 0x7a)) {
      letters += text.charAt(index);
    }
  }
  return letters;
}

// 标题匹配：原文子串优先，拼音首字母兜底。收藏夹 / 播放记录的搜索框都走这里，
// 行为与 App 的 matchesTitle 对齐（`BDZC` 能搜到《霸道总裁》）。
function matchesTitleQuery(title, query) {
  var term = normalizeSearchText(query);
  if (!term) {
    return true;
  }
  var text = normalizeSearchText(title);
  if (text.indexOf(term) !== -1) {
    return true;
  }
  return pinyinInitials(text).indexOf(term) !== -1;
}

function api(payload) {
  // 脚本源（js: 前缀）不走核心：Worker 已经能给出核心同形状的 JSON。
  // 详情请求只带 drama.id（`js:<id>:<源内编号>`），没有 source 字段，
  // 所以这里连 drama 一起判断。
  if (
    window.JsSandbox &&
    payload &&
    (JsSandbox.handles(payload.source) || JsSandbox.handlesDrama(payload.drama))
  ) {
    var handled = JsSandbox.handleRequest(payload);
    if (handled) return handled;
  }
  return fetch('/api/request', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  })
    .then(function (response) {
      return response.json();
    })
    .then(function (data) {
      if (!data.ok) {
        throw new Error(data.error || '请求失败');
      }
      return data.data;
    });
}

function coverSrc(drama) {
  if (!drama || !drama.id) {
    return '';
  }
  var query = new URLSearchParams();
  query.set('id', drama.id);
  if (drama.source) {
    query.set('source', String(drama.source));
  }
  var cover = drama.cover ? String(drama.cover) : '';
  if (/^https?:\/\//i.test(cover)) {
    // 脚本源的封面是 CDN 直链，浏览器直接取即可；走核心会因未知站源 404。
    if (String(drama.source || '').indexOf('js:') === 0) return cover;
    query.set('u', cover);
  }
  return '/api/cover?' + query.toString();
}

function coverHTML(drama) {
  var url = coverSrc(drama);
  if (!url) {
    return '<div class="cover"><div class="fallback">' + escapeHTML(drama.title || '无封面') + '</div></div>';
  }
  return (
    '<div class="cover"><img loading="lazy" src="' +
    escapeHTML(url) +
    '" alt="" onerror="this.style.display=\'none\'" /></div>'
  );
}

/* ---------- 收藏夹与播放记录 ---------- */

function libraryRequest(payload) {
  return fetch('/api/library', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  })
    .then(function (response) {
      return response.json();
    })
    .then(function (data) {
      if (!data.ok) {
        throw new Error(data.error || '收藏夹更新失败');
      }
      state.library = { history: data.data.history || [], favorites: data.data.favorites || [] };
      return state.library;
    });
}

function loadLibrary() {
  return fetch('/api/library')
    .then(function (response) {
      return response.json();
    })
    .then(function (data) {
      if (data && data.ok && data.data) {
        state.library = { history: data.data.history || [], favorites: data.data.favorites || [] };
      }
      return state.library;
    })
    .catch(function () {
      return state.library;
    });
}

function entryKey(drama) {
  var source = (drama && (drama.source || state.source)) || '';
  return String(source) + '|' + String((drama && drama.id) || '');
}

function sourceLabel(source) {
  return state.sourceNames[source] || source || '';
}

// 播放记录要带上海报、片名、站源名称与看到第几集、看到几分几秒。
function currentEntry(position, duration) {
  var drama = state.drama || {};
  var chapter = (state.chapters || [])[state.index] || {};
  return {
    id: drama.id || '',
    source: drama.source || state.source || '',
    sourceName: sourceLabel(drama.source || state.source),
    title: drama.title || '',
    cover: drama.cover || '',
    episodes: drama.episodes ? String(drama.episodes) : '',
    index: state.index,
    episodeTitle: chapter.title || '',
    position: position || 0,
    duration: duration || 0,
    updatedAt: Date.now(),
  };
}

function findEntry(list, key, index) {
  for (var i = 0; i < list.length; i += 1) {
    if (entryKey(list[i]) !== key) {
      continue;
    }
    if (typeof index === 'number' && Number(list[i].index || 0) !== index) {
      continue;
    }
    return list[i];
  }
  return null;
}

function isFavorite(drama) {
  return !!findEntry(state.library.favorites, entryKey(drama || state.drama));
}

function formatTime(seconds) {
  var total = Math.max(0, Math.floor(Number(seconds) || 0));
  var hours = Math.floor(total / 3600);
  var minutes = Math.floor((total % 3600) / 60);
  var rest = total % 60;
  var mm = String(minutes).padStart(hours ? 2 : 1, '0');
  var ss = String(rest).padStart(2, '0');
  return (hours ? hours + ':' + mm : mm) + ':' + ss;
}

function progressText(entry) {
  var parts = ['第 ' + (Number(entry.index || 0) + 1) + ' 集'];
  if (entry.duration > 0 && entry.position > 0) {
    parts.push(formatTime(entry.position) + ' / ' + formatTime(entry.duration));
  } else if (entry.position > 0) {
    parts.push('看到 ' + formatTime(entry.position));
  } else {
    parts.push('刚开始');
  }
  if (entry.episodeTitle && !/^第\s*\d+\s*集$/.test(entry.episodeTitle.trim())) {
    parts.push(entry.episodeTitle);
  }
  return parts.join(' · ');
}

function progressPercent(entry) {
  if (!(entry.duration > 0) || !(entry.position > 0)) {
    return 0;
  }
  return Math.min(100, Math.round((entry.position / entry.duration) * 100));
}

// 播放进度每 5 秒上报一次，切集、暂停、离开页面时立刻补一次。
function reportProgress(force) {
  if (!state.drama) {
    return;
  }
  var video = document.getElementById('player');
  if (!video) {
    return;
  }
  var position = Number(video.currentTime) || 0;
  if (!(position > 0)) {
    return;
  }
  var now = Date.now();
  if (!force && now - lastProgressSave < 5000) {
    return;
  }
  lastProgressSave = now;
  libraryRequest({
    list: 'history',
    op: 'put',
    item: currentEntry(position, Number(video.duration) || 0),
  }).catch(function () {});
}

function flushProgress() {
  reportProgress(true);
}

function hashParams() {
  var raw = location.hash.replace(/^#\/?/, '');
  var parts = raw.split('?');
  return { path: parts[0] || 'home', params: new URLSearchParams(parts[1] || '') };
}

function link(hash) {
  return hash;
}

function loadSources() {
  // JS 沙箱源与内核站源分开取：脚本源的清单在服务端 js_sources 目录里，
  // 这里拼到同一个下拉框，源菜单与 App 端一样按分组折叠。
  var sandboxItems = window.JsSandbox
    ? JsSandbox.sourceEntries()
    : Promise.resolve([]);
  return Promise.all([
    fetch('/api/sources').then(function (response) {
      return response.json();
    }),
    sandboxItems,
  ])
    .then(function (results) {
      var data = results[0];
      var jsItems = results[1] || [];
      var items = ((data && data.items) || []).concat(jsItems);
      state.sourceNames = {};
      // 保留全部站源名称映射（含隐藏的），供收藏夹/播放记录标注来源。
      items.forEach(function (item) {
        state.sourceNames[item.id] = item.name;
      });
      // 下拉框只列「源显示列表」中开启的站源。
      var visibleItems = items.filter(function (item) {
        return item.visible !== false;
      });
      // 按清单的分组（group / groupName）折叠成 optgroup：黄果系三个源归到
      // 「黄果」一组，与 App 端站源面板的分组保持一致；没分组的平铺在最外层。
      var groups = [];
      var groupIndex = {};
      visibleItems.forEach(function (item) {
        var key = item.group || '';
        if (key === '') {
          groups.push({ key: '', name: '', items: [item] });
          return;
        }
        if (groupIndex[key] === undefined) {
          groupIndex[key] = groups.length;
          groups.push({ key: key, name: item.groupName || item.group || key, items: [item] });
          return;
        }
        groups[groupIndex[key]].items.push(item);
      });
      function optionOf(item) {
        return '<option value="' + escapeHTML(item.id) + '">' + escapeHTML(item.name) + '</option>';
      }
      sourceSelect.innerHTML = visibleItems.length
        ? groups
            .map(function (group) {
              if (!group.key) return group.items.map(optionOf).join('');
              return '<optgroup label="' + escapeHTML(group.name) + '">' +
                group.items.map(optionOf).join('') + '</optgroup>';
            })
            .join('')
        : '<option value="">无显示中的站源</option>';
      if (visibleItems.length && !visibleItems.some(function (item) { return item.id === state.source; })) {
        // 默认源是 JS 沙箱的官方短剧；它还没导入时退回模块红果，再不行用首个。
        var fallback = ['js:hongguo', 'hongguo'];
        var preferred = '';
        for (var i = 0; i < fallback.length; i++) {
          if (visibleItems.some(function (item) { return item.id === fallback[i]; })) {
            preferred = fallback[i];
            break;
          }
        }
        state.source = preferred || visibleItems[0].id;
      }
      sourceSelect.value = state.source;
    })
    .catch(function () {});
}

function loadInfo() {
  return fetch('/api/info')
    .then(function (response) {
      return response.json();
    })
    .then(function (data) {
      if (data && data.name) {
        document.getElementById('brand').textContent = data.name;
        document.title = data.name;
      }
      state.ffmpeg = !(data && data.ffmpeg === '');
    })
    .catch(function () {});
}

var FFMPEG_MISSING =
  '未检测到 ffmpeg：红果等加密站源需要服务端转码才能播放，其余站源不受影响。' +
  'Windows 上重新运行 start.bat 会提示下载 ffmpeg；也可以执行 winget install ffmpeg 后重启服务。';

function ffmpegNotice() {
  if (state.ffmpeg) {
    return '';
  }
  return (
    '<div class="notice" style="display:block">' +
    escapeHTML(FFMPEG_MISSING) +
    ' <button type="button" id="ffmpeg-recheck" class="link-btn">重新检测</button>' +
    '</div>'
  );
}

function bindFFmpegRecheck() {
  var button = document.getElementById('ffmpeg-recheck');
  if (!button) {
    return;
  }
  button.addEventListener('click', function () {
    button.disabled = true;
    button.textContent = '检测中…';
    loadInfo().then(function () {
      render();
    });
  });
}

function loadCategories(force) {
  if (!force && state.categories.length && state.categoriesSource === state.source) {
    return Promise.resolve(state.categories);
  }
  return api({ action: 'categories', source: state.source })
    .then(function (data) {
      state.categories = (data.items || []).map(function (item) {
        return { id: item.id || '', name: item.name };
      });
      state.categoriesSource = state.source;
      return state.categories;
    })
    .catch(function () {
      state.categories = [{ id: '', name: '全部' }];
      state.categoriesSource = state.source;
      return state.categories;
    });
}

function hashFor(overrides) {
  var merged = {
    source: state.source,
    category: state.category,
    page: state.page,
    q: state.query,
    cross: state.allSources ? 1 : '',
  };
  Object.keys(overrides || {}).forEach(function (key) {
    merged[key] = overrides[key];
  });
  var query = new URLSearchParams();
  query.set('source', merged.source);
  if (merged.category) query.set('category', merged.category);
  if (merged.q) query.set('q', merged.q);
  if (merged.cross) query.set('cross', '1');
  query.set('page', String(merged.page));
  return '#/home?' + query.toString();
}

// 「全部源」聚合搜索：勾选时并发打所有可见源（含自定义源），核心按标题/年份/集数
// 归一去重后合并。搜索是分批回来的：先 searchStart 拿会话号，再每 200ms 轮询一次
// 快照，哪个站源先回来就先画哪批，不必等最慢的那几个站源。
var crossSearch = { token: 0, id: '', timer: null, painted: '' };

// 模块页当前页签：installed / repos / builtin。
// 源显示已并入「已安装」，在线仓库独立成一页，与 App 端模块页一致。
var moduleTab = 'installed';

// 逐源勾选：与 App 端搜索页的站源勾选条等价。空数组表示「跟随全部源开关」，
// 非空时只并发搜索勾中的这些源。选择记在 localStorage，跨刷新保留。
var PICKED_SOURCES_KEY = 'duanjuweb:pickedSources';

function readPickedSources() {
  try {
    var raw = window.localStorage.getItem(PICKED_SOURCES_KEY);
    var parsed = raw ? JSON.parse(raw) : [];
    return Array.isArray(parsed)
      ? parsed.filter(function (item) { return typeof item === 'string' && item; })
      : [];
  } catch (error) {
    return [];
  }
}

function writePickedSources(ids) {
  try {
    if (ids && ids.length) {
      window.localStorage.setItem(PICKED_SOURCES_KEY, JSON.stringify(ids));
    } else {
      window.localStorage.removeItem(PICKED_SOURCES_KEY);
    }
  } catch (error) {
    /* 隐私模式下写不进去，忽略 */
  }
}

// searchSourceIDs 返回本轮参与搜索的站源：优先用逐源勾选，否则用全部可见源。
function searchSourceIDs(items) {
  var visible = items
    .filter(function (item) { return item.visible; })
    .map(function (item) { return item.id; });
  var picked = readPickedSources();
  if (!picked.length) return visible;
  // 只保留仍然可见的源，避免勾过的源被关掉后还去打它。
  var allowed = {};
  visible.forEach(function (id) { allowed[id] = true; });
  var filtered = picked.filter(function (id) { return allowed[id]; });
  return filtered.length ? filtered : visible;
}

// pickSources 弹出逐源勾选面板。
// pickSources 打开/收起逐源勾选面板。
//
// 面板是单例：重复点击不会叠出多个弹层，再点一次「选源」就收起（需求里
// 明确要求「点击弹出、再次点击收起」）。打开时每次重新拉一次可见源，
// 避免用过期列表。
var pickSourcesPanel = null;

function pickSourcesOpen() {
  return pickSourcesPanel !== null;
}

function closePickSources() {
  if (pickSourcesPanel && pickSourcesPanel.parentNode) {
    pickSourcesPanel.parentNode.removeChild(pickSourcesPanel);
  }
  pickSourcesPanel = null;
  var button = document.getElementById('pick-sources-btn');
  if (button) button.classList.remove('active');
}

function pickSources() {
  // 已打开就收起，不再新建。
  if (pickSourcesOpen()) {
    closePickSources();
    return Promise.resolve();
  }
  return visibilityList().then(function (items) {
    // 拉列表期间可能又被点了一次，重新检查，避免连点叠两层。
    if (pickSourcesOpen()) return;
    var visible = items.filter(function (item) { return item.visible; });
    if (!visible.length) {
      window.alert('没有开启显示的站源，请先在「自定义模块」里开启');
      return;
    }
    var picked = readPickedSources();
    var selected = {};
    if (!picked.length) {
      visible.forEach(function (item) { selected[item.id] = true; });
    } else {
      picked.forEach(function (id) { selected[id] = true; });
    }
    var mask = document.createElement('div');
    mask.className = 'modal-mask';
    mask.innerHTML =
      '<div class="modal" style="max-width:520px">' +
      '<h3 style="margin:0 0 6px">选择搜索站源</h3>' +
      '<div style="font-size:12px;opacity:0.75;margin-bottom:10px">' +
      '勾选后，搜索会并发查询这些站源（含模块与自定义源）。全不勾等于跟随「全部源」开关。' +
      '</div>' +
      '<div id="pick-sources-list" style="max-height:50vh;overflow:auto">' +
      visible
        .map(function (item) {
          return (
            '<label style="display:flex;align-items:center;gap:8px;padding:6px 2px">' +
            '<input type="checkbox" data-source="' + escapeHTML(item.id) + '"' +
            (selected[item.id] ? ' checked' : '') +
            ' />' +
            '<span>' + escapeHTML(item.name) + '</span>' +
            (item.groupName ? '<span style="font-size:11px;opacity:0.6">' + escapeHTML(item.groupName) + '</span>' : '') +
            '</label>'
          );
        })
        .join('') +
      '</div>' +
      '<div style="display:flex;gap:8px;justify-content:flex-end;margin-top:12px">' +
      '<button type="button" class="btn" id="pick-sources-all">全选</button>' +
      '<button type="button" class="btn" id="pick-sources-cancel">取消</button>' +
      '<button type="button" class="btn" id="pick-sources-ok">确定</button>' +
      '</div></div>';
    document.body.appendChild(mask);
    pickSourcesPanel = mask;
    var button = document.getElementById('pick-sources-btn');
    if (button) button.classList.add('active');

    mask.addEventListener('click', function (event) {
      if (event.target === mask) closePickSources();
    });
    mask.querySelector('#pick-sources-cancel').addEventListener('click', closePickSources);
    mask.querySelector('#pick-sources-all').addEventListener('click', function () {
      Array.prototype.forEach.call(
        mask.querySelectorAll('input[data-source]'),
        function (input) { input.checked = true; }
      );
    });
    mask.querySelector('#pick-sources-ok').addEventListener('click', function () {
      var ids = [];
      Array.prototype.forEach.call(
        mask.querySelectorAll('input[data-source]'),
        function (input) { if (input.checked) ids.push(input.getAttribute('data-source')); }
      );
      // 全选等于「跟随全部源」，不写偏好；否则记住勾选。
      writePickedSources(ids.length === visible.length ? [] : ids);
      closePickSources();
      if (state.query) {
        render();
      }
    });
  });
}

function cancelCrossSearch() {
  var previous = crossSearch;
  crossSearch = { token: previous.token + 1, id: '', timer: null, painted: '' };
  if (previous.timer) {
    clearTimeout(previous.timer);
  }
  if (previous.id) {
    api({ action: 'searchCancel', search: previous.id }).catch(function () {});
  }
}

function renderCrossSearch() {
  cancelCrossSearch();
  var token = crossSearch.token;
  view.innerHTML =
    '<div class="cross-head"><span>全部源搜索「' + escapeHTML(state.query) + '」</span>' +
    '<a href="' + escapeHTML(link(hashFor({ q: '' }))) + '">返回目录</a></div>' +
    '<div class="cross-progress"><span>正在联系各站源…</span></div>' +
    '<div class="grid"><div class="empty">正在搜索，结果会边搜边显示…</div></div>';
  return visibilityList().then(function (items) {
    var ids = searchSourceIDs(items);
    if (!ids.length) {
      throw new Error('没有开启显示的站源，请先在「源显示」里开启');
    }
    return api({ action: 'searchStart', sources: ids, query: state.query, page: 1 });
  }).then(function (first) {
    if (token !== crossSearch.token) {
      return;
    }
    crossSearch.id = first.search || '';
    paintCrossResults(first);
    if (!first.finished) {
      pollCrossSearch(token);
    }
  });
}

function pollCrossSearch(token) {
  crossSearch.timer = setTimeout(function () {
    if (token !== crossSearch.token) {
      return;
    }
    var id = crossSearch.id;
    if (!id) {
      return;
    }
    api({ action: 'searchPoll', search: id })
      .then(function (result) {
        if (token !== crossSearch.token) {
          return;
        }
        paintCrossResults(result);
        if (!result.finished) {
          pollCrossSearch(token);
        }
      })
      .catch(function (error) {
        if (token !== crossSearch.token) {
          return;
        }
        // 会话过期或核心重启：给出明确提示，不无限重试把服务打满。
        view.innerHTML = '<div class="empty">' +
          escapeHTML(error.message || '搜索中断，请重新搜索') + '</div>';
      });
  }, 200);
}

function paintCrossResults(result) {
  var items = result.items || [];
  var total = Number(result.total) || 0;
  var done = Number(result.done) || 0;
  var running = !result.finished;
  var warning = result.warning || '';
  // 只在「条目数/进度/提示」真的变了才重绘：轮询很密，没必要每次都重建 DOM，
  // 否则封面图会跟着重新解码、看起来在闪。
  var key = items.length + '|' + done + '|' + total + '|' + (running ? 1 : 0) + '|' + warning;
  if (crossSearch.painted === key) {
    return;
  }
  crossSearch.painted = key;
  state.hasMore = false;
  // 缓存同名剧的各源副本，供详情页「切换播放源」使用（含当前源自身）。
  items.forEach(function (drama) {
    if (!drama.id) {
      return;
    }
    state.crossPeers[drama.id] = [drama].concat(drama.peers || []);
  });
  var cards = items.map(function (drama) {
    var sources = [drama.source || ''].concat(
      (drama.peers || []).map(function (peer) { return peer.source || ''; })
    ).filter(function (value, position, list) {
      return value && list.indexOf(value) === position;
    });
    var badge = sources.map(function (source) {
      return '<span class="card-source" title="' + escapeHTML(sourceLabel(source)) + '">' +
        escapeHTML(sourceLabel(source)) + '</span>';
    }).join('');
    return (
      '<div class="card"><a href="#/drama?id=' + encodeURIComponent(drama.id) +
      (drama.source ? '&source=' + encodeURIComponent(drama.source) : '') + '">' +
      coverHTML(drama) +
      '<div class="title">' + escapeHTML(drama.title) + '</div>' +
      '<div class="meta">' + escapeHTML(drama.episodes ? drama.episodes + ' 集' : '') + '</div>' +
      (badge ? '<div class="meta">' + badge + '</div>' : '') +
      '</a></div>'
    );
  }).join('');
  var percent = total > 0 ? Math.round((done / total) * 100) : 0;
  var progress =
    '<div class="cross-progress"><span>' +
    (running
      ? '已搜索 ' + done + '/' + total + ' 个站源 · 已找到 ' + items.length + ' 条'
      : '已搜索 ' + total + ' 个站源 · 共 ' + items.length + ' 条') +
    '</span>' +
    (running ? '<div class="bar"><span style="width:' + percent + '%"></span></div>' : '') +
    '</div>';
  var notice = warning
    ? '<div class="cross-warning">部分站源未返回结果：' + escapeHTML(warning) + '</div>'
    : '';
  var empty = running
    ? '<div class="empty">正在搜索，结果会边搜边显示…</div>'
    : '<div class="empty">没有找到内容，换个关键词试试。</div>';
  view.innerHTML =
    '<div class="cross-head">' +
    '<span>全部源搜索「' + escapeHTML(state.query) + '」</span>' +
    '<a href="' + escapeHTML(link(hashFor({ q: '' }))) + '">返回目录</a>' +
    '</div>' +
    progress +
    notice +
    '<div class="grid">' + (cards || empty) + '</div>';
}

function renderCatalog() {
  view.innerHTML = '<div class="loading">正在加载剧库…</div>';
  return loadCategories(false).then(function (categories) {
    var payload = {
      action: 'catalog',
      source: state.source,
      category: state.category,
      page: state.page,
    };
    if (state.query) {
      payload.query = state.query;
    }
    return api(payload).catch(function (error) {
      if (state.category === '' && categories.length > 1) {
        state.category = categories[1].id;
        return api({ action: 'catalog', source: state.source, category: state.category, page: state.page });
      }
      throw error;
    });
  }).then(function (result) {
    var items = result.items || [];
    state.hasMore = !!result.hasMore;
    var chips = state.categories
      .map(function (item) {
        var active = item.id === state.category ? ' active' : '';
        return (
          '<a class="chip' + active + '" href="' +
          escapeHTML(link(hashFor({ category: item.id, page: 1 }))) +
          '">' + escapeHTML(item.name) + '</a>'
        );
      })
      .join('');
    var cards = items
      .map(function (drama) {
        return (
          '<div class="card"><a href="#/drama?id=' + encodeURIComponent(drama.id) + '">' +
          coverHTML(drama) +
          '<div class="title">' + escapeHTML(drama.title) + '</div>' +
          '<div class="meta">' + escapeHTML(drama.episodes ? drama.episodes + ' 集' : '') + '</div>' +
          '</a></div>'
        );
      })
      .join('');
    if (!cards) {
      cards = '<div class="empty">没有找到内容，换个分类或关键词试试。</div>';
    }
    var previous = state.page > 1
      ? '<a href="' + escapeHTML(link(hashFor({ page: state.page - 1 }))) + '">上一页</a>'
      : '<span class="disabled">上一页</span>';
    var next = state.hasMore
      ? '<a href="' + escapeHTML(link(hashFor({ page: state.page + 1 }))) + '">下一页</a>'
      : '<span class="disabled">下一页</span>';
    view.innerHTML =
      ffmpegNotice() +
      '<div class="chips">' + chips + '</div>' +
      '<div class="grid">' + cards + '</div>' +
      '<div class="pager">' + previous + '<span>第 ' + state.page + ' 页</span>' + next + '</div>';
    bindFFmpegRecheck();
  });
}

function ensureDrama(id, source) {
  if (
    state.drama &&
    state.drama.id === id &&
    (!source || !state.drama.source || state.drama.source === source)
  ) {
    return Promise.resolve(state.drama);
  }
  var drama = { id: id };
  if (source) {
    drama.source = source;
  }
  return api({ action: 'detail', drama: drama }).then(function (data) {
    // 换剧后线路选择作废，否则会沿用上一部剧的线路名。
    if (state.drama && state.drama.id !== id) {
      state.routeName = '';
    }
    state.drama = data.drama;
    state.chapters = data.chapters || [];
    state.seasons = [];
    // 脚本源的多季是异步补的：接口慢或没实现都不该拖住详情页。
    api({ action: 'seasons', drama: data.drama })
      .then(function (result) {
        var items = (result && result.items) || [];
        if (state.drama && state.drama.id === data.drama.id) {
          state.seasons = items;
          refreshSeasonChips();
        }
      })
      .catch(function () {
        // 没有多季能力，保持空列表。
      });
    return state.drama;
  });
}

// #/drama（无 index）进入观看页时，落到该剧最近看的一集；没有记录就看第一集。
function defaultWatchIndex(dramaRef) {
  var remembered = findEntry(state.library.history, entryKey(dramaRef));
  return remembered ? Number(remembered.index || 0) : 0;
}

// 中间选集区：当前集高亮，点击走就地换集（不销毁 <video>，倍速/全屏保留）。
// 「倒序」开关改变格子显示顺序（第 N 集→第 1 集 反向排列），上一集/下一集/自动连播
// 也按屏幕上的排列顺序走（见 episodeNextIndex/episodePrevIndex）；
// 格子的 data-index / href 仍指向真实集序，换集后高亮与地址栏不会错位。

// 多线路数据来自核心：TVBox 源把每条线路的每一集都编进同一个列表，标题写成
// 「线路名 · 集名」。这里按同样的分隔符拆回线路，与 App 端 detail_routes.dart 一致。
var ROUTE_SEPARATOR = ' · ';

function splitRouteTitle(title) {
  var text = String(title || '');
  var sep = text.indexOf(ROUTE_SEPARATOR);
  if (sep <= 0) return null;
  var route = text.slice(0, sep).trim();
  var label = text.slice(sep + ROUTE_SEPARATOR.length).trim();
  if (!route) return null;
  return { route: route, label: label };
}

// detailRoutes 返回 [{ name, entries: [{ position, label }] }]；
// 不是「线路名 · 集名」编码时返回空数组（单线路源不显示线路区块）。
function detailRoutes(chapters) {
  if (!chapters || !chapters.length) return [];
  var grouped = {};
  var order = [];
  for (var i = 0; i < chapters.length; i += 1) {
    var split = splitRouteTitle((chapters[i] || {}).title);
    if (!split) return [];
    if (!grouped[split.route]) {
      grouped[split.route] = [];
      order.push(split.route);
    }
    grouped[split.route].push({ position: i, label: split.label });
  }
  if (order.length < 2) return [];
  return order.map(function (name) {
    return { name: name, entries: grouped[name] };
  });
}

// currentRouteName 返回当前选中线路；没有记录时落到当前播放集所在线路。
function currentRouteName(routes) {
  var selected = state.routeName;
  if (selected && routes.some(function (route) { return route.name === selected; })) {
    return selected;
  }
  var index = state.index || 0;
  var matched = routes.filter(function (route) {
    return route.entries.some(function (entry) { return entry.position === index; });
  })[0];
  return (matched || routes[0]).name;
}

// routeSectionHTML 渲染「线路」区块：放在「选集」上方，左右 16px 边距。
function routeSectionHTML() {
  var routes = detailRoutes(state.chapters || []);
  if (routes.length < 2) return '';
  var active = currentRouteName(routes);
  var chips = routes.map(function (route) {
    return '<button type="button" class="route-chip' +
      (route.name === active ? ' active' : '') +
      '" data-route="' + escapeHTML(route.name) + '">' +
      escapeHTML(route.name) + ' (' + route.entries.length + ')</button>';
  }).join('');
  return '<div class="section route-section">' +
    '<div class="section-title"><span>线路</span></div>' +
    '<div class="route-chips">' + chips + '</div>' +
    '</div>';
}

function episodesGridInnerHTML() {
  var drama = state.drama;
  var chapters = state.chapters || [];
  var suffix = drama.source ? '&source=' + encodeURIComponent(drama.source) : '';
  // 多线路时只显示当前线路的集；单线路沿用原来的整表。
  var routes = detailRoutes(chapters);
  var positions = chapters.map(function (unused, position) {
    return position;
  });
  if (routes.length >= 2) {
    var active = currentRouteName(routes);
    var route = routes.filter(function (item) { return item.name === active; })[0];
    positions = route.entries.map(function (entry) { return entry.position; });
  }
  if (state.episodesReversed) {
    positions = positions.slice().reverse();
  }
  var cells = positions
    .map(function (position) {
      var active = position === state.index ? ' active' : '';
      var title = (chapters[position] || {}).title || '第 ' + (position + 1) + ' 集';
      return (
        '<a class="ep-link' + active + '" data-index="' + position + '" href="#/play?id=' +
        encodeURIComponent(drama.id) + '&index=' + position + suffix + '">' +
        escapeHTML(title) +
        '</a>'
      );
    })
    .join('');
  var reversedToggle =
    '<label class="toggle ep-reverse" title="选集列表倒序展示，上一集/下一集也按这个顺序走">' +
    '<input type="checkbox" id="episodes-reversed"' +
    (state.episodesReversed ? ' checked' : '') + '>倒序</label>';
  var count = routes.length >= 2 ? positions.length : chapters.length;
  return (
    '<div class="section-title"><span>选集（' + count + '）</span>' +
    reversedToggle + '</div>' +
    '<div class="episodes">' + cells + '</div>'
  );
}

function episodesGridHTML() {
  var chapters = state.chapters || [];
  if (!chapters.length) {
    return '';
  }
  return routeSectionHTML() +
    '<div class="section" id="episodes-section">' + episodesGridInnerHTML() + '</div>';
}

// 底部详情区：海报 + 简介 + 元信息 + 切换播放源（同一剧在其它站源的副本）。
function detailSectionHTML() {
  var drama = state.drama;
  var ownSource = drama.source || '';
  var copies = (state.crossPeers[drama.id] || [])
    .filter(function (peer) {
      return peer.source && peer.source !== ownSource;
    });
  var peerChips = copies
    .map(function (peer) {
      var label = sourceLabel(peer.source) + (peer.episodes ? '（' + peer.episodes + ' 集）' : '');
      return (
        '<a class="chip peer-chip" href="#/play?id=' + encodeURIComponent(peer.id) +
        '&index=' + state.index +
        (peer.source ? '&source=' + encodeURIComponent(peer.source) : '') + '">' +
        escapeHTML(label) + '</a>'
      );
    })
    .join('');
  var peerSection = copies.length
    ? '<div class="chips"><span class="chips-label">切换播放源：</span>' + peerChips + '</div>'
    : '';
  var seasons = state.seasons || [];
  var seasonSection =
    '<div id="season-chips">' + seasonChipsHTML(drama, seasons) + '</div>';
  return (
    '<div class="section"><div class="section-title">详情</div>' +
    '<div class="detail">' +
    '<div class="poster">' + coverHTML(drama) + '</div>' +
    '<div class="info">' +
    '<h1>' + escapeHTML(drama.title) + '</h1>' +
    '<div class="desc">' + escapeHTML(drama.description || '暂无简介') + '</div>' +
    '<div class="meta" style="color:var(--muted)">共 ' + (state.chapters || []).length + ' 集' +
    (drama.source ? ' · ' + escapeHTML(sourceLabel(drama.source)) : '') + '</div>' +
    seasonSection +
    peerSection +
    '</div></div></div>'
  );
}

// 多季是异步补的（接口慢或脚本没实现都不该拖住播放页），所以先渲染一个
// 空容器，等 seasons 回来再单独刷新这一块。
function seasonChipsHTML(drama, seasons) {
  if (!seasons || seasons.length <= 1) return '';
  var chips = seasons
    .map(function (season) {
      if (!season.drama) return '';
      var active = season.drama.id === drama.id;
      var label = '第' + season.number + '季';
      if (season.status) label += ' · ' + season.status;
      return (
        '<a class="chip season-chip' + (active ? ' active' : '') + '"' +
        ' href="#/play?id=' + encodeURIComponent(season.drama.id) +
        (season.drama.source ? '&source=' + encodeURIComponent(season.drama.source) : '') +
        '&index=0">' + escapeHTML(label) + '</a>'
      );
    })
    .join('');
  if (!chips) return '';
  return '<div class="chips"><span class="chips-label">切换季：</span>' + chips + '</div>';
}

// seasons 回来时如果播放页还在同一部剧，就地补上「切换季」，不重建 <video>。
function refreshSeasonChips() {
  var box = document.getElementById('season-chips');
  if (!box || !state.drama) return;
  box.innerHTML = seasonChipsHTML(state.drama, state.seasons || []);
}

// ---- 画质档（原画 / 锐化）----
// 锐化走 SVG feConvolveMatrix 卷积核。
// 偏好存 localStorage，切集/换线/刷新保留。
var PICTURE_QUALITY_MODES = ['original', 'sharpen'];
var pictureQuality = {
  video: null,
  noteTimer: null,
};

function pictureQualitySelectHTML() {
  var value = state.pictureQuality || { mode: 'original', strength: 50 };
  var options = PICTURE_QUALITY_MODES
    .map(function (mode) {
      var label = mode === 'original' ? '原画' : '锐化';
      var selected = value.mode === mode ? ' selected' : '';
      return '<option value="' + mode + '"' + selected + '>' + label + '</option>';
    })
    .join('');
  var showStrength = value.mode === 'sharpen' ? '' : ' style="display:none"';
  return (
    '<span class="picture-quality" title="画质档：只增强播放画面，下载文件保持原画">' +
    '<label>画质档 <select id="picture-quality-select">' + options + '</select></label>' +
    '<label class="picture-quality-strength" id="picture-quality-strength-wrap"' + showStrength + '>' +
    '锐化强度 <input id="picture-quality-strength" type="range" min="0" max="100" step="5" value="' + (value.strength | 0) + '"></label>' +
    '</span>'
  );
}

// 锐化 SVG 卷积滤镜 + 提示浮层，注入在 <video> 之后、绝对定位覆盖画面。
function pictureEnhancementChrome() {
  return (
    '<svg class="picture-quality-svg" aria-hidden="true" focusable="false">' +
    '<defs><filter id="picture-sharpen-filter" x="0" y="0" width="100%" height="100%" colorInterpolationFilters="sRGB">' +
    '<feConvolveMatrix order="3" kernelMatrix="0 -1 0 -1 5 -1 0 -1 0" divisor="1" bias="0" edgeMode="duplicate" preserveAlpha="true"/>' +
    '</filter></defs></svg>' +
    '<div class="picture-quality-note" id="picture-quality-note" style="display:none"></div>'
  );
}

function pictureSharpenKernel(strength) {
  var amount = Math.max(0, Math.min(100, Number(strength) || 0)) / 100 * 0.7;
  return [0, -amount, 0, -amount, 1 + 4 * amount, -amount, 0, -amount, 0];
}

function pictureQualitySetSharpen(video) {
  var strength = (state.pictureQuality || {}).strength || 50;
  var kernel = pictureSharpenKernel(strength);
  var filter = document.getElementById('picture-sharpen-filter');
  if (filter) {
    var matrix = filter.querySelector('feConvolveMatrix');
    if (matrix) {
      matrix.setAttribute('kernelMatrix', kernel.join(' '));
    }
  }
  video.style.filter = 'url(#picture-sharpen-filter)';
}

// 切到锐化时显示强度滑块，其余档隐藏。
function syncPictureQualityControls(strengthWrap, strengthBox) {
  if (strengthWrap) {
    strengthWrap.style.display = state.pictureQuality.mode === 'sharpen' ? '' : 'none';
  }
  if (strengthBox) {
    strengthBox.value = (state.pictureQuality.strength | 0) || 0;
  }
}

// 把当前画质档应用到给定 <video>：清旧效果后按档生效。
function applyPictureQuality(video) {
  teardownPictureQuality();
  var value = state.pictureQuality || { mode: 'original' };
  if (value.mode === 'sharpen') {
    pictureQuality.video = video;
    pictureQualitySetSharpen(video);
    showPictureQualityNote('锐化已开启（强度 ' + ((value.strength | 0) || 50) + '%）');
  } else {
    showPictureQualityNote('');
  }
}


function teardownPictureQuality() {
  if (pictureQuality.video) {
    pictureQuality.video.style.filter = '';
    pictureQuality.video = null;
  }
}

// 提示浮层显示 2 秒后自动消失，避免长期遮挡进度条控制。
function showPictureQualityNote(message) {
  var note = document.getElementById('picture-quality-note');
  if (!note) return;
  if (pictureQuality.noteTimer) {
    clearTimeout(pictureQuality.noteTimer);
    pictureQuality.noteTimer = null;
  }
  note.textContent = message || '';
  note.style.display = message ? 'block' : 'none';
  if (message) {
    pictureQuality.noteTimer = setTimeout(function () {
      pictureQuality.noteTimer = null;
      note.textContent = '';
      note.style.display = 'none';
    }, 2000);
  }
}

// 融合观看页整页骨架：顶部播放器（video + 控制条）+ 中间选集 + 底部详情。
function watchPageHTML(plan, index, message, kind) {
  var qualities = plan.qualities || [];
  var current = plan.quality || 0;
  if (qualities.indexOf(current) === -1 && qualities.length) {
    current = qualities[0];
  }
  var qualitySelect = qualities.length
    ? '<label>画质 <select id="quality-select">' +
      qualities
        .map(function (item) {
          return optionHTML(item, item + 'P', item === current);
        })
        .join('') +
      '</select></label>'
    : '';
  var pictureQuality = pictureQualitySelectHTML();
  var routeTotal = plan.routeCount || 1;
  var routeSelect =
    '<label>线路 <select id="route-select">' +
    Array.apply(null, new Array(routeTotal))
      .map(function (unused, position) {
        return optionHTML(position, '线路 ' + (position + 1) + '/' + routeTotal, position === (plan.routeIndex || 0));
      })
      .join('') +
    '</select></label>';
  var chapters = state.chapters || [];
  // 三个控件一律渲染，可见性交给 syncEpisodeNav 按当前排列方向决定：
  // 倒序时列表顶部是最后一集、原始第 1 集才是末尾，静态判断会判反。
  var next = '<button type="button" class="btn" id="episode-next" style="display:none">下一集</button>';
  var previous = '<button type="button" class="btn" id="episode-previous" style="display:none">上一集</button>';
  var favorite = isFavorite(state.drama)
    ? '<button type="button" class="btn active" id="fav-toggle">已收藏</button>'
    : '<button type="button" class="btn" id="fav-toggle">收藏</button>';
  var autoNextBox =
    '<label class="toggle" title="播完自动跳到下一集" style="display:none">' +
    '<input type="checkbox" id="auto-next"' + (state.autoNext ? ' checked' : '') + '>自动连播</label>';
  var adBlockBox = '<label class="toggle" title="播放前清洗 m3u8，剔除插播在时间线里的广告分片；关闭后加载原画">' +
    '<input type="checkbox" id="ad-block"' + (state.adBlock ? ' checked' : '') + '>去广告</label>';
  var playerWrap =
    '<div class="player-wrap">' +
    '<div class="player-title">' +
    escapeHTML(state.drama.title) + ' · ' + escapeHTML(((state.chapters || [])[index] || {}).title || '') +
    '</div>' +
    '<div class="player-stage">' +
    '<video id="player" controls autoplay playsinline></video>' +
    pictureEnhancementChrome() +
    '</div>' +
    '<div class="notice" id="play-note" data-kind="' + kind + '"' +
    (message ? ' style="display:block"' : '') + '>' +
    escapeHTML(message) +
    '</div>' +
    '<div class="notice next-up" id="next-up"></div>' +
    '<div class="player-bar">' + qualitySelect + pictureQuality + routeSelect +
    '<span class="spacer"></span>' + adBlockBox + autoNextBox + favorite + previous + next +
    '</div></div>';
  return '<div class="watch">' + playerWrap + episodesGridHTML() + detailSectionHTML() + '</div>';
}

// 融合观看页：#/drama 与 #/play 统一入口，播放器在最上、选集居中、详情沉底。
function renderWatch(id, index, source) {
  if (index === undefined || index === null || index === '') {
    index = defaultWatchIndex({ id: id, source: source });
  }
  index = Number(index) || 0;
  // 整页重建会换掉 <video>，先把倍速和全屏状态记下来。
  capturePlaybackState();
  flushProgress();
  view.innerHTML = '<div class="loading">正在加载剧集…</div>';
  state.index = index;
  return ensureDrama(id, source)
    .then(function () {
      // 切源/切集后目标集数可能超出该源实际分集数，越界则收回到最后一集。
      var chapters = state.chapters || [];
      if (chapters.length && state.index >= chapters.length) {
        state.index = chapters.length - 1;
      }
      index = state.index;
      return apiPlay({
        drama: state.drama,
        chapter: (state.chapters || [])[index],
        index: index,
        quality: state.quality || 0,
        route: state.route || 0,
      });
    })
    .then(function (plan) {
      state.plan = plan;
      resetRouteTried(plan.routeIndex || 0, plan.routeCount || 1);
      var message = '';
      var kind = '';
      if (plan.message === '需要 ffmpeg 转码' || (plan.mode === 'direct' && plan.encrypted)) {
        message = FFMPEG_HINT;
      } else if (plan.mode === 'direct' && plan.hevc) {
        message = HEVC_NOTICE;
      } else if (plan.transcoding) {
        message = '服务端正在转码，首次缓冲可能需要十几秒…';
        kind = 'transcode';
      } else if (plan.message) {
        message = plan.message;
      }
      view.innerHTML = watchPageHTML(plan, index, message, kind);
      var resumeAt = 0;
      var remembered = findEntry(state.library.history, entryKey(state.drama), index);
      if (remembered && remembered.position > 5) {
        resumeAt = remembered.position;
      }
      mountVideo(plan.url, resumeAt);
      bindFavoriteToggle(state.drama);
      bindEpisodes();
      // 打开播放页就先记一条播放记录，之后的进度由播放器持续更新。
      libraryRequest({ list: 'history', op: 'put', item: currentEntry(resumeAt, 0) }).catch(function () {});
      var qualityBox = document.getElementById('quality-select');
      if (qualityBox) {
        qualityBox.addEventListener('change', function () {
          state.quality = Number(qualityBox.value);
          state.route = 0;
          renderWatch(id, index, source);
        });
      }
      var routeBox = document.getElementById('route-select');
      if (routeBox) {
        routeBox.addEventListener('change', function () {
          state.route = Number(routeBox.value);
          renderWatch(id, index, source);
        });
      }
      var pictureQualityBox = document.getElementById('picture-quality-select');
      if (pictureQualityBox) {
        var strengthWrap = document.getElementById('picture-quality-strength-wrap');
        var strengthBox = document.getElementById('picture-quality-strength');
        pictureQualityBox.addEventListener('change', function () {
          state.pictureQuality.mode = pictureQualityBox.value;
          writePictureQuality(state.pictureQuality);
          syncPictureQualityControls(strengthWrap, strengthBox);
          var video = document.getElementById('player');
          if (video) {
            applyPictureQuality(video);
          }
        });
        if (strengthBox) {
          strengthBox.addEventListener('input', function () {
            state.pictureQuality.strength = Number(strengthBox.value) | 0;
            writePictureQuality(state.pictureQuality);
            var video = document.getElementById('player');
            if (video && state.pictureQuality.mode === 'sharpen') {
              pictureQualitySetSharpen(video);
            }
          });
        }
      }
      var autoNextToggle = document.getElementById('auto-next');
      if (autoNextToggle) {
        autoNextToggle.addEventListener('change', function () {
          state.autoNext = autoNextToggle.checked;
          writeAutoNext(state.autoNext);
          if (!state.autoNext) {
            cancelAutoNext();
          }
        });
      }
      var adBlockToggle = document.getElementById('ad-block');
      if (adBlockToggle) {
        adBlockToggle.addEventListener('change', function () {
          state.adBlock = adBlockToggle.checked;
          writeAdBlock(state.adBlock);
          // 重新解析当前集让开关立即生效（核心按新会话清洗或放行原画）。
          flushProgress();
          renderWatch(id, index, source);
        });
      }
      var nextButton = document.getElementById('episode-next');
      if (nextButton) {
        nextButton.addEventListener('click', function () {
          playNextEpisode();
        });
      }
      var previousButton = document.getElementById('episode-previous');
      if (previousButton) {
        previousButton.addEventListener('click', function () {
          playPreviousEpisode();
        });
      }
      // 进页时先按当前排列方向定好上一集/下一集/自动连播的可见性。
      syncEpisodeNav(index);
      // 整页重建（换画质/线路）后，若进入本页前处于全屏，重新进全屏。
      // 就地换集（下一集/上一集/自动连播）不会走这里，全屏由 <video> 保留。
      restoreFullscreen();
    });
}

// 选集格子点击：拦截默认跳转，改走就地换集，复用同一个 <video>。
function bindEpisodes() {
  // 「线路」区块：切线路只重排选集格子，不打断正在播放的画面。
  var routeChips = view.querySelectorAll('.route-chip');
  Array.prototype.forEach.call(routeChips, function (chip) {
    chip.addEventListener('click', function () {
      var route = chip.getAttribute('data-route') || '';
      if (!route || route === currentRouteName(detailRoutes(state.chapters || []))) {
        return;
      }
      state.routeName = route;
      rerenderEpisodes();
    });
  });
  var links = view.querySelectorAll('.ep-link');
  Array.prototype.forEach.call(links, function (anchor) {
    anchor.addEventListener('click', function (event) {
      var targetIndex = Number(anchor.getAttribute('data-index'));
      event.preventDefault();
      if (targetIndex === state.index) {
        return;
      }
      playToIndex(targetIndex);
    });
  });
  // 「倒序」开关：切档只重排选集格子，不销毁 <video>，全屏/倍速/进度都保留。
  var reversedToggle = document.getElementById('episodes-reversed');
  if (reversedToggle) {
    reversedToggle.addEventListener('change', function () {
      state.episodesReversed = reversedToggle.checked;
      writeEpisodesReversed(state.episodesReversed);
      rerenderEpisodes();
      // 排列方向变了，上一集/下一集的可见性要立刻跟着变。
      syncEpisodeNav(state.index);
    });
  }
}

// 只重写选集区（正序/倒序），复用同一个 <video>；随后重新绑定格子与开关事件。
function rerenderEpisodes() {
  var section = document.getElementById('episodes-section');
  if (!section) {
    return;
  }
  section.innerHTML = episodesGridInnerHTML();
  bindEpisodes();
  highlightEpisode(state.index);
}

// 就地跳到指定集：复用 <video>，更新选中高亮与地址栏（不整页重建）。
function playToIndex(targetIndex) {
  var drama = state.drama;
  var chapters = state.chapters || [];
  var video = document.getElementById('player');
  if (!drama || targetIndex < 0 || targetIndex >= chapters.length) {
    return Promise.resolve(false);
  }
  cancelAutoNext();
  if (!video) {
    location.hash = episodeHash(drama.id, drama.source, targetIndex);
    window.scrollTo(0, 0);
    return Promise.resolve(true);
  }
  state.route = 0;
  flushProgress();
  showNotice('正在加载第 ' + (targetIndex + 1) + ' 集…');
  return apiPlay({
    drama: drama,
    chapter: chapters[targetIndex],
    index: targetIndex,
    quality: state.quality || 0,
    route: 0,
  })
    .then(function (plan) {
      if (!document.body.contains(video)) {
        return false;
      }
      state.index = targetIndex;
      state.plan = plan;
      resetRouteTried(plan.routeIndex || 0, plan.routeCount || 1);
      var note = document.getElementById('play-note');
      if (note) {
        note.textContent = '';
        note.style.display = 'none';
      }
      syncEpisodeChrome(targetIndex);
      mountVideo(plan.url, 0);
      libraryRequest({ list: 'history', op: 'put', item: currentEntry(0, 0) }).catch(function () {});
      return true;
    })
    .catch(function (error) {
      showNotice(error.message || '切换集数失败，请手动重试。');
      return false;
    });
}

// 就地换集后同步选集格子的高亮（当前集点亮，其余熄灭）。
function highlightEpisode(index) {
  var links = view.querySelectorAll('.ep-link');
  Array.prototype.forEach.call(links, function (anchor) {
    anchor.classList.toggle('active', Number(anchor.getAttribute('data-index')) === index);
  });
}

function favoritePayload(drama) {
  return {
    id: drama.id || '',
    source: drama.source || state.source || '',
    sourceName: sourceLabel(drama.source || state.source),
    title: drama.title || '',
    cover: drama.cover || '',
    episodes: drama.episodes ? String(drama.episodes) : '',
    index: 0,
    episodeTitle: '',
    position: 0,
    duration: 0,
    updatedAt: Date.now(),
  };
}

// 点一次加入收藏，再点一次取消。
function bindFavoriteToggle(drama) {
  var button = document.getElementById('fav-toggle');
  if (!button) {
    return;
  }
  button.addEventListener('click', function () {
    button.disabled = true;
    libraryRequest({ list: 'favorites', op: 'toggle', item: favoritePayload(drama) })
      .then(function () {
        var active = isFavorite(drama);
        button.textContent = active ? '已收藏' : '收藏';
        button.classList.toggle('active', active);
        button.disabled = false;
      })
      .catch(function (error) {
        button.disabled = false;
        showNotice(error.message || '收藏失败');
      });
  });
}

function episodeHash(id, source, index) {
  return (
    '#/play?id=' + encodeURIComponent(id) +
    '&index=' + index +
    (source ? '&source=' + encodeURIComponent(source) : '')
  );
}

// 自动连播不再做倒计时确认，播完直接加载下一集。
function stopAutoNextTimer() {
  if (autoNextTimer) {
    clearInterval(autoNextTimer);
    autoNextTimer = null;
  }
}

function cancelAutoNext() {
  stopAutoNextTimer();
  var box = document.getElementById('next-up');
  if (box) {
    box.style.display = 'none';
  }
}

// 换集时同步标题与上一集/下一集按钮状态，并让地址栏跟上（不触发整页重建）。
// 选集排列方向：倒序打开时屏幕上是「最后一集 → 第 1 集」，上一集/下一集
// 也按屏幕顺序走，否则点「下一集」会跳到列表另一端，看着像乱序。
function episodeStep() {
  return state.episodesReversed ? -1 : 1;
}

// 当前排列下「下一个」格子的真实集索引；越界返回 -1。
function episodeNextIndex(index) {
  var total = (state.chapters || []).length;
  var next = index + episodeStep();
  return next >= 0 && next < total ? next : -1;
}

// 当前排列下「上一个」格子的真实集索引；越界返回 -1。
function episodePrevIndex(index) {
  var total = (state.chapters || []).length;
  var prev = index - episodeStep();
  return prev >= 0 && prev < total ? prev : -1;
}

// 上一集/下一集/自动连播三个控件的可见性，统一跟着排列方向走。
function syncEpisodeNav(index) {
  var nextIndex = episodeNextIndex(index);
  var prevIndex = episodePrevIndex(index);
  var next = document.getElementById('episode-next');
  if (next) {
    next.disabled = nextIndex < 0;
    next.style.display = nextIndex >= 0 ? '' : 'none';
  }
  var previous = document.getElementById('episode-previous');
  if (previous) {
    previous.disabled = prevIndex < 0;
    previous.style.display = prevIndex >= 0 ? '' : 'none';
  }
  // 自动连播开关跟着「还有没有下一集」走：倒序时原始第 1 集才是末尾。
  var autoNext = document.getElementById('auto-next');
  if (autoNext && autoNext.parentNode) {
    autoNext.parentNode.style.display = nextIndex >= 0 ? '' : 'none';
  }
}

function syncEpisodeChrome(index) {
  var drama = state.drama;
  var chapters = state.chapters || [];
  var title = document.querySelector('.player-title');
  if (title && drama) {
    title.textContent = drama.title + ' · ' + ((chapters[index] || {}).title || '');
  }
  // 上一集/下一集按当前排列方向决定能不能点。
  syncEpisodeNav(index);
  var hash = drama ? episodeHash(drama.id, drama.source, index) : '';
  if (hash && location.hash !== hash) {
    // 只改地址栏，并标记本次 hashchange 不重建页面（就地换集复用同一个 <video>）。
    suppressHashRender = true;
    location.hash = hash;
  }
  // 选集格子高亮跟着当前集走（下一集/上一集/自动连播/点格子四条路径共用这里）。
  highlightEpisode(index);
}

// 就地换集：复用同一个 <video>，全屏和倍速都不会被重置。
function playNextEpisode() {
  var drama = state.drama;
  var chapters = state.chapters || [];
  // 倒序时「下一集」是原始集序的上一集，所以用排列方向算，而不是 index + 1。
  var nextIndex = episodeNextIndex(state.index);
  var video = document.getElementById('player');
  if (!drama || nextIndex < 0) {
    return Promise.resolve(false);
  }
  cancelAutoNext();
  if (!video) {
    // 播放器还没建好时退回整页跳转。
    location.hash = episodeHash(drama.id, drama.source, nextIndex);
    window.scrollTo(0, 0);
    return Promise.resolve(true);
  }
  state.route = 0;
  flushProgress();
  showNotice('正在加载下一集…');
  return apiPlay({
    drama: drama,
    chapter: chapters[nextIndex],
    index: nextIndex,
    quality: state.quality || 0,
    route: 0,
  })
    .then(function (plan) {
      if (!document.body.contains(video)) {
        return false;
      }
      state.index = nextIndex;
      state.plan = plan;
      resetRouteTried(plan.routeIndex || 0, plan.routeCount || 1);
      var note = document.getElementById('play-note');
      if (note) {
        note.textContent = '';
        note.style.display = 'none';
      }
      syncEpisodeChrome(nextIndex);
      mountVideo(plan.url, 0);
      libraryRequest({ list: 'history', op: 'put', item: currentEntry(0, 0) }).catch(function () {});
      return true;
    })
    .catch(function (error) {
      showNotice(error.message || '下一集加载失败，请手动点“下一集”重试。');
      return false;
    });
}

// 上一集：和下一集一样就地换集，复用同一个 <video>，倍速与全屏都不丢。
function playPreviousEpisode() {
  var drama = state.drama;
  var chapters = state.chapters || [];
  var prevIndex = episodePrevIndex(state.index);
  var video = document.getElementById('player');
  if (!drama || prevIndex < 0) {
    return Promise.resolve(false);
  }
  cancelAutoNext();
  if (!video) {
    location.hash = episodeHash(drama.id, drama.source, prevIndex);
    window.scrollTo(0, 0);
    return Promise.resolve(true);
  }
  state.route = 0;
  flushProgress();
  showNotice('正在加载上一集…');
  return apiPlay({
    drama: drama,
    chapter: chapters[prevIndex],
    index: prevIndex,
    quality: state.quality || 0,
    route: 0,
  })
    .then(function (plan) {
      if (!document.body.contains(video)) {
        return false;
      }
      state.index = prevIndex;
      state.plan = plan;
      resetRouteTried(plan.routeIndex || 0, plan.routeCount || 1);
      var note = document.getElementById('play-note');
      if (note) {
        note.textContent = '';
        note.style.display = 'none';
      }
      syncEpisodeChrome(prevIndex);
      mountVideo(plan.url, 0);
      libraryRequest({ list: 'history', op: 'put', item: currentEntry(0, 0) }).catch(function () {});
      return true;
    })
    .catch(function (error) {
      showNotice(error.message || '上一集加载失败，请手动点“上一集”重试。');
      return false;
    });
}

// 本集播完直接进下一集；已是最后一集或开关关闭时只做提示。
function scheduleAutoNext() {
  var nextIndex = episodeNextIndex(state.index);
  if (!state.drama || nextIndex < 0) {
    showNotice('已经没有下一集了。');
    return;
  }
  if (!state.autoNext) {
    return;
  }
  playNextEpisode();
}

function fitVideo(video) {
  var width = video.videoWidth;
  var height = video.videoHeight;
  if (!width || !height) {
    return;
  }
  // 竖屏短剧很常见，按真实比例收窄并居中，画面最大化又不超出屏幕。
  if (height > width) {
    video.classList.add('portrait');
    video.style.setProperty('--ratio', String(width / height));
  } else {
    video.classList.remove('portrait');
    video.style.removeProperty('--ratio');
  }
}

function stopPlayback() {
  cancelAutoNext();
  flushProgress();
  teardownPictureQuality();
  if (hlsInstance) {
    hlsInstance.destroy();
    hlsInstance = null;
  }
  state.plan = null;
}

function apiPlay(payload) {
  if (payload && payload.adBlock === undefined) {
    payload.adBlock = state.adBlock;
  }
  if (window.JsSandbox && JsSandbox.handlesDrama(payload && payload.drama)) {
    return JsSandbox.handlePlay(payload);
  }
  return fetch('/api/play', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  })
    .then(function (response) {
      return response.json();
    })
    .then(function (data) {
      if (!data.ok) {
        throw new Error(data.error || '解析播放地址失败');
      }
      // 服务端回 verify 表示这一集要先用浏览器完成验证（广告短链带 Cloudflare
      // 挑战）。本地服务版跑在浏览器里，直接开一个窗口让用户走完验证，
      // 拿到落地地址后带上 pageUrl 重新解析。
      if (data.data && data.data.verify) {
        return verifyInBrowser(data.data.verify).then(function (landed) {
          if (!landed) {
            throw new Error('没有完成验证，已取消播放');
          }
          var retry = Object.assign({}, payload);
          retry.chapter = Object.assign({}, payload.chapter || {}, {
            pageUrl: landed,
            videoUrl: '',
          });
          return apiPlay(retry);
        });
      }
      return data.data;
    });
}

// verifyInBrowser 在浏览器里打开短链验证页，返回落地地址。
//
// 本地服务版没有隐藏浏览器，用一个居中的小窗口打开短链：用户在里面完成
// Cloudflare 挑战后，窗口把最终地址回传给主页面。窗口被关掉时返回空串。
function verifyInBrowser(address) {
  return new Promise(function (resolve) {
    var width = 520;
    var height = 680;
    var left = Math.max(0, Math.round((window.screen.width - width) / 2));
    var top = Math.max(0, Math.round((window.screen.height - height) / 2));
    var popup = window.open(
      address,
      'guoapp-verify',
      'width=' + width + ',height=' + height + ',left=' + left + ',top=' + top
    );
    if (!popup) {
      resolve('');
      return;
    }
    var settled = false;
    function finish(value) {
      if (settled) return;
      settled = true;
      clearInterval(timer);
      try {
        if (popup && !popup.closed) popup.close();
      } catch (error) {
        /* 跨域时关不掉，忽略 */
      }
      resolve(value || '');
    }
    // 短链会在验证后跳转到播放器站点；同源能读到 location，跨域读不到时
    // 退到「地址变了就认为已落地」。最多等 3 分钟。
    var started = Date.now();
    var last = address;
    var timer = setInterval(function () {
      if (Date.now() - started > 180000) {
        finish('');
        return;
      }
      if (!popup || popup.closed) {
        finish('');
        return;
      }
      var current = '';
      try {
        current = popup.location.href || '';
      } catch (error) {
        current = '';
      }
      if (!current || current === 'about:blank') return;
      if (current === last) return;
      last = current;
      if (/^(https?:)/.test(current) && !isVerifyLanding(current, address)) {
        finish(current);
      }
    }, 800);
  });
}

// isVerifyLanding 判断当前地址是否还停在短链/广告页（没落地到播放器）。
function isVerifyLanding(current, origin) {
  try {
    var now = new URL(current);
    var from = new URL(origin);
    if (now.host === from.host) return true;
  } catch (error) {
    return true;
  }
  return false;
}

// 红果等站源的视频是加密的 H.265，浏览器既不能解密也不能解码，
// 只能由服务端用 ffmpeg 解密重编码后再播。
var FFMPEG_HINT =
  '这一集是加密的 H.265 视频，浏览器无法直接播放，需要服务端转码。' +
  '请先安装 ffmpeg（Windows：winget install ffmpeg；macOS：brew install ffmpeg），' +
  '放到本程序同一个目录或加入 PATH，然后重启本地服务。';

var HEVC_NOTICE =
  '该视频采用 H.265/HEVC 编码，当前浏览器无法解码。' +
  '建议改用 Safari / Edge；Windows 用户可在「设置 → 应用 → 可选功能」安装' +
  '「HEVC 视频扩展」后重试。';

function showNotice(message, kind) {
  var box = document.getElementById('play-note');
  if (!box) {
    return;
  }
  box.setAttribute('data-kind', kind || '');
  box.textContent = message;
  box.style.display = 'block';
}

function applyPlaybackRate(video) {
  if (!video || !(playbackRate > 0)) {
    return;
  }
  try {
    if (video.playbackRate !== playbackRate) {
      video.playbackRate = playbackRate;
    }
  } catch (error) {
    // 个别浏览器在加载初期不允许改倍速，loadedmetadata 时会再试一次。
  }
}

function rememberPlaybackRate(value) {
  if (!(value > 0)) {
    return;
  }
  playbackRate = value;
  writePlaybackRate(value);
}

// 播放器事件只绑一次：就地换集复用同一个 <video>，避免监听器叠加。
function bindPlayerEvents(video) {
  video.addEventListener('ratechange', function () {
    rememberPlaybackRate(video.playbackRate);
  });
  video.addEventListener('playing', function () {
    // 首帧已经出画面，撤掉模糊封面遮罩。
    hideVideoBackdrop();
    // 线路已被证明能正常出画面：撤销"原线路重试"的消耗，
    // 之后偶发一次网络抖动还能再享受一次宽容，而不是直接换线。
    if (video.videoWidth > 0 && sameLineRetried) {
      if (sameLineRetryTimer) {
        clearTimeout(sameLineRetryTimer);
        sameLineRetryTimer = null;
      }
      sameLineRetried = false;
    }
    var box = document.getElementById('play-note');
    if (box && (box.getAttribute('data-kind') === 'transcode' ||
      box.getAttribute('data-kind') === 'switching')) {
      box.style.display = 'none';
    }
  });
  video.addEventListener('loadedmetadata', function () {
    fitVideo(video);
    applyPlaybackRate(video);
  });
  video.addEventListener('timeupdate', function () {
    reportProgress(false);
  });
  video.addEventListener('pause', function () {
    reportProgress(true);
  });
  video.addEventListener('ended', function () {
    reportProgress(true);
    scheduleAutoNext();
  });
}

// 整页重建前记下倍速与全屏状态，重建后好还原。
function capturePlaybackState() {
  var video = document.getElementById('player');
  if (video) {
    rememberPlaybackRate(video.playbackRate);
  }
  resumeFullscreen =
    !!video &&
    (document.fullscreenElement === video || document.webkitFullscreenElement === video);
}

// 只有用户手势里才可能重新进全屏（点“下一集”链接属于这种情况）；
// 自动连播走的是就地换集，元素压根没换，不需要这里恢复。
function restoreFullscreen() {
  if (!resumeFullscreen) {
    return;
  }
  resumeFullscreen = false;
  var video = document.getElementById('player');
  if (!video) {
    return;
  }
  var request =
    video.requestFullscreen || video.webkitRequestFullscreen || video.webkitEnterFullscreen;
  if (!request) {
    return;
  }
  try {
    var result = request.call(video);
    if (result && typeof result.catch === 'function') {
      result.catch(function () {});
    }
  } catch (error) {
    // 没有用户手势时浏览器会拒绝，保持非全屏即可。
  }
}

// 黑屏看门狗：部分线路的 TS 把 H.265 藏在私有流（PMT stream_type=0x06）里，
// 浏览器 MSE 认不出可解码的视频轨，表现为"进度条在走、画面全黑"。
// 检测到时间推进但 videoWidth 始终为 0 时，同样走自动换线。
function startBlackScreenWatchdog(video, token) {
  var lastTime = -1;
  var advancing = 0;
  var timer = setInterval(function () {
    if (token !== mountToken) {
      clearInterval(timer);
      return;
    }
    if (video.videoWidth > 0) {
      clearInterval(timer); // 画面已出来，看门狗使命完成
      return;
    }
    if (video.paused || video.seeking) {
      // 暂停、拖动期间时间轴本来就不动，不作判定依据
      advancing = 0;
      lastTime = video.currentTime;
      return;
    }
    if (video.currentTime > lastTime + 1) {
      advancing += 1;
    } else {
      advancing = 0;
    }
    lastTime = video.currentTime;
    if (advancing >= 6) {
      clearInterval(timer);
      showNotice('该线路画面无法解码（可能是浏览器不支持的视频编码），正在自动切换线路…', 'switching');
      // 编码不兼容是确定性故障，原线路重试也不会变，直接换线
      failoverRoute('视频编码不支持', true);
    }
  }, 4000);
  if (blackWatchdog) {
    clearInterval(blackWatchdog);
  }
  blackWatchdog = timer;
}

// showVideoBackdrop 在首帧渲染前铺一层模糊封面 + 状态文案，避免纯黑等待。
// 首帧（loadeddata / playing）后自动移除。
function showVideoBackdrop(message) {
  var stage = document.querySelector('.player-stage');
  if (!stage) return;
  var backdrop = stage.querySelector('.video-backdrop');
  if (!backdrop) {
    backdrop = document.createElement('div');
    backdrop.className = 'video-backdrop';
    var drama = state.drama || {};
    var cover = drama.cover || drama.coverUrl || '';
    backdrop.innerHTML =
      (cover ? '<div class="video-backdrop-cover" style="background-image:url(\'' +
        escapeHTML(cover) + '\')"></div>' : '') +
      '<div class="video-backdrop-veil"></div>' +
      '<div class="video-backdrop-status">' +
        '<div class="spinner"></div>' +
        '<div class="video-backdrop-text"></div>' +
      '</div>';
    stage.appendChild(backdrop);
  }
  var text = backdrop.querySelector('.video-backdrop-text');
  if (text) text.textContent = message || '正在缓冲视频…';
  backdrop.style.display = 'flex';
}

function hideVideoBackdrop() {
  var backdrop = document.querySelector('.player-stage .video-backdrop');
  if (backdrop) backdrop.style.display = 'none';
}

function mountVideo(url, resumeAt) {
  var video = document.getElementById('player');
  if (!video) {
    return;
  }
  // 首帧前先铺模糊封面；单线路切画质、换集、换线路都走这里。
  showVideoBackdrop(
    state.routeName && detailRoutes(state.chapters || []).length >= 2
      ? '正在加载线路「' + state.routeName + '」…'
      : '正在缓冲视频…'
  );
  if (hlsInstance) {
    hlsInstance.destroy();
    hlsInstance = null;
  }
  if (!video.dataset.bound) {
    video.dataset.bound = '1';
    bindPlayerEvents(video);
  }
  var token = ++mountToken;
  // 每次新建播放（首次播放 / 换集 / 换画质 / 换到某条新线路）都视为"全新尝试"，
  // 给这条线路重新享有一次原线路重试的宽容预算。
  lastMountUrl = url;
  sameLineRetried = false;
  if (sameLineRetryTimer) {
    clearTimeout(sameLineRetryTimer);
    sameLineRetryTimer = null;
  }
  video.onerror = function () {
    cancelAutoNext();
    // 加载失败先走"原线路重试"，重试仍失败才换线（failoverRoute 内部两层）。
    failoverRoute('视频加载失败');
  };
  var isPlaylist = /\.m3u8($|\?)/i.test(url);
  var mediaRecoveries = 0;
  if (isPlaylist && window.Hls && window.Hls.isSupported()) {
    hlsInstance = new window.Hls({
      enableWorker: true,
      manifestLoadPolicy: {
        default: {
          maxTimeToFirstByteMs: 60000,
          maxLoadTimeMs: 120000,
          // 清单加载先自行重试几轮，抗住瞬时抖动；连续失败到顶才判死换线。
          timeoutRetry: { maxNumRetry: 3, retryDelayMs: 1000, maxRetryDelayMs: 4000, backoff: 'linear' },
          errorRetry: { maxNumRetry: 3, retryDelayMs: 1000, maxRetryDelayMs: 4000, backoff: 'linear' },
        },
      },
    });
    hlsInstance.on(window.Hls.Events.ERROR, function (event, data) {
      if (!data || !data.fatal) {
        return;
      }
      if (token !== mountToken) {
        return; // 旧实例的迟到回调，忽略
      }
      // 播放追上转码进度时会缓冲停滞，这属于正常现象，恢复播放等转码跟上即可。
      if (data.type === window.Hls.ErrorTypes.MEDIA_ERROR && mediaRecoveries < 4) {
        mediaRecoveries += 1;
        showNotice('缓冲中…服务端转码需要一点时间，会自动继续播放。', 'transcode');
        hlsInstance.recoverMediaError();
        return;
      }
      // 致命网络错误（含 manifestLoadError）或已耗尽媒体恢复次数：自动切换线路。
      var reason = data.details || data.type || '未知错误';
      if (data.type === window.Hls.ErrorTypes.MEDIA_ERROR) {
        reason = '画面解码失败';
      }
      failoverRoute(reason);
    });
    hlsInstance.loadSource(url);
    hlsInstance.attachMedia(video);
  } else {
    video.src = url;
  }
  applyPlaybackRate(video);
  video.play().catch(function (error) {
    // 浏览器可能因为自动播放策略拦截首次播放，提示用户手动点一下。
    if (error && error.name === 'NotAllowedError') {
      showNotice('浏览器阻止了自动播放，请点击播放按钮开始。');
    }
  });
  // 续播：有播放记录时跳回上次看到的位置。
  if (resumeAt > 0) {
    video.addEventListener(
      'loadedmetadata',
      function () {
        if (token !== mountToken) {
          return;
        }
        if (video.duration && resumeAt > video.duration - 5) {
          return;
        }
        try {
          video.currentTime = resumeAt;
          showNotice('已从上次进度 ' + formatTime(resumeAt) + ' 继续播放。', 'resume');
          // 播放真正开始由 playing 事件清掉它；万一用户一直不点播放，5 秒后也自动收起。
          setTimeout(function () {
            if (token !== mountToken) {
              return;
            }
            var box = document.getElementById('play-note');
            if (box && box.getAttribute('data-kind') === 'resume') {
              box.style.display = 'none';
            }
          }, 5000);
        } catch (error) {
          // 部分流不允许跳转，忽略即可。
        }
      },
      { once: true },
    );
  }
  // 浏览器拿不到视频帧但时间在走（HEVC/私有流），9 秒内自动换线。
  startBlackScreenWatchdog(video, token);
  // 套用当前画质档（原画/锐化）。
  applyPictureQuality(video);
}

function optionHTML(value, label, selected) {
  return (
    '<option value="' + escapeHTML(String(value)) + '"' + (selected ? ' selected' : '') + '>' +
    escapeHTML(label) +
    '</option>'
  );
}


function libraryCardHTML(entry, tab) {
  var key = entryKey(entry);
  var suffix = entry.source ? '&source=' + encodeURIComponent(entry.source) : '';
  var href = tab === 'history'
    ? '#/play?id=' + encodeURIComponent(entry.id) + '&index=' + Number(entry.index || 0) + suffix
    : '#/drama?id=' + encodeURIComponent(entry.id) + suffix;
  var second = tab === 'history'
    ? progressText(entry)
    : (entry.episodes ? entry.episodes + ' 集' : '点击查看剧集');
  var bar = tab === 'history'
    ? '<div class="progress"><span style="width:' + progressPercent(entry) + '%"></span></div>'
    : '';
  var checked = state.libraryEditing && state.librarySelected[key] ? ' checked' : '';
  var check = state.libraryEditing
    ? '<label class="lib-check"><input type="checkbox" data-check="' +
      escapeHTML(key) + '"' + checked + ' /></label>'
    : '';
  return (
    '<div class="card lib-card">' +
    check +
    '<button type="button" class="lib-remove" data-remove="' + escapeHTML(key) + '" title="删除">×</button>' +
    '<a class="lib-link" href="' + escapeHTML(href) + '">' +
    coverHTML(entry) +
    '<div class="title">' + escapeHTML(entry.title || '未命名') + '</div>' +
    '<div class="meta">' + escapeHTML(entry.sourceName || sourceLabel(entry.source) || '未知站源') + '</div>' +
    '<div class="meta">' + escapeHTML(second) + '</div>' +
    bar +
    '</a></div>'
  );
}

// 当前标签页里「按搜索框过滤之后」的条目：列表页的显示、全选、计数都按它算。
function libraryItems() {
  var tab = state.libraryTab === 'favorites' ? 'favorites' : 'history';
  var all = tab === 'history' ? state.library.history : state.library.favorites;
  var query = state.libraryQuery || '';
  if (!query) {
    return all;
  }
  return all.filter(function (entry) {
    return matchesTitleQuery(entry.title, query);
  });
}

function renderFavoritesView() {
  var tab = state.libraryTab === 'favorites' ? 'favorites' : 'history';
  var all = tab === 'history' ? state.library.history : state.library.favorites;
  var items = libraryItems();
  var query = state.libraryQuery || '';
  var selectedKeys = Object.keys(state.librarySelected).filter(function (key) {
    return state.librarySelected[key];
  });
  var toolbar = state.libraryEditing
    ? '<div class="lib-toolbar">' +
      '<label class="lib-all"><input type="checkbox" id="lib-all"' +
      (selectedKeys.length && selectedKeys.length === items.length ? ' checked' : '') +
      ' /> 全选</label>' +
      '<button type="button" class="btn" id="lib-delete">删除选中（' + selectedKeys.length + '）</button>' +
      '<button type="button" class="btn danger" id="lib-clear">清空全部</button>' +
      '<button type="button" class="btn" id="lib-done">完成</button>' +
      '</div>'
    : '';
  // 搜索框只在有内容时出现：空列表摆一个搜不到东西的输入框没有意义。
  // 提示里提一句拼音首字母，否则没人会想到能这么用。
  var filter = all.length
    ? '<div class="lib-filter">' +
      '<input type="search" id="lib-search" autocomplete="off"' +
      ' placeholder="搜索' + (tab === 'history' ? '播放记录' : '收藏') + '（支持拼音首字母，如 BDZC）"' +
      ' value="' + escapeHTML(query) + '" />' +
      (query
        ? '<span class="lib-count">匹配 ' + items.length + ' / ' + all.length + '</span>'
        : '<span class="lib-count">共 ' + all.length + ' 条</span>') +
      '</div>'
    : '';
  var cards = items.map(function (entry) {
    return libraryCardHTML(entry, tab);
  }).join('');
  if (!cards) {
    cards = '<div class="empty">' +
      (query
        ? '没有匹配「' + escapeHTML(query) + '」的条目，换个词或清空搜索框看看。'
        : tab === 'history'
          ? '还没有播放记录，看过的剧会自动出现在这里。'
          : '还没有收藏，可在播放页点「收藏」加入。') +
      '</div>';
  }
  var editButton = items.length
    ? '<button type="button" class="btn" id="lib-edit">' + (state.libraryEditing ? '退出编辑' : '编辑') + '</button>'
    : '';
  view.innerHTML =
    '<div class="lib">' +
    '<div class="lib-tabs">' +
    '<button type="button" class="lib-tab' + (tab === 'history' ? ' active' : '') +
    '" data-tab="history">播放记录（' + state.library.history.length + '）</button>' +
    '<button type="button" class="lib-tab' + (tab === 'favorites' ? ' active' : '') +
    '" data-tab="favorites">收藏（' + state.library.favorites.length + '）</button>' +
    '<span class="spacer"></span>' + editButton +
    '</div>' +
    filter +
    toolbar +
    '<div class="grid" id="lib-grid">' + cards + '</div>' +
    '</div>';
  bindLibraryView();
}

function libraryMutate(list, op, keys) {
  return libraryRequest({ list: list, op: op, keys: keys || [] }).then(function () {
    state.librarySelected = {};
    renderFavoritesView();
  });
}

function bindLibraryView() {
  var tabs = document.querySelectorAll('.lib-tab');
  Array.prototype.forEach.call(tabs, function (button) {
    button.addEventListener('click', function () {
      state.libraryTab = button.getAttribute('data-tab');
      state.librarySelected = {};
      renderFavoritesView();
    });
  });
  var editButton = document.getElementById('lib-edit');
  if (editButton) {
    editButton.addEventListener('click', function () {
      state.libraryEditing = !state.libraryEditing;
      state.librarySelected = {};
      renderFavoritesView();
    });
  }
  var doneButton = document.getElementById('lib-done');
  if (doneButton) {
    doneButton.addEventListener('click', function () {
      state.libraryEditing = false;
      state.librarySelected = {};
      renderFavoritesView();
    });
  }
  var allBox = document.getElementById('lib-all');
  if (allBox) {
    allBox.addEventListener('change', function () {
      // 全选只覆盖「当前过滤后能看到」的条目，别把搜不到的一起选上。
      var list = libraryItems();
      state.librarySelected = {};
      if (allBox.checked) {
        list.forEach(function (entry) {
          state.librarySelected[entryKey(entry)] = true;
        });
      }
      renderFavoritesView();
    });
  }
  var search = document.getElementById('lib-search');
  if (search) {
    search.addEventListener('input', function () {
      var caret = search.selectionStart;
      state.libraryQuery = search.value;
      renderFavoritesView();
      // 整块重绘会丢掉焦点与光标位置，这里补回去，连续打字才不会断。
      var again = document.getElementById('lib-search');
      if (again) {
        again.focus({ preventScroll: true });
        try {
          again.setSelectionRange(caret, caret);
        } catch (error) {
          // 个别浏览器不允许给 search 输入框设选区，忽略即可。
        }
      }
    });
  }
  Array.prototype.forEach.call(document.querySelectorAll('[data-check]'), function (box) {
    box.addEventListener('change', function () {
      state.librarySelected[box.getAttribute('data-check')] = box.checked;
      renderFavoritesView();
    });
  });
  Array.prototype.forEach.call(document.querySelectorAll('[data-remove]'), function (button) {
    button.addEventListener('click', function (event) {
      event.preventDefault();
      libraryMutate(state.libraryTab, 'remove', [button.getAttribute('data-remove')]);
    });
  });
  var deleteButton = document.getElementById('lib-delete');
  if (deleteButton) {
    deleteButton.addEventListener('click', function () {
      var keys = Object.keys(state.librarySelected).filter(function (key) {
        return state.librarySelected[key];
      });
      if (!keys.length) {
        return;
      }
      libraryMutate(state.libraryTab, 'remove', keys);
    });
  }
  var clearButton = document.getElementById('lib-clear');
  if (clearButton) {
    clearButton.addEventListener('click', function () {
      var label = state.libraryTab === 'history' ? '播放记录' : '收藏';
      if (!window.confirm('确定清空全部' + label + '？此操作不可撤销。')) {
        return;
      }
      libraryMutate(state.libraryTab, 'clear', []);
    });
  }
}

function renderFavorites(tab) {
  if (tab) {
    state.libraryTab = tab;
  }
  view.innerHTML = '<div class="loading">正在加载收藏夹…</div>';
  return loadLibrary().then(function () {
    renderFavoritesView();
  });
}

// —— 自定义 maccms 源管理 ——

function customSourceList() {
  return fetch('/api/custom-sources')
    .then(function (response) {
      return response.json();
    })
    .then(function (data) {
      return (data && data.items) || [];
    });
}

function customSourceSave(record, editing) {
  return fetch('/api/custom-sources' + (editing ? '/' + encodeURIComponent(record.id) : ''), {
    method: editing ? 'PUT' : 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      name: record.name,
      base: record.base,
      rule: record.rule || '',
      kind: record.kind || ''
    }),
  }).then(function (response) {
    return response.json().then(function (data) {
      if (!data || !data.id) {
        throw new Error(data && data.error ? data.error : '保存自定义源失败');
      }
      return data;
    });
  });
}

function customSourceImportText(content) {
  return fetch('/api/custom-sources/import', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ content: content }),
  }).then(function (response) {
    return response.json().then(function (data) {
      if (!data || data.ok !== true) {
        throw new Error(data && data.error ? data.error : '导入自定义源失败');
      }
      return data.result || {};
    });
  });
}

function customSourceImportUrl(url) {
  return fetch('/api/custom-sources/import', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ url: url }),
  }).then(function (response) {
    return response.json().then(function (data) {
      if (!data || data.ok !== true) {
        throw new Error(data && data.error ? data.error : '导入远程配置失败');
      }
      return data.result || {};
    });
  });
}

// 自动识别：把站点网址交给 Go 核心抓 HTML 反推规则；只回填表单，不保存。
function customSourceAnalyze(base) {
  return fetch('/api/custom-sources/analyze', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ base: base }),
  }).then(function (response) {
    return response.json().then(function (data) {
      if (!data || data.ok !== true) {
        throw new Error(data && data.error ? data.error : '自动识别失败');
      }
      return data.data || {};
    });
  });
}

function customSourceResetAll() {
  return fetch('/api/custom-sources/reset', { method: 'POST' })
    .then(function (response) {
      return response.json();
    })
    .then(function (data) {
      if (!data || data.ok !== true) {
        throw new Error(data && data.error ? data.error : '恢复默认源失败');
      }
      return data.removed || 0;
    });
}

function afterCustomSourcesChanged(result) {
  return Promise.all([customSourceList(), loadSources()]).then(function (listResults) {
    state.sourceNames = {};
    (listResults[0] || []).forEach(function (item) {
      state.sourceNames[item.id] = item.name;
    });
    renderCustomSources();
    if (result) {
      var added = (result.added || []).length;
      var updated = (result.updated || []).length;
      var notes = [].concat(result.skipped || [], result.failed || []);
      var message = '导入完成：新增 ' + added + ' 个，更新 ' + updated + ' 个。';
      if (notes.length) {
        message += '\n' + notes.join('\n');
      }
      window.alert(message);
    }
    return listResults;
  });
}

function customSourceRemove(id) {
  return fetch('/api/custom-sources/' + encodeURIComponent(id), { method: 'DELETE' })
    .then(function (response) {
      return response.json();
    })
    .then(function (data) {
      if (!data || data.ok !== true) {
        throw new Error(data && data.error ? data.error : '删除自定义源失败');
      }
      return data;
    });
}

// —— 源显示列表管理 ——

function visibilityList() {
  return fetch('/api/source-visibility')
    .then(function (response) {
      return response.json();
    })
    .then(function (data) {
      return (data && data.items) || [];
    });
}

function visibilitySet(id, visible) {
  return fetch('/api/source-visibility', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ id: id, visible: !!visible }),
  }).then(function (response) {
    return response.json().then(function (data) {
      if (!data || data.ok !== true) {
        throw new Error(data && data.error ? data.error : '保存源显示设置失败');
      }
      return data;
    });
  });
}

function renderSourceVisibility() {
  view.innerHTML = '<div class="loading">正在加载站源列表…</div>';
  return visibilityList().then(function (items) {
    var visibleCount = items.filter(function (item) { return item.visible; }).length;
    var rows = items.map(function (item) {
      return (
        '<div class="vis-row" style="display:flex;align-items:center;justify-content:space-between;border:1px solid var(--border);border-radius:8px;padding:10px 14px;margin:6px 0">' +
        '<div style="min-width:0">' +
        '<div style="font-weight:600">' + escapeHTML(item.name || '') +
        (item.builtin ? '（内置）' : item.module ? '' : '（自定义）') + '</div>' +
        '<div style="font-size:12px;opacity:0.6">' + escapeHTML(item.id) + '</div>' +
        '</div>' +
        '<label style="display:flex;align-items:center;gap:8px;cursor:pointer;flex:none">' +
        '<span style="font-size:13px;opacity:0.8">' + (item.visible ? '首页显示' : '已隐藏') + '</span>' +
        '<input type="checkbox" class="vis-toggle" data-id="' + escapeHTML(item.id) + '"' +
        (item.visible ? ' checked' : '') + ' />' +
        '</label>' +
        '</div>'
      );
    }).join('');
    if (!rows) {
      rows = '<div class="empty">当前没有可用站源。</div>';
    }
    view.innerHTML =
      '<div class="lib">' +
      '<div class="lib-tabs">' +
      '<span class="lib-tab active">源显示列表（可见 ' + visibleCount + ' / 共 ' + items.length + '）</span>' +
      '</div>' +
      '<div style="font-size:12px;opacity:0.7;padding:4px 2px 8px">' +
      '关闭的站源不会出现在顶部站源下拉框与首页目录中；自定义源记录、已缓存内容与播放都不受影响，随时可以重新开启。</div>' +
      rows +
      '</div>';
    bindSourceVisibilityView();
  });
}

function bindSourceVisibilityView() {
  var toggles = view.querySelectorAll('.vis-toggle');
  Array.prototype.forEach.call(toggles, function (input) {
    input.addEventListener('change', function () {
      input.disabled = true;
      visibilitySet(input.getAttribute('data-id'), input.checked).then(function () {
        // 下拉框同步刷新：当前源被隐藏时 loadSources 会自动落到首个可见源。
        return loadSources();
      }).then(function () {
        renderSourceVisibility();
      }).catch(function (error) {
        input.disabled = false;
        window.alert(error.message || '保存源显示设置失败');
      });
    });
  });
}

// —— 站源模块管理（设在自定义源页的「模块」标签里）——
//
// 模块是运行时加载的 JS 站源：装上之后它提供的站源会出现在站源下拉框与
// 源显示列表里，与内置源、自定义源一样可以开关。与本体同名的模块由 Go 核心
// 改名成 mod-<标识>，两者共存互不影响。

function moduleList() {
  return fetch('/api/modules')
    .then(function (response) {
      return response.json();
    })
    .then(function (data) {
      return (data && data.items) || [];
    });
}

function moduleStore() {
  return fetch('/api/modules/index')
    .then(function (response) {
      return response.json();
    })
    .then(function (data) {
      if (!data || data.ok !== true) {
        throw new Error(data && data.error ? data.error : '读取模块商店失败');
      }
      return { items: data.items || [], warning: data.warning || '' };
    });
}

function moduleRepositories() {
  return fetch('/api/modules/repositories')
    .then(function (response) {
      return response.json();
    })
    .then(function (data) {
      if (!data || data.ok !== true) {
        throw new Error(data && data.error ? data.error : '读取在线仓库失败');
      }
      return data.data || { items: [], active: 0, warning: '' };
    });
}

function moduleSaveRepositories(repositories, active) {
  return fetch('/api/modules/repositories', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ repositories: repositories, active: active }),
  })
    .then(function (response) {
      return response.json();
    })
    .then(function (data) {
      if (!data || data.ok !== true) {
        throw new Error(data && data.error ? data.error : '保存在线仓库失败');
      }
      return data.data;
    });
}

function moduleInstall(payload) {
  var options = { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) };
  return fetch('/api/modules/install', options)
    .then(function (response) {
      return response.json();
    })
    .then(function (data) {
      if (!data || data.ok !== true) {
        throw new Error(data && data.error ? data.error : '安装模块失败');
      }
      return data;
    });
}

// 准备：把 zip / 地址展开成待安装项，不安装，供用户勾选。
function modulePrepare(body, isJSON) {
  var options = { method: 'POST' };
  if (isJSON) {
    options.headers = { 'Content-Type': 'application/json' };
  }
  options.body = body;
  return fetch('/api/modules/prepare', options)
    .then(function (response) {
      return response.json();
    })
    .then(function (data) {
      if (!data || data.ok !== true) {
        throw new Error(data && data.error ? data.error : '解析安装包失败');
      }
      return (data.items || []);
    });
}

// 按勾选的项安装：items 为 [{token, name}]。
function moduleInstallPrepared(items) {
  return fetch('/api/modules/install-prepared', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ items: items }),
  }).then(function (response) {
    return response.json().then(function (data) {
      if (!data || data.ok !== true) {
        throw new Error(data && data.error ? data.error : '安装模块失败');
      }
      return data;
    });
  });
}

// 批量准备完成后弹出勾选层：默认全选，用户可只装合集里的部分模块。
// 返回 Promise，resolve 选中的 items，取消则 resolve null。
// 在线仓库管理弹层：新增 / 编辑 / 删除仓库名+index.json 地址，单选切换启用项。
// 返回 {repositories:[{name,url}], active:int}；返回 null 表示取消。
function openRepositoryManager(config) {
  return new Promise(function (resolve) {
    var repos = [];
    ((config && config.items) || []).forEach(function (repo) {
      repos.push({ name: repo.name || '', url: repo.url || '' });
    });
    if (!repos.length) repos.push({ name: '默认仓库', url: '' });
    var active = config && typeof config.active === 'number' ? config.active : 0;
    if (active < 0 || active >= repos.length) active = 0;

    var overlay = document.createElement('div');
    overlay.style.cssText =
      'position:fixed;inset:0;background:rgba(0,0,0,0.55);z-index:1000;display:flex;align-items:center;justify-content:center';
    function rows() {
      return repos.map(function (repo, index) {
        return '<div style="display:flex;align-items:center;gap:8px;padding:8px 2px;border-bottom:1px solid var(--border,#333)">' +
          '<input type="radio" name="repo-active" data-index="' + index + '"' + (index === active ? ' checked' : '') + ' />' +
          '<div style="min-width:0;flex:1">' +
          '<div style="font-weight:600">' + (repo.name ? escapeHTML(repo.name) : '未命名仓库') + '</div>' +
          '<div style="font-size:12px;opacity:0.7;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">' +
          (repo.url ? escapeHTML(repo.url) : '未填写地址') + '</div></div>' +
          '<button type="button" class="btn" data-repo-edit="' + index + '" style="font-size:12px;padding:4px 10px">编辑</button>' +
          '<button type="button" class="btn danger" data-repo-remove="' + index + '" style="font-size:12px;padding:4px 10px">删除</button>' +
          '</div>';
      }).join('');
    }
    function render() {
      overlay.innerHTML =
        '<div style="background:var(--panel,#1e2430);border:1px solid var(--border,#333);border-radius:12px;' +
        'width:min(620px,94vw);padding:20px;box-sizing:border-box;max-height:88vh;display:flex;flex-direction:column">' +
        '<h3 style="margin:0 0 6px">管理在线仓库</h3>' +
        '<div style="font-size:12px;opacity:0.75;margin-bottom:10px">点击圆点切换启用的仓库，应用商店将从该地址的 index.json 读取模块列表。</div>' +
        '<div style="overflow:auto;border:1px solid var(--border,#333);border-radius:8px;padding:2px 10px;min-height:48px" id="repo-list">' +
        rows() + '</div>' +
        '<div style="display:flex;gap:8px;margin-top:10px">' +
        '<button type="button" class="btn" id="repo-add">添加仓库</button></div>' +
        '<div style="display:flex;justify-content:flex-end;gap:8px;margin-top:14px">' +
        '<button type="button" class="btn" id="repo-cancel">取消</button>' +
        '<button type="button" class="btn" id="repo-save">保存</button>' +
        '</div></div>';
      bind();
    }
    function valid() {
      var seen = {};
      for (var i = 0; i < repos.length; i++) {
        if (!repos[i].name || !repos[i].name.trim()) return false;
        var text = (repos[i].url || '').trim();
        var uri;
        try { uri = new URL(text); } catch (e) { return false; }
        if (uri.protocol !== 'http:' && uri.protocol !== 'https:') return false;
        if (!uri.hostname) return false;
        var key = text.toLowerCase();
        if (seen[key]) return false;
        seen[key] = true;
      }
      return true;
    }
    function editRepo(index) {
      var existing = repos[index];
      var name = window.prompt('仓库名：', existing.name || '');
      if (name === null) return;
      var url = window.prompt(
        'index.json 地址（以 http:// 或 https:// 开头）：',
        existing.url || 'https://'
      );
      if (url === null) return;
      repos[index] = { name: name.trim(), url: url.trim() };
      render();
    }
    function addRepo() {
      var name = window.prompt('仓库名：', '我的应用商店');
      if (name === null) return;
      var url = window.prompt(
        'index.json 地址（以 http:// 或 https:// 开头）：',
        'https://'
      );
      if (url === null) return;
      repos.push({ name: name.trim(), url: url.trim() });
      active = repos.length - 1;
      render();
    }
    function bind() {
      Array.prototype.forEach.call(overlay.querySelectorAll('input[name=repo-active]'), function (radio) {
        radio.addEventListener('change', function () {
          active = parseInt(radio.dataset.index, 10);
        });
      });
      Array.prototype.forEach.call(overlay.querySelectorAll('[data-repo-edit]'), function (button) {
        button.addEventListener('click', function () {
          editRepo(parseInt(button.getAttribute('data-repo-edit'), 10));
        });
      });
      Array.prototype.forEach.call(overlay.querySelectorAll('[data-repo-remove]'), function (button) {
        button.addEventListener('click', function () {
          var index = parseInt(button.getAttribute('data-repo-remove'), 10);
          if (repos.length <= 1) {
            window.alert('至少保留一个在线仓库');
            return;
          }
          repos.splice(index, 1);
          if (active >= repos.length) active = repos.length - 1;
          if (active < 0) active = 0;
          render();
        });
      });
      var add = document.getElementById('repo-add');
      if (add) add.addEventListener('click', addRepo);
      var cancel = document.getElementById('repo-cancel');
      if (cancel) cancel.addEventListener('click', function () { close(null); });
      var save = document.getElementById('repo-save');
      if (save) save.addEventListener('click', function () {
        if (!valid()) {
          window.alert('请填写有效的仓库名与 http(s) 地址，且地址不重复');
          return;
        }
        close({
          repositories: repos.map(function (r) { return { name: r.name.trim(), url: r.url.trim() }; }),
          active: active,
        });
      });
    }
    function close(result) {
      document.body.removeChild(overlay);
      resolve(result);
    }
    render();
  });
}

function openModuleSelectDialog(items, failures) {
  return new Promise(function (resolve) {
    var selected = {};
    (items || []).forEach(function (item) {
      if (item.token) selected[item.token] = true;
    });
    var overlay = document.createElement('div');
    overlay.style.cssText =
      'position:fixed;inset:0;background:rgba(0,0,0,0.55);z-index:1000;display:flex;align-items:center;justify-content:center';
    function itemLabel(item) {
      var label = escapeHTML(item.displayName || item.name || item.id || '模块') +
        (item.version ? ' · ' + escapeHTML(item.version) : '');
      if (item.adult) label += '（限制级）';
      if (item.installed) {
        label += item.previous ? '（覆盖 ' + escapeHTML(item.previous) + '）' : '（已安装）';
      }
      return label;
    }
    var rows = (items || []).map(function (item) {
      return '<label style="display:flex;align-items:center;gap:8px;padding:7px 2px;border-bottom:1px solid var(--border,#333)">' +
        '<input type="checkbox" data-token="' + escapeHTML(item.token || '') + '" checked' +
        (item.token ? '' : ' disabled') + ' />' +
        '<span style="min-width:0;flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">' +
        itemLabel(item) + '</span></label>';
    }).join('');
    var failureRows = (failures || []).filter(function (item) {
      return item.error;
    }).map(function (item) {
      return '<div style="font-size:12px;color:#ff8b90;padding:4px 2px">' +
        escapeHTML(item.name || '模块') + '：' + escapeHTML(item.error) + '</div>';
    }).join('');
    var errorCount = (failures || []).filter(function (item) {
      return item.error;
    }).length;
    overlay.innerHTML =
      '<div style="background:var(--panel,#1e2430);border:1px solid var(--border,#333);border-radius:12px;' +
      'width:min(520px,92vw);padding:20px;box-sizing:border-box;max-height:88vh;display:flex;flex-direction:column">' +
      '<h3 style="margin:0 0 6px">选择要安装的站源（共 ' + (items || []).length + ' 个）</h3>' +
      '<div style="font-size:12px;opacity:0.75;margin-bottom:10px">合集里识别出多个模块，勾选后只安装选中的。</div>' +
      '<div style="display:flex;align-items:center;gap:8px;margin-bottom:6px">' +
      '<button type="button" class="btn" id="mod-sel-all" style="font-size:12px;padding:4px 10px">全选</button>' +
      '<button type="button" class="btn" id="mod-sel-none" style="font-size:12px;padding:4px 10px">全不选</button>' +
      '<span id="mod-sel-count" style="font-size:12px;opacity:0.7"></span>' +
      '</div>' +
      '<div style="overflow:auto;border:1px solid var(--border,#333);border-radius:8px;padding:2px 10px;min-height:40px">' +
      (rows || '<div class="empty">没有可安装的模块</div>') + failureRows + '</div>' +
      (errorCount ? '<div style="font-size:12px;color:#ff8b90;margin-top:6px">' + errorCount + ' 项无法识别，将跳过。</div>' : '') +
      '<div style="display:flex;justify-content:flex-end;gap:8px;margin-top:14px">' +
      '<button type="button" class="btn" id="mod-sel-cancel">取消</button>' +
      '<button type="button" class="btn" id="mod-sel-go" disabled>安装</button>' +
      '</div></div>';
    document.body.appendChild(overlay);
    var checkboxes = Array.prototype.slice.call(overlay.querySelectorAll('input[type=checkbox]'));
    var countLabel = document.getElementById('mod-sel-count');
    var goButton = document.getElementById('mod-sel-go');
    function refresh() {
      var chosen = checkboxes.filter(function (box) {
        return box.checked && !box.disabled;
      });
      if (countLabel) countLabel.textContent = '已选 ' + chosen.length + ' / ' + checkboxes.length;
      if (goButton) goButton.disabled = chosen.length === 0;
    }
    function close(result) {
      document.body.removeChild(overlay);
      resolve(result);
    }
    checkboxes.forEach(function (box) {
      box.addEventListener('change', function () {
        if (box.dataset.token) {
          if (box.checked) selected[box.dataset.token] = true;
          else delete selected[box.dataset.token];
        }
        refresh();
      });
    });
    var all = document.getElementById('mod-sel-all');
    var none = document.getElementById('mod-sel-none');
    if (all) all.addEventListener('click', function () {
      checkboxes.forEach(function (box) {
        if (!box.disabled) box.checked = true;
      });
      selected = {};
      (items || []).forEach(function (item) {
        if (item.token) selected[item.token] = true;
      });
      refresh();
    });
    if (none) none.addEventListener('click', function () {
      checkboxes.forEach(function (box) { box.checked = false; });
      selected = {};
      refresh();
    });
    var cancel = document.getElementById('mod-sel-cancel');
    if (cancel) cancel.addEventListener('click', function () { close(null); });
    if (goButton) goButton.addEventListener('click', function () {
      var chosen = (items || []).filter(function (item) {
        return item.token && selected[item.token];
      }).map(function (item) {
        return { token: item.token, name: item.displayName || item.name || item.id || '' };
      });
      close(chosen);
    });
    refresh();
  });
}

// 安装流程：先准备、弹勾选层，再安装选中的模块。
function moduleInstallWithSelection(preparePromise) {
  return preparePromise.then(function (items) {
    var ready = items.filter(function (item) { return item.token; });
    var failures = items.filter(function (item) { return !item.token; });
    if (!ready.length) {
      var reason = failures.length && failures[0].error ? failures[0].error : '没有可安装的模块';
      throw new Error(reason);
    }
    return openModuleSelectDialog(ready, failures);
  }).then(function (chosen) {
    if (!chosen) return null;
    return moduleInstallPrepared(chosen);
  });
}

function moduleUninstall(id) {
  return fetch('/api/modules/uninstall', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ id: id }),
  }).then(function (response) {
    return response.json().then(function (data) {
      if (!data || data.ok !== true) {
        throw new Error(data && data.error ? data.error : '卸载模块失败');
      }
      return data;
    });
  });
}

// 批量安装：一次提交多个地址；核心会展开合集包里的子模块。
function moduleInstallBatch(urls) {
  return fetch('/api/modules/batch', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ urls: urls }),
  }).then(function (response) {
    return response.json().then(function (data) {
      if (!data || data.ok !== true) {
        throw new Error(data && data.error ? data.error : '安装模块失败');
      }
      return data;
    });
  });
}

// 恢复默认：删掉全部用户安装的模块，内置模块重新装回来。
function moduleReset() {
  return fetch('/api/modules/reset', { method: 'POST' }).then(function (response) {
    return response.json().then(function (data) {
      if (!data || data.ok !== true) {
        throw new Error(data && data.error ? data.error : '恢复默认失败');
      }
      return data;
    });
  });
}

// 导出模块：ids 为空表示全部已安装模块，返回 zip 并触发浏览器下载。
function moduleExport(ids) {
  var options = { method: 'POST', headers: { 'Content-Type': 'application/json' } };
  if (ids && ids.length) {
    options.body = JSON.stringify({ ids: ids });
  } else {
    options.method = 'GET';
    delete options.headers;
  }
  return fetch('/api/modules/export', options).then(function (response) {
    var type = response.headers.get('Content-Type') || '';
    if (type.indexOf('application/zip') < 0) {
      return response.json().then(function (data) {
        throw new Error(data && data.error ? data.error : '导出模块失败');
      });
    }
    return response.blob().then(function (blob) {
      var url = URL.createObjectURL(blob);
      var link = document.createElement('a');
      var stamp = new Date().toISOString().slice(0, 10);
      link.href = url;
      link.download = ids && ids.length === 1
        ? 'guoapp-module-' + ids[0] + '-' + stamp + '.zip'
        : 'guoapp-modules-' + stamp + '.zip';
      document.body.appendChild(link);
      link.click();
      document.body.removeChild(link);
      setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
    });
  });
}

// 把多行文本拆成地址列表：支持换行、逗号、空格分隔。
function splitAddresses(text) {
  var seen = {};
  var out = [];
  String(text || '').split(/[\s,，;；]+/).forEach(function (part) {
    var value = part.trim();
    if (value && !seen[value]) {
      seen[value] = true;
      out.push(value);
    }
  });
  return out;
}

// 版本比较：模块版本固定是 x.y.z，装上的比商店里的旧就提示可更新。
function moduleNewerVersion(latest, installed) {
  var next = String(latest || '').split('.');
  var current = String(installed || '').split('.');
  if (next.length !== 3 || current.length !== 3) {
    return false;
  }
  for (var index = 0; index < 3; index++) {
    var a = parseInt(next[index], 10);
    var b = parseInt(current[index], 10);
    if (isNaN(a) || isNaN(b)) {
      return false;
    }
    if (a !== b) {
      return a > b;
    }
  }
  return false;
}

function renderModules() {
  return Promise.all([
    moduleList(),
    moduleStore().catch(function (error) {
      return { items: [], warning: error.message || '读取模块商店失败' };
    }),
    moduleRepositories().catch(function () {
      return { items: [], active: 0, warning: '' };
    }),
    visibilityList().catch(function () {
      return [];
    }),
  ]).then(function (results) {
    var installed = results[0];
    var store = results[1];
    var repos = results[2];
    var byId = {};
    installed.forEach(function (item) {
      byId[item.id] = item;
    });
    function moduleLabel(item) {
      return escapeHTML(item.name || item.id || '') +
        (item.version ? ' · ' + escapeHTML(item.version) : '') +
        (item.adult ? '（限制级）' : '');
    }
    // 已安装模块带上「首页显示」开关：源显示的职责已并到这里，
    // 模块源的可见性、导出、卸载都在本页完成。
    var visibleById = {};
    var visItems = results[3] || [];
    visItems.forEach(function (item) { visibleById[item.id] = item.visible !== false; });
    var installedRows = installed.map(function (item) {
      var shown = visibleById[item.id] !== false;
      return (
        '<div style="display:flex;align-items:center;justify-content:space-between;border:1px solid var(--border);border-radius:8px;padding:10px 14px;margin:6px 0">' +
        '<div style="min-width:0">' +
        '<div style="font-weight:600">' + moduleLabel(item) + '</div>' +
        '<div style="font-size:12px;opacity:0.7">' +
        escapeHTML(item.description || '') +
        '</div>' +
        '<div style="font-size:12px;opacity:0.55">站源：' + escapeHTML(item.sourceId || item.id || '') +
        (item.error ? ' · ' + escapeHTML(item.error) : '') + '</div>' +
        '</div>' +
        '<div style="display:flex;gap:6px;flex:none;align-items:center">' +
        '<label style="display:flex;align-items:center;gap:6px;cursor:pointer;margin-right:4px" title="关闭后不出现在首页站源下拉框，追剧与记录保留">' +
        '<span style="font-size:12px;opacity:0.8">' + (shown ? '显示' : '隐藏') + '</span>' +
        '<input type="checkbox" class="vis-toggle" data-id="' + escapeHTML(item.id) + '"' + (shown ? ' checked' : '') + ' />' +
        '</label>' +
        '<button type="button" class="btn" data-module-export="' + escapeHTML(item.id) + '">导出</button>' +
        '<button type="button" class="btn danger" data-module-remove="' + escapeHTML(item.id) + '" data-name="' +
        escapeHTML(item.name || item.id || '') + '">卸载</button>' +
        '</div>' +
        '</div>'
      );
    }).join('');
    if (!installedRows) {
      installedRows = '<div class="empty">还没有安装模块。站源以模块的形式提供，安装后才能在站源列表里使用。</div>';
    }
    var storeRows = store.items.map(function (entry) {
      var have = byId[entry.id];
      var update = have && moduleNewerVersion(entry.version, have.version);
      var action = '';
      if (!have) {
        action = '<button type="button" class="btn" data-module-install="' + escapeHTML(entry.id) + '">安装</button>';
      } else if (update) {
        action = '<button type="button" class="btn" data-module-install="' + escapeHTML(entry.id) + '">更新</button>';
      } else {
        action = '<span style="font-size:12px;opacity:0.6">已安装</span>';
      }
      return (
        '<div style="display:flex;align-items:center;justify-content:space-between;border:1px solid var(--border);border-radius:8px;padding:10px 14px;margin:6px 0">' +
        '<div style="min-width:0">' +
        '<div style="font-weight:600">' + moduleLabel(entry) + (entry.bundled ? '（内置）' : '') + '</div>' +
        '<div style="font-size:12px;opacity:0.7">' + escapeHTML(entry.description || entry.id || '') + '</div>' +
        '</div>' +
        '<div style="flex:none">' + action + '</div>' +
        '</div>'
      );
    }).join('');
    if (!storeRows) {
      storeRows = '<div class="empty">商店里还没有模块。</div>';
    }
    // 一键安装只处理「还没装」或「商店里版本更新」的模块，已是最新的不重复打接口。
    var pendingIds = store.items.filter(function (entry) {
      var have = byId[entry.id];
      return !have || moduleNewerVersion(entry.version, have.version);
    }).map(function (entry) {
      return entry.id;
    });
    var installAllButton = pendingIds.length
      ? '<button type="button" class="btn" id="module-install-all" title="在线仓库里还有 ' + pendingIds.length + ' 个未安装或可更新">安装全部站源（' + pendingIds.length + '）</button>'
      : '';
    // 在线仓库列表：内置 3 个（官方仓库 / guocheng1378 / jqk4388）+ 用户自加。
    // 点单选框切换启用项，与 App 端「在线仓库」的交互一致。
    var repoList = (repos && repos.items) || [];
    var repoActive = repos && typeof repos.active === 'number' ? repos.active : 0;
    var repoRows = repoList
      .map(function (repo, index) {
        var active = index === repoActive;
        return (
          '<div style="display:flex;align-items:center;gap:10px;border:1px solid var(--border);border-radius:8px;padding:10px 14px;margin:6px 0">' +
          '<label style="display:flex;align-items:center;gap:8px;cursor:pointer;flex:none">' +
          '<input type="radio" name="module-repo" data-repo="' + index + '"' + (active ? ' checked' : '') + ' />' +
          '<span style="font-size:12px;opacity:0.8">' + (active ? '当前' : '切换') + '</span>' +
          '</label>' +
          '<div style="min-width:0;flex:1">' +
          '<div style="font-weight:600">' + escapeHTML(repo.name || '未命名仓库') + '</div>' +
          '<div style="font-size:12px;opacity:0.6;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">' +
          escapeHTML(repo.url || '') + '</div>' +
          '</div>' +
          '<div style="display:flex;gap:6px;flex:none">' +
          '<button type="button" class="btn" data-repo-edit="' + index + '">编辑</button>' +
          (repoList.length > 1
            ? '<button type="button" class="btn danger" data-repo-remove="' + index + '">删除</button>'
            : '') +
          '</div>' +
          '</div>'
        );
      })
      .join('');
    if (!repoRows) {
      repoRows = '<div class="empty">还没有配置在线仓库。</div>';
    }

    // 页签：已安装 / 在线仓库 / 内置。源显示已并入「已安装」，
    // 与 App 端「自定义模块 › 已安装」的职责一致。
    var tab = moduleTab;
    var tabBar =
      '<div class="lib-tabs">' +
      '<span class="lib-tab' + (tab === 'installed' ? ' active' : '') + '" data-module-tab="installed">已安装（' + installed.length + '）</span>' +
      '<span class="lib-tab' + (tab === 'repos' ? ' active' : '') + '" data-module-tab="repos">在线仓库（' + repoList.length + '）</span>' +
      '<span class="lib-tab' + (tab === 'builtin' ? ' active' : '') + '" data-module-tab="builtin">内置</span>' +
      '<span class="spacer"></span>' +
      (tab === 'repos'
        ? '<button type="button" class="btn" id="repo-add">新增仓库</button>'
        : '<input type="file" id="module-install-file" accept=".zip,application/zip" multiple style="display:none" />' +
          '<button type="button" class="btn" id="module-install-file-btn" title="可多选；合集包内多个站源可勾选安装">从文件安装</button>' +
          '<button type="button" class="btn" id="module-install-url-btn" title="可一次填多个地址，每行一个">从地址安装</button>' +
          (installed.length
            ? '<button type="button" class="btn" id="module-export-all">导出全部</button>'
            : '') +
          '<button type="button" class="btn danger" id="module-reset">恢复默认</button>') +
      '</div>';

    var body = '';
    if (tab === 'repos') {
      body =
        '<div style="font-size:12px;opacity:0.7;padding:4px 2px 8px">' +
        '点单选框切换启用的仓库，模块商店从该地址的 index.json 读取模块列表。内置官方仓库与两个社区合集，也可以自己新增。' +
        '</div>' +
        (repos && repos.warning ? '<div class="empty">' + escapeHTML(repos.warning) + '</div>' : '') +
        repoRows;
    } else if (tab === 'builtin') {
      body =
        '<div style="font-size:12px;opacity:0.7;padding:4px 2px 8px">' +
        '这些模块随安装包内置，版本更高时自动升级；卸载过的不会自动装回。' +
        '</div>' +
        (store.items.filter(function (entry) { return entry.bundled; }).length
          ? store.items.filter(function (entry) { return entry.bundled; }).map(function (entry) {
              var have = byId[entry.id];
              var update = have && moduleNewerVersion(entry.version, have.version);
              var action = !have
                ? '<button type="button" class="btn" data-module-install="' + escapeHTML(entry.id) + '">安装</button>'
                : update
                  ? '<button type="button" class="btn" data-module-install="' + escapeHTML(entry.id) + '">更新</button>'
                  : '<span style="font-size:12px;opacity:0.6">已安装</span>';
              return (
                '<div style="display:flex;align-items:center;justify-content:space-between;border:1px solid var(--border);border-radius:8px;padding:10px 14px;margin:6px 0">' +
                '<div style="min-width:0">' +
                '<div style="font-weight:600">' + moduleLabel(entry) + '（内置）</div>' +
                '<div style="font-size:12px;opacity:0.7">' + escapeHTML(entry.description || entry.id || '') + '</div>' +
                '</div>' +
                '<div style="flex:none">' + action + '</div>' +
                '</div>'
              );
            }).join('')
          : '<div class="empty">这个安装包没有内置模块。</div>');
    } else {
      body =
        '<div style="font-size:12px;opacity:0.7;padding:4px 2px 8px">' +
        '模块是可安装的站源。右侧开关控制它在首页是否显示；导出、卸载也在这里。卸载后追剧、观看记录与已下载视频保留。' +
        '</div>' +
        (store.warning ? '<div class="empty">' + escapeHTML(store.warning) + '</div>' : '') +
        '<div style="font-weight:600;padding:8px 2px 2px">已安装</div>' +
        installedRows +
        '<div style="font-weight:600;padding:12px 2px 2px;display:flex;align-items:center;justify-content:space-between;gap:8px">' +
        '<span>模块商店' + (function () {
          var current = repoList[repoActive];
          return current && current.name ? '（' + escapeHTML(current.name) + '）' : '';
        })() + '</span>' +
        installAllButton +
        '</div>' +
        storeRows;
    }

    view.innerHTML = '<div class="lib">' + tabBar + body + '</div>';
    bindModuleView(pendingIds, installed, repos);
  });
}

// 一键安装商店里所有还没装（或有新版）的模块。
//
// 串行安装而不是并发：核心的安装接口一次只处理一个包，并发打过去既排不上队，
// 出错也分不清是哪个模块。每个模块单独 catch，一个失败不影响后面的继续装，
// 结束后把失败原因一次性列出来。
function moduleInstallAll(ids, button) {
  if (!ids.length) {
    return;
  }
  // 与 Flutter 端一致的确认文案：批量装的是站源，说清楚会逐个安装并启用。
  if (!window.confirm('安装 ' + ids.length + ' 个站源？这些站源会逐个安装并启用。')) {
    return;
  }
  var original = button.textContent;
  var failed = [];
  button.disabled = true;
  Array.prototype.forEach.call(view.querySelectorAll('[data-module-install]'), function (item) {
    item.disabled = true;
  });
  function step(index) {
    if (index >= ids.length) {
      return Promise.resolve();
    }
    button.textContent = '安装中 ' + (index + 1) + '/' + ids.length + '…';
    return moduleInstall({ id: ids[index] })
      .catch(function (error) {
        failed.push(ids[index] + '：' + (error.message || '安装失败'));
      })
      .then(function () {
        return step(index + 1);
      });
  }
  return step(0)
    .then(function () {
      return loadSources();
    })
    .then(function () {
      // renderModules 会用最新的已装列表重建整个视图，按钮也跟着重来，
      // 这里不用再把文字和禁用状态还原。
      return renderModules();
    })
    .catch(function (error) {
      button.textContent = original;
      button.disabled = false;
      window.alert(error.message || '安装模块失败');
    })
    .then(function () {
      if (failed.length) {
        window.alert('以下模块没能装上：\n' + failed.join('\n'));
      }
    });
}

function bindModuleView(installableIds, installed, repos) {
  // 页签切换：只改状态再重渲染，不重新拉远程数据。
  Array.prototype.forEach.call(view.querySelectorAll('[data-module-tab]'), function (tab) {
    tab.addEventListener('click', function () {
      moduleTab = tab.getAttribute('data-module-tab') || 'installed';
      renderModules();
    });
  });

  // 已安装列表里的「显示/隐藏」开关：源显示已并入模块页。
  Array.prototype.forEach.call(view.querySelectorAll('.vis-toggle'), function (input) {
    input.addEventListener('change', function () {
      input.disabled = true;
      visibilitySet(input.getAttribute('data-id'), input.checked)
        .then(function () { return loadSources(); })
        .then(function () { return renderModules(); })
        .catch(function (error) {
          input.disabled = false;
          window.alert(error.message || '保存源显示设置失败');
        });
    });
  });

  // 在线仓库：切换启用项 / 编辑 / 删除 / 新增。
  var repoList = (repos && repos.items) || [];
  var repoActive = repos && typeof repos.active === 'number' ? repos.active : 0;
  Array.prototype.forEach.call(view.querySelectorAll('input[data-repo]'), function (input) {
    input.addEventListener('change', function () {
      var index = Number(input.getAttribute('data-repo'));
      if (!Number.isInteger(index) || index === repoActive) return;
      input.disabled = true;
      moduleSaveRepositories(repoList, index)
        .then(function () { return renderModules(); })
        .catch(function (error) {
          input.disabled = false;
          window.alert(error.message || '切换在线仓库失败');
        });
    });
  });
  Array.prototype.forEach.call(view.querySelectorAll('[data-repo-edit]'), function (button) {
    button.addEventListener('click', function () {
      var index = Number(button.getAttribute('data-repo-edit'));
      var current = repoList[index];
      if (!current) return;
      var name = window.prompt('仓库名：', current.name || '');
      if (name === null) return;
      var url = window.prompt('index.json 地址：', current.url || '');
      if (url === null) return;
      var next = repoList.map(function (repo, i) {
        return i === index ? { name: name.trim(), url: url.trim() } : repo;
      });
      moduleSaveRepositories(next, repoActive)
        .then(function () { return renderModules(); })
        .catch(function (error) {
          window.alert(error.message || '保存在线仓库失败');
        });
    });
  });
  Array.prototype.forEach.call(view.querySelectorAll('[data-repo-remove]'), function (button) {
    button.addEventListener('click', function () {
      var index = Number(button.getAttribute('data-repo-remove'));
      var current = repoList[index];
      if (!current) return;
      if (!window.confirm('删除在线仓库「' + (current.name || '未命名') + '」？')) return;
      var next = repoList.filter(function (_, i) { return i !== index; });
      if (!next.length) {
        window.alert('至少保留一个在线仓库');
        return;
      }
      var active = repoActive;
      if (index < active) active -= 1;
      if (index === active && active >= next.length) active = next.length - 1;
      moduleSaveRepositories(next, active)
        .then(function () { return renderModules(); })
        .catch(function (error) {
          window.alert(error.message || '删除在线仓库失败');
        });
    });
  });
  var repoAdd = document.getElementById('repo-add');
  if (repoAdd) {
    repoAdd.addEventListener('click', function () {
      var name = window.prompt('仓库名：', '我的应用商店');
      if (name === null) return;
      var url = window.prompt('index.json 地址：', 'https://');
      if (url === null) return;
      var next = repoList.concat([{ name: name.trim(), url: url.trim() }]);
      moduleSaveRepositories(next, repoActive)
        .then(function () { return renderModules(); })
        .catch(function (error) {
          window.alert(error.message || '新增在线仓库失败');
        });
    });
  }
  var installAll = document.getElementById('module-install-all');
  if (installAll) {
    installAll.addEventListener('click', function () {
      moduleInstallAll(installableIds || [], installAll);
    });
  }
  var fileInput = document.getElementById('module-install-file');
  var fileButton = document.getElementById('module-install-file-btn');
  if (fileButton && fileInput) {
    fileButton.addEventListener('click', function () {
      fileInput.click();
    });
    // 多选：一次把选中的 zip 全部提交，合集包由后端展开。
    fileInput.addEventListener('change', function () {
      var files = Array.prototype.slice.call(fileInput.files || []);
      if (!files.length) {
        return;
      }
      fileButton.disabled = true;
      var failed = [];
      var installed = 0;
      var skipped = 0;
      // 每个文件先展开暂存并让用户勾选，只安装选中的模块。
      function next(index) {
        if (index >= files.length) {
          fileButton.disabled = false;
          fileInput.value = '';
          return loadSources().then(function () {
            renderModules();
            var summary = '已安装 ' + installed + ' 个模块';
            if (skipped) summary += '，跳过 ' + skipped + ' 个未勾选';
            if (failed.length) {
              summary += '\n以下安装包没能装上：\n' + failed.join('\n');
            }
            window.alert(summary);
          });
        }
        var file = files[index];
        moduleInstallWithSelection(modulePrepare(file, false))
          .then(function (data) {
            if (!data) {
              skipped++;
            } else {
              installed += data.installed || 0;
              var problems = data.failures || [];
              if (problems.length) failed.push(file.name + '：' + problems.join('；'));
            }
          })
          .catch(function (error) {
            failed.push(file.name + '：' + (error.message || '安装失败'));
          })
          .then(function () {
            next(index + 1);
          });
      }
      next(0);
    });
  }
  var urlButton = document.getElementById('module-install-url-btn');
  if (urlButton) {
    urlButton.addEventListener('click', function () {
      var text = window.prompt(
        '填写模块安装包（zip）的下载地址，可一次填多个（每行一个）：',
        'https://'
      );
      if (!text) {
        return;
      }
      var urls = splitAddresses(text);
      if (!urls.length) {
        return;
      }
      urlButton.disabled = true;
      moduleInstallWithSelection(
        modulePrepare(JSON.stringify({ urls: urls }), true)
      )
        .then(function (data) {
          return loadSources().then(function () {
            renderModules();
            if (data) {
              var failures = data.failures || [];
              var summary = '已安装 ' + (data.installed || 0) + ' 个模块';
              if (failures.length) {
                summary += '\n以下没能装上：\n' + failures.join('\n');
              }
              window.alert(summary);
            }
          });
        })
        .catch(function (error) {
          window.alert(error.message || '安装模块失败');
        })
        .then(function () {
          urlButton.disabled = false;
        });
    });
  }
  var exportAll = document.getElementById('module-export-all');
  if (exportAll) {
    exportAll.addEventListener('click', function () {
      exportAll.disabled = true;
      moduleExport([])
        .catch(function (error) {
          window.alert(error.message || '导出模块失败');
        })
        .then(function () {
          exportAll.disabled = false;
        });
    });
  }
  var reset = document.getElementById('module-reset');
  if (reset) {
    reset.addEventListener('click', function () {
      if (!window.confirm('恢复默认模块？会删除全部已安装的模块，只保留安装包内置的站源。各站源的追剧、观看记录和已下载视频会保留。')) {
        return;
      }
      reset.disabled = true;
      moduleReset()
        .then(function (data) {
          return loadSources().then(function () {
            renderModules();
            var removed = (data && data.removed) || [];
            window.alert('已删除 ' + removed.length + ' 个模块，恢复 ' + ((data && data.bundled) || 0) + ' 个内置站源。');
          });
        })
        .catch(function (error) {
          reset.disabled = false;
          window.alert(error.message || '恢复默认失败');
        });
    });
  }
  Array.prototype.forEach.call(view.querySelectorAll('[data-module-export]'), function (button) {
    button.addEventListener('click', function () {
      button.disabled = true;
      moduleExport([button.getAttribute('data-module-export')])
        .catch(function (error) {
          window.alert(error.message || '导出模块失败');
        })
        .then(function () {
          button.disabled = false;
        });
    });
  });
  Array.prototype.forEach.call(view.querySelectorAll('[data-module-install]'), function (button) {
    button.addEventListener('click', function () {
      button.disabled = true;
      moduleInstall({ id: button.getAttribute('data-module-install') })
        .then(function () {
          return loadSources();
        })
        .then(function () {
          renderModules();
        })
        .catch(function (error) {
          button.disabled = false;
          window.alert(error.message || '安装模块失败');
        });
    });
  });
  Array.prototype.forEach.call(view.querySelectorAll('[data-module-remove]'), function (button) {
    button.addEventListener('click', function () {
      var name = button.getAttribute('data-name') || button.getAttribute('data-module-remove');
      if (!window.confirm('卸载「' + name + '」？该站源的追剧、观看记录和已下载视频会保留，但重新安装前不再显示。')) {
        return;
      }
      button.disabled = true;
      moduleUninstall(button.getAttribute('data-module-remove'))
        .then(function () {
          return loadSources();
        })
        .then(function () {
          renderModules();
        })
        .catch(function (error) {
          button.disabled = false;
          window.alert(error.message || '卸载模块失败');
        });
    });
  });
}

function renderCustomSources() {
  return customSourceList().then(function (items) {
    var rows = items.map(function (item) {
      return (
        '<div class="lib-tab custom-row" style="display:flex;align-items:center;justify-content:space-between;border:1px solid var(--border);border-radius:8px;padding:10px 14px;margin:6px 0;cursor:default">' +
        '<div style="min-width:0">' +
        '<div style="font-weight:600">' + escapeHTML(item.name || '') + (item.rule ? '（规则）' : '') + '</div>' +
        '<div style="font-size:12px;opacity:0.7;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">' +
        escapeHTML(item.base || '') + '</div>' +
        '</div>' +
        '<div style="display:flex;gap:6px;flex:none">' +
        '<button type="button" class="btn" data-edit="' + escapeHTML(item.id) + '">编辑</button>' +
        '<button type="button" class="btn danger" data-remove="' + escapeHTML(item.id) + '" data-name="' +
        escapeHTML(item.name || '') + '">删除</button>' +
        '</div>' +
        '</div>'
      );
    }).join('');
    if (!rows) {
      rows = '<div class="empty">还没有自定义源。填入符合 MacCMS 规范的站点名称与网址，或粘贴 XBPQ 爬虫规则；也可以导入 JSON/TXT 文件批量添加。</div>';
    }
    view.innerHTML =
      '<div class="lib">' +
      '<div class="lib-tabs">' +
      '<span class="lib-tab active">自定义源（' + items.length + '）</span>' +
      '<span class="spacer"></span>' +
      '<input type="file" id="custom-import-file" accept=".json,.txt,application/json,text/plain" style="display:none" />' +
      '<button type="button" class="btn" id="custom-import">导入文件</button>' +
      '<button type="button" class="btn" id="custom-import-url">导入网络地址</button>' +
      '<button type="button" class="btn" id="custom-export">导出 JSON</button>' +
      '<button type="button" class="btn danger" id="custom-reset">恢复默认源</button>' +
      '<button type="button" class="btn" id="custom-add">新增</button>' +
      '</div>' +
      '<div style="font-size:12px;opacity:0.7;padding:4px 2px 8px">' +
      '自定义源读取网址并判断是否符合 MacCMS 规范；符合后套用通用规则自动完成列表、搜索与播放。粘贴 XBPQ 规则时按规则字段逐项截取。' +
      '</div>' +
      rows +
      '</div>';
    bindCustomSourcesView(items);
  });
}

function bindCustomSourcesView(items) {
  var addButton = document.getElementById('custom-add');
  if (addButton) {
    addButton.addEventListener('click', function () {
      openCustomSourceEditor(null);
    });
  }
  var exportButton = document.getElementById('custom-export');
  if (exportButton) {
    exportButton.addEventListener('click', function () {
      exportButton.disabled = true;
      fetch('/api/custom-sources/export')
        .then(function (response) {
          if (!response.ok) {
            throw new Error('导出失败');
          }
          return response.text();
        })
        .then(function (text) {
          if (!text || text.charAt(0) === '{' && JSON.parse(text).ok === false) {
            var parsed = {};
            try { parsed = JSON.parse(text); } catch (e) {}
            throw new Error(parsed.error || '导出失败');
          }
          var blob = new Blob([text], { type: 'application/json' });
          var link = document.createElement('a');
          link.href = URL.createObjectURL(blob);
          link.download = 'duanju-custom-sources.json';
          document.body.appendChild(link);
          link.click();
          document.body.removeChild(link);
          setTimeout(function () { URL.revokeObjectURL(link.href); }, 1000);
        })
        .catch(function (error) {
          window.alert(error.message || '导出自定义源失败');
        })
        .then(function () {
          exportButton.disabled = false;
        });
    });
  }
  var importButton = document.getElementById('custom-import');
  var importInput = document.getElementById('custom-import-file');
  if (importButton && importInput) {
    importButton.addEventListener('click', function () {
      importInput.value = '';
      importInput.click();
    });
    importInput.addEventListener('change', function () {
      var file = importInput.files && importInput.files[0];
      if (!file) {
        return;
      }
      if (file.size > 8 * 1024 * 1024) {
        window.alert('导入文件过大（上限 8MB）');
        return;
      }
      var reader = new FileReader();
      reader.onload = function () {
        importButton.disabled = true;
        customSourceImportText(String(reader.result || ''))
          .then(function (result) {
            return afterCustomSourcesChanged(result);
          })
          .catch(function (error) {
            window.alert(error.message || '导入自定义源失败');
          })
          .then(function () {
            importButton.disabled = false;
          });
      };
      reader.readAsText(file, 'utf-8');
    });
  }
  var importUrlButton = document.getElementById('custom-import-url');
  if (importUrlButton) {
    importUrlButton.addEventListener('click', function () {
      openCustomSourceImportUrlDialog();
    });
  }
  var resetButton = document.getElementById('custom-reset');
  if (resetButton) {
    resetButton.addEventListener('click', function () {
      var confirmed = window.confirm('将删除全部自定义源（含 XBPQ 规则），仅保留内置源。此操作不可撤销，建议先「导出 JSON」备份。\n\n确定恢复默认吗？');
      if (!confirmed) {
        return;
      }
      resetButton.disabled = true;
      customSourceResetAll()
        .then(function (removed) {
          return afterCustomSourcesChanged(null).then(function () {
            window.alert('已删除 ' + removed + ' 个自定义源，恢复为默认内置源。');
          });
        })
        .catch(function (error) {
          window.alert(error.message || '恢复默认源失败');
        })
        .then(function () {
          resetButton.disabled = false;
        });
    });
  }
  Array.prototype.forEach.call(view.querySelectorAll('[data-edit]'), function (button) {
    button.addEventListener('click', function () {
      var id = button.getAttribute('data-edit');
      var item = items.filter(function (entry) { return entry.id === id; })[0];
      if (item) {
        openCustomSourceEditor(item);
      }
    });
  });
  Array.prototype.forEach.call(view.querySelectorAll('[data-remove]'), function (button) {
    button.addEventListener('click', function () {
      var id = button.getAttribute('data-remove');
      var name = button.getAttribute('data-name') || '';
      var confirmed = window.confirm('确定删除「' + name + '」吗？已加载的剧集仍会保留在浏览器本地。');
      if (!confirmed) {
        return;
      }
      customSourceRemove(id)
        .then(function () {
          return Promise.all([customSourceList(), loadSources()]);
        })
        .then(function (results) {
          state.sourceNames = {};
          (results[0] || []).forEach(function (item) {
            state.sourceNames[item.id] = item.name;
          });
          renderCustomSources();
        })
        .catch(function (error) {
          window.alert(error.message || '删除自定义源失败');
        });
    });
  });
}

// 网络地址导入栏的预设配置地址：打开弹窗即预填第一项，也可点选切换，
// 输入框保留且可手动改成任意地址。预设本身是「加速链接+网址」拼接形态，
// 核心会作为整体识别抓取（见 isSplicedAcceleratorURL）。
var CS_IMPORT_PRESETS = [
  {
    name: '网页',
    url:
      'https://cfkua.wokaotianshi.eu.org/https://raw.githubusercontent.com/' +
      'wokaotianshi123/wokaotianshi123.github.io/refs/heads/main/hongguo/config.json',
  },
  {
    name: '采集',
    url:
      'https://cfkua.wokaotianshi.eu.org/https://raw.githubusercontent.com/' +
      'wokaotianshi123/jgcj/refs/heads/main/hongguo.json',
  },
];
var CS_IMPORT_DEFAULT_URL = CS_IMPORT_PRESETS[0].url;

function openCustomSourceImportUrlDialog() {
  var overlay = document.createElement('div');
  overlay.style.cssText =
    'position:fixed;inset:0;background:rgba(0,0,0,0.55);z-index:1000;display:flex;align-items:center;justify-content:center';
  overlay.innerHTML =
    '<div style="background:var(--panel,#1e2430);border:1px solid var(--border,#333);border-radius:12px;' +
    'width:min(480px,92vw);padding:20px;box-sizing:border-box;max-height:90vh;overflow:auto">' +
    '<h3 style="margin:0 0 14px">从网络地址导入</h3>' +
    '<div style="font-size:12px;opacity:0.75;margin-bottom:10px">粘贴 TVBox 配置 / JSON / TXT 远程地址，核心自动抓取并解析导入；「导入文件」仍可本地选择。</div>' +
    '<textarea id="cs-import-url" spellcheck="false" placeholder="https://…/config.json" ' +
    'style="width:100%;min-height:70px;font-family:monospace;font-size:12px;box-sizing:border-box;background:var(--bg,#12161f);color:inherit;border:1px solid var(--border,#333);border-radius:8px;padding:8px">' +
    escapeHTML(CS_IMPORT_DEFAULT_URL) +
    '</textarea>' +
    '<div id="cs-import-presets" style="margin-top:8px;display:flex;align-items:center;gap:8px;flex-wrap:wrap">' +
    '<span style="font-size:12px;opacity:0.75">预设地址（点击填入，仍可手动改）：</span>' +
    CS_IMPORT_PRESETS.map(function (preset, index) {
      return '<button type="button" class="btn" data-preset="' + index + '" style="font-size:12px;padding:4px 10px">' +
        escapeHTML(preset.name) + '</button>';
    }).join('') +
    '</div>' +
    '<div id="cs-import-error" style="color:#ff8b90;font-size:12px;min-height:18px;margin-top:8px"></div>' +
    '<div style="display:flex;justify-content:flex-end;gap:8px;margin-top:6px">' +
    '<button type="button" class="btn" id="cs-import-cancel">取消</button>' +
    '<button type="button" class="btn" id="cs-import-go">导入</button>' +
    '</div>' +
    '</div>';
  document.body.appendChild(overlay);
  var urlInput = document.getElementById('cs-import-url');
  var errorBox = document.getElementById('cs-import-error');
  var goButton = document.getElementById('cs-import-go');
  var cancelButton = document.getElementById('cs-import-cancel');
  function applyPreset(index) {
    var preset = CS_IMPORT_PRESETS[index];
    if (!preset || !urlInput) {
      return;
    }
    urlInput.value = preset.url;
    errorBox.textContent = '';
    urlInput.focus();
    urlInput.setSelectionRange(urlInput.value.length, urlInput.value.length);
  }
  var presetBox = document.getElementById('cs-import-presets');
  if (presetBox && urlInput) {
    presetBox.addEventListener('click', function (event) {
      var target = event.target;
      while (target && target !== presetBox && !target.hasAttribute('data-preset')) {
        target = target.parentNode;
      }
      if (target && target !== presetBox) {
        applyPreset(parseInt(target.getAttribute('data-preset'), 10));
      }
    });
  }
  if (urlInput) urlInput.focus();
  function close() {
    document.body.removeChild(overlay);
  }
  if (cancelButton) cancelButton.addEventListener('click', close);
  if (goButton) {
    goButton.addEventListener('click', function () {
      var url = (urlInput.value || '').trim();
      if (!url) {
        errorBox.textContent = '请填写配置地址';
        return;
      }
      if (!/^https?:\/\//i.test(url)) {
        errorBox.textContent = '地址需以 http:// 或 https:// 开头';
        return;
      }
      goButton.disabled = true;
      errorBox.textContent = '';
      customSourceImportUrl(url)
        .then(function (result) {
          close();
          return afterCustomSourcesChanged(result);
        })
        .catch(function (error) {
          errorBox.textContent = error.message || '导入远程配置失败';
          goButton.disabled = false;
        });
    });
  }
}

function openCustomSourceEditor(existing) {
  var overlay = document.createElement('div');
  overlay.style.cssText =
    'position:fixed;inset:0;background:rgba(0,0,0,0.55);z-index:1000;display:flex;align-items:center;justify-content:center';
  var title = existing ? '编辑自定义源' : '新增自定义源';
  var hasRule = !!(existing && existing.rule);
  overlay.innerHTML =
    '<div style="background:var(--panel,#1e2430);border:1px solid var(--border,#333);border-radius:12px;' +
    'width:min(480px,92vw);padding:20px;box-sizing:border-box;max-height:90vh;overflow:auto">' +
    '<h3 style="margin:0 0 14px">' + title + '</h3>' +
    '<label style="display:block;font-size:12px;opacity:0.8;margin-bottom:4px">源名称</label>' +
    '<input id="cs-name" class="search" type="text" maxlength="40" placeholder="例如：我的影院" ' +
    'style="width:100%;margin-bottom:12px" value="' + escapeHTML(existing ? existing.name : '') + '" />' +
    '<label style="display:block;font-size:12px;opacity:0.8;margin-bottom:4px">源网址（MacCMS 站点根地址）</label>' +
    '<input id="cs-base" class="search" type="url" placeholder="https://example.com" ' +
    'style="width:100%;margin-bottom:12px" value="' + escapeHTML(existing ? existing.base : '') + '" />' +
    '<div style="display:flex;justify-content:flex-end;margin:-6px 0 12px">' +
    '<button type="button" class="btn" id="cs-analyze">自动识别规则（抓取网页 HTML）</button></div>' +
    '<label style="display:block;font-size:12px;opacity:0.8;margin-bottom:4px">源类型（快速判定走网页模块还是 JSON API 模块）</label>' +
    '<select id="cs-kind" class="search" ' +
    'style="width:100%;margin-bottom:12px;background:var(--bg,#12161f);color:inherit;border:1px solid var(--border,#333);border-radius:8px;padding:8px">' +
    '<option value=""' + (!existing || !existing.type ? ' selected' : '') + '>自动（默认，先探测再兜底）</option>' +
    '<option value="web"' + (existing && existing.type === 'web' ? ' selected' : '') + '>网页源（MacCMS 站点，走 HTML 抓取）</option>' +
    '<option value="json"' + (existing && existing.type === 'json' ? ' selected' : '') + '>JSON 源（ac=videolist/list 接口，直连 API）</option>' +
    '</select>' +
    '<label style="display:flex;align-items:center;gap:8px;font-size:13px;margin-bottom:8px">' +
    '<input id="cs-rule-on" type="checkbox"' + (hasRule ? ' checked' : '') + ' /> 使用 XBPQ 爬虫规则（粘贴规则 JSON，按字段截取）</label>' +
    '<div id="cs-rule-wrap" style="display:' + (hasRule ? 'block' : 'none') + '">' +
    '<textarea id="cs-rule" spellcheck="false" placeholder=\'{"主页url":"https://…","分类url":"…{cateId}-{catePg}…","数组":"…&&…","标题":"…","链接":"…"}\' ' +
    'style="width:100%;min-height:130px;font-family:monospace;font-size:12px;box-sizing:border-box;background:var(--bg,#12161f);color:inherit;border:1px solid var(--border,#333);border-radius:8px;padding:8px">' +
    escapeHTML(existing && existing.rule ? existing.rule : '') + '</textarea></div>' +
    '<div id="cs-analyze-info" style="font-size:12px;opacity:0.85;white-space:pre-wrap;line-height:1.5;margin-top:8px"></div>' +
    '<div id="cs-error" style="color:#ff8b90;font-size:12px;min-height:18px;margin-top:8px"></div>' +
    '<div style="display:flex;justify-content:flex-end;gap:8px;margin-top:6px">' +
    '<button type="button" class="btn" id="cs-cancel">取消</button>' +
    '<button type="button" class="btn" id="cs-save">保存</button>' +
    '</div>' +
    '</div>';
  document.body.appendChild(overlay);
  var nameInput = document.getElementById('cs-name');
  var baseInput = document.getElementById('cs-base');
  var kindInput = document.getElementById('cs-kind');
  var ruleToggle = document.getElementById('cs-rule-on');
  var ruleWrap = document.getElementById('cs-rule-wrap');
  var ruleInput = document.getElementById('cs-rule');
  var errorBox = document.getElementById('cs-error');
  var saveButton = document.getElementById('cs-save');
  var cancelButton = document.getElementById('cs-cancel');
  var analyzeButton = document.getElementById('cs-analyze');
  var analyzeInfo = document.getElementById('cs-analyze-info');
  if (nameInput) nameInput.focus();
  if (ruleToggle) {
    ruleToggle.addEventListener('change', function () {
      if (ruleWrap) ruleWrap.style.display = ruleToggle.checked ? 'block' : 'none';
      if (!ruleToggle.checked && baseInput) baseInput.removeAttribute('readonly');
      else if (baseInput) baseInput.placeholder = '留空则自动取规则「主页url」';
    });
  }
  if (analyzeButton) {
    analyzeButton.addEventListener('click', function () {
      var base = (baseInput && baseInput.value ? baseInput.value : '').trim();
      if (!base) {
        errorBox.textContent = '请先填写源网址再自动识别';
        return;
      }
      var label = '自动识别规则（抓取网页 HTML）';
      function restore() {
        analyzeButton.disabled = false;
        analyzeButton.textContent = label;
      }
      analyzeButton.disabled = true;
      analyzeButton.textContent = '识别中…';
      errorBox.textContent = '';
      if (analyzeInfo) analyzeInfo.textContent = '正在抓取网页 HTML 并反推分类、列表、搜索与播放字段…';
      customSourceAnalyze(base)
        .then(function (result) {
          var rule = (result && result.rule ? String(result.rule) : '').trim();
          if (rule) {
            if (ruleToggle) ruleToggle.checked = true;
            if (ruleWrap) ruleWrap.style.display = 'block';
            if (ruleInput) ruleInput.value = rule;
            if (nameInput && !nameInput.value.trim() && result.name) nameInput.value = result.name;
          }
          var notes = (result && Array.isArray(result.notes) ? result.notes : []).slice(0, 8);
          var text = rule
            ? '已按网页 HTML 生成规则：可直接保存，也可在下方微调后保存。规则优先于源类型。'
            : '未能识别出可靠规则，已保留为普通网页源（引擎会自动适配 MacCMS），也可以手动粘贴规则。';
          if (notes.length) { text += '\n• ' + notes.join('\n• '); }
          if (analyzeInfo) analyzeInfo.textContent = text;
          restore();
        })
        .catch(function (error) {
          errorBox.textContent = error.message || '自动识别失败';
          if (analyzeInfo) analyzeInfo.textContent = '';
          restore();
        });
    });
  }
  function close() {
    document.body.removeChild(overlay);
  }
  if (cancelButton) {
    cancelButton.addEventListener('click', close);
  }
  if (saveButton) {
    saveButton.addEventListener('click', function () {
      var name = (nameInput.value || '').trim();
      var base = (baseInput.value || '').trim();
      var useRule = ruleToggle && ruleToggle.checked;
      var rule = useRule ? (ruleInput.value || '').trim() : '';
      if (useRule && !rule) {
        errorBox.textContent = '粘贴规则 JSON 后再保存，或取消勾选规则';
        return;
      }
      if (!useRule && !base) {
        errorBox.textContent = '请填写源网址（或勾选规则并粘贴规则 JSON）';
        return;
      }
      saveButton.disabled = true;
      customSourceSave({
        id: existing ? existing.id : '',
        name: name,
        base: base,
        rule: rule,
        kind: kindInput ? kindInput.value : ''
      }, !!existing)
        .then(function () {
          return Promise.all([customSourceList(), loadSources()]);
        })
        .then(function (results) {
          state.sourceNames = {};
          (results[0] || []).forEach(function (item) {
            state.sourceNames[item.id] = item.name;
          });
          close();
          renderCustomSources();
        })
        .catch(function (error) {
          errorBox.textContent = error.message || '保存自定义源失败';
          saveButton.disabled = false;
        });
    });
  }
}

/* ---------- 直播（Web 版，仅直播入口，无播放器选择） ---------- */

function liveGet(path, params) {
  var query = new URLSearchParams(params || {});
  return fetch('/api/livestream/' + path + '?' + query.toString())
    .then(function (response) { return response.json(); })
    .then(function (data) {
      if (!data.ok) { throw new Error(data.error || '直播请求失败'); }
      return data.data;
    });
}

function livePost(path, payload) {
  return fetch('/api/livestream/' + path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload || {}),
  })
    .then(function (response) { return response.json(); })
    .then(function (data) {
      if (!data.ok) { throw new Error(data.error || '直播请求失败'); }
      return data.data;
    });
}

var liveHlsInstance = null;
// flv.js 实例（秀果等直播源下发的是 .flv 流，浏览器原生与 hls.js 都无法解码，需 flv.js）。
var liveFlvInstance = null;
// ArtPlayer 实例（直播播放器的 UI 外壳；m3u8 走 hls.js、flv 走 flv.js，都挂到其 .video 元素）。
var liveArtplayer = null;
var liveState = {
  source: '',
  sources: [],
  platform: '',
  platforms: [],
  channels: [],
  playing: null,
  green: false,
  loading: false,
  channelLoading: false,
  platformLoading: false,
  showFavs: false,
  showCustom: false,
  page: 1,
  hasMore: false,
  moreLoading: false,
  urlIndex: 0,
  urlList: [],
};

// 取得直播播放用的 <video>：优先 ArtPlayer 的 video 元素，缺失时退回原生 <video>。
function liveVideoElement() {
  if (liveArtplayer && liveArtplayer.video) { return liveArtplayer.video; }
  var stage = document.getElementById('live-stage');
  if (!stage) { return null; }
  var video = document.getElementById('live-player');
  if (!video) {
    video = document.createElement('video');
    video.id = 'live-player';
    video.controls = true;
    video.autoplay = true;
    video.playsInline = true;
    stage.appendChild(video);
  }
  return video;
}

function liveEnsureArtplayer() {
  if (liveArtplayer || !window.Artplayer) { return; }
  var host = document.getElementById('live-artplayer');
  if (!host) { return; }
  try {
    liveArtplayer = new window.Artplayer({
      container: host,
      url: '',
      type: '',
      isLive: true,
      autoplay: true,
      muted: true,
      volume: .8,
      loop: false,
      pip: false,
      airplay: false,
      fullscreen: true,
      snapshot: false,
      autoMini: false,
      theme: '#ff5a5f',
    });
  } catch (error) {
    liveArtplayer = null;
  }
}

function liveReleaseArtplayer() {
  if (liveArtplayer) {
    try { liveArtplayer.destroy(true); } catch (error) {}
    liveArtplayer = null;
  }
}

function liveSourceById(id) {
  return liveState.sources.filter(function (item) { return item.id === id; })[0];
}

function liveFavourites() {
  try {
    var raw = localStorage.getItem('liveFavourites');
    return raw ? JSON.parse(raw) : [];
  } catch (error) { return []; }
}

function liveFavouriteKey(channel) {
  return liveState.source + '\u0001' + (channel.group || '') + '\u0001' + channel.name;
}

function liveIsFavourite(channel) {
  var key = liveFavouriteKey(channel);
  return liveFavourites().some(function (item) { return item.key === key; });
}

function liveToggleFavourite(channel) {
  var key = liveFavouriteKey(channel);
  var list = liveFavourites().filter(function (item) { return item.key !== key; });
  if (!liveIsFavourite(channel)) {
    list.unshift({
      key: key, source: liveState.source, group: channel.group || '',
      name: channel.name, urls: channel.urls || [], logo: channel.logo || '',
      token: channel.token || '',
    });
  }
  try { localStorage.setItem('liveFavourites', JSON.stringify(list.slice(0, 200))); } catch (error) {}
}

function liveMountChannel(channel, startIndex) {
  var urls = (channel.urls || []).filter(function (item) { return !!item; });
  // 房间型源（斗鱼 / 哔哩哔哩 / 虎牙）列表只带房间号，点播时才向服务端换取真实地址。
  if (!urls.length && channel.token) {
    if (liveState.playing && liveState.playing.token === channel.token) { return; }
    liveState.playing = channel;
    liveStopPlayer();
    var idleNode = document.getElementById('live-idle');
    if (idleNode) { idleNode.style.display = 'none'; }
    showNotice('正在解析直播地址…');
    liveGet('play', { source: liveState.source, room: channel.token })
      .then(function (data) {
        var list = (data && data.urls) || [];
        if (!list.length) {
          showNotice('该直播间当前没有可播放的地址');
          liveState.playing = null;
          if (idleNode) { idleNode.style.display = ''; }
          return;
        }
        channel.urls = list;
        if (data && data.headers) { channel.headers = data.headers; }
        liveMountChannel(channel, 0);
      })
      .catch(function (error) {
        showNotice(error.message || '直播地址解析失败');
        liveState.playing = null;
        if (idleNode) { idleNode.style.display = ''; }
      });
    return;
  }
  if (!urls.length) {
    showNotice('该频道没有可播线路');
    return;
  }
  var startRoute = (typeof startIndex === 'number' && startIndex >= 0 && startIndex < urls.length)
    ? startIndex
    : 0;
  liveState.playing = channel;
  liveState.urlList = urls;
  liveState.urlIndex = startRoute;
  liveSyncControls();
  liveStopPlayer();
  liveEnsureArtplayer();
  var idle = document.getElementById('live-idle');
  if (idle) { idle.style.display = 'none'; }
  var info = document.getElementById('live-title');
  if (info) {
    info.innerHTML = '<b>' + escapeHTML(channel.name) + '</b>' +
      (channel.group ? '<span class="live-group">' + escapeHTML(channel.group) + '</span>' : '') +
      ' <button type="button" class="btn mini" id="live-fav">' +
      (liveIsFavourite(channel) ? '★ 已收藏' : '☆ 收藏') + '</button>';
    var favButton = document.getElementById('live-fav');
    if (favButton) {
      favButton.addEventListener('click', function () {
        liveToggleFavourite(channel);
        var list = liveFavourites().filter(function (item) { return item.key === liveFavouriteKey(channel); });
        favButton.textContent = list.length ? '★ 已收藏' : '☆ 收藏';
      });
    }
  }
  livePlayRoute(urls, startRoute);
  renderLiveChannels();
}

// 已存在的直播 <video>：这里只读不建，避免为了同步按钮状态凭空多出一个空播放器。
function liveExistingVideo() {
  if (liveArtplayer && liveArtplayer.video) { return liveArtplayer.video; }
  return document.getElementById('live-player');
}

// 同步换台控制条：没有频道时禁用上一台/下一台，文案跟随真实播放状态，
// 用户点 ArtPlayer 自带控件暂停时也要同步。
function liveSyncControls() {
  var hasChannels = !!(liveState.channels && liveState.channels.length);
  var prev = document.getElementById('live-prev');
  var next = document.getElementById('live-next');
  if (prev) { prev.disabled = !hasChannels; }
  if (next) { next.disabled = !hasChannels; }
  var video = liveExistingVideo();
  var toggle = document.getElementById('live-toggle');
  if (toggle) {
    toggle.disabled = !video || !liveState.playing;
    toggle.textContent = video && !video.paused ? '暂停' : '播放';
  }
  if (video && !video.__liveControlsBound) {
    video.__liveControlsBound = true;
    video.addEventListener('play', liveSyncControls);
    video.addEventListener('pause', liveSyncControls);
    video.addEventListener('emptied', liveSyncControls);
  }
}

function liveTogglePlay() {
  var video = liveExistingVideo();
  if (!video) { return; }
  if (video.paused) {
    var started = video.play();
    if (started && started.catch) { started.catch(function () {}); }
  } else {
    video.pause();
  }
  liveSyncControls();
}

// 上一台 / 下一台：在当前频道列表里环绕切换，与 App 端 switchBy 一致。
function liveStepChannel(delta) {
  var list = liveState.channels || [];
  if (!list.length) {
    showNotice('当前分类还没有频道');
    return;
  }
  var index = -1;
  var playing = liveState.playing;
  if (playing) {
    index = list.indexOf(playing);
    if (index < 0) {
      // 收藏视图里的对象与列表项不是同一个引用，按频道标识兜底匹配。
      var key = liveFavouriteKey(playing);
      for (var i = 0; i < list.length; i++) {
        if (liveFavouriteKey(list[i]) === key) { index = i; break; }
      }
    }
  }
  var next = index < 0 ? 0 : (index + delta + list.length) % list.length;
  liveMountChannel(list[next], 0);
  liveScrollToChannel(next);
}

// 换台后把播放列表滚到当前项，长列表下不至于「换了却看不出选中哪个」。
function liveScrollToChannel(index) {
  var body = document.getElementById('live-channels-body');
  if (!body) { return; }
  var item = body.querySelector('[data-index="' + index + '"]');
  if (item && item.scrollIntoView) { item.scrollIntoView({ block: 'nearest' }); }
}

// 取直播播放用的 <video>：ArtPlayer 存在时用它的 video 元素，
// hls.js / flv.js / src 都挂到同一元素上，ArtPlayer 的控件仍对该元素生效。
function livePlayRoute(urls, index) {
  if (!urls || index >= urls.length) {
    showNotice('全部线路都无法播放');
    liveStopPlayer();
    return;
  }
  var first = urls[index];
  var target = /^(https?|rtp|udp):\/\//i.test(first)
    ? '/api/livestream/stream?source=' + encodeURIComponent(liveState.source) +
      '&url=' + encodeURIComponent(first)
    : first;
  var video = liveVideoElement();
  if (!video) { return; }
  // 直播默认静音开播：浏览器只允许「静音」自动播放，未静音会 play() 被拦、
  // ArtPlayer 转圈永不消失、表现为「一直加载无画面」。用户可点 ArtPlayer 控件开声。
  video.muted = true;
  liveStopDecoder();
  liveState.urlList = urls;
  liveState.urlIndex = index;
  if (first.indexOf('rtmp') === 0 || first.indexOf('rtsp') === 0 ||
      first.indexOf('rtp') === 0 || first.indexOf('udp') === 0) {
    showNotice('该线路是 ' + first.split('://')[0] + ' 协议，浏览器无法直接播放');
    return;
  }
  // 判定真实媒体类型：按 URL 原始后缀（而非代理前缀）。秀果等直播源下发 .flv，
  // 浏览器原生与 hls.js 都无法解码，必须走 flv.js；.m3u8 走 hls.js；其余直连 src。
  var pathOnly = first.split('?')[0].split('#')[0];
  var isFlv = /\.flv$/i.test(pathOnly);
  var isHls = /\.m3u8$/i.test(pathOnly);
  if (isFlv && window.flvjs && window.flvjs.isSupported()) {
    liveStartFlv(video, target);
    return;
  }
  if (isHls && window.Hls && window.Hls.isSupported()) {
    liveStartHls(video, target, urls, index);
    return;
  }
  // 兜底：直连 video.src（mp4 等浏览器原生可解的格式）。
  video.src = target;
  video.play().catch(function () {});
}

// flv.js 解码 .flv 直播流，挂到 ArtPlayer 的 video 元素。
function liveStartFlv(video, target) {
  try {
    liveFlvInstance = window.flvjs.createPlayer({
      type: 'flv',
      url: target,
      isLive: true,
      hasAudio: true,
      enableStashBuffer: true,
      stashInitialSize: 512,
      lazyLoad: false,
      autoCleanupSourceBuffer: true,
    });
  } catch (error) {
    showNotice('FLV 解码器初始化失败');
    return;
  }
  liveFlvInstance.attachMediaElement(video);
  liveFlvInstance.on(window.flvjs.Events.ERROR, function (type, detail) {
    showNotice('FLV 流异常（' + detail + '）');
  });
  liveFlvInstance.load();
  video.play().catch(function () {});
}

// hls.js 解码 .m3u8 直播流，挂到 ArtPlayer 的 video 元素。
function liveStartHls(video, target, urls, index) {
  liveHlsInstance = new window.Hls({ lowLatencyMode: false, enableWorker: true });
  liveHlsInstance.on(window.Hls.Events.ERROR, function (event, data) {
    if (!data || !data.fatal) { return; }
    if (data.type === window.Hls.ErrorTypes.MEDIA_ERROR) {
      liveHlsInstance.recoverMediaError();
      return;
    }
    if (data.type === window.Hls.ErrorTypes.NETWORK_ERROR) {
      showNotice('线路 ' + (index + 1) + ' 异常，尝试下一条…');
      livePlayRoute(urls, index + 1);
    }
  });
  liveHlsInstance.loadSource(target);
  liveHlsInstance.attachMedia(video);
  video.play().catch(function () {});
}

// 销毁 flv.js / hls.js 解码器（换台、离页、停播时调用，避免后台继续拉流）。
function liveStopDecoder() {
  if (liveFlvInstance) {
    try { liveFlvInstance.destroy(); } catch (error) {}
    liveFlvInstance = null;
  }
  if (liveHlsInstance) {
    try { liveHlsInstance.destroy(); } catch (error) {}
    liveHlsInstance = null;
  }
}

function liveStopPlayer() {
  liveStopDecoder();
  var stage = document.getElementById('live-stage');
  if (stage) {
    var video = stage.querySelector('#live-player, .art-video');
    if (video) {
      try {
        video.pause();
        video.removeAttribute('src');
        video.load();
      } catch (error) {}
    }
  }
}

// 左侧播放列表：一列频道、可上下滚动；「收藏」视图下显示收藏频道。
function renderLiveChannels() {
  var body = document.getElementById('live-channels-body');
  if (!body) { return; }
  // 列表变化（换源/换分类/加载更多）后换台按钮的可用状态跟着变。
  liveSyncControls();
  if (liveState.showFavs) {
    var favourites = liveFavourites();
    if (!favourites.length) {
      body.innerHTML = '<div class="empty">还没有收藏频道，播放时点星标即可收藏。</div>';
      return;
    }
    var playingKey = liveState.playing ? liveFavouriteKey(liveState.playing) : null;
    body.innerHTML = '<div class="live-group-head">★ 收藏</div>' +
      favourites.map(function (item) {
        var active = item.key === playingKey ? ' active' : '';
        return '<button type="button" class="live-channel live-fav' + active +
          '" data-key="' + escapeHTML(item.key) + '"><span class="live-name">' +
          escapeHTML(item.name) + '</span></button>';
      }).join('');
    Array.prototype.forEach.call(body.querySelectorAll('.live-fav'), function (button) {
      button.addEventListener('click', function () {
        var key = button.getAttribute('data-key');
        var item = liveFavourites().filter(function (entry) { return entry.key === key; })[0];
        if (!item) { return; }
        if (item.source !== liveState.source) {
          liveSelectSource(item.source, function () { liveMountChannel(item, 0); });
        } else {
          liveMountChannel(item, 0);
        }
      });
    });
    return;
  }
  if (liveState.channelLoading) {
    body.innerHTML = '<div class="loading">正在加载频道…</div>';
    return;
  }
  if (!liveState.channels.length) {
    body.innerHTML = '<div class="empty">当前分类暂无频道，可切换上方分类或直播源。</div>';
    return;
  }
  var groups = {};
  var order = [];
  liveState.channels.forEach(function (channel) {
    var key = channel.group || '其他';
    if (!groups[key]) { groups[key] = []; order.push(key); }
    groups[key].push(channel);
  });
  var currentKey = liveState.playing ? liveFavouriteKey(liveState.playing) : null;
  body.innerHTML = order.map(function (key) {
    return '<div class="live-group-head">' + escapeHTML(key) +
      ' <span class="live-count">' + groups[key].length + '</span></div>' +
      groups[key].map(function (channel) {
        var active = liveFavouriteKey(channel) === currentKey ? ' active' : '';
        var count = (channel.urls || []).length;
        var index = liveState.channels.indexOf(channel);
        return '<button type="button" class="live-channel' + active +
          '" data-group="' + escapeHTML(channel.group || '') +
          '" data-name="' + escapeHTML(channel.name) +
          '" data-index="' + index + '">' +
          '<span class="live-name">' + escapeHTML(channel.name) + '</span>' +
          (count > 1 ? '<span class="live-count">' + count + ' 路</span>' : '') +
          '</button>';
      }).join('');
  }).join('') + (liveState.hasMore
    ? '<button type="button" class="btn mini live-more">' +
      (liveState.moreLoading ? '正在加载…' : '加载更多') + '</button>'
    : '');
  var moreButton = body.querySelector('.live-more');
  if (moreButton) {
    moreButton.addEventListener('click', liveLoadMoreChannels);
  }
  Array.prototype.forEach.call(body.querySelectorAll('.live-channel'), function (button) {
    button.addEventListener('click', function () {
      var name = button.getAttribute('data-name');
      var group = button.getAttribute('data-group');
      var channel = liveState.channels.filter(function (item) {
        return item.name === name && (item.group || '') === (group || '');
      })[0];
      if (channel) { liveMountChannel(channel, 0); }
    });
  });
}

// 左侧分类列：分类（游戏 / 娱乐 / 赛事等）一列上下滚动；list 型源无分类时显示提示。
function renderLivePlatforms() {
  var body = document.getElementById('live-platforms-body');
  if (!body) { return; }
  if (liveState.platformLoading) {
    body.innerHTML = '<div class="loading">正在加载分类…</div>';
    return;
  }
  if (!liveState.platforms.length) {
    body.innerHTML = '<div class="empty">该直播源无分类，下方为全部频道。</div>';
    return;
  }
  body.innerHTML = liveState.platforms.map(function (item) {
    var active = item.id === liveState.platform ? ' active' : '';
    return '<button type="button" class="live-channel live-platform-item' + active +
      '" data-id="' + escapeHTML(item.id) + '" data-endpoint="' + escapeHTML(item.endpoint || '') +
      '" data-name="' + escapeHTML(item.name) + '">' +
      '<span class="live-name">' + escapeHTML(item.name) + '</span>' +
      '<span class="live-count">' + (item.count || 0) + '</span></button>';
  }).join('');
  Array.prototype.forEach.call(body.querySelectorAll('.live-platform-item'), function (button) {
    button.addEventListener('click', function () {
      liveSelectPlatform({
        id: button.getAttribute('data-id'),
        endpoint: button.getAttribute('data-endpoint'),
        name: button.getAttribute('data-name'),
      });
    });
  });
}

function renderLivePanel() {
  var panel = document.getElementById('live-panel-body');
  if (!panel) { return; }
  var sources = liveState.sources.map(function (item) {
    return '<button type="button" class="btn mini live-source' +
      (item.id === liveState.source ? ' active' : '') + '" data-id="' + escapeHTML(item.id) + '">' +
      escapeHTML(item.name) + '</button>';
  }).join('');
  var sourceHTML = liveState.loading
    ? '<div class="loading">正在加载直播源…</div>'
    : '<div class="live-sources">' + sources +
      (liveState.sources.length ? '' : '<span class="live-empty-inline">暂无直播源，可添加自定义源</span>') + '</div>';
  panel.innerHTML =
    '<div class="live-toolbar">' +
      sourceHTML +
      '<label class="live-green"><input id="live-green" type="checkbox"' +
        (liveState.green ? ' checked' : '') + '> 绿色模式</label>' +
      '<button type="button" class="btn mini" id="live-custom-toggle">自定义源</button>' +
      '<button type="button" class="btn mini live-favs-toggle' +
        (liveState.showFavs ? ' active' : '') + '" id="live-favs-toggle">★ 收藏</button>' +
    '</div>' +
    '<div class="live-custom-form" id="live-custom-form"' + (liveState.showCustom ? '' : ' hidden') + '>' +
      '<input id="live-custom-name" placeholder="直播源名称" />' +
      '<input id="live-custom-url" placeholder="m3u / txt 直链" />' +
      '<button type="button" class="btn" id="live-custom-add">添加</button>' +
      '<button type="button" class="btn mini" id="live-custom-cancel">取消</button>' +
      '<span id="live-custom-status"></span>' +
    '</div>' +
    '<div class="live-columns">' +
      '<div class="live-col live-col-platforms">' +
        '<div class="live-group-head">分类</div>' +
        '<div class="live-platform-scroll" id="live-platforms-body"></div>' +
      '</div>' +
      '<div class="live-col live-col-channels">' +
        '<div class="live-group-head">播放列表</div>' +
        '<div class="live-channel-scroll" id="live-channels-body"></div>' +
      '</div>' +
    '</div>';
  Array.prototype.forEach.call(panel.querySelectorAll('.live-source'), function (button) {
    button.addEventListener('click', function () { liveSelectSource(button.getAttribute('data-id')); });
  });
  var greenToggle = document.getElementById('live-green');
  if (greenToggle) {
    greenToggle.addEventListener('change', function () {
      liveState.green = greenToggle.checked;
      if (liveState.source) { liveSelectSource(liveState.source); }
    });
  }
  var customToggle = document.getElementById('live-custom-toggle');
  if (customToggle) {
    customToggle.addEventListener('click', function () {
      liveState.showCustom = !liveState.showCustom;
      liveState.showFavs = false;
      renderLivePanel();
      if (liveState.showCustom) {
        var nameInput = document.getElementById('live-custom-name');
        if (nameInput) { nameInput.focus(); }
      }
    });
  }
  var customForm = document.getElementById('live-custom-form');
  if (customForm && !customForm.hidden) {
    var addButton = document.getElementById('live-custom-add');
    var cancelButton = document.getElementById('live-custom-cancel');
    var status = document.getElementById('live-custom-status');
    if (cancelButton) {
      cancelButton.addEventListener('click', function () {
        liveState.showCustom = false;
        renderLivePanel();
      });
    }
    if (addButton) {
      addButton.addEventListener('click', function () {
        var name = document.getElementById('live-custom-name').value.trim();
        var endpoint = document.getElementById('live-custom-url').value.trim();
        if (!name || !endpoint) {
          status.textContent = '请填写名称与直链';
          return;
        }
        addButton.disabled = true;
        status.textContent = '';
        livePost('custom-sources', { action: 'save', name: name, endpoint: endpoint })
          .then(function () { return liveLoadSources(); })
          .then(function () {
            liveState.showCustom = false;
            renderLivePanel();
            status.textContent = '已添加';
          })
          .catch(function (error) { status.textContent = error.message || '添加失败'; })
          .then(function () { addButton.disabled = false; });
      });
    }
  }
  var favsToggle = document.getElementById('live-favs-toggle');
  if (favsToggle) {
    favsToggle.addEventListener('click', function () {
      liveState.showFavs = !liveState.showFavs;
      liveState.showCustom = false;
      renderLivePanel();
    });
  }
  renderLivePlatforms();
  renderLiveChannels();
}

function liveLoadSources() {
  liveState.loading = true;
  return liveGet('sources', { green: liveState.green ? '1' : '0' })
    .then(function (list) {
      liveState.sources = list || [];
      liveState.loading = false;
      if (!liveState.source && list.length) { liveState.source = list[0].id; }
      return list;
    })
    .catch(function (error) {
      liveState.loading = false;
      throw error;
    });
}

function liveSelectSource(id, done) {
  liveState.source = id;
  liveState.showFavs = false;
  liveState.channels = [];
  liveState.platforms = [];
  liveState.platform = '';
  liveState.channelLoading = true;
  liveState.platformLoading = true;
  liveState.playing = null;
  liveState.page = 1;
  liveState.hasMore = false;
  liveState.moreLoading = false;
  liveStopPlayer();
  var idleOnSource = document.getElementById('live-idle');
  if (idleOnSource) { idleOnSource.style.display = ''; }
  var source = liveSourceById(id) || {};
  renderLivePanel();
  // pingtai / room 都要先取分类再取房间列表，其余（list 型）直接是频道清单。
  if (source.protocol === 'pingtai' || source.protocol === 'room') {
    liveGet('platforms', { source: id })
      .then(function (list) {
        liveState.platformLoading = false;
        liveState.platforms = list || [];
        renderLivePlatforms();
        // 自动载入第一个分类的频道，避免用户必须手动点分类才看得到内容。
        if (liveState.platforms.length) {
          liveSelectPlatform(liveState.platforms[0], function () { done && done(); });
        } else {
          liveState.channelLoading = false;
          renderLiveChannels();
          done && done();
        }
      })
      .catch(function (error) {
        liveState.platformLoading = false;
        liveState.channelLoading = false;
        renderLivePlatforms();
        renderLiveChannels();
        showNotice(error.message || '分类加载失败');
        if (done) { done(); }
      });
    return;
  }
  liveState.platformLoading = false;
  liveGet('channels', { source: id, green: liveState.green ? '1' : '0' })
    .then(function (list) {
      liveState.channelLoading = false;
      liveState.channels = list || [];
      liveState.platforms = [];
      liveState.platform = '';
      renderLivePlatforms();
      renderLiveChannels();
      if (done) { done(); }
    })
    .catch(function (error) {
      liveState.channelLoading = false;
      renderLiveChannels();
      showNotice(error.message || '频道加载失败');
      if (done) { done(); }
    });
}

function liveSelectPlatform(platform, done) {
  liveState.channelLoading = true;
  liveState.page = 1;
  liveState.hasMore = false;
  liveState.moreLoading = false;
  renderLiveChannels();
  liveGet('channels', {
    source: liveState.source,
    platform: platform.id,
    endpoint: platform.endpoint || '',
    group: platform.name || '',
    page: 1,
    green: liveState.green ? '1' : '0',
  })
    .then(function (list) {
      liveState.channelLoading = false;
      liveState.platform = platform.id;
      liveState.channels = list || [];
      // 房间型源没有总数接口，用「这一页是否满」判断还有没有下一页。
      liveState.hasMore = list.length >= 24;
      renderLivePlatforms();
      renderLiveChannels();
      if (done) { done(); }
    })
    .catch(function (error) {
      liveState.channelLoading = false;
      renderLiveChannels();
      showNotice(error.message || '频道加载失败');
      if (done) { done(); }
    });
}

// 房间型源的「加载更多」：按页追加，按房间号去重。
function liveLoadMoreChannels() {
  if (!liveState.hasMore || liveState.moreLoading) { return; }
  var platform = liveState.platforms.filter(function (item) {
    return item.id === liveState.platform;
  })[0];
  if (!platform) { return; }
  liveState.moreLoading = true;
  renderLiveChannels();
  var page = liveState.page + 1;
  liveGet('channels', {
    source: liveState.source,
    platform: platform.id,
    endpoint: platform.endpoint || '',
    group: platform.name || '',
    page: page,
    green: liveState.green ? '1' : '0',
  })
    .then(function (list) {
      liveState.moreLoading = false;
      liveState.page = page;
      var seen = {};
      liveState.channels.forEach(function (item) {
        seen[(item.token || '') + '\u0001' + (item.group || '') + '\u0001' + item.name] = true;
      });
      (list || []).forEach(function (item) {
        var key = (item.token || '') + '\u0001' + (item.group || '') + '\u0001' + item.name;
        if (!seen[key]) { seen[key] = true; liveState.channels.push(item); }
      });
      liveState.hasMore = (list || []).length >= 24;
      renderLiveChannels();
    })
    .catch(function (error) {
      liveState.moreLoading = false;
      showNotice(error.message || '加载更多失败');
      renderLiveChannels();
    });
}

function renderLiveView() {
  view.innerHTML =
    '<div class="live-wrap">' +
    '<div class="live-stage" id="live-stage">' +
      '<div class="live-artplayer" id="live-artplayer"></div>' +
      '<div class="live-idle" id="live-idle">选择频道开始观看</div>' +
    '</div>' +
    // 与 App 播放页一致的换台控制：上一台 / 暂停·继续 / 下一台，按当前列表环绕。
    '<div class="live-controls">' +
      '<button type="button" class="btn mini" id="live-prev" title="上一个频道">◀ 上一台</button>' +
      '<button type="button" class="btn mini" id="live-toggle" title="暂停或继续播放">暂停</button>' +
      '<button type="button" class="btn mini" id="live-next" title="下一个频道">下一台 ▶</button>' +
    '</div>' +
    '<div class="live-title" id="live-title"></div>' +
    '<div class="live-panel"><div id="live-panel-body"></div></div>' +
    '</div>';
  liveEnsureArtplayer();
  var prevButton = document.getElementById('live-prev');
  if (prevButton) { prevButton.addEventListener('click', function () { liveStepChannel(-1); }); }
  var nextButton = document.getElementById('live-next');
  if (nextButton) { nextButton.addEventListener('click', function () { liveStepChannel(1); }); }
  var toggleButton = document.getElementById('live-toggle');
  if (toggleButton) { toggleButton.addEventListener('click', liveTogglePlay); }
  liveSyncControls();
  return liveLoadSources().then(function (list) {
    if (list.length && !liveState.source) { liveState.source = list[0].id; }
    renderLivePanel();
    if (liveState.source) {
      return liveSelectSource(liveState.source);
    }
  }).catch(function (error) {
    var panel = document.getElementById('live-panel-body');
    if (panel) { panel.innerHTML = '<div class="empty">' + escapeHTML(error.message || '直播加载失败') + '</div>'; }
  });
}

/* ---------- 听书（Web 版） ---------- */

var AUDIOBOOK_PROGRESS_KEY = 'duanjuweb:audiobookProgress';
var AUDIOBOOK_SHELF_KEY = 'duanjuweb:audiobookShelf';
var audiobookBoards = [
  { name: '听书榜', side: '17', type: '1' },
  { name: '女生听书', side: '17', type: '0' },
];
var audiobookRates = [1, 1.25, 1.5, 2, 0.75];

var audiobookState = {
  board: 0,
  page: 1,
  pageCount: 1,
  total: 0,
  pageSize: 10,
  hasMore: false,
  books: [],
  loading: false,
  query: '',
  // 分类来自书池的真实标签 + 官方书城实时返回的 category_info / popular_tags；
  // 空串表示「全部」。
  category: '',
  categories: [],
  // 书源：fanqie = 番茄听书（畅听男女榜）。
  origin: 'fanqie',
  // 分类条与「全部分类」面板：面板状态要在书库轮询重绘后保持。
  allCategoriesOpen: false,
  revealCategory: false,
  // 服务端全量书库的加载进度：边加载边能用，前端按 loading 轮询补全。
  library: { loading: false, done: false, count: 0, error: '' },
  // 官方书城（fanqie.apk 反编译所得）实时抓取进度，服务端每 10 分钟刷新。
  official: { loading: false, count: 0, tabs: 0, tags: 0, error: '' },
  libraryToken: 0,
  shelf: false,
  book: null,
  chapters: [],
  chapterPage: 1,
  chapterHasMore: false,
  chapterIndex: -1,
  paragraphs: [],
  timed: false,
  duration: 0,
  rate: 1,
  textLoading: false,
  current: 0,
};

var audiobookAudio = null;
var audiobookHls = null;
var audiobookLibraryTimer = null;
var audiobookSleepTimer = null;
var audiobookSleepMinutes = 0;
var audiobookSleepUntil = 0;

// 睡眠定时：15 / 30 / 60 分钟循环，到点暂停播放（与 App 端一致）。
function abCycleSleep() {
  var options = [0, 15, 30, 60];
  var index = options.indexOf(audiobookSleepMinutes);
  audiobookSleepMinutes = options[(index + 1) % options.length];
  if (audiobookSleepTimer) {
    window.clearInterval(audiobookSleepTimer);
    audiobookSleepTimer = null;
  }
  if (!audiobookSleepMinutes) {
    audiobookSleepUntil = 0;
    abSyncPlayer();
    showNotice('已关闭睡眠定时');
    return;
  }
  audiobookSleepUntil = Date.now() + audiobookSleepMinutes * 60000;
  audiobookSleepTimer = window.setInterval(function () {
    if (Date.now() < audiobookSleepUntil) {
      abSyncPlayer();
      return;
    }
    window.clearInterval(audiobookSleepTimer);
    audiobookSleepTimer = null;
    audiobookSleepUntil = 0;
    audiobookSleepMinutes = 0;
    if (audiobookAudio) {
      try { audiobookAudio.pause(); } catch (error) {}
    }
    abSyncPlayer();
    showNotice('睡眠定时已到，已暂停播放');
  }, 20000);
  abSyncPlayer();
  showNotice(audiobookSleepMinutes + ' 分钟后自动暂停');
}

function abSleepLabel() {
  if (!audiobookSleepUntil) { return '定时'; }
  var left = Math.max(1, Math.ceil((audiobookSleepUntil - Date.now()) / 60000));
  return '定时 ' + left + '分';
}

function abGet(path, params) {
  var query = new URLSearchParams(params || {});
  return fetch('/api/audiobook/' + path + '?' + query.toString())
    .then(function (response) { return response.json(); })
    .then(function (data) {
      if (!data.ok) { throw new Error(data.error || '听书请求失败'); }
      return data.data;
    });
}

function abReadJSON(key, fallback) {
  try {
    var raw = window.localStorage.getItem(key);
    return raw ? JSON.parse(raw) : fallback;
  } catch (error) {
    return fallback;
  }
}

function abWriteJSON(key, value) {
  try { window.localStorage.setItem(key, JSON.stringify(value)); } catch (error) {}
}

function abReadProgress(chapterId) {
  var map = abReadJSON(AUDIOBOOK_PROGRESS_KEY, {});
  var value = Number(map[chapterId]);
  return value > 0 ? value : 0;
}

function abSaveProgress(chapterId, seconds) {
  if (!chapterId || !(seconds > 0)) { return; }
  var map = abReadJSON(AUDIOBOOK_PROGRESS_KEY, {});
  map[chapterId] = Math.floor(seconds);
  var keys = Object.keys(map);
  // 只留最近 500 条，避免本地存储无限膨胀。
  if (keys.length > 500) {
    var trimmed = {};
    keys.slice(keys.length - 500).forEach(function (key) { trimmed[key] = map[key]; });
    map = trimmed;
  }
  abWriteJSON(AUDIOBOOK_PROGRESS_KEY, map);
}

function abShelf() {
  var list = abReadJSON(AUDIOBOOK_SHELF_KEY, []);
  return Array.isArray(list) ? list : [];
}

function abRememberBook(book) {
  if (!book || !book.id) { return; }
  var list = abShelf().filter(function (item) { return item.id !== book.id; });
  list.unshift({
    id: book.id,
    title: book.title,
    author: book.author || '',
    category: book.category || '',
    cover: book.cover || '',
    intro: book.intro || '',
    board: typeof book.board === 'number' ? book.board : 0
  });
  abWriteJSON(AUDIOBOOK_SHELF_KEY, list.slice(0, 100));
}

function abFormatTime(seconds) {
  var total = Math.max(0, Math.floor(seconds || 0));
  var minute = Math.floor(total / 60);
  var second = total % 60;
  return minute + ':' + (second < 10 ? '0' : '') + second;
}

function abEnsureAudio() {
  if (audiobookAudio) { return audiobookAudio; }
  var audio = new window.Audio();
  audio.preload = 'auto';
  audio.addEventListener('ended', function () { abPlayChapter(audiobookState.chapterIndex + 1); });
  audio.addEventListener('timeupdate', abOnTime);
  audio.addEventListener('play', abSyncPlayer);
  audio.addEventListener('pause', abSyncPlayer);
  audiobookAudio = audio;
  return audio;
}

function abStopAudio() {
  if (audiobookHls) {
    try { audiobookHls.destroy(); } catch (error) {}
    audiobookHls = null;
  }
  var audio = audiobookAudio;
  if (audio) {
    try {
      audio.pause();
      audio.removeAttribute('src');
      audio.load();
    } catch (error) {}
  }
  audiobookState.current = 0;
}

function abChapterId() {
  var chapter = audiobookState.chapters[audiobookState.chapterIndex];
  return chapter ? chapter.id : '';
}

function abOnTime() {
  var audio = audiobookAudio;
  if (!audio) { return; }
  audiobookState.current = audio.currentTime || 0;
  var chapterId = abChapterId();
  // 每 5 秒落一次进度，避免 timeupdate（每秒 4 次）频繁写本地存储。
  if (chapterId && Math.floor(audiobookState.current) % 5 === 0) {
    abSaveProgress(chapterId, audiobookState.current);
  }
  abSyncPlayer();
  abHighlightParagraph();
}

function abSyncPlayer() {
  var bar = document.getElementById('ab-progress');
  var audio = audiobookAudio;
  var total = (audio && isFinite(audio.duration) && audio.duration > 0)
    ? audio.duration
    : audiobookState.duration;
  var current = audio ? (audio.currentTime || 0) : 0;
  if (bar) {
    bar.max = total || 0;
    bar.value = current;
  }
  var label = document.getElementById('ab-time');
  if (label) { label.textContent = abFormatTime(current) + ' / ' + abFormatTime(total); }
  var toggle = document.getElementById('ab-toggle');
  if (toggle) {
    var playing = audio && !audio.paused;
    toggle.textContent = playing ? '暂停' : '播放';
  }
  var rateButton = document.getElementById('ab-rate');
  if (rateButton) { rateButton.textContent = audiobookState.rate + 'x'; }
  var sleepButton = document.getElementById('ab-sleep');
  if (sleepButton) { sleepButton.textContent = abSleepLabel(); }
}

function abBooksHTML(books) {
  if (!books.length) {
    var empty = audiobookState.library.loading && !audiobookState.shelf
      ? '正在加载完整听书书库，请稍候…'
      : '这里还没有内容，换个分类或搜索一下。';
    return '<div class="empty">' + empty + '</div>';
  }
  return '<div class="ab-grid">' + books.map(function (book, index) {
    // 封面来自榜单 thumb_url；被防盗链拦掉时隐藏图片，露出底下的书名首字占位。
    var cover = book.cover
      ? '<img class="ab-cover-img" src="' + escapeHTML(book.cover) + '" alt="" loading="lazy" />'
      : '';
    return '<button type="button" class="ab-card" data-index="' + index + '">' +
      '<span class="ab-cover">' + escapeHTML((book.title || '书').slice(0, 1)) + cover + '</span>' +
      '<span class="ab-meta"><span class="ab-title">' + escapeHTML(book.title) + '</span>' +
      (book.voiceMode
        ? '<span class="ab-voice ' + (book.voiceMode === '真人录音' ? 'real' : 'ai') +
          '">' + escapeHTML(book.voiceMode) + '</span>'
        : '') +
      '<span class="ab-sub">' + escapeHTML(book.author || '佚名') +
      (book.category ? ' · ' + escapeHTML(book.category) : '') + '</span>' +
      (book.intro ? '<span class="ab-intro">' + escapeHTML(book.intro) + '</span>' : '') +
      '</span></button>';
  }).join('') + '</div>';
}

// 列表上方的分类条 + 书库进度 + 分页：分类与分页都基于服务端全量书库。
function abListHeadHTML() {
  if (audiobookState.shelf) {
    return '<div class="ab-list-head"><div class="ab-pager-row">' +
      '<span class="ab-count">书架共 ' + audiobookState.books.length + ' 本</span></div></div>';
  }
  var categories = '<button type="button" class="btn mini ab-category' +
    (audiobookState.category === '' ? ' active' : '') + '" data-index="-1">全部</button>' +
    audiobookState.categories.map(function (name, index) {
      return '<button type="button" class="btn mini ab-category' +
        (audiobookState.category === name ? ' active' : '') +
        '" data-index="' + index + '">' + escapeHTML(name) + '</button>';
    }).join('');
  // 「全部分类」面板：把书池里所有真实分类一次列全，选中后回到分类条并
  // 重新加载该分类的书；面板状态存在 state 里，书库轮询重绘不会把它关掉。
  var allOptions = '<button type="button" class="btn mini ab-category-option' +
    (audiobookState.category === '' ? ' active' : '') +
    '" data-ab-cat-index="-1">全部</button>' +
    audiobookState.categories.map(function (name, index) {
      return '<button type="button" class="btn mini ab-category-option' +
        (audiobookState.category === name ? ' active' : '') +
        '" data-ab-cat-index="' + index + '">' + escapeHTML(name) + '</button>';
    }).join('');
  var opened = audiobookState.allCategoriesOpen;
  var allPanel = '<div class="ab-category-panel" id="ab-category-panel"' +
    (opened ? '' : ' hidden') + '>' +
    '<div class="ab-category-panel-head"><span>全部分类 · 共 ' +
      audiobookState.categories.length + ' 类</span>' +
      '<button type="button" class="btn mini" id="ab-category-panel-close">关闭</button></div>' +
    '<div class="ab-category-panel-grid">' + allOptions + '</div></div>';
  var scope = audiobookState.query
    ? '搜索「' + escapeHTML(audiobookState.query) + '」'
    : (audiobookState.category
      ? '分类「' + escapeHTML(audiobookState.category) + '」'
      : '全量书库');
  var official = audiobookState.official || {};
  var officialText = official.error
    ? ' · 官方书城：' + escapeHTML(official.error)
    : (Number(official.count) > 0
      ? ' · 官方书城 ' + Number(official.count) + ' 本'
        + (Number(official.tags) > 0 ? ' / ' + Number(official.tags) + ' 个标签' : '')
        + (official.loading ? '（更新中）' : '')
      : '');
  var status = audiobookState.library.error
    ? escapeHTML(audiobookState.library.error) + officialText
    : (audiobookState.library.loading
      ? '书库加载中…（已收录 ' + audiobookState.library.count + ' 本）'
      : scope + ' · 共 ' + audiobookState.total + ' 本') + officialText;
  var prevDisabled = audiobookState.page <= 1 ? ' disabled' : '';
  var nextDisabled = audiobookState.page >= audiobookState.pageCount ? ' disabled' : '';
  var pager = '<span class="ab-pager">' +
    '<button type="button" class="btn mini" id="ab-prev-page"' + prevDisabled + '>上一页</button>' +
    '<span class="ab-page-info">第 ' + audiobookState.page + ' / ' + audiobookState.pageCount + ' 页</span>' +
    '<button type="button" class="btn mini" id="ab-next-page"' + nextDisabled + '>下一页</button>' +
    '</span>';
  return '<div class="ab-list-head">' +
    '<div class="ab-category-bar">' +
      '<div class="ab-category-row"><span class="ab-category-label">分类</span>' + categories + '</div>' +
      '<button type="button" class="btn mini ab-category-all' + (opened ? ' active' : '') +
        '" id="ab-all-categories" aria-expanded="' + (opened ? 'true' : 'false') +
        '">全部分类</button>' +
      allPanel +
    '</div>' +
    '<div class="ab-pager-row"><span class="ab-count">' + status + '</span>' + pager + '</div>' +
    '</div>';
}

// 切换书源时把书池、分类、搜索一起重置，避免把上一源的书单混进来。
function abSelectOrigin(origin) {
  if (audiobookState.origin === origin) { return; }
  audiobookState.origin = origin;
  audiobookState.board = 0;
  audiobookState.category = '';
  audiobookState.query = '';
  audiobookState.shelf = false;
  audiobookState.page = 1;
  audiobookState.categories = [];
  audiobookState.allCategoriesOpen = false;
  var input = document.getElementById('ab-search-input');
  if (input) { input.value = ''; }
  renderAudiobookToolbar();
  abLoadLibrary(1);
}

// 分类条与「全部分类」面板共用的切换逻辑：选中后立刻重新拉该分类第一页。
function abSelectCategory(name) {
  audiobookState.category = name;
  audiobookState.query = '';
  audiobookState.shelf = false;
  audiobookState.page = 1;
  audiobookState.allCategoriesOpen = false;
  audiobookState.revealCategory = true;
  var input = document.getElementById('ab-search-input');
  if (input) { input.value = ''; }
  renderAudiobookToolbar();
  // 先立刻刷新分类条选中态并把它滚到可见处，再异步拉书，避免点击后"没反应"。
  renderAudiobookBody();
  abLoadLibrary(1);
}

// 点击分类后把横向分类条滚到选中项，右侧后续分类跟着露出来（与视频分类
// 点击后 tab 跟随定位一致）。只在真正切换分类时跑一次，轮询重绘不抢滚动。
function abRevealCategory() {
  if (!audiobookState.revealCategory) { return; }
  audiobookState.revealCategory = false;
  var row = document.querySelector('.ab-category-row');
  if (!row) { return; }
  var active = row.querySelector('.ab-category.active');
  if (!active) { return; }
  var rowRect = row.getBoundingClientRect();
  var activeRect = active.getBoundingClientRect();
  var delta = (activeRect.left + activeRect.width / 2) -
    (rowRect.left + rowRect.width / 2);
  if (Math.abs(delta) < 4) { return; }
  if (typeof row.scrollBy === 'function') {
    row.scrollBy({ left: delta, behavior: 'smooth' });
  } else {
    row.scrollLeft += delta;
  }
}

// 「全部分类」面板：一次列出书池里全部真实分类，选中即加载。
function abBindCategoryPanel(body) {
  var toggle = body.querySelector('#ab-all-categories');
  var panel = body.querySelector('#ab-category-panel');
  if (!toggle || !panel) { return; }
  function setOpen(open) {
    audiobookState.allCategoriesOpen = open;
    panel.hidden = !open;
    toggle.classList.toggle('active', open);
    toggle.setAttribute('aria-expanded', open ? 'true' : 'false');
  }
  toggle.addEventListener('click', function (event) {
    event.stopPropagation();
    setOpen(!audiobookState.allCategoriesOpen);
  });
  var close = panel.querySelector('#ab-category-panel-close');
  if (close) {
    close.addEventListener('click', function () { setOpen(false); });
  }
  Array.prototype.forEach.call(panel.querySelectorAll('.ab-category-option'), function (button) {
    button.addEventListener('click', function () {
      var index = Number(button.getAttribute('data-ab-cat-index'));
      abSelectCategory(index < 0 ? '' : (audiobookState.categories[index] || ''));
    });
  });
}

// 点击面板以外的地方收起面板；只注册一次，避免列表反复重绘叠加监听。
document.addEventListener('click', function (event) {
  if (!audiobookState.allCategoriesOpen) { return; }
  var bar = document.querySelector('.ab-category-bar');
  if (bar && bar.contains(event.target)) { return; }
  audiobookState.allCategoriesOpen = false;
  var panel = document.getElementById('ab-category-panel');
  if (panel) { panel.hidden = true; }
  var toggle = document.getElementById('ab-all-categories');
  if (toggle) {
    toggle.classList.remove('active');
    toggle.setAttribute('aria-expanded', 'false');
  }
});

// 书库后台还在翻页时定时补全当前查询；token 变化（用户切榜/搜索/翻页）即作废。
function abScheduleLibraryRefresh() {
  if (audiobookLibraryTimer) {
    window.clearTimeout(audiobookLibraryTimer);
    audiobookLibraryTimer = null;
  }
  var info = audiobookState.library;
  var official = audiobookState.official || {};
  // 榜单全量抓取或官方书城刷新还在跑时，定时回来补全当前页。
  var waiting = (info && info.loading && !info.done) || !!official.loading;
  if (!waiting) { return; }
  var token = audiobookState.libraryToken;
  audiobookLibraryTimer = window.setTimeout(function () {
    audiobookLibraryTimer = null;
    if (token !== audiobookState.libraryToken) { return; }
    if (!audiobookState.book && !audiobookState.shelf && document.getElementById('ab-body')) {
      abLoadLibrary(audiobookState.page);
    }
  }, 1800);
}

function abLoadLibrary(page) {
  var token = ++audiobookState.libraryToken;
  audiobookState.loading = true;
  return abGet('library', {
    board: audiobookState.board,
    category: audiobookState.category,
    q: audiobookState.query,
    origin: audiobookState.origin,
    page: page,
    size: audiobookState.pageSize
  }).then(function (data) {
    if (token !== audiobookState.libraryToken) { return; }
    audiobookState.loading = false;
    audiobookState.page = Number(data.page) || 1;
    audiobookState.pageCount = Math.max(1, Number(data.pageCount) || 1);
    audiobookState.total = Number(data.total) || 0;
    audiobookState.hasMore = audiobookState.page < audiobookState.pageCount;
    audiobookState.books = (data.books || []).slice();
    audiobookState.categories = Array.isArray(data.categories) ? data.categories.slice() : [];
    audiobookState.library = data.library || { loading: false, done: true, count: 0, error: '' };
    audiobookState.official = data.official || audiobookState.official;
    // 不重建 toolbar：搜索框还在里面，轮询刷新时不能打断输入。
    renderAudiobookBody();
    if (document.getElementById('ab-body')) { abScheduleLibraryRefresh(); }
  }).catch(function (error) {
    if (token !== audiobookState.libraryToken) { return; }
    audiobookState.loading = false;
    var body = document.getElementById('ab-body');
    if (body) {
      body.innerHTML = '<div class="empty">' + escapeHTML(error.message || '听书书库加载失败') + '</div>';
    }
  });
}

function abParagraphsHTML() {
  if (audiobookState.textLoading) {
    return '<div class="loading">正在加载正文…</div>';
  }
  if (!audiobookState.paragraphs.length) {
    return '<div class="empty">这一章没有可显示的正文，可直接听音频。</div>';
  }
  return '<div class="ab-text">' + audiobookState.paragraphs.map(function (item, index) {
    var inner = item.text;
    if (item.segments && item.segments.length) {
      // 带逐句时间轴时按句拆成 span，高亮能跟到当前这一句。
      inner = item.segments.map(function (segment) {
        return '<span class="ab-seg" data-start="' + (segment.start || 0) + '">' +
          escapeHTML(segment.text) + '</span>';
      }).join('');
    }
    return '<p class="ab-line" data-index="' + index + '" data-start="' + (item.start || 0) + '">' +
      inner + '</p>';
  }).join('') + '</div>';
}

function abChaptersHTML() {
  if (!audiobookState.chapters.length) {
    return '<div class="loading">正在加载目录…</div>';
  }
  return audiobookState.chapters.map(function (chapter, index) {
    var active = index === audiobookState.chapterIndex ? ' active' : '';
    return '<button type="button" class="ab-chapter' + active + '" data-index="' + index + '">' +
      '<span class="ab-order">' + chapter.order + '</span>' +
      '<span class="ab-chapter-title">' + escapeHTML(chapter.title) + '</span>' +
      (chapter.locked ? '<span class="ab-lock">可能付费</span>' : '') +
      '</button>';
  }).join('') + (audiobookState.chapterHasMore
    ? '<button type="button" class="btn mini" id="ab-more-chapters">加载更多章节</button>'
    : '');
}

function renderAudiobookBody() {
  var body = document.getElementById('ab-body');
  if (!body) { return; }
  if (audiobookState.book) {
    body.innerHTML = '<div class="ab-text-pane">' +
      '<div class="ab-pane-head">' + escapeHTML(audiobookState.book.title) + '</div>' +
      abParagraphsHTML() + '</div>';
  } else {
    body.innerHTML = '<div class="ab-grid-pane">' + abListHeadHTML() +
      abBooksHTML(audiobookState.books) + '</div>';
  }
  Array.prototype.forEach.call(body.querySelectorAll('.ab-card'), function (button) {
    button.addEventListener('click', function () {
      abOpenBook(audiobookState.books[Number(button.getAttribute('data-index'))]);
    });
  });
  Array.prototype.forEach.call(body.querySelectorAll('.ab-cover-img'), function (image) {
    image.addEventListener('error', function () { image.style.display = 'none'; });
  });
  Array.prototype.forEach.call(body.querySelectorAll('.ab-category'), function (button) {
    button.addEventListener('click', function () {
      var index = Number(button.getAttribute('data-index'));
      abSelectCategory(index < 0 ? '' : (audiobookState.categories[index] || ''));
    });
  });
  abBindCategoryPanel(body);
  abRevealCategory();
  var prevPage = body.querySelector('#ab-prev-page');
  if (prevPage) {
    prevPage.addEventListener('click', function () {
      if (audiobookState.page > 1) { abLoadLibrary(audiobookState.page - 1); }
    });
  }
  var nextPage = body.querySelector('#ab-next-page');
  if (nextPage) {
    nextPage.addEventListener('click', function () {
      if (audiobookState.page < audiobookState.pageCount) { abLoadLibrary(audiobookState.page + 1); }
    });
  }
  Array.prototype.forEach.call(body.querySelectorAll('.ab-line'), function (line) {
    line.addEventListener('click', function () {
      var start = Number(line.getAttribute('data-start')) || 0;
      if (audiobookAudio) { audiobookAudio.currentTime = start; }
    });
  });
  // 句级跳转：点某一句直接跳到这一句的时间点（比整段更准）。
  Array.prototype.forEach.call(body.querySelectorAll('.ab-seg'), function (segment) {
    segment.addEventListener('click', function (event) {
      event.stopPropagation();
      var start = Number(segment.getAttribute('data-start')) || 0;
      if (audiobookAudio) { audiobookAudio.currentTime = start; }
    });
  });
}

function renderAudiobookPanel() {
  var panel = document.getElementById('ab-panel');
  if (!panel) { return; }
  if (!audiobookState.book) {
    panel.innerHTML = '<div class="live-group-head">榜单</div>' +
      '<div class="empty">选一本书开始听</div>';
    return;
  }
  panel.innerHTML = '<div class="live-group-head">目录' +
    '<button type="button" class="btn mini" id="ab-back">返回</button></div>' +
    '<div class="ab-chapters" id="ab-chapters">' + abChaptersHTML() + '</div>';
  var back = document.getElementById('ab-back');
  if (back) {
    back.addEventListener('click', function () {
      audiobookState.book = null;
      audiobookState.chapters = [];
      audiobookState.chapterIndex = -1;
      audiobookState.paragraphs = [];
      renderAudiobookView();
    });
  }
  Array.prototype.forEach.call(panel.querySelectorAll('.ab-chapter'), function (button) {
    button.addEventListener('click', function () {
      abPlayChapter(Number(button.getAttribute('data-index')));
    });
  });
  var more = document.getElementById('ab-more-chapters');
  if (more) { more.addEventListener('click', abLoadMoreChapters); }
}

function renderAudiobookPlayer() {
  var player = document.getElementById('ab-player');
  if (!player) { return; }
  var chapter = audiobookState.chapters[audiobookState.chapterIndex];
  if (!chapter) {
    player.innerHTML = '';
    return;
  }
  player.innerHTML =
    '<div class="ab-now">' +
      '<span class="ab-now-title">' + escapeHTML(chapter.title) + '</span>' +
      '<span class="ab-now-sub">' + escapeHTML(audiobookState.book ? audiobookState.book.title : '') + '</span>' +
    '</div>' +
    '<input id="ab-progress" class="ab-progress" type="range" min="0" max="0" step="1" value="0" />' +
    '<span class="ab-time" id="ab-time">0:00 / 0:00</span>' +
    '<button type="button" class="btn mini" id="ab-prev">上一章</button>' +
    '<button type="button" class="btn mini" id="ab-toggle">播放</button>' +
    '<button type="button" class="btn mini" id="ab-next">下一章</button>' +
    '<button type="button" class="btn mini" id="ab-rate">' + audiobookState.rate + 'x</button>' +
    '<button type="button" class="btn mini" id="ab-sleep">' + abSleepLabel() + '</button>';
  var toggle = document.getElementById('ab-toggle');
  if (toggle) {
    toggle.addEventListener('click', function () {
      var audio = audiobookAudio;
      if (!audio || !audio.src) { return; }
      if (audio.paused) { audio.play().catch(function () {}); } else { audio.pause(); }
    });
  }
  var prev = document.getElementById('ab-prev');
  if (prev) { prev.addEventListener('click', function () { abPlayChapter(audiobookState.chapterIndex - 1); }); }
  var next = document.getElementById('ab-next');
  if (next) { next.addEventListener('click', function () { abPlayChapter(audiobookState.chapterIndex + 1); }); }
  var rate = document.getElementById('ab-rate');
  if (rate) {
    rate.addEventListener('click', function () {
      var index = audiobookRates.indexOf(audiobookState.rate);
      audiobookState.rate = audiobookRates[(index + 1) % audiobookRates.length];
      if (audiobookAudio) { audiobookAudio.playbackRate = audiobookState.rate; }
      abSyncPlayer();
    });
  }
  var progress = document.getElementById('ab-progress');
  if (progress) {
    progress.addEventListener('change', function () {
      if (audiobookAudio) { audiobookAudio.currentTime = Number(progress.value) || 0; }
    });
  }
  var sleep = document.getElementById('ab-sleep');
  if (sleep) { sleep.addEventListener('click', abCycleSleep); }
  abSyncPlayer();
}

function renderAudiobookToolbar() {
  var toolbar = document.getElementById('ab-toolbar');
  if (!toolbar) { return; }
  var labels = ['听书榜', '女生听书'];
  var boards = audiobookBoards.map(function (board, index) {
    return '<button type="button" class="btn mini ab-board' +
      (index === audiobookState.board && !audiobookState.shelf ? ' active' : '') +
      '" data-index="' + index + '">' + escapeHTML(labels[index] || board.name) + '</button>';
  }).join('');
  toolbar.innerHTML =
    '<div class="ab-toolbar-row">' +
      '<button type="button" class="btn mini ab-shelf' +
        (audiobookState.shelf ? ' active' : '') + '" id="ab-shelf">书架</button>' +
      boards +
      '<form class="ab-search" id="ab-search-form">' +
        '<input id="ab-search-input" type="search" placeholder="搜索书名 / 作者" value="' +
          escapeHTML(audiobookState.query) + '" />' +
        '<button type="submit" class="btn mini">搜索</button>' +
      '</form>' +
    '</div>';
  Array.prototype.forEach.call(toolbar.querySelectorAll('.ab-board'), function (button) {
    button.addEventListener('click', function () {
      audiobookState.board = Number(button.getAttribute('data-index'));
      audiobookState.query = '';
      audiobookState.category = '';
      audiobookState.shelf = false;
      audiobookState.page = 1;
      abLoadBooks(1);
    });
  });
  var shelf = document.getElementById('ab-shelf');
  if (shelf) {
    shelf.addEventListener('click', function () {
      audiobookState.shelf = !audiobookState.shelf;
      // 让在途的书库请求与轮询作废，书架视图不与列表数据互相覆盖。
      ++audiobookState.libraryToken;
      if (audiobookState.shelf) {
        audiobookState.books = abShelf();
        audiobookState.hasMore = false;
        audiobookState.query = '';
        audiobookState.category = '';
        renderAudiobookToolbar();
        renderAudiobookBody();
      } else {
        abLoadBooks(1);
      }
    });
  }
  var form = document.getElementById('ab-search-form');
  if (form) {
    form.addEventListener('submit', function (event) {
      event.preventDefault();
      var input = document.getElementById('ab-search-input');
      var query = input ? input.value.trim() : '';
      audiobookState.query = query;
      audiobookState.category = '';
      audiobookState.shelf = false;
      audiobookState.page = 1;
      if (query) { abSearchBooks(1); } else { abLoadBooks(1); }
    });
  }
}

function renderAudiobookView() {
  view.innerHTML =
    '<div class="ab-wrap">' +
      '<div class="ab-toolbar" id="ab-toolbar"></div>' +
      '<div class="ab-columns">' +
        '<div class="ab-col ab-panel" id="ab-panel"></div>' +
        '<div class="ab-col ab-main" id="ab-body"></div>' +
      '</div>' +
      '<div class="ab-player" id="ab-player"></div>' +
    '</div>';
  renderAudiobookToolbar();
  renderAudiobookPanel();
  renderAudiobookPlayer();
  if (audiobookState.book) {
    renderAudiobookBody();
    return Promise.resolve();
  }
  return abLoadBooks(1);
}

// 榜单 / 分类 / 全库搜索统一走服务端全量书库：榜单 has_more 恒 false、
// 单页搜索结果稀疏，都不再作为翻页与搜索的依据。
function abLoadBooks(page) {
  audiobookState.query = '';
  audiobookState.category = '';
  audiobookState.book = null;
  audiobookState.chapters = [];
  audiobookState.chapterIndex = -1;
  // 清空搜索框里可能残留的上一次关键词，避免输入框与列表不一致。
  renderAudiobookToolbar();
  renderAudiobookPanel();
  renderAudiobookBody();
  return abLoadLibrary(page);
}

function abSearchBooks(page) {
  audiobookState.category = '';
  audiobookState.book = null;
  audiobookState.chapters = [];
  audiobookState.chapterIndex = -1;
  renderAudiobookPanel();
  renderAudiobookBody();
  return abLoadLibrary(page);
}

function abOpenBook(book) {
  if (!book) { return; }
  audiobookState.book = book;
  audiobookState.chapters = [];
  audiobookState.chapterIndex = -1;
  audiobookState.paragraphs = [];
  audiobookState.chapterPage = 1;
  audiobookState.chapterHasMore = false;
  abRememberBook(book);
  renderAudiobookPanel();
  renderAudiobookBody();
  abGet('chapters', { book: book.id, page: 1 })
    .then(function (data) {
      audiobookState.chapters = data.chapters || [];
      audiobookState.chapterHasMore = !!data.hasMore;
      renderAudiobookPanel();
    })
    .catch(function (error) {
      showNotice(error.message || '目录加载失败');
    });
}

function abLoadMoreChapters() {
  var book = audiobookState.book;
  if (!book || !audiobookState.chapterHasMore) { return; }
  var page = audiobookState.chapterPage + 1;
  abGet('chapters', { book: book.id, page: page })
    .then(function (data) {
      audiobookState.chapterPage = page;
      audiobookState.chapters = audiobookState.chapters.concat(data.chapters || []);
      audiobookState.chapterHasMore = !!data.hasMore;
      renderAudiobookPanel();
    })
    .catch(function (error) { showNotice(error.message || '目录加载失败'); });
}

function abPlayChapter(index) {
  var chapter = audiobookState.chapters[index];
  if (!chapter) {
    showNotice('已经是最后一章了');
    return;
  }
  // 标着「可能付费」的章节照样尝试播放：多数付费标记只影响正文，音频本身是
  // 可取的；真的取不到时再按接口返回的原因提示，不能在这里直接拦掉。
  var book = audiobookState.book;
  if (!book) { return; }
  audiobookState.chapterIndex = index;
  audiobookState.paragraphs = [];
  audiobookState.timed = false;
  audiobookState.duration = 0;
  audiobookState.textLoading = true;
  abStopAudio();
  renderAudiobookPanel();
  renderAudiobookPlayer();
  renderAudiobookBody();
  abGet('media', { book: book.id, chapter: chapter.id })
    .then(function (data) {
      audiobookState.duration = Number(data.duration) || 0;
      if (data.message) { showNotice(data.message); }
      var audio = abEnsureAudio();
      audio.playbackRate = audiobookState.rate;
      var target = data.url || '';
      var saved = abReadProgress(chapter.id);
      var applySaved = function () {
        if (saved > 0) {
          var limit = (audio.duration && isFinite(audio.duration)) ? audio.duration - 5 : Infinity;
          if (saved < limit) { audio.currentTime = saved; }
        }
      };
      audio.addEventListener('loadedmetadata', applySaved, { once: true });
      if (/\.m3u8(\?|$)/.test(target) && window.Hls && window.Hls.isSupported()) {
        audiobookHls = new window.Hls({ lowLatencyMode: false });
        audiobookHls.loadSource(target);
        audiobookHls.attachMedia(audio);
        audiobookHls.on(window.Hls.Events.MANIFEST_PARSED, function () {
          audio.play().catch(function () {});
        });
      } else {
        audio.src = target;
        audio.play().catch(function () {});
      }
      abLoadText(chapter.id);
    })
    .catch(function (error) {
      audiobookState.textLoading = false;
      renderAudiobookBody();
      showNotice(error.message || '取音频地址失败');
    });
}

function abLoadText(chapterId) {
  abGet('text', { chapter: chapterId })
    .then(function (data) {
      var rows = data.paragraphs || [];
      var duration = audiobookState.duration;
      var total = 0;
      rows.forEach(function (row) { total += (row.text || '').length || 1; });
      var cursor = 0;
      audiobookState.paragraphs = rows.map(function (row, index) {
        var text = row.text || '';
        var weight = text.length || 1;
        var span = duration > 0 ? duration * weight / total : 0;
        var start = (typeof row.start === 'number' && row.start >= 0) ? row.start : cursor;
        var end = index === rows.length - 1
          ? (duration > 0 ? duration : start + span)
          : start + span;
        cursor = end;
        var raw = Array.isArray(row.segments) ? row.segments : [];
        var segments = [];
        raw.forEach(function (part) {
          if (!part || typeof part.text !== 'string' || !part.text) { return; }
          if (typeof part.start !== 'number' || part.start < 0) { return; }
          segments.push({ text: part.text, start: part.start });
        });
        // 只要有一句缺时间戳，整段就退回按段高亮，避免高亮在句间乱跳。
        if (segments.length !== raw.length) { segments = []; }
        return { text: text, start: start, end: end, segments: segments };
      });
      audiobookState.timed = !!data.timed;
      audiobookState.textLoading = false;
      renderAudiobookBody();
    })
    .catch(function (error) {
      audiobookState.textLoading = false;
      audiobookState.paragraphs = [];
      renderAudiobookBody();
      showNotice(error.message || '正文加载失败');
    });
}

// 根据播放位置高亮当前段 / 当前句并滚动到可见区域（跟读用）。
function abActiveParagraph() {
  var list = audiobookState.paragraphs;
  var seconds = audiobookState.current;
  for (var index = 0; index < list.length; index++) {
    if (seconds < list[index].end || index === list.length - 1) { return index; }
  }
  return -1;
}

function abHighlightParagraph() {
  var pane = document.getElementById('ab-body');
  if (!pane) { return; }
  var seconds = audiobookState.current;
  var lines = pane.querySelectorAll('.ab-line');
  if (!lines.length) { return; }
  var active = abActiveParagraph();
  Array.prototype.forEach.call(lines, function (line, index) {
    line.classList.toggle('active', index === active);
  });
  Array.prototype.forEach.call(pane.querySelectorAll('.ab-seg.active'), function (node) {
    node.classList.remove('active');
  });
  var target = active >= 0 ? lines[active] : null;
  if (active >= 0 && lines[active]) {
    var spans = lines[active].querySelectorAll('.ab-seg');
    for (var index = 0; index < spans.length; index++) {
      var start = Number(spans[index].getAttribute('data-start')) || 0;
      var next = index + 1 < spans.length
        ? Number(spans[index + 1].getAttribute('data-start')) || start
        : Infinity;
      if (seconds >= start && seconds < next) {
        spans[index].classList.add('active');
        target = spans[index];
        break;
      }
    }
  }
  if (target) {
    var rect = target.getBoundingClientRect();
    var box = pane.getBoundingClientRect();
    if (rect.top < box.top || rect.bottom > box.bottom) {
      target.scrollIntoView({ block: 'center', behavior: 'smooth' });
    }
  }
}

function render() {
  cancelAutoNext();
  // 换路由就放弃还在跑的全部源搜索，别让它的轮询继续往页面上画结果。
  cancelCrossSearch();
  // 路由离开直播页时停掉直播播放器，避免后台继续拉流。
  if (location.hash.indexOf('#/live') !== 0 && (liveHlsInstance || liveFlvInstance || liveArtplayer)) {
    liveStopPlayer();
    liveReleaseArtplayer();
    liveState.playing = null;
  }
  // 离开听书页同样停掉音频，避免在别的页面继续出声。
  if (location.hash.indexOf('#/audiobook') !== 0 && (audiobookAudio || audiobookHls)) {
    abStopAudio();
  }
  var current = hashParams();
  var params = current.params;
  state.source = params.get('source') || state.source;
  state.query = params.get('q') || '';
  // 「全部源」是持久化勾选偏好（localStorage），不被 URL 参数反向覆盖，
  // 否则切源 / 翻页 / 换路由会把勾选态悄悄清掉。
  if (sourceSelect.value !== state.source) {
    sourceSelect.value = state.source;
  }
  if (searchInput.value !== state.query) {
    searchInput.value = state.query;
  }
  if (allSourcesInput) {
    allSourcesInput.checked = state.allSources;
  }
  var favoritesButton = document.getElementById('favorites-btn');
  if (favoritesButton) {
    favoritesButton.classList.toggle('active', current.path === 'favorites');
  }
  var customSourcesButton = document.getElementById('custom-sources-btn');
  if (customSourcesButton) {
    customSourcesButton.classList.toggle('active', current.path === 'custom-sources');
  }
  var modulesButton = document.getElementById('modules-btn');
  if (modulesButton) {
    modulesButton.classList.toggle('active', current.path === 'modules');
  }
  var jsSandboxButton = document.getElementById('js-sandbox-btn');
  if (jsSandboxButton) {
    jsSandboxButton.classList.toggle('active', current.path === 'js-sandbox');
  }
  var task;
  // #/drama 与 #/play 统一渲染融合观看页（播放器在上、选集居中、详情沉底）；
  // 旧链接 #/play 继续兼容，落到同一页并带上 index。
  if (current.path === 'drama') {
    task = renderWatch(params.get('id') || '', '', params.get('source') || '');
  } else if (current.path === 'play') {
    task = renderWatch(params.get('id') || '', Number(params.get('index') || 0), params.get('source') || '');
  } else if (current.path === 'favorites') {
    task = renderFavorites(params.get('tab') || '');
  } else if (current.path === 'custom-sources') {
    task = Promise.resolve().then(renderCustomSources);
  } else if (current.path === 'js-sandbox') {
    task = Promise.resolve().then(function () {
      return JsSandbox.render(view);
    });
  } else if (current.path === 'modules') {
    task = Promise.resolve().then(renderModules);
  } else if (current.path === 'live') {
    task = Promise.resolve().then(renderLiveView);
  } else if (current.path === 'audiobook') {
    task = Promise.resolve().then(renderAudiobookView);
  } else if (current.path === 'netdisk') {
    task = Promise.resolve().then(renderNetdiskView);
  } else {
    state.category = params.get('category') || '';
    state.page = Number(params.get('page') || 1);
    task = state.allSources && state.query ? renderCrossSearch() : renderCatalog();
  }
  var liveButton = document.getElementById('live-btn');
  if (liveButton) {
    liveButton.classList.toggle('active', current.path === 'live');
  }
  var audiobookButton = document.getElementById('audiobook-btn');
  if (audiobookButton) {
    audiobookButton.classList.toggle('active', current.path === 'audiobook');
  }
  var netdiskButton = document.getElementById('netdisk-btn');
  if (netdiskButton) {
    netdiskButton.classList.toggle('active', current.path === 'netdisk');
  }
  task.catch(function (error) {
    var message = error.message || '加载失败';
    view.innerHTML = '<div class="empty">' + escapeHTML(message) + '</div>' +
      selfHealHTML(message, state.source || '');
    bindSelfHeal();
  });
}

// 顶栏「清理缓存」：调用核心统计/清理，删除播放与转码临时文件。
// 本地服务版没有「我的 → 设置」分组，入口直接放在顶栏。
function readableCacheSize(bytes) {
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
  if (bytes < 1024 * 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
  return (bytes / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
}

(function bindClearCacheButton() {
  var button = document.getElementById('clear-cache-btn');
  if (!button) return;
  button.addEventListener('click', function (event) {
    event.preventDefault();
    if (button.disabled) return;
    button.disabled = true;
    api({ action: 'cacheInfo' })
      .then(function (info) {
        var bytes = Number(info.bytes || 0);
        if (!bytes) {
          window.alert('没有需要清理的缓存');
          return null;
        }
        if (!window.confirm(
          '发现 ' + readableCacheSize(bytes) + ' 可清理缓存（播放、封面、目录、日志与转码临时文件）。\n' +
          '已下载视频、听书离线音频、剧库和设置不会受影响，是否清理？'
        )) {
          return null;
        }
        return api({ action: 'clearCache' }).then(function (result) {
          var cleared = Number(result.clearedBytes || 0);
          var message = cleared > 0 ? '已释放 ' + readableCacheSize(cleared) : '没有文件被删除';
          if (result.warning) message += '\n' + result.warning;
          window.alert(message);
        });
      })
      .catch(function (error) {
        window.alert('清理缓存失败：' + (error.message || error));
      })
      .then(function () {
        button.disabled = false;
      });
  });
})();

sourceSelect.addEventListener('change', function () {
  state.source = sourceSelect.value;
  state.category = '';
  state.page = 1;
  state.query = '';
  state.categories = [];
  location.hash = hashFor({});
});

searchForm.addEventListener('submit', function (event) {
  event.preventDefault();
  state.query = searchInput.value.trim();
  state.page = 1;
  state.category = '';
  location.hash = hashFor({});
});

// 「全部源」勾选不再触发整页重渲染（之前 change 时重写 hash 会走一次
// hashchange → render() 全量刷新，表现为点一下就闪一下）。
// 勾选态只更新 state 并记到本地；提交搜索时由 hashFor 把 cross=1 写进 hash。
if (allSourcesInput) {
  allSourcesInput.addEventListener('change', function () {
    state.allSources = allSourcesInput.checked;
    writeAllSources(allSourcesInput.checked);
  });
}

// 「选源」：逐源勾选参与搜索的站源，与 App 端搜索页的站源勾选条一致。
var pickSourcesButton = document.getElementById('pick-sources-btn');
if (pickSourcesButton) {
  pickSourcesButton.addEventListener('click', function (event) {
    event.preventDefault();
    pickSources().catch(function (error) {
      window.alert(error.message || '读取站源失败');
    });
  });
}

window.addEventListener('hashchange', function () {
  // 就地换集时只改了地址栏（syncEpisodeChrome 会置位 suppressHashRender），
  // 这时不能再整页重建，否则刚复用的 <video> 会被销毁、倍速与全屏都丢。
  if (suppressHashRender) {
    suppressHashRender = false;
    return;
  }
  var current = hashParams();
  // 融合后 #/drama 与 #/play 是同一个观看页：离开这两者才停播放；
  // 只在观看页之间换集时回到默认线路，画质沿用上次的选择。
  if (current.path !== 'drama' && current.path !== 'play') {
    stopPlayback();
  } else if (Number(current.params.get('index') || 0) !== state.index) {
    state.route = 0;
  }
  render();
});

// 关闭页面时用 sendBeacon 补一次进度，普通 fetch 在页面卸载时来不及发出。
window.addEventListener('beforeunload', function () {
  if (!state.drama || !navigator.sendBeacon) {
    return;
  }
  var video = document.getElementById('player');
  if (!video || !(Number(video.currentTime) > 0)) {
    return;
  }
  var body = JSON.stringify({
    list: 'history',
    op: 'put',
    item: currentEntry(Number(video.currentTime) || 0, Number(video.duration) || 0),
  });
  navigator.sendBeacon('/api/library', new Blob([body], { type: 'application/json' }));
});

loadInfo();
Promise.all([loadSources(), loadLibrary()]).then(function () {
  if (!location.hash) {
    location.hash = hashFor({});
  } else {
    render();
  }
});

// ---- 网盘与订阅（夸克登录 / 分享直解 / TVBox 订阅）----
//
// 本地服务版没有原生 WebView，登录态与订阅都走核心的 netdisk* / tvbox* 动作；
// 扫码二维码由核心直接生成 base64 PNG，前端只负责展示与轮询。

// netdiskPost 调用 /api/netdisk/<path>。
//
// 服务端从 URL query 读参数（不是 JSON body），所以这里把参数拼进查询串，
// 否则 provider / cookie 传不过去，登录与清理都会落到默认的夸克上。
function netdiskPost(path, params) {
  var search = [];
  Object.keys(params || {}).forEach(function (key) {
    var value = params[key];
    if (value === undefined || value === null || value === '') return;
    search.push(encodeURIComponent(key) + '=' + encodeURIComponent(value));
  });
  var url = '/api/netdisk/' + path + (search.length ? '?' + search.join('&') : '');
  return fetch(url, { method: 'POST' })
    .then(function (response) { return response.json(); })
    .then(function (data) {
      if (!data.ok) throw new Error(data.error || '网盘请求失败');
      return data.data;
    });
}

function tvboxPost(path) {
  return fetch('/api/tvbox/' + path, { method: 'POST' })
    .then(function (response) { return response.json(); })
    .then(function (data) {
      if (!data.ok) throw new Error(data.error || '订阅请求失败');
      return data.data;
    });
}

var netdiskState = {
  ready: {},
  tvboxUrl: '',
  episodes: [],
  shareUrl: '',
};

// 界面上的网盘列表：与 App 端一致，夸克与 UC 各自一行。
var NETDISK_PROVIDERS = [
  { id: 'quark', name: '夸克网盘', host: 'pan.quark.cn' },
  { id: 'uc', name: 'UC 网盘', host: 'drive.uc.cn' },
];

function renderNetdiskView() {
  return Promise.all([
    fetch('/api/netdisk/status', { method: 'POST' })
      .then(function (r) { return r.json(); })
      .then(function (d) { return d.ok ? d.data : {}; })
      .catch(function () { return {}; }),
    fetch('/api/tvbox/status', { method: 'POST' })
      .then(function (r) { return r.json(); })
      .then(function (d) { return d.ok ? d.data : {}; })
      .catch(function () { return {}; }),
  ]).then(function (results) {
    var status = results[0] || {};
    var tvbox = results[1] || {};
    netdiskState.ready = status.ready || {};
    if (tvbox.url) netdiskState.tvboxUrl = tvbox.url;
    paintNetdisk(tvbox);
  });
}

// netdiskAccountHTML 渲染单个网盘的一行：登录态 + 扫码 / Cookie / 退出 / 清理。
function netdiskAccountHTML(provider) {
  var ready = netdiskState.ready[provider.id] === true;
  var actions = ready
    ? '<button type="button" class="btn" data-netdisk-logout="' + provider.id + '">退出登录</button>' +
      '<button type="button" class="btn" data-netdisk-cleanup="' + provider.id + '">清理临时目录</button>'
    : '<button type="button" class="btn primary" data-netdisk-login="' + provider.id + '">扫码登录</button>' +
      '<button type="button" class="btn" data-netdisk-cookie="' + provider.id + '">Cookie 登录</button>';
  return '<div class="netdisk-account">' +
    '<span class="' + (ready ? 'dot on' : 'dot') + '"></span>' +
    '<span>' + escapeHTML(provider.name) + (ready ? '已登录' : '未登录') + '</span>' +
    actions +
    '</div>';
}

function paintNetdisk(tvbox) {
  tvbox = tvbox || {};
  var supported = Number(tvbox.supportedCount) || 0;
  var skipped = Number(tvbox.skippedCount) || 0;
  var summary = tvbox.url
    ? '已加载 ' + supported + ' 个站源' + (skipped > 0 ? '，跳过 ' + skipped + ' 个不支持的' : '')
    : '未订阅饭太硬 / TVBox 接口';
  var episodeRows = '';
  netdiskState.episodes.forEach(function (ep, index) {
    episodeRows += '<div class="netdisk-row" data-index="' + index + '">' +
      '<span class="netdisk-index">' + (index + 1) + '</span>' +
      '<span class="netdisk-name">' + escapeHTML(ep.name || '') + '</span>' +
      '<button type="button" class="btn netdisk-play">播放</button>' +
      '</div>';
  });
  var accounts = NETDISK_PROVIDERS.map(netdiskAccountHTML).join('');
  view.innerHTML =
    '<section class="panel">' +
      '<h2>网盘账号</h2>' +
      accounts +
      '<div id="netdisk-qr" class="netdisk-qr"></div>' +
    '</section>' +
    '<section class="panel">' +
      '<h2>饭太硬 / TVBox 接口订阅</h2>' +
      '<div class="netdisk-summary">' + escapeHTML(summary) + '</div>' +
      '<div class="netdisk-form">' +
        '<input type="url" id="tvbox-url" placeholder="输入订阅 JSON 地址 (http/https)" value="' +
          escapeHTML(netdiskState.tvboxUrl || '') + '" />' +
        '<button type="button" class="btn primary" id="tvbox-subscribe">同步</button>' +
        (tvbox.url ? '<button type="button" class="btn" id="tvbox-clear">清除订阅</button>' : '') +
      '</div>' +
    '</section>' +
    '<section class="panel">' +
      '<h2>网盘分享链接直解</h2>' +
      '<div class="netdisk-form">' +
        '<input type="url" id="netdisk-share" placeholder="粘贴夸克 / UC 分享链接（https://pan.quark.cn/s/xxxx 或 https://drive.uc.cn/s/xxxx）" />' +
        '<button type="button" class="btn primary" id="netdisk-open">打开详情播放</button>' +
        '<button type="button" class="btn" id="netdisk-parse">解析文件列表</button>' +
      '</div>' +
      '<div class="netdisk-list">' + (episodeRows || '<div class="empty">解析后显示可播放的文件</div>') + '</div>' +
    '</section>';
  bindNetdisk();
}

function bindNetdisk() {
  // 每个网盘各自的登录 / 退出 / 清理按钮用 data 属性标记，避免为两种网盘
  // 复制一份 id 绑定逻辑。
  Array.prototype.forEach.call(
    document.querySelectorAll('[data-netdisk-login]'),
    function (button) {
      button.addEventListener('click', function () {
        var provider = button.getAttribute('data-netdisk-login');
        netdiskPost('login', { provider: provider }).then(function (state) {
          showQr(state);
        }).catch(function (error) {
          alert(error.message);
        });
      });
    }
  );
  Array.prototype.forEach.call(
    document.querySelectorAll('[data-netdisk-cookie]'),
    function (button) {
      button.addEventListener('click', function () {
        var provider = button.getAttribute('data-netdisk-cookie');
        var name = provider === 'uc' ? 'UC 网盘' : '夸克网盘';
        var cookie = window.prompt(
          '在浏览器登录 ' + name + ' 后，从开发者工具复制整段 Cookie 粘贴到这里：',
          ''
        );
        if (!cookie) return;
        netdiskPost('loginCookie', { provider: provider, cookie: cookie.trim() })
          .then(function () { return renderNetdiskView(); })
          .then(function () { alert(name + ' 登录成功'); })
          .catch(function (error) { alert(error.message); });
      });
    }
  );
  Array.prototype.forEach.call(
    document.querySelectorAll('[data-netdisk-logout]'),
    function (button) {
      button.addEventListener('click', function () {
        var provider = button.getAttribute('data-netdisk-logout');
        netdiskPost('logout', { provider: provider }).then(function () {
          return renderNetdiskView();
        });
      });
    }
  );
  Array.prototype.forEach.call(
    document.querySelectorAll('[data-netdisk-cleanup]'),
    function (button) {
      button.addEventListener('click', function () {
        var provider = button.getAttribute('data-netdisk-cleanup');
        netdiskPost('cleanup', { provider: provider }).then(function (res) {
          alert('已清理 ' + (Number(res.deleted) || 0) + ' 个临时转存文件');
        }).catch(function (error) {
          alert(error.message);
        });
      });
    }
  );
  var subscribe = document.getElementById('tvbox-subscribe');
  if (subscribe) {
    subscribe.addEventListener('click', function () {
      var input = document.getElementById('tvbox-url');
      var url = (input && input.value || '').trim();
      if (!url) {
        alert('请先填写订阅地址');
        return;
      }
      subscribe.disabled = true;
      subscribe.textContent = '同步中…';
      fetch('/api/tvbox/subscribe?url=' + encodeURIComponent(url), { method: 'POST' })
        .then(function (r) { return r.json(); })
        .then(function (data) {
          if (!data.ok) throw new Error(data.error || '订阅失败');
          netdiskState.tvboxUrl = url;
          paintNetdisk(data.data);
          loadSources();
        })
        .catch(function (error) {
          alert(error.message);
          subscribe.disabled = false;
          subscribe.textContent = '同步';
        });
    });
  }
  var clear = document.getElementById('tvbox-clear');
  if (clear) {
    clear.addEventListener('click', function () {
      fetch('/api/tvbox/clear', { method: 'POST' })
        .then(function (r) { return r.json(); })
        .then(function () {
          netdiskState.tvboxUrl = '';
          return renderNetdiskView();
        })
        .then(function () { loadSources(); });
    });
  }
  var parse = document.getElementById('netdisk-parse');
  if (parse) {
    parse.addEventListener('click', function () {
      var input = document.getElementById('netdisk-share');
      var url = (input && input.value || '').trim();
      if (!url) {
        alert('请先粘贴分享链接');
        return;
      }
      netdiskState.shareUrl = url;
      netdiskPost('share', { url: url }).then(function (data) {
        netdiskState.episodes = data.episodes || [];
        paintNetdisk({ url: netdiskState.tvboxUrl });
      }).catch(function (error) {
        alert(error.message);
      });
    });
  }
  var open = document.getElementById('netdisk-open');
  if (open) {
    open.addEventListener('click', function () {
      var input = document.getElementById('netdisk-share');
      var url = (input && input.value || '').trim();
      if (!url) {
        alert('请先粘贴分享链接');
        return;
      }
      netdiskPost('openShare', { url: url }).then(function (data) {
        var drama = data.drama || {};
        if (drama.id) {
          location.hash = episodeHash(drama.id, drama.source || 'netdisk', 0);
        }
      }).catch(function (error) {
        alert(error.message);
      });
    });
  }
  Array.prototype.forEach.call(view.querySelectorAll('.netdisk-row'), function (row) {
    row.querySelector('.netdisk-play').addEventListener('click', function () {
      var index = Number(row.dataset.index) || 0;
      netdiskPost('play', { url: netdiskState.shareUrl, index: index }).then(function (data) {
        if (data.url) {
          window.open(data.url, '_blank');
        }
      }).catch(function (error) {
        alert(error.message);
      });
    });
  });
}

function showQr(state) {
  var box = document.getElementById('netdisk-qr');
  if (!box || !state.qrBase64) return;
  box.innerHTML = '<img alt="登录二维码" src="data:image/png;base64,' + state.qrBase64 + '" />' +
    '<div class="netdisk-hint">用夸克 App 扫码并确认登录</div>';
  var timer = setInterval(function () {
    netdiskPost('loginPoll', { session: state.id }).then(function (next) {
      var status = next.status || '';
      if (status === 'done') {
        clearInterval(timer);
        box.innerHTML = '';
        renderNetdiskView();
        return;
      }
      if (status === 'expired' || status === 'error') {
        clearInterval(timer);
        var hint = box.querySelector('.netdisk-hint');
        if (hint) hint.textContent = next.message || '登录失败，请重试';
      }
    }).catch(function () {
      // 轮询失败不打断，下一轮继续。
    });
  }, 3000);
}

// ---- 出错时的「一键自愈」引导 ----
//
// 与 App 端一致：按失败原因给出人机验证 / 青空登录 / 网络代理入口。
// 本地服务版没有原生 WebView，人机验证改为在浏览器新标签页完成，完成后把
// Cookie 与 UA 交回核心（受浏览器同源策略限制，提示用户复制粘贴）。
function selfHealHTML(message, source) {
  var lower = String(message || '').toLowerCase();
  var buttons = [];
  if (lower.indexOf('cf_challenge') >= 0 || lower.indexOf('cloudflare') >= 0 ||
      lower.indexOf('just a moment') >= 0 || message.indexOf('人机验证') >= 0) {
    buttons.push('<button type="button" class="btn" data-heal="challenge" data-source="' +
      escapeHTML(source || '') + '">完成人机验证</button>');
  }
  if (lower.indexOf('登录') >= 0 || lower.indexOf('login') >= 0 || lower.indexOf('未授权') >= 0) {
    buttons.push('<button type="button" class="btn" data-heal="login">登录青空账号</button>');
  }
  if (lower.indexOf('超时') >= 0 || lower.indexOf('timeout') >= 0 || lower.indexOf('网络') >= 0 ||
      lower.indexOf('连接') >= 0 || lower.indexOf('connection') >= 0 || lower.indexOf('失败') >= 0) {
    buttons.push('<button type="button" class="btn" data-heal="proxy">设置网络代理</button>');
  }
  if (!buttons.length) return '';
  return '<div class="self-heal">' + buttons.join('') + '</div>';
}

function bindSelfHeal() {
  Array.prototype.forEach.call(view.querySelectorAll('[data-heal]'), function (button) {
    button.addEventListener('click', function () {
      var kind = button.dataset.heal;
      if (kind === 'challenge') {
        var source = button.dataset.source || '';
        fetch('/api/webview/challenge?source=' + encodeURIComponent(source), { method: 'POST' })
          .then(function (r) { return r.json(); })
          .then(function (data) {
            var url = data.ok && data.data && data.data.url;
            if (!url) {
              alert('该站源没有可用的验证地址');
              return;
            }
            window.open(url, '_blank');
            alert('已在新标签页打开验证页。完成验证后回到本页点击「重试」。');
          });
      } else if (kind === 'login') {
        alert('青空账号登录请在「自定义源」里配置，或联系管理员开放权限。');
      } else if (kind === 'proxy') {
        alert('网络代理请在系统或启动参数里配置；本地服务版暂不支持页内代理设置。');
      }
    });
  });
}
