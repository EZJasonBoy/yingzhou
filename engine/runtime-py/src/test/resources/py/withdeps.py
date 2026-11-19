# -*- coding: utf-8 -*-
# Test spider with a dependency (TVBox getDependence): init() gets the loaded helper spider instead of the ext.
from base.spider import Spider


class Spider(Spider):
    def getDependence(self):
        return ['helper']

    def init(self, extend=''):
        self.helper = extend[0] if isinstance(extend, list) and extend else None

    def homeContent(self, filter):
        return {'class': [{'type_id': '1', 'type_name': self.helper.greeting() if self.helper else 'no helper'}], 'list': []}
