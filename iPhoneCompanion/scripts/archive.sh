#!/bin/bash
# Archives Second Chair for TestFlight and the App Store, with the relay host
# built in, and checks the result is signed the way TestFlight needs.
#
#   scripts/archive.sh             archive, then export an App Store Connect package
#   scripts/archive.sh --upload    archive, then upload the build to App Store Connect
#
# A plain Product → Archive in Xcode leaves MSB_RELAY_HOST empty, so that build
# would have no relay and couldn't pair. This script passes it in.
#
# Needs:
#   - The team ID: MSB_TEAM_ID, or ~/.config/second-chair/team-id.
#   - The relay host: MSB_RELAY_HOST, or ~/.config/second-chair/relay-host.
#     Both files sit outside every checkout, so neither value is committed.
#   - The App Group group.com.alistairmerritt.MusicStandBy registered and
#     enabled for both App IDs (Xcode → the MusicStandBy target → Signing &
#     Capabilities → App Groups; the same for MusicStandByNowPlaying). The
#     committed entitlements name it, and an App Store profile must match them.
#   - For --upload, an app record in App Store Connect with the bundle ID
#     com.alistairmerritt.MusicStandBy.
# The first export makes an Apple Distribution certificate and App Store
# profiles through Xcode's automatic signing (-allowProvisioningUpdates).
#
# MSB_BUILD_NUMBER sets CFBundleVersion (default: the time, as yyyymmddHHMM),
# which App Store Connect needs to go up with every upload.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
config=$HOME/.config/second-chair
fail() { echo "✗ $*" >&2; exit 1; }
first_line() { head -n 1 "$1" 2>/dev/null | tr -d '[:space:]' || true; }

host=${MSB_RELAY_HOST:-$(first_line "$config/relay-host")}
team=${MSB_TEAM_ID:-$(first_line "$config/team-id")}
[[ -n "$host" ]] || fail "no relay host: set MSB_RELAY_HOST or write it to $config/relay-host"
[[ -n "$team" ]] || fail "no team ID: set MSB_TEAM_ID or write it to $config/team-id"
destination=export
[[ "${1:-}" == --upload ]] && destination=upload
build_number=${MSB_BUILD_NUMBER:-$(date +%Y%m%d%H%M)}

out=$root/build
archive=$out/SecondChair.xcarchive
export_dir=$out/export
mkdir -p "$out"
rm -rf "$archive" "$export_dir"

echo "› archiving build $build_number"
xcodebuild archive -project "$root/MusicStandBy.xcodeproj" -scheme MusicStandBy -configuration Release \
  -destination generic/platform=iOS -archivePath "$archive" -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$team" MSB_RELAY_HOST="$host" CURRENT_PROJECT_VERSION="$build_number" \
  > "$out/archive.log" 2>&1 || { grep -E "error:|application-groups" "$out/archive.log" | sort -u | head -20; fail "archive failed; see $out/archive.log"; }

app=$archive/Products/Applications/MusicStandBy.app
[[ "$(plutil -extract MSBRelayHost raw "$app/Info.plist" 2>/dev/null)" == "$host" ]] || fail "the archived app has no relay host"
echo "› archived, relay host built in"

cat > "$out/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$destination</string>
  <key>teamID</key><string>$team</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

echo "› exporting ($destination)"
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$export_dir" \
  -exportOptionsPlist "$out/ExportOptions.plist" -allowProvisioningUpdates \
  > "$out/export.log" 2>&1 || { grep -E "error:" "$out/export.log" | sort -u | head -20; fail "export failed; see $out/export.log"; }

if [[ "$destination" == export ]]; then
  ipa=$(ls "$export_dir"/*.ipa | head -n 1)
  unpacked=$(mktemp -d)
  ditto -x -k "$ipa" "$unpacked"
  check() {   # bundle, entitlement, expected value
    local value
    value=$(codesign -d --entitlements - --xml "$1" 2>/dev/null | plutil -extract "$2" raw - 2>/dev/null || true)
    [[ "$value" == "$3" ]] || fail "$(basename "$1"): $2 is '${value:-missing}', not '$3'"
  }
  check "$unpacked/Payload/MusicStandBy.app" aps-environment production
  check "$unpacked/Payload/MusicStandBy.app" com\\.apple\\.developer\\.usernotifications\\.time-sensitive true
  # The Lock Screen extension is an ExtensionKit extension, so it lives in
  # Extensions/, not PlugIns/. Without it nothing shows on the Lock Screen.
  extension="$unpacked/Payload/MusicStandBy.app/Extensions/MusicStandByNowPlaying.appex"
  [[ -d "$extension" ]] || fail "the Now Playing extension is missing from the package"
  codesign --verify --strict "$extension" || fail "the Now Playing extension's signature doesn't verify"
  codesign -d --entitlements - --xml "$extension" 2>/dev/null | grep -q "group.com.alistairmerritt.MusicStandBy" \
    || fail "the Now Playing extension has no App Group"
  rm -rf "$unpacked"
  echo "› $ipa"
  echo "  signed for production pushes, with Time Sensitive notifications and the Now Playing extension"
  echo "  To send it to TestFlight: scripts/archive.sh --upload, or Xcode's Organizer, or Transporter"
else
  echo "› uploaded build $build_number; it shows in App Store Connect → TestFlight after processing"
fi
