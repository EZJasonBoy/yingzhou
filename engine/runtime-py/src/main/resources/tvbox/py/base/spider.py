# -*- coding: utf-8 -*-
# base.spider: the class TVBox Python spiders derive from (`from base.spider import Spider`).
#
# The method names and helpers follow TVBox's "pyramid" base class (TVBoxOS / Box, AGPL-3.0, pyramid/src/python/
# base/spider.py), so spiders written for TVBox on Android run here unchanged. Differences from the Android version:
#
# - HTTP goes through `requests` when it is installed and through the standard library otherwise, so a spider that
#   only uses self.fetch / self.post works without third-party packages. Either way the engine's rules apply
#   (config `hosts` / `headers`, the GitHub proxy setting, certificates not checked unless the engine is strict);
#   see worker.py.
# - `getProxyUrl()` names this spider (`&siteKey=`), so the engine hands the request back to it and not to whichever
#   Python spider was used last.
# - getCache / setCache / delCache keep their values in a file of the engine, not behind TVBox's local server.
# - `lxml`, `requests` are imported when first used, not when this module is.

import json
import os
import re
import time
from abc import ABCMeta, abstractmethod
from importlib.machinery import SourceFileLoader

from base import _host
from base.localProxy import Proxy

# TVBox's base imported these at the top, and spiders written `from base.spider import *` use them without importing
# them again. They are only there when installed; a spider that needs a missing one is told which package it is.
try:
    import requests
except ImportError:
    pass
try:
    from lxml import etree
except ImportError:
    pass


class Spider(metaclass=ABCMeta):
    _instance = None

    def __init__(self):
        self.extend = ''

    # TVBox keeps one instance per spider class.
    def __new__(cls, *args, **kwargs):
        if cls._instance:
            return cls._instance
        cls._instance = super().__new__(cls)
        return cls._instance

    def init(self, extend=""):
        pass

    def homeContent(self, filter):
        pass

    def homeVideoContent(self):
        pass

    def categoryContent(self, tid, pg, filter, extend):
        pass

    def detailContent(self, ids):
        pass

    def searchContent(self, key, quick, pg="1"):
        pass

    def playerContent(self, flag, id, vipFlags):
        pass

    def liveContent(self, url):
        pass

    def localProxy(self, param):
        pass

    def isVideoFormat(self, url):
        pass

    def manualVideoCheck(self):
        pass

    def action(self, action):
        pass

    def destroy(self):
        pass

    def getName(self):
        pass

    def getDependence(self):
        return []

    def setExtendInfo(self, extend):
        self.extend = extend

    # ---- other spiders ----

    def loadSpider(self, name):
        return self.loadModule(name).Spider()

    def loadModule(self, name, fileName=None):
        """A dependency named by getDependence(), or a .py file next to this spider (TVBox looks in ../plugin)."""
        return _host.load_module(self, name, fileName)

    # ---- text ----

    def regStr(self, src, reg=None, group=1):
        """The first match of a pattern. Spiders call it as regStr(reg, src) and as regStr(src, reg); both work."""
        if reg is None:
            return ''
        match = None
        try:
            match = re.search(reg, src)
        except Exception:
            pass
        if not match:
            try:
                match = re.search(src, reg)
            except Exception:
                pass
        try:
            return match.group(group) if match else ''
        except (IndexError, re.error):
            return ''

    def removeHtmlTags(self, src):
        return re.sub(re.compile('<.*?>'), '', src)

    def cleanText(self, src):
        return re.sub('[\U0001F600-\U0001F64F\U0001F300-\U0001F5FF\U0001F680-\U0001F6FF\U0001F1E0-\U0001F1FF]', '', src)

    def str2json(self, content):
        return json.loads(content)

    def json2str(self, content):
        return json.dumps(content, ensure_ascii=False)

    def html(self, content):
        from lxml import etree
        if isinstance(content, str):
            content = content.encode('utf-8')
        return etree.HTML(content)

    def xpText(self, root, expr):
        ele = root.xpath(expr)
        return ele[0] if len(ele) > 0 else ''

    # ---- network ----

    # verify=None: certificates are checked only when the engine runs with --strict-tls, as for the engine's own
    # requests (TVBox does not check them either). An explicit verify=True is kept.
    def fetch(self, url, params=None, cookies=None, headers=None, timeout=10, verify=None, stream=False,
              allow_redirects=True):
        # TVBoxOS put `headers` second, Box and most forks `params`: a dict of header names in that place is headers.
        if headers is None and _host.looks_like_headers(params):
            params, headers = None, params
        rsp = _host.request('GET', url, params=params, cookies=cookies, headers=headers, timeout=timeout,
                            verify=verify, stream=stream, allow_redirects=allow_redirects)
        rsp.encoding = 'utf-8'
        return rsp

    def post(self, url, params=None, data=None, json=None, cookies=None, headers=None, timeout=10, verify=None,
             stream=False, allow_redirects=True):
        if headers:
            headers = {k: self._clean_header_value(v) for k, v in headers.items()}
        rsp = _host.request('POST', url, params=params, data=data, json=json, cookies=cookies, headers=headers,
                            timeout=timeout, verify=verify, stream=stream, allow_redirects=allow_redirects)
        rsp.encoding = 'utf-8'
        return rsp

    def postJson(self, url, json, headers=None, cookies=None):
        rsp = _host.request('POST', url, json=json, headers=headers, cookies=cookies, timeout=10)
        rsp.encoding = 'utf-8'
        return rsp

    def _clean_header_value(self, value):
        cleaned = str(value).strip()
        if cleaned.startswith("<!DOCTYPE html>"):
            cleaned = "DefaultValue"
        return cleaned

    def getProxyUrl(self, local=True, param=None):
        """The engine's proxy for this spider: requests to it come back to localProxy(params).

        Spiders append their own parameters (`getProxyUrl() + '&url=...'`); newer ones pass them as a dict.
        """
        url = '%s?do=py' % _host.proxy_base()
        key = getattr(self, 'siteKey', '')
        if key:
            url += '&siteKey=' + _host.quote(str(key))
        extra = local if isinstance(local, dict) else param
        if isinstance(extra, dict) and extra:
            url += '&' + _host.urlencode([(k, v) for k, v in extra.items() if v is not None])
        return url

    def log(self, msg):
        if isinstance(msg, (dict, list)):
            print(json.dumps(msg, ensure_ascii=False))
        else:
            print('%s' % (msg,))

    # ---- a small persistent store (TVBox: the local server's /cache) ----

    def getCache(self, key):
        value = _host.cache_get(key)
        if value is None or value == '':
            return None
        if isinstance(value, str) and ((value.startswith('{') and value.endswith('}')) or (value.startswith('[') and value.endswith(']'))):
            try:
                value = json.loads(value)
            except ValueError:
                return value
            if isinstance(value, dict) and 'expiresAt' in value and value['expiresAt'] < int(time.time()):
                self.delCache(key)
                return None
        return value

    def setCache(self, key, value):
        if isinstance(value, (int, float)):
            value = str(value)
        if isinstance(value, (dict, list)):
            value = json.dumps(value, ensure_ascii=False)
        if value is None or len(value) == 0:
            return 'failed'
        _host.cache_set(key, value)
        return 'succeed'

    def delCache(self, key):
        _host.cache_del(key)
        return 'succeed'
