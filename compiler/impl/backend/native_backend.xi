// XiNativeBackend — the direct-to-native path, selected by `xc --backend native`
// (or XC_BACKEND=native). It replaces "emit C, then run cc" with "emit machine
// code, then write the executable ourselves", so a built binary needs no C
// compiler or linker on the machine.
//
//     Program ──lower──► XModule ──encode──► EncodedModule ──write──► file
//                (this)          (InsnEncoder)            (ObjectWriter)
//
// Coverage so far: `entry main -> Integer { return <expr> }` where <expr> is
// integer literals combined with `+`, `-`, `*` and parentheses. Lowering reports
// anything else rather than emitting a broken binary, and the C backend stays
// the default so nothing here can regress a real build. Locals, control flow,
// calls and the runtime link come next.

// Lowering outcome: an XModule, or the first unsupported construct.
type LowerResult = { ok: Bool, module: XModule, reason: String }

// ── a tiny expression parser that lowers straight to XIR ───────────
// Recursive descent with the usual precedence (`*` over `+`/`-`), threading an
// immutable state record. `insns` is heap-built (appendXInsn) so the lowered
// module survives the return; `resultTemp` is the temp holding the last value.
type PS = {
    toks:       Token[],
    pos:        Integer,
    insns:      XInsn[],
    nextTemp:   Integer,
    resultTemp: Integer,
    ok:         Bool
}

mapper psKind(ps: PS) -> Integer {
    if ps.pos >= tokenArrLen(ps.toks) { return 0 }
    return tokenArrGet(ps.toks, ps.pos).kind
}
mapper psAdvance(ps: PS) -> PS =>
    PS { toks: ps.toks, pos: ps.pos + 1, insns: ps.insns, nextTemp: ps.nextTemp, resultTemp: ps.resultTemp, ok: ps.ok }
mapper psFail(ps: PS) -> PS =>
    PS { toks: ps.toks, pos: ps.pos, insns: ps.insns, nextTemp: ps.nextTemp, resultTemp: ps.resultTemp, ok: false }
mapper psEmitConst(ps: PS, v: Integer) -> PS {
    let t = ps.nextTemp
    return PS { toks: ps.toks, pos: ps.pos, insns: appendXInsn(ps.insns, xi_const(t, v)),
                nextTemp: t + 1, resultTemp: t, ok: ps.ok }
}
mapper psEmitBin(ps: PS, op: String, a: Integer, b: Integer) -> PS {
    let t = ps.nextTemp
    return PS { toks: ps.toks, pos: ps.pos, insns: appendXInsn(ps.insns, xi_bin(op, t, xtemp(a), xtemp(b))),
                nextTemp: t + 1, resultTemp: t, ok: ps.ok }
}

// primary := INT | '(' expr ')'
mapper parsePrimary(ps: PS) -> PS {
    let k = psKind(ps)
    if k == 2 {                                   // K_INT_LIT
        let v = digitsToInt(tokenArrGet(ps.toks, ps.pos).text)
        return psEmitConst(psAdvance(ps), v)
    }
    if k == 100 {                                 // '('
        let inner = parseExpr(psAdvance(ps))
        if not inner.ok { return inner }
        if psKind(inner) != 101 { return psFail(inner) }   // expect ')'
        return psAdvance(inner)                   // resultTemp carries through
    }
    return psFail(ps)
}

// term := primary ('*' primary)*
mapper parseTerm(ps: PS) -> PS {
    let cur = parsePrimary(ps)
    if not cur.ok { return cur }
    while psKind(cur) == 120 {                    // '*'
        let left = cur.resultTemp
        let rhs = parsePrimary(psAdvance(cur))
        if not rhs.ok { return rhs }
        cur = psEmitBin(rhs, "mul", left, rhs.resultTemp)
    }
    return cur
}

// expr := term (('+' | '-') term)*
mapper parseExpr(ps: PS) -> PS {
    let cur = parseTerm(ps)
    if not cur.ok { return cur }
    while (psKind(cur) == 118) or (psKind(cur) == 119) {   // '+' / '-'
        let op = "add"
        if psKind(cur) == 119 { op = "sub" }
        let left = cur.resultTemp
        let rhs = parseTerm(psAdvance(cur))
        if not rhs.ok { return rhs }
        cur = psEmitBin(rhs, op, left, rhs.resultTemp)
    }
    return cur
}

mapper unsupportedLower() -> LowerResult {
    return LowerResult { ok: false, module: emptyXModule(), reason: "the native backend currently supports only a return of an integer expression (int literals with + - * and parentheses)" }
}

// Program -> XIR. Require the entry body to be exactly `return <expr>`; anything
// else (a call, a local, more statements) is refused rather than mis-compiled.
mapper lowerProgram(prog: Program) -> LowerResult {
    let toks = prog.entrySpec.bodyTokens
    let n = tokenArrLen(toks)
    if n < 2 { return unsupportedLower() }
    if tokenArrGet(toks, 0).kind != 221 { return unsupportedLower() }   // K_RETURN

    let insns0: XInsn[] = []
    let ps = parseExpr(PS { toks: toks, pos: 1, insns: insns0, nextTemp: 0, resultTemp: 0, ok: true })
    if not ps.ok { return unsupportedLower() }
    // every remaining token must be EOF (nothing after the expression)
    let j = ps.pos
    while j < n {
        if tokenArrGet(toks, j).kind != 0 { return unsupportedLower() }
        j = j + 1
    }

    let insns = appendXInsn(ps.insns, xi_ret(xtemp(ps.resultTemp)))
    let blocks0: XBlock[] = []
    let blocks = appendXBlock(blocks0, XBlock { id: 0, insns: insns })
    let funcs0: XFunc[] = []
    let funcs = appendXFunc(funcs0, XFunc { name: "main", params: [], ret: "i64", blocks: blocks, nTemps: ps.nextTemp, frame: 0 })
    return LowerResult { ok: true, module: XModule { funcs: funcs, externs: [], entry: "main" }, reason: "" }
}

class XiNativeBackend implements NativeBackend {
    deps { diag: Diagnostics, enc: InsnEncoder, obj: ObjectWriter }

    // Compile an already-analysed program straight to an executable at binPath.
    // Returns 0 on success; on an unsupported program it names the gap.
    producer emit(prog: Program, srcPath: String, binPath: String) -> Integer {
        let lo = lowerProgram(prog)
        if not lo.ok {
            diag.error(0, "native backend: " + lo.reason)
            return 1
        }
        let m = lo.module
        let efs: EncodedFunc[] = []
        for f in m.funcs { efs = appendEncodedFunc(efs, enc.encode(f)) }
        let em = EncodedModule { funcs: efs, entry: m.entry }
        if obj.write(em, binPath) { return 0 }
        diag.error(0, "native backend: failed to write executable " + binPath)
        return 1
    }
}
