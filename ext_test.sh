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
    "$exe" build -e "$PROG" "$EXTC" > /dev/null 2>&1 || { echo "  FAIL: build ($name)"; exit 1; }
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
run_one "self-hosted main.mil" "./main"

echo ""
echo "=== Results: ext extension + OpaqueType verified ==="
