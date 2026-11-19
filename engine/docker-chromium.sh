#!/bin/sh
# The browser the engine sniffs with inside the container (TVBOX_BROWSER points here). A container gives Chromium no
# user namespaces for its sandbox, and Docker's /dev/shm is only 64 MB by default.
exec /usr/bin/chromium --no-sandbox --disable-dev-shm-usage "$@"
