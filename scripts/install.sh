#!/bin/sh
# install.sh - build and install the full minilang toolchain (self-hosted
# compiler + boot VM + standard library + documentation) onto a standard user
# prefix (default ~/.local).
#
# Steps: fetch boot / compiler / syslib / document (or reuse local checkouts)
# -> compile the boot VM on site -> lay down bin/ and lib/minilang plus
# share/doc/minilang -> add the prefix bin to PATH -> run the full test suite
# against the installed layout.
#
# Layout under $PREFIX:
#   bin/minilang                       wrapper: boot run lib/minilang/main.mil
#   lib/minilang/bin/minilang          real boot binary
#   lib/minilang/runtime.c             C runtime for the native backend
#   lib/minilang/minilang.h            shared C headers
#   lib/minilang/minilang_runtime.h
#   lib/minilang/main.mil compiler.mil vm.mil milc_io.mil   self-hosted sources
#   lib/minilang/syslib/*.mil          bundled standard library
#   share/doc/minilang/docs/*.md       user documentation
#
# Environment / flags:
#   MINILANG_PREFIX   install prefix (default $HOME/.local)
#   MINILANG_REPO     compiler git URL
#   MINILANG_BOOT_REPO boot git URL
#   MINILANG_DOC_REPO document git URL
#   MINILANG_SYS_REPO syslib git URL
#   MINILANG_BRANCH   branch/tag to clone (default experiment/asm-gen)
#   COMPILER_SOURCE / BOOT_SOURCE / DOC_SOURCE / SYS_SOURCE reuse local trees
#   SKIP_TESTS=1      do not run the full test suite after install
#   KEEP_WORK=1       keep the temporary build tree for inspection
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PREFIX="${MINILANG_PREFIX:-$HOME/.local}"
BRANCH="${MINILANG_BRANCH:-experiment/asm-gen}"
COMPILER_REPO="${MINILANG_REPO:-https://github.com/HFunction2013/minilang-compiler.git}"
BOOT_REPO="${MINILANG_BOOT_REPO:-https://github.com/HFunction2013/minilang-boot.git}"
DOC_REPO="${MINILANG_DOC_REPO:-https://github.com/HFunction2013/minilang-document.git}"
SYS_REPO="${MINILANG_SYS_REPO:-https://github.com/HFunction2013/minilang-syslib.git}"

COMPILER_SOURCE="${COMPILER_SOURCE:-}"
BOOT_SOURCE="${BOOT_SOURCE:-}"
DOC_SOURCE="${DOC_SOURCE:-}"
SYS_SOURCE="${SYS_SOURCE:-}"

log()  { printf '\033[1;36m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[install]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[install]\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX="$2"; shift 2 ;;
        --compiler) COMPILER_SOURCE="$2"; shift 2 ;;
        --boot)   BOOT_SOURCE="$2"; shift 2 ;;
        --doc)    DOC_SOURCE="$2"; shift 2 ;;
        --sys)    SYS_SOURCE="$2"; shift 2 ;;
        --branch) BRANCH="$2"; shift 2 ;;
        --skip-tests) SKIP_TESTS=1; shift ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$PREFIX" ] || die "empty prefix"

WORK=""
cleanup() {
    if [ -n "$WORK" ] && [ -d "$WORK" ] && [ "${KEEP_WORK:-0}" != "1" ]; then
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

clone() { # $1 repo url, $2 dirname, $3 out-var
    url="$1"; dir="$2"
    if [ ! -d "$WORK/$dir" ]; then
        log "Cloning $url ($BRANCH)"
        git clone --depth 1 --branch "$BRANCH" "$url" "$WORK/$dir"
    fi
    eval "$3=\$WORK/$dir"
}

# ---- 1. Resolve sources: local siblings first, otherwise clone into WORK ----
if [ -z "$COMPILER_SOURCE" ] && [ -f "$REPO_ROOT/main.mil" ]; then
    COMPILER_SOURCE="$REPO_ROOT"
    log "Using local compiler checkout: $COMPILER_SOURCE"
fi
if [ -z "$BOOT_SOURCE" ] && [ -f "$REPO_ROOT/../minilang-boot/main.c" ]; then
    BOOT_SOURCE="$(cd "$REPO_ROOT/../minilang-boot" && pwd)"
    log "Using local boot checkout: $BOOT_SOURCE"
fi
if [ -z "$DOC_SOURCE" ] && [ -d "$REPO_ROOT/../minilang-document/docs" ]; then
    DOC_SOURCE="$(cd "$REPO_ROOT/../minilang-document" && pwd)"
    log "Using local document checkout: $DOC_SOURCE"
fi
if [ -z "$SYS_SOURCE" ] && [ -d "$COMPILER_SOURCE/syslib" ] && [ -f "$COMPILER_SOURCE/syslib/builtin.mil" ]; then
    SYS_SOURCE="$COMPILER_SOURCE/syslib"
elif [ -z "$SYS_SOURCE" ] && [ -f "$COMPILER_SOURCE/../minilang-syslib/builtin.mil" ]; then
    SYS_SOURCE="$(cd "$COMPILER_SOURCE/../minilang-syslib" && pwd)"
    log "Using local syslib checkout: $SYS_SOURCE"
fi

if [ -z "$WORK" ] && { [ -z "$COMPILER_SOURCE" ] || [ -z "$BOOT_SOURCE" ] || [ -z "$DOC_SOURCE" ] || [ -z "$SYS_SOURCE" ]; }; then
    WORK="$(mktemp -d)"
fi
[ -z "$COMPILER_SOURCE" ] && clone "$COMPILER_REPO" compiler COMPILER_SOURCE
[ -z "$BOOT_SOURCE" ]    && clone "$BOOT_REPO"    boot    BOOT_SOURCE
[ -z "$DOC_SOURCE" ]     && clone "$DOC_REPO"     document DOC_SOURCE
[ -z "$SYS_SOURCE" ]     && clone "$SYS_REPO"     syslib  SYS_SOURCE

[ -f "$BOOT_SOURCE/main.c" ]     || die "boot source not found ($BOOT_SOURCE)"
[ -f "$COMPILER_SOURCE/main.mil" ]|| die "compiler source not found ($COMPILER_SOURCE)"

# ---- 2. Compile the boot VM on site ----
command -v make >/dev/null 2>&1 || die "make not found; install build-essential/xcode-tools"
command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 || die "C compiler (cc/gcc) not found"

log "Building boot compiler in $BOOT_SOURCE"
( cd "$BOOT_SOURCE" && make clean >/dev/null 2>&1 || true && make )
BOOT_BIN="$BOOT_SOURCE/minilang"
[ -x "$BOOT_BIN" ] || die "boot build failed: $BOOT_BIN not produced"

# ---- 3. Lay down the install tree ----
LIB="$PREFIX/lib/minilang"
BINDIR="$LIB/bin"
DOCDIR="$PREFIX/share/doc/minilang"
log "Installing to $PREFIX"
mkdir -p "$BINDIR" "$LIB/syslib" "$PREFIX/bin" "$DOCDIR/docs"

cp "$BOOT_BIN" "$BINDIR/minilang"
chmod +x "$BINDIR/minilang"

# Import library produced by the build (MSVC minilang.lib, MinGW
# libminilang.dll.a) lives next to the exe so prebuilt extension DLLs link it.
for imp in "$BOOT_SOURCE/minilang.lib" "$BOOT_SOURCE/libminilang.dll.a" \
           "$BOOT_SOURCE/build/Release/minilang.lib" "$BOOT_SOURCE/build/libminilang.dll.a"; do
    [ -f "$imp" ] && cp "$imp" "$BINDIR/"
done

for f in runtime.c minilang.h minilang_runtime.h; do
    [ -f "$BOOT_SOURCE/$f" ] && cp "$BOOT_SOURCE/$f" "$LIB/"
done

# Self-hosted compiler sources (top-level .mil, excluding tests/).
for f in main.mil compiler.mil vm.mil milc_io.mil; do
    [ -f "$COMPILER_SOURCE/$f" ] && cp "$COMPILER_SOURCE/$f" "$LIB/"
done

# Standard library.
if [ -d "$SYS_SOURCE" ]; then
    for f in "$SYS_SOURCE"/*.mil; do
        [ -f "$f" ] && cp "$f" "$LIB/syslib/"
    done
fi

# Documentation.
if [ -d "$DOC_SOURCE/docs" ]; then
    cp "$DOC_SOURCE"/docs/*.md "$DOCDIR/docs/" 2>/dev/null || true
fi

# ---- 4. Wrapper on PATH: run the self-hosted entry through the boot VM ----
WRAPPER="$PREFIX/bin/minilang"
cat > "$WRAPPER" <<EOF
#!/bin/sh
# Generated by minilang-compiler/scripts/install.sh.
: "\${MINILANG_DIR:=$LIB}"
export MINILANG_DIR
exec "$BINDIR/minilang" run "$LIB/main.mil" "\$@"
EOF
chmod +x "$WRAPPER"

# ---- 5. Add $PREFIX/bin to the shell PATH (idempotent) ----
PATH_LINE='export PATH="'"$PREFIX"'/bin:$PATH"'
for rc in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc" "$HOME/.profile"; do
    [ -f "$rc" ] || continue
    if ! grep -qF "$PATH_LINE" "$rc" 2>/dev/null; then
        log "Adding PATH to $rc"
        printf '\n# minilang install\n%s\n' "$PATH_LINE" >> "$rc"
    fi
done
case ":$PATH:" in
    *":$PREFIX/bin:"*) ;;
    *) warn "$PREFIX/bin is not on PATH in this shell; reopen your terminal or run: export PATH=\"$PREFIX/bin:\$PATH\"" ;;
esac

# ---- 6. Full test suite against the installed layout ----
if [ "${SKIP_TESTS:-0}" != "1" ]; then
    log "Running full test suite (MINILANG_BOOT=$BINDIR/minilang)"
    ( cd "$COMPILER_SOURCE" && \
      MINILANG_BOOT="$BINDIR/minilang" \
      MINILANG_DIR="$COMPILER_SOURCE" \
      CC="${CC:-cc}" \
      bash full_test.sh )
else
    warn "Skipping full test suite (SKIP_TESTS=1)"
fi

log "Done. Documentation at $DOCDIR/docs. Run 'minilang' from a fresh shell (or '$WRAPPER')."
