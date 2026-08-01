// Locals, a while loop, and control flow, compiled straight to native code.
//
//   xc --backend native examples/native/loop_sum.xi
//   ./build/loop_sum ; echo $?      # -> 55  (1 + 2 + ... + 10)
//
// No cc, ld, or codesign: `xc` emits arm64 with a stack frame and a resolved
// branch back-edge, then writes a self-signed Mach-O. The default C backend
// (drop `--backend native`) builds and runs it identically.
module LoopSum {
    id = "loop_sum"

    entry main(args: String[]) -> Integer {
        let sum = 0
        let i = 1
        while i <= 10 {
            sum = sum + i
            i = i + 1
        }
        return sum
    }
}
