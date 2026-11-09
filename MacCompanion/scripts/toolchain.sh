# Sourced by build.sh and test.sh. Chooses a Swift toolchain and sets:
#   toolchain   "xcode" or "clt"
#   common      swiftc flags shared by every compile
#   testflags   extra flags for compiling Swift Testing suites
#
# Xcode is used when it is selected and working. Otherwise the Command Line
# Tools are used with a VFS overlay that hides a duplicate module map: on the
# authoring Mac they fail with "redefinition of module 'SwiftBridging'".
# FORCE_CLT=1 picks the Command Line Tools even when Xcode works.

clt=/Library/Developer/CommandLineTools
target="$(uname -m)-apple-macos14.0"

if [[ "$(xcode-select -p)" != *CommandLineTools* && "${FORCE_CLT:-0}" != 1 ]] && xcrun --find swiftc >/dev/null 2>&1; then
  toolchain=xcode
  sdk=$(xcrun --sdk macosx --show-sdk-path)
  developer=$(xcode-select -p)
  frameworks=$developer/Platforms/MacOSX.platform/Developer/Library/Frameworks
  plugins=$(dirname "$(xcrun --find swiftc)")/../lib/swift/host/plugins/testing
  common=(-sdk "$sdk")
  testflags=()
else
  toolchain=clt
  export DEVELOPER_DIR=$clt
  sdk=${SDK:-$(ls -d "$clt"/SDKs/MacOSX[0-9]*.sdk | sort -V | tail -1)}
  frameworks=$clt/Library/Developer/Frameworks
  plugins=$clt/usr/lib/swift/host/plugins/testing
  overlay_dir=${TMPDIR:-/tmp}/musicstandby-swiftc-overlay
  mkdir -p "$overlay_dir"
  : > "$overlay_dir/empty.modulemap"
  cat > "$overlay_dir/overlay.yaml" <<YAML
{ "version": 0, "case-sensitive": "false", "roots": [ { "type": "file",
  "name": "$clt/usr/include/swift/module.modulemap",
  "external-contents": "$overlay_dir/empty.modulemap" } ] }
YAML
  common=(-sdk "$sdk" -vfsoverlay "$overlay_dir/overlay.yaml" -Xcc -ivfsoverlay -Xcc "$overlay_dir/overlay.yaml")
  testflags=(-Xfrontend -disable-cross-import-overlays)
fi

common+=(-target "$target" -swift-version 6)
testflags+=(-plugin-path "$plugins" -F "$frameworks" -Xlinker -rpath -Xlinker "$frameworks")
