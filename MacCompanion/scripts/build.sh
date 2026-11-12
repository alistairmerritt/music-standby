#!/bin/bash
# Builds the Mac companion with swiftc, without SwiftPM or an Xcode project.
#
#   scripts/build.sh            the app, msbctl and the test runner
#   scripts/build.sh core       StandByProtocol and CompanionCore only
#
# The relay host is built into the app's Info.plist (MSBRelayHost) from
# MSB_RELAY_HOST, or else the first line of ~/.config/second-chair/relay-host,
# which is outside every checkout so it can't be committed. Without one the app
# uses `relayURL` from its defaults, else the mock.
#
# MSB_RELEASE=1, set by scripts/release.sh: optimised, hardened runtime and a
# secure timestamp, as notarisation requires.
#
# Output in MacCompanion/.build/swiftc; the app at MacCompanion/build/Second Chair.app,
# signed with your Apple Development identity so keychain and Automation
# approvals survive rebuilds (ad-hoc when there is none; see the codesign step).
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
protocol=$root/../Shared/StandByProtocol
source "$root/scripts/toolchain.sh"
out=$root/.build/swiftc
mkdir -p "$out"
what=${1:-all}

sign_flags=()
if [[ "${MSB_RELEASE:-0}" == 1 ]]; then
  common+=(-O)
  sign_flags=(--options runtime --timestamp)
fi
relay_host=${MSB_RELAY_HOST:-$(head -n 1 "$HOME/.config/second-chair/relay-host" 2>/dev/null | tr -d '[:space:]' || true)}

echo "› toolchain: $toolchain ($(basename "$sdk"))${MSB_RELEASE:+, release}"

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

# MSB_APP_PATH puts the app elsewhere; release.sh uses it so a Developer ID build
# never replaces the development one, whose signature the approvals belong to.
app=${MSB_APP_PATH:-"$root/build/Second Chair.app"}
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$out/MusicStandBy" "$app/Contents/MacOS/MusicStandBy"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
# The host itself isn't printed, so it stays out of logs as well as the repository.
if [[ -n "$relay_host" ]]; then
  plutil -insert MSBRelayHost -string "$relay_host" "$app/Contents/Info.plist"
  echo "› relay host built in"
else
  echo "› no relay host built in: the app uses relayURL from its defaults, else the mock"
fi
printf 'APPL????' > "$app/Contents/PkgInfo"
# The icon is an Icon Composer document; actool, which only Xcode has, turns it
# into Assets.car (macOS 26 and later) and AppIcon.icns (earlier systems).
if xcrun --find actool >/dev/null 2>&1; then
  xcrun actool "$root/Resources/AppIcon.icon" --compile "$app/Contents/Resources" \
    --platform macosx --target-device mac --minimum-deployment-target 14.0 --app-icon AppIcon \
    --output-partial-info-plist "$out/AppIcon-Info.plist" --output-format human-readable-text \
    | grep -E "error|warning" || true
else
  echo "› no actool (Command Line Tools only): the app has no icon"
fi
# Signed with the first Apple Development identity when there is one: an ad-hoc
# signature is a new identity every build, so macOS asks again for the keychain
# item and for Automation of Music after each rebuild. MSB_SIGN_IDENTITY
# overrides it; "-" forces ad-hoc.
identity=${MSB_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development: / { print $2; exit }')}
# (Bash 3.2 calls an empty array unbound under set -u, hence the ${…+…}.)
codesign --force --sign "${identity:--}" ${sign_flags[@]+"${sign_flags[@]}"} \
  --entitlements "$root/Resources/MusicStandBy.entitlements" "$app" 2>&1 | grep -v "replacing existing signature" || true
codesign --verify --strict "$app"
echo "› $app"
