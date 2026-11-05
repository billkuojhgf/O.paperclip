#!/usr/bin/env bash
set -euo pipefail

# Build script: compile Python DVT location stream into a standalone binary
# Output binary: bundled/dvt-location-stream

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PYTHON_BIN="${PYTHON_BIN:-$ROOT_DIR/build/python-bundle/bin/python}"
if [ ! -x "$PYTHON_BIN" ]; then
  echo "ERROR: Python not found at $PYTHON_BIN"; exit 1
fi
"$PYTHON_BIN" -c 'import importlib.metadata as m; assert m.version("pymobiledevice3") == "11.49.2"; assert m.version("pyinstaller") == "6.22.3"'
COLLECT=(--collect-all pymobiledevice3 --recursive-copy-metadata pymobiledevice3 --collect-all pykdebugparser --recursive-copy-metadata pykdebugparser)
for MODULE in pmd_pytcp pmd_net_addr pmd_net_proto pytun_pmd3 ipsw_parser pyimg4 apple_compress; do
  "$PYTHON_BIN" -c "import $MODULE"
  COLLECT+=(--collect-all "$MODULE" --recursive-copy-metadata "${MODULE//_/-}")
done
for MODULE in zeroconf readchar; do
  if "$PYTHON_BIN" -c "import $MODULE" 2>/dev/null; then
    COLLECT+=(--collect-all "$MODULE" --recursive-copy-metadata "$MODULE")
  fi
done
"$PYTHON_BIN" -m PyInstaller --noconfirm --clean --onefile --name dvt-location-stream \
  --distpath "$ROOT_DIR/build/python-worker-dist" \
  --workpath "$ROOT_DIR/build/pyinstaller-worker" \
  --specpath "$ROOT_DIR/build/specs-worker" \
  "${COLLECT[@]}" "$ROOT_DIR/scripts/dvt_location_stream.py"
"$ROOT_DIR/build/python-worker-dist/dvt-location-stream" --check-runtime
cp "$ROOT_DIR/build/python-worker-dist/dvt-location-stream" "$ROOT_DIR/bundled/dvt-location-stream"
chmod +x "$ROOT_DIR/bundled/dvt-location-stream"
echo "[INFO] Built bundled/dvt-location-stream"
