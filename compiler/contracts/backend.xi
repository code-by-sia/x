// NativeBackend — the alternative to the C backend: Program straight to a native
// executable, no cc and no ld on the machine. Implemented by XiNativeBackend
// (impl/backend/native_backend.xi), which drives the InsnEncoder (ISA seam) and
// ObjectWriter (object-format seam). Selected per build by `xc --backend native`
// / XC_BACKEND=native; the C path (Codegen + Host.compileC) remains the default.
interface NativeBackend {
    producer emit(prog: Program, srcPath: String, binPath: String) -> Integer
}
