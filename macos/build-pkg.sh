#!/bin/bash
# Build a system-wide Installer package. The package is ad-hoc signed (unsigned
# as a package), so Installer will not offer the automatic logout action.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
app="$here/build/TigerClaw.app"
version="${TIGERCLAW_VERSION:-0.1.0}"
if [[ ! -d "$app" ]]; then
  echo "Building first..."
  "$here/build.sh"
fi
codesign --force --deep --sign - --identifier com.viui.inputmethod.TigerClaw "$app"

root="$(mktemp -d "${TMPDIR:-/tmp}/tigerclaw-pkg.XXXXXX")"
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/root"
ditto "$app" "$root/root/TigerClaw.app"

pkg="$here/build/TigerClaw-macOS-$version.pkg"
pkgbuild \
  --root "$root/root" \
  --identifier com.viui.inputmethod.TigerClaw.pkg \
  --version "$version" \
  --install-location "/Library/Input Methods" \
  --scripts "$here/pkg-scripts" \
  "$pkg"
echo "package: $pkg"
echo "Install with: sudo installer -pkg \"$pkg\" -target /"
echo "The input source appears after a logout/login (or add it manually in"
echo "System Settings > Keyboard > Input Sources)."
