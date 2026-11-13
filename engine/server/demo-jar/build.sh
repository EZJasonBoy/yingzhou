#!/usr/bin/env bash
# Builds the demo spider jar (a zip with classes.dex, like real TVBox spider jars) into the server's resources.
# Needs JDK 17+ and the Android SDK (platforms;android-36 and build-tools;36.0.0).
set -euo pipefail
cd "$(dirname "$0")"
SDK="${ANDROID_HOME:?set ANDROID_HOME}"
ANDROID_JAR="$SDK/platforms/android-36/android.jar"
D8="$SDK/build-tools/36.0.0/lib/d8.jar"
OUT=../src/main/resources/demo
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

sep=":"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) sep=";"; ANDROID_JAR=$(cygpath -w "$ANDROID_JAR"); D8=$(cygpath -w "$D8");;
esac
javac --release 11 -nowarn -cp "$ANDROID_JAR${sep}stubs" -d "$work/classes" $(find src -name '*.java')
# Only the spider's own classes go into the dex; host classes come from the app.
java -cp "$D8" com.android.tools.r8.D8 --release --min-api 21 --lib "$ANDROID_JAR" --output "$work" $(find "$work/classes" -name '*.class')
mkdir -p "$OUT"
(cd "$work" && jar cf spider.jar classes.dex)
cp "$work/spider.jar" "$OUT/spider.jar"
echo "wrote $OUT/spider.jar"
