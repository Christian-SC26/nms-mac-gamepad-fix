#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/src/gamepad_bridge.m"
OUT="$SCRIPT_DIR/bin/libsteam_api.dylib"
EMU="$SCRIPT_DIR/bin/libsteam_emu.dylib"

if [ ! -f "$EMU" ]; then
    echo "[-] Error: $EMU not found!"
    exit 1
fi

echo "[*] Compiling universal libsteam_api.dylib (arm64 + x86_64)..."
clang -arch arm64 -arch x86_64 -dynamiclib -O2 \
    -fmodules -framework Foundation -framework GameController \
    -Wl,-reexport_library,"$EMU" \
    -install_name "@loader_path/libsteam_api.dylib" \
    -o "$OUT" \
    "$SRC"

codesign --force -s - "$OUT"
echo "[+] Successfully built and signed $OUT"
