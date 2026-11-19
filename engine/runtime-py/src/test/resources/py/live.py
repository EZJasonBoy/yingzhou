# -*- coding: utf-8 -*-
# Test live spider: an M3U list with a direct channel, one through getProxyUrl and one through proxy://.
from base.spider import Spider


class Spider(Spider):
    def init(self, extend=''):
        self.ext = extend

    def liveContent(self, url):
        return '\n'.join([
            '#EXTM3U',
            '#EXTINF:-1 group-title="Py",直连台',
            'http://media.test/direct.m3u8',
            '#EXTINF:-1 group-title="Py",代理台',
            self.getProxyUrl() + '&ch=a',
            '#EXTINF:-1 group-title="Py",协议台',
            'proxy://do=py&ch=b',
        ])

    def localProxy(self, param):
        return [302, 'text/plain', '', {'Location': 'http://media.test/%s.m3u8' % param.get('ch')}]
