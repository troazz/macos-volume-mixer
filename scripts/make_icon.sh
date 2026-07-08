#!/usr/bin/env bash
# Generate the AppIcon asset catalog from scripts/make_icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

ICONSET="Sources/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$ICONSET"

MASTER="$(mktemp -d)/icon_1024.png"
swift scripts/make_icon.swift "$MASTER"

# Downscale to every size the macOS AppIcon set needs.
for s in 16 32 64 128 256 512; do
  sips -z "$s" "$s" "$MASTER" --out "$ICONSET/icon_${s}.png" >/dev/null
done
cp "$MASTER" "$ICONSET/icon_1024.png"

cat > "$ICONSET/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16",   "filename" : "icon_16.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16",   "filename" : "icon_32.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32",   "filename" : "icon_32.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32",   "filename" : "icon_64.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "icon_128.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "icon_256.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "icon_256.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "icon_512.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "icon_512.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "icon_1024.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

echo "Generated $ICONSET"
ls "$ICONSET"
