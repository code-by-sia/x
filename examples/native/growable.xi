// Building an array by returning it, compiled to native code.
//
//   xc --backend native examples/native/growable.xi
//   ./build/growable       # prints: 45, 5
//
// Arrays are passed and returned per the platform convention: an array argument
// travels by pointer, and an array result comes back through the x8 register
// into a buffer the caller reserved. That is exactly what a C compiler does, so
// a runtime function like `xstd_iappend(arr, v) -> arr` (which grows the backing
// store and returns the new array) can be called and its result reassigned.
// No cc/ld/codesign.
extern "C" {
    producer xstd_put_int(n: Integer)
    mapper xstd_iappend(a: Integer[], v: Integer) -> Integer[]
}

module M {
    id = "growable"
    entry main(args: String[]) -> Integer {
        let xs = [1, 2]
        xs = xstd_iappend(xs, 10)
        xs = xstd_iappend(xs, 20)
        xs = xstd_iappend(xs, 12)

        let sum = 0
        for x in xs { sum = sum + x }   // 1 + 2 + 10 + 20 + 12
        xstd_put_int(sum)               // 45
        xstd_put_int(xs.len)            // 5
        return 0
    }
}
