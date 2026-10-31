/* file_counter.c — example user C extension for minilang.
 *
 * Demonstrates OpaqueType: a FILE* handle wrapped with ml_opaque_create() is
 * passed back and forth between minilang and C.
 *
 * Build (from minilang-boot or minilang-compiler):
 *     ./minilang build -e opaque_test.mil file_counter.c
 *     (or: ./main build -e opaque_test.mil file_counter.c)
 *
 * The .mil side declares:
 *     native func counter_open(path);
 *     native func counter_lines(handle);
 *     native func counter_close(handle);
 * and each maps to Value ml_native_<base>(...) here.
 */
#include "minilang_runtime.h"

#include <stdio.h>

/* Open a file and return its FILE* as an opaque handle. */
Value ml_native_counter_open(Value path) {
    const char *p = ml_cstr(path);
    FILE *f = fopen(p, "r");
    return ml_opaque_create(f); /* NULL handle is a valid opaque value */
}

/* Count the lines in the file behind an opaque handle. */
Value ml_native_counter_lines(Value handle) {
    FILE *f = (FILE *)ml_opaque_ptr(handle);
    if (!f) return ml_mkint(-1);
    long n = 0;
    int c;
    while ((c = fgetc(f)) != EOF) {
        if (c == '\n') n++;
    }
    return ml_mkint(n);
}

/* Close the file behind an opaque handle. */
Value ml_native_counter_close(Value handle) {
    FILE *f = (FILE *)ml_opaque_ptr(handle);
    if (f) fclose(f);
    return ml_mkint(0);
}
