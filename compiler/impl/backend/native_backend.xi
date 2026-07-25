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
    kinds:      Integer[],   // per local: 0 = Integer (1 slot), 1 = String (2), 2 = Integer[] (3)
    nextLabel:  Integer,
    lastRet:    Bool,
    resultKind: Integer      // kind of the last expression (0/1/2); extra slots follow resultTemp
}

// Stack slots a value of `kind` occupies: Integer 1, String 2, array 3, and a
// compound (kind >= 3, i.e. type index kind-3) its registered width.
mapper slotWidth(kind: Integer) -> Integer {
    if kind == 1 { return 2 }
    if kind == 2 { return 3 }
    if kind >= 3 {
        if ctype_is_ref(kind - 3) == 1 { return 1 }   // a class value is one pointer slot
        return ctype_width(kind - 3)
    }
    return 1
}

mapper psKind(ps: PS) -> Integer {
    if ps.pos >= tokenArrLen(ps.toks) { return 0 }
    return tokenArrGet(ps.toks, ps.pos).kind
}
mapper psText(ps: PS) -> String { return tokenArrGet(ps.toks, ps.pos).text }
mapper psAdvance(ps: PS) -> PS {
    return PS { toks: ps.toks, pos: ps.pos + 1, insns: ps.insns, nextSlot: ps.nextSlot, resultTemp: ps.resultTemp, ok: ps.ok, names: ps.names, slots: ps.slots, nextLabel: ps.nextLabel, lastRet: ps.lastRet, kinds: ps.kinds, resultKind: ps.resultKind }
}
mapper psFail(ps: PS) -> PS {
    return PS { toks: ps.toks, pos: ps.pos, insns: ps.insns, nextSlot: ps.nextSlot, resultTemp: ps.resultTemp, ok: false, names: ps.names, slots: ps.slots, nextLabel: ps.nextLabel, lastRet: ps.lastRet, kinds: ps.kinds, resultKind: ps.resultKind }
}
mapper psEmit(ps: PS, insn: XInsn) -> PS {
    return PS { toks: ps.toks, pos: ps.pos, insns: appendXInsn(ps.insns, insn), nextSlot: ps.nextSlot, resultTemp: ps.resultTemp, ok: ps.ok, names: ps.names, slots: ps.slots, nextLabel: ps.nextLabel, lastRet: false, kinds: ps.kinds, resultKind: ps.resultKind }
}
mapper psResult(ps: PS, slot: Integer) -> PS {
    return PS { toks: ps.toks, pos: ps.pos, insns: ps.insns, nextSlot: ps.nextSlot, resultTemp: slot, ok: ps.ok, names: ps.names, slots: ps.slots, nextLabel: ps.nextLabel, lastRet: ps.lastRet, kinds: ps.kinds, resultKind: ps.resultKind }
}
mapper withNextLabel(ps: PS, n: Integer) -> PS {
    return PS { toks: ps.toks, pos: ps.pos, insns: ps.insns, nextSlot: ps.nextSlot, resultTemp: ps.resultTemp, ok: ps.ok, names: ps.names, slots: ps.slots, nextLabel: n, lastRet: ps.lastRet, kinds: ps.kinds, resultKind: ps.resultKind }
}
mapper psEmitConst(ps: PS, v: Integer) -> PS {
    let t = ps.nextSlot
    return PS { toks: ps.toks, pos: ps.pos, insns: appendXInsn(ps.insns, xi_const(t, v)), nextSlot: t + 1, resultTemp: t, ok: ps.ok, names: ps.names, slots: ps.slots, nextLabel: ps.nextLabel, lastRet: ps.lastRet, kinds: ps.kinds, resultKind: 0 }
}
mapper psEmitBin(ps: PS, op: String, a: Integer, b: Integer) -> PS {
    let t = ps.nextSlot
    return PS { toks: ps.toks, pos: ps.pos, insns: appendXInsn(ps.insns, xi_bin(op, t, xtemp(a), xtemp(b))), nextSlot: t + 1, resultTemp: t, ok: ps.ok, names: ps.names, slots: ps.slots, nextLabel: ps.nextLabel, lastRet: ps.lastRet, kinds: ps.kinds, resultKind: 0 }
}
mapper psEmitCmp(ps: PS, op: String, a: Integer, b: Integer) -> PS {
    let t = ps.nextSlot
    return PS { toks: ps.toks, pos: ps.pos, insns: appendXInsn(ps.insns, xi_cmp(op, t, a, b)), nextSlot: t + 1, resultTemp: t, ok: ps.ok, names: ps.names, slots: ps.slots, nextLabel: ps.nextLabel, lastRet: ps.lastRet, kinds: ps.kinds, resultKind: 0 }
}
// Declare a local. A String local (kind 1) reserves two slots (pointer, length).
mapper declareLocal(ps: PS, name: String, kind: Integer) -> PS {
    let slot = ps.nextSlot
    let ns = slot + slotWidth(kind)
    return PS { toks: ps.toks, pos: ps.pos, insns: ps.insns, nextSlot: ns, resultTemp: ps.resultTemp, ok: ps.ok, names: appendString(ps.names, name), slots: appendInt(ps.slots, slot), nextLabel: ps.nextLabel, lastRet: ps.lastRet, kinds: appendInt(ps.kinds, kind), resultKind: ps.resultKind }
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
// Set the result to `slot` with a given kind (0 Integer, 1 String, 2 array).
mapper psKindResult(ps: PS, slot: Integer, kind: Integer) -> PS {
    return PS { toks: ps.toks, pos: ps.pos, insns: ps.insns, nextSlot: ps.nextSlot, resultTemp: slot, ok: ps.ok, names: ps.names, slots: ps.slots, nextLabel: ps.nextLabel, lastRet: ps.lastRet, kinds: ps.kinds, resultKind: kind }
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
    let rk = 0
    if retStr { typ = "str"  ns = dst + 2  rk = 1 }
    return PS { toks: ps.toks, pos: ps.pos, insns: appendXInsn(ps.insns, xi_call(dst, callee, slotsToVals(argSlots), typ)), nextSlot: ns, resultTemp: dst, ok: ps.ok, names: ps.names, slots: ps.slots, nextLabel: ps.nextLabel, lastRet: ps.lastRet, kinds: ps.kinds, resultKind: rk }
}

mapper psEmitStrAddr(ps: PS, strid: Integer) -> PS {
    let t = ps.nextSlot
    return PS { toks: ps.toks, pos: ps.pos, insns: appendXInsn(ps.insns, xi_straddr(t, strid)), nextSlot: t + 1, resultTemp: t, ok: ps.ok, names: ps.names, slots: ps.slots, nextLabel: ps.nextLabel, lastRet: ps.lastRet, kinds: ps.kinds, resultKind: 1 }
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

mapper bumpSlots(ps: PS, k: Integer) -> PS {
    return PS { toks: ps.toks, pos: ps.pos, insns: ps.insns, nextSlot: ps.nextSlot + k, resultTemp: ps.resultTemp, ok: ps.ok, names: ps.names, slots: ps.slots, nextLabel: ps.nextLabel, lastRet: ps.lastRet, kinds: ps.kinds, resultKind: ps.resultKind }
}

// Fresh construction: allocate zeroed storage, then recursively construct and
// store each dependency.
mapper emitConstruct(ps: PS, ci: Integer) -> PS {
    let bytes = ctype_width(ci) * 8
    if bytes == 0 { bytes = 8 }                        // at least one word for a stateless object
    let c1 = psEmitConst(ps, bytes)
    let args: Integer[] = []
    args = appendInt(args, c1.resultTemp)
    let c2 = psEmitCall(c1, "xstd_alloc", args, c1.nextSlot, false)
    let ptrSlot = c2.resultTemp
    let cur = c2
    let nf = ctype_nfields(ci)
    let i = 0
    while i < nf {
        let fk = ctype_field_kind_at(ci, i)
        if fk >= 3 and ctype_is_ref(fk - 3) == 1 {     // a dependency: construct and store it
            let dc = psEmitResolveClass(cur, fk - 3)
            cur = psEmit(dc, xi_astorec(ptrSlot, ctype_field_off_at(ci, i), dc.resultTemp))
        }
        i = i + 1
    }
    return psKindResult(cur, ptrSlot, 3 + ci)
}

// Produce a class value. A singleton is built once and cached: load the cache,
// and construct + store only on the first request.
mapper psEmitResolveClass(ps: PS, ci: Integer) -> PS {
    let si = sing_index(ctype_name(ci))
    if si < 0 { return emitConstruct(ps, ci) }         // transient

    let rslot = ps.nextSlot                            // holds the instance on both paths
    let p0 = bumpSlots(ps, 1)
    let g1 = psEmitConst(p0, si)
    let gArgs: Integer[] = []
    gArgs = appendInt(gArgs, g1.resultTemp)
    let pg = psEmitCall(g1, "xstd_singleton_get", gArgs, g1.nextSlot, false)
    let pc = psEmit(pg, xi_copy(rslot, pg.resultTemp))
    let lc = pc.nextLabel
    let le = pc.nextLabel + 1
    let plab = withNextLabel(pc, pc.nextLabel + 2)
    let pbrz = psEmit(plab, xi_brz(rslot, lc))         // cached == 0 -> construct
    let pbr = psEmit(pbrz, xi_br(le))                  // else use the cache
    let plc = psEmit(pbr, xi_label(lc))
    let pcon = emitConstruct(plc, ci)
    let pcp = psEmit(pcon, xi_copy(rslot, pcon.resultTemp))
    let s1 = psEmitConst(pcp, si)
    let sArgs: Integer[] = []
    sArgs = appendInt(sArgs, s1.resultTemp)
    sArgs = appendInt(sArgs, rslot)
    let pset = psEmitCall(s1, "xstd_singleton_set", sArgs, s1.nextSlot, false)
    let ple = psEmit(pset, xi_label(le))
    return psKindResult(ple, rslot, 3 + ci)
}
mapper parseResolve(ps: PS) -> PS {
    let p1 = psAdvance(psAdvance(psAdvance(ps)))       // past IDENT, '.', 'resolve'
    if psKind(p1) != 100 { return psFail(p1) }         // '('
    let iface = psText(psAdvance(p1))
    let p2 = psAdvance(psAdvance(p1))                  // past '(' and interface name
    if psKind(p2) != 101 { return psFail(p2) }         // ')'
    let ci = ctype_index(bind_class(iface))
    if ci < 0 { return psFail(p2) }
    return parsePostfix(psEmitResolveClass(psAdvance(p2), ci))
}

// c.method(args): a static call to <Class>_<method> with the object as arg 0.
mapper parseMethodCall(ps: PS, className: String, method: String, selfSlot: Integer) -> PS {
    let cur = psAdvance(ps)                            // consume '('
    let argSlots: Integer[] = []
    argSlots = appendInt(argSlots, selfSlot)          // `this`
    if psKind(cur) != 101 {
        let r = parseOneArg(cur)
        if not r.ps.ok { return r.ps }
        cur = r.ps
        argSlots = concatInts(argSlots, r.slots)
        while psKind(cur) == 106 {
            let r2 = parseOneArg(psAdvance(cur))
            if not r2.ps.ok { return r2.ps }
            cur = r2.ps
            argSlots = concatInts(argSlots, r2.slots)
        }
    }
    if psKind(cur) != 101 { return psFail(cur) }       // ')'
    if intArrLen(argSlots) > 8 { return psFail(cur) }
    let callee = className + "_" + method
    let p2 = psAdvance(cur)
    return psEmitCall(p2, callee, argSlots, p2.nextSlot, fnsig_ret_str(callee) == 1)
}

// Load a heap field of a class value at a constant slot offset (this.field).
mapper psEmitAloadc(ps: PS, ptrSlot: Integer, off: Integer, fkind: Integer) -> PS {
    let t = ps.nextSlot
    let p = bumpSlots(ps, slotWidth(fkind))
    let j = 0
    while j < slotWidth(fkind) { p = psEmit(p, xi_aloadc(t + j, ptrSlot, off + j))  j = j + 1 }
    return psKindResult(p, t, fkind)
}

// Load one element: dst = ((Integer*)ptr)[idx]. Result is an Integer.
mapper psEmitAload(ps: PS, ptrSlot: Integer, idxSlot: Integer) -> PS {
    let t = ps.nextSlot
    return PS { toks: ps.toks, pos: ps.pos, insns: appendXInsn(ps.insns, xi_aload(t, ptrSlot, idxSlot)), nextSlot: t + 1, resultTemp: t, ok: ps.ok, names: ps.names, slots: ps.slots, nextLabel: ps.nextLabel, lastRet: ps.lastRet, kinds: ps.kinds, resultKind: 0 }
}

// An Integer[] literal: allocate n*8 bytes, store each element, and produce the
// three-slot fat pointer { data, len, cap }.
mapper psEmitArrayLit(ps: PS, elemSlots: Integer[]) -> PS {
    let n = intArrLen(elemSlots)
    let c1 = psEmitConst(ps, n * 8)                    // byte size
    let args: Integer[] = []
    args = appendInt(args, c1.resultTemp)
    let c2 = psEmitCall(c1, "xstd_alloc", args, c1.nextSlot, false)
    let ptrSlot = c2.resultTemp
    let base = c2.nextSlot                              // data / len / cap
    let p = bumpSlots(c2, 3)
    p = psEmit(p, xi_copy(base, ptrSlot))
    p = psEmit(p, xi_const(base + 1, n))
    p = psEmit(p, xi_const(base + 2, n))
    let i = 0
    while i < n {
        p = psEmit(p, xi_astorec(base, i, intArrGet(elemSlots, i)))
        i = i + 1
    }
    return psKindResult(p, base, 2)
}

// arraylit := '[' (expr (',' expr)*)? ']'
mapper parseArrayLit(ps: PS) -> PS {
    let cur = psAdvance(ps)                            // consume '['
    let elemSlots: Integer[] = []
    if psKind(cur) != 105 {
        let e = parseExpr(cur)
        if not e.ok { return e }
        elemSlots = appendInt(elemSlots, e.resultTemp)
        cur = e
        while psKind(cur) == 106 {
            let e2 = parseExpr(psAdvance(cur))
            if not e2.ok { return e2 }
            elemSlots = appendInt(elemSlots, e2.resultTemp)
            cur = e2
        }
    }
    if psKind(cur) != 105 { return psFail(cur) }       // ']'
    return psEmitArrayLit(psAdvance(cur), elemSlots)
}

// One call argument: its value slot, plus a second slot (the length) if String.
type ArgResult = { ps: PS, slots: Integer[] }
mapper parseOneArg(ps: PS) -> ArgResult {
    let e = parseExpr(ps)
    let sl: Integer[] = []
    if e.ok {
        let w = slotWidth(e.resultKind)
        let j = 0
        while j < w { sl = appendInt(sl, e.resultTemp + j)  j = j + 1 }
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
        return psKindResult(psAdvance(a2), ptrSlot, 1)
    }
    if k == 104 { return parseArrayLit(ps) }       // '[' -> array literal
    if k == 238 {                                  // 'this' (the object pointer, slot 0 of a method)
        let slot = lookupLocal(ps, "this")
        if slot < 0 { return psFail(ps) }
        return parsePostfix(psKindResult(psAdvance(ps), slot, lookupKind(ps, "this")))
    }
    if k == 1 {
        let name = psText(ps)
        let p1 = psAdvance(ps)
        if psKind(p1) == 100 { return parseCall(p1, name) }   // '(' -> call
        if psKind(p1) == 102 and ctype_index(name) >= 0 {     // 'T {' -> compound construction
            return parsePostfix(parseCompoundLit(ps, ctype_index(name)))
        }                                                     // else the { belongs to an enclosing form
        if psKind(p1) == 107 and psText(psAdvance(p1)) == "resolve" { return parseResolve(ps) }   // Module.resolve(I)
        let slot = lookupLocal(ps, name)
        if slot >= 0 { return parsePostfix(psKindResult(p1, slot, lookupKind(ps, name))) }
        // not a local: a bare dep/field of `this` inside a method
        let thisSlot = lookupLocal(ps, "this")
        if thisSlot >= 0 {
            let ti = lookupKind(ps, "this") - 3
            let off = ctype_field_off(ti, name)
            if off >= 0 { return parsePostfix(psEmitAloadc(p1, thisSlot, off, ctype_field_kind(ti, name))) }
        }
        return psFail(ps)
    }
    if k == 100 {
        let inner = parseExpr(psAdvance(ps))
        if not inner.ok { return inner }
        if psKind(inner) != 101 { return psFail(inner) }
        return psAdvance(inner)
    }
    return psFail(ps)
}

// compoundlit := IDENT '{' (field ':' expr (',' ...)*)? '}'
mapper parseCompoundLit(ps: PS, ti: Integer) -> PS {
    let base = ps.nextSlot
    let cur = bumpSlots(psAdvance(psAdvance(ps)), ctype_width(ti))   // reserve slots; past IDENT and '{'
    while psKind(cur) != 103 and psKind(cur) != 0 {                  // until '}'
        let fname = psText(cur)
        let afterName = psAdvance(cur)
        if psKind(afterName) != 108 { return psFail(afterName) }     // ':'
        let off = ctype_field_off(ti, fname)
        if off < 0 { return psFail(cur) }
        let v = parseExpr(psAdvance(afterName))
        if not v.ok { return v }
        let cc = v
        let j = 0
        while j < slotWidth(v.resultKind) { cc = psEmit(cc, xi_copy(base + off + j, v.resultTemp + j))  j = j + 1 }
        cur = cc
        if psKind(cur) == 106 { cur = psAdvance(cur) }               // ','
    }
    if psKind(cur) != 103 { return psFail(cur) }                     // '}'
    return psKindResult(psAdvance(cur), base, 3 + ti)
}

// Postfix: array `.len`/`.cap`/`.data[i]`, or a compound field `.name`.
mapper parsePostfix(ps: PS) -> PS {
    let cur = ps
    while psKind(cur) == 107 {                     // '.'
        let field = psText(psAdvance(cur))
        let after = psAdvance(psAdvance(cur))       // past '.' and the field name
        if cur.resultKind >= 3 {                    // compound field, class field, or method
            let ti = cur.resultKind - 3
            if ctype_is_ref(ti) == 1 and psKind(after) == 100 {          // c.method(args)
                cur = parseMethodCall(after, ctype_name(ti), field, cur.resultTemp)
                if not cur.ok { return cur }
            } else {
                let off = ctype_field_off(ti, field)
                if off < 0 { return psFail(cur) }
                if ctype_is_ref(ti) == 1 { cur = psEmitAloadc(after, cur.resultTemp, off, ctype_field_kind(ti, field)) }   // heap field
                else { cur = psKindResult(after, cur.resultTemp + off, ctype_field_kind(ti, field)) }                       // inline field
            }
        }
        else {
        if field == "len" { cur = psKindResult(after, cur.resultTemp + 1, 0) }
        else {
            if field == "cap" { cur = psKindResult(after, cur.resultTemp + 2, 0) }
            else {
                if field == "data" {
                    if psKind(after) != 104 { return psFail(after) }   // '['
                    let ptrSlot = cur.resultTemp
                    let idx = parseExpr(psAdvance(after))
                    if not idx.ok { return idx }
                    if psKind(idx) != 105 { return psFail(idx) }       // ']'
                    cur = psEmitAload(psAdvance(idx), ptrSlot, idx.resultTemp)
                } else { return psFail(cur) }
            }
        }
        }
    }
    return cur
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
        let leftStr = cur.resultKind == 1
        let left = cur.resultTemp
        let rhs = parseMul(psAdvance(cur))
        if not rhs.ok { return rhs }
        if isAdd and leftStr and rhs.resultKind == 1 {
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
    let kind = p3.resultKind
    let sx = p3.nextSlot
    let cur = psEmit(declareLocal(p3, name, kind), xi_copy(sx, vslot))
    let j = 1
    while j < slotWidth(kind) { cur = psEmit(cur, xi_copy(sx + j, vslot + j))  j = j + 1 }   // extra slots
    return cur
}

mapper parseAssign(ps: PS) -> PS {
    let name = psText(ps)
    let slot = lookupLocal(ps, name)
    if slot < 0 { return psFail(ps) }
    let w = slotWidth(lookupKind(ps, name))
    let p1 = psAdvance(ps)
    if psKind(p1) != 111 { return psFail(p1) }   // '='
    let p2 = parseExpr(psAdvance(p1))
    if not p2.ok { return p2 }
    let cur = psEmit(p2, xi_copy(slot, p2.resultTemp))
    let j = 1
    while j < w { cur = psEmit(cur, xi_copy(slot + j, p2.resultTemp + j))  j = j + 1 }
    return cur
}

mapper parseReturn(ps: PS) -> PS {
    let p1 = parseExpr(psAdvance(ps))
    if not p1.ok { return p1 }
    let p2 = psEmit(p1, xi_ret2(xtemp(p1.resultTemp), p1.resultKind == 1))
    return PS { toks: p2.toks, pos: p2.pos, insns: p2.insns, nextSlot: p2.nextSlot, resultTemp: p2.resultTemp, ok: p2.ok, names: p2.names, slots: p2.slots, nextLabel: p2.nextLabel, lastRet: true, kinds: p2.kinds, resultKind: p2.resultKind }
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
    if k == 238 { return parseDotStmt(ps) }                        // this.field = v  or  this.method(...)
    if k == 1 {
        let p1 = psAdvance(ps)
        if psKind(p1) == 100 { return parseCall(p1, psText(ps)) }   // f(...) call statement
        if psKind(p1) == 107 { return parseDotStmt(ps) }            // c.field = v  or  c.method(...)
        return parseAssign(ps)
    }
    return psFail(ps)
}

// this.field = v (store into a class object), or c.method(...) as a statement.
mapper parseDotStmt(ps: PS) -> PS {
    let name = psText(ps)
    let slot = lookupLocal(ps, name)
    if slot < 0 { return psFail(ps) }
    let kind = lookupKind(ps, name)
    if kind < 3 { return psFail(ps) }                  // must be a class value
    let ti = kind - 3
    let pField = psAdvance(psAdvance(ps))              // past IDENT and '.'
    let field = psText(pField)
    let pAfter = psAdvance(pField)
    if psKind(pAfter) == 100 { return parseMethodCall(pAfter, ctype_name(ti), field, slot) }   // c.method()
    if psKind(pAfter) != 111 { return psFail(pAfter) } // '='
    let off = ctype_field_off(ti, field)
    if off < 0 { return psFail(pField) }
    let v = parseExpr(psAdvance(pAfter))
    if not v.ok { return v }
    let cc = v
    let j = 0
    while j < slotWidth(v.resultKind) { cc = psEmit(cc, xi_astorec(slot, off + j, v.resultTemp + j))  j = j + 1 }
    return cc
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
    let ps = parseStmts(PS { toks: bodyTokens, pos: 0, insns: insns0, nextSlot: nslots, resultTemp: 0, ok: true, names: names0, slots: slots0, nextLabel: 0, lastRet: false, kinds: kinds0, resultKind: 0 })
    if not ps.ok { return FuncLower { ok: false, fn: dummyFn() } }
    if not ps.lastRet { return FuncLower { ok: false, fn: dummyFn() } }
    let blocks0: XBlock[] = []
    let blocks = appendXBlock(blocks0, XBlock { id: 0, insns: ps.insns })
    return FuncLower { ok: true, fn: XFunc { name: name, params: names0, paramKinds: pkinds, ret: "i64", blocks: blocks, nTemps: ps.nextSlot, frame: 0 } }
}

// Lower a class method to <Class>_<method>. `this` (the object pointer) is the
// first parameter, in slot 0; declared parameters follow. A void method (no
// return) gets a trailing return so the epilogue runs.
mapper lowerMethod(className: String, ci: Integer, meth: MethodSpec) -> FuncLower {
    let retC = meth.retCtype
    let isVoid = retC != "xc_integer_t" and retC != "xc_string_t"
    let pp = parseNativeParams(meth.params)
    if not pp.ok { return FuncLower { ok: false, fn: dummyFn() } }
    let names0: String[] = []
    let slots0: Integer[] = []
    let kinds0: Integer[] = []
    let pkinds: Integer[] = []
    names0 = appendString(names0, "this")
    slots0 = appendInt(slots0, 0)
    kinds0 = appendInt(kinds0, 3 + ci)     // a class value, for field access
    pkinds = appendInt(pkinds, 0)          // one register (the pointer)
    let nslots = 1
    let nregs = 1
    let np = stringArrLen(pp.names)
    let i = 0
    while i < np {
        let kd = intArrGet(pp.kinds, i)
        names0 = appendString(names0, stringArrGet(pp.names, i))
        slots0 = appendInt(slots0, nslots)
        kinds0 = appendInt(kinds0, kd)
        pkinds = appendInt(pkinds, kd)
        if kd == 1 { nslots = nslots + 2  nregs = nregs + 2 } else { nslots = nslots + 1  nregs = nregs + 1 }
        i = i + 1
    }
    if nregs > 8 { return FuncLower { ok: false, fn: dummyFn() } }
    let insns0: XInsn[] = []
    let ps0 = parseStmts(PS { toks: meth.bodyTokens, pos: 0, insns: insns0, nextSlot: nslots, resultTemp: 0, ok: true, names: names0, slots: slots0, nextLabel: 0, lastRet: false, kinds: kinds0, resultKind: 0 })
    if not ps0.ok { return FuncLower { ok: false, fn: dummyFn() } }
    let ps = ps0
    if not ps0.lastRet {
        if isVoid { ps = psEmit(ps0, xi_ret2(xtemp(0), false)) } else { return FuncLower { ok: false, fn: dummyFn() } }
    }
    let blocks0: XBlock[] = []
    let blocks = appendXBlock(blocks0, XBlock { id: 0, insns: ps.insns })
    return FuncLower { ok: true, fn: XFunc { name: className + "_" + meth.name, params: names0, paramKinds: pkinds, ret: "i64", blocks: blocks, nTemps: ps.nextSlot, frame: 0 } }
}

// Add "name:ctype" fields to a registered type, mapping the C type to a kind.
producer addFields(ti: Integer, fields: String[]) {
    for fstr in fields {
        let colon = findChar(fstr, 58)                   // ':'
        let fname = string_slice(fstr, 0, colon)
        let fctype = string_slice(fstr, colon + 1, string_len(fstr))
        let fk = 0
        let fw = 1
        if fctype == "xc_string_t" { fk = 1  fw = 2 }
        if fctype.startsWith2("xc_arr_") { fk = 2  fw = 3 }
        ctype_add_field(ti, fname, fk, fw)
    }
}

// Register compound types (value), classes (heap ref, state layout), and the
// module's interface->class binds.
producer registerTypes(prog: Program) {
    ctype_reset()
    bind_reset()
    for t in prog.types {
        if t.isCompound { addFields(ctype_add(t.name, 0), t.fields) }
    }
    for c in prog.classes { ctype_add(c.name, 1) }             // names first (so deps can resolve)
    sing_reset()
    for m in prog.modules {
        for b in m.bindings {
            bind_add(b.ifaceName, b.concreteName)
            let scope = b.scopeKind
            if string_len(scope) == 0 { scope = m.defaultScope }
            if scope == "singleton" { sing_mark(b.concreteName) }   // shares one instance
        }
    }
    for c in prog.classes {                                    // then fields: deps, then state
        let ci = ctype_index(c.name)
        for dep in c.depList {                                 // a dep is a pointer to its bound class
            let dci = ctype_index(bind_class(dep.ifaceName))
            if dci >= 0 { ctype_add_field(ci, dep.name, 3 + dci, 1) }
        }
        addFields(ci, c.stateFields)
    }
}

// Record every callee's return kind so calls can size their result.
producer registerSigs(prog: Program) {
    fnsig_reset()
    fnsig_add("xstd_concat", 1)
    fnsig_add("xstd_alloc", 0)
    fnsig_add("xstd_singleton_get", 0)
    fnsig_add("xstd_singleton_set", 0)
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
    for c in prog.classes {
        for meth in c.methList {
            let rs = 0
            if meth.retCtype == "xc_string_t" { rs = 1 }
            fnsig_add(c.name + "_" + meth.name, rs)
        }
    }
}

// Lower the whole program: main (the entry) plus every top-level function. Any
// function outside the supported subset refuses the native build.
producer lowerProgram(prog: Program) -> LowerResult {
    registerTypes(prog)
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
    for c in prog.classes {
        let ci = ctype_index(c.name)
        for meth in c.methList {
            let lf = lowerMethod(c.name, ci, meth)
            if not lf.ok { return unsupportedLower() }
            funcs = appendXFunc(funcs, lf.fn)
        }
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
    externNames = appendString(externNames, "xstd_alloc")    // runtime array/object alloc
    externNames = appendString(externNames, "xstd_singleton_get")
    externNames = appendString(externNames, "xstd_singleton_set")
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
