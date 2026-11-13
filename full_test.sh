#!/bin/bash
# full_test.sh — cross-platform full test suite entrypoint (bash; runs under
# Linux/macOS and the Git Bash shell on Windows).
#
# Runs every suite in order:
#   1. vm_test.sh          boot VM vs self-hosted mil VM identity over tests/
#   2. bootstrap_test.sh   boot -> native A -> bytecode, bytecode identity
#   3. full_selfhost_test.sh full self-hosting chain + native build + args
#   4. ext_test.sh         precompiled object/shared-library extension model
#   5. every tests/*.mil    executed through the boot VM
#
# Environment:
#   MINILANG_BOOT  path to the built boot `minilang` binary (exe on Windows)
#   MINILANG_DIR   compiler repo root (defaults to this script's dir)
#   CC             C/C++ driver used for native builds (cc/gcc/g++/clang/cl)
#   SKIP_EXT=1     skip the extension shared-library suite (e.g. a stripped
#                  Windows runner without a shared-lib toolchain)
set -e
cd "$(dirname "$0")"

: "${MINILANG_DIR:=$PWD}"
export MINILANG_DIR

# Resolve the boot binary: explicit override first, then the sibling repo in
# either its Unix or Windows build layout.
if [ -z "${MINILANG_BOOT:-}" ]; then
    if [ -x ../minilang-boot/build/Release/minilang.exe ]; then
        MINILANG_BOOT=../minilang-boot/build/Release/minilang.exe
    elif [ -x ../minilang-boot/minilang.exe ]; then
        MINILANG_BOOT=../minilang-boot/minilang.exe
    elif [ -x ../minilang-boot/minilang ]; then
        MINILANG_BOOT=../minilang-boot/minilang
    fi
fi
export MINILANG_BOOT
export MINILANG="${MINILANG_BOOT}"

echo "MINILANG_BOOT=$MINILANG_BOOT"
echo "MINILANG_DIR=$MINILANG_DIR"
echo "CC=${CC:-<default>}"
echo ""

bash vm_test.sh
echo ""
bash bootstrap_test.sh
echo ""
bash full_selfhost_test.sh
echo ""

if [ "${SKIP_EXT:-0}" = "1" ]; then
    echo "=== ext_test.sh skipped (SKIP_EXT=1) ==="
else
    bash ext_test.sh
fi
echo ""

echo "=== every tests/*.mil through the boot VM ==="
shopt -s nullglob
for f in tests/*.mil; do
    echo "--- $f ---"
    "$MINILANG_BOOT" run "$f"
done
shopt -u nullglob

echo ""
echo "=== FULL TEST SUITE PASSED ==="
