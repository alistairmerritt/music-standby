#!/bin/bash
# Builds Second Chair for other people's Macs: Developer ID signed, hardened
# runtime, notarised by Apple and stapled, then zipped for GitHub Releases.
#
#   scripts/release.sh            build, notarise, staple, zip
#   scripts/release.sh --check    only check the certificate, credentials and host
#
# Needs, once:
#   - A "Developer ID Application" certificate in the login keychain. Only the
#     team's Account Holder can make one: Xcode → Settings → Accounts → the team
#     → Manage Certificates → + → Developer ID Application.
#   - notarytool credentials saved in the keychain under a profile name:
#       xcrun notarytool store-credentials SecondChair --apple-id <Apple ID> --team-id <team ID>
#     It asks for an app-specific password (account.apple.com → Sign-In and
#     Security → App-Specific Passwords). MSB_NOTARY_PROFILE picks another name.
#   - The relay host: MSB_RELAY_HOST, or ~/.config/second-chair/relay-host.
#
# MSB_SIGN_IDENTITY overrides the certificate. Nothing is uploaded or published:
# the zip lands in build/release for `gh release create`.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
profile=${MSB_NOTARY_PROFILE:-SecondChair}
fail() { echo "✗ $*" >&2; exit 1; }

host=${MSB_RELAY_HOST:-$(head -n 1 "$HOME/.config/second-chair/relay-host" 2>/dev/null | tr -d '[:space:]' || true)}
[[ -n "$host" ]] || fail "no relay host: set MSB_RELAY_HOST or write it to ~/.config/second-chair/relay-host"
echo "› relay host: found"

identity=${MSB_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/"Developer ID Application: / { print $2; exit }')}
[[ -n "$identity" ]] || fail "no Developer ID Application certificate (see the top of this script)"
echo "› certificate: $identity"

xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 \
  || fail "no notarytool credentials under \"$profile\" (see the top of this script)"
echo "› notarytool profile: $profile"

[[ "${1:-}" == --check ]] && { echo "› ready to release"; exit 0; }

version=$(plutil -extract CFBundleShortVersionString raw "$root/Resources/Info.plist")
build=$(plutil -extract CFBundleVersion raw "$root/Resources/Info.plist")
dist="$root/build/release"
app="$dist/Second Chair.app"
zip="$dist/Second-Chair-$version.zip"
mkdir -p "$dist"

MSB_RELEASE=1 MSB_SIGN_IDENTITY="$identity" MSB_RELAY_HOST="$host" MSB_APP_PATH="$app" "$root/scripts/build.sh"

echo "› checking the signature"
codesign --verify --strict --verbose=1 "$app"
flags=$(codesign -dv "$app" 2>&1 | awk -F'flags=' '/flags=/ { print $2 }')
[[ "$flags" == *runtime* ]] || fail "not signed with the hardened runtime ($flags)"
codesign -d --entitlements - --xml "$app" 2>/dev/null | grep -q "com.apple.security.automation.apple-events" \
  || fail "the Apple Events entitlement is missing, so Music couldn't be driven"
[[ -n "$(plutil -extract MSBRelayHost raw "$app/Contents/Info.plist" 2>/dev/null)" ]] || fail "no relay host in Info.plist"

echo "› notarising $version ($build); this usually takes a few minutes"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
out=$(xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait 2>&1) || true
echo "$out" | grep -E "id:|status:" | sed 's/^ */  /'
if ! echo "$out" | grep -q "status: Accepted"; then
  id=$(echo "$out" | awk '/^ *id:/ { print $2; exit }')
  [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$profile" || true
  fail "notarisation wasn't accepted"
fi

echo "› stapling"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app" 2>&1 | sed 's/^/  /'

# The zip that was notarised has no ticket inside; the one people download should.
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
echo "› $zip"
echo "  sha256 $(shasum -a 256 "$zip" | awk '{ print $1 }')"
echo "  To publish: gh release create mac-v$version \"$zip\" --title \"Second Chair for Mac $version\""
