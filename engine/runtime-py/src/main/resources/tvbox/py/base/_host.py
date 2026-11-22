# -*- coding: utf-8 -*-
# base._host: what the engine gives Python spiders. worker.py fills it in; spiders reach it through base.spider.
#
# - where the engine's /proxy is;
# - the engine's network rules, applied to everything the worker fetches: the config's `hosts` (by answering name
#   lookups, socket.getaddrinfo), its `headers` and the GitHub proxy setting (on requests made with `requests` and
#   with base.spider's fetch/post), and whether certificates are checked;
# - HTTP for base.spider: `requests` when installed, the standard library otherwise;
# - a small persistent key/value store (getCache / setCache);
# - loading other spiders a spider depends on.
#
# Nothing here uses the config's DoH: Python resolves names with the system's DNS, after `hosts`.

import importlib.util
import ipaddress
import json
import os
import re
import socket
import ssl
import sys
import threading
import urllib.error
import urllib.request
from urllib.parse import parse_qsl, quote, urlencode, urlsplit

__all__ = ['quote', 'urlencode']

_state = {
    'proxy': 'http://127.0.0.1:9978/proxy',
    'strict_tls': False,
    'home': None,
}


def configure(proxy=None, home=None):
    if proxy:
        _state['proxy'] = proxy.rstrip('?')
    if home:
        _state['home'] = home


def proxy_base():
    return _state['proxy']


def proxy_port():
    try:
        return urlsplit(_state['proxy']).port or 80
    except ValueError:
        return 9978


# ---------------------------------------------------------------- network rules

_IPV4 = re.compile(r'^\d{1,3}(\.\d{1,3}){3}$')


class _HostRules(object):
    """Values by host name: exact names first, then names with `*` (any run of characters) in the order given."""

    def __init__(self, entries):
        self.exact = {}
        self.patterns = []
        for name, value in entries:
            name = str(name).strip().lower()
            if not name:
                continue
            if '*' in name:
                self.patterns.append((re.compile('^' + '.*'.join(re.escape(p) for p in name.split('*')) + '$'), value))
            else:
                self.exact[name] = value

    def find(self, host):
        if host in self.exact:
            return self.exact[host]
        for pattern, value in self.patterns:
            if pattern.match(host):
                return value
        return None


class _Rules(object):
    def __init__(self, spec=None):
        spec = spec or {}
        self.hosts = _HostRules(list((spec.get('hosts') or {}).items()))
        self.headers = _HostRules(list((spec.get('headers') or {}).items()))
        github = spec.get('github') or {}
        self.github_enabled = bool(github.get('enabled'))
        self.github_prefix = github.get('prefix') or ''
        self.strict_tls = bool(spec.get('strictTls'))
        self.playback_proxy = spec.get('playbackProxy') or ''
        self.empty = not (self.hosts.exact or self.hosts.patterns)


_rules = _Rules()
_request_context = threading.local()


def resolve_playback(function, args):
    _request_context.playback = True
    try:
        return function(*args)
    finally:
        _request_context.playback = False


def _playback_proxies(url):
    proxy = _rules.playback_proxy
    if not proxy or not getattr(_request_context, 'playback', False):
        return None
    host = (urlsplit(url).hostname or '').lower().rstrip('.')
    try:
        address = ipaddress.ip_address(host)
        local = address.is_loopback or address.is_private or address.is_link_local
    except ValueError:
        local = '.' not in host or host.endswith(('.localhost', '.local', '.lan', '.internal', '.home'))
    if local:
        return {'http': None, 'https': None, 'all': None}
    return {'http': 'http://' + proxy, 'https': 'http://' + proxy}


def set_rules(spec):
    global _rules
    _rules = _Rules(spec)
    _state['strict_tls'] = _rules.strict_tls


def _literal(host):
    return ':' in host or bool(_IPV4.match(host))


def map_host(host):
    """The name or address `hosts` says to resolve [host] as; None when no rule applies (one step, like TVBox)."""
    rules = _rules
    if rules.empty or host is None:
        return None
    if isinstance(host, bytes):
        try:
            host = host.decode('ascii')
        except UnicodeDecodeError:
            return None
    if not isinstance(host, str):
        return None
    name = host.lower().rstrip('.')
    if not name or _literal(name) or name == 'localhost' or name.endswith('.localhost'):
        return None
    target = rules.hosts.find(name)
    return target if target and target != name else None


def headers_for(url):
    """The config's headers for [url]'s host."""
    try:
        host = (urlsplit(url).hostname or '').lower()
    except ValueError:
        return {}
    if not host:
        return {}
    return _rules.headers.find(host) or {}


_GITHUB_HOST = r'(?:[a-z0-9-]+\.githubusercontent\.com|(?:(?:api|gist|codeload)\.)?github\.com)'
_GITHUB_AUTHORITY = r'(?:[^/?#@]*@)?' + _GITHUB_HOST
_WRAPPED = re.compile(r'^https?://([^/?#]+)/(?:(https?):/{1,2})?(' + _GITHUB_AUTHORITY + r'/.*)$', re.I)
_PLAIN = re.compile(r'^https?://' + _GITHUB_AUTHORITY + r'/.*$', re.I)
_HOST_ONLY = re.compile('^' + _GITHUB_HOST + '$', re.I)


def github_direct(url):
    """The GitHub address [url] stands for (itself, or what a gh-proxy address wraps); None when it is not one."""
    if _PLAIN.match(url):
        return url
    m = _WRAPPED.match(url)
    if not m or _HOST_ONLY.match(m.group(1)):
        return None
    return (m.group(2) or 'https').lower() + '://' + m.group(3)


def _private_params(params):
    if not params:
        return False
    if isinstance(params, str):
        params = parse_qsl(params, keep_blank_values=True)
    names = params.keys() if isinstance(params, dict) else (entry[0] for entry in params)
    for name in names:
        key = str(name).lower()
        if ('token' in key or 'signature' in key or key.startswith(('x-amz-', 'x-goog-')) or
                key in ('sig', 'jwt', 'auth', 'authorization', 'api_key', 'apikey', 'key', 'credential', 'policy', 'key-pair-id', 'awsaccesskeyid')):
            return True
    return False


def routes(url, public_read=True):
    """The addresses to try for [url], in order: the engine's GitHub proxy setting applies (see GithubProxy.kt)."""
    url = str(url)
    direct = github_direct(url)
    rules = _rules
    if direct is None and rules.github_prefix and url.startswith(rules.github_prefix):
        direct = github_direct(url[len(rules.github_prefix):])
    if direct is None:
        return [url]
    origin = urlsplit(direct)
    if public_read and rules.github_enabled and rules.github_prefix and not (origin.username or origin.password or _private_params(origin.query)):
        return [rules.github_prefix + direct, direct]
    return [direct]


_orig_getaddrinfo = socket.getaddrinfo


def _getaddrinfo(host, *args, **kwargs):
    target = map_host(host)
    return _orig_getaddrinfo(target if target else host, *args, **kwargs)


def install():
    """Puts the rules in place: name lookups, and `requests` when it is installed."""
    if socket.getaddrinfo is not _getaddrinfo:
        socket.getaddrinfo = _getaddrinfo
    _install_requests()


def _install_requests():
    try:
        import requests
    except ImportError:
        return
    try:
        import urllib3
        urllib3.disable_warnings()
    except Exception:
        pass
    session_request = requests.sessions.Session.request
    if getattr(session_request, '_yingzhou', False):
        return

    def request(self, method, url, *args, **kwargs):
        headers = kwargs.get('headers') or (args[2] if len(args) > 2 else {}) or {}
        public_read = str(method).upper() in ('GET', 'HEAD') and not (self.auth or self.cookies or kwargs.get('auth') or kwargs.get('cookies') or len(args) > 3)
        config_headers = headers_for(github_direct(str(url)) or url)
        params = kwargs.get('params') or (args[0] if args else None)
        public_read = public_read and not _private_params(params) and not _private_params(self.params)
        public_read = public_read and not any(str(key).lower() in ('authorization', 'cookie', 'x-api-key', 'x-auth-token') for group in (headers, self.headers, config_headers) for key in group)
        targets = routes(url, public_read)
        def send(target):
            options = dict(kwargs)
            proxies = _playback_proxies(target)
            if proxies is not None and len(args) < 9:
                options['proxies'] = proxies
            return session_request(self, method, target, *args, **options)

        extra = headers_for(targets[-1])
        # headers is the third argument after method and url; a call that passes it positionally keeps its own.
        if extra and len(args) < 3:
            merged = requests.structures.CaseInsensitiveDict(kwargs.get('headers') or {})
            for k, v in extra.items():
                merged[k] = v
            kwargs['headers'] = merged
        if not _state['strict_tls'] and kwargs.get('verify') is None and len(args) < 12:
            kwargs['verify'] = False
        if len(targets) == 1:
            return send(targets[0])
        # Through the proxy first; GitHub itself when the proxy fails.
        try:
            rsp = send(targets[0])
            if rsp.ok:
                return rsp
            rsp.close()
        except requests.RequestException:
            pass
        return send(targets[1])

    request._yingzhou = True
    requests.sessions.Session.request = request


# ---------------------------------------------------------------- HTTP for base.spider

_HEADER_NAMES = {
    'user-agent', 'referer', 'cookie', 'accept', 'accept-language', 'accept-encoding', 'origin', 'host',
    'content-type', 'authorization', 'x-requested-with', 'connection', 'range',
}


def looks_like_headers(value):
    return isinstance(value, dict) and any(str(k).lower() in _HEADER_NAMES for k in value.keys())


def request(method, url, **kwargs):
    """`requests.request` when requests is installed, else the same through the standard library."""
    try:
        import requests
    except ImportError:
        return _std_request(method, url, **kwargs)
    return requests.request(method, url, **kwargs)


class _Headers(dict):
    """Case-insensitive lookups over the response headers (like requests' CaseInsensitiveDict)."""

    def __init__(self, pairs):
        super(_Headers, self).__init__()
        self._lower = {}
        for k, v in pairs:
            if k in self:
                v = self[k] + ', ' + v
            dict.__setitem__(self, k, v)
            self._lower[k.lower()] = k

    def __getitem__(self, key):
        return dict.__getitem__(self, self._lower.get(str(key).lower(), key))

    def __contains__(self, key):
        return str(key).lower() in self._lower

    def get(self, key, default=None):
        return self[key] if key in self else default


class Response(object):
    """The parts of requests.Response spiders use."""

    def __init__(self, status, reason, headers, content, url):
        self.status_code = status
        self.reason = reason
        self.headers = headers
        self.content = content
        self.url = url
        self.encoding = None
        m = re.search(r'charset=([\w-]+)', headers.get('Content-Type', '') or '', re.I)
        if m:
            self.encoding = m.group(1)
        self.cookies = {}
        for item in (headers.get('Set-Cookie') or '').split(','):
            pair = item.split(';', 1)[0].strip()
            if '=' in pair:
                k, v = pair.split('=', 1)
                self.cookies[k.strip()] = v.strip()

    @property
    def text(self):
        try:
            return self.content.decode(self.encoding or 'utf-8', 'replace')
        except LookupError:
            return self.content.decode('utf-8', 'replace')

    @property
    def ok(self):
        return self.status_code < 400

    def json(self, **kwargs):
        return json.loads(self.text, **kwargs)

    def raise_for_status(self):
        if self.status_code >= 400:
            raise IOError('HTTP %d for %s' % (self.status_code, self.url))

    def iter_content(self, chunk_size=1, decode_unicode=False):
        for i in range(0, len(self.content), chunk_size or len(self.content) or 1):
            yield self.content[i:i + (chunk_size or len(self.content))]

    def close(self):
        pass


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def _std_request(method, url, params=None, data=None, json=None, cookies=None, headers=None, timeout=10,
                 verify=None, stream=False, allow_redirects=True, **ignored):
    import json as _json
    if params:
        query = params if isinstance(params, str) else urlencode(params, doseq=True)
        url = str(url) + ('&' if '?' in str(url) else '?') + query
    sent = {}
    for k, v in (headers or {}).items():
        sent[str(k)] = str(v)
    body = None
    if json is not None:
        body = _json.dumps(json, ensure_ascii=False).encode('utf-8')
        sent.setdefault('Content-Type', 'application/json')
    elif data is not None:
        if isinstance(data, dict):
            body = urlencode(data, doseq=True).encode('utf-8')
            sent.setdefault('Content-Type', 'application/x-www-form-urlencoded')
        elif isinstance(data, str):
            body = data.encode('utf-8')
        else:
            body = bytes(data)
    if cookies:
        sent['Cookie'] = '; '.join('%s=%s' % (k, v) for k, v in dict(cookies).items())
    sent.setdefault('User-Agent', 'okhttp/4.12.0')
    config_headers = headers_for(github_direct(str(url)) or url)
    public_read = str(method).upper() in ('GET', 'HEAD') and not any(str(key).lower() in ('authorization', 'cookie', 'x-api-key', 'x-auth-token') for group in (sent, config_headers) for key in group)
    targets = routes(url, public_read)
    for k, v in headers_for(targets[-1]).items():
        for existing in [h for h in sent if h.lower() == k.lower()]:
            del sent[existing]
        sent[k] = v
    check = verify if verify is not None else _state['strict_tls']
    context = ssl.create_default_context()
    if not check:
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
    handlers = [urllib.request.HTTPSHandler(context=context)]
    if not allow_redirects:
        handlers.append(_NoRedirect())
    error = None
    for i, target in enumerate(targets):
        proxies = _playback_proxies(target)
        handlers_for_target = handlers if proxies is None else handlers + [urllib.request.ProxyHandler({key: value for key, value in proxies.items() if value})]
        opener = urllib.request.build_opener(*handlers_for_target)
        req = urllib.request.Request(target, data=body, headers=sent, method=str(method).upper())
        try:
            res = opener.open(req, timeout=timeout)
            rsp = Response(res.status, res.reason, _Headers(res.headers.items()), res.read(), res.geturl())
        except urllib.error.HTTPError as e:
            rsp = Response(e.code, e.reason, _Headers(e.headers.items() if e.headers else []), e.read() or b'', target)
        except Exception as e:
            error = e
            continue
        if rsp.ok or i == len(targets) - 1 or str(method).upper() != 'GET':
            return rsp
    raise IOError('cannot fetch %s: %s' % (url, error))


# ---------------------------------------------------------------- getCache / setCache

_cache_lock = threading.Lock()
_cache = None


def _cache_file():
    home = _state['home']
    return os.path.join(home, 'cache.json') if home else None


def _cache_load():
    global _cache
    if _cache is None:
        _cache = {}
        path = _cache_file()
        if path and os.path.exists(path):
            try:
                with open(path, 'r', encoding='utf-8') as f:
                    _cache = json.load(f)
            except (OSError, ValueError):
                _cache = {}
    return _cache


def _cache_save():
    path = _cache_file()
    if not path:
        return
    tmp = path + '.tmp'
    try:
        with open(tmp, 'w', encoding='utf-8') as f:
            json.dump(_cache, f, ensure_ascii=False)
        os.replace(tmp, path)
    except OSError:
        pass


def cache_get(key):
    with _cache_lock:
        return _cache_load().get(str(key))


def cache_set(key, value):
    with _cache_lock:
        _cache_load()[str(key)] = value
        _cache_save()


def cache_del(key):
    with _cache_lock:
        if _cache_load().pop(str(key), None) is not None:
            _cache_save()


# ---------------------------------------------------------------- other spiders

_deps = {}
_modules = {}
_modules_lock = threading.Lock()
_counter = [0]


def register_dependency(name, path):
    _deps[str(name)] = path


def load_file(path, label):
    """Runs a .py file as a module of its own; the same file is loaded once."""
    path = os.path.abspath(path)
    with _modules_lock:
        module = _modules.get(path)
        if module is not None:
            return module
        _counter[0] += 1
        name = 'tvbox_py_%d_%s' % (_counter[0], re.sub(r'\W', '_', label) or 'spider')
        folder = os.path.dirname(path)
        if folder not in sys.path:
            sys.path.append(folder)
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        try:
            spec.loader.exec_module(module)
        except BaseException:
            sys.modules.pop(name, None)
            raise
        _modules[path] = module
        return module


def forget_file(path):
    with _modules_lock:
        module = _modules.pop(os.path.abspath(path), None)
        if module is not None:
            sys.modules.pop(module.__name__, None)


def load_module(spider, name, file_name=None):
    path = file_name or _deps.get(str(name))
    if not path:
        own = getattr(sys.modules.get(type(spider).__module__), '__file__', None)
        folder = os.path.dirname(own) if own else os.getcwd()
        for candidate in (os.path.join(folder, '%s.py' % name), os.path.join(folder, '..', 'plugin', '%s.py' % name)):
            if os.path.exists(candidate):
                path = candidate
                break
    if not path:
        raise ImportError('spider module not found: %s' % name, name=str(name))
    return load_file(path, str(name))
