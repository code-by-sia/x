// Calling the Xi runtime from native code (the runtime is linked as a dylib).
//
//   xc --backend native examples/native/runtime_call.xi
//   ./build/runtime_call        # prints: 42
//
// `xstd_*` symbols bind from runtime.dylib (a second LC_LOAD_DYLIB, dyld
// ordinal 2) via the same stub + __got machinery used for libSystem. Build the
// dylib once with compiler/bootstrap.sh; the build itself needs no cc or ld.
// The default C backend links runtime.c and prints the same.
extern "C" { producer xstd_put_int(n: Integer) }

module RuntimeCall {
    id = "runtime_call"

    entry main(args: String[]) -> Integer {
        xstd_put_int(6 * 7)
        return 0
    }
}
