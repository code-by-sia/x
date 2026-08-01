// String variables and concatenation, compiled to native code.
//
//   xc --backend native examples/native/greeting.xi
//   ./build/greeting          # prints: Hello, native world!
//
// A String value is two machine registers (pointer + length); a String local
// takes two stack slots, and `a + b` calls the runtime's concat. No cc, ld, or
// codesign.
extern "C" { producer xstd_put_str(s: String) }

module Greeting {
    id = "greeting"

    entry main(args: String[]) -> Integer {
        let greeting = "Hello, "
        let subject = "native world"
        let line = greeting + subject + "!\n"
        xstd_put_str(line)
        return 0
    }
}
