#!/usr/bin/env bash
set -euo pipefail

MODE="development"
if [[ $# -gt 0 ]]; then
  if [[ "$1" != "--distribution" || $# -ne 1 ]]; then
    echo "usage: $0 [--distribution]" >&2
    exit 2
  fi
  MODE="distribution"
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
APP_VERSION="$(sed -n 's/^version = "\([^"]*\)"/\1/p' "$ROOT/pyproject.toml" | head -n 1)"
GIT_HEAD="$(git -C "$ROOT" rev-parse --short HEAD)"
APP_BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD)"
SCRATCH="/private/tmp/pinna2hrtf-swift-build"
STAGE_ROOT="$(mktemp -d /private/tmp/pinna2hrtf-release-stage.XXXXXX)"
CLEAN_ROOT="$(mktemp -d /private/tmp/pinna2hrtf-release-clean.XXXXXX)"
trap 'rm -rf "$STAGE_ROOT" "$CLEAN_ROOT"' EXIT
APP_DIR="$STAGE_ROOT/Pinna2HRTF.app"
CLEAN_APP_DIR="$CLEAN_ROOT/Pinna2HRTF.app"
FINAL_APP_DIR="$ROOT/build/release/Pinna2HRTF.app"
DIST_DIR="$ROOT/dist"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
ICON="$ROOT/Sources/Pinna2HRTF/Resources/app_icon.icns"
EXTERNAL_ROOT="$ROOT/External"
SIGNING_IDENTITY="-"
NOTARY_PROFILE="${PINNA2HRTF_NOTARY_PROFILE:-Pinna2HRTF-notary}"
if [[ ! -d "$EXTERNAL_ROOT" ]]; then
  EXTERNAL_ROOT="$REPO_ROOT/External"
fi
if [[ -z "$APP_VERSION" || -z "$APP_BUILD_NUMBER" ]]; then
  exit 1
fi
if [[ "$MODE" == "distribution" ]]; then
  SIGNING_IDENTITY="${PINNA2HRTF_SIGNING_IDENTITY:-}"
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p')"
    IDENTITY_COUNT="$(printf "%s\n" "$IDENTITIES" | sed '/^$/d' | wc -l | tr -d ' ')"
    if [[ "$IDENTITY_COUNT" != "1" ]]; then
      echo "Distribution requires exactly one Developer ID Application identity or PINNA2HRTF_SIGNING_IDENTITY." >&2
      exit 1
    fi
    SIGNING_IDENTITY="$IDENTITIES"
  elif ! security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$SIGNING_IDENTITY\""; then
    echo "Developer ID identity not found: $SIGNING_IDENTITY" >&2
    exit 1
  fi
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "Notary profile '$NOTARY_PROFILE' is missing or invalid." >&2
    exit 1
  fi
fi
UV_BIN="$(command -v uv || true)"
if [[ ! -x "$UV_BIN" ]]; then
  echo "uv is required to build the release app"
  exit 1
fi
if [[ ! -f "$ROOT/uv.lock" ]]; then
  echo "uv.lock is required to build the release app"
  exit 1
fi
export UV_CACHE_DIR="/private/tmp/pinna2hrtf-uv-cache"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
SDK_SWIFT_INTERFACE="$(find "$SDK_PATH/usr/lib/swift/Swift.swiftmodule" -name '*-apple-macos.swiftinterface' -print -quit)"
SDK_SWIFT_VERSION="$(sed -n 's|// swift-compiler-version: Apple Swift version \([^ ]*\).*|\1|p' "$SDK_SWIFT_INTERFACE")"
SWIFT_COMPATIBILITY_FLAGS=()
if [[ -n "$SDK_SWIFT_VERSION" ]]; then
  SWIFT_COMPATIBILITY_FLAGS=(-Xswiftc -interface-compiler-version -Xswiftc "$SDK_SWIFT_VERSION")
fi

cd "$ROOT"
CLANG_MODULE_CACHE_PATH="/private/tmp/pinna2hrtf-clang-cache" \
SWIFTPM_HOME="/private/tmp/pinna2hrtf-swiftpm-cache" \
swift build -c release --disable-sandbox --scratch-path "$SCRATCH" --product Pinna2HRTF "${SWIFT_COMPATIBILITY_FLAGS[@]}"

rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"
cp "$SCRATCH/release/Pinna2HRTF" "$MACOS/Pinna2HRTF"
cp -R "$ROOT/HRTFCalculation" "$RESOURCES/HRTFCalculation"
cp "$ROOT/pyproject.toml" "$RESOURCES/pyproject.toml"
cp "$ROOT/uv.lock" "$RESOURCES/uv.lock"
if [[ -d "$EXTERNAL_ROOT/bin" ]]; then
  mkdir -p "$RESOURCES/External/bin"
  for bundled_file in NumCalc NumCalc.source-commit hrtf_mesh_grading libpmp.1.2.1.dylib libpmp.dylib; do
    if [[ -e "$EXTERNAL_ROOT/bin/$bundled_file" ]]; then
      cp -P "$EXTERNAL_ROOT/bin/$bundled_file" "$RESOURCES/External/bin/$bundled_file"
    fi
  done
  for executable in NumCalc hrtf_mesh_grading; do
    if [[ -f "$RESOURCES/External/bin/$executable" ]]; then
      chmod +x "$RESOURCES/External/bin/$executable"
    fi
  done
  if [[ "$(uname -s)" == "Darwin" && -x "$RESOURCES/External/bin/hrtf_mesh_grading" && -f "$RESOURCES/External/bin/libpmp.1.2.1.dylib" ]]; then
    install_name_tool -change "@rpath/libpmp.1.2.1.dylib" "@loader_path/libpmp.1.2.1.dylib" "$RESOURCES/External/bin/hrtf_mesh_grading"
  fi
fi
if [[ -d "$EXTERNAL_ROOT/src/Mesh2HRTF/mesh2hrtf" && -f "$EXTERNAL_ROOT/src/Mesh2HRTF/VERSION" ]]; then
  mkdir -p "$RESOURCES/External/src/Mesh2HRTF"
  cp -R "$EXTERNAL_ROOT/src/Mesh2HRTF/mesh2hrtf" "$RESOURCES/External/src/Mesh2HRTF/mesh2hrtf"
  cp "$EXTERNAL_ROOT/src/Mesh2HRTF/VERSION" "$RESOURCES/External/src/Mesh2HRTF/VERSION"
  find "$RESOURCES/External/src/Mesh2HRTF" -type f -name '*.o' -delete
fi
if [[ -f "$ICON" ]]; then
  cp "$ICON" "$RESOURCES/app_icon.icns"
fi
if [[ -f "$ROOT/icon.png" ]]; then
  cp "$ROOT/icon.png" "$RESOURCES/icon.png"
fi
if [[ -f "$ROOT/ProjectSettingHelp.json" ]]; then
  cp "$ROOT/ProjectSettingHelp.json" "$RESOURCES/ProjectSettingHelp.json"
fi
cd "$RESOURCES"
GIT_CONFIG_COUNT=1 \
GIT_CONFIG_KEY_0="url.https://github.com/.insteadOf" \
GIT_CONFIG_VALUE_0="git@github.com:" \
UV_CACHE_DIR="/private/tmp/pinna2hrtf-uv-cache" \
"$UV_BIN" sync --locked --no-dev --no-install-project --managed-python --python 3.11
cd "$ROOT"
PYTHON_REALPATH="$("$RESOURCES/.venv/bin/python" -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$RESOURCES/.venv/bin/python")"
PYTHON_PREFIX="$(cd "$(dirname "$PYTHON_REALPATH")/.." && pwd)"
PYTHON_BUNDLE="$RESOURCES/Python/$(basename "$PYTHON_PREFIX")"
mkdir -p "$RESOURCES/Python"
rm -rf "$PYTHON_BUNDLE"
cp -R "$PYTHON_PREFIX" "$PYTHON_BUNDLE"
rm -f "$RESOURCES/.venv/bin/python" "$RESOURCES/.venv/bin/python3" "$RESOURCES/.venv/bin/python3.11"
ln -s "../../Python/$(basename "$PYTHON_PREFIX")/bin/python3.11" "$RESOURCES/.venv/bin/python"
ln -s "python" "$RESOURCES/.venv/bin/python3"
ln -s "python" "$RESOURCES/.venv/bin/python3.11"
"$PYTHON_BUNDLE/bin/python3.11" - "$RESOURCES/.venv/pyvenv.cfg" "$(basename "$PYTHON_PREFIX")" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
name = sys.argv[2]
lines = path.read_text().splitlines()
next_lines = []
for line in lines:
    if line.startswith("home = "):
        next_lines.append(f"home = ../../Python/{name}/bin")
    elif line.startswith("uv = "):
        continue
    else:
        next_lines.append(line)
path.write_text("\n".join(next_lines) + "\n")
PY
find "$RESOURCES/.venv/bin" -mindepth 1 -maxdepth 1 ! -name python ! -name python3 ! -name python3.11 -exec rm -rf {} +
find "$RESOURCES" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$RESOURCES" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete
cat > "$CONTENTS/Info.plist" <<PLIST
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
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD_NUMBER</string>
  <key>Pinna2HRTFGitHead</key>
  <string>$GIT_HEAD</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>© 2026 Any2HRTF</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSUserNotificationUsageDescription</key>
  <string>Notify when a Pinna2HRTF pipeline stage completes.</string>
</dict>
</plist>
PLIST
chmod +x "$MACOS/Pinna2HRTF"
ditto --norsrc --noextattr --noqtn "$APP_DIR" "$CLEAN_APP_DIR"
xattr -cr "$CLEAN_APP_DIR"
while IFS= read -r -d '' candidate; do
  if file -b "$candidate" | grep -q "Mach-O"; then
    if ! lipo -archs "$candidate" | tr ' ' '\n' | grep -qx "arm64"; then
      echo "Embedded executable is not Apple Silicon compatible: $candidate" >&2
      exit 1
    fi
    if [[ "$MODE" == "distribution" ]]; then
      codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$candidate"
    else
      codesign --force --sign - "$candidate"
    fi
  fi
done < <(find "$CLEAN_APP_DIR/Contents" -type f -print0)
while IFS= read -r bundle; do
  if [[ "$MODE" == "distribution" ]]; then
    codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$bundle"
  else
    codesign --force --sign - "$bundle"
  fi
done < <(find "$CLEAN_APP_DIR/Contents" -type d \( -name '*.framework' -o -name '*.bundle' -o -name '*.xpc' -o -name '*.app' \) -print | awk '{ print length($0) "\t" $0 }' | sort -rn | cut -f2-)
if [[ "$MODE" == "distribution" ]]; then
  codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$CLEAN_APP_DIR"
else
  codesign --force --sign - "$CLEAN_APP_DIR"
fi
codesign --verify --deep --strict --verbose=2 "$CLEAN_APP_DIR"
if [[ "$MODE" == "distribution" ]]; then
  APP_ARCHIVE="$STAGE_ROOT/Pinna2HRTF.zip"
  DMG_STAGE="$STAGE_ROOT/dmg"
  DMG_PATH="$DIST_DIR/Pinna2HRTF-$APP_VERSION-macOS-arm64.dmg"
  ditto -c -k --sequesterRsrc --keepParent "$CLEAN_APP_DIR" "$APP_ARCHIVE"
  xcrun notarytool submit "$APP_ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$CLEAN_APP_DIR"
  xcrun stapler validate "$CLEAN_APP_DIR"
  spctl --assess --type execute --verbose=2 "$CLEAN_APP_DIR"
  mkdir -p "$DMG_STAGE" "$DIST_DIR"
  ditto --norsrc --noextattr --noqtn "$CLEAN_APP_DIR" "$DMG_STAGE/Pinna2HRTF.app"
  ln -s /Applications "$DMG_STAGE/Applications"
  rm -f "$DMG_PATH" "$DMG_PATH.sha256"
  hdiutil create -volname "Pinna2HRTF $APP_VERSION" -srcfolder "$DMG_STAGE" -format UDZO -ov "$DMG_PATH"
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
  shasum -a 256 "$DMG_PATH" > "$DMG_PATH.sha256"
  rm -rf "$FINAL_APP_DIR"
  mkdir -p "$(dirname "$FINAL_APP_DIR")"
  ditto --norsrc --noextattr --noqtn "$CLEAN_APP_DIR" "$FINAL_APP_DIR"
  codesign --verify --deep --verbose=2 "$FINAL_APP_DIR"
  echo "$DMG_PATH"
else
  rm -rf "$FINAL_APP_DIR"
  mkdir -p "$(dirname "$FINAL_APP_DIR")"
  ditto --norsrc --noextattr --noqtn "$CLEAN_APP_DIR" "$FINAL_APP_DIR"
  codesign --verify --deep --verbose=2 "$FINAL_APP_DIR"
  echo "$FINAL_APP_DIR"
fi
