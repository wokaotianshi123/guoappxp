'use strict';

// JS 沙箱 Worker（本地服务版）。
//
// 浏览器本身就是 JS 引擎，脚本直接在 Worker 里跑，主线程只负责三件事：
// 把 fetch 转给服务端代发、把保存下来的游客设备号传进来、把脚本抛的错显示出来。
// 与 Flutter 端 catpaw_js_runtime.dart 的 shim 保持同一套语义：
//   - fetch 返回 {status, ok, headers, text(), json()}；
//   - 脚本抛错时把 message / code 原样带回；
//   - html.parse 提供 find/text/attr 三个最小能力。

var spider = null;
var fetchSeq = 0;
var fetchWaiters = new Map();
var evalSeq = 0;

var DEVICE_KEY = 'duoapp:jsSandbox:device';

self.onmessage = function (event) {
  var data = event.data || {};
  switch (data.type) {
    case 'init':
      boot(data.script || '', data.device || '');
      break;
    case 'call':
      invoke(data.id, data.method || '', data.args || []);
      break;
    case 'fetchResult':
      settleFetch(data);
      break;
  }
};

function post(message) {
  self.postMessage(message);
}

function bootFail(message) {
  post({ type: 'ready', ok: false, error: message });
}

function boot(script, device) {
  try {
    installConsole();
    installHtml();
    installFetch();
    installDevice(device);
    if (!script.trim()) {
      bootFail('脚本内容为空');
      return;
    }
    // 用 Function 包一层：脚本里的 const / var 留在函数作用域，
    // 不会和本文件自己的变量撞名，也能拿到闭包里的 spider。
    var factory = new Function(
      script +
        '\n;return (typeof spider !== "undefined" && spider) || ' +
        '(typeof module !== "undefined" && module.exports) || null;',
    );
    spider = factory();
    if (!spider || typeof spider !== 'object') {
      bootFail('脚本没有导出 spider 对象');
      return;
    }
    post({
      type: 'ready',
      ok: true,
      meta: safeMeta(spider.meta),
    });
  } catch (error) {
    bootFail(error && error.message ? error.message : String(error));
  }
}

function safeMeta(meta) {
  if (!meta || typeof meta !== 'object') return {};
  return {
    id: meta.id ? String(meta.id) : '',
    name: meta.name ? String(meta.name) : '',
    version: meta.version ? String(meta.version) : '',
    description: meta.description ? String(meta.description) : '',
    author: meta.author ? String(meta.author) : '',
    features: Array.isArray(meta.features) ? meta.features.map(String) : [],
  };
}

/// 统一调用入口。返回值必须能结构化克隆：脚本里带函数 / Map 的对象由
/// 主线程按需再取，这里先 JSON 化一次，保证跨线程不会抛 DataCloneError。
function invoke(id, method, args) {
  if (!spider) {
    post({ type: 'result', id: id, ok: false, error: '脚本尚未加载', code: 'NOT_READY' });
    return;
  }
  var target = spider[method];
  if (typeof target !== 'function') {
    post({
      type: 'result',
      id: id,
      ok: false,
      error: '当前脚本没有实现 ' + method,
      code: 'MISSING_METHOD',
    });
    return;
  }
  Promise.resolve()
    .then(function () {
      return target.apply(spider, args);
    })
    .then(function (value) {
      post({ type: 'result', id: id, ok: true, value: cloneable(value) });
    })
    .catch(function (error) {
      post({
        type: 'result',
        id: id,
        ok: false,
        error: error && error.message ? String(error.message) : String(error),
        code: error && error.code ? String(error.code) : 'JS_EXECUTION',
      });
    });
}

/// JSON 往返一次，去掉 goja/引擎之间的差异对象（Map、函数、undefined）。
function cloneable(value) {
  if (value === undefined || value === null) return null;
  try {
    return JSON.parse(JSON.stringify(value));
  } catch (error) {
    return null;
  }
}

function installConsole() {
  var noop = function () {};
  self.console = { log: noop, warn: noop, error: noop, info: noop, debug: noop };
}

function installDevice(device) {
  self.__native_save_device = function (json) {
    if (!json || typeof json !== 'string') return;
    try {
      self.localStorage && self.localStorage.setItem(DEVICE_KEY, json);
    } catch (error) {
      // Worker 里没有 localStorage，交给主线程存。
    }
    post({ type: 'device', json: json });
  };
  if (device) {
    try {
      globalThis.__hongguoCachedDevice = JSON.parse(device);
    } catch (error) {
      // 存下来的设备号损坏就当没有，脚本会重新注册。
    }
  }
}

// ---------------------------------------------------------------- fetch

function installFetch() {
  self.fetch = function (url, options) {
    var opts = options || {};
    var id = ++fetchSeq;
    var body = opts.body;
    if (body && typeof body !== 'string') {
      try {
        body = JSON.stringify(body);
      } catch (error) {
        body = '';
      }
    }
    return new Promise(function (resolve, reject) {
      fetchWaiters.set(id, { resolve: resolve, reject: reject });
      post({
        type: 'fetch',
        id: id,
        url: String(url),
        method: (opts.method || 'GET').toUpperCase(),
        headers: opts.headers || {},
        body: body || '',
        timeoutMs: opts.timeoutMs || 15000,
      });
    });
  };
}

function settleFetch(data) {
  var waiter = fetchWaiters.get(data.id);
  if (!waiter) return;
  fetchWaiters.delete(data.id);
  var status = typeof data.status === 'number' ? data.status : 0;
  var body = data.body == null ? '' : String(data.body);
  if (!status && data.error) {
    var failure = new Error(data.errorDetail || '网络请求失败');
    failure.code = data.error;
    waiter.reject(failure);
    return;
  }
  var headers = data.headers || {};
  waiter.resolve({
    status: status,
    ok: status >= 200 && status < 300,
    headers: headers,
    body: body,
    text: function () {
      return Promise.resolve(body);
    },
    json: function () {
      try {
        return Promise.resolve(JSON.parse(body));
      } catch (error) {
        return Promise.resolve({});
      }
    },
  });
}

// ---------------------------------------------------------------- html

/// 最小 HTML 解析器：只实现脚本常用的 find / text / attr。
/// 与 Dart 端注入的 html shim 同一套选择器子集（tag、.class、#id、后代）。
function installHtml() {
  var voidTags = {
    area: 1, base: 1, br: 1, col: 1, embed: 1, hr: 1, img: 1,
    input: 1, link: 1, meta: 1, param: 1, source: 1, track: 1, wbr: 1,
  };

  function Node(tag, attrs) {
    this.tag = (tag || '').toLowerCase();
    this.attrs = attrs || {};
    this.children = [];
    this.texts = [];
  }

  Node.prototype.text = function () {
    var parts = [];
    (function collect(node) {
      for (var i = 0; i < node.texts.length; i++) {
        if (node.texts[i]) parts.push(node.texts[i]);
      }
      for (var j = 0; j < node.children.length; j++) collect(node.children[j]);
    })(this);
    return parts.join(' ').replace(/\s+/g, ' ').trim();
  };

  Node.prototype.attr = function (name) {
    return name ? this.attrs[String(name).toLowerCase()] || '' : '';
  };

  function parseAttrs(raw) {
    var attrs = {};
    if (!raw) return attrs;
    var pattern = /([a-zA-Z0-9_\-:]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g;
    var match;
    while ((match = pattern.exec(raw)) !== null) {
      var value = match[2] !== undefined ? match[2] : match[3] !== undefined ? match[3] : match[4] !== undefined ? match[4] : '';
      attrs[match[1].toLowerCase()] = value;
    }
    return attrs;
  }

  function matchSingle(node, selector) {
    if (!selector || !node.tag) return false;
    if (selector === '*') return true;
    var id = selector.indexOf('#');
    var dot = selector.indexOf('.');
    if (id === 0) return (node.attrs.id || '') === selector.slice(1);
    if (dot === 0) return String(node.attrs.class || '').split(/\s+/).indexOf(selector.slice(1)) !== -1;
    var tag = selector;
    var cls = '';
    if (dot > 0) {
      tag = selector.slice(0, dot);
      cls = selector.slice(dot + 1);
    }
    var idValue = '';
    if (id > 0) {
      tag = selector.slice(0, id);
      idValue = selector.slice(id + 1);
    }
    if (node.tag !== tag.toLowerCase()) return false;
    if (idValue && (node.attrs.id || '') !== idValue) return false;
    if (cls && String(node.attrs.class || '').split(/\s+/).indexOf(cls) === -1) return false;
    return true;
  }

  function findIn(roots, selector) {
    if (!selector) return wrap([]);
    var current = roots.slice();
    selector.trim().split(/\s+/).forEach(function (part) {
      var next = [];
      current.forEach(function (root) {
        (function walk(node, isRoot) {
          if (!isRoot && matchSingle(node, part) && next.indexOf(node) === -1) next.push(node);
          node.children.forEach(function (child) {
            walk(child, false);
          });
        })(root, true);
      });
      current = next;
    });
    return wrap(current);
  }

  function wrap(nodes) {
    return {
      length: nodes.length,
      text: function () {
        return nodes
          .map(function (node) {
            return node.text();
          })
          .join(' ')
          .replace(/\s+/g, ' ')
          .trim();
      },
      attr: function (name) {
        return nodes.length ? nodes[0].attr(name) : '';
      },
      find: function (selector) {
        return findIn(nodes, selector);
      },
      eq: function (index) {
        return wrap(index >= 0 && index < nodes.length ? [nodes[index]] : []);
      },
      first: function () {
        return wrap(nodes.slice(0, 1));
      },
    };
  }

  function parse(html) {
    var root = new Node('root', {});
    var current = root;
    var clean = String(html || '')
      .replace(/<!--[\s\S]*?-->/g, '')
      .replace(/<script[\s\S]*?<\/script>/gi, '')
      .replace(/<style[\s\S]*?<\/style>/gi, '');
    var pattern = /<(\/)?([a-zA-Z0-9_\-]+)([^>]*)>|([^<]+)/g;
    var match;
    while ((match = pattern.exec(clean)) !== null) {
      var closing = !!match[1];
      var tag = match[2];
      var rawAttrs = match[3];
      var text = match[4];
      if (text) {
        var trimmed = text.trim();
        if (trimmed) current.texts.push(trimmed);
        continue;
      }
      if (!tag) continue;
      var lower = tag.toLowerCase();
      if (closing) {
        var cursor = current;
        while (cursor && cursor !== root && cursor.tag !== lower) {
          cursor = cursor.parent;
        }
        if (cursor && cursor !== root) current = cursor.parent || root;
        continue;
      }
      var node = new Node(lower, parseAttrs(rawAttrs));
      node.parent = current;
      current.children.push(node);
      if (!voidTags[lower] && !(rawAttrs && rawAttrs.trim().slice(-1) === '/')) {
        current = node;
      }
    }
    return wrap([root]);
  }

  self.html = { parse: parse };
}
