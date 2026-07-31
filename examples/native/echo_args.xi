// Reading the command line: `entry main(args: String[])`, compiled natively.
//
//   xc --backend native examples/native/echo_args.xi
//   ./build/echo_args one two three      # prints: one / two / three (one per line)
//
// The loader hands the entry argc in x0 and argv in x1; the backend marshals
// them into a String[] with one runtime call (the same { data, len, cap } the C
// backend builds inline), then the body reads it like any other array. args is
// only marshalled when the entry actually names it, so a program that ignores
// its arguments carries no argv setup. No cc, ld, or codesign.
extern "C" { producer xstd_put_str(s: String) }

module EchoArgs {
    id = "echo_args"

    entry main(args: String[]) -> Integer {
        let i = 1                          // skip args.data[0], the program path
        while i < args.len {
            xstd_put_str(args.data[i])
            xstd_put_str("\n")
            i = i + 1
        }
        return 0
    }
}
