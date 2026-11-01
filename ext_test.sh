#!/bin/bash
# ext_test.sh — verify user C extensions + OpaqueType end to end.
#
# Builds tests/ext/opaque_test.mil twice (boot compiler and self-hosted
# main.mil), linking tests/ext/file_counter.c, then runs the executables and
# asserts the opaque-handle behaviour:
#   - two opens yield different handles (identity ==)
#   - an opaque value prints as <opaque>
#   - a non-NULL handle is truthy
#   - the C extension can count lines through an opaque FILE* handle
#
# Usage: ./ext_test.sh   (set LLVM_DIR/PATH/MINILANG_DIR as for the other suites)
set -e

cd "$(dirname "$0")"
MINILANG=${MINILANG:-../minilang-boot/minilang}

EXT_DIR=tests/ext
PROG=$EXT_DIR/opaque_test.mil
EXTC=$EXT_DIR/file_counter.c
BIN=$EXT_DIR/opaque_test

check() {
    if [ "$1" = "$2" ]; then
        echo "  PASS: $3"
    else
        echo "  FAIL: $3 (expected '$2', got '$1')"
        exit 1
    fi
}

pass=0
fail=0
run_one() {
    local name="$1" exe="$2"
    echo "--- $name ---"
    rm -f "$BIN" "$BIN".ll "$BIN".o
    # Note: `$exe` intentionally unquoted so a compound launcher like
    # "$MINILANG run main.mil" splits into the interpreter + entry file.
    $exe build -e "$PROG" "$EXTC" > /dev/null 2>&1 || { echo "  FAIL: build ($name)"; exit 1; }
    [ -x "$BIN" ] || { echo "  FAIL: no executable produced ($name)"; exit 1; }
    local out
    out=$("$BIN" "$PROG")
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
echo "=== run -e: boot VM loads a C extension via a shared lib ==="
echo "--- run -e (boot compiler) ---"
out=$("$MINILANG" run -e "$PROG" "$EXTC" -- "$PROG" 2>/dev/null)
check "$(echo "$out" | sed -n 's/^same handle: //p')" "0" "run -e: two opens give different handles"
check "$(echo "$out" | sed -n 's/^opaque value: //p')" "<opaque>" "run -e: opaque prints as <opaque>"
check "$(echo "$out" | sed -n 's/^line count: //p')" "50" "run -e: extension counts lines via opaque FILE*"
check "$(echo "$out" | sed -n 's/^truthy: //p')" "1" "run -e: non-NULL opaque is truthy"

echo "--- run -e (self-hosted main.mil must give a clear error) ---"
err=$("$MINILANG" run main.mil run -e "$PROG" "$EXTC" 2>&1 | head -1)
case "$err" in
    *"not supported"*) echo "  PASS: main run -e reports unsupported" ;;
    *) echo "  FAIL: main run -e should refuse with a clear message (got: $err)"; exit 1 ;;
esac

echo ""
echo "=== build -e --dynamic: extensions linked as shared libraries ==="
echo "--- dynamic build (boot compiler) ---"
rm -f "$BIN" "$BIN".ll "$BIN".o "$BIN"_ext0.so
"$MINILANG" build -e --dynamic "$PROG" "$EXTC" > /dev/null 2>&1 || { echo "  FAIL: dynamic build"; exit 1; }
[ -f "$BIN"_ext0.so ] || { echo "  FAIL: no shared extension produced"; exit 1; }
out=$("$BIN" "$PROG")
check "$(echo "$out" | sed -n 's/^line count: //p')" "50" "dynamic executable works via .so extension"

echo ""
echo "=== Results: ext extension + OpaqueType verified ==="
