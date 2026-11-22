#!/bin/bash
set -euo pipefail

module_dir="$(cd "$(dirname "$0")/../lab/engine-go" && pwd)"
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/local/go/bin"
command -v go >/dev/null || { echo "Install Go to build the iOS engine." >&2; exit 1; }
case "$PLATFORM_NAME" in
  iphoneos) platform_suffix='' ;;
  iphonesimulator) platform_suffix='-simulator' ;;
  *) echo "Unsupported Xcode SDK: $PLATFORM_NAME" >&2; exit 1 ;;
esac

export SDKROOT="$(xcrun --sdk "$PLATFORM_NAME" --show-sdk-path)"
cd "$module_dir"
archives=()
for arch in $ARCHS; do
  case "$arch" in
    arm64) go_arch=arm64 ;;
    x86_64) go_arch=amd64 ;;
    *) echo "Unsupported iOS CPU: $arch" >&2; exit 1 ;;
  esac
  archive_dir="$DERIVED_FILE_DIR/yingzhou-go/$PLATFORM_NAME/$arch"
  mkdir -p "$archive_dir"
  target="$arch-apple-ios${IPHONEOS_DEPLOYMENT_TARGET:?}$platform_suffix"
  GOOS=ios GOARCH="$go_arch" CGO_ENABLED=1 CC="xcrun --sdk $PLATFORM_NAME clang -target $target" \
    go build -trimpath -buildvcs=false -buildmode=c-archive -ldflags='-s -w' -o "$archive_dir/engine.a" .
  archives+=("$archive_dir/engine.a")
done
if [[ ${#archives[@]} -eq 1 ]]; then
  cp "${archives[0]}" "$DERIVED_FILE_DIR/libYingzhouGo.a"
else
  xcrun lipo -create "${archives[@]}" -output "$DERIVED_FILE_DIR/libYingzhouGo.a"
fi
