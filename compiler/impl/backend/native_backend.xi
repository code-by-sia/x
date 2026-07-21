// XiNativeBackend — the direct-to-native path, selected by `xc --backend native`
// (or XC_BACKEND=native). It replaces "emit C, then run cc" with "emit machine
// code, then write the executable ourselves", so a built binary needs no C
// compiler or linker on the machine.
//
//     Program ──lower──► XModule ──encode──► EncodedModule ──write──► file
//                (this)          (InsnEncoder)            (ObjectWriter)
//
// Milestone coverage: `entry main -> Integer { return <int literal> }`. Lowering
// reports the first unsupported construct rather than emitting a broken binary,
// and the C backend stays the default so nothing here can regress a real build.
// Stages fill the layers in from here: runtime link, full language coverage,
// then self-host.

// Lowering outcome: an XModule, or the first unsupported construct.
type LowerResult = { ok: Bool, module: XModule, reason: String }

// Program -> XIR. Milestone: find `return <int literal>` in the entry body and
// build a one-block `main` that materialises it. Stage 2 grows this to cover the
// language, diffing behaviour against the C backend.
mapper lowerProgram(prog: Program) -> LowerResult {
    let toks = prog.entrySpec.bodyTokens
    let n = tokenArrLen(toks)
    // Accept ONLY a body that is exactly `return <int literal>`. Anything else
    // (a call, a local, more statements) is rejected rather than silently
    // dropped — emitting a binary that misrepresents the program is worse than
    // failing. `bodyTokens` excludes the outer braces; a trailing EOF is ok.
    let retval = 0
    let found = false
    if n >= 2 {
        let t0 = tokenArrGet(toks, 0)
        let t1 = tokenArrGet(toks, 1)
        if t0.kind == 221 and t1.kind == 2 {       // K_RETURN, K_INT_LIT
            let onlyReturn = true
            let j = 2
            while j < n {
                if tokenArrGet(toks, j).kind != 0 { onlyReturn = false }  // non-EOF trailing token
                j = j + 1
            }
            if onlyReturn {
                retval = digitsToInt(t1.text)
                found = true
            }
        }
    }
    if not found {
        return LowerResult { ok: false, module: emptyXModule(),
            reason: "the native backend currently supports only `entry main -> Integer { return <int literal> }`" }
    }
    // Heap-build every array: this module is returned to the backend, so array
    // literals (block-scoped storage) would dangle.
    let insns: XInsn[] = []
    insns = appendXInsn(insns, xi_const(0, retval))
    insns = appendXInsn(insns, xi_ret(xtemp(0)))
    let blocks: XBlock[] = []
    blocks = appendXBlock(blocks, XBlock { id: 0, insns: insns })
    let funcs: XFunc[] = []
    funcs = appendXFunc(funcs, XFunc { name: "main", params: [], ret: "i64", blocks: blocks, nTemps: 1, frame: 0 })
    return LowerResult { ok: true, module: XModule { funcs: funcs, externs: [], entry: "main" }, reason: "" }
}

class XiNativeBackend implements NativeBackend {
    deps { diag: Diagnostics, enc: InsnEncoder, obj: ObjectWriter }

    // Compile an already-analysed program straight to an executable at binPath.
    // Returns 0 on success; on an unsupported program it names the gap and
    // returns 1.
    producer emit(prog: Program, srcPath: String, binPath: String) -> Integer {
        let lo = lowerProgram(prog)
        if not lo.ok {
            diag.error(0, "native backend: " + lo.reason)
            return 1
        }
        let m = lo.module
        // Encode each function (milestone: the single entry). Heap-build the
        // encoded list so it is safe to pass on.
        let efs: EncodedFunc[] = []
        for f in m.funcs { efs = appendEncodedFunc(efs, enc.encode(f)) }
        let em = EncodedModule { funcs: efs, entry: m.entry }
        if obj.write(em, binPath) { return 0 }
        diag.error(0, "native backend: failed to write executable " + binPath)
        return 1
    }
}
