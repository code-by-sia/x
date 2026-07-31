// `break` and `continue` in `while` and `for` loops, compiled natively.
//
//   xc --backend native examples/native/loop_control.xi
//   ./build/loop_control ; echo $?      # -> 17
//
// break jumps past the loop; continue jumps to the loop's back-edge (for a
// `for` loop that is the index increment, so the walk still advances). Both are
// plain branches to labels the backend resolves in its second pass. No cc, ld,
// or codesign. The default C backend builds it identically.
module LoopControl {
    id = "loop_control"

    entry main(args: String[]) -> Integer {
        // while + break: stop the running sum once it reaches 5.
        let a = 0
        let i = 0
        while i < 100 {
            if i == 5 { break }
            a = a + i                       // 0 + 1 + 2 + 3 + 4 = 10
            i = i + 1
        }

        // for + continue: sum the list but skip the value 3.
        let xs = [1, 2, 3, 4]
        let b = 0
        for x in xs {
            if x == 3 { continue }          // increment still runs, no infinite loop
            b = b + x                       // 1 + 2 + 4 = 7
        }

        return a + b                        // 10 + 7 = 17
    }
}
