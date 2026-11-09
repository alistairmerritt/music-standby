#!/bin/bash
# Builds StandByProtocol and runs its tests.
#
# With a working Xcode selected this is just `swift test`. Otherwise it compiles
# with the Command Line Tools' swiftc directly, because SwiftPM cannot link
# package manifests with the damaged tools on the authoring Mac ("redefinition
# of module 'SwiftBridging'"). The overlay below hides the duplicate module map.
# FORCE_SWIFTC=1 takes the swiftc path even when Xcode works.
set -euo pipefail

pkg=$(cd "$(dirname "$0")/.." && pwd)
developer=$(xcode-select -p)

# `xcrun --find` fails while Xcode's licence is unaccepted, as well as when
# Xcode is missing.
if [[ "$developer" != *CommandLineTools* && "${FORCE_SWIFTC:-0}" != 1 ]] && xcrun --find swift >/dev/null 2>&1; then
  cd "$pkg" && exec swift test
fi

clt=/Library/Developer/CommandLineTools
export DEVELOPER_DIR=$clt
sdk=${SDK:-$(ls -d "$clt"/SDKs/MacOSX[0-9]*.sdk | sort -V | tail -1)}
build="$pkg/.build/swiftc"
mkdir -p "$build"

: > "$build/empty.modulemap"
cat > "$build/overlay.yaml" <<YAML
{ "version": 0, "case-sensitive": "false", "roots": [ { "type": "file",
  "name": "$clt/usr/include/swift/module.modulemap",
  "external-contents": "$build/empty.modulemap" } ] }
YAML

common=(-sdk "$sdk" -target "$(uname -m)-apple-macos14.0" -swift-version 6
        -vfsoverlay "$build/overlay.yaml" -Xcc -ivfsoverlay -Xcc "$build/overlay.yaml")
frameworks=$clt/Library/Developer/Frameworks

echo "› compiling StandByProtocol ($(basename "$sdk"))"
swiftc "${common[@]}" -parse-as-library -enable-testing -module-name StandByProtocol \
  -emit-library -static -emit-module -emit-module-path "$build/StandByProtocol.swiftmodule" \
  "$pkg"/Sources/StandByProtocol/*.swift -o "$build/libStandByProtocol.a"

echo "› compiling tests"
swiftc "${common[@]}" -parse-as-library -module-name StandByProtocolTests \
  -Xfrontend -disable-cross-import-overlays \
  -plugin-path "$clt/usr/lib/swift/host/plugins/testing" \
  -F "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" \
  -I "$build" -L "$build" -lStandByProtocol \
  "$pkg"/Tests/StandByProtocolTests/*.swift "$pkg/scripts/TestMain.swift" -o "$build/StandByProtocolTests"

echo "› running tests"
exec "$build/StandByProtocolTests" "$@"
