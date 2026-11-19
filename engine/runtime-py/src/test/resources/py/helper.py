# -*- coding: utf-8 -*-
# The dependency of withdeps.py, found next to it.
from base.spider import Spider


class Spider(Spider):
    def init(self, extend=''):
        pass

    def greeting(self):
        return 'helper says hi, extend=%s' % self.extend
