#!/bin/bash
# Self-hosting verification for minilang.
# Requires a boot `minilang` binary (built from minilang-boot) on PATH or in
# $MINILANG_BOOT / ../minilang-boot/minilang.
#
# Stage 1: boot compiles compiler.mil -> native executable A (LLVM)
# Stage 2: A compiles compiler.mil -> bytecode text B
# Stage 3: boot compiles compiler.mil -> bytecode text A'
# Stage 4: compare A' and B (must be identical)
set -e
cd "$(dirname "$0")"

MINILANG="${MINILANG_BOOT:-../minilang-boot/minilang}"
if [ ! -x "$MINILANG" ]; then MINILANG="./minilang"; fi
if [ ! -x "$MINILANG" ]; then
    echo "Boot compiler not found. Build minilang-boot first, or set MINILANG_BOOT."
    exit 1
fi
echo "Using boot binary: $MINILANG"
echo ""

echo "=== Stage 1: boot compiles compiler.mil -> native executable A ==="
"$MINILANG" build -e compiler.mil 2>&1 | tail -1
if [ ! -x ./compiler ]; then
    echo "ERROR: failed to build compiler executable"
    exit 1
fi
echo "A = ./compiler ($(wc -c < compiler) bytes)"
echo ""

echo "=== Stage 2: A compiles compiler.mil -> bytecode text B ==="
./compiler dump-text compiler.mil > /tmp/minilang_stage2_b.txt 2>/tmp/minilang_stage2_err.txt
echo "Exit code: $?"
if [ -s /tmp/minilang_stage2_err.txt ]; then
    echo "Errors:"
    cat /tmp/minilang_stage2_err.txt
    exit 1
fi
echo "B: $(wc -l < /tmp/minilang_stage2_b.txt) lines"
echo ""

echo "=== Stage 3: boot compiles compiler.mil -> bytecode text A' ==="
"$MINILANG" dump-text compiler.mil > /tmp/minilang_stage3_a.txt 2>/dev/null
echo "A': $(wc -l < /tmp/minilang_stage3_a.txt) lines"
echo ""

echo "=== Stage 4: compare A' and B ==="
if diff -q /tmp/minilang_stage3_a.txt /tmp/minilang_stage2_b.txt > /dev/null 2>&1; then
    echo "SUCCESS: Boot and self-hosted bytecode are IDENTICAL!"
    exit 0
else
    echo "FAILURE: Bytecode outputs differ!"
    diff /tmp/minilang_stage3_a.txt /tmp/minilang_stage2_b.txt | head -30
    exit 1
fi
