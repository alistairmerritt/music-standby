#!/bin/bash
# Builds the Mac companion with swiftc, without SwiftPM or an Xcode project.
#
#   scripts/build.sh            the app, msbctl and the test runner
#   scripts/build.sh core       StandByProtocol and CompanionCore only
#
# Output in MacCompanion/.build/swiftc; the app at MacCompanion/build/Music StandBy.app,
# signed with your Apple Development identity so keychain and Automation
# approvals survive rebuilds (ad-hoc when there is none; see the codesign step).
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
# Signed with the first Apple Development identity when there is one: an ad-hoc
# signature is a new identity every build, so macOS asks again for the keychain
# item and for Automation of Music after each rebuild. MSB_SIGN_IDENTITY
# overrides it; "-" forces ad-hoc.
identity=${MSB_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development: / { print $2; exit }')}
codesign --force --sign "${identity:--}" --entitlements "$root/Resources/MusicStandBy.entitlements" "$app" 2>&1 | grep -v "replacing existing signature" || true
codesign --verify "$app"
echo "› $app"
