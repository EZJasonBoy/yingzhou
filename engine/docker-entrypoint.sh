#!/bin/sh
# Starts the engine in the container: LAN sharing on (--lan, listening on 0.0.0.0), data in /data. The pairing code
# is printed in the log (`docker logs`). Arguments given to the container are passed on to the engine.
#
#   TVBOX_PORT      port inside the container (default 9978)
#   TVBOX_NAME      the name other devices see (default 映舟引擎（Docker）)
#   TVBOX_MAX_HEAP  Java heap limit (default 1g)
#   JAVA_OPTS       further JVM options
set -eu

# The same JVM options as the desktop app's engine (client/lib/engine/local_engine_io.dart). Spider classes
# converted from dex do not always pass the JVM verifier; Android does not verify them either.
# shellcheck disable=SC2086
exec /opt/yingzhou/jre/bin/java \
  -Xss1m -XX:+UseSerialGC -Xms16m -Xmx"${TVBOX_MAX_HEAP:-1g}" -XX:MinHeapFreeRatio=10 -XX:MaxHeapFreeRatio=30 \
  -XX:+UnlockDiagnosticVMOptions -XX:-BytecodeVerificationRemote \
  -Dfile.encoding=UTF-8 -Dstdout.encoding=UTF-8 -Dstderr.encoding=UTF-8 \
  ${JAVA_OPTS:-} \
  -cp '/opt/yingzhou/lib/*' tvbox.engine.server.MainKt \
  --lan --port "${TVBOX_PORT:-9978}" --data /data --name "${TVBOX_NAME:-映舟引擎（Docker）}" "$@"
