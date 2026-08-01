// String operations, compiled to native code.
//
//   xc --backend native examples/native/strings.xi
//   ./build/strings        # prints: match, 5, bcd
//
// String equality compares bytes (not pointers), and length, indexing, and
// slicing call the runtime. A String travels as a pointer plus a length in two
// registers. No cc/ld/codesign.
extern "C" {
    producer xstd_put_int(n: Integer)
    producer xstd_put_str(s: String)
}

module M {
    id = "strings"
    entry main(args: String[]) -> Integer {
        let a = "hello"
        let b = "hel" + "lo"                 // built at runtime, equal by value
        if a == b { xstd_put_str("match\n") } else { xstd_put_str("differ\n") }

        xstd_put_int(string_len(a))          // 5
        xstd_put_str(string_slice(a, 1, 4))  // ell
        xstd_put_str("\n")
        return 0
    }
}
