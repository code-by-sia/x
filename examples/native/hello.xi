// Native hello world: a string literal printed through the runtime.
//
//   xc --backend native examples/native/hello.xi
//   ./build/hello              # prints: Hello, native world!
//
// The literal's bytes go into a constant pool after the code in __TEXT; the
// backend materializes its address with adrp/add and passes (pointer, length)
// to xstd_put_str, bound from runtime.dylib. No cc, ld, or codesign.
extern "C" { producer xstd_put_str(s: String) }

module Hello {
    id = "hello"

    entry main(args: String[]) -> Integer {
        xstd_put_str("Hello, native world!\n")
        return 0
    }
}
