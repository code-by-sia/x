// The native backend's first runnable program.
//
//   xc --backend native examples/native/exit_code.xi
//   ./build/exit_code ; echo $?      # -> 42
//
// Built with no cc, no ld, no codesign: `xc` emits arm64 machine code and writes
// a self-signed Mach-O directly. The native backend currently supports a return
// of an integer expression (literals with + - * and parentheses); see
// docs/native-backend.md for scope and the staged roadmap. The default C backend
// (drop `--backend native`) builds and runs it too.
module ExitCode {
    id = "exit_code"

    entry main(args: String[]) -> Integer {
        return 6 * 7 + 0    // 42, computed by native arithmetic codegen
    }
}
