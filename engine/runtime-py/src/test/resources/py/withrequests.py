# -*- coding: utf-8 -*-
# Test spider that uses `requests` directly (only run where requests is installed).
import json

import requests

from base.spider import Spider


class Spider(Spider):
    def init(self, extend=''):
        self.conf = json.loads(extend)

    def homeContent(self, filter):
        data = requests.get(self.conf['api'] + '?ac=home', headers={'X-Spider': 'requests'}, timeout=5).json()
        return {'class': [], 'list': data['list']}
