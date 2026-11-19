# -*- coding: utf-8 -*-
# Test spider that misbehaves on purpose: homeContent kills the whole Python process, categoryContent hangs,
# searchContent raises. detailContent works, to show the worker (or its replacement) is still usable.
import os
import time

from base.spider import Spider


class Spider(Spider):
    def init(self, extend=''):
        pass

    def homeContent(self, filter):
        os._exit(3)

    def categoryContent(self, tid, pg, filter, extend):
        time.sleep(20)
        return {'list': []}

    def searchContent(self, key, quick, pg='1'):
        raise KeyError('the site changed its page')

    def detailContent(self, ids):
        return {'list': [{'vod_id': ids[0], 'vod_name': 'still here', 'vod_play_from': 'a', 'vod_play_url': '1$http://x.test/1.mp4'}]}
