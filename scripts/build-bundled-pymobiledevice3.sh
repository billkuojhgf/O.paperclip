#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-$HOME/.local/pipx/venvs/pymobiledevice3/bin/python}"
DIST_DIR="$ROOT_DIR/build/pymobiledevice3-dist"
TARGET_DIR="$ROOT_DIR/bundled/pymobiledevice3-bundle"

if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "ERROR: Python not found at $PYTHON_BIN"
  exit 1
fi

echo "[INFO] Using Python: $PYTHON_BIN"
if ! "$PYTHON_BIN" -c 'import pymobiledevice3' >/dev/null 2>&1; then
  echo "ERROR: pymobiledevice3 is not installed in the selected Python environment"
  exit 1
fi

CLI_BIN="$(dirname "$PYTHON_BIN")/pymobiledevice3"
if [[ ! -x "$CLI_BIN" ]]; then
  echo "ERROR: pymobiledevice3 CLI not found at $CLI_BIN"
  exit 1
fi

"$PYTHON_BIN" -m PyInstaller --noconfirm --clean \
  --onedir \
  --name pymobiledevice3 \
  --collect-all pymobiledevice3 \
  --recursive-copy-metadata pymobiledevice3 \
  --distpath "$DIST_DIR" \
  --workpath "$ROOT_DIR/build/pyinstaller" \
  "$CLI_BIN"

if [[ ! -x "$DIST_DIR/pymobiledevice3/pymobiledevice3" ]]; then
  echo "ERROR: Failed to build bundled pymobiledevice3 onedir bundle"
  exit 1
fi

rm -rf "$TARGET_DIR"
mv "$DIST_DIR/pymobiledevice3" "$TARGET_DIR"

echo "[INFO] Built bundled/pymobiledevice3-bundle/pymobiledevice3"
