/*
 * 红果短剧（网页版）——CatPawOpen / CatVodOpen 数据源
 *
 * 只走 hongguoduanju.com 的公开网页数据，不涉及 App 接口，因此不需要
 * 任何签名参数，导入即可用：
 *   分类页  /category/{route}?page=n   → _ROUTER_DATA.loaderData.*.recommendList
 *   详情页  /detail?series_id=xxx      → seriesDetail.vid_list
 *   播放页  /player/{sid}/{vid}        → POST /api/video/protected/play-info
 *
 * 已知限制（两条都绕不过去，与实现无关）：
 * 1. 播放接口返回的 video / audio 分轨是 CENC 加密的（mp4 里有 encv/enca
 *    与 tenc box），密钥由播放器 SDK 用 player_access_key 派生，没有它解
 *    不出来，所以这个源只用于浏览，play 会明确报 DRM_PROTECTED；
 * 2. 网页搜索是客户端渲染、接口带 msToken/a_bogus 风控签名，这里不实现，
 *    search 返回空（界面按「该源不支持搜索」处理）。
 */

const BASE_URL = 'https://hongguoduanju.com';
const UA =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
const AID = '8662';

const meta = {
  id: 'hongguoweb',
  name: '红果短剧（网页）',
  version: '1.0.0',
  description: '走红果网页公开数据，无需签名参数；可浏览分类与详情，播放受 DRM 限制',
  author: 'guoapp',
  type: 'video',
  features: ['categories', 'recommendations'],
};

// 一级分类 + 真人剧题材。slug 取自站点分类页的 tab 链接。
const CATEGORIES = [
  ['real-drama', '真人剧'],
  ['real-drama/romance', '爱情'],
  ['real-drama/comeback', '逆袭'],
  ['real-drama/urban', '都市'],
  ['real-drama/period', '年代'],
  ['real-drama/legend', '传奇'],
  ['real-drama/costume', '古装'],
  ['real-drama/family', '家庭'],
  ['real-drama/clan', '家族'],
  ['real-drama/cute-kids', '萌宝'],
  ['real-drama/growth', '成长'],
  ['real-drama/youth', '青春'],
  ['real-drama/comedy', '喜剧'],
  ['real-drama/drama', '剧情'],
  ['real-drama/suspense', '悬疑'],
  ['real-drama/thriller', '惊悚'],
  ['real-drama/horror', '恐怖'],
  ['real-drama/fantasy', '奇幻'],
  ['real-drama/supernatural', '超自然'],
  ['real-drama/sci-fi', '科幻'],
  ['real-drama/wonder', '奇遇'],
  ['real-drama/war', '战争'],
  ['real-drama/disaster', '灾难'],
  ['real-drama/variety', '综艺'],
  ['comic-drama', '漫剧'],
  ['ai-drama', 'AI 剧'],
];

// ------------------------------------------------------------------ 工具

function text(value) {
  return String(value === undefined || value === null ? '' : value)
    .replace(/\s+/g, ' ')
    .trim();
}

function number(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function digits(value) {
  const matched = String(value || '').match(/\d{5,}/);
  return matched ? matched[0] : '';
}

function coverUrl(raw) {
  const value = text(raw);
  if (!value) return '';
  if (value.indexOf('//') === 0) return 'https:' + value;
  return /^https?:\/\//i.test(value) ? value : '';
}

async function getPage(path) {
  const response = await fetch(BASE_URL + path, {
    headers: { 'User-Agent': UA, Referer: BASE_URL + '/' },
    timeoutMs: 20000,
  });
  const body =
    typeof response.text === 'function' ? await response.text() : response.body;
  if (!body) throw new Error('红果网页返回空正文');
  return body;
}

/**
 * 页面里的 `_ROUTER_DATA = {...}` 是 SSR 数据。JSON 后面还跟着别的脚本，
 * 不能靠正则截到 `</script>`，这里做一次括号配对（跳过字符串里的括号）。
 */
function routerData(body) {
  const marker = body.indexOf('_ROUTER_DATA');
  if (marker < 0) throw new Error('页面结构已变化：找不到内嵌数据');
  const start = body.indexOf('{', marker);
  if (start < 0) throw new Error('页面结构已变化：内嵌数据为空');

  let depth = 0;
  let inString = false;
  let escaped = false;
  let end = -1;
  for (let i = start; i < body.length; i += 1) {
    const ch = body[i];
    if (inString) {
      if (escaped) escaped = false;
      else if (ch === '\\') escaped = true;
      else if (ch === '"') inString = false;
      continue;
    }
    if (ch === '"') inString = true;
    else if (ch === '{') depth += 1;
    else if (ch === '}') {
      depth -= 1;
      if (depth === 0) {
        end = i + 1;
        break;
      }
    }
  }
  if (end < 0) throw new Error('页面结构已变化：内嵌数据不完整');
  try {
    return JSON.parse(body.slice(start, end));
  } catch (error) {
    throw new Error('页面数据解析失败');
  }
}

/** loaderData 里挑出带列表的那一段（分类页叫 category_$，详情页叫 detail_page）。 */
function loaderOf(data, key) {
  const loader = (data && data.loaderData) || {};
  for (const name of Object.keys(loader)) {
    const value = loader[name];
    if (!value || typeof value !== 'object') continue;
    if (key && value[key]) return value;
    if (!key && Array.isArray(value.recommendList)) return value;
  }
  return null;
}

function toVod(item, route) {
  const id = text(item.series_id);
  const tags = Array.isArray(item.tags) ? item.tags.filter(Boolean) : [];
  return {
    vod_id: id,
    vod_name: text(item.series_name),
    vod_pic: coverUrl(item.series_cover),
    vod_content: text(item.series_intro),
    vod_remarks: text(item.episode_right_text || ('全' + number(item.episode_cnt) + '集')),
    vod_tag: tags.join(','),
    vod_episodes: number(item.episode_cnt),
    vod_category: text(route),
  };
}

// ------------------------------------------------------------------ 协议

async function home() {
  return {
    class: CATEGORIES.map(function (row) {
      return { type_id: row[0], type_name: row[1] };
    }),
    filters: {},
  };
}

async function category(tid, pg) {
  const page = number(pg) > 0 ? number(pg) : 1;
  const route = text(tid) || 'real-drama';
  const suffix = page > 1 ? '?page=' + page : '';
  const data = routerData(await getPage('/category/' + route + suffix));
  const section = loaderOf(data, 'recommendList');
  const rows = (section && section.recommendList) || [];
  const pagination = (section && section.pagination) || {};
  const totalPages = number(pagination.totalPages) || page;
  return {
    page: page,
    pagecount: totalPages,
    limit: 24,
    total: number(pagination.total),
    list: rows.map(function (item) {
      return toVod(item, route);
    }),
    hasMore: page < totalPages,
  };
}

async function detail(id) {
  const sid = digits(id);
  if (!sid) return { list: [] };

  const data = routerData(await getPage('/detail?series_id=' + sid));
  const section = loaderOf(data, 'seriesDetail');
  const info = (section && section.seriesDetail) || {};
  const vids = (Array.isArray(info.vid_list) ? info.vid_list : [])
    .map(function (item) {
      return text(item);
    })
    .filter(Boolean);

  // 兜底：整页正则捞一次 vid_list，防止以后 seriesDetail 改名。
  if (!vids.length) {
    const matched = /vid_list[^:]*:\s*\[([^\]]*)\]/.exec(
      JSON.stringify(data),
    );
    if (matched) {
      for (const item of matched[1].match(/\d{15,}/g) || []) vids.push(item);
    }
  }

  const episodes = [];
  for (let i = 0; i < vids.length; i += 1) {
    episodes.push('第' + (i + 1) + '集$' + sid + '_' + vids[i]);
  }
  if (!episodes.length) {
    // 没有分集表时至少给出第 1 集的播放页，取流时按 vid 再解析。
    episodes.push('第1集$' + sid + '_' + sid);
  }

  return {
    list: [
      {
        vod_id: sid,
        vod_name: text(info.series_name) || '短剧 ' + sid,
        vod_pic: coverUrl(info.series_cover),
        vod_content: text(info.series_intro),
        vod_remarks: text(info.episode_right_text || ('全' + episodes.length + '集')),
        vod_tag: (Array.isArray(info.tags) ? info.tags : []).join(','),
        vod_play_from: '红果网页',
        vod_play_url: episodes.join('#'),
      },
    ],
  };
}

async function search() {
  // 网页搜索走 /api/search/result，带 msToken / a_bogus 风控签名，这里不做。
  return [];
}

// ------------------------------------------------------------------ 播放

function playInfoError(code) {
  const error = new Error(code);
  error.code = code;
  return error;
}

async function playInfo(sid, vid, definition) {
  const response = await fetch(
    BASE_URL + '/api/video/protected/play-info?aid=' + AID,
    {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'User-Agent': UA,
        Referer: BASE_URL + '/player/' + sid + '/' + vid,
      },
      body: JSON.stringify({
        series_id: sid,
        item_id: vid,
        definition: definition,
      }),
      timeoutMs: 20000,
    },
  );
  const body =
    typeof response.text === 'function' ? await response.text() : response.body;
  let parsed = null;
  try {
    parsed = JSON.parse(body || '{}');
  } catch (error) {
    throw playInfoError('INVALID_RESPONSE');
  }
  const info = parsed && parsed.play_info;
  if (!info || !info.main_url) throw playInfoError('MISSING_MODEL');
  return info;
}

/** fMP4 分轨 → DASH 清单（SegmentBase + indexRange，静态文件整段就是一个 segment）。 */
function buildMpd(info) {
  const duration = number(info.duration) || 0;
  const width = number(info.width) || 720;
  const height = number(info.height) || 1280;
  const videoCodec =
    height <= 720 ? 'avc1.64001f' : height <= 1080 ? 'avc1.640028' : 'avc1.640032';
  const audio = info.audio || {};
  const videoBandwidth = Math.max(1, Math.round(number(info.bitrate)));
  const audioBandwidth = Math.max(1, Math.round(number(audio.bitrate)));

  const video =
    '<AdaptationSet id="1" contentType="video" mimeType="video/mp4" ' +
    'segmentAlignment="true" startWithSAP="1">' +
    '<Representation id="v1" bandwidth="' + videoBandwidth + '" codecs="' +
    videoCodec + '" width="' + width + '" height="' + height + '">' +
    '<BaseURL>' + info.main_url + '</BaseURL>' +
    '<SegmentBase indexRange="' + (info.index_range || '') + '">' +
    '<Initialization range="' + (info.init_range || '') + '"/>' +
    '</SegmentBase></Representation></AdaptationSet>';

  const audioTrack = audio.main_url
    ? '<AdaptationSet id="2" contentType="audio" mimeType="audio/mp4" ' +
      'segmentAlignment="true">' +
      '<Representation id="a1" bandwidth="' + audioBandwidth + '" ' +
      'codecs="mp4a.40.2">' +
      '<BaseURL>' + audio.main_url + '</BaseURL>' +
      '<SegmentBase indexRange="' + (audio.index_range || '') + '">' +
      '<Initialization range="' + (audio.init_range || '') + '"/>' +
      '</SegmentBase></Representation></AdaptationSet>'
    : '';

  return (
    '<?xml version="1.0" encoding="UTF-8"?>' +
    '<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" ' +
    'profiles="urn:mpeg:dash:profile:isoff-on-demand:2011" type="static" ' +
    'mediaPresentationDuration="PT' + duration + 'S" minBufferTime="PT2S">' +
    '<Period id="1" start="PT0S">' + video + audioTrack + '</Period></MPD>'
  );
}

function base64(value) {
  const utf8 = unescape(encodeURIComponent(value));
  return btoa(utf8);
}

/** 解析分集 target：`{sid}_{vid}`、播放页地址、或裸 vid。 */
function parseTarget(id, flags) {
  const raw = text(id).replace(/^hongguo(web)?:/, '');
  let matched = /\/player\/(\d{10,})\/(\d{10,})/.exec(raw);
  if (matched) return { sid: matched[1], vid: matched[2] };

  matched = /^(\d{10,})[_-](\d{10,})$/.exec(raw);
  if (matched) return { sid: matched[1], vid: matched[2] };

  const seriesId = text(
    (Array.isArray(flags) ? flags : []).reduce(function (found, item) {
      return found || (item && typeof item === 'object' && item.seriesId) || '';
    }, ''),
  );
  if (/^\d{10,}$/.test(raw) && /^\d{10,}$/.test(seriesId)) {
    return { sid: seriesId, vid: raw };
  }
  return { sid: '', vid: '' };
}

async function play(flag, id, flags) {
  // 分集编号里带着 series / vid，说明详情链路是通的；但片源是 CENC 加密的，
  // 没有播放器密钥解不出来，这里如实告诉用户原因，不再继续取流。
  const target = parseTarget(id, flags);
  if (!target.sid) {
    return { parse: 0, url: '', header: {}, error: 'MISSING_EPISODE' };
  }
  return { parse: 0, url: '', header: {}, error: 'DRM_PROTECTED' };
}

var spider = {
  meta: meta,
  init: function () {},
  home: home,
  category: category,
  detail: detail,
  play: play,
  search: search,
  suggestions: async function () {
    return [];
  },
};

if (typeof module !== 'undefined' && module.exports) {
  module.exports = spider;
}
