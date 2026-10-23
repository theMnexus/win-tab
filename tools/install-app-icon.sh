#!/usr/bin/env bash
# Generate every required size from tools/icon-1024.png and write Contents.json
# into Sources/Switch/Resources/Assets.xcassets/AppIcon.appiconset/
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MASTER="$PROJECT_DIR/tools/icon-1024.png"
ICONSET="$PROJECT_DIR/Sources/Switch/Resources/Assets.xcassets/AppIcon.appiconset"

if [[ ! -f "$MASTER" ]]; then
    echo "missing master at $MASTER — run tools/render-icon.swift first"
    exit 1
fi

mkdir -p "$ICONSET"

sips -z 16 16    "$MASTER" --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32 32    "$MASTER" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32 32    "$MASTER" --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64 64    "$MASTER" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128  "$MASTER" --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256 256  "$MASTER" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256  "$MASTER" --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512 512  "$MASTER" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512  "$MASTER" --out "$ICONSET/icon_512x512.png"    >/dev/null
cp "$MASTER" "$ICONSET/icon_512x512@2x.png"

cat > "$ICONSET/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16",   "filename" : "icon_16x16.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16",   "filename" : "icon_16x16@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32",   "filename" : "icon_32x32.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32",   "filename" : "icon_32x32@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "icon_128x128.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "icon_128x128@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "icon_256x256.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "icon_256x256@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "icon_512x512.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "icon_512x512@2x.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

echo "installed app icon to $ICONSET"
ls -la "$ICONSET"
