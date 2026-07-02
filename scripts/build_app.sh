#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT_DIR/Whisper Clipboard.app"
CONTENTS="$APP/Contents"
RESOURCES="$CONTENTS/Resources"
RUNTIME="$RESOURCES/runtime"
FRAMEWORKS="$CONTENTS/Frameworks"
PYTHON_EXECUTABLE="$(realpath "$ROOT_DIR/.venv/bin/python3.13")"
PYTHON_ROOT="$(cd "$(dirname "$PYTHON_EXECUTABLE")/.." && pwd)"

if [[ ! -d "$ROOT_DIR/.venv" ]]; then
  printf 'Missing .venv. Run ./install.sh first.\n' >&2
  exit 1
fi

if [[ ! -d "$ROOT_DIR/models" ]]; then
  printf 'Missing local Whisper model. Prepare the model first.\n' >&2
  exit 1
fi

mkdir -p "$CONTENTS/MacOS" "$RESOURCES/app" "$FRAMEWORKS"
install -m 644 "$ROOT_DIR/packaging/Info.plist" "$CONTENTS/Info.plist"

clang -O2 \
  -I "$PYTHON_ROOT/include/python3.13" \
  "$ROOT_DIR/packaging/launcher.c" \
  -L "$PYTHON_ROOT/lib" -lpython3.13 \
  -Wl,-rpath,@executable_path/../Frameworks \
  -o "$CONTENTS/MacOS/WhisperClipboard"
rsync -a --delete --include '*.dylib' --exclude '*' \
  "$PYTHON_ROOT/lib/" "$FRAMEWORKS/"

rsync -a --delete --exclude '__pycache__' --exclude '*.pyc' \
  "$ROOT_DIR/src/whisper_clipboard/" "$RESOURCES/app/whisper_clipboard/"
find "$RESOURCES/app" -type d -name '__pycache__' -prune -exec rm -rf {} +
rsync -a --delete "$ROOT_DIR/models/" "$RESOURCES/models/"
rm -rf "$RUNTIME"
mkdir -p "$RUNTIME/lib/python3.13/site-packages"
rsync -a --exclude 'site-packages' --exclude '__pycache__' --exclude '*.pyc' \
  "$PYTHON_ROOT/lib/python3.13/" "$RUNTIME/lib/python3.13/"
rsync -a --delete --delete-excluded \
  --exclude '__editable__.*.pth' \
  --exclude '__pycache__' --exclude '*.pyc' \
  "$ROOT_DIR/.venv/lib/python3.13/site-packages/" \
  "$RUNTIME/lib/python3.13/site-packages/"

cp "$ROOT_DIR/config.toml" "$RESOURCES/config.toml"
mkdir -p "$RESOURCES"
"$ROOT_DIR/.venv/bin/python" "$ROOT_DIR/scripts/create_icns.py" \
  "$ROOT_DIR/assets/AppIcon.iconset" "$RESOURCES/AppIcon.icns"

codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
plutil -lint "$CONTENTS/Info.plist"

printf 'Built %s\n' "$APP"
