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
EXTERNAL_ROOT="$ROOT/External"
if [[ ! -d "$EXTERNAL_ROOT" ]]; then
  EXTERNAL_ROOT="$REPO_ROOT/External"
fi
UV_BIN="$EXTERNAL_ROOT/bin/uv"

cd "$ROOT"
CLANG_MODULE_CACHE_PATH="/private/tmp/pinna2hrtf-clang-cache" \
SWIFTPM_HOME="/private/tmp/pinna2hrtf-swiftpm-cache" \
swift build -c release --disable-sandbox --scratch-path "$SCRATCH" --product Pinna2HRTF

rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"
cp "$SCRATCH/release/Pinna2HRTF" "$MACOS/Pinna2HRTF"
cp -R "$ROOT/HRTFCalculation" "$RESOURCES/HRTFCalculation"
cp "$ROOT/pyproject.toml" "$RESOURCES/pyproject.toml"
if [[ -f "$ROOT/uv.lock" ]]; then
  cp "$ROOT/uv.lock" "$RESOURCES/uv.lock"
fi
if [[ -d "$EXTERNAL_ROOT/bin" ]]; then
  mkdir -p "$RESOURCES/External"
  cp -R "$EXTERNAL_ROOT/bin" "$RESOURCES/External/bin"
fi
if [[ -d "$REPO_ROOT/Paper/Data/Resources/EvalGrid" ]]; then
  mkdir -p "$RESOURCES/Data/Resources"
  cp -R "$REPO_ROOT/Paper/Data/Resources/EvalGrid" "$RESOURCES/Data/Resources/EvalGrid"
fi
if [[ -f "$ICON" ]]; then
  cp "$ICON" "$RESOURCES/app_icon.icns"
fi
if [[ ! -x "$UV_BIN" ]]; then
  UV_BIN="$(command -v uv || true)"
fi
if [[ -x "$UV_BIN" ]]; then
  cd "$RESOURCES"
  UV_CACHE_DIR="/private/tmp/pinna2hrtf-uv-cache" "$UV_BIN" sync --no-dev
  cd "$ROOT"
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
