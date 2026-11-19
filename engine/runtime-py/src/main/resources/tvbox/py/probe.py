# -*- coding: utf-8 -*-
"""Tells the engine about a Python: version, where it is, whether pip is there, which modules it can import.

Usage: python -E -X utf8 probe.py [--packages <dir>]... [module]...
Prints one line of JSON. Modules are looked up, not imported (nothing of a package runs).
"""

import json
import os
import platform
import sys
import sysconfig


def main(argv):
    packages, modules = [], []
    i = 0
    while i < len(argv):
        if argv[i] == '--packages' and i + 1 < len(argv):
            packages.append(argv[i + 1])
            i += 2
        else:
            modules.append(argv[i])
            i += 1
    for p in reversed(packages):
        sys.path.insert(0, p)
    import importlib.util

    found = {}
    for name in modules:
        try:
            spec = importlib.util.find_spec(name)
        except (ImportError, ValueError):
            spec = None
        origin = ''
        if spec is not None:
            origin = spec.origin or (list(spec.submodule_search_locations or [''])[0])
        found[name] = origin if spec is not None else None
    try:
        pip = importlib.util.find_spec('pip') is not None
    except (ImportError, ValueError):
        pip = False
    impl = sys.implementation.name
    short = {'cpython': 'cp', 'pypy': 'pp'}.get(impl, impl)
    plat = sysconfig.get_platform()
    if plat.startswith('macosx-'):
        plat = 'macosx-' + plat.rsplit('-', 1)[-1]
    tag = '%s%d%d-%s' % (short, sys.version_info[0], sys.version_info[1], plat.replace('-', '_').replace('.', '_'))
    print(json.dumps({
        'version': list(sys.version_info[:3]),
        'executable': sys.executable,
        'implementation': impl,
        'platform': sys.platform,
        'machine': platform.machine(),
        'tag': tag,
        'pip': pip,
        'embedded': any(f.endswith('._pth') for f in os.listdir(os.path.dirname(sys.executable) or '.')),
        'modules': found,
    }))


if __name__ == '__main__':
    main(sys.argv[1:])
