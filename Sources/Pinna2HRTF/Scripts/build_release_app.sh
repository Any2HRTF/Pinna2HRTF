#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
APP_VERSION="$(sed -n 's/^version = "\([^"]*\)"/\1/p' "$ROOT/pyproject.toml" | head -n 1)"
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
if [[ -z "$APP_VERSION" ]]; then
  exit 1
fi
UV_BIN="$EXTERNAL_ROOT/bin/uv"
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
if [[ -f "$ROOT/uv.lock" ]]; then
  cp "$ROOT/uv.lock" "$RESOURCES/uv.lock"
fi
if [[ -d "$EXTERNAL_ROOT/bin" ]]; then
  mkdir -p "$RESOURCES/External"
  cp -R "$EXTERNAL_ROOT/bin" "$RESOURCES/External/bin"
  for executable in uv NumCalc hrtf_mesh_grading; do
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
fi
if [[ -d "$REPO_ROOT/Data/Resources/EvalGrid" ]]; then
  mkdir -p "$RESOURCES/Data/Resources"
  cp -R "$REPO_ROOT/Data/Resources/EvalGrid" "$RESOURCES/Data/Resources/EvalGrid"
fi
if [[ -f "$ICON" ]]; then
  cp "$ICON" "$RESOURCES/app_icon.icns"
fi
if [[ ! -x "$UV_BIN" ]]; then
  UV_BIN="$(command -v uv || true)"
fi
if [[ -x "$UV_BIN" ]]; then
  cd "$RESOURCES"
  GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0="url.https://github.com/.insteadOf" \
  GIT_CONFIG_VALUE_0="git@github.com:" \
  UV_CACHE_DIR="/private/tmp/pinna2hrtf-uv-cache" \
  "$UV_BIN" sync --no-dev --managed-python --python 3.11
  cd "$ROOT"
  PYTHON_REALPATH="$("$UV_BIN" run --project "$RESOURCES" --no-sync python -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$RESOURCES/.venv/bin/python")"
  PYTHON_PREFIX="$(cd "$(dirname "$PYTHON_REALPATH")/.." && pwd)"
  PYTHON_BUNDLE="$RESOURCES/Python/$(basename "$PYTHON_PREFIX")"
  mkdir -p "$RESOURCES/Python"
  rm -rf "$PYTHON_BUNDLE"
  cp -R "$PYTHON_PREFIX" "$PYTHON_BUNDLE"
  rm -f "$RESOURCES/.venv/bin/python" "$RESOURCES/.venv/bin/python3" "$RESOURCES/.venv/bin/python3.11"
  ln -s "../../Python/$(basename "$PYTHON_PREFIX")/bin/python3.11" "$RESOURCES/.venv/bin/python"
  ln -s "python" "$RESOURCES/.venv/bin/python3"
  ln -s "python" "$RESOURCES/.venv/bin/python3.11"
  "$UV_BIN" run --project "$RESOURCES" --no-sync python - "$RESOURCES/.venv/pyvenv.cfg" "$(basename "$PYTHON_PREFIX")" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
name = sys.argv[2]
lines = path.read_text().splitlines()
next_lines = []
for line in lines:
    if line.startswith("home = "):
        next_lines.append(f"home = ../../Python/{name}/bin")
    else:
        next_lines.append(line)
path.write_text("\n".join(next_lines) + "\n")
PY
fi
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
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSUserNotificationUsageDescription</key>
  <string>Notify when a Pinna2HRTF pipeline stage completes.</string>
</dict>
</plist>
PLIST
chmod +x "$MACOS/Pinna2HRTF"
codesign --force --deep --sign - "$APP_DIR"
echo "$APP_DIR"
