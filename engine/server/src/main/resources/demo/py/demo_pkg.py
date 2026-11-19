# -*- coding: utf-8 -*-
# The demo engine's Python site that needs a third-party package (演示Python依赖站): it parses HTML with lxml, as
# many real spiders do. Where lxml is not installed, opening it shows what is missing and the 「Python 蜘蛛」
# settings offer to install it; once installed, it lists three titles.
import json
import sys

from lxml import etree

sys.path.append('..')
from base.spider import Spider

PAGE = '''
<ul class="list">
  <li data-id="1"><a>依赖演示一</a></li>
  <li data-id="2"><a>依赖演示二</a></li>
  <li data-id="3"><a>依赖演示三</a></li>
</ul>
'''


class Spider(Spider):
    def getName(self):
        return '演示Python依赖站'

    def init(self, extend=''):
        try:
            self.conf = json.loads(extend) if extend else {}
        except ValueError:
            self.conf = {}

    def _list(self):
        root = etree.HTML(PAGE)
        return [{
            'vod_id': li.get('data-id'),
            'vod_name': li.xpath('./a/text()')[0],
            'vod_pic': '%s%s.png' % (self.conf.get('poster', ''), 300 + int(li.get('data-id'))),
            'vod_remarks': 'lxml',
        } for li in root.xpath('//li')]

    def homeContent(self, filter):
        return {'class': [{'type_id': '1', 'type_name': '依赖演示'}], 'list': self._list()}

    def categoryContent(self, tid, pg, filter, extend):
        items = self._list()
        return {'page': 1, 'pagecount': 1, 'limit': len(items), 'total': len(items), 'list': items}

    def detailContent(self, ids):
        vod = next((v for v in self._list() if v['vod_id'] == ids[0]), None)
        if vod is None:
            return {'list': []}
        vod.update({'vod_content': '列表由 lxml 解析。', 'vod_play_from': '直连', 'vod_play_url': '正片$' + vod['vod_id']})
        return {'list': [vod]}

    def playerContent(self, flag, id, vipFlags):
        return {'parse': 0, 'url': self.conf.get('stream', '')}
