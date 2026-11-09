#!/bin/bash
# Builds the Mac companion with swiftc, without SwiftPM or an Xcode project.
#
#   scripts/build.sh            the app, msbctl and the test runner
#   scripts/build.sh core       StandByProtocol and CompanionCore only
#
# Output in MacCompanion/.build/swiftc; the app at MacCompanion/build/Music StandBy.app,
# ad-hoc signed. Each rebuild changes the signature, so macOS asks for
# Automation permission again.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
protocol=$root/../Shared/StandByProtocol
source "$root/scripts/toolchain.sh"
out=$root/.build/swiftc
mkdir -p "$out"
what=${1:-all}

echo "› toolchain: $toolchain ($(basename "$sdk"))"

library() {   # name, sources...
  local name=$1; shift
  echo "› $name"
  swiftc "${common[@]}" -parse-as-library -enable-testing -module-name "$name" \
    -emit-library -static -emit-module -emit-module-path "$out/$name.swiftmodule" \
    -I "$out" "$@" -o "$out/lib$name.a"
}

library StandByProtocol "$protocol"/Sources/StandByProtocol/*.swift
library CompanionCore $(find "$root/Sources/CompanionCore" -name '*.swift')
[[ "$what" == core ]] && exit 0

link=(-I "$out" -L "$out" -lCompanionCore -lStandByProtocol)

echo "› msbctl"
swiftc "${common[@]}" -module-name msbctl "${link[@]}" "$root"/Sources/msbctl/*.swift -o "$out/msbctl"

echo "› MusicStandBy"
swiftc "${common[@]}" -parse-as-library -module-name MusicStandBy "${link[@]}" \
  "$root"/Sources/MusicStandBy/*.swift -o "$out/MusicStandBy"

echo "› CompanionCoreTests"
swiftc "${common[@]}" "${testflags[@]}" -parse-as-library -module-name CompanionCoreTests "${link[@]}" \
  "$root"/Tests/CompanionCoreTests/*.swift "$protocol/scripts/TestMain.swift" -o "$out/CompanionCoreTests"

app="$root/build/Music StandBy.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$out/MusicStandBy" "$app/Contents/MacOS/MusicStandBy"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"
codesign --force --sign - --entitlements "$root/Resources/MusicStandBy.entitlements" "$app" 2>&1 | grep -v "replacing existing signature" || true
echo "› $app"
