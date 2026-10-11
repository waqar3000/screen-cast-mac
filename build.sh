#!/bin/bash
# Builds "Screen Cast.app" into ./build.
#
#   ./build.sh              build for this Mac
#   ./build.sh --open       build, then launch the app
#   ./build.sh --universal  build for both Apple Silicon and Intel Macs
#   ./build.sh --release    universal build, zipped for a GitHub release
set -euo pipefail
cd "$(dirname "$0")"

OPEN=false
UNIVERSAL=false
ZIP=false
for arg in "$@"; do
  case "$arg" in
    --open) OPEN=true ;;
    --universal) UNIVERSAL=true ;;
    --release) UNIVERSAL=true; ZIP=true ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

APP="build/Screen Cast.app"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" Resources/Info.plist)
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)

ARCHS=()
if $UNIVERSAL; then ARCHS=(--arch arm64 --arch x86_64); fi
swift build -c release "${ARCHS[@]+"${ARCHS[@]}"}"
BIN="$(swift build -c release "${ARCHS[@]+"${ARCHS[@]}"}" --show-bin-path)/ScreenCast"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ScreenCast"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# macOS tracks Local Network permission by the executable's Mach-O UUID, which changes on every
# build. Pin it (per architecture) so a rebuild doesn't count as a brand-new app and re-prompt.
python3 - "$APP/Contents/MacOS/ScreenCast" "$BUNDLE_ID" <<'EOF'
import hashlib, struct, sys
path, bundle_id = sys.argv[1], sys.argv[2]
data = bytearray(open(path, "rb").read())

def pin_uuid(start):
    assert struct.unpack_from("<I", data, start)[0] == 0xFEEDFACF, "expected a 64-bit Mach-O"
    cputype, _, _, ncmds = struct.unpack_from("<iiII", data, start + 4)
    offset = start + 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, offset)
        if cmd == 0x1B:  # LC_UUID
            data[offset + 8:offset + 24] = hashlib.md5(f"{bundle_id}-{cputype}".encode()).digest()
        offset += size

if struct.unpack_from(">I", data, 0)[0] == 0xCAFEBABE:  # universal binary: one slice per architecture
    for index in range(struct.unpack_from(">I", data, 4)[0]):
        pin_uuid(struct.unpack_from(">I", data, 8 + index * 20 + 8)[0])
else:
    pin_uuid(0)
open(path, "wb").write(data)
EOF

# Sign with your Apple Development certificate if you have one. Otherwise sign ad hoc with a
# requirement based on the bundle ID, so macOS keeps the Screen Recording permission across rebuilds.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}"
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  codesign --force --sign - -r="designated => identifier \"$BUNDLE_ID\"" "$APP"
fi
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/ScreenCast"))"

if $ZIP; then
  ZIP_PATH="build/ScreenCast-$VERSION.zip"
  rm -f "$ZIP_PATH"
  ditto -c -k --keepParent "$APP" "$ZIP_PATH"
  echo "Zipped $ZIP_PATH"
fi
if $OPEN; then open "$APP"; fi
