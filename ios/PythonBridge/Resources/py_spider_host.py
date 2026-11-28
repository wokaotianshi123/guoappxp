import ast
import base64
import hashlib
import importlib.util
import inspect
import json
import os
import ssl
import sys
import threading
import time
import traceback
import types
import urllib.parse
import urllib.request

try:
    _ssl_paths = ssl.get_default_verify_paths()
    _ssl_unverified = not (
        (_ssl_paths.cafile and os.path.exists(_ssl_paths.cafile))
        or (_ssl_paths.capath and os.path.exists(_ssl_paths.capath))
        or os.environ.get("SSL_CERT_FILE")
        or os.environ.get("SSL_CERT_DIR")
    )
except Exception:
    _ssl_unverified = False
if _ssl_unverified:
    ssl._create_default_https_context = ssl._create_unverified_context

# 宿主真实调用面（_dispatch/handle/dispose 逐处核对）：
# 核心方法缺失即不可用，导入校验硬性要求；缺省方法宿主从不调用
# （getDependence/isVideoFormat/manualVideoCheck/action）或仅按需、
# 带兜底调用（destroy 异常吞掉、localProxy 仅代理动作触发），缺失时
# 由 _fill_defaults 在加载期补默认实现，不再拒绝导入（用户 2026-10-24
# 拍板：其自有 py 多为老壳方言，缺的多是这类缺省方法）。
CORE_METHODS = (
    "getName",
    "init",
    "homeContent",
    "homeVideoContent",
    "categoryContent",
    "detailContent",
    "searchContent",
    "playerContent",
)

DEFAULTED_METHODS = (
    "getDependence",
    "destroy",
    "localProxy",
    "isVideoFormat",
    "manualVideoCheck",
    "action",
)

REQUIRED_METHODS = CORE_METHODS + DEFAULTED_METHODS

_instances = {}


def validate_source(text):
    if text.startswith("\ufeff"):
        text = text[1:]
    try:
        tree = ast.parse(text)
    except SyntaxError as error:
        return {
            "ok": False,
            "error": "语法错误：第 %s 行 %s" % (error.lineno or 0, error.msg),
            "missing": list(CORE_METHODS),
            "filled": [],
            "hasSpider": False,
            "mode": "full",
        }
    spider = None
    for node in tree.body:
        if isinstance(node, ast.ClassDef) and node.name == "Spider":
            spider = node
            break
    if spider is None:
        return {
            "ok": False,
            "error": "未找到 class Spider",
            "missing": list(CORE_METHODS),
            "filled": [],
            "hasSpider": False,
            "mode": "full",
        }
    found = []
    for node in spider.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            found.append(node.name)
        elif isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name):
                    found.append(target.id)
        elif isinstance(node, ast.AnnAssign):
            if isinstance(node.target, ast.Name):
                found.append(node.target.id)
    missing = [name for name in CORE_METHODS if name not in found]
    filled = [name for name in DEFAULTED_METHODS if name not in found]
    if missing and "playerContent" in found:
        return {
            "ok": True,
            "error": "",
            "missing": [],
            "filled": missing + filled,
            "hasSpider": True,
            "methods": found,
            "mode": "playOnly",
        }
    return {
        "ok": not missing,
        "error": "" if not missing else "缺少核心方法：%s" % "、".join(missing),
        "missing": missing,
        "filled": filled,
        "hasSpider": True,
        "methods": found,
        "mode": "full",
    }


def validate_source_json(text):
    return json.dumps(validate_source(text), ensure_ascii=False)


def _jsonable(value):
    if value is None or isinstance(value, (bool, int, float, str)):
        return value
    if isinstance(value, bytes):
        return {"$bytes": base64.b64encode(value).decode("ascii")}
    if isinstance(value, dict):
        return {str(key): _jsonable(item) for key, item in value.items()}
    if isinstance(value, (list, tuple, set)):
        return [_jsonable(item) for item in value]
    return str(value)


class _FetchResult(str):
    def __new__(cls, body, status=200, headers=None, url=""):
        obj = super().__new__(cls, body)
        obj.text = body
        obj.content = body.encode("utf-8", "ignore")
        obj.status_code = status
        obj.headers = dict(headers or {})
        obj.url = url
        return obj

    def json(self):
        return json.loads(str(self))


def _norm_timeout(timeout):
    if timeout is None:
        return 30.0
    try:
        value = float(timeout)
    except Exception:
        return 30.0
    if value > 1000:
        value = value / 1000.0
    return min(max(value, 1.0), 60.0)


_cf_disguise_enabled = True

# Direct connection only: drop any proxy env vars so `requests` cannot pick
# them up, and install an opener with an empty ProxyHandler so urllib
# never routes through a proxy regardless of environment.
for _proxy_env_key in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY"):
    os.environ.pop(_proxy_env_key, None)
urllib.request.install_opener(
    urllib.request.build_opener(urllib.request.ProxyHandler({}))
)


def _pick_impersonate(hdrs):
    ua = ""
    for key, value in (hdrs or {}).items():
        if str(key).lower() == "user-agent":
            ua = str(value)
            break
    if "Firefox" in ua:
        return "firefox"
    if "Edg/" in ua or "Edge/" in ua:
        return "edge"
    if "Chrome" in ua or "Chromium" in ua:
        return "chrome"
    if "Safari" in ua:
        return "safari"
    return "chrome"


def _is_cf_challenge(result):
    if result is None:
        return False
    body = str(result)
    headers = {str(k).lower(): str(v) for k, v in result.headers.items()}
    if "cf-ray" in headers or headers.get("server", "").lower() == "cloudflare":
        if result.status_code in (403, 429, 503):
            return True
        if any(
            marker in body
            for marker in (
                "Just a moment",
                "Attention Required",
                "Checking your browser",
                "Enable JavaScript and cookies",
            )
        ):
            return True
    return result.status_code in (403, 503) and (
        "challenge" in body.lower() or "cloudflare" in body.lower()
    )


def _do_http_urllib(method, url, hdrs, data, timeout):
    import urllib.error
    import urllib.request

    req = urllib.request.Request(url, data=data, headers=hdrs, method=method.upper())
    try:
        with urllib.request.urlopen(req, timeout=_norm_timeout(timeout)) as resp:
            body = resp.read().decode("utf-8", "ignore")
            return _FetchResult(body, resp.status, dict(resp.headers), resp.url)
    except urllib.error.HTTPError as err:
        body = err.read().decode("utf-8", "ignore")
        return _FetchResult(body, err.code, dict(err.headers), url)


def _do_http_curl(method, url, hdrs, data, timeout):
    if not _cf_disguise_enabled:
        return None
    try:
        from curl_cffi.requests import Session
    except Exception:
        return None
    try:
        session = Session(
            impersonate=_pick_impersonate(hdrs),
        )
        try:
            resp = session.request(
                method.upper(),
                url,
                headers=hdrs,
                data=data,
                timeout=_norm_timeout(timeout),
            )
            body = resp.text
            headers = dict(resp.headers) if resp.headers is not None else {}
            return _FetchResult(body, resp.status_code, headers, resp.url)
        finally:
            try:
                session.close()
            except Exception:
                pass
    except Exception:
        return None


def _do_http(method, url, headers=None, cookies=None, data=None, payload=None, timeout=None):
    hdrs = dict(headers or {})
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        hdrs.setdefault("Content-Type", "application/json")
    if isinstance(data, str):
        data = data.encode("utf-8")
    if cookies:
        if isinstance(cookies, dict):
            cookie = "; ".join("%s=%s" % (k, v) for k, v in cookies.items())
        else:
            cookie = str(cookies)
        hdrs.setdefault("Cookie", cookie)
    try:
        result = _do_http_urllib(method, url, hdrs, data, timeout)
    except Exception as first_error:
        disguised = _do_http_curl(method, url, hdrs, data, timeout)
        if disguised is not None:
            return disguised
        raise first_error
    if _is_cf_challenge(result):
        disguised = _do_http_curl(method, url, hdrs, data, timeout)
        if disguised is not None:
            return disguised
    return result


# Pure-python AES (ECB/CBC/CTR) + ARC4 + pad/unpad, used only when Crypto is missing.
# S-boxes are generated from GF(2^8) arithmetic, no tables copied in.
def _gf_mul(a, b):
    r = 0
    while b:
        if b & 1: r ^= a
        a = ((a << 1) ^ 0x1b) & 0xff if a & 0x80 else (a << 1)
        b >>= 1
    return r
def _gf_inv(a):
    if a == 0: return 0
    r = 1
    for _ in range(254): r = _gf_mul(r, a) if False else r
    # use exponentiation: a^254
    result = 1
    base = a
    exp = 254
    while exp:
        if exp & 1: result = _gf_mul(result, base)
        base = _gf_mul(base, base)
        exp >>= 1
    return result
def _make_sbox():
    sbox = []
    for i in range(256):
        inv = _gf_inv(i)
        s = inv
        for shift in (1, 2, 3, 4):
            s ^= ((inv << shift) | (inv >> (8 - shift))) & 0xff
        s ^= 0x63
        sbox.append(s & 0xff)
    inv_sbox = [0] * 256
    for i, v in enumerate(sbox): inv_sbox[v] = i
    return sbox, inv_sbox
SBOX, INV_SBOX = _make_sbox()
RCON = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36]
def _expand_key(key):
    Nk = len(key) // 4
    Nr = Nk + 6
    w = [list(key[4*i:4*i+4]) for i in range(Nk)]
    for i in range(Nk, 4 * (Nr + 1)):
        temp = list(w[i-1])
        if i % Nk == 0:
            temp = [SBOX[temp[1]] ^ RCON[i//Nk - 1], SBOX[temp[2]], SBOX[temp[3]], SBOX[temp[0]]]
        elif Nk > 6 and i % Nk == 4:
            temp = [SBOX[b] for b in temp]
        w.append([w[i-Nk][j] ^ temp[j] for j in range(4)])
    return w, Nr
def _add_rk(state, w, rnd):
    for c in range(4):
        for r in range(4):
            state[r][c] ^= w[rnd*4 + c][r]
def _sub(state, box):
    for r in range(4):
        for c in range(4): state[r][c] = box[state[r][c]]
def _shift(state, inv=False):
    for r in range(1, 4):
        row = [state[r][c] for c in range(4)]
        shift = r if not inv else 4 - r
        for c in range(4): state[r][c] = row[(c + shift) % 4]
def _mix(state, inv=False):
    for c in range(4):
        col = [state[r][c] for r in range(4)]
        if not inv:
            state[0][c] = _gf_mul(col[0],2) ^ _gf_mul(col[1],3) ^ col[2] ^ col[3]
            state[1][c] = col[0] ^ _gf_mul(col[1],2) ^ _gf_mul(col[2],3) ^ col[3]
            state[2][c] = col[0] ^ col[1] ^ _gf_mul(col[2],2) ^ _gf_mul(col[3],3)
            state[3][c] = _gf_mul(col[0],3) ^ col[1] ^ col[2] ^ _gf_mul(col[3],2)
        else:
            state[0][c] = _gf_mul(col[0],14) ^ _gf_mul(col[1],11) ^ _gf_mul(col[2],13) ^ _gf_mul(col[3],9)
            state[1][c] = _gf_mul(col[0],9) ^ _gf_mul(col[1],14) ^ _gf_mul(col[2],11) ^ _gf_mul(col[3],13)
            state[2][c] = _gf_mul(col[0],13) ^ _gf_mul(col[1],9) ^ _gf_mul(col[2],14) ^ _gf_mul(col[3],11)
            state[3][c] = _gf_mul(col[0],11) ^ _gf_mul(col[1],13) ^ _gf_mul(col[2],9) ^ _gf_mul(col[3],14)
def _block_to_state(block):
    return [[block[r + 4*c] for c in range(4)] for r in range(4)]
def _state_to_block(state):
    return bytes(state[r][c] for c in range(4) for r in range(4))
def _encrypt_block(block, w, Nr):
    state = _block_to_state(block)
    _add_rk(state, w, 0)
    for rnd in range(1, Nr):
        _sub(state, SBOX); _shift(state); _mix(state); _add_rk(state, w, rnd)
    _sub(state, SBOX); _shift(state); _add_rk(state, w, Nr)
    return _state_to_block(state)
def _decrypt_block(block, w, Nr):
    state = _block_to_state(block)
    _add_rk(state, w, Nr)
    for rnd in range(Nr-1, 0, -1):
        _shift(state, True); _sub(state, INV_SBOX); _add_rk(state, w, rnd); _mix(state, True)
    _shift(state, True); _sub(state, INV_SBOX); _add_rk(state, w, 0)
    return _state_to_block(state)

class _AESCipher:
    block_size = 16
    MODE_ECB = 1
    MODE_CBC = 2
    MODE_CFB = 3
    MODE_OFB = 5
    MODE_CTR = 6
    MODE_GCM = 11
    def __init__(self, key, mode, iv=None, nonce=None):
        self._w, self._nr = _expand_key(key)
        self._mode = mode
        self._iv = iv or bytes(16)
        self._counter = int.from_bytes((nonce or bytes(8)) + bytes(8), "big") if mode == 6 else 0
        self._prev = self._iv
    @staticmethod
    def new(key, mode, iv=None, nonce=None, **kw):
        if "initial_value" in kw:
            nonce = kw["initial_value"]
        return _AESCipher(key, mode, iv=iv, nonce=nonce)
    def encrypt(self, data):
        if self._mode == 1:
            return b"".join(_encrypt_block(data[i:i+16], self._w, self._nr) for i in range(0, len(data), 16))
        if self._mode == 2:
            out = b""; prev = self._prev
            for i in range(0, len(data), 16):
                blk = bytes(a ^ b for a, b in zip(data[i:i+16], prev))
                enc = _encrypt_block(blk, self._w, self._nr); out += enc; prev = enc
            self._prev = prev
            return out
        if self._mode == 6:
            out = b""
            for i in range(0, len(data), 16):
                ks = _encrypt_block(self._counter.to_bytes(16, "big"), self._w, self._nr)
                chunk = data[i:i+16]
                out += bytes(a ^ b for a, b in zip(chunk, ks))
                self._counter += 1
            return out
        raise ValueError("AES mode not supported by pure-python shim")
    def decrypt(self, data):
        if self._mode == 1:
            return b"".join(_decrypt_block(data[i:i+16], self._w, self._nr) for i in range(0, len(data), 16))
        if self._mode == 2:
            out = b""; prev = self._prev
            for i in range(0, len(data), 16):
                blk = data[i:i+16]
                dec = _decrypt_block(blk, self._w, self._nr)
                out += bytes(a ^ b for a, b in zip(dec, prev)); prev = blk
            self._prev = prev
            return out
        if self._mode == 6:
            return self.encrypt(data)
        raise ValueError("AES mode not supported by pure-python shim")

class _ARC4Cipher:
    def __init__(self, key):
        self._s = list(range(256)); j = 0
        for i in range(256):
            j = (j + self._s[i] + key[i % len(key)]) % 256
            self._s[i], self._s[j] = self._s[j], self._s[i]
        self._i = 0; self._j = 0
    @staticmethod
    def new(key, **kw):
        return _ARC4Cipher(key)
    def _stream(self, data):
        out = bytearray()
        for b in data:
            self._i = (self._i + 1) % 256
            self._j = (self._j + self._s[self._i]) % 256
            self._s[self._i], self._s[self._j] = self._s[self._j], self._s[self._i]
            out.append(b ^ self._s[(self._s[self._i] + self._s[self._j]) % 256])
        return bytes(out)
    def encrypt(self, data): return self._stream(data)
    def decrypt(self, data): return self._stream(data)

def _pad(data, block_size):
    n = block_size - len(data) % block_size
    return data + bytes([n]) * n

def _unpad(data, block_size=None):
    if not data: raise ValueError("empty data")
    n = data[-1]
    if n < 1 or n > len(data): raise ValueError("bad padding")
    return data[:-n]

def _ensure_crypto_shim():
    try:
        import Crypto  # noqa: F401
        return False
    except Exception:
        pass
    import hashlib as _hashlib
    crypto = types.ModuleType("Crypto")
    cipher_mod = types.ModuleType("Crypto.Cipher")
    cipher_mod.AES = _AESCipher
    cipher_mod.ARC4 = _ARC4Cipher
    cipher_mod.MODE_ECB = 1; cipher_mod.MODE_CBC = 2; cipher_mod.MODE_CTR = 6
    util_mod = types.ModuleType("Crypto.Util")
    pad_mod = types.ModuleType("Crypto.Util.Padding")
    pad_mod.pad = _pad; pad_mod.unpad = _unpad
    hash_mod = types.ModuleType("Crypto.Hash")
    hash_mod.MD5 = _hashlib.md5; hash_mod.SHA256 = _hashlib.sha256; hash_mod.SHA1 = _hashlib.sha1
    sys.modules["Crypto"] = crypto
    sys.modules["Crypto.Cipher"] = cipher_mod
    sys.modules["Crypto.Util"] = util_mod
    sys.modules["Crypto.Util.Padding"] = pad_mod
    sys.modules["Crypto.Hash"] = hash_mod
    sys.modules["Cryptodome"] = crypto
    sys.modules["Cryptodome.Cipher"] = cipher_mod
    sys.modules["Cryptodome.Util"] = util_mod
    sys.modules["Cryptodome.Util.Padding"] = pad_mod
    sys.modules["Cryptodome.Hash"] = hash_mod
    return True

_cache_file_lock = threading.Lock()


def _ensure_base_spider_stub():
    if "base.spider" in sys.modules:
        return
    try:
        import base.spider  # noqa: F401
        return
    except Exception:
        pass
    base_module = types.ModuleType("base")
    spider_module = types.ModuleType("base.spider")

    class BaseSpider:
        def _cache_state(self):
            state = getattr(self, "_huoyi_cache_state", None)
            if state is None:
                with _cache_file_lock:
                    state = getattr(self, "_huoyi_cache_state", None)
                    if state is None:
                        state = {
                            "entries": {},
                            "lock": threading.Lock(),
                            "loaded_path": None,
                        }
                        self._huoyi_cache_state = state
            path = getattr(self, "_huoyi_cache_path", None)
            if path and state["loaded_path"] != path:
                with state["lock"]:
                    if state["loaded_path"] != path:
                        try:
                            with open(path, "r", encoding="utf-8") as handle:
                                raw = json.load(handle)
                        except Exception:
                            raw = None
                        if isinstance(raw, dict):
                            now = time.time()
                            for key, item in raw.items():
                                if not isinstance(item, dict) or "v" not in item:
                                    continue
                                exp = item.get("exp")
                                if exp is not None:
                                    try:
                                        if float(exp) <= now:
                                            continue
                                    except Exception:
                                        continue
                                if str(key) not in state["entries"]:
                                    state["entries"][str(key)] = item
                        state["loaded_path"] = path
            return state

        def _cache_save(self, state):
            path = getattr(self, "_huoyi_cache_path", None)
            if not path:
                return
            with state["lock"]:
                snapshot = dict(state["entries"])
            serializable = {}
            for key, item in snapshot.items():
                try:
                    json.dumps(item, ensure_ascii=False)
                except Exception:
                    continue
                serializable[key] = item
            try:
                data = json.dumps(serializable, ensure_ascii=False)
            except Exception:
                return
            try:
                parent = os.path.dirname(path)
                if parent:
                    os.makedirs(parent, exist_ok=True)
                tmp = path + ".tmp"
                with open(tmp, "w", encoding="utf-8") as handle:
                    handle.write(data)
                os.replace(tmp, path)
            except Exception:
                return

        def getCache(self, key, default=None):
            state = self._cache_state()
            item = state["entries"].get(str(key))
            if item is None:
                return default
            exp = item.get("exp")
            if exp is not None:
                try:
                    expired = float(exp) <= time.time()
                except Exception:
                    expired = False
                if expired:
                    with state["lock"]:
                        state["entries"].pop(str(key), None)
                    return default
            return item.get("v")

        def setCache(self, key, value, ttl=None, **kw):
            if ttl is None:
                for name in ("expire", "expires", "expires_in"):
                    if name in kw and kw[name] is not None:
                        ttl = kw[name]
                        break
            exp = None
            if ttl is not None:
                try:
                    exp = time.time() + float(ttl)
                except Exception:
                    exp = None
            state = self._cache_state()
            with state["lock"]:
                state["entries"][str(key)] = {"v": value, "exp": exp}
            self._cache_save(state)
            return True

        def putCache(self, key, value, ttl=None, **kw):
            return self.setCache(key, value, ttl=ttl, **kw)

        def delCache(self, key):
            state = self._cache_state()
            with state["lock"]:
                existed = state["entries"].pop(str(key), None) is not None
            if existed:
                self._cache_save(state)
            return existed

        def fetch(self, url, headers=None, cookies=None, timeout=None, **kw):
            timeout = kw.get("timeout", timeout)
            return _do_http("GET", url, headers, cookies, timeout=timeout)

        def get(self, url, headers=None, cookies=None, timeout=None, **kw):
            return self.fetch(url, headers, cookies, timeout, **kw)

        def post(self, url, headers=None, cookies=None, data=None, payload=None, timeout=None, **kw):
            if "json" in kw:
                payload = kw.pop("json")
            return _do_http("POST", url, headers, cookies, data, payload, timeout=timeout)

        def request(self, method, url, headers=None, cookies=None, data=None, timeout=None, **kw):
            return _do_http(method, url, headers, cookies, data, timeout=timeout)

        # 合同方法兜底（与 _DEFAULT_IMPLS 同口径）：老壳方言蜘蛛常以
        # super().init(extend) 起手、或 super().homeContent() 取基类结果
        # 再加工；桩基类缺这些方法时这类调用直接 AttributeError，
        # handle 的 init 阶段就炸、整站打不开（2026-11-26 巨型聚合蜘蛛
        # 实报：init 第一行 super().init(extend) 无处可落）。默认实现
        # 只求不炸、回空结果，真实现由子类覆写。
        def init(self, extend=""):
            return None

        def getName(self):
            return ""

        def homeContent(self, filter=None):
            return {"class": [], "list": []}

        def homeVideoContent(self):
            return {"list": []}

        def categoryContent(self, tid=None, pg=1, filter=None, extend=None):
            return {"list": [], "page": pg, "pagecount": 1}

        def detailContent(self, ids=None):
            return {"list": []}

        def searchContent(self, key=None, quick=False, pg="1"):
            return {"list": [], "page": 1}

        def playerContent(self, flag=None, id=None, vipFlags=None):
            return {}

        def getDependence(self):
            return []

        def destroy(self):
            return None

        def localProxy(self, param=None):
            return [404, "text/plain", "localProxy not implemented", {}]

        def isVideoFormat(self, url=None):
            path = str(url or "").split("?")[0].lower()
            return path.endswith(
                (".m3u8", ".mp4", ".mp3", ".flv", ".mkv", ".mov", ".ts", ".aac")
            )

        def manualVideoCheck(self):
            return False

        def action(self, action=None):
            return ""

    for alias in (
        "BaseSpider",
        "Spider",
        "SpiderBase",
        "_BaseSpider",
        "_Base",
        "_Spider",
        "_B",
        "Base",
        "Spidaer",
        "BaseSpile",
    ):
        setattr(spider_module, alias, BaseSpider)

    def _base_getattr(name):
        if name.startswith("__") and name.endswith("__"):
            raise AttributeError(name)
        return BaseSpider

    spider_module.__getattr__ = _base_getattr
    base_module.spider = spider_module
    if "base" not in sys.modules:
        sys.modules["base"] = base_module
    sys.modules["base.spider"] = spider_module
    if "spider" not in sys.modules:
        try:
            import spider  # noqa: F401
        except Exception:
            plain_module = types.ModuleType("spider")
            plain_module.Spider = BaseSpider
            plain_module.BaseSpider = BaseSpider
            plain_module.__getattr__ = _base_getattr
            sys.modules["spider"] = plain_module


# Optional HTML fetching module ("moyi_html"), injected into sys.modules the
# same way the base spider stub is. Spiders opt in with an explicit import;
# spiders that never import it behave exactly as before.
#
# Android: calls moyi.HtmlPageRunner.fetch (Chaquopy direct call, JSON in/out).
# Any other platform (iOS, desktop): the "java" import fails, the module stays
# in unsupported mode, and load_page returns an "unsupported" result dict
# instead of raising. Spiders must check html_supported() first; they must not
# guess capability with try/except around the import.
#
# load_page never raises for bad input or runner failure: it always returns a
# result dict with the same shape as the Java HtmlResult JSON.
def _ensure_moyi_html_module():
    if "moyi_html" in sys.modules:
        return
    module = types.ModuleType("moyi_html")

    state_lock = threading.Lock()
    state = {"runner": False, "locks": {}, "shared_lock": threading.Lock()}

    def _resolve_runner():
        if state["runner"] is not False:
            return state["runner"]
        with state_lock:
            if state["runner"] is not False:
                return state["runner"]
            runner = None
            try:
                from java import jclass

                candidate = jclass("moyi.HtmlPageRunner")
                if callable(getattr(candidate, "fetch", None)):
                    runner = candidate
            except Exception:
                runner = None
            state["runner"] = runner
            return runner

    def html_supported():
        return _resolve_runner() is not None

    def _failure(error, message):
        return {
            "ok": False,
            "html": "",
            "cookies": "",
            "ua": "",
            "sniffed": [],
            "eval": None,
            "error": error,
            "message": message,
            "title": "",
            "url": "",
            "truncated": False,
        }

    def _caller_key():
        try:
            frame = inspect.currentframe()
            outer = None
            if frame is not None and frame.f_back is not None:
                outer = frame.f_back.f_back
            if outer is not None:
                name = outer.f_globals.get("__file__") or outer.f_globals.get("__name__")
                if name:
                    return str(name)
        except Exception:
            pass
        return ""

    def _lock_for(key):
        if not key:
            return state["shared_lock"]
        with state_lock:
            lock = state["locks"].get(key)
            if lock is None:
                lock = threading.Lock()
                state["locks"][key] = lock
            return lock

    def _normalize_wait(wait):
        if wait is None:
            return {}
        if isinstance(wait, dict):
            out = {}
            if wait.get("js"):
                out["js"] = str(wait["js"])
            elif wait.get("selector"):
                out["selector"] = str(wait["selector"])
            if "delayMs" in wait:
                try:
                    out["delayMs"] = int(wait["delayMs"])
                except Exception:
                    pass
            elif wait.get("delay") is not None:
                try:
                    out["delayMs"] = int(float(wait["delay"]) * 1000)
                except Exception:
                    pass
            return out
        if isinstance(wait, (int, float)) and not isinstance(wait, bool):
            return {"delayMs": int(wait * 1000)}
        if isinstance(wait, str) and wait.strip():
            return {"selector": wait.strip()}
        return {}

    def _normalize_timeout(timeout):
        try:
            seconds = float(timeout)
        except Exception:
            return 30000
        if seconds <= 0:
            return 30000
        return max(1000, min(120000, int(seconds * 1000)))

    def load_page(url, headers=None, referer="", user_agent="", cookies="",
                  wait=None, script="", sniff=True, timeout=30):
        if not isinstance(url, str) or not url.strip():
            return _failure("network", "empty url")
        target = url.strip()
        if not (target.startswith("http://") or target.startswith("https://")):
            return _failure("network", "only http/https urls are supported")
        runner = _resolve_runner()
        if runner is None:
            result = _failure(
                "unsupported", "HTML fetching is not available on this platform")
            result["url"] = target
            return result
        request = {
            "url": target,
            "headers": dict(headers) if isinstance(headers, dict) else {},
            "referer": str(referer or ""),
            "userAgent": str(user_agent or ""),
            "cookies": str(cookies or ""),
            "wait": _normalize_wait(wait),
            "script": str(script or ""),
            "sniff": bool(sniff),
            "timeoutMs": _normalize_timeout(timeout),
        }
        lock = _lock_for(_caller_key())
        with lock:
            try:
                raw = runner.fetch(json.dumps(request))
            except Exception as error:
                result = _failure("network", "runner call failed: %s" % error)
                result["url"] = target
                return result
        try:
            parsed = json.loads(raw)
        except Exception:
            result = _failure("network", "runner returned invalid JSON")
            result["url"] = target
            return result
        if not isinstance(parsed, dict):
            result = _failure("network", "runner returned a non-object result")
            result["url"] = target
            return result
        parsed.setdefault("url", target)
        return parsed

    module.html_supported = html_supported
    module.load_page = load_page
    module.__all__ = ["html_supported", "load_page"]
    sys.modules["moyi_html"] = module


def _default_is_video_format(url=None):
    path = str(url or "").split("?")[0].lower()
    return path.endswith(
        (".m3u8", ".mp4", ".mp3", ".flv", ".mkv", ".mov", ".ts", ".aac")
    )


_DEFAULT_IMPLS = {
    "getName": lambda: "仅播放",
    "init": lambda extend="": None,
    "homeContent": lambda filter=None: {
        "class": [],
        "list": [
            {
                "vod_id": "play",
                "vod_name": "仅播放",
                "vod_pic": "",
                "vod_remarks": "仅播放模式",
            },
        ],
    },
    "homeVideoContent": lambda: {"list": []},
    "categoryContent": lambda tid=None, pg=1, filter=None, extend=None: {
        "list": [],
        "page": pg,
        "pagecount": 1,
    },
    "detailContent": lambda ids=None: {
        "list": [
            {
                "vod_id": "play",
                "vod_name": "仅播放",
                "vod_pic": "",
                "vod_content": "仅播放模式",
                "vod_play_from": "默认",
                "vod_play_url": "正片$play",
            },
        ],
    },
    "searchContent": lambda key=None, quick=False, pg="1": {"list": [], "page": 1},
    "getDependence": lambda: [],
    "destroy": lambda: None,
    "localProxy": lambda param=None: [
        404,
        "text/plain",
        "localProxy not implemented",
        {},
    ],
    "isVideoFormat": _default_is_video_format,
    "manualVideoCheck": lambda: False,
    "action": lambda action=None: "",
}


def _fill_defaults(spider):
    filled = []
    for name, impl in _DEFAULT_IMPLS.items():
        if name == "playerContent":
            continue
        if not callable(getattr(spider, name, None)):
            setattr(spider, name, impl)
            filled.append(name)
    spider._huoyi_filled = filled
    return filled


class _Dummy:
    def __call__(self, *args, **kwargs):
        return _Dummy()

    def __getattr__(self, name):
        return _Dummy()

    def __mro_entries__(self, bases):
        raise ImportError("stubbed module member used as a base class")

    def __iter__(self):
        return iter(())

    def __str__(self):
        return ""

    def __bool__(self):
        return False


def _make_dummy_module(name):
    module = types.ModuleType(name)
    module.__path__ = []
    module.__getattr__ = lambda attr: _Dummy()
    return module


class _RequestsResponse:
    def __init__(self, status, headers, body, url):
        self.status_code = status
        self.headers = headers
        self._body = body
        self.url = url

    @property
    def content(self):
        return self._body

    @property
    def text(self):
        return self._body.decode("utf-8", "ignore")

    def json(self):
        return json.loads(self.text)

    def raise_for_status(self):
        if self.status_code >= 400:
            raise RuntimeError("HTTP %s" % self.status_code)


def _make_requests_module():
    def _request(method, url, **kwargs):
        headers = dict(kwargs.get("headers") or {})
        body = kwargs.get("data")
        payload = kwargs.get("json")
        result = _do_http(
            method,
            url,
            headers=headers,
            data=body,
            payload=payload,
            timeout=kwargs.get("timeout"),
        )
        return _RequestsResponse(
            result.status_code, result.headers, result.content, result.url
        )

    class _Session:
        def __init__(self):
            self.headers = {}

        def request(self, method, url, **kwargs):
            merged = dict(self.headers)
            merged.update(kwargs.get("headers") or {})
            kwargs["headers"] = merged
            return _request(method, url, **kwargs)

        def get(self, url, **kwargs):
            return self.request("GET", url, **kwargs)

        def post(self, url, **kwargs):
            return self.request("POST", url, **kwargs)

        def close(self):
            return None

    module = types.ModuleType("requests")
    module.get = lambda url, **kwargs: _request("GET", url, **kwargs)
    module.post = lambda url, **kwargs: _request("POST", url, **kwargs)
    module.head = lambda url, **kwargs: _request("HEAD", url, **kwargs)
    module.put = lambda url, **kwargs: _request("PUT", url, **kwargs)
    module.delete = lambda url, **kwargs: _request("DELETE", url, **kwargs)
    module.request = _request
    module.Session = _Session
    exceptions = types.ModuleType("requests.exceptions")

    class _RequestException(Exception):
        pass

    exceptions.RequestException = _RequestException
    exceptions.HTTPError = _RequestException
    exceptions.ConnectionError = _RequestException
    exceptions.Timeout = _RequestException
    module.exceptions = exceptions
    return module


def _ensure_requests_stub():
    if "requests" in sys.modules:
        return False
    try:
        import requests  # noqa: F401
        return False
    except ImportError:
        pass
    sys.modules["requests"] = _make_requests_module()
    return True


def _load_spider(path):
    import os

    mtime = os.path.getmtime(path)
    cached = _instances.get(path)
    if cached is not None and cached[0] == mtime:
        return cached[1]
    _ensure_base_spider_stub()
    _ensure_moyi_html_module()
    _ensure_crypto_shim()
    stubbed = []
    if _ensure_requests_stub():
        stubbed.append("requests")
    digest = hashlib.md5(path.encode("utf-8")).hexdigest()[:12]
    module_name = "py_spider_%s" % digest
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise ImportError("无法加载蜘蛛文件：%s" % path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    last_error = None
    for _ in range(9):
        try:
            spec.loader.exec_module(module)
            last_error = None
            break
        except ModuleNotFoundError as error:
            last_error = error
            missing_name = error.name or ""
            if not missing_name or missing_name in stubbed:
                raise
            stubbed.append(missing_name)
            sys.modules[missing_name] = _make_dummy_module(missing_name)
    if last_error is not None:
        raise last_error
    spider_class = getattr(module, "Spider", None)
    if spider_class is None:
        raise ImportError("蜘蛛文件缺少 class Spider：%s" % path)
    spider = spider_class()
    spider._huoyi_cache_path = os.path.join(
        os.path.dirname(path), "py_spider_cache", digest + ".json"
    )
    _fill_defaults(spider)
    spider._huoyi_stubbed_imports = stubbed
    _instances[path] = (mtime, spider)
    return spider


def _call_arity(func, args):
    try:
        params = list(inspect.signature(func).parameters.values())
    except (TypeError, ValueError):
        return func(*args)
    kinds = {
        inspect.Parameter.POSITIONAL_ONLY,
        inspect.Parameter.POSITIONAL_OR_KEYWORD,
    }
    positional = [p for p in params if p.kind in kinds]
    has_var = any(p.kind == inspect.Parameter.VAR_POSITIONAL for p in params)
    if has_var or len(args) <= len(positional):
        return func(*args)
    return func(*args[: len(positional)])


def _norm_pg(value):
    try:
        page = int(value)
    except (TypeError, ValueError):
        return 1
    return page if page >= 1 else 1


def _call_home(spider, request):
    result = _call_arity(spider.homeContent, (False,))
    return result if isinstance(result, dict) else {"list": result}


def _dispatch(spider, request):
    action = request.get("action") or ""
    if action == "ping":
        methods = [
            name for name in REQUIRED_METHODS if callable(getattr(spider, name, None))
        ]
        return {
            "name": str(spider.getName() or ""),
            "methods": methods,
            "stubbedImports": list(getattr(spider, "_huoyi_stubbed_imports", [])),
            "filled": list(getattr(spider, "_huoyi_filled", [])),
            "sslUnverified": _ssl_unverified,
            "cfDisguise": _cf_disguise_enabled,
        }
    if action == "categories":
        return _call_home(spider, request)
    if action == "home":
        result = _call_arity(spider.homeContent, (True,))
        return result if isinstance(result, dict) else {"list": result}
    if action == "dependence":
        return spider.getDependence()
    if action == "format":
        return bool(spider.isVideoFormat(str(request.get("url") or "")))
    if action == "check":
        return bool(spider.manualVideoCheck())
    if action == "action":
        return spider.action(str(request.get("name") or ""))
    if action == "webFetchResult":
        # webFetch declarative two-stage resume: the shell fetched the
        # rendered HTML for the marker the spider returned; hand it back
        # to the spider's optional webFetchResult(html, ctx) method.
        fn = getattr(spider, "webFetchResult", None)
        if not callable(fn):
            raise ValueError("spider does not define webFetchResult")
        ctx = request.get("ctx") or {}
        result = _call_arity(fn, (str(request.get("html") or ""), ctx))
        return result if isinstance(result, dict) else {"list": result}
    if action == "catalog":
        query = str(request.get("query") or "").strip()
        page = _norm_pg(request.get("page") or 1)
        category = str(request.get("category") or "")
        extend = request.get("extend") or {}
        if query:
            result = _call_arity(spider.searchContent, (query, False, page))
            return result if isinstance(result, dict) else {"list": result}
        if category:
            filter_flag = request.get("filter")
            if filter_flag is None:
                filter_flag = bool(extend)
            result = _call_arity(
                spider.categoryContent, (category, page, filter_flag, extend)
            )
            return result if isinstance(result, dict) else {"list": result}
        home = _call_home(spider, request)
        items = home.get("list") or []
        if not items:
            video = _call_arity(spider.homeVideoContent, ())
            if isinstance(video, dict):
                items = video.get("list") or []
                home = dict(home)
                home["list"] = items
        return home
    if action == "search":
        query = str(request.get("query") or "").strip()
        page = _norm_pg(request.get("page") or 1)
        result = _call_arity(spider.searchContent, (query, False, page))
        return result if isinstance(result, dict) else {"list": result}
    if action == "detail":
        vod_id = str(request.get("vodId") or "")
        try:
            result = _call_arity(spider.detailContent, ([vod_id],))
        except TypeError as first_error:
            try:
                result = spider.detailContent(vod_id)
            except TypeError:
                raise first_error
        return result if isinstance(result, dict) else {"list": []}
    if action == "resolve":
        flag = str(request.get("flag") or "")
        play_id = str(request.get("playId") or "")
        result = _call_arity(spider.playerContent, (flag, play_id, []))
        return result if isinstance(result, dict) else {}
    if action == "proxy":
        param = request.get("param") or {}
        result = _call_arity(spider.localProxy, (param,))
        if isinstance(result, (list, tuple)) and len(result) >= 3:
            body = result[2]
            if len(result) >= 5 and result[4] == 1:
                if not isinstance(body, str):
                    raise ValueError("localProxy base64 标志置位但 body 不是字符串")
                body_bytes = base64.b64decode(body)
            elif isinstance(body, str):
                body_bytes = body.encode("utf-8")
            elif isinstance(body, bytes):
                body_bytes = body
            else:
                raise ValueError("localProxy body 类型不支持")
            headers = result[3] if len(result) > 3 and isinstance(result[3], dict) else {}
            return {
                "status": int(result[0]),
                "mime": str(result[1] or ""),
                "bodyBase64": base64.b64encode(body_bytes).decode("ascii"),
                "headers": {str(k): str(v) for k, v in headers.items()},
            }
        raise ValueError("localProxy 返回格式不正确")
    raise ValueError("不支持的动作：%s" % action)


_ACTION_METHODS = {
    "ping": "getName",
    "categories": "homeContent",
    "home": "homeContent",
    "dependence": "getDependence",
    "format": "isVideoFormat",
    "check": "manualVideoCheck",
    "action": "action",
    "webFetchResult": "webFetchResult",
    "detail": "detailContent",
    "search": "searchContent",
    "resolve": "playerContent",
    "proxy": "localProxy",
}


def handle(path, request_json):
    global _cf_disguise_enabled
    action = ""
    try:
        request = json.loads(request_json) if request_json else {}
        if not isinstance(request, dict):
            raise ValueError("请求格式不正确")
        action = str(request.get("action") or "")
        if action == "setCfDisguise":
            if isinstance(request.get("enabled"), bool):
                _cf_disguise_enabled = request["enabled"]
            return json.dumps(
                {"ok": True, "data": {"cfDisguise": _cf_disguise_enabled}},
                ensure_ascii=False,
            )
        if isinstance(request.get("cfDisguise"), bool):
            _cf_disguise_enabled = request["cfDisguise"]
        spider = _load_spider(path)
        extend = request.get("extend") or ""
        if isinstance(extend, str):
            extend_text = extend
        else:
            extend_text = json.dumps(extend, ensure_ascii=False, sort_keys=True)
        if getattr(spider, "_huoyi_inited", False) and (
            getattr(spider, "_huoyi_extend", None) != extend_text
        ):
            dispose(path)
            spider = _load_spider(path)
        if not getattr(spider, "_huoyi_inited", False):
            try:
                spider.init(extend_text)
            except TypeError:
                spider.init()
            spider._huoyi_inited = True
            spider._huoyi_extend = extend_text
        data = _dispatch(spider, request)
        return json.dumps({"ok": True, "data": _jsonable(data)}, ensure_ascii=False)
    except Exception as error:  # noqa: BLE001
        detail = "".join(traceback.format_exception_only(type(error), error)).strip()
        method = _ACTION_METHODS.get(action, action)
        label = ("%s/%s" % (action, method)) if method else "py"
        return json.dumps(
            {"ok": False, "error": "%s: %s" % (label, detail)},
            ensure_ascii=False,
        )


def dispose(path):
    cached = _instances.pop(path, None)
    if cached is not None:
        try:
            cached[1].destroy()
        except Exception:
            pass
    return json.dumps({"ok": True}, ensure_ascii=False)


def dispose_all():
    paths = list(_instances.keys())
    for path in paths:
        dispose(path)
    return json.dumps({"ok": True}, ensure_ascii=False)


def _rpc_status():
    return {"available": True, "python": sys.version.split()[0]}


def _rpc_main():
    import sys as _sys
    for line in _sys.stdin:
        line = line.strip()
        if not line:
            continue
        request = None
        try:
            request = json.loads(line)
            rid = request.get("id")
            method = request.get("method")
            params = request.get("params") or {}
            if method == "status":
                reply = {"id": rid, "ok": True, "data": _rpc_status()}
            elif method == "validate":
                reply = {"id": rid, "ok": True, "data": json.loads(validate_source_json(params.get("source") or ""))}
            elif method == "call":
                raw = handle(params.get("path") or "", json.dumps(params.get("request") or {}, ensure_ascii=False))
                parsed = json.loads(raw)
                reply = {"id": rid, "ok": parsed.get("ok") is True, "data": parsed.get("data")}
                if parsed.get("ok") is not True:
                    reply["error"] = parsed.get("error") or "py_exec"
            elif method == "dispose":
                reply = {"id": rid, "ok": True, "data": json.loads(dispose(params.get("path") or ""))}
            elif method == "disposeAll":
                reply = {"id": rid, "ok": True, "data": json.loads(dispose_all())}
            else:
                reply = {"id": rid, "ok": False, "error": "unknown method %s" % method}
        except Exception as error:  # noqa: BLE001
            reply = {"id": request.get("id") if isinstance(request, dict) else None,
                     "ok": False, "error": str(error)}
        try:
            _sys.stdout.write(json.dumps(reply, ensure_ascii=False) + "\n")
            _sys.stdout.flush()
        except Exception:
            break


if __name__ == "__main__":
    if "--rpc" in sys.argv:
        _rpc_main()
