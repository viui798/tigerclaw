#!/bin/bash
# Build the macOS InputMethodKit port of TigerClaw.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
build="$here/build"
model="${TIGERCLAW_SENTENCE_MODEL:-$here/resources/Models/sentence-fivegram-mobile.bin}"
jobs="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

if [[ ! -f "$model" ]]; then
  echo "warning: sentence model not found at: $model" >&2
  echo "         Set TIGERCLAW_SENTENCE_MODEL to the 405 MB" >&2
  echo "         sentence-fivegram-mobile.bin to enable 虎整句." >&2
  echo "         The build will produce a words-only bundle." >&2
fi

cmake -S "$here" -B "$build" -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_TESTING=ON \
  -DTIGERCLAW_SENTENCE_MODEL="$model"
cmake --build "$build" --parallel "$jobs"

if [[ -x "$build/tigerclaw_engine_probe" ]]; then
  ctest --test-dir "$build" --output-on-failure
fi

app="$build/TigerClaw.app"
if [[ -d "$app" ]]; then
  # Sign only after Info.plist and all resources are present.
  codesign --force --deep --sign - --identifier com.viui.inputmethod.TigerClaw "$app"
  echo "built: $app"
else
  echo "error: app bundle missing" >&2
  exit 1
fi
