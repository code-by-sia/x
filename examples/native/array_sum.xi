// Integer arrays, compiled to native code.
//
//   xc --backend native examples/native/array_sum.xi
//   ./build/array_sum         # prints: 55
//
// An Integer[] is a fat pointer { data, len, cap } (three stack slots). A
// literal allocates its backing store through the runtime and fills it; `.len`
// and `.data[i]` read the length and elements. No cc, ld, or codesign.
extern "C" { producer xstd_put_int(n: Integer) }

module ArraySum {
    id = "array_sum"

    entry main(args: String[]) -> Integer {
        let a = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        let sum = 0
        let i = 0
        while i < a.len {
            sum = sum + a.data[i]
            i = i + 1
        }
        xstd_put_int(sum)
        return 0
    }
}
