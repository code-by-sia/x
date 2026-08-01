// Recursive function calls, compiled straight to native code.
//
//   xc --backend native examples/native/factorial.xi
//   ./build/factorial ; echo $?      # -> 120  (5!)
//
// Each call follows the AArch64 convention (args in x0..x7, result in x0, fp/lr
// saved), and the backend lays the functions out and patches every BL itself.
// No cc, ld, or codesign. The default C backend builds it identically.
mapper fact(n: Integer) -> Integer {
    if n <= 1 { return 1 }
    return n * fact(n - 1)
}

module Factorial {
    id = "factorial"

    entry main(args: String[]) -> Integer {
        return fact(5)
    }
}
