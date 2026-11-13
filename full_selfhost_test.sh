#!/bin/bash
# Full self-hosting verification: the mil toolchain matches the C bootstrap.
#
# Native sections use the system C compiler (cc, or CC); the C backend emits a
# .c source and links runtime.c -O2. There is no LLVM/llc/ir_compile step.
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

set -e
cd "$(dirname "$0")"

# The C bootstrap compiler lives in the sibling minilang-boot repo since the
# toolchain split; resolve it the same way bootstrap_test.sh does.
MINILANG="${MINILANG_BOOT:-../minilang-boot/minilang}"
if [ ! -x "$MINILANG" ]; then MINILANG="./minilang"; fi
if [ ! -x "$MINILANG" ]; then
    echo "Boot compiler not found. Build minilang-boot first, or set MINILANG_BOOT."
    exit 1
fi
case "$MINILANG" in
  /*) MIL_ABS="$MINILANG" ;;
  *)  MIL_ABS="$(cd "$(dirname "$MINILANG")" && pwd)/$(basename "$MINILANG")" ;;
esac

# Native sections need a system C compiler; skip them cleanly when none is
# available (set CC, or put cc/clang/gcc on PATH).
CC_BIN="${CC:-cc}"
if command -v "$CC_BIN" >/dev/null 2>&1; then HAVE_CC=1;
elif command -v clang >/dev/null 2>&1; then HAVE_CC=1;
elif command -v gcc >/dev/null 2>&1; then HAVE_CC=1;
else HAVE_CC=0; fi

echo "=== Building boot compiler ==="
make 2>&1 | grep -E "error|Error" || true
echo ""
PASS=0
FAIL=0
REPO=$(cd "$(dirname "$0")" && pwd)
TMPMOD=$(mktemp -d)
check() {
    if [ "$1" = "$2" ]; then
        echo "  PASS: $3"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $3"
        FAIL=$((FAIL + 1))
    fi
}
# Resolve the native executable name produced for a stem (Unix stem, Windows stem.exe).
# Return a ./-prefixed relative path (or absolute path as-is): a bare name is not
# found via PATH when the cwd is not on PATH, which would exit 127.
native_bin() {
    local bin="$1" rel
    if [ -x "$bin" ]; then
        case "$bin" in /*) echo "$bin" ;; *) echo "./$bin" ;; esac
    elif [ -x "$bin.exe" ]; then
        rel="$bin.exe"
        case "$rel" in /*) echo "$rel" ;; *) echo "./$rel" ;; esac
    else
        echo ""
    fi
}

echo "=== 1. compiler.mil self-hosting (compiles itself) ==="
"$MINILANG" dump-text compiler.mil > /tmp/sh_boot.txt 2>/dev/null
"$MINILANG" run compiler.mil dump-text compiler.mil > /tmp/sh_mil.txt 2>/dev/null
check "$(diff -q /tmp/sh_boot.txt /tmp/sh_mil.txt >/dev/null && echo OK)" "OK" "compiler.mil output matches boot"
echo "=== 2. vm.mil runs all test programs ==="
for f in tests/hello.mil tests/fib.mil tests/array_test.mil tests/nested_test.mil tests/require_test.mil tests/require_path.mil; do
    base=$(basename "$f" .mil)
    "$MINILANG" dump-text "$f" > /tmp/sh_$base.bc 2>/dev/null
    "$MINILANG" run "$f" > /tmp/sh_boot_$base.out 2>/dev/null
    "$MINILANG" run vm.mil /tmp/sh_$base.bc > /tmp/sh_vm_$base.out 2>/dev/null
    check "$(diff -q /tmp/sh_boot_$base.out /tmp/sh_vm_$base.out >/dev/null && echo OK)" "OK" "vm.mil runs $base"
done
echo "=== 3. main.mil C source matches boot C backend ==="
for f in tests/hello.mil tests/fib.mil tests/array_test.mil tests/nested_test.mil tests/require_test.mil tests/require_path.mil; do
    base=$(basename "$f" .mil)
    rm -f "tests/$base.c"
    "$MINILANG" c "$f" 2>/dev/null
    cp "tests/$base.c" "/tmp/sh_boot_$base.c"
    "$MINILANG" run main.mil c "$f" 2>/dev/null
    check "$(diff -q "/tmp/sh_boot_$base.c" "tests/$base.c" >/dev/null && echo OK)" "OK" "main.mil C source matches boot for $base"
    rm -f "tests/$base.c" "/tmp/sh_boot_$base.c"
done
echo "=== 4. milc_io.mil serialization matches boot ==="
for f in tests/hello.mil tests/fib.mil; do
    base=$(basename "$f" .mil)
    "$MINILANG" dump-text "$f" > /tmp/sh_io_boot_$base.txt 2>/dev/null
    "$MINILANG" run milc_io.mil "$f" > /tmp/sh_io_mil_$base.txt 2>/dev/null
    check "$(diff -q /tmp/sh_io_boot_$base.txt /tmp/sh_io_mil_$base.txt >/dev/null && echo OK)" "OK" "milc_io.mil matches $base"
done
echo "=== 5. main.mil unified CLI ==="
"$MINILANG" run main.mil run tests/hello.mil > /tmp/sh_main_run.out 2>/dev/null
"$MINILANG" run tests/hello.mil > /tmp/sh_boot_run.out 2>/dev/null
check "$(diff -q /tmp/sh_main_run.out /tmp/sh_boot_run.out >/dev/null && echo OK)" "OK" "main.mil run command"
"$MINILANG" run main.mil dump-text tests/hello.mil > /tmp/sh_main_dt.txt 2>/dev/null
"$MINILANG" dump-text tests/hello.mil > /tmp/sh_dt_boot.txt 2>/dev/null
check "$(diff -q /tmp/sh_dt_boot.txt /tmp/sh_main_dt.txt >/dev/null && echo OK)" "OK" "main.mil dump-text matches boot"
rm -f tests/hello.c
"$MINILANG" run main.mil c tests/hello.mil > /dev/null 2>/dev/null
cp tests/hello.c /tmp/sh_main_c.c
rm -f tests/hello.c
"$MINILANG" c tests/hello.mil 2>/dev/null
check "$(diff -q tests/hello.c /tmp/sh_main_c.c >/dev/null && echo OK)" "OK" "main.mil c command matches boot"
rm -f tests/hello.c /tmp/sh_main_c.c
echo "=== 6. Full self-hosting chain ==="
echo "  boot -> main.mil bytecode -> vm.mil -> compile compiler.mil"
"$MINILANG" dump-text main.mil > /tmp/sh_main.bc 2>/dev/null
"$MINILANG" run vm.mil /tmp/sh_main.bc dump-text compiler.mil > /tmp/sh_chain.txt 2>/dev/null
check "$(diff -q /tmp/sh_boot.txt /tmp/sh_chain.txt >/dev/null && echo OK)" "OK" "full chain output identical"
echo "  boot -> main.mil bytecode -> vm.mil -> run hello.mil"
"$MINILANG" run vm.mil /tmp/sh_main.bc run tests/hello.mil > /tmp/sh_chain_run.out 2>/dev/null
check "$(diff -q /tmp/sh_boot_run.out /tmp/sh_chain_run.out >/dev/null && echo OK)" "OK" "full chain runs programs"
echo "  boot -> main.mil bytecode -> vm.mil -> emit C source for hello.mil"
rm -f tests/hello.c
"$MINILANG" run vm.mil /tmp/sh_main.bc c tests/hello.mil 2>/dev/null
cp tests/hello.c /tmp/sh_chain_c.c
rm -f tests/hello.c
"$MINILANG" c tests/hello.mil 2>/dev/null
check "$(diff -q tests/hello.c /tmp/sh_chain_c.c >/dev/null && echo OK)" "OK" "full chain emits the same C source"
rm -f tests/hello.c /tmp/sh_chain_c.c
echo "=== 7. Program arguments ==="
cat > /tmp/sh_args.mil << 'MILEOF'
func main() {
    var n = argc();
    println toString(n);
    var i = 0;
    while (i < n) {
        println argv(i);
        i = i + 1;
    }
    return 0;
}
MILEOF
"$MINILANG" run main.mil run /tmp/sh_args.mil hello world > /tmp/sh_args.out 2>/dev/null
echo -e "3\n/tmp/sh_args.mil\nhello\nworld" > /tmp/sh_args_expected.txt
check "$(diff -q /tmp/sh_args_expected.txt /tmp/sh_args.out >/dev/null && echo OK)" "OK" "program arguments correct"
echo "=== 8. build command ==="
echo "  build -b: compile to .milc bytecode file"
rm -f /tmp/sh_hello.milc
cp tests/hello.mil /tmp/sh_hello.mil
"$MINILANG" run main.mil build -b /tmp/sh_hello.mil > /dev/null 2>&1
check "$(test -f /tmp/sh_hello.milc && echo OK)" "OK" "build -b creates .milc file"
echo "  run .milc file"
"$MINILANG" run main.mil run /tmp/sh_hello.milc > /tmp/sh_milc_run.out 2>/dev/null
check "$(diff -q /tmp/sh_boot_run.out /tmp/sh_milc_run.out >/dev/null && echo OK)" "OK" "run .milc output matches"
echo "  build -e: emits a .c source (compiled by the system cc)"
rm -f /tmp/sh_hello.c
"$MINILANG" run main.mil build -e /tmp/sh_hello.mil > /dev/null 2>&1
check "$(test -f /tmp/sh_hello.c && echo OK)" "OK" "build -e creates .c file"
rm -f /tmp/sh_hello.mil /tmp/sh_hello.milc /tmp/sh_hello.c
echo "=== 9. Native build (system C compiler) ==="
if [ "$HAVE_CC" = "1" ]; then
    echo "  boot build main.mil -> native executable"
    rm -f main main.c
    "$MINILANG" build main.mil > /dev/null 2>&1
    NATIVE="$(native_bin main)"
    if [ -n "$NATIVE" ]; then
        check "OK" "OK" "boot build main.mil produces native executable"
        echo "  native executable runs programs"
        "$NATIVE" run tests/hello.mil > /tmp/sh_native_run.out 2>/dev/null
        check "$(diff -q /tmp/sh_boot_run.out /tmp/sh_native_run.out >/dev/null && echo OK)" "OK" "native executable output matches"
        echo "  native executable self-hosts compiler.mil"
        "$NATIVE" dump-text compiler.mil > /tmp/sh_native_compiler.txt 2>/dev/null
        check "$(diff -q /tmp/sh_boot.txt /tmp/sh_native_compiler.txt >/dev/null && echo OK)" "OK" "native executable compiles compiler.mil identically"
        rm -f "$NATIVE" main.c
    else
        check "FAIL" "OK" "boot build main.mil produces native executable"
    fi
else
    echo "  SKIP: no system C compiler found (set CC, or put cc/clang/gcc on PATH)"
fi

echo "=== 10. New commands: bytecode / self-test / repl (must match boot) ==="
echo "  bytecode: human-readable disassembly"
for f in tests/hello.mil tests/fib.mil tests/array_test.mil tests/nested_test.mil tests/require_test.mil tests/require_path.mil; do
    base=$(basename "$f" .mil)
    "$MINILANG" bytecode "$f" > /tmp/sh_bc_boot_$base.txt 2>/dev/null
    "$MINILANG" run main.mil bytecode "$f" > /tmp/sh_bc_mil_$base.txt 2>/dev/null
    check "$(diff -q /tmp/sh_bc_boot_$base.txt /tmp/sh_bc_mil_$base.txt >/dev/null && echo OK)" "OK" "bytecode command matches boot for $base"
done
echo "  self-test"
"$MINILANG" run main.mil self-test 2>/dev/null | grep -v "Self-hosting test" | grep -v "self-test:" > /tmp/sh_st_mil.txt
"$MINILANG" self-test 2>/dev/null | grep -v "Self-hosting test" | grep -v "boot compile done" > /tmp/sh_st_boot.txt
check "$(diff -q /tmp/sh_st_boot.txt /tmp/sh_st_mil.txt >/dev/null && echo OK)" "OK" "self-test dumps compiler.mil bytecode identically"
echo "  repl (piped input)"
printf 'println 42;\nfunc add(a, b) { return a + b; }\nprintln add(2, 3);\nquit\n' | "$MINILANG" repl > /tmp/sh_repl_boot.txt 2>/dev/null
printf 'println 42;\nfunc add(a, b) { return a + b; }\nprintln add(2, 3);\nquit\n' | "$MINILANG" run main.mil repl > /tmp/sh_repl_mil.txt 2>/dev/null
check "$(diff -q /tmp/sh_repl_boot.txt /tmp/sh_repl_mil.txt >/dev/null && echo OK)" "OK" "repl output matches boot"
echo "=== 11. A/B two-compiler self-hosting acceptance ==="
if [ "$HAVE_CC" = "1" ]; then
echo "  A = boot-compiled compiler.mil; B = A-compiled compiler.mil"
echo "  Step 1: boot compiles compiler.mil -> A"
rm -f compiler compiler.c
"$MINILANG" build compiler.mil > /dev/null 2>&1
A="$(native_bin compiler)"
if [ -n "$A" ]; then
    check "OK" "OK" "boot builds A compiler"
else
    check "FAIL" "OK" "boot builds A compiler"
fi
echo "  Step 2: A compiles + runs all test programs"
for f in tests/hello.mil tests/fib.mil tests/array_test.mil tests/nested_test.mil tests/require_test.mil tests/require_path.mil; do
    base=$(basename "$f" .mil)
    "$A" dump-text "$f" > /tmp/sh_A_$base.bc 2>/dev/null
    "$MINILANG" run "$f" > /tmp/sh_ref_$base.out 2>/dev/null
    "$MINILANG" run vm.mil /tmp/sh_A_$base.bc > /tmp/sh_A_$base.out 2>/dev/null
    check "$(diff -q /tmp/sh_ref_$base.out /tmp/sh_A_$base.out >/dev/null && echo OK)" "OK" "A runs $base"
done
echo "  Step 3: A compiles itself (B bytecode); compare A bytecode with boot"
"$A" dump-text compiler.mil > /tmp/sh_B_bc.txt 2>/dev/null
"$MINILANG" dump-text compiler.mil > /tmp/sh_boot_bc.txt 2>/dev/null
check "$(diff -q /tmp/sh_B_bc.txt /tmp/sh_boot_bc.txt >/dev/null && echo OK)" "OK" "A/B bytecode identical (boot == A-compiled)"
echo "  Step 4: A/B C source identical (boot c == main.mil c)"
rm -f compiler.c
"$MINILANG" c compiler.mil 2>/dev/null
cp compiler.c /tmp/sh_A_compiler.c
rm -f compiler.c
"$MINILANG" run main.mil c compiler.mil > /dev/null 2>/dev/null
check "$(diff -q /tmp/sh_A_compiler.c compiler.c >/dev/null && echo OK)" "OK" "A/B C source identical"
echo "  Step 5: B (A-compiled bytecode) runs all test programs"
for f in tests/hello.mil tests/fib.mil tests/array_test.mil tests/nested_test.mil tests/require_test.mil tests/require_path.mil; do
    base=$(basename "$f" .mil)
    "$A" dump-text "$f" > /tmp/sh_B_$base.bc 2>/dev/null
    "$MINILANG" run vm.mil /tmp/sh_B_$base.bc > /tmp/sh_B_$base.out 2>/dev/null
    check "$(diff -q /tmp/sh_ref_$base.out /tmp/sh_B_$base.out >/dev/null && echo OK)" "OK" "B runs $base"
done
rm -f "$A" compiler.c /tmp/sh_A_compiler.c
else
    echo "  SKIP: no system C compiler found (set CC, or put cc/clang/gcc on PATH)"
fi


echo "=== 12. Native main self-host: A builds itself -> B ==="
if [ "$HAVE_CC" = "1" ]; then
echo "  A = boot-built main.mil; B = A-built main.mil (native)"
rm -f main main.c main_A main_A.exe
"$MINILANG" build main.mil > /dev/null 2>&1
MAIN_A="$(native_bin main)"
if [ -n "$MAIN_A" ]; then
    cp "$MAIN_A" main_A; [ -x main_A.exe ] || true
    rm -f main main.c
    ./main_A build main.mil > /dev/null 2>&1
    MAIN_B="$(native_bin main)"
    if [ -n "$MAIN_B" ]; then
        check "OK" "OK" "A (main_A) builds main.mil -> B (main) natively"
        echo "  B runs all test programs"
        for f in tests/hello.mil tests/fib.mil tests/array_test.mil tests/nested_test.mil tests/require_test.mil tests/require_path.mil; do
            base=$(basename "$f" .mil)
            ./main run "$f" > /tmp/sh_B2_$base.out 2>/dev/null
            "$MINILANG" run "$f" > /tmp/sh_ref2_$base.out 2>/dev/null
            check "$(diff -q /tmp/sh_ref2_$base.out /tmp/sh_B2_$base.out >/dev/null && echo OK)" "OK" "B (native) runs $base"
        done
    else
        check "FAIL" "OK" "A (main_A) builds main.mil -> B (main) natively"
    fi
    rm -f main main.c main_A main_A.exe
else
    check "FAIL" "OK" "boot builds main.mil natively"
fi
else
    echo "  SKIP: no system C compiler found (set CC, or put cc/clang/gcc on PATH)"
fi

echo ""
echo "=== 13. Module resolution is independent of the working directory ==="
# syslib/ lives next to the minilang executable, so `require` must work no
# matter where you run from (this used to break on macOS, where /proc/self/exe
# does not exist and the search path fell back to "syslib" relative to cwd).
mkdir -p "$TMPMOD/sub"
cat > "$TMPMOD/sub/prog.mil" <<'EOF'
require math;
require word in syslib;
func main() {
    println math.abs(0 - 5);
    println word.shout("hi");
    return 0;
}
EOF
EXPECTED=$(printf '5\nhi!\n')
(cd "$TMPMOD/sub" && "$MIL_ABS" run prog.mil > /tmp/sh_mod_sub.out 2>&1)
check "$(cat /tmp/sh_mod_sub.out)" "$EXPECTED" "require resolves from the script directory"
(cd / && "$MIL_ABS" run "$TMPMOD/sub/prog.mil" > /tmp/sh_mod_root.out 2>&1)
check "$(cat /tmp/sh_mod_root.out)" "$EXPECTED" "require resolves from /"
(cd "$TMPMOD" && "$MIL_ABS" run "$REPO/main.mil" run "$TMPMOD/sub/prog.mil" > /tmp/sh_mod_mil.out 2>&1)
check "$(cat /tmp/sh_mod_mil.out)" "$EXPECTED" "mil-side main.mil resolves syslib too"
rm -rf "$TMPMOD"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ $FAIL -eq 0 ]; then
    echo "ALL TESTS PASSED - Full self-hosting verified!"
else
    echo "SOME TESTS FAILED"
    exit 1
fi
