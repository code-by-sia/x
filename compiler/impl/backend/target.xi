// A compilation target: a CPU architecture and an operating system.
//
// The native backend is injected every InsnEncoder and ObjectWriter implementor
// and selects the pair matching the target: the encoder whose archName() equals
// the arch, and the writer whose osName() equals the os. Supporting a new
// arch_os is a matter of adding an InsnEncoder and/or ObjectWriter implementor;
// no change to the backend or the selection is required.
//
// The target defaults to the host (arm64/macos) and is overridable with the
// XC_ARCH and XC_OS environment variables.
type Target = { arch: String, os: String }
