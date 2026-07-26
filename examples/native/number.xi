// Floating-point (Number) arithmetic, compiled to native code.
//
//   xc --backend native examples/native/number.xi
//   ./build/number         # prints: 6, 3.75, 28.2743, 2.5
//
// Number is an IEEE-754 double. A literal is materialized into a stack slot, and
// + - * / are the AArch64 double instructions (fadd/fsub/fmul/fdiv) over the
// hardware FP registers. Number parameters and returns travel in d-registers per
// the calling convention, alongside the integer registers. No cc/ld/codesign.
mapper area(r: Number) -> Number => 3.14159 * r * r

extern "C" { producer xstd_put_num(n: Number) }

module M {
    id = "number"
    entry main(args: String[]) -> Integer {
        xstd_put_num(2.0 * 3.0)          // 6
        xstd_put_num(1.5 + 2.25)         // 3.75
        xstd_put_num(10.0 / 4.0)         // 2.5
        xstd_put_num(area(3.0))          // a circle's area: 28.2743
        return 0
    }
}
