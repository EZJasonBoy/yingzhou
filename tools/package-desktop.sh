#!/usr/bin/env bash
# Builds a self-contained desktop package: the Flutter client plus the engine and a trimmed Java runtime.
#
#   tools/package-desktop.sh            # Windows (Git Bash), output: dist/tvbox-next-windows-x64.zip
#
# Needs JDK 21 (JAVA_HOME), Flutter, and on Windows Visual Studio with the C++ desktop workload.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) os=windows ;;
  Darwin) os=macos ;;
  *) os=linux ;;
esac
[ "$os" = windows ] || { echo "only Windows packaging is wired up so far" >&2; exit 1; }

# Modules from `jdeps --print-module-deps` on the engine, plus charsets (GBK sites), EC crypto (TLS) and logging.
modules=java.base,java.compiler,java.desktop,java.instrument,java.logging,java.management,java.naming,java.net.http,java.sql,java.xml,jdk.charsets,jdk.crypto.ec,jdk.unsupported

echo "== engine"
(cd "$root/engine" && ./gradlew :server:installDist --console=plain -q)

echo "== java runtime"
jre="$root/engine/server/build/jre"
rm -rf "$jre"
"$JAVA_HOME/bin/jlink" --add-modules "$modules" --strip-debug --no-header-files --no-man-pages \
  --compress zip-6 --output "$jre"

echo "== client"
(cd "$root/client" && flutter build windows --release)

out="$root/client/build/windows/x64/runner/Release"
rm -rf "$out/engine"
mkdir -p "$out/engine"
cp -r "$root/engine/server/build/install/tvbox-engine/lib" "$out/engine/lib"
cp -r "$jre" "$out/engine/jre"

echo "== zip"
mkdir -p "$root/dist"
zip="$root/dist/tvbox-next-windows-x64.zip"
rm -f "$zip"
powershell.exe -NoProfile -Command "Compress-Archive -Path '$(cygpath -w "$out")\\*' -DestinationPath '$(cygpath -w "$zip")'"
echo "done: $zip ($(du -h "$zip" | cut -f1)), folder: $out ($(du -sh "$out" | cut -f1))"
