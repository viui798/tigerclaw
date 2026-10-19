#!/bin/bash
# Install TigerClaw.app for the current user (or system-wide when run as root).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
app="$here/build/TigerClaw.app"
if [[ ! -d "$app" ]]; then
  echo "Building first..."
  "$here/build.sh"
fi

if [[ "$(id -u)" -eq 0 ]]; then
  target="/Library/Input Methods"
elif [[ -w "/Library/Input Methods" ]]; then
  target="/Library/Input Methods"
else
  target="$HOME/Library/Input Methods"
  echo "note: /Library/Input Methods is not writable; installing for the current user."
  echo "      Use 'sudo $0' for a system-wide installation."
fi
mkdir -p "$target"
installed="$target/TigerClaw.app"

for pid in $(pgrep -f "$installed/Contents/MacOS/TigerClaw" 2>/dev/null || true); do
  kill "$pid" 2>/dev/null || true
done
sleep 1
rm -rf "$installed"
ditto "$app" "$installed"
codesign --force --deep --sign - --identifier com.viui.inputmethod.TigerClaw "$installed"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
# A stale LaunchServices entry for the build product makes the input source
# grey and unselectable. Drop it and index the installed bundle.
"$LSREGISTER" -u "$app" >/dev/null 2>&1 || true
"$LSREGISTER" -f "$installed" >/dev/null 2>&1 || true

"$installed/Contents/MacOS/TigerClaw" --register-input-source
"$installed/Contents/MacOS/TigerClaw" --enable-input-source --select || {
  echo "note: could not select the input source automatically." >&2
  echo "      Open System Settings > Keyboard > Input Sources and add 虎爪." >&2
}
echo "installed: $installed"
