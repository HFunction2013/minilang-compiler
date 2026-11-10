#!/usr/bin/env python3
"""Compile LLVM IR (.ll) to an object file, and optionally link it with
runtime.c and user C extensions into a native executable.

Drives the portable LLVM project binaries directly: prefers
$LLVM_DIR/bin/<tool>, then falls back to PATH ($LLVM_LINKER overrides the
linker, default clang).

Usage:
    ir_compile.py <input.ll> <output.o>
    ir_compile.py <input.ll> <output.o> <runtime.c> <output-bin> [ext.c ...]
    ir_compile.py <input.ll> <output.o> <runtime.c> <output-bin> --dynamic [ext.c|ext.so ...]
"""
import os
import subprocess
import sys

IS_WINDOWS = os.name == "nt"


def find_tool(name):
    # On Windows, append .exe if the bare name isn't found.
    candidates = [name]
    if IS_WINDOWS:
        candidates.insert(0, name + ".exe")
    d = os.environ.get("LLVM_DIR")
    if d:
        for c in list(candidates):
            cand = os.path.join(d, "bin", c)
            if os.path.exists(cand):
                return cand
    return candidates[0]


def main():
    if len(sys.argv) < 3 or len(sys.argv) == 4:
        print("Usage: ir_compile.py <input.ll> <output.o> [runtime.c <output-bin> [ext.c ...]]", file=sys.stderr)
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
    if len(sys.argv) >= 5:
        rtc, binpath = sys.argv[3], sys.argv[4]
        rest = sys.argv[5:]
        dynamic = False
        if rest and rest[0] == "--dynamic":
            dynamic = True
            rest = rest[1:]
        exts = rest
        linker = os.environ.get("LLVM_LINKER", "clang")
        cc = find_tool(linker)
        # -I <rtc dir> so user extensions can `#include "minilang_runtime.h"`.
        rtc_dir = os.path.dirname(os.path.abspath(rtc))
        # -no-pie is a Unix-only linker flag; skip on Windows.
        cmd = [cc, "-O2", "-I", rtc_dir]
        if not IS_WINDOWS:
            cmd.append("-no-pie")
        cmd += ["-o", binpath, opath, rtc]
        # Static (default): extension .c sources are linked in directly.
        # --dynamic: compile each .c to a shared lib beside the executable and
        # link it, so native code can be swapped without rebuilding.
        for e in exts:
            if dynamic and e.endswith(".c"):
                suffix = ".dll" if IS_WINDOWS else ".so"
                sopath = os.path.splitext(binpath)[0] + "_ext%d%s" % (exts.index(e), suffix)
                if IS_WINDOWS:
                    # Bundle runtime.c into the DLL so it needs no symbols from
                    # the host exe (Windows has no --export-dynamic), export the
                    # entry points this source defines and emit an import
                    # library the exe links against; fall back to GNU ld
                    # spellings for MinGW.
                    libpath = sopath[:-4] + ".lib"
                    with open(e, "r", encoding="utf-8", errors="replace") as f:
                        entry = []
                        for name in re.findall(r"ml_native_([A-Za-z_][A-Za-z0-9_]*)", f.read()):
                            sym = "ml_native_" + name
                            if sym not in entry:
                                entry.append(sym)
                    exports = ["-Wl,/export:%s" % s for s in entry]
                    sub = [cc, "-O2", "-shared", "-I", rtc_dir, e,
                           os.path.join(rtc_dir, "runtime.c"), "-o", sopath,
                           "-Wl,/implib:%s" % libpath] + exports
                    print("  $ " + " ".join(sub), file=sys.stderr)
                    rc = subprocess.call(sub)
                    if rc != 0:
                        sub = [cc, "-O2", "-shared", "-I", rtc_dir, e,
                               os.path.join(rtc_dir, "runtime.c"), "-o", sopath,
                               "-Wl,--out-implib,%s" % libpath, "-Wl,--export-all-symbols"]
                        print("  $ " + " ".join(sub), file=sys.stderr)
                        rc = subprocess.call(sub)
                    if rc != 0:
                        print("Failed to compile shared extension %s" % e, file=sys.stderr)
                        return rc
                    cmd.append(libpath)
                else:
                    sub = [cc, "-O2", "-fPIC", "-shared", "-I", rtc_dir, e, "-o", sopath]
                    print("  $ " + " ".join(sub), file=sys.stderr)
                    rc = subprocess.call(sub)
                    if rc != 0:
                        print("Failed to compile shared extension %s" % e, file=sys.stderr)
                        return rc
                    cmd.append(sopath)
                    cmd.append("-Wl,-rpath,$ORIGIN")
            else:
                cmd.append(e)
        print("  $ " + " ".join(cmd), file=sys.stderr)
        rc = subprocess.call(cmd)
        if rc != 0:
            print("LLVM link failed (set LLVM_LINKER or install clang)", file=sys.stderr)
            return rc
        print("Executable built: %s" % binpath)
    return 0


if __name__ == "__main__":
    sys.exit(main())
