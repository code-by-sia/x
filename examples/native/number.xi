// Floating-point (Number) arithmetic, compiled to native code.
//
//   xc --backend native examples/native/number.xi
//   ./build/number         # prints: 6, 3.75, 28.2743, 2.5
//
// Number is an IEEE-754 double. A literal is materialized into a stack slot, and
// + - * / are the AArch64 double instructions (fadd/fsub/fmul/fdiv) over the
// hardware FP registers; a Number argument is passed in a d-register per the
// calling convention. No cc/ld/codesign.
extern "C" { producer xstd_put_num(n: Number) }

module M {
    id = "number"
    entry main(args: String[]) -> Integer {
        xstd_put_num(2.0 * 3.0)          // 6
        xstd_put_num(1.5 + 2.25)         // 3.75

        let r = 3.0
        xstd_put_num(3.14159 * r * r)    // a circle's area: 28.2743

        xstd_put_num(10.0 / 4.0)         // 2.5
        return 0
    }
}
