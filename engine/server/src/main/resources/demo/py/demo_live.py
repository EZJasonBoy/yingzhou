# -*- coding: utf-8 -*-
# The demo engine's Python live source (演示Python直播): liveContent answers with a TXT channel list. The three
# channels name their address the three ways spiders do: as it is, through this spider's proxy (getProxyUrl), and
# with TVBox's proxy://. The last two only play when the request comes back to this spider, whose localProxy sends
# the player on to the stream.
import json
import sys

sys.path.append('..')
from base.spider import Spider


class Spider(Spider):
    def getName(self):
        return '演示Python直播'

    def init(self, extend=''):
        try:
            self.conf = json.loads(extend) if extend else {}
        except ValueError:
            self.conf = {}

    def liveContent(self, url):
        group = self.conf.get('group', 'Python')
        return '\n'.join([
            group + ',#genre#',
            'Python 直连台,' + self.conf.get('direct', ''),
            'Python 代理台,' + self.getProxyUrl() + '&ch=bipbop',
            'Python 协议台,proxy://do=py&ch=live',
        ])

    def localProxy(self, param):
        to = {'bipbop': self.conf.get('bipbop'), 'live': self.conf.get('live')}.get(param.get('ch'))
        if not to:
            return [404, 'text/plain', 'no such channel']
        return [302, 'text/plain', '', {'Location': to}]
