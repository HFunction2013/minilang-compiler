#!/bin/bash
# ext_test.sh — verify user C extensions + OpaqueType end to end.
#
# The toolchain never compiles extension C on the fly. This script first
# precompiles tests/ext/file_counter.c itself:
#   * an object file linked into a native executable via `build -e`, and
#   * a shared library loaded by the interpreted VM via `run -e`.
# then runs the executables and asserts the opaque-handle behaviour:
#   - two opens yield different handles (identity ==)
#   - an opaque value prints as <opaque>
#   - a non-NULL handle is truthy
#   - the C extension can count lines through an opaque FILE* handle
#
# Usage: ./ext_test.sh   (set MINILANG_BOOT / MINILANG_DIR / CC as for other suites)
set -e

cd "$(dirname "$0")"
MINILANG="${MINILANG:-../minilang-boot/minilang}"
if [ ! -x "$MINILANG" ]; then MINILANG="./minilang"; fi
CC="${CC:-cc}"

EXT_DIR=tests/ext
PROG=$EXT_DIR/opaque_test.mil
EXTC=$EXT_DIR/file_counter.c
OBJ=$EXT_DIR/file_counter.o
BIN=$EXT_DIR/opaque_test

# Shared-library artifact and link flags depend on platform and driver.
UNAME_S="$(uname -s)"
CC_BASE="$(basename "$CC")"
case "$CC_BASE" in
    cl|cl.exe) MSVC=1 ;;
    *)         MSVC=0 ;;
esac
# Extension sources are plain C. A C++ driver (g++/clang++) would mangle the
# ml_native_* entry points the loader looks up by unmangled name, so precompile
# them with the matching C driver instead.
case "$CC_BASE" in
    g++)       EXT_CC=gcc ;;
    clang++|c++) EXT_CC=clang ;;
    *)         EXT_CC=$CC ;;
esac
case "$UNAME_S" in
    Darwin)        SO=$EXT_DIR/file_counter.dylib; SHARED_FLAGS="-dynamiclib -undefined dynamic_lookup" ;;
    MINGW*|MSYS*|*NT*) SO=$EXT_DIR/file_counter.dll ;;
    *)             SO=$EXT_DIR/file_counter.so;    SHARED_FLAGS="-shared" ;;
esac

# Boot include dir for minilang_runtime.h: sibling minilang-boot repo. The exe
# may live in build/Release (cmake/MSVC) or the repo root (make), so walk up
# until the runtime header is found.
BOOT_DIR="$(cd "$(dirname "$MINILANG")" && pwd)"
while [ ! -f "$BOOT_DIR/minilang_runtime.h" ] && [ "$BOOT_DIR" != "/" ]; do
    BOOT_DIR="$(cd "$BOOT_DIR/.." && pwd)"
done
if [ "$MSVC" = 1 ]; then
    # Git Bash rewrites cl's `/O2` `/I` `/Fo` switches as POSIX paths unless
    # argument conversion is disabled; also give cl a native include path.
    export MSYS2_ARG_CONV_EXCL="*"
    BOOT_DIR="$(cygpath -m "$BOOT_DIR" 2>/dev/null || echo "$BOOT_DIR")"
    # A Windows DLL cannot resolve host helpers from the loaded executable the
    # way ELF/dlopen does; link against the boot exe's import library. The DLL
    # always loads into the boot minilang.exe process, so its recorded module
    # name matches at runtime.
    _exe_dir="$(cd "$(dirname "$MINILANG")" && pwd)"
    _exe_stem="$(basename "$MINILANG")"; _exe_stem="${_exe_stem%.*}"
    IMPLIB="$(cygpath -m "$_exe_dir/$_exe_stem.lib" 2>/dev/null || echo "$_exe_dir/$_exe_stem.lib")"
fi

check() {
    if [ "$1" = "$2" ]; then
        echo "  PASS: $3"
    else
        echo "  FAIL: $3 (expected '$2', got '$1')"
        exit 1
    fi
}

echo "=== Precompile extension C (no on-the-fly compilation by minilang) ==="
if [ "$MSVC" = 1 ]; then
    "$EXT_CC" /O2 /I"$BOOT_DIR" /c "$EXTC" /Fo"$OBJ"
    "$EXT_CC" /O2 /I"$BOOT_DIR" /LD "$EXTC" "$IMPLIB" /Fe"$SO"
else
    "$EXT_CC" -O2 -fPIC -I"$BOOT_DIR" -c "$EXTC" -o "$OBJ"
    # Shared-library link flags differ by platform: Linux/MinGW use `-shared`;
    # macOS needs `-dynamiclib` and allows undefined symbols resolved at dlopen.
    "$EXT_CC" -O2 -fPIC $SHARED_FLAGS -I"$BOOT_DIR" "$EXTC" -o "$SO"
fi
echo "  object: $OBJ ; shared library: $SO"

run_one() {
    local name="$1" exe="$2"
    echo "--- $name (build -e, link precompiled object) ---"
    rm -f "$BIN" "$BIN.exe" "$BIN".c
    # Note: `$exe` intentionally unquoted so a compound launcher like
    # "$MINILANG run main.mil" splits into the interpreter + entry file.
    $exe build -e "$PROG" "$OBJ" > /dev/null 2>&1 || { echo "  FAIL: build ($name)"; exit 1; }
    local BINRUN="$BIN"
    if [ ! -x "$BINRUN" ]; then BINRUN="$BIN.exe"; fi
    [ -x "$BINRUN" ] || { echo "  FAIL: no executable produced ($name)"; exit 1; }
    local out
    out=$("$BINRUN" "$PROG")
    local same opaque lines truthy
    same=$(echo "$out" | sed -n 's/^same handle: //p')
    opaque=$(echo "$out" | sed -n 's/^opaque value: //p')
    lines=$(echo "$out" | sed -n 's/^line count: //p')
    truthy=$(echo "$out" | sed -n 's/^truthy: //p')
    check "$same" "0" "two opens give different handles"
    check "$opaque" "<opaque>" "opaque prints as <opaque>"
    check "$lines" "50" "extension counts lines via opaque FILE*"
    check "$truthy" "1" "non-NULL opaque is truthy"
}

run_one "boot compiler" "$MINILANG"
# Self-hosted CLI: run main.mil through the boot VM (no `main` binary needed).
run_one "self-hosted main.mil" "$MINILANG run main.mil"

echo ""
echo "=== run -e: interpreted VM loads a prebuilt shared library ==="
echo "--- run -e (boot compiler) ---"
out=$("$MINILANG" run -e "$PROG" "$SO" -- "$PROG" 2>&1) || echo "  [run -e exited non-zero]"
check "$(echo "$out" | sed -n 's/^same handle: //p')" "0" "run -e: two opens give different handles"
check "$(echo "$out" | sed -n 's/^opaque value: //p')" "<opaque>" "run -e: opaque prints as <opaque>"
check "$(echo "$out" | sed -n 's/^line count: //p')" "50" "run -e: extension counts lines via opaque FILE*"
check "$(echo "$out" | sed -n 's/^truthy: //p')" "1" "run -e: non-NULL opaque is truthy"

echo "--- run -e (self-hosted main.mil loads the shared library too) ---"
out=$("$MINILANG" run main.mil run -e "$PROG" "$SO" -- "$PROG" 2>&1) || echo "  [self-hosted run -e exited non-zero]"
check "$(echo "$out" | sed -n 's/^same handle: //p')" "0" "self-hosted run -e: two opens give different handles"
check "$(echo "$out" | sed -n 's/^opaque value: //p')" "<opaque>" "self-hosted run -e: opaque prints as <opaque>"
check "$(echo "$out" | sed -n 's/^line count: //p')" "50" "self-hosted run -e: extension counts lines via opaque FILE*"
check "$(echo "$out" | sed -n 's/^truthy: //p')" "1" "self-hosted run -e: non-NULL opaque is truthy"

echo ""
echo "=== Reject raw .c extension sources ==="
if "$MINILANG" build -e "$PROG" "$EXTC" > /dev/null 2>&1; then
    echo "  FAIL: build -e accepted a raw .c source"
    exit 1
else
    echo "  PASS: build -e rejects a raw .c source"
fi

echo ""
echo "=== Results: extension + OpaqueType verified ==="
