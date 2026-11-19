# -*- coding: utf-8 -*-
"""The Python spider worker of the Yingzhou engine (tvbox-next).

The engine starts one of these per engine and talks to it over stdin / stdout, one JSON object per line:

  engine -> worker   {"id": 7, "op": "call", "key": "site", "method": "homeContent", "args": [true]}
  worker -> engine   {"id": 7, "ok": true, "result": "<the spider's answer as JSON text>"}
                     {"id": 7, "ok": false, "error": {"type", "message", "module", "trace"}}

Operations: setup, net, load, init, call, proxy, destroy, ping (see PyWorker.kt). The first line the worker writes
is {"id": 0, "ok": true, "result": {"hello": ...}}. Requests run on a thread pool, so a slow spider does not hold up
the others; answers come back in whatever order they finish. The worker exits when its stdin closes, which is when
the engine stops or dies.

Spiders print, and some C libraries write to the process's stdout. So before anything else the protocol takes copies
of the real stdin / stdout, and file descriptors 0 / 1 are pointed at nothing / stderr. The engine copies stderr into
its log.

Usage: python -E -X utf8 -u worker.py --home <dir> [--packages <dir>]...
"""

import os
import sys


def _take_stdio():
    proto_in = os.fdopen(os.dup(0), 'rb')
    proto_out = os.fdopen(os.dup(1), 'wb')
    null = os.open(os.devnull, os.O_RDONLY)
    os.dup2(null, 0)
    os.close(null)
    os.dup2(2, 1)
    sys.stdin = open(os.devnull, 'r')
    sys.stdout = sys.stderr
    return proto_in, proto_out


_PROTO_IN, _PROTO_OUT = _take_stdio()


def _args(argv):
    home, packages = None, []
    i = 0
    while i < len(argv):
        if argv[i] == '--home' and i + 1 < len(argv):
            home = argv[i + 1]
            i += 2
        elif argv[i] == '--packages' and i + 1 < len(argv):
            packages.append(argv[i + 1])
            i += 2
        else:
            i += 1
    return home, packages


HOME, PACKAGES = _args(sys.argv[1:])
BRIDGE = os.path.dirname(os.path.abspath(__file__))
# The embeddable CPython ignores the script's folder and PYTHONPATH (its ._pth file decides), so the bridge (with
# the `base` package) and the engine's package folders are put on the path here. The engine's packages come before
# whatever the Python itself has installed.
for _p in reversed([BRIDGE] + [p for p in PACKAGES if p]):
    if _p in sys.path:
        sys.path.remove(_p)
    sys.path.insert(0, _p)
if HOME:
    os.makedirs(HOME, exist_ok=True)
    os.chdir(HOME)

import base64
import inspect
import json
import threading
import traceback
from concurrent.futures import ThreadPoolExecutor

from base import _host

PROTOCOL = 1

if os.name == 'nt':
    # The engine runs without a console window. A console program a spider starts (node for execjs, ...) would get
    # a window of its own; this keeps it hidden.
    import subprocess

    _popen_init = subprocess.Popen.__init__

    def _quiet_popen_init(self, *args, **kwargs):
        if not kwargs.get('creationflags'):
            kwargs['creationflags'] = 0x08000000  # CREATE_NO_WINDOW
        _popen_init(self, *args, **kwargs)

    subprocess.Popen.__init__ = _quiet_popen_init

_out_lock = threading.Lock()


def _send(message):
    line = json.dumps(message, ensure_ascii=True, separators=(',', ':'), default=_json_default) + '\n'
    with _out_lock:
        _PROTO_OUT.write(line.encode('ascii'))
        _PROTO_OUT.flush()


def _json_default(value):
    if isinstance(value, (bytes, bytearray)):
        return bytes(value).decode('utf-8', 'replace')
    if isinstance(value, (set, frozenset, tuple)):
        return list(value)
    return str(value)


def _log(text):
    try:
        sys.stderr.write('[py] %s\n' % text)
        sys.stderr.flush()
    except Exception:
        pass


# ---------------------------------------------------------------- spiders

class LoadError(Exception):
    pass


class _Entry(object):
    def __init__(self, key, module, spider, path):
        self.key = key
        self.module = module
        self.spider = spider
        self.path = path


_entries = {}
_entries_lock = threading.Lock()
_module_counter = [0]

# What may be called through "call": the spider methods of TVBox's base class.
_METHODS = {
    'homeContent', 'homeVideoContent', 'categoryContent', 'detailContent', 'searchContent', 'playerContent',
    'liveContent', 'isVideoFormat', 'manualVideoCheck', 'getName', 'action',
}


def _entry(key):
    with _entries_lock:
        entry = _entries.get(key)
    if entry is None:
        raise LoadError('spider not loaded: %s' % key)
    return entry


def _load_spider_module(path, key):
    """Each site gets its own copy of its script: two sites on one script must not share the spider instance."""
    import importlib.util
    _module_counter[0] += 1
    label = os.path.splitext(os.path.basename(path))[0]
    name = 'tvbox_site_%d_%s' % (_module_counter[0], ''.join(c if c.isalnum() else '_' for c in label))
    folder = os.path.dirname(os.path.abspath(path))
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
    return module


def _drop(entry):
    try:
        entry.spider.destroy()
    except Exception:
        pass
    sys.modules.pop(getattr(entry.module, '__name__', ''), None)


def op_load(req):
    key = str(req['key'])
    path = req['path']
    with _entries_lock:
        old = _entries.pop(key, None)
    if old is not None:
        _drop(old)
    module = _load_spider_module(path, key)
    cls = getattr(module, 'Spider', None)
    if cls is None or not callable(cls):
        sys.modules.pop(module.__name__, None)
        raise LoadError('the script has no class Spider')
    spider = cls()
    try:
        spider.siteKey = key
    except Exception:
        pass
    with _entries_lock:
        _entries[key] = _Entry(key, module, spider, path)
    deps = []
    getter = getattr(spider, 'getDependence', None)
    if callable(getter):
        try:
            deps = [str(d) for d in (getter() or [])]
        except Exception as e:
            _log('%s getDependence: %s' % (key, e))
    return {'deps': deps}


def _set_extend(spider, extend):
    setter = getattr(spider, 'setExtendInfo', None)
    if callable(setter):
        setter(extend)
    else:
        try:
            spider.extend = extend
        except Exception:
            pass


def op_init(req):
    entry = _entry(str(req['key']))
    ext = req.get('ext') or ''
    loaded = []
    # TVBox hands init() the spiders this one depends on (when there are any) instead of its ext.
    for dep in req.get('deps') or []:
        alias, path, dep_ext = dep.get('name'), dep.get('path'), dep.get('ext') or ''
        _host.register_dependency(alias, path)
        module = _host.load_file(path, alias)
        dep_spider = module.Spider()
        _set_extend(dep_spider, dep_ext)
        loaded.append(dep_spider)
    _set_extend(entry.spider, ext)
    entry.spider.init(loaded if loaded else ext)
    return None


def _call_variants(fn, variants):
    """The first argument list the function accepts (TVBox's searchContent has no `pg`, Box's has)."""
    try:
        signature = inspect.signature(fn)
    except (TypeError, ValueError):
        return fn(*variants[0])
    for args in variants:
        try:
            signature.bind(*args)
        except TypeError:
            continue
        return fn(*args)
    return fn(*variants[0])


def _text(result):
    if result is None:
        return None
    if isinstance(result, (bytes, bytearray)):
        return bytes(result).decode('utf-8', 'replace')
    if isinstance(result, str):
        return result
    return json.dumps(result, ensure_ascii=False, default=_json_default)


def op_call(req):
    entry = _entry(str(req['key']))
    method = req.get('method')
    if method not in _METHODS:
        raise ValueError('not a spider method: %s' % method)
    fn = getattr(entry.spider, method, None)
    if not callable(fn):
        return None
    args = list(req.get('args') or [])
    if method == 'searchContent':
        result = _call_variants(fn, [args, args[:2], args[:1]])
    elif method == 'homeContent':
        result = _call_variants(fn, [args, []])
    else:
        result = fn(*args)
    return _text(result)


def _proxy_function(spider):
    """localProxy, or `proxy` in spiders that name it so and do not override localProxy."""
    for cls in type(spider).__mro__:
        if cls.__module__ == 'base.spider':
            break
        if 'localProxy' in cls.__dict__:
            return spider.localProxy
        if 'proxy' in cls.__dict__ and callable(cls.__dict__['proxy']):
            return spider.proxy
    return getattr(spider, 'localProxy', None)


def _body_bytes(content, b64):
    if content is None:
        return b''
    if isinstance(content, (bytes, bytearray, memoryview)):
        return bytes(content)
    if isinstance(content, str):
        if b64:
            text = content.split('base64,', 1)[1] if 'base64,' in content else content
            return base64.b64decode(text)
        return content.encode('utf-8')
    if hasattr(content, 'content') and isinstance(getattr(content, 'content'), (bytes, bytearray)):
        return bytes(content.content)  # a requests.Response
    if hasattr(content, 'read'):
        data = content.read()
        return data.encode('utf-8') if isinstance(data, str) else bytes(data or b'')
    if isinstance(content, (dict, list)):
        return json.dumps(content, ensure_ascii=False).encode('utf-8')
    try:
        return b''.join(c.encode('utf-8') if isinstance(c, str) else bytes(c) for c in content)
    except TypeError:
        return str(content).encode('utf-8')


def _headers(value):
    if not value:
        return {}
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except ValueError:
            return {}
    out = {}
    try:
        for k, v in dict(value).items():
            out[str(k)] = ', '.join(str(x) for x in v) if isinstance(v, (list, tuple)) else str(v)
    except (TypeError, ValueError):
        return {}
    return out


def _proxy_result(result):
    """TVBox's [code, mime, content, headers, base64] (or a dict with those names) as status / type / headers / body."""
    if result is None:
        return None
    if isinstance(result, dict):
        code = result.get('code', result.get('status', 200))
        mime = result.get('type') or result.get('mime') or result.get('content-type') or ''
        b64 = result.get('buffer') == 2 or result.get('base64') in (1, True)
        content = result.get('content', result.get('body'))
        headers = result.get('headers')
    elif isinstance(result, (list, tuple)):
        if len(result) < 3:
            return None
        code, mime, content = result[0], result[1], result[2]
        headers = result[3] if len(result) > 3 else None
        b64 = len(result) > 4 and result[4] in (1, True, '1')
    else:
        return None
    try:
        code = int(code)
    except (TypeError, ValueError):
        code = 200
    headers = _headers(headers)
    if not mime:
        mime = next((v for k, v in headers.items() if k.lower() == 'content-type'), '') or 'application/octet-stream'
    body = _body_bytes(content, b64)
    return {'status': code, 'type': str(mime), 'headers': headers, 'body': base64.b64encode(body).decode('ascii')}


def op_proxy(req):
    entry = _entry(str(req['key']))
    fn = _proxy_function(entry.spider)
    if not callable(fn):
        return None
    params = {str(k): str(v) for k, v in (req.get('params') or {}).items()}
    return _proxy_result(fn(params))


def op_destroy(req):
    with _entries_lock:
        entry = _entries.pop(str(req.get('key')), None)
    if entry is not None:
        _drop(entry)
    return None


def op_net(req):
    _host.set_rules(req.get('net') or {})
    return None


def op_setup(req):
    _host.configure(proxy=req.get('proxy'), home=HOME)
    _host.set_rules(req.get('net') or {})
    _host.install()
    return None


def op_ping(req):
    return {'pid': os.getpid(), 'spiders': len(_entries)}


_OPS = {
    'setup': op_setup, 'net': op_net, 'load': op_load, 'init': op_init, 'call': op_call, 'proxy': op_proxy,
    'destroy': op_destroy, 'ping': op_ping,
}

# ---------------------------------------------------------------- errors

# Names TVBox's base class imported for spiders (`from base.spider import *`), by the module that provides them.
_GLOBALS = {'requests': 'requests', 'etree': 'lxml'}


def _describe(e):
    missing = ''
    if isinstance(e, ModuleNotFoundError) and getattr(e, 'name', None):
        missing = str(e.name).split('.')[0]
    elif isinstance(e, NameError):
        name = getattr(e, 'name', None)
        if not name:
            text = str(e)
            name = text.split("'")[1] if text.count("'") >= 2 else ''
        missing = _GLOBALS.get(name, '')
    return {
        'type': type(e).__name__,
        'message': str(e)[:2000],
        'module': missing,
        'trace': traceback.format_exc()[-4000:],
    }


def _handle(req):
    rid = req.get('id')
    op = req.get('op')
    try:
        fn = _OPS.get(op)
        if fn is None:
            raise ValueError('unknown op: %s' % op)
        result = fn(req)
        _send({'id': rid, 'ok': True, 'result': result})
    except BaseException as e:  # a spider calling sys.exit() must not end the worker
        error = _describe(e)
        _log('%s %s %s: %s: %s\n%s' % (op, req.get('key', ''), req.get('method', ''), error['type'], error['message'],
                                         error['trace']))
        try:
            _send({'id': rid, 'ok': False, 'error': error})
        except Exception:
            pass


def main():
    pool = ThreadPoolExecutor(max_workers=32)
    _send({'id': 0, 'ok': True, 'result': {
        'hello': PROTOCOL,
        'pid': os.getpid(),
        'version': '%d.%d.%d' % sys.version_info[:3],
        'executable': sys.executable,
    }})
    while True:
        raw = _PROTO_IN.readline()
        if not raw:
            break
        raw = raw.strip()
        if not raw:
            continue
        try:
            req = json.loads(raw.decode('utf-8'))
        except ValueError:
            _log('bad request line: %r' % raw[:200])
            continue
        if req.get('op') in ('setup', 'net', 'ping'):
            _handle(req)
        else:
            pool.submit(_handle, req)
    # The engine is gone: leave at once, whatever spider threads are still running.
    os._exit(0)


if __name__ == '__main__':
    main()
