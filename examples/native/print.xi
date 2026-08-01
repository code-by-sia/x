// Calling an external (libSystem) function from native code, via dyld.
//
//   xc --backend native examples/native/print.xi
//   ./build/print          # prints: Hi!
//
// The backend emits a call stub (adrp/ldr/br into __got), a __DATA_CONST/__got
// bind pointer, and a chained-fixups import so dyld binds `putchar` from
// libSystem at load. No cc, ld, or codesign.
//
// Native-backend only: the C backend cannot redeclare `putchar` (its own
// prototype would clash with the libc `int putchar(int)`). Real programs will
// call the Xi runtime, not libc directly; this is the smallest demonstration of
// the import machinery.
extern "C" { producer putchar(c: Integer) -> Integer }

module Print {
    id = "print"

    entry main(args: String[]) -> Integer {
        putchar(72)     // H
        putchar(105)    // i
        putchar(33)     // !
        putchar(10)     // newline
        return 0
    }
}
