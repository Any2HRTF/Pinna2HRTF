#!/usr/bin/env bash
# Packages an app bundle into a styled drag-to-install DMG.
# usage: make_dmg.sh <Pinna2HRTF.app> <output.dmg> <volume name> <version label>
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 <app> <output.dmg> <volume name> <version label>" >&2
  exit 2
fi
APP="$1"
OUT="$2"
VOLNAME="$3"
VERSION_LABEL="$4"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORK="$(mktemp -d /private/tmp/pinna2hrtf-dmg.XXXXXX)"
MOUNT=""
cleanup() {
  if [[ -n "$MOUNT" && -d "$MOUNT" ]]; then hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# Window geometry. Keep in sync with render_background.swift.
WIN_W=660
WIN_H=440
APP_X=180
APP_Y=250
LINK_X=480
LINK_Y=250

swift "$HERE/render_background.swift" "$ROOT/website/assets" "$WORK/bg" "$VERSION_LABEL"
tiffutil -cathidpicheck "$WORK/bg/background.png" "$WORK/bg/background@2x.png" -out "$WORK/background.tiff" >/dev/null

STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
ditto --norsrc --noextattr --noqtn "$APP" "$STAGE/Pinna2HRTF.app"
ln -s /Applications "$STAGE/Applications"
cp "$WORK/background.tiff" "$STAGE/.background/background.tiff"
APP_ICNS="$STAGE/Pinna2HRTF.app/Contents/Resources/Pinna2HRTF.icns"
[[ -f "$APP_ICNS" ]] || APP_ICNS="$STAGE/Pinna2HRTF.app/Contents/Resources/app_icon.icns"

SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) * 11 / 10 + 64 ))
RW="$WORK/rw.dmg"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -fs APFS -format UDRW -size "${SIZE_MB}m" -ov "$RW" >/dev/null
MOUNT="$(hdiutil attach "$RW" -readwrite -noverify -noautoopen | awk -F'\t' '/\/Volumes\// { print $NF }' | tail -1)"
if [[ -z "$MOUNT" || ! -d "$MOUNT" ]]; then
  echo "Could not mount the writable image." >&2
  exit 1
fi

# Lay out the Finder window. Finder needs the disk by its POSIX path.
osascript <<OSA
tell application "Finder"
  set d to (POSIX file "$MOUNT" as alias)
  open d
  set w to container window of d
  set current view of w to icon view
  set toolbar visible of w to false
  set statusbar visible of w to false
  set bounds of w to {200, 120, 200 + $WIN_W, 120 + $WIN_H}
  set o to icon view options of w
  set arrangement of o to not arranged
  set icon size of o to 128
  set text size of o to 13
  set background picture of o to file ".background:background.tiff" of d
  set position of item "Pinna2HRTF.app" of d to {$APP_X, $APP_Y}
  set position of item "Applications" of d to {$LINK_X, $LINK_Y}
  update d without registering applications
  delay 1
  close w
  open d
  delay 1
  close container window of d
end tell
OSA
sync
for _ in 1 2 3 4 5; do
  [[ -f "$MOUNT/.DS_Store" ]] && break
  sleep 1
done
if [[ ! -f "$MOUNT/.DS_Store" ]]; then
  echo "Finder did not save the window layout." >&2
  exit 1
fi
# Finder removes a volume icon during layout, so add it afterwards.
if [[ -f "$APP_ICNS" ]]; then
  cp "$APP_ICNS" "$MOUNT/.VolumeIcon.icns"
  SetFile -a C "$MOUNT" 2>/dev/null || xcrun SetFile -a C "$MOUNT" 2>/dev/null || true
fi
chmod -Rf go-w "$MOUNT" 2>/dev/null || true
rm -rf "$MOUNT/.fseventsd" "$MOUNT/.Trashes"
hdiutil detach "$MOUNT" >/dev/null
MOUNT=""

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
hdiutil convert "$RW" -format ULMO -o "$OUT" >/dev/null
echo "$OUT"
