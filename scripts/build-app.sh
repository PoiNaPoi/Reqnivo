#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
app_version="${REQNIVO_VERSION:-0.0.7}"
app_build="${REQNIVO_BUILD:-7}"
feed_url="${REQNIVO_FEED_URL:-https://raw.githubusercontent.com/PoiNaPoi/Reqnivo/updates/appcast.xml}"
public_ed_key="${REQNIVO_SPARKLE_PUBLIC_KEY:-}"
if [ -z "$public_ed_key" ] && [ -f updates/sparkle-public-key.txt ]; then
    public_ed_key="$(grep -v '^[[:space:]]*#' updates/sparkle-public-key.txt | grep -v '^[[:space:]]*$' | head -n 1 | tr -d '[:space:]' || true)"
fi
if [ "${REQNIVO_REQUIRE_UPDATER_CONFIG:-0}" = "1" ] && { [ -z "$feed_url" ] || [ -z "$public_ed_key" ]; }; then
    echo "Updater configuration incomplete: SUFeedURL and SUPublicEDKey are required for release packaging" >&2
    exit 1
fi
iconset=".build/Reqnivo.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -s format png -z "$size" "$size" images/Reqnivo-icon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -s format png -z "$retina_size" "$retina_size" images/Reqnivo-icon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o Sources/Reqnivo/Resources/Reqnivo.icns
if [ ! -x vendor/mitmproxy.app/Contents/MacOS/mitmdump ]; then ./scripts/fetch-engine.sh; fi
python3 scripts/verify-third-party-notices.py
./scripts/swift.sh build -c "$configuration"
bin_path="$(./scripts/swift.sh build -c "$configuration" --show-bin-path)"
app="dist/Reqnivo.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources/Engine"
cp "$bin_path/Reqnivo" "$app/Contents/MacOS/Reqnivo"
if ! otool -l "$app/Contents/MacOS/Reqnivo" | grep -q '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath '@executable_path/../Frameworks' "$app/Contents/MacOS/Reqnivo"
fi
sparkle_framework=""
for candidate in \
    "$bin_path/Sparkle.framework" \
    ".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"; do
    if [ -d "$candidate" ]; then
        sparkle_framework="$candidate"
        break
    fi
done
if [ -z "$sparkle_framework" ]; then
    echo "Sparkle.framework not found in $bin_path or .build/artifacts" >&2
    exit 1
fi
rm -rf "$app/Contents/Frameworks/Sparkle.framework"
ditto "$sparkle_framework" "$app/Contents/Frameworks/Sparkle.framework"
# AppResources resolves the packaged module bundle inside the app Resources directory.
rm -rf "$app/Contents/MacOS/Reqnivo_Reqnivo.bundle"
rm -rf "$app/Contents/Resources/Reqnivo_Reqnivo.bundle"
cp -R "$bin_path/Reqnivo_Reqnivo.bundle" "$app/Contents/Resources/"
# Older SwiftPM versions emit a flat resource bundle without signing metadata.
resource_bundle="$app/Contents/Resources/Reqnivo_Reqnivo.bundle"
if [ ! -f "$resource_bundle/Info.plist" ] && [ ! -f "$resource_bundle/Contents/Info.plist" ]; then
    cat > "$resource_bundle/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.reqnivo.mac.resources</string>
<key>CFBundleName</key><string>Reqnivo_Reqnivo</string>
<key>CFBundlePackageType</key><string>BNDL</string>
</dict></plist>
PLIST
fi
rm -rf "$app/Contents/Resources/Engine/mitmproxy.app"
cp -R vendor/mitmproxy.app "$app/Contents/Resources/Engine/"
cp vendor/mitmproxy-LICENSE.txt "$app/Contents/Resources/"
rm -rf "$app/Contents/Resources/Legal"
mkdir -p "$app/Contents/Resources/Legal"
cp LICENSE THIRD_PARTY_NOTICES.md docs/PRIVACY.md docs/AUTHORIZED_USE.md docs/ENGINE_SOURCE.md "$app/Contents/Resources/Legal/"
cp -R vendor/third-party "$app/Contents/Resources/Legal/"
cp Sources/Reqnivo/Resources/Reqnivo.icns "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Reqnivo</string>
<key>CFBundleIdentifier</key><string>dev.reqnivo.mac</string>
<key>CFBundleName</key><string>Reqnivo</string>
<key>CFBundleDisplayName</key><string>Reqnivo</string>
<key>CFBundleIconFile</key><string>Reqnivo.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${app_version}</string>
<key>CFBundleVersion</key><string>${app_build}</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Reqnivo · mitmproxy engine licensed under MIT</string>
<key>SUFeedURL</key><string>${feed_url}</string>
<key>SUEnableAutomaticChecks</key><true/>
<key>SUAutomaticallyUpdate</key><false/>
<key>SUAllowsAutomaticUpdates</key><false/>
<key>SUEnableSystemProfile</key><false/>
<key>SURequireSignedFeed</key><true/>
<key>SUVerifyUpdateBeforeExtraction</key><true/>
<key>SUScheduledCheckInterval</key><integer>86400</integer>
PLIST
if [ -n "$public_ed_key" ]; then
    cat >> "$app/Contents/Info.plist" <<PLIST
<key>SUPublicEDKey</key><string>${public_ed_key}</string>
PLIST
fi
cat >> "$app/Contents/Info.plist" <<'PLIST'
</dict></plist>
PLIST
# Development signature only. Keep the vendor's nested signature intact.
codesign --force --sign - "$app/Contents/Resources/Reqnivo_Reqnivo.bundle"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
touch "$app"
printf 'Built %s\n' "$PWD/$app"
