// =============================================================
// xc — the X language compiler, written in X (self-hosting)
//
// Manifest for the `xc` binary. The compiler is organized in two layers:
//
//   contracts/      the abstraction layer — every interface (the contracts)
//   impl/           the implementation layer — all the code
//     text/ arrays/ host/ diag/   FFI components: each file declares its
//                   `extern "C"` block on top and a class that wraps it
//     lexer/ parser/ codegen/ driver/   the four compiler stages
//
// `import` (impl/driver/driver.xi) splices each file's declarations into one
// compilation unit, so this layout is organizational: each interface and class
// lives in its own file, and the driver depends on the stage/service
// *interfaces* — the `module` in impl/driver/app.xi binds the implementations.
// =============================================================

// ── contracts: interfaces ─────────────────────────────────────────
import "contracts/text.xi"
import "contracts/token_arrays.xi"
import "contracts/spec_arrays.xi"
import "contracts/host.xi"
import "contracts/diagnostics.xi"
import "contracts/lexer.xi"
import "contracts/parser.xi"
import "contracts/codegen.xi"
import "contracts/codecs.xi"
import "contracts/backend.xi"
import "contracts/compiler.xi"
import "contracts/module_loader.xi"

// ── implementation layer: FFI components (extern block + wrapper class) ──
import "impl/ffi/text/std_text.xi"
import "impl/ffi/arrays/token_arrays.xi"
import "impl/ffi/arrays/spec_arrays.xi"
import "impl/ffi/host/posix_host.xi"
import "impl/ffi/diag/diagnostics.xi"

// ── implementation layer: shared utilities ────────────────────────
import "impl/strings.xi"

// ── implementation layer: lexer ───────────────────────────────────
import "impl/lexer/scanner.xi"
import "impl/lexer/xi_lexer.xi"

// ── implementation layer: parser ──────────────────────────────────
import "impl/parser/pstate.xi"
import "impl/parser/type_parser.xi"
import "impl/parser/specs.xi"
import "impl/parser/sig_parser.xi"
import "impl/parser/decision_parser.xi"
import "impl/parser/decl_parser.xi"
import "impl/parser/module_parser.xi"
import "impl/parser/program_parser.xi"
import "impl/parser/xi_parser.xi"

// ── implementation layer: codegen ─────────────────────────────────
import "impl/codegen/core.xi"
import "impl/codegen/gen_context.xi"
import "impl/codegen/async_codegen.xi"
import "impl/codegen/program_query.xi"
import "impl/codegen/generics.xi"
import "impl/codegen/sumtypes.xi"
import "impl/codegen/machines.xi"
import "impl/codegen/feature_detect.xi"
import "impl/codegen/checks.xi"
import "impl/codegen/xtype.xi"
import "impl/codegen/expr.xi"
import "impl/codegen/seq.xi"
import "impl/codegen/postfix.xi"
import "impl/codegen/queryreify.xi"
import "impl/codegen/operators.xi"
import "impl/codegen/stmt.xi"
import "impl/codegen/decl.xi"
import "impl/codegen/emit.xi"
import "impl/codegen/di.xi"
import "impl/codegen/codecs.xi"
import "impl/codegen/top.xi"
import "impl/codegen/xi_codegen.xi"

// ── implementation layer: native backend (Program -> machine code) ─
// The alternative to the C backend, selected by `xc --backend native`. Design
// scaffolding: the IR and the ISA / object-format seams, with stub encoders that
// report "not yet implemented" so the default C path never regresses.
import "impl/backend/backend_ffi.xi"
import "impl/backend/xir.xi"
import "impl/backend/encoder.xi"
import "impl/backend/objwriter.xi"
import "impl/backend/native_backend.xi"

// ── implementation layer: driver + composition root ───────────────
import "impl/driver/driver.xi"
import "impl/driver/module_loader.xi"
import "impl/driver/xc_compiler.xi"

// ── composition root ──────────────────────────────────────────────
// The module + entry live in the manifest (the self-contained buildable unit),
// not in a separate part file — otherwise `xc --all` would see a part with
// module+entry and try to build it in isolation. The module declares the full
// set of module fields (see docs/multi-file.md#module-fields); includes/excludes
// stay empty because the compiler is assembled by explicit `import`, not glob.
module Compile {
    id           = "xc"
    name         = "Xi Compiler"
    description  = "The Xi language compiler — Xi source to C99 to native binaries."
    version      = "0.1.12"
    license      = "Apache 2.0"
    includes     = []
    excludes     = []
    dependencies = []

    bind Text         -> StdText        as singleton
    bind TokenArrays  -> StdTokenArrays as singleton
    bind SpecArrays   -> StdSpecArrays  as singleton
    bind Host         -> PosixHost      as singleton
    bind Diagnostics  -> Diag           as singleton
    bind Lexer        -> XiLexer        as singleton
    bind Parser       -> XiParser       as singleton
    bind Codecs       -> JsonCodecs     as singleton
    bind Codegen      -> XiCodegen      as singleton
    bind InsnEncoder  -> Arm64Encoder   as singleton
    bind ObjectWriter -> MachoWriter    as singleton
    bind NativeBackend -> XiNativeBackend as singleton
    bind ModuleLoader -> XiModuleLoader as singleton
    bind Compiler     -> XcCompiler     as singleton

    async entry main(args: String[]) -> Integer {
        let xc = Compile.resolve(Compiler)
        return xc.run(args)
    }
}
