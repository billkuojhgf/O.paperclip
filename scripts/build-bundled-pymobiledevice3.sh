#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-$ROOT_DIR/build/python-bundle/bin/python}"

if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "ERROR: Python not found at $PYTHON_BIN"
  exit 1
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
"$PYTHON_BIN" -m PyInstaller --noconfirm --clean --onedir --name pymobiledevice3 \
  --distpath "$ROOT_DIR/build/python-cli-dist" \
  --workpath "$ROOT_DIR/build/pyinstaller-cli" \
  --specpath "$ROOT_DIR/build/specs-cli" \
  "${COLLECT[@]}" "$ROOT_DIR/scripts/pymobiledevice3_entry.py"
"$ROOT_DIR/build/python-cli-dist/pymobiledevice3/pymobiledevice3" version
rm -rf "$ROOT_DIR/bundled/pymobiledevice3-bundle"
cp -R "$ROOT_DIR/build/python-cli-dist/pymobiledevice3" "$ROOT_DIR/bundled/pymobiledevice3-bundle"
echo "[INFO] Built bundled/pymobiledevice3-bundle/pymobiledevice3"
