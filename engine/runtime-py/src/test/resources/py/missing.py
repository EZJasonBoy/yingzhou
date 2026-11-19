# -*- coding: utf-8 -*-
# Test spider that imports a package nobody has.
import yingzhou_no_such_package

from base.spider import Spider


class Spider(Spider):
    def init(self, extend=''):
        pass

    def homeContent(self, filter):
        return {'list': []}
