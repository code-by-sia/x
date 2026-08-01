// A function with a String parameter and a String return, compiled natively.
//
//   xc --backend native examples/native/string_fn.xi
//   ./build/string_fn         # prints: Hi, world! Hi, there!
//
// String parameters arrive in two registers (pointer + length) and a String
// result comes back in x0:x1; the backend spills and reloads them around the
// AArch64 calling convention. No cc, ld, or codesign.
extern "C" { producer xstd_put_str(s: String) }

mapper greet(name: String) -> String {
    return "Hi, " + name + "! "
}

module StringFn {
    id = "string_fn"

    entry main(args: String[]) -> Integer {
        xstd_put_str(greet("world"))
        xstd_put_str(greet("there"))
        xstd_put_str("\n")
        return 0
    }
}
