#!/bin/bash
# Remove installed TigerClaw input methods. Run as root to remove the
# system-wide copy as well.
set -euo pipefail
app="/Library/Input Methods/TigerClaw.app"
userapp="$HOME/Library/Input Methods/TigerClaw.app"
for target in "$app" "$userapp"; do
  for pid in $(pgrep -f "$target/Contents/MacOS/TigerClaw" 2>/dev/null || true); do
    kill "$pid" 2>/dev/null || true
  done
  if [[ -d "$target" ]]; then
    if [[ -w "$(dirname "$target")" ]]; then
      rm -rf "$target"
      echo "removed: $target"
    else
      echo "skip (not writable): $target; rerun with sudo" >&2
    fi
  fi
done
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -u "$app" >/dev/null 2>&1 || true
"$LSREGISTER" -u "$userapp" >/dev/null 2>&1 || true
echo "TigerClaw data (config, lexicons, journals) remains at:"
echo "  $HOME/Library/Application Support/TigerClaw"
