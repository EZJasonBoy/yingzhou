# -*- coding: utf-8 -*-
# The demo engine's Python VOD site (演示Python站): written like a TVBox Python spider, with nothing but the standard
# library and base.spider. Its catalogue is made up; the video is the demo's public HLS test stream.
#
# Each title has two lines:
#   直连  playerContent gives the stream's address;
#   代理  playerContent gives this spider's proxy address (getProxyUrl); the player's request comes back to
#         localProxy, which fetches the playlist, makes its addresses absolute and serves it.
import json
import sys
from urllib.parse import quote, urljoin

sys.path.append('..')
from base.spider import Spider

CLASSES = [('1', '电影'), ('2', '剧集')]
TITLES = ['蟒山奇谈', '青蟒传', '绿洲来信', '白蛇新传', '蟒河往事', '山海蟒影', '长河夜渡', '雾港蛇影', '竹林来客', '夜航船']


class Spider(Spider):
    def getName(self):
        return '演示Python站'

    def init(self, extend=''):
        try:
            self.conf = json.loads(extend) if extend else {}
        except ValueError:
            self.conf = {}
        self.stream = self.conf.get('stream', '')

    def _vod(self, i):
        return {
            'vod_id': str(i),
            'vod_name': TITLES[i % len(TITLES)],
            'vod_pic': '%s%d.png' % (self.conf.get('poster', ''), 200 + i),
            'vod_remarks': '电影' if i % 2 == 0 else '全%d集' % (3 + i % 4),
            'type_id': '1' if i % 2 == 0 else '2',
        }

    def homeContent(self, filter):
        return {
            'class': [{'type_id': t, 'type_name': n} for t, n in CLASSES],
            'list': [self._vod(i) for i in range(4)],
        }

    def homeVideoContent(self):
        return {'list': [self._vod(i) for i in range(4)]}

    def categoryContent(self, tid, pg, filter, extend):
        items = [self._vod(i) for i in range(len(TITLES)) if self._vod(i)['type_id'] == tid]
        return {'page': int(pg), 'pagecount': 1, 'limit': len(items), 'total': len(items), 'list': items}

    def detailContent(self, ids):
        i = int(ids[0])
        vod = self._vod(i)
        count = 1 if vod['type_id'] == '1' else 3 + i % 4
        episodes = '#'.join('第%d集$%d_%d' % (n + 1, i, n + 1) for n in range(count))
        vod.update({
            'vod_year': str(2020 + i % 6),
            'vod_area': '演示',
            'vod_actor': '蟒蛇',
            'vod_director': 'Python',
            'vod_content': '演示Python站的第 %d 部。两条线路：直连，以及经蜘蛛自己的代理（localProxy）。' % (i + 1),
            'vod_play_from': '直连$$$代理',
            'vod_play_url': episodes + '$$$' + episodes,
        })
        return {'list': [vod]}

    def searchContent(self, key, quick, pg='1'):
        return {'list': [self._vod(i) for i in range(len(TITLES)) if key in TITLES[i]], 'page': int(pg)}

    def playerContent(self, flag, id, vipFlags):
        if flag == '代理':
            return {'parse': 0, 'url': self.getProxyUrl() + '&type=m3u8&id=' + quote(id)}
        return {'parse': 0, 'url': self.stream}

    def localProxy(self, param):
        if param.get('type') != 'm3u8':
            return [404, 'text/plain', 'unknown request']
        text = self.fetch(self.stream).text
        lines = []
        for line in text.splitlines():
            line = line.strip()
            lines.append(line if not line or line.startswith('#') else urljoin(self.stream, line))
        return [200, 'application/vnd.apple.mpegurl', '\n'.join(lines) + '\n']
