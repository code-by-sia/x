// XiNativeBackend — the direct-to-native path, selected by `xc --backend native`
// (or XC_BACKEND=native). Emit machine code and write the executable ourselves,
// so a built binary needs no C compiler or linker on the machine.
//
//     Program ──lower──► XModule ──encode──► EncodedModule ──write──► file
//                (this)          (InsnEncoder)            (ObjectWriter)
//
// Coverage so far: an integer `entry main` body of `let`, assignment, `return`,
// `if`/`else`, and `while`, over expressions of int literals, locals, `+ - *`,
// comparisons, and parentheses. Locals get dedicated stack slots (stable across
// loop iterations); expression temps get fresh slots. Anything outside this is
// refused rather than mis-compiled, and the C backend stays the default.

type LowerResult = { ok: Bool, module: XModule, reason: String }

// Immutable parser state threaded through recursive descent. `insns` is
// heap-built; `resultTemp` is the slot holding the last expression's value;
// `names`/`slots` map a local to its stack slot; `nextSlot`/`nextLabel` hand out
// fresh slots and branch labels; `lastRet` tracks whether the last top-level
// statement was a return (main must end in one).
type PS = {
    toks:       Token[],
    pos:        Integer,
    insns:      XInsn[],
    nextSlot:   Integer,
    resultTemp: Integer,
    ok:         Bool,
    names:      String[],
    slots:      Integer[],
    nextLabel:  Integer,
    lastRet:    Bool
}

mapper psKind(ps: PS) -> Integer {
    if ps.pos >= tokenArrLen(ps.toks) { return 0 }
    return tokenArrGet(ps.toks, ps.pos).kind
}
mapper psText(ps: PS) -> String { return tokenArrGet(ps.toks, ps.pos).text }
mapper psAdvance(ps: PS) -> PS {
    return PS { toks: ps.toks, pos: ps.pos + 1, insns: ps.insns, nextSlot: ps.nextSlot, resultTemp: ps.resultTemp, ok: ps.ok, names: ps.names, slots: ps.slots, nextLabel: ps.nextLabel, lastRet: ps.lastRet }
}
mapper psFail(ps: PS) -> PS {
    return PS { toks: ps.toks, pos: ps.pos, insns: ps.insns, nextSlot: ps.nextSlot, resultTemp: ps.resultTemp, ok: false, names: ps.names, slots: ps.slots, nextLabel: ps.nextLabel, lastRet: ps.lastRet }
}
mapper psEmit(ps: PS, insn: XInsn) -> PS {
    return PS { toks: ps.toks, pos: ps.pos, insns: appendXInsn(ps.insns, insn), nextSlot: ps.nextSlot, resultTemp: ps.resultTemp, ok: ps.ok, names: ps.names, slots: ps.slots, nextLabel: ps.nextLabel, lastRet: false }
}
mapper psResult(ps: PS, slot: Integer) -> PS {
    return PS { toks: ps.toks, pos: ps.pos, insns: ps.insns, nextSlot: ps.nextSlot, resultTemp: slot, ok: ps.ok, names: ps.names, slots: ps.slots, nextLabel: ps.nextLabel, lastRet: ps.lastRet }
}
mapper withNextLabel(ps: PS, n: Integer) -> PS {
    return PS { toks: ps.toks, pos: ps.pos, insns: ps.insns, nextSlot: ps.nextSlot, resultTemp: ps.resultTemp, ok: ps.ok, names: ps.names, slots: ps.slots, nextLabel: n, lastRet: ps.lastRet }
}
mapper psEmitConst(ps: PS, v: Integer) -> PS {
    let t = ps.nextSlot
    return PS { toks: ps.toks, pos: ps.pos, insns: appendXInsn(ps.insns, xi_const(t, v)), nextSlot: t + 1, resultTemp: t, ok: ps.ok, names: ps.names, slots: ps.slots, nextLabel: ps.nextLabel, lastRet: ps.lastRet }
}
mapper psEmitBin(ps: PS, op: String, a: Integer, b: Integer) -> PS {
    let t = ps.nextSlot
    return PS { toks: ps.toks, pos: ps.pos, insns: appendXInsn(ps.insns, xi_bin(op, t, xtemp(a), xtemp(b))), nextSlot: t + 1, resultTemp: t, ok: ps.ok, names: ps.names, slots: ps.slots, nextLabel: ps.nextLabel, lastRet: ps.lastRet }
}
mapper psEmitCmp(ps: PS, op: String, a: Integer, b: Integer) -> PS {
    let t = ps.nextSlot
    return PS { toks: ps.toks, pos: ps.pos, insns: appendXInsn(ps.insns, xi_cmp(op, t, a, b)), nextSlot: t + 1, resultTemp: t, ok: ps.ok, names: ps.names, slots: ps.slots, nextLabel: ps.nextLabel, lastRet: ps.lastRet }
}
mapper declareLocal(ps: PS, name: String) -> PS {
    let slot = ps.nextSlot
    return PS { toks: ps.toks, pos: ps.pos, insns: ps.insns, nextSlot: slot + 1, resultTemp: ps.resultTemp, ok: ps.ok, names: appendString(ps.names, name), slots: appendInt(ps.slots, slot), nextLabel: ps.nextLabel, lastRet: ps.lastRet }
}
mapper lookupLocal(ps: PS, name: String) -> Integer {
    let i = 0
    let n = stringArrLen(ps.names)
    while i < n {
        if stringArrGet(ps.names, i) == name { return intArrGet(ps.slots, i) }
        i = i + 1
    }
    return 0 - 1
}
mapper cmpOpOf(k: Integer) -> String {
    if k == 112 { return "eq" }
    if k == 113 { return "ne" }
    if k == 114 { return "slt" }
    if k == 115 { return "sgt" }
    if k == 116 { return "sle" }
    if k == 117 { return "sge" }
    return ""
}

// primary := INT | IDENT | '(' expr ')'
mapper parsePrimary(ps: PS) -> PS {
    let k = psKind(ps)
    if k == 2 { return psEmitConst(psAdvance(ps), digitsToInt(psText(ps))) }
    if k == 1 {
        let slot = lookupLocal(ps, psText(ps))
        if slot < 0 { return psFail(ps) }
        return psResult(psAdvance(ps), slot)
    }
    if k == 100 {
        let inner = parseExpr(psAdvance(ps))
        if not inner.ok { return inner }
        if psKind(inner) != 101 { return psFail(inner) }
        return psAdvance(inner)
    }
    return psFail(ps)
}

// mul := primary (('*' | '/' | '%') primary)*
mapper parseMul(ps: PS) -> PS {
    let cur = parsePrimary(ps)
    if not cur.ok { return cur }
    while (psKind(cur) == 120) or (psKind(cur) == 121) or (psKind(cur) == 122) {
        let op = "mul"
        if psKind(cur) == 121 { op = "sdiv" }
        if psKind(cur) == 122 { op = "smod" }
        let left = cur.resultTemp
        let rhs = parsePrimary(psAdvance(cur))
        if not rhs.ok { return rhs }
        cur = psEmitBin(rhs, op, left, rhs.resultTemp)
    }
    return cur
}

// add := mul (('+' | '-') mul)*
mapper parseAdd(ps: PS) -> PS {
    let cur = parseMul(ps)
    if not cur.ok { return cur }
    while (psKind(cur) == 118) or (psKind(cur) == 119) {
        let op = "add"
        if psKind(cur) == 119 { op = "sub" }
        let left = cur.resultTemp
        let rhs = parseMul(psAdvance(cur))
        if not rhs.ok { return rhs }
        cur = psEmitBin(rhs, op, left, rhs.resultTemp)
    }
    return cur
}

// expr := add ((cmp) add)?    (a single, non-associative comparison)
mapper parseExpr(ps: PS) -> PS {
    let cur = parseAdd(ps)
    if not cur.ok { return cur }
    let op = cmpOpOf(psKind(cur))
    if string_len(op) > 0 {
        let left = cur.resultTemp
        let rhs = parseAdd(psAdvance(cur))
        if not rhs.ok { return rhs }
        return psEmitCmp(rhs, op, left, rhs.resultTemp)
    }
    return cur
}

// block := '{' stmt* '}'
mapper parseBlock(ps: PS) -> PS {
    if psKind(ps) != 102 { return psFail(ps) }
    let cur = psAdvance(ps)
    while psKind(cur) != 103 and psKind(cur) != 0 {
        cur = parseStmt(cur)
        if not cur.ok { return cur }
    }
    if psKind(cur) != 103 { return psFail(cur) }
    return psAdvance(cur)
}

mapper parseLet(ps: PS) -> PS {
    let p1 = psAdvance(ps)                       // 'let'
    if psKind(p1) != 1 { return psFail(p1) }
    let name = psText(p1)
    let p2 = psAdvance(p1)
    if psKind(p2) != 111 { return psFail(p2) }   // '='
    let p3 = parseExpr(psAdvance(p2))
    if not p3.ok { return p3 }
    let vslot = p3.resultTemp
    let sx = p3.nextSlot
    return psEmit(declareLocal(p3, name), xi_copy(sx, vslot))
}

mapper parseAssign(ps: PS) -> PS {
    let slot = lookupLocal(ps, psText(ps))
    if slot < 0 { return psFail(ps) }
    let p1 = psAdvance(ps)
    if psKind(p1) != 111 { return psFail(p1) }   // '='
    let p2 = parseExpr(psAdvance(p1))
    if not p2.ok { return p2 }
    return psEmit(p2, xi_copy(slot, p2.resultTemp))
}

mapper parseReturn(ps: PS) -> PS {
    let p1 = parseExpr(psAdvance(ps))
    if not p1.ok { return p1 }
    let p2 = psEmit(p1, xi_ret(xtemp(p1.resultTemp)))
    return PS { toks: p2.toks, pos: p2.pos, insns: p2.insns, nextSlot: p2.nextSlot, resultTemp: p2.resultTemp, ok: p2.ok, names: p2.names, slots: p2.slots, nextLabel: p2.nextLabel, lastRet: true }
}

// if cond { then } [ else { else } ]
mapper parseIf(ps: PS) -> PS {
    let p1 = parseExpr(psAdvance(ps))
    if not p1.ok { return p1 }
    let cond = p1.resultTemp
    let lElse = p1.nextLabel
    let p3 = psEmit(withNextLabel(p1, lElse + 1), xi_brz(cond, lElse))
    let p4 = parseBlock(p3)
    if not p4.ok { return p4 }
    if psKind(p4) == 223 {                       // else
        let lEnd = p4.nextLabel
        let p6 = psEmit(withNextLabel(p4, lEnd + 1), xi_br(lEnd))
        let p7 = psEmit(p6, xi_label(lElse))
        let p8 = parseBlock(psAdvance(p7))       // consume 'else'
        if not p8.ok { return p8 }
        return psEmit(p8, xi_label(lEnd))
    }
    return psEmit(p4, xi_label(lElse))
}

// while cond { body }
mapper parseWhile(ps: PS) -> PS {
    let lStart = ps.nextLabel
    let lEnd = ps.nextLabel + 1
    let p1 = psEmit(withNextLabel(ps, ps.nextLabel + 2), xi_label(lStart))
    let p2 = parseExpr(psAdvance(p1))            // consume 'while', parse condition
    if not p2.ok { return p2 }
    let p3 = psEmit(p2, xi_brz(p2.resultTemp, lEnd))
    let p4 = parseBlock(p3)
    if not p4.ok { return p4 }
    let p5 = psEmit(p4, xi_br(lStart))
    return psEmit(p5, xi_label(lEnd))
}

mapper parseStmt(ps: PS) -> PS {
    let k = psKind(ps)
    if k == 220 { return parseLet(ps) }
    if k == 221 { return parseReturn(ps) }
    if k == 222 { return parseIf(ps) }
    if k == 247 { return parseWhile(ps) }
    if k == 1 { return parseAssign(ps) }
    return psFail(ps)
}

mapper parseStmts(ps: PS) -> PS {
    let cur = ps
    while psKind(cur) != 0 {
        cur = parseStmt(cur)
        if not cur.ok { return cur }
    }
    return cur
}

mapper unsupportedLower() -> LowerResult {
    return LowerResult { ok: false, module: emptyXModule(), reason: "the native backend supports an integer entry body of let, assignment, return, if/else and while over int literals, locals, + - *, comparisons and parentheses; the body must end in a return" }
}

mapper lowerProgram(prog: Program) -> LowerResult {
    let toks = prog.entrySpec.bodyTokens
    let names0: String[] = []
    let slots0: Integer[] = []
    let insns0: XInsn[] = []
    let ps = parseStmts(PS { toks: toks, pos: 0, insns: insns0, nextSlot: 0, resultTemp: 0, ok: true, names: names0, slots: slots0, nextLabel: 0, lastRet: false })
    if not ps.ok { return unsupportedLower() }
    if not ps.lastRet { return unsupportedLower() }   // must end in a return

    let blocks0: XBlock[] = []
    let blocks = appendXBlock(blocks0, XBlock { id: 0, insns: ps.insns })
    let funcs0: XFunc[] = []
    let funcs = appendXFunc(funcs0, XFunc { name: "main", params: [], ret: "i64", blocks: blocks, nTemps: ps.nextSlot, frame: 0 })
    return LowerResult { ok: true, module: XModule { funcs: funcs, externs: [], entry: "main" }, reason: "" }
}

class XiNativeBackend implements NativeBackend {
    deps { diag: Diagnostics, enc: InsnEncoder, obj: ObjectWriter }

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
