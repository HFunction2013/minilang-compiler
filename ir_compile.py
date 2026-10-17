#!/usr/bin/env python3
"""Compile LLVM IR (.ll) to an object file (.o), and optionally link it with
runtime.c into a native executable.

The original script used llvmlite, which is deprecated and no longer available
in this environment. This version drives the portable LLVM project binaries
directly, exactly like the C boot toolchain in minilang-boot: it prefers
$LLVM_DIR/bin/<tool>, then falls back to PATH ($LLVM_LINKER overrides the
linker, default clang).

Usage:
    ir_compile.py <input.ll> <output.o>
    ir_compile.py <input.ll> <output.o> <runtime.c> <output-bin>
"""
import os
import subprocess
import sys


def find_tool(name):
    d = os.environ.get("LLVM_DIR")
    if d:
        cand = os.path.join(d, "bin", name)
        if os.access(cand, os.X_OK):
            return cand
    return name  # rely on PATH


def main():
    if len(sys.argv) not in (3, 5):
        print("Usage: ir_compile.py <input.ll> <output.o> [runtime.c <output-bin>]", file=sys.stderr)
        return 1
    llpath, opath = sys.argv[1], sys.argv[2]
    llc = find_tool("llc")
    cmd = [llc, "-O2", "-filetype=obj", llpath, "-o", opath]
    print("  $ " + " ".join(cmd), file=sys.stderr)
    rc = subprocess.call(cmd)
    if rc != 0:
        print("LLVM llc compilation failed (set LLVM_DIR or put llc on PATH)", file=sys.stderr)
        return rc
    print("Compiled %s -> %s" % (llpath, opath))
    if len(sys.argv) == 5:
        rtc, binpath = sys.argv[3], sys.argv[4]
        linker = os.environ.get("LLVM_LINKER", "clang")
        cc = find_tool(linker)
        cmd = [cc, "-O2", "-no-pie", "-o", binpath, opath, rtc]
        print("  $ " + " ".join(cmd), file=sys.stderr)
        rc = subprocess.call(cmd)
        if rc != 0:
            print("LLVM link failed (set LLVM_LINKER or install clang)", file=sys.stderr)
            return rc
        print("Executable built: %s" % binpath)
    return 0


if __name__ == "__main__":
    sys.exit(main())
