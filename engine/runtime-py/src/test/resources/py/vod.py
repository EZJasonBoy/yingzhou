# -*- coding: utf-8 -*-
# Test spider: a VOD site whose catalogue comes from an HTTP API named in its ext (to check the engine's network
# rules reach Python), with a proxied line, a dependency-free localProxy and a log line.
import json
import sys

sys.path.append('..')
from base.spider import Spider


class Spider(Spider):
    def init(self, extend=''):
        self.conf = json.loads(extend) if extend else {}
        print('hello from python, ext keys: %s' % ','.join(sorted(self.conf.keys())))

    def homeContent(self, filter):
        data = self.fetch(self.conf['api'] + '?ac=home').json()
        return {'class': [{'type_id': '1', 'type_name': '电影'}], 'list': data['list'], 'filter_seen': filter}

    def homeVideoContent(self):
        return {'list': []}

    def categoryContent(self, tid, pg, filter, extend):
        return {'page': int(pg), 'pagecount': 3, 'list': [{'vod_id': 'c%s-%s-%s' % (tid, pg, extend.get('year', '')), 'vod_name': '分类片'}]}

    def detailContent(self, ids):
        return {'list': [{
            'vod_id': ids[0],
            'vod_name': '详情 ' + ids[0],
            'vod_play_from': '直连$$$代理',
            'vod_play_url': '第1集$e1#第2集$e2$$$第1集$e1',
        }]}

    def searchContent(self, key, quick, pg='1'):
        return {'list': [{'vod_id': 's1', 'vod_name': key + ' 搜索结果'}], 'page': int(pg)}

    def playerContent(self, flag, id, vipFlags):
        if flag == '代理':
            return {'parse': 0, 'url': self.getProxyUrl() + '&id=' + id}
        return {'parse': 0, 'url': 'http://media.test/%s.mp4' % id, 'header': {'Referer': 'http://media.test/'}}

    def localProxy(self, param):
        body = ('proxied %s by %s' % (param.get('id'), param.get('siteKey'))).encode('utf-8')
        return [200, 'video/mp2t', body, {'X-Spider': 'vod'}]
