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
    kinds:      Integer[],   // per local: 1 = String (two slots), 0 = Integer
    nextLabel:  Integer,
    lastRet:    Bool,
    resultStr:  Bool         // is the last expression a String? (its len is at resultTemp+1)
}

mapper psKind(ps: PS) -> Integer {
    if ps.pos >= tokenArrLen(ps.toks) { return 0 }
    return tokenArrGet(ps.toks, ps.pos).kind
}
mapper psText(ps: PS) -> String { return tokenArrGet(ps.toks, ps.pos).text }
mapper psAdvance(ps: PS) -> PS {
    return PS { toks: ps.toks, pos: ps.pos + 1, insns: ps.insns, nextSlot: ps.nextSlot, resultTemp: ps.resultTemp, ok: ps.ok, names: ps.names, slots: ps.slots, nextLabel: ps.nextLabel, lastRet: ps.lastRet, kinds: ps.kinds, resultStr: ps.resultStr }
}
mapper psFail(ps: PS) -> PS {
    return PS { toks: ps.toks, pos: ps.pos, insns: ps.insns, nextSlot: ps.nextSlot, resultTemp: ps.resultTemp, ok: false, names: ps.names, slots: ps.slots, nextLabel: ps.nextLabel, lastRet: ps.lastRet, kinds: ps.kinds, resultStr: ps.resultStr }
}
mapper psEmit(ps: PS, insn: XInsn) -> PS {
    return PS { toks: ps.toks, pos: ps.pos, insns: appendXInsn(ps.insns, insn), nextSlot: ps.nextSlot, resultTemp: ps.resultTemp, ok: ps.ok, names: ps.names, slots: ps.slots, nextLabel: ps.nextLabel, lastRet: false, kinds: ps.kinds, resultStr: ps.resultStr }
}
mapper psResult(ps: PS, slot: Integer) -> PS {
    return PS { toks: ps.toks, pos: ps.pos, insns: ps.insns, nextSlot: ps.nextSlot, resultTemp: slot, ok: ps.ok, names: ps.names, slots: ps.slots, nextLabel: ps.nextLabel, lastRet: ps.lastRet, kinds: ps.kinds, resultStr: ps.resultStr }
}
mapper withNextLabel(ps: PS, n: Integer) -> PS {
    return PS { toks: ps.toks, pos: ps.pos, insns: ps.insns, nextSlot: ps.nextSlot, resultTemp: ps.resultTemp, ok: ps.ok, names: ps.names, slots: ps.slots, nextLabel: n, lastRet: ps.lastRet, kinds: ps.kinds, resultStr: ps.resultStr }
}
mapper psEmitConst(ps: PS, v: Integer) -> PS {
    let t = ps.nextSlot
    return PS { toks: ps.toks, pos: ps.pos, insns: appendXInsn(ps.insns, xi_const(t, v)), nextSlot: t + 1, resultTemp: t, ok: ps.ok, names: ps.names, slots: ps.slots, nextLabel: ps.nextLabel, lastRet: ps.lastRet, kinds: ps.kinds, resultStr: false }
}
mapper psEmitBin(ps: PS, op: String, a: Integer, b: Integer) -> PS {
    let t = ps.nextSlot
    return PS { toks: ps.toks, pos: ps.pos, insns: appendXInsn(ps.insns, xi_bin(op, t, xtemp(a), xtemp(b))), nextSlot: t + 1, resultTemp: t, ok: ps.ok, names: ps.names, slots: ps.slots, nextLabel: ps.nextLabel, lastRet: ps.lastRet, kinds: ps.kinds, resultStr: false }
}
mapper psEmitCmp(ps: PS, op: String, a: Integer, b: Integer) -> PS {
    let t = ps.nextSlot
    return PS { toks: ps.toks, pos: ps.pos, insns: appendXInsn(ps.insns, xi_cmp(op, t, a, b)), nextSlot: t + 1, resultTemp: t, ok: ps.ok, names: ps.names, slots: ps.slots, nextLabel: ps.nextLabel, lastRet: ps.lastRet, kinds: ps.kinds, resultStr: false }
}
// Declare a local. A String local (kind 1) reserves two slots (pointer, length).
mapper declareLocal(ps: PS, name: String, kind: Integer) -> PS {
    let slot = ps.nextSlot
    let ns = slot + 1
    if kind == 1 { ns = slot + 2 }
    return PS { toks: ps.toks, pos: ps.pos, insns: ps.insns, nextSlot: ns, resultTemp: ps.resultTemp, ok: ps.ok, names: appendString(ps.names, name), slots: appendInt(ps.slots, slot), nextLabel: ps.nextLabel, lastRet: ps.lastRet, kinds: appendInt(ps.kinds, kind), resultStr: ps.resultStr }
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
mapper lookupKind(ps: PS, name: String) -> Integer {
    let i = 0
    let n = stringArrLen(ps.names)
    while i < n {
        if stringArrGet(ps.names, i) == name { return intArrGet(ps.kinds, i) }
        i = i + 1
    }
    return 0
}
// Set the result to `slot` and mark whether it is a String.
mapper psStrResult(ps: PS, slot: Integer, isStr: Bool) -> PS {
    return PS { toks: ps.toks, pos: ps.pos, insns: ps.insns, nextSlot: ps.nextSlot, resultTemp: slot, ok: ps.ok, names: ps.names, slots: ps.slots, nextLabel: ps.nextLabel, lastRet: ps.lastRet, kinds: ps.kinds, resultStr: isStr }
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

mapper slotsToVals(slots: Integer[]) -> XVal[] {
    let out: XVal[] = []
    let i = 0
    let n = intArrLen(slots)
    while i < n { out = appendXVal(out, xtemp(intArrGet(slots, i)))  i = i + 1 }
    return out
}
// Emit a call. A String result (retStr) comes back in x0:x1 and takes two slots.
mapper psEmitCall(ps: PS, callee: String, argSlots: Integer[], dst: Integer, retStr: Bool) -> PS {
    let typ = "i64"
    let ns = dst + 1
    if retStr { typ = "str"  ns = dst + 2 }
    return PS { toks: ps.toks, pos: ps.pos, insns: appendXInsn(ps.insns, xi_call(dst, callee, slotsToVals(argSlots), typ)), nextSlot: ns, resultTemp: dst, ok: ps.ok, names: ps.names, slots: ps.slots, nextLabel: ps.nextLabel, lastRet: ps.lastRet, kinds: ps.kinds, resultStr: retStr }
}

mapper psEmitStrAddr(ps: PS, strid: Integer) -> PS {
    let t = ps.nextSlot
    return PS { toks: ps.toks, pos: ps.pos, insns: appendXInsn(ps.insns, xi_straddr(t, strid)), nextSlot: t + 1, resultTemp: t, ok: ps.ok, names: ps.names, slots: ps.slots, nextLabel: ps.nextLabel, lastRet: ps.lastRet, kinds: ps.kinds, resultStr: true }
}
mapper concatInts(a: Integer[], b: Integer[]) -> Integer[] {
    let out = a
    let i = 0
    while i < intArrLen(b) { out = appendInt(out, intArrGet(b, i))  i = i + 1 }
    return out
}

// A concatenation a + b (both String) is a call to the runtime, result in two
// slots (pointer + length).
mapper psEmitConcat(ps: PS, a: Integer, b: Integer) -> PS {
    let args: Integer[] = []
    args = appendInt(args, a)
    args = appendInt(args, a + 1)
    args = appendInt(args, b)
    args = appendInt(args, b + 1)
    return psEmitCall(ps, "xstd_concat", args, ps.nextSlot, true)
}

// One call argument: its value slot, plus a second slot (the length) if String.
type ArgResult = { ps: PS, slots: Integer[] }
mapper parseOneArg(ps: PS) -> ArgResult {
    let e = parseExpr(ps)
    let sl: Integer[] = []
    if e.ok {
        sl = appendInt(sl, e.resultTemp)
        if e.resultStr { sl = appendInt(sl, e.resultTemp + 1) }
    }
    return ArgResult { ps: e, slots: sl }
}

// call := IDENT '(' (arg (',' arg)*)? ')'   — ps is positioned at '('
mapper parseCall(ps: PS, name: String) -> PS {
    let cur = psAdvance(ps)                       // consume '('
    let argSlots: Integer[] = []
    if psKind(cur) != 101 {
        let r = parseOneArg(cur)
        if not r.ps.ok { return r.ps }
        cur = r.ps
        argSlots = concatInts(argSlots, r.slots)
        while psKind(cur) == 106 {                // ','
            let r2 = parseOneArg(psAdvance(cur))
            if not r2.ps.ok { return r2.ps }
            cur = r2.ps
            argSlots = concatInts(argSlots, r2.slots)
        }
    }
    if psKind(cur) != 101 { return psFail(cur) }  // ')'
    if intArrLen(argSlots) > 8 { return psFail(cur) }
    let p2 = psAdvance(cur)
    return psEmitCall(p2, name, argSlots, p2.nextSlot, fnsig_ret_str(name) == 1)
}

// primary := INT | STRING | IDENT | call | '(' expr ')'
mapper parsePrimary(ps: PS) -> PS {
    let k = psKind(ps)
    if k == 2 { return psEmitConst(psAdvance(ps), digitsToInt(psText(ps))) }
    if k == 4 {                                    // string literal -> pointer + length
        let ptrSlot = ps.nextSlot
        let a1 = psEmitStrAddr(ps, strpool_add(psText(ps)))
        let a2 = psEmitConst(a1, unescapedLen(psText(ps)))   // length at ptrSlot+1
        return psStrResult(psAdvance(a2), ptrSlot, true)
    }
    if k == 1 {
        let name = psText(ps)
        let p1 = psAdvance(ps)
        if psKind(p1) == 100 { return parseCall(p1, name) }   // '(' -> call
        let slot = lookupLocal(ps, name)
        if slot < 0 { return psFail(ps) }
        return psStrResult(p1, slot, lookupKind(ps, name) == 1)
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
        let isAdd = psKind(cur) == 118
        let leftStr = cur.resultStr
        let left = cur.resultTemp
        let rhs = parseMul(psAdvance(cur))
        if not rhs.ok { return rhs }
        if isAdd and leftStr and rhs.resultStr {
            cur = psEmitConcat(rhs, left, rhs.resultTemp)   // String + String
        } else {
            let op = "add"
            if not isAdd { op = "sub" }
            cur = psEmitBin(rhs, op, left, rhs.resultTemp)
        }
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
    let kind = 0
    if p3.resultStr { kind = 1 }
    let sx = p3.nextSlot
    let c1 = psEmit(declareLocal(p3, name, kind), xi_copy(sx, vslot))
    if kind == 1 { return psEmit(c1, xi_copy(sx + 1, vslot + 1)) }   // String: copy length too
    return c1
}

mapper parseAssign(ps: PS) -> PS {
    let name = psText(ps)
    let slot = lookupLocal(ps, name)
    if slot < 0 { return psFail(ps) }
    let isStr = lookupKind(ps, name) == 1
    let p1 = psAdvance(ps)
    if psKind(p1) != 111 { return psFail(p1) }   // '='
    let p2 = parseExpr(psAdvance(p1))
    if not p2.ok { return p2 }
    let c1 = psEmit(p2, xi_copy(slot, p2.resultTemp))
    if isStr { return psEmit(c1, xi_copy(slot + 1, p2.resultTemp + 1)) }
    return c1
}

mapper parseReturn(ps: PS) -> PS {
    let p1 = parseExpr(psAdvance(ps))
    if not p1.ok { return p1 }
    let p2 = psEmit(p1, xi_ret2(xtemp(p1.resultTemp), p1.resultStr))
    return PS { toks: p2.toks, pos: p2.pos, insns: p2.insns, nextSlot: p2.nextSlot, resultTemp: p2.resultTemp, ok: p2.ok, names: p2.names, slots: p2.slots, nextLabel: p2.nextLabel, lastRet: true, kinds: p2.kinds, resultStr: p2.resultStr }
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
    if k == 1 {
        // IDENT '(' -> a call statement (result discarded); else an assignment.
        if psKind(psAdvance(ps)) == 100 { return parseCall(psAdvance(ps), psText(ps)) }
        return parseAssign(ps)
    }
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
    return LowerResult { ok: false, module: emptyXModule(), reason: "the native backend supports Integer/String functions of let, assignment, return, if/else, while and calls over literals, params, locals, + - * / %, comparisons, string concatenation and parentheses; every function must end in a return" }
}

type FuncLower = { ok: Bool, fn: XFunc }
type ParamParse = { ok: Bool, names: String[], kinds: Integer[] }

mapper trimStr(s: String) -> String {
    let n = string_len(s)
    let a = 0
    while a < n and string_char_at(s, a) == 32 { a = a + 1 }
    let b = n
    while b > a and string_char_at(s, b - 1) == 32 { b = b - 1 }
    return string_slice(s, a, b)
}

// Parse a C parameter list into names + kinds (0 = Integer, 1 = String); not-ok
// if any parameter is neither.
mapper parseNativeParams(pstr: String) -> ParamParse {
    let names: String[] = []
    let kinds: Integer[] = []
    if string_len(trimStr(pstr)) == 0 { return ParamParse { ok: true, names: names, kinds: kinds } }
    let n = string_len(pstr)
    let start = 0
    let i = 0
    while i <= n {
        if i == n or string_char_at(pstr, i) == 44 {          // ',' or end
            let piece = trimStr(string_slice(pstr, start, i))
            let kind = 0 - 1
            let off = 0
            if piece.startsWith2("xc_integer_t ") { kind = 0  off = 13 }
            if piece.startsWith2("xc_string_t ")  { kind = 1  off = 12 }
            if kind < 0 { return ParamParse { ok: false, names: names, kinds: kinds } }
            let name = trimStr(string_slice(piece, off, string_len(piece)))
            if string_len(name) == 0 { return ParamParse { ok: false, names: names, kinds: kinds } }
            names = appendString(names, name)
            kinds = appendInt(kinds, kind)
            start = i + 1
        }
        i = i + 1
    }
    return ParamParse { ok: true, names: names, kinds: kinds }
}

mapper dummyFn() -> XFunc {
    let b0: XBlock[] = []
    let e0: Integer[] = []
    return XFunc { name: "", params: [], paramKinds: e0, ret: "i64", blocks: b0, nTemps: 0, frame: 0 }
}

// Lower one function body. The entry ignores its params (called by the loader);
// others bind params to the first slots (a String param takes two) and spill
// them in the prologue. Integer and String returns are both allowed.
mapper lowerFunc(name: String, paramStr: String, retC: String, bodyTokens: Token[], isEntry: Bool) -> FuncLower {
    if retC != "xc_integer_t" and retC != "xc_string_t" { return FuncLower { ok: false, fn: dummyFn() } }
    let names0: String[] = []
    let slots0: Integer[] = []
    let kinds0: Integer[] = []
    let pkinds: Integer[] = []
    let nslots = 0
    let nregs = 0
    if not isEntry {
        let pp = parseNativeParams(paramStr)
        if not pp.ok { return FuncLower { ok: false, fn: dummyFn() } }
        names0 = pp.names
        pkinds = pp.kinds
        let np = stringArrLen(pp.names)
        let i = 0
        while i < np {
            let kind = intArrGet(pp.kinds, i)
            slots0 = appendInt(slots0, nslots)
            kinds0 = appendInt(kinds0, kind)
            if kind == 1 { nslots = nslots + 2  nregs = nregs + 2 } else { nslots = nslots + 1  nregs = nregs + 1 }
            i = i + 1
        }
        if nregs > 8 { return FuncLower { ok: false, fn: dummyFn() } }
    }
    let insns0: XInsn[] = []
    let ps = parseStmts(PS { toks: bodyTokens, pos: 0, insns: insns0, nextSlot: nslots, resultTemp: 0, ok: true, names: names0, slots: slots0, nextLabel: 0, lastRet: false, kinds: kinds0, resultStr: false })
    if not ps.ok { return FuncLower { ok: false, fn: dummyFn() } }
    if not ps.lastRet { return FuncLower { ok: false, fn: dummyFn() } }
    let blocks0: XBlock[] = []
    let blocks = appendXBlock(blocks0, XBlock { id: 0, insns: ps.insns })
    return FuncLower { ok: true, fn: XFunc { name: name, params: names0, paramKinds: pkinds, ret: "i64", blocks: blocks, nTemps: ps.nextSlot, frame: 0 } }
}

// Record every callee's return kind so calls can size their result.
producer registerSigs(prog: Program) {
    fnsig_reset()
    fnsig_add("xstd_concat", 1)
    for f in prog.functions {
        let rs = 0
        if f.retCtype == "xc_string_t" { rs = 1 }
        fnsig_add(f.name, rs)
    }
    for x in prog.externs {
        let rs = 0
        if x.retCtype == "xc_string_t" { rs = 1 }
        fnsig_add(x.name, rs)
    }
}

// Lower the whole program: main (the entry) plus every top-level function. Any
// function outside the supported subset refuses the native build.
producer lowerProgram(prog: Program) -> LowerResult {
    registerSigs(prog)
    let funcs0: XFunc[] = []
    let funcs = funcs0
    let lm = lowerFunc("main", "", prog.entrySpec.retCtype, prog.entrySpec.bodyTokens, true)
    if not lm.ok { return unsupportedLower() }
    funcs = appendXFunc(funcs, lm.fn)
    for f in prog.functions {
        let lf = lowerFunc(f.name, f.params, f.retCtype, f.bodyTokens, false)
        if not lf.ok { return unsupportedLower() }
        funcs = appendXFunc(funcs, lf.fn)
    }
    return LowerResult { ok: true, module: XModule { funcs: funcs, externs: [], entry: "main" }, reason: "" }
}

// Compile a program with a chosen encoder/writer pair. A free function (not a
// method) so it can be called with the selected interface values as arguments.
producer compileNative(diag: Diagnostics, host: Host, enc: InsnEncoder, obj: ObjectWriter, prog: Program, binPath: String) -> Integer {
    strpool_reset()
    let lo = lowerProgram(prog)
    if not lo.ok {
        diag.error(0, "native backend: " + lo.reason)
        return 1
    }
    let m = lo.module
    let efs: EncodedFunc[] = []
    for f in m.funcs { efs = appendEncodedFunc(efs, enc.encode(f)) }
    let externNames: String[] = []
    externNames = appendString(externNames, "xstd_concat")   // runtime string concat
    for x in prog.externs { externNames = appendString(externNames, x.name) }
    let lk = linkModule(EncodedModule { funcs: efs, entry: m.entry }, externNames)
    if not lk.ok {
        diag.error(0, "native backend: unresolved call to " + lk.missing)
        return 1
    }
    let runtimePath = host.env("XC_RUNTIME", "runtime") + "/runtime.dylib"
    if obj.write(lk.words, lk.entryWord, lk.extSites, lk.extSyms, lk.strSites, lk.strIds, runtimePath, binPath) { return 0 }
    diag.error(0, "native backend: failed to write executable " + binPath)
    return 1
}

class XiNativeBackend implements NativeBackend {
    deps { diag: Diagnostics, host: Host, encoders: InsnEncoder[], writers: ObjectWriter[] }

    // Select the encoder/writer matching the target (host by default, overridable
    // with XC_ARCH/XC_OS), then compile with them.
    producer emit(prog: Program, srcPath: String, binPath: String) -> Integer {
        let tgt = Target { arch: host.env("XC_ARCH", "arm64"), os: host.env("XC_OS", "macos") }
        for e in encoders {
            if e.archName() == tgt.arch {
                for w in writers {
                    if w.osName() == tgt.os { return compileNative(diag, host, e, w, prog, binPath) }
                }
            }
        }
        diag.error(0, "native backend: no backend for target " + tgt.arch + "-" + tgt.os)
        return 1
    }
}
