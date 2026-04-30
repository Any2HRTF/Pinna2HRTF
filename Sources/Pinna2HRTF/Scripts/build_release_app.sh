#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
SCRATCH="/private/tmp/pinna2hrtf-swift-build"
APP_DIR="$ROOT/build/release/Pinna2HRTF.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
ICON="$ROOT/Sources/Pinna2HRTF/Resources/app_icon.icns"

cd "$ROOT"
CLANG_MODULE_CACHE_PATH="/private/tmp/pinna2hrtf-clang-cache" \
SWIFTPM_HOME="/private/tmp/pinna2hrtf-swiftpm-cache" \
swift build -c release --disable-sandbox --scratch-path "$SCRATCH" --product Pinna2HRTF

rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"
cp "$SCRATCH/release/Pinna2HRTF" "$MACOS/Pinna2HRTF"
if [[ -f "$ICON" ]]; then
  cp "$ICON" "$RESOURCES/app_icon.icns"
fi
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>Pinna2HRTF</string>
  <key>CFBundleIconFile</key>
  <string>app_icon</string>
  <key>CFBundleIdentifier</key>
  <string>at.ac.vbc.cbe.Pinna2HRTF</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Pinna2HRTF</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST
chmod +x "$MACOS/Pinna2HRTF"
echo "$APP_DIR"
