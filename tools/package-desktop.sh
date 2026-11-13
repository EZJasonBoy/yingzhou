#!/usr/bin/env bash
# Builds a self-contained desktop package: the Flutter client plus the engine and a trimmed Java runtime.
#
#   tools/package-desktop.sh     # Windows (Git Bash): dist/tvbox-next-windows-x64.zip
#                                # macOS:             dist/tvbox-next-macos-<arm64|x86_64>.dmg
#
# Needs JDK 21 (JAVA_HOME) and Flutter; on Windows Visual Studio with the C++ desktop workload, on macOS Xcode.
# The Java runtime is jlinked from the JDK running the build, so a macOS package only runs on that CPU type
# (build on Apple Silicon for arm64, on an Intel Mac or `macos-13` CI runner for x86_64).
# macOS signing: ad-hoc by default; set SIGN_IDENTITY="Developer ID Application: ..." to sign for notarization.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) os=windows ;;
  Darwin) os=macos ;;
  *) os=linux ;;
esac
[ "$os" = linux ] && { echo "Linux packaging is not wired up yet" >&2; exit 1; }

# Modules from `jdeps --print-module-deps` on the engine, plus charsets (GBK sites), EC crypto (TLS) and logging.
modules=java.base,java.compiler,java.desktop,java.instrument,java.logging,java.management,java.naming,java.net.http,java.sql,java.xml,jdk.charsets,jdk.crypto.ec,jdk.unsupported

echo "== engine"
(cd "$root/engine" && ./gradlew :server:installDist --console=plain -q)

echo "== java runtime"
jre="$root/engine/server/build/jre"
rm -rf "$jre"
"$JAVA_HOME/bin/jlink" --add-modules "$modules" --strip-debug --no-header-files --no-man-pages \
  --compress zip-6 --output "$jre"

mkdir -p "$root/dist"

if [ "$os" = windows ]; then
  echo "== client"
  (cd "$root/client" && flutter build windows --release)

  out="$root/client/build/windows/x64/runner/Release"
  rm -rf "$out/engine"
  mkdir -p "$out/engine"
  cp -r "$root/engine/server/build/install/tvbox-engine/lib" "$out/engine/lib"
  cp -r "$jre" "$out/engine/jre"

  echo "== zip"
  zip="$root/dist/tvbox-next-windows-x64.zip"
  rm -f "$zip"
  powershell.exe -NoProfile -Command "Compress-Archive -Path '$(cygpath -w "$out")\\*' -DestinationPath '$(cygpath -w "$zip")'"
  echo "done: $zip ($(du -h "$zip" | cut -f1)), folder: $out ($(du -sh "$out" | cut -f1))"
  exit 0
fi

echo "== client"
(cd "$root/client" && flutter build macos --release)
app="$root/client/build/macos/Build/Products/Release/TVBox Next.app"
# The client looks for the engine in Contents/Resources/engine (see lib/engine/local_engine_io.dart).
res="$app/Contents/Resources/engine"
rm -rf "$res"
mkdir -p "$res"
cp -R "$root/engine/server/build/install/tvbox-engine/lib" "$res/lib"
cp -R "$jre" "$res/jre"

echo "== sign"
identity="${SIGN_IDENTITY:--}"
entitlements="$root/client/macos/Runner/Release.entitlements"
# Every Mach-O in the runtime, then the app (adding files invalidated Flutter's signature).
find "$res/jre" -type f \( -name '*.dylib' -o -perm -u+x \) -print0 |
  xargs -0 -I{} codesign --force --timestamp=none --options runtime --entitlements "$entitlements" --sign "$identity" "{}"
codesign --force --deep --timestamp=none --options runtime --entitlements "$entitlements" --sign "$identity" "$app"
codesign --verify --deep --strict "$app"

echo "== dmg"
arch="$(uname -m)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
dmg="$root/dist/tvbox-next-macos-$arch.dmg"
rm -f "$dmg"
hdiutil create -volname "TVBox Next" -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null
echo "done: $dmg ($(du -h "$dmg" | cut -f1))"
if [ "$identity" = "-" ]; then
  echo "note: ad-hoc signed; a downloaded copy needs right-click > Open the first time (or: xattr -dr com.apple.quarantine \"/Applications/TVBox Next.app\")"
fi
