#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Pinna2HRTF"
case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify) ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREPARE_SCRIPT="$ROOT_DIR/Scripts/prepare_external_tools.sh"
RELEASE_SCRIPT="$ROOT_DIR/Scripts/build_release_app.sh"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

bash "$PREPARE_SCRIPT"
BUILD_OUTPUT="$(bash "$RELEASE_SCRIPT")"
printf "%s\n" "$BUILD_OUTPUT"
APP_BUNDLE="$(printf "%s\n" "$BUILD_OUTPUT" | tail -n 1)"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist")"

case "$MODE" in
  run)
    /usr/bin/open -n "$APP_BUNDLE"
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    /usr/bin/open -n "$APP_BUNDLE"
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
esac
