# -*- coding: utf-8 -*-
# base.localProxy: where the engine's proxy is (TVBox: com.github.catvod.Proxy). Spiders call these as
# Proxy.getUrl(self, local) and Proxy.getPort(self).

from base import _host


class Proxy:
    def getUrl(*args):
        """The engine's /proxy address, e.g. http://127.0.0.1:9978/proxy."""
        return _host.proxy_base()

    def getPort(*args):
        return _host.proxy_port()
