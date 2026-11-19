# syntax=docker/dockerfile:1.7
#
# The Yingzhou (映舟) engine for a NAS or server: LAN sharing on, pairing codes in the log, data in /data.
#
#   cd engine
#   docker build -t yingzhou-engine .                                   # this machine's CPU
#   docker buildx build --platform linux/amd64,linux/arm64 -t ... .     # both
#   docker build --build-arg WITH_CHROMIUM=false -t yingzhou-engine .   # no web page sniffing, about half the size
#
# Stages: the engine is compiled once on the build machine's own CPU (bytecode is the same everywhere); the trimmed
# Java runtime is made by jlink of the target CPU's JDK (a jlinked runtime only runs on the CPU it was made for); the
# final image is Debian slim with that runtime, the engine's jars and, by default, Chromium for sniffing.
#
# The image has not been built or run on the machine this file was written on (no Docker there); see
# docs/development.md section 12 for what was checked and how CI builds it.

ARG JDK_IMAGE=eclipse-temurin:21-jdk
ARG BASE_IMAGE=debian:bookworm-slim

# ---- 1. compile (build machine's CPU) ----
FROM --platform=$BUILDPLATFORM ${JDK_IMAGE} AS build
WORKDIR /src
# Gradle and its wrapper first, so a change in the sources does not download Gradle again.
COPY gradlew settings.gradle.kts build.gradle.kts ./
COPY gradle gradle
RUN chmod +x gradlew && ./gradlew --version --no-daemon --console=plain -q
COPY core core
COPY api api
COPY server server
COPY runtime-js runtime-js
COPY runtime-jar runtime-jar
COPY jar-host jar-host
RUN --mount=type=cache,target=/root/.gradle/caches \
    ./gradlew :server:installDist --no-daemon --console=plain -q \
    && cp -r server/build/install/tvbox-engine/lib /engine-lib

# ---- 2. trimmed Java runtime (target CPU) ----
FROM ${JDK_IMAGE} AS jre
# Same module list as tools/package-desktop.sh (see the comment there): the whole of Java SE because spider jars
# are other people's code, plus jdk.zipfs (dex conversion opens jars through it by name), charsets, crypto, ...
ARG JRE_MODULES=java.se,jdk.unsupported,jdk.zipfs,jdk.charsets,jdk.crypto.ec,jdk.crypto.cryptoki,jdk.httpserver,jdk.naming.dns,jdk.net,jdk.xml.dom,jdk.management
RUN jlink --add-modules "$JRE_MODULES" --strip-debug --no-header-files --no-man-pages --compress zip-6 --output /jre

# ---- 3. the image ----
FROM ${BASE_IMAGE}
ARG WITH_CHROMIUM=true
# tini reaps the browser's child processes and passes SIGTERM on, so `docker stop` ends the engine cleanly.
# curl is for the health check. Chromium (headless) sniffs videos out of web pages, as Edge/Chrome do on desktop.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl tini tzdata \
    && if [ "$WITH_CHROMIUM" = "true" ]; then apt-get install -y --no-install-recommends chromium fonts-liberation; fi \
    && rm -rf /var/lib/apt/lists/*

# A fixed non-root user; a named volume mounted on /data takes the directory's owner.
RUN groupadd --system --gid 10001 yingzhou \
    && useradd --system --uid 10001 --gid yingzhou --home-dir /data --shell /usr/sbin/nologin yingzhou \
    && mkdir -p /data \
    && chown yingzhou:yingzhou /data

COPY --from=jre /jre /opt/yingzhou/jre
COPY --from=build /engine-lib /opt/yingzhou/lib
COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin/yingzhou-engine
# Chromium with the flags a container needs (no sandbox, no reliance on /dev/shm). Without Chromium the engine finds
# no browser and reports sniffing as unavailable.
COPY --chmod=0755 docker-chromium.sh /usr/local/bin/yingzhou-chromium
RUN if [ "$WITH_CHROMIUM" != "true" ]; then rm /usr/local/bin/yingzhou-chromium; fi

ENV LANG=C.UTF-8 \
    TZ=Asia/Shanghai \
    HOME=/data \
    TVBOX_PORT=9978 \
    TVBOX_BROWSER=/usr/local/bin/yingzhou-chromium

USER 10001:10001
WORKDIR /data
VOLUME ["/data"]
EXPOSE 9978/tcp

# /api/v1/info needs no token, and the check comes from inside the container (loopback) anyway.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${TVBOX_PORT}/api/v1/info" >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/yingzhou-engine"]
