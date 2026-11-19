#!/usr/bin/env bash
# Builds a self-contained desktop package: the Flutter client plus the engine and a trimmed Java runtime.
#
#   tools/package-desktop.sh     # Windows (Git Bash): dist/yingzhou-windows-x64.zip
#                                #                     dist/yingzhou-windows-x64-setup.exe (when Inno Setup is installed)
#                                # macOS:             dist/yingzhou-macos-<arm64|x86_64>.dmg
#
# Needs JDK 21 (JAVA_HOME) and Flutter; on Windows Visual Studio with the C++ desktop workload, on macOS Xcode.
# The Windows installer (tools/installer/windows.iss) also needs Inno Setup 6.3 or newer; without it only the zip is built.
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

# The whole of Java SE rather than what `jdeps` finds in the engine: spider jars are other people's code and use
# what they like. On top of it: jdk.zipfs (dex conversion opens jars through it, by name, so jdeps does not see it —
# without it every jar spider fails with "cant find zipfs support"), charsets (GBK sites), EC and PKCS11 crypto (TLS),
# sun.misc.Unsafe, the JDK http server and DNS lookups.
modules=java.se,jdk.unsupported,jdk.zipfs,jdk.charsets,jdk.crypto.ec,jdk.crypto.cryptoki,jdk.httpserver,jdk.naming.dns,jdk.net,jdk.xml.dom,jdk.management

echo "== engine"
(cd "$root/engine" && ./gradlew :server:installDist --console=plain -q)

echo "== java runtime"
jre="$root/engine/server/build/jre"
rm -rf "$jre"
"$JAVA_HOME/bin/jlink" --add-modules "$modules" --strip-debug --no-header-files --no-man-pages \
  --compress zip-6 --output "$jre"

echo "== self-test (demo sites on the packaged runtime)"
# The package is only good if the trimmed runtime runs every kind of site: CMS, JS spider, jar spider, sniffing, live.
cp="$root/engine/server/build/install/tvbox-engine/lib/*"
[ "$os" = windows ] && cp="$(cygpath -w "$root/engine/server/build/install/tvbox-engine/lib")\\*"
"$jre/bin/java" -Xss1m -XX:+UnlockDiagnosticVMOptions -XX:-BytecodeVerificationRemote -Dstdout.encoding=UTF-8 \
  -cp "$cp" tvbox.engine.server.MainKt --demo --check --play --strict \
  || { echo "the packaged runtime failed the self-test; not packaging" >&2; exit 1; }

mkdir -p "$root/dist"

if [ "$os" = windows ]; then
  echo "== client"
  (cd "$root/client" && flutter build windows --release)

  out="$root/client/build/windows/x64/runner/Release"
  rm -rf "$out/engine"
  mkdir -p "$out/engine"
  cp -r "$root/engine/server/build/install/tvbox-engine/lib" "$out/engine/lib"
  cp -r "$jre" "$out/engine/jre"
  cp "$root/LICENSE" "$out/LICENSE.txt"
  cp "$root/THIRD-PARTY-NOTICES.md" "$out/"

  echo "== zip"
  zip="$root/dist/yingzhou-windows-x64.zip"
  rm -f "$zip"
  powershell.exe -NoProfile -Command "Compress-Archive -Path '$(cygpath -w "$out")\\*' -DestinationPath '$(cygpath -w "$zip")'"
  echo "done: $zip ($(du -h "$zip" | cut -f1)), folder: $out ($(du -sh "$out" | cut -f1))"

  echo "== installer"
  # Inno Setup's compiler: $ISCC, or on PATH (scoop install inno-setup), or where its own installer puts it.
  iscc="${ISCC:-$(command -v iscc || true)}"
  for dir in "/c/Program Files (x86)/Inno Setup 6" "/c/Program Files/Inno Setup 7" "/c/Program Files (x86)/Inno Setup 7"; do
    [ -z "$iscc" ] && [ -f "$dir/ISCC.exe" ] && iscc="$dir/ISCC.exe"
  done
  if [ -z "$iscc" ]; then
    echo "skipped: Inno Setup (ISCC.exe) not found; the zip above is complete without it"
    exit 0
  fi
  setup="$root/dist/yingzhou-windows-x64-setup.exe"
  log="$root/dist/installer.log"
  rm -f "$setup"
  "$iscc" "$(cygpath -w "$root/tools/installer/windows.iss")" >"$log" 2>&1 \
    || { tail -n 30 "$log" >&2; echo "the installer did not build; full output in $log" >&2; exit 1; }
  echo "done: $setup ($(du -h "$setup" | cut -f1))"
  exit 0
fi

echo "== client"
(cd "$root/client" && flutter build macos --release)
app="$root/client/build/macos/Build/Products/Release/Yingzhou.app"
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
dmg="$root/dist/yingzhou-macos-$arch.dmg"
rm -f "$dmg"
hdiutil create -volname "Yingzhou" -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null
echo "done: $dmg ($(du -h "$dmg" | cut -f1))"
if [ "$identity" = "-" ]; then
  echo "note: ad-hoc signed; a downloaded copy needs right-click > Open the first time (or: xattr -dr com.apple.quarantine \"/Applications/Yingzhou.app\")"
fi
