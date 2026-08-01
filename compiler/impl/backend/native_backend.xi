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
// Number (a double) is a distinct 1-slot kind. A high sentinel keeps it clear of
// the type range (3+ti) and the ref-array range (1000+ti).
mapper numKind() -> Integer => 2000000

// Array-of-String kind (elements are two-slot Strings). Above numKind() so it is
// still caught by the `>= 1000` fat-pointer width rule.
mapper strArrKind() -> Integer => 2000001

mapper slotWidth(kind: Integer) -> Integer {
    if kind == 1 { return 2 }
    if kind == 2 { return 3 }
    if kind == numKind() { return 1 }                  // a double occupies one slot
    if kind >= 1000 { return 3 }                       // any array: { data, len, cap }
    if kind >= 3 {
        let r = ctype_is_ref(kind - 3)
        if r == 1 or r == 2 { return 1 }               // a class or interface value is one pointer slot
        return ctype_width(kind - 3)                   // a compound (0) or sum (3): inline value
    }
    return 1
}

// Is `kind` an array type, and if so what is its element's kind?
predicate isArr(kind: Integer) {
    return kind == 2 or kind == strArrKind() or (kind >= 1000 and kind < numKind())
}
mapper arrElemKind(kind: Integer) -> Integer {
    if kind == 2 { return 0 }                          // Integer[]
    if kind == strArrKind() { return 1 }               // String[]
    return 3 + (kind - 1000)                            // array of a ctype (class/interface/compound)
}
// The array kind holding elements of `elemKind`.
mapper arrKindOf(elemKind: Integer) -> Integer {
    if elemKind == 1 { return strArrKind() }
    if elemKind >= 3 { return 1000 + (elemKind - 3) }
    return 2                                            // Integer[] (also the default/empty)
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
mapper psEmitFConst(ps: PS, text: String) -> PS {
    let t = ps.nextSlot
    return PS { toks: ps.toks, pos: ps.pos, insns: appendXInsn(ps.insns, xi_fconst(t, f64_chunk(text, 0), f64_chunk(text, 1), f64_chunk(text, 2), f64_chunk(text, 3))), nextSlot: t + 1, resultTemp: t, ok: ps.ok, names: ps.names, slots: ps.slots, nextLabel: ps.nextLabel, lastRet: ps.lastRet, kinds: ps.kinds, resultKind: numKind() }
}
mapper psEmitFBin(ps: PS, op: String, a: Integer, b: Integer) -> PS {
    let t = ps.nextSlot
    return PS { toks: ps.toks, pos: ps.pos, insns: appendXInsn(ps.insns, xi_fbin(op, t, a, b)), nextSlot: t + 1, resultTemp: t, ok: ps.ok, names: ps.names, slots: ps.slots, nextLabel: ps.nextLabel, lastRet: ps.lastRet, kinds: ps.kinds, resultKind: numKind() }
}
mapper psEmitI2F(ps: PS, src: Integer) -> PS {
    let t = ps.nextSlot
    return PS { toks: ps.toks, pos: ps.pos, insns: appendXInsn(ps.insns, xi_i2f(t, src)), nextSlot: t + 1, resultTemp: t, ok: ps.ok, names: ps.names, slots: ps.slots, nextLabel: ps.nextLabel, lastRet: ps.lastRet, kinds: ps.kinds, resultKind: numKind() }
}
mapper psEmitBin(ps: PS, op: String, a: Integer, b: Integer) -> PS {
    let t = ps.nextSlot
    return PS { toks: ps.toks, pos: ps.pos, insns: appendXInsn(ps.insns, xi_bin(op, t, xtemp(a), xtemp(b))), nextSlot: t + 1, resultTemp: t, ok: ps.ok, names: ps.names, slots: ps.slots, nextLabel: ps.nextLabel, lastRet: ps.lastRet, kinds: ps.kinds, resultKind: 0 }
}
mapper psEmitCmp(ps: PS, op: String, a: Integer, b: Integer) -> PS {
    let t = ps.nextSlot
    return PS { toks: ps.toks, pos: ps.pos, insns: appendXInsn(ps.insns, xi_cmp(op, t, a, b)), nextSlot: t + 1, resultTemp: t, ok: ps.ok, names: ps.names, slots: ps.slots, nextLabel: ps.nextLabel, lastRet: ps.lastRet, kinds: ps.kinds, resultKind: 0 }
}
mapper psEmitFCmp(ps: PS, op: String, a: Integer, b: Integer) -> PS {
    let t = ps.nextSlot
    return PS { toks: ps.toks, pos: ps.pos, insns: appendXInsn(ps.insns, xi_fcmp(op, t, a, b)), nextSlot: t + 1, resultTemp: t, ok: ps.ok, names: ps.names, slots: ps.slots, nextLabel: ps.nextLabel, lastRet: ps.lastRet, kinds: ps.kinds, resultKind: 0 }
}
// Declare a local. A String local (kind 1) reserves two slots (pointer, length).
mapper declareLocal(ps: PS, name: String, kind: Integer) -> PS {
    let slot = ps.nextSlot
    let ns = slot + slotWidth(kind)
    return PS { toks: ps.toks, pos: ps.pos, insns: ps.insns, nextSlot: ns, resultTemp: ps.resultTemp, ok: ps.ok, names: appendString(ps.names, name), slots: appendInt(ps.slots, slot), nextLabel: ps.nextLabel, lastRet: ps.lastRet, kinds: appendInt(ps.kinds, kind), resultKind: ps.resultKind }
}
// Bind a name to an already-occupied slot (a match payload aliases the subject's
// slots, no copy). Overwrites an existing binding of the same name so each match
// arm rebinds cleanly.
mapper bindLocal(ps: PS, name: String, slot: Integer, kind: Integer) -> PS {
    let i = 0
    let n = stringArrLen(ps.names)
    while i < n {
        if stringArrGet(ps.names, i) == name {
            return PS { toks: ps.toks, pos: ps.pos, insns: ps.insns, nextSlot: ps.nextSlot, resultTemp: ps.resultTemp, ok: ps.ok, names: ps.names, slots: setInt(ps.slots, i, slot), nextLabel: ps.nextLabel, lastRet: ps.lastRet, kinds: setInt(ps.kinds, i, kind), resultKind: ps.resultKind }
        }
        i = i + 1
    }
    return PS { toks: ps.toks, pos: ps.pos, insns: ps.insns, nextSlot: ps.nextSlot, resultTemp: ps.resultTemp, ok: ps.ok, names: appendString(ps.names, name), slots: appendInt(ps.slots, slot), nextLabel: ps.nextLabel, lastRet: ps.lastRet, kinds: appendInt(ps.kinds, kind), resultKind: ps.resultKind }
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

// Build call-argument values. `modes` is per slot: 1 = float (a d-register),
// 2 = array pointer (AAPCS: the array's base slot is passed by address), else a
// plain value in an integer register.
mapper slotsToValsF(slots: Integer[], modes: Integer[]) -> XVal[] {
    let out: XVal[] = []
    let i = 0
    let n = intArrLen(slots)
    while i < n {
        let m = intArrGet(modes, i)
        if m == 1 { out = appendXVal(out, xftemp(intArrGet(slots, i))) }
        else { if m == 2 { out = appendXVal(out, xaptr(intArrGet(slots, i))) }
        else { out = appendXVal(out, xtemp(intArrGet(slots, i))) } }
        i = i + 1
    }
    return out
}
mapper zeroFlags(n: Integer) -> Integer[] {
    let out: Integer[] = []
    let i = 0
    while i < n { out = appendInt(out, 0)  i = i + 1 }
    return out
}
// Emit a call. `retKind` is the callee's full native return kind: 1 String (x0:x1),
// numKind Number (d0), an array kind (returned via x8 into 3 slots), else Integer.
// `argModes` marks each arg slot's register bank (see slotsToValsF).
mapper psEmitCallF(ps: PS, callee: String, argSlots: Integer[], argModes: Integer[], dst: Integer, retKind: Integer) -> PS {
    let typ = "i64"
    let ns = dst + 1
    let rk = 0
    if retKind == 1 { typ = "str"  ns = dst + 2  rk = 1 }
    if retKind == numKind() { typ = "f64"  rk = numKind() }
    if isArr(retKind) { typ = "arr"  ns = dst + 3  rk = retKind }
    return PS { toks: ps.toks, pos: ps.pos, insns: appendXInsn(ps.insns, xi_call(dst, callee, slotsToValsF(argSlots, argModes), typ)), nextSlot: ns, resultTemp: dst, ok: ps.ok, names: ps.names, slots: ps.slots, nextLabel: ps.nextLabel, lastRet: ps.lastRet, kinds: ps.kinds, resultKind: rk }
}
mapper psEmitCall(ps: PS, callee: String, argSlots: Integer[], dst: Integer, retStr: Bool) -> PS {
    let rk = 0
    if retStr { rk = 1 }
    return psEmitCallF(ps, callee, argSlots, zeroFlags(intArrLen(argSlots)), dst, rk)
}
// A callee's full native return kind (0 Integer/void, 1 String, numKind Number,
// or an array kind returned via x8).
mapper callRetKind(name: String) -> Integer {
    return fnsig_ret_kind(name)
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
    let hc = psEmitConst(c2, ci)                       // class-index header at slot 0 (for dynamic dispatch)
    let cur = psEmit(hc, xi_astorec(ptrSlot, 0, hc.resultTemp))
    let nf = ctype_nfields(ci)
    let i = 0
    while i < nf {
        let fk = ctype_field_kind_at(ci, i)
        let off = ctype_field_off_at(ci, i)
        if fk >= 1000 {                                // a list dep: construct one of each implementor
            let lst = psEmitImplList(cur, fk - 1000)
            cur = lst
            let j = 0
            while j < 3 { cur = psEmit(cur, xi_astorec(ptrSlot, off + j, lst.resultTemp + j))  j = j + 1 }
        } else {
            if fk >= 3 and ctype_is_ref(fk - 3) == 1 { // a single dep: construct and store it
                let dc = psEmitResolveClass(cur, fk - 3)
                cur = psEmit(dc, xi_astorec(ptrSlot, off, dc.resultTemp))
            } else {
                let def = ctype_field_default_at(ci, i)   // a non-zero constant state default
                if def != 0 and fk == 0 {
                    let dc = psEmitConst(cur, def)
                    cur = psEmit(dc, xi_astorec(ptrSlot, off, dc.resultTemp))
                }
            }
        }
        i = i + 1
    }
    return psKindResult(cur, ptrSlot, 3 + ci)
}

// The concrete class to build for an interface or class name: an explicit bind
// wins; a concrete class is itself; otherwise an interface with exactly one
// implementor is auto-wired to it. -1 when unresolvable (unbound and ambiguous).
mapper concreteClassOf(name: String) -> Integer {
    let bc = bind_class(name)
    if string_len(bc) > 0 { return ctype_index(bc) }
    let ti = ctype_index(name)
    if ti < 0 { return 0 - 1 }
    if ctype_is_ref(ti) == 1 { return ti }             // already a concrete class
    if iface_nimpls(ti) == 1 { return iface_impl_at(ti, 0) }   // sole implementor
    return 0 - 1
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
    let ci = concreteClassOf(iface)
    if ci < 0 { return psFail(p2) }
    return parsePostfix(psEmitResolveClass(psAdvance(p2), ci))
}

// Parse a method call's argument list — ps at '(' — returning the state
// positioned after ')' and the arg slots (self first, then each argument).
mapper parseMethodArgs(ps: PS, selfSlot: Integer) -> ArgResult {
    let cur = psAdvance(ps)                            // consume '('
    let argSlots: Integer[] = []
    let argFloats: Integer[] = []
    argSlots = appendInt(argSlots, selfSlot)          // `this`
    argFloats = appendInt(argFloats, 0)               // the object pointer, not a float
    if psKind(cur) != 101 {
        let r = parseOneArg(cur)
        if not r.ps.ok { return ArgResult { ps: r.ps, slots: argSlots, isFloat: argFloats } }
        cur = r.ps
        argSlots = concatInts(argSlots, r.slots)
        argFloats = concatInts(argFloats, r.isFloat)
        while psKind(cur) == 106 {
            let r2 = parseOneArg(psAdvance(cur))
            if not r2.ps.ok { return ArgResult { ps: r2.ps, slots: argSlots, isFloat: argFloats } }
            cur = r2.ps
            argSlots = concatInts(argSlots, r2.slots)
            argFloats = concatInts(argFloats, r2.isFloat)
        }
    }
    if psKind(cur) != 101 { return ArgResult { ps: psFail(cur), slots: argSlots, isFloat: argFloats } }   // ')'
    return ArgResult { ps: psAdvance(cur), slots: argSlots, isFloat: argFloats }
}

// c.method(args): a static call to <Class>_<method> with the object as arg 0.
mapper parseMethodCall(ps: PS, className: String, method: String, selfSlot: Integer) -> PS {
    let a = parseMethodArgs(ps, selfSlot)
    if not a.ps.ok { return a.ps }
    if intArrLen(a.slots) > 8 { return psFail(a.ps) }
    let callee = className + "_" + method
    return psEmitCallF(a.ps, callee, a.slots, a.isFloat, a.ps.nextSlot, callRetKind(callee))
}

// x.method(args) where x is an interface value: dispatch on the object's
// class-index header to the matching implementor. No vtable, no function
// pointers — a compare-and-branch chain over the interface's implementors,
// each an ordinary static call, all writing their result to one slot.
mapper parseDynMethodCall(ps: PS, ii: Integer, method: String, selfSlot: Integer) -> PS {
    let a = parseMethodArgs(ps, selfSlot)
    if not a.ps.ok { return a.ps }
    if intArrLen(a.slots) > 8 { return psFail(a.ps) }
    let n = iface_nimpls(ii)
    if n == 0 { return psFail(a.ps) }
    let retK = callRetKind(ctype_name(iface_impl_at(ii, 0)) + "_" + method)
    let rk = 0
    if retK == 1 { rk = 1 }
    if retK == 2 { rk = numKind() }
    let rw = slotWidth(rk)
    let rslot = a.ps.nextSlot                          // every arm writes its result here
    let ph = psEmitAloadc(bumpSlots(a.ps, rw), selfSlot, 0, 0)   // load the class-index header
    let hdr = ph.resultTemp
    let lend = ph.nextLabel
    let cur = withNextLabel(ph, ph.nextLabel + 1)
    let k = 0
    while k < n {
        let cci = iface_impl_at(ii, k)
        let lnext = cur.nextLabel
        let pc = psEmitConst(withNextLabel(cur, cur.nextLabel + 1), cci)
        let pe = psEmitCmp(pc, "eq", hdr, pc.resultTemp)
        let pb = psEmit(pe, xi_brz(pe.resultTemp, lnext))        // not this class -> next arm
        let pcall = psEmitCallF(pb, ctype_name(cci) + "_" + method, a.slots, a.isFloat, pb.nextSlot, retK)
        let pcp = pcall
        let j = 0
        while j < rw { pcp = psEmit(pcp, xi_copy(rslot + j, pcall.resultTemp + j))  j = j + 1 }
        cur = psEmit(psEmit(pcp, xi_br(lend)), xi_label(lnext))
        k = k + 1
    }
    return psKindResult(psEmit(cur, xi_label(lend)), rslot, rk)
}

// Load a heap field of a class value at a constant slot offset (this.field).
mapper psEmitAloadc(ps: PS, ptrSlot: Integer, off: Integer, fkind: Integer) -> PS {
    let t = ps.nextSlot
    let p = bumpSlots(ps, slotWidth(fkind))
    let j = 0
    while j < slotWidth(fkind) { p = psEmit(p, xi_aloadc(t + j, ptrSlot, off + j))  j = j + 1 }
    return psKindResult(p, t, fkind)
}

// Load one element: dst = ((i64*)ptr)[idx], one slot, tagged with `kind`. An
// Integer[] element is an Integer (kind 0); a ref array's element is a class or
// interface pointer (kind 3+ti).
mapper psEmitAloadK(ps: PS, ptrSlot: Integer, idxSlot: Integer, kind: Integer) -> PS {
    let t = ps.nextSlot
    return PS { toks: ps.toks, pos: ps.pos, insns: appendXInsn(ps.insns, xi_aload(t, ptrSlot, idxSlot)), nextSlot: t + 1, resultTemp: t, ok: ps.ok, names: ps.names, slots: ps.slots, nextLabel: ps.nextLabel, lastRet: ps.lastRet, kinds: ps.kinds, resultKind: kind }
}
mapper psEmitAload(ps: PS, ptrSlot: Integer, idxSlot: Integer) -> PS {
    return psEmitAloadK(ps, ptrSlot, idxSlot, 0)
}
// Load an element of any width (String = 2 slots, a compound = its width) at a
// variable index, tagged with the element kind.
mapper psEmitAloadN(ps: PS, ptrSlot: Integer, idxSlot: Integer, elemKind: Integer) -> PS {
    let w = slotWidth(elemKind)
    let t = ps.nextSlot
    let p = psEmit(bumpSlots(ps, w), xi_aloadn(t, ptrSlot, idxSlot, w))
    return psKindResult(p, t, elemKind)
}

// Build { data, len, cap } holding one freshly-constructed instance of every
// class implementing interface `ii` (a list-injected `I[]` dependency).
mapper psEmitImplList(ps: PS, ii: Integer) -> PS {
    let n = iface_nimpls(ii)
    let cur = ps
    let ptrSlots: Integer[] = []
    let k = 0
    while k < n {
        cur = psEmitResolveClass(cur, iface_impl_at(ii, k))
        ptrSlots = appendInt(ptrSlots, cur.resultTemp)
        k = k + 1
    }
    let ca = psEmitConst(cur, n * 8)
    let aArgs: Integer[] = []
    aArgs = appendInt(aArgs, ca.resultTemp)
    let cA = psEmitCall(ca, "xstd_alloc", aArgs, ca.nextSlot, false)
    let dataPtr = cA.resultTemp
    let base = cA.nextSlot                              // data / len / cap
    let p = bumpSlots(cA, 3)
    p = psEmit(p, xi_copy(base, dataPtr))
    p = psEmit(p, xi_const(base + 1, n))
    p = psEmit(p, xi_const(base + 2, n))
    let j = 0
    while j < n { p = psEmit(p, xi_astorec(base, j, intArrGet(ptrSlots, j)))  j = j + 1 }
    return psKindResult(p, base, 1000 + ii)
}

// An array literal: allocate n * elemWidth * 8 bytes, store each element's slots,
// and produce the three-slot fat pointer { data, len, cap }. `elemSlots` holds
// each element's base slot; a String or compound element spans several slots.
mapper psEmitArrayLit(ps: PS, elemSlots: Integer[], elemKind: Integer) -> PS {
    let n = intArrLen(elemSlots)
    let ew = slotWidth(elemKind)
    let c1 = psEmitConst(ps, n * ew * 8)               // byte size
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
        let j = 0
        while j < ew { p = psEmit(p, xi_astorec(base, i * ew + j, intArrGet(elemSlots, i) + j))  j = j + 1 }
        i = i + 1
    }
    return psKindResult(p, base, arrKindOf(elemKind))
}

// arraylit := '[' (expr (',' expr)*)? ']'    — element kind taken from the first.
mapper parseArrayLit(ps: PS) -> PS {
    let cur = psAdvance(ps)                            // consume '['
    let elemSlots: Integer[] = []
    let elemKind = 0
    if psKind(cur) != 105 {
        let e = parseExpr(cur)
        if not e.ok { return e }
        elemKind = e.resultKind
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
    return psEmitArrayLit(psAdvance(cur), elemSlots, elemKind)
}

// One call argument: its value slot(s), plus a parallel per-slot mode flag
// (0 value, 1 Number/d-register, 2 array passed by pointer per AAPCS).
type ArgResult = { ps: PS, slots: Integer[], isFloat: Integer[] }
mapper parseOneArg(ps: PS) -> ArgResult {
    let e = parseExpr(ps)
    let sl: Integer[] = []
    let fl: Integer[] = []
    if e.ok {
        if isArr(e.resultKind) {                       // an array: one register, its base by address
            sl = appendInt(sl, e.resultTemp)
            fl = appendInt(fl, 2)
        } else {
            let w = slotWidth(e.resultKind)
            let isf = 0
            if e.resultKind == numKind() { isf = 1 }
            let j = 0
            while j < w { sl = appendInt(sl, e.resultTemp + j)  fl = appendInt(fl, isf)  j = j + 1 }
        }
    }
    return ArgResult { ps: e, slots: sl, isFloat: fl }
}

// Built-in string functions become their linkable runtime symbols (the C
// backend inlines the runtime.h helpers; the native backend calls real symbols).
mapper mapBuiltin(name: String) -> String {
    if name == "string_len" { return "xstd_strlen" }
    if name == "string_char_at" { return "xstd_str_char_at" }
    if name == "string_slice" { return "xstd_str_slice" }
    return name
}

// call := IDENT '(' (arg (',' arg)*)? ')'   — ps is positioned at '('
mapper parseCall(ps: PS, rawName: String) -> PS {
    let name = mapBuiltin(rawName)
    let cur = psAdvance(ps)                       // consume '('
    let argSlots: Integer[] = []
    let argFloats: Integer[] = []
    if psKind(cur) != 101 {
        let r = parseOneArg(cur)
        if not r.ps.ok { return r.ps }
        cur = r.ps
        argSlots = concatInts(argSlots, r.slots)
        argFloats = concatInts(argFloats, r.isFloat)
        while psKind(cur) == 106 {                // ','
            let r2 = parseOneArg(psAdvance(cur))
            if not r2.ps.ok { return r2.ps }
            cur = r2.ps
            argSlots = concatInts(argSlots, r2.slots)
            argFloats = concatInts(argFloats, r2.isFloat)
        }
    }
    if psKind(cur) != 101 { return psFail(cur) }  // ')'
    if intArrLen(argSlots) > 8 { return psFail(cur) }
    let p2 = psAdvance(cur)
    return psEmitCallF(p2, name, argSlots, argFloats, p2.nextSlot, callRetKind(name))
}

// primary := INT | STRING | IDENT | call | '(' expr ')'
mapper parsePrimary(ps: PS) -> PS {
    let k = psKind(ps)
    if k == 227 or k == 126 {                      // logical not: `not x` / `!x` -> (x == 0)
        let r = parsePrimary(psAdvance(ps))
        if not r.ok { return r }
        let z = psEmitConst(r, 0)
        return psEmitCmp(z, "eq", r.resultTemp, z.resultTemp)
    }
    if k == 119 {                                  // unary minus: -x -> 0 - x (float-aware)
        let r = parsePrimary(psAdvance(ps))
        if not r.ok { return r }
        if r.resultKind == numKind() {
            let zf = psEmitFConst(r, "0.0")
            return psEmitFBin(zf, "fsub", zf.resultTemp, r.resultTemp)
        }
        let z = psEmitConst(r, 0)
        return psEmitBin(z, "sub", z.resultTemp, r.resultTemp)
    }
    if k == 2 { return psEmitConst(psAdvance(ps), digitsToInt(psText(ps))) }
    if k == 3 { return psEmitFConst(psAdvance(ps), psText(ps)) }   // float literal -> Number
    if k == 236 { return psEmitConst(psAdvance(ps), 1) }           // true
    if k == 237 { return psEmitConst(psAdvance(ps), 0) }           // false
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
        if var_sum_of(name) >= 0 { return parsePostfix(parseVariantLit(ps, name)) }   // sum-type variant
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

// A sum-type variant literal: `Variant { field: v, ... }` or a nullary `Variant`.
// The value is laid out inline as [tag, payload...]; the payload fields live in
// the variant's payload compound, stored at slot 1 upward.
mapper parseVariantLit(ps: PS, vname: String) -> PS {
    let sumTi = var_sum_of(vname)
    let tag = var_tag_of(vname)
    let payTi = var_pay_of(vname)
    let base = ps.nextSlot
    let sw = ctype_width(sumTi)
    let cur = psEmit(bumpSlots(psAdvance(ps), sw), xi_const(base, tag))   // reserve slots; slot 0 = tag
    if psKind(cur) == 102 and payTi >= 0 {                               // '{ fields }'
        cur = psAdvance(cur)
        while psKind(cur) != 103 and psKind(cur) != 0 {
            let fname = psText(cur)
            let afterName = psAdvance(cur)
            if psKind(afterName) != 108 { return psFail(afterName) }     // ':'
            let off = ctype_field_off(payTi, fname)
            if off < 0 { return psFail(cur) }
            let v = parseExpr(psAdvance(afterName))
            if not v.ok { return v }
            let cc = v
            let j = 0
            while j < slotWidth(v.resultKind) { cc = psEmit(cc, xi_copy(base + 1 + off + j, v.resultTemp + j))  j = j + 1 }
            cur = cc
            if psKind(cur) == 106 { cur = psAdvance(cur) }               // ','
        }
        if psKind(cur) != 103 { return psFail(cur) }                     // '}'
        cur = psAdvance(cur)
    }
    return psKindResult(cur, base, 3 + sumTi)
}

// The extension-function key a scalar receiver carries: `recv.method(args)`
// calls `<key>__method(recv, args)`. "" if the kind has no extension key here.
mapper extKeyOf(kind: Integer) -> String {
    if kind == 0 { return "Integer" }
    if kind == 1 { return "String" }
    if kind == numKind() { return "Number" }
    if kind == 2 { return "arr_integer" }               // Integer[]
    if kind == strArrKind() { return "arr_string" }     // String[]
    if kind >= 1000 and kind < numKind() { return "arr_" + ctype_name(kind - 1000) }   // I[] / compound[]
    return ""
}

// recv.method(args) on a scalar receiver -> <key>__method(recv, args), with the
// receiver (one or two slots) as the first argument.
mapper parseExtCall(ps: PS, key: String, method: String, recvSlot: Integer, recvKind: Integer) -> PS {
    let callee = key + "__" + method
    let cur = psAdvance(ps)                            // consume '('
    let argSlots: Integer[] = []
    let argFloats: Integer[] = []
    if isArr(recvKind) {                              // an array receiver rides a pointer (AAPCS)
        argSlots = appendInt(argSlots, recvSlot)
        argFloats = appendInt(argFloats, 2)
    } else {
        let rw = slotWidth(recvKind)
        let risf = 0
        if recvKind == numKind() { risf = 1 }
        let rj = 0
        while rj < rw { argSlots = appendInt(argSlots, recvSlot + rj)  argFloats = appendInt(argFloats, risf)  rj = rj + 1 }
    }
    if psKind(cur) != 101 {
        let r = parseOneArg(cur)
        if not r.ps.ok { return r.ps }
        cur = r.ps
        argSlots = concatInts(argSlots, r.slots)
        argFloats = concatInts(argFloats, r.isFloat)
        while psKind(cur) == 106 {
            let r2 = parseOneArg(psAdvance(cur))
            if not r2.ps.ok { return r2.ps }
            cur = r2.ps
            argSlots = concatInts(argSlots, r2.slots)
            argFloats = concatInts(argFloats, r2.isFloat)
        }
    }
    if psKind(cur) != 101 { return psFail(cur) }       // ')'
    if intArrLen(argSlots) > 8 { return psFail(cur) }
    let p2 = psAdvance(cur)
    return psEmitCallF(p2, callee, argSlots, argFloats, p2.nextSlot, callRetKind(callee))
}

// Postfix: extension call on a scalar, array `.len`/`.cap`/`.data[i]`, or a
// compound/class field or method.
mapper parsePostfix(ps: PS) -> PS {
    let cur = ps
    while psKind(cur) == 107 {                     // '.'
        let field = psText(psAdvance(cur))
        let after = psAdvance(psAdvance(cur))       // past '.' and the field name
        let ekey = extKeyOf(cur.resultKind)
        if string_len(ekey) > 0 and psKind(after) == 100 {   // scalar.method(args): extension call
            cur = parseExtCall(after, ekey, field, cur.resultTemp, cur.resultKind)
            if not cur.ok { return cur }
        } else {
        if cur.resultKind >= 3 and cur.resultKind < 1000 {   // compound field, class field, or method
            let ti = cur.resultKind - 3
            if ctype_is_ref(ti) == 2 and psKind(after) == 100 {          // interface: dynamic dispatch
                cur = parseDynMethodCall(after, ti, field, cur.resultTemp)
                if not cur.ok { return cur }
            } else {
            if ctype_is_ref(ti) == 1 and psKind(after) == 100 {          // c.method(args): static
                cur = parseMethodCall(after, ctype_name(ti), field, cur.resultTemp)
                if not cur.ok { return cur }
            } else {
                let off = ctype_field_off(ti, field)
                if off < 0 { return psFail(cur) }
                if ctype_is_ref(ti) == 1 { cur = psEmitAloadc(after, cur.resultTemp, off, ctype_field_kind(ti, field)) }   // heap field
                else { cur = psKindResult(after, cur.resultTemp + off, ctype_field_kind(ti, field)) }                       // inline field
            }
            }
        }
        else {                                      // an array: Integer[]/String[]/ref/compound array
        let elemKind = arrElemKind(cur.resultKind)
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
                    cur = psEmitAloadN(psAdvance(idx), ptrSlot, idx.resultTemp, elemKind)
                } else { return psFail(cur) }
            }
        }
        }
        }
    }
    return cur
}

// Promote a slot to Number (Integer -> double via scvtf); a Number is unchanged.
// Used for the implicit Integer -> Number coercion in mixed expressions.
type NumRes = { ps: PS, slot: Integer }
mapper toNum(ps: PS, slot: Integer, kind: Integer) -> NumRes {
    if kind == numKind() { return NumRes { ps: ps, slot: slot } }
    let p = psEmitI2F(ps, slot)
    return NumRes { ps: p, slot: p.resultTemp }
}

// mul := primary (('*' | '/' | '%') primary)*
mapper parseMul(ps: PS) -> PS {
    let cur = parsePrimary(ps)
    if not cur.ok { return cur }
    while (psKind(cur) == 120) or (psKind(cur) == 121) or (psKind(cur) == 122) {
        let isDiv = psKind(cur) == 121
        let isMod = psKind(cur) == 122
        let op = "mul"
        if isDiv { op = "sdiv" }
        if isMod { op = "smod" }
        let leftKind = cur.resultKind
        let left = cur.resultTemp
        let rhs = parsePrimary(psAdvance(cur))
        if not rhs.ok { return rhs }
        if leftKind == numKind() or rhs.resultKind == numKind() {
            if isMod { return psFail(rhs) }                                           // no float remainder
            let fop = "fmul"
            if isDiv { fop = "fdiv" }
            let ln = toNum(rhs, left, leftKind)                                       // coerce both to Number
            let rn = toNum(ln.ps, rhs.resultTemp, rhs.resultKind)
            cur = psEmitFBin(rn.ps, fop, ln.slot, rn.slot)
        } else {
            cur = psEmitBin(rhs, op, left, rhs.resultTemp)
        }
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
        let leftKind = cur.resultKind
        let left = cur.resultTemp
        let rhs = parseMul(psAdvance(cur))
        if not rhs.ok { return rhs }
        if isAdd and leftStr and rhs.resultKind == 1 {
            cur = psEmitConcat(rhs, left, rhs.resultTemp)   // String + String
        } else {
            if leftKind == numKind() or rhs.resultKind == numKind() {
                let fop = "fadd"
                if not isAdd { fop = "fsub" }
                let ln = toNum(rhs, left, leftKind)                                       // coerce both to Number
                let rn = toNum(ln.ps, rhs.resultTemp, rhs.resultKind)
                cur = psEmitFBin(rn.ps, fop, ln.slot, rn.slot)
            } else {
                let op = "add"
                if not isAdd { op = "sub" }
                cur = psEmitBin(rhs, op, left, rhs.resultTemp)
            }
        }
    }
    return cur
}

// cmp := add ((cmp) add)?    (a single, non-associative comparison)
mapper parseCmp(ps: PS) -> PS {
    let cur = parseAdd(ps)
    if not cur.ok { return cur }
    let op = cmpOpOf(psKind(cur))
    if string_len(op) > 0 {
        let leftKind = cur.resultKind
        let leftStr = cur.resultKind == 1
        let left = cur.resultTemp
        let rhs = parseAdd(psAdvance(cur))
        if not rhs.ok { return rhs }
        if leftKind == numKind() or rhs.resultKind == numKind() {
            let ln = toNum(rhs, left, leftKind)                                        // coerce both to Number
            let rn = toNum(ln.ps, rhs.resultTemp, rhs.resultKind)
            return psEmitFCmp(rn.ps, op, ln.slot, rn.slot)
        }
        if leftStr or rhs.resultKind == 1 {                                           // String == / !=
            if not (leftStr and rhs.resultKind == 1) { return psFail(rhs) }
            if op != "eq" and op != "ne" { return psFail(rhs) }                       // only equality on Strings
            let eargs: Integer[] = []
            eargs = appendInt(eargs, left)
            eargs = appendInt(eargs, left + 1)
            eargs = appendInt(eargs, rhs.resultTemp)
            eargs = appendInt(eargs, rhs.resultTemp + 1)
            let ec = psEmitCall(rhs, "xstd_str_eq", eargs, rhs.nextSlot, false)
            if op == "ne" {
                let c1 = psEmitConst(ec, 1)
                return psEmitBin(c1, "sub", c1.resultTemp, ec.resultTemp)             // 1 - eq
            }
            return ec
        }
        return psEmitCmp(rhs, op, left, rhs.resultTemp)
    }
    return cur
}

// and := cmp ('and' cmp)*   — short-circuit like the C backend's `&&`: if the
// left is false (0) the result is 0 and the right side is never evaluated (so a
// guard such as `i + 1 < n and s.charAt(i + 1) == c` stays in bounds).
mapper parseAnd(ps: PS) -> PS {
    let cur = parseCmp(ps)
    if not cur.ok { return cur }
    while psKind(cur) == 225 {
        let la = cur.resultTemp
        let rps = psEmitConst(cur, 0)                          // result slot, default false
        let r = rps.resultTemp
        let lend = rps.nextLabel
        let p = psEmit(withNextLabel(rps, lend + 1), xi_brz(la, lend))   // left false -> keep 0
        let rhs = parseCmp(psAdvance(p))                       // consume 'and', evaluate right
        if not rhs.ok { return rhs }
        let p2 = psEmit(rhs, xi_brz(rhs.resultTemp, lend))     // right false -> keep 0
        let p3 = psEmit(psEmit(p2, xi_const(r, 1)), xi_label(lend))      // both true -> 1
        cur = psKindResult(p3, r, 0)
    }
    return cur
}

// expr := and ('or' and)*   — short-circuit like the C backend's `||`: if the
// left is true the result is 1 and the right side is never evaluated.
mapper parseExpr(ps: PS) -> PS {
    let cur = parseAnd(ps)
    if not cur.ok { return cur }
    while psKind(cur) == 226 {
        let la = cur.resultTemp
        let rps = psEmitConst(cur, 1)                          // result slot, default true
        let r = rps.resultTemp
        let lcheck = rps.nextLabel
        let lend = lcheck + 1
        let p = psEmit(withNextLabel(rps, lend + 1), xi_brz(la, lcheck))   // left false -> check right
        let p1 = psEmit(psEmit(p, xi_br(lend)), xi_label(lcheck))         // left true -> keep 1
        let p1b = psEmit(p1, xi_const(r, 0))                              // assume right false
        let rhs = parseAnd(psAdvance(p1b))                                // consume 'or', evaluate right
        if not rhs.ok { return rhs }
        let p2 = psEmit(rhs, xi_brz(rhs.resultTemp, lend))               // right false -> keep 0
        let p3 = psEmit(psEmit(p2, xi_const(r, 1)), xi_label(lend))      // right true -> 1
        cur = psKindResult(p3, r, 0)
    }
    return cur
}

// block := '{' stmt* '}'
// `brk` / `cont` are the branch targets for `break` / `continue` in the nearest
// enclosing loop, or -1 when there is none (a break/continue there is refused).
mapper parseBlock(ps: PS, brk: Integer, cont: Integer) -> PS {
    if psKind(ps) != 102 { return psFail(ps) }
    let cur = psAdvance(ps)
    while psKind(cur) != 103 and psKind(cur) != 0 {
        cur = parseStmt(cur, brk, cont)
        if not cur.ok { return cur }
    }
    if psKind(cur) != 103 { return psFail(cur) }
    return psAdvance(cur)
}

// Read a type annotation (Integer/Number/Bool/String, a user type, or any of
// these with `[]`) into a native kind, plus the state positioned past it.
type AnnRes = { kind: Integer, ps: PS }
mapper parseTypeAnn(ps: PS) -> AnnRes {
    let k = psKind(ps)
    let base = 0
    if k == 260 { base = numKind() }
    if k == 263 { base = 1 }
    if k == 1 { let ti = ctype_index(psText(ps))  if ti >= 0 { base = 3 + ti } }
    let after = psAdvance(ps)
    if psKind(after) == 104 and psKind(psAdvance(after)) == 105 {   // '[' ']'  -> an array
        let a2 = psAdvance(psAdvance(after))
        if base == 1 { return AnnRes { kind: strArrKind(), ps: a2 } }
        if base >= 3 and base < numKind() { return AnnRes { kind: 1000 + (base - 3), ps: a2 } }
        return AnnRes { kind: 2, ps: a2 }                          // Integer[] (and the fallback)
    }
    return AnnRes { kind: base, ps: after }
}

mapper parseLet(ps: PS) -> PS {
    let p1 = psAdvance(ps)                       // 'let'
    if psKind(p1) != 1 { return psFail(p1) }
    let name = psText(p1)
    let p2 = psAdvance(p1)
    let declKind = 0 - 999                       // no annotation
    if psKind(p2) == 108 {                        // ': Type'
        let ann = parseTypeAnn(psAdvance(p2))
        declKind = ann.kind
        p2 = ann.ps
    }
    if psKind(p2) != 111 { return psFail(p2) }   // '='
    let p3 = parseExpr(psAdvance(p2))
    if not p3.ok { return p3 }
    let vslot = p3.resultTemp
    let kind = p3.resultKind
    let cur0 = p3
    if declKind == numKind() and kind == 0 {     // Integer literal/value -> a Number local
        cur0 = psEmitI2F(p3, vslot)
        vslot = cur0.resultTemp
        kind = numKind()
    }
    if isArr(declKind) and kind == 2 { kind = declKind }   // an empty [] takes the declared element type
    let sx = cur0.nextSlot
    let cur = psEmit(declareLocal(cur0, name, kind), xi_copy(sx, vslot))
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
    let rins = xi_ret2(xtemp(p1.resultTemp), p1.resultKind == 1)
    if p1.resultKind == numKind() { rins = xi_retn(xtemp(p1.resultTemp)) }   // Number -> d0
    if isArr(p1.resultKind) { rins = xi_reta(xtemp(p1.resultTemp)) }         // array -> x8
    let p2 = psEmit(p1, rins)
    return PS { toks: p2.toks, pos: p2.pos, insns: p2.insns, nextSlot: p2.nextSlot, resultTemp: p2.resultTemp, ok: p2.ok, names: p2.names, slots: p2.slots, nextLabel: p2.nextLabel, lastRet: true, kinds: p2.kinds, resultKind: p2.resultKind }
}

// if cond { then } [ else { else } ]   (break/continue in either branch target
// the enclosing loop, so `brk` / `cont` pass straight through)
mapper parseIf(ps: PS, brk: Integer, cont: Integer) -> PS {
    let p1 = parseExpr(psAdvance(ps))
    if not p1.ok { return p1 }
    let cond = p1.resultTemp
    let lElse = p1.nextLabel
    let p3 = psEmit(withNextLabel(p1, lElse + 1), xi_brz(cond, lElse))
    let p4 = parseBlock(p3, brk, cont)
    if not p4.ok { return p4 }
    if psKind(p4) == 223 {                       // else
        let lEnd = p4.nextLabel
        let p6 = psEmit(withNextLabel(p4, lEnd + 1), xi_br(lEnd))
        let p7 = psEmit(p6, xi_label(lElse))
        let p8 = parseBlock(psAdvance(p7), brk, cont)       // consume 'else'
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
    let p4 = parseBlock(p3, lEnd, lStart)       // break -> exit, continue -> re-test the condition
    if not p4.ok { return p4 }
    let p5 = psEmit(p4, xi_br(lStart))
    return psEmit(p5, xi_label(lEnd))
}

// for x in <array> { body } — an index walk over the fat pointer: the loop var
// is bound to data[i] with the element's kind (an Integer, or a class/interface
// ref for a ref array, so `x.method()` dispatches).
mapper parseForIn(ps: PS) -> PS {
    let p1 = psAdvance(ps)                          // consume 'for'
    if psKind(p1) != 1 { return psFail(p1) }
    let varName = psText(p1)
    let p2 = psAdvance(p1)
    if psKind(p2) != 229 { return psFail(p2) }      // 'in'
    let coll = parseExpr(psAdvance(p2))
    if not coll.ok { return coll }
    if not isArr(coll.resultKind) { return psFail(coll) }
    let elemKind = arrElemKind(coll.resultKind)
    let ew = slotWidth(elemKind)                    // an element may span several slots
    let arrBase = coll.resultTemp                   // data / len / cap
    let lenSlot = arrBase + 1
    let iSlot = coll.nextSlot
    let xSlot = coll.nextSlot + 1
    let pinit = psEmit(bumpSlots(coll, 1 + ew), xi_const(iSlot, 0))  // i = 0; reserve i and x (ew slots)
    let pbind = bindLocal(pinit, varName, xSlot, elemKind)
    let lStart = pbind.nextLabel
    let lEnd = pbind.nextLabel + 1
    let pstart = psEmit(withNextLabel(pbind, pbind.nextLabel + 2), xi_label(lStart))
    let pcmp = psEmitCmp(pstart, "slt", iSlot, lenSlot)              // i < len
    let pbrz = psEmit(pcmp, xi_brz(pcmp.resultTemp, lEnd))
    let pload = psEmit(pbrz, xi_aloadn(xSlot, arrBase, iSlot, ew))   // x = data[i] (ew slots)
    let lCont = pload.nextLabel                                      // continue lands on the increment
    let pbody = parseBlock(withNextLabel(pload, pload.nextLabel + 1), lEnd, lCont)  // break -> exit
    if not pbody.ok { return pbody }
    let pcont = psEmit(pbody, xi_label(lCont))
    let pinc = psEmitBin(psEmitConst(pcont, 1), "add", iSlot, pcont.nextSlot)   // i = i + 1
    let pstore = psEmit(pinc, xi_copy(iSlot, pinc.resultTemp))
    return psEmit(psEmit(pstore, xi_br(lStart)), xi_label(lEnd))
}

// match <sum-expr> { Variant [binding] -> { body } ... } — a tag test per arm,
// binding the payload before running the arm, lowered to a compare/branch chain.
mapper parseMatch(ps: PS, brk: Integer, cont: Integer) -> PS {
    let subj = parseExpr(psAdvance(ps))                // consume 'match', parse the subject
    if not subj.ok { return subj }
    if subj.resultKind < 3 { return psFail(subj) }
    let sumTi = subj.resultKind - 3
    if ctype_is_ref(sumTi) != 3 { return psFail(subj) }   // subject must be a sum value
    let tagSlot = subj.resultTemp                      // slot 0 of the value holds the tag
    if psKind(subj) != 102 { return psFail(subj) }     // '{'
    let lend = subj.nextLabel
    let cur = withNextLabel(psAdvance(subj), subj.nextLabel + 1)
    while psKind(cur) != 103 and psKind(cur) != 0 {
        let vname = psText(cur)
        let vtag = var_tag_of(vname)
        if vtag < 0 { return psFail(cur) }             // only variant patterns are supported
        if var_sum_of(vname) != sumTi { return psFail(cur) }
        let payTi = var_pay_of(vname)
        let p1 = psAdvance(cur)                        // past the variant name
        let bindName = ""
        let pAfter = p1
        if psKind(p1) == 1 { bindName = psText(p1)  pAfter = psAdvance(p1) }
        if psKind(pAfter) != 109 { return psFail(pAfter) }   // '->'
        let pArrow = psAdvance(pAfter)
        let lnext = pArrow.nextLabel
        let pconst = psEmitConst(withNextLabel(pArrow, pArrow.nextLabel + 1), vtag)
        let pcmp = psEmitCmp(pconst, "eq", tagSlot, pconst.resultTemp)
        let pbrz = psEmit(pcmp, xi_brz(pcmp.resultTemp, lnext))   // tag mismatch -> next arm
        let pbound = pbrz
        if string_len(bindName) > 0 and payTi >= 0 { pbound = bindLocal(pbrz, bindName, tagSlot + 1, 3 + payTi) }
        if psKind(pbound) != 102 { return psFail(pbound) }        // require a { block } body
        let pbody = parseBlock(pbound, brk, cont)
        if not pbody.ok { return pbody }
        cur = psEmit(psEmit(pbody, xi_br(lend)), xi_label(lnext))
        if psKind(cur) == 106 { cur = psAdvance(cur) }            // optional ','
    }
    if psKind(cur) != 103 { return psFail(cur) }                  // '}'
    return psEmit(psAdvance(cur), xi_label(lend))
}

mapper parseStmt(ps: PS, brk: Integer, cont: Integer) -> PS {
    let k = psKind(ps)
    if k == 220 { return parseLet(ps) }
    if k == 221 { return parseReturn(ps) }
    if k == 222 { return parseIf(ps, brk, cont) }
    if k == 247 { return parseWhile(ps) }                          // a loop resets break/continue scope
    if k == 246 { return parseForIn(ps) }                          // for x in <array> { ... }
    if k == 224 { return parseMatch(ps, brk, cont) }               // match <sum> { ... }
    if k == 249 {                                                  // break -> loop exit
        if brk < 0 { return psFail(ps) }
        return psEmit(psAdvance(ps), xi_br(brk))
    }
    if k == 250 {                                                  // continue -> loop back-edge
        if cont < 0 { return psFail(ps) }
        return psEmit(psAdvance(ps), xi_br(cont))
    }
    if k == 238 { return parseDotStmt(ps) }                        // this.field = v  or  this.method(...)
    if k == 1 {
        let p1 = psAdvance(ps)
        if psKind(p1) == 100 { return parseCall(p1, psText(ps)) }   // f(...) call statement
        if psKind(p1) == 107 { return parseDotStmt(ps) }            // c.field = v  or  c.method(...)
        return parseAssign(ps)
    }
    return psFail(ps)
}

// this.field = v (store into a class object), c.method(...) as a statement, or
// an array element store xs.data[i] = v.
mapper parseDotStmt(ps: PS) -> PS {
    let name = psText(ps)
    let slot = lookupLocal(ps, name)
    if slot < 0 { return psFail(ps) }
    let kind = lookupKind(ps, name)
    if isArr(kind) {                                   // xs.data[i] = v
        let pd = psAdvance(psAdvance(ps))              // past IDENT and '.'
        if psText(pd) != "data" { return psFail(pd) }
        let pBr = psAdvance(pd)
        if psKind(pBr) != 104 { return psFail(pBr) }   // '['
        let idx = parseExpr(psAdvance(pBr))
        if not idx.ok { return idx }
        if psKind(idx) != 105 { return psFail(idx) }   // ']'
        let pEq = psAdvance(idx)
        if psKind(pEq) != 111 { return psFail(pEq) }   // '='
        let v = parseExpr(psAdvance(pEq))
        if not v.ok { return v }
        return psEmit(v, xi_astoren(slot, idx.resultTemp, v.resultTemp, slotWidth(arrElemKind(kind))))
    }
    if kind < 3 { return psFail(ps) }                  // must be a class value
    let ti = kind - 3
    let pField = psAdvance(psAdvance(ps))              // past IDENT and '.'
    let field = psText(pField)
    let pAfter = psAdvance(pField)
    if psKind(pAfter) == 100 {                         // c.method() / s.method() as a statement
        if ctype_is_ref(ti) == 2 { return parseDynMethodCall(pAfter, ti, field, slot) }
        return parseMethodCall(pAfter, ctype_name(ti), field, slot)
    }
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
        cur = parseStmt(cur, 0 - 1, 0 - 1)             // top level: no enclosing loop
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
            let sp = findChar(piece, 32)                       // "<ctype> <name>"
            if sp < 0 { return ParamParse { ok: false, names: names, kinds: kinds } }
            let pct = string_slice(piece, 0, sp)
            let name = trimStr(string_slice(piece, sp + 1, string_len(piece)))
            let kind = 0 - 1
            if pct == "xc_integer_t" { kind = 0 }
            if pct == "xc_bool_t"    { kind = 0 }        // Bool is a 1-slot Integer
            if pct == "xc_string_t"  { kind = 1 }
            if pct == "xc_number_t"  { kind = numKind() }
            if pct == "xc_arr_integer_t" { kind = 2 }              // Integer[]
            if pct == "xc_arr_string_t"  { kind = strArrKind() }   // String[]
            if kind < 0 and pct.startsWith2("xc_arr_") {           // an array of a registered type
                let et = ctype_index(string_slice(pct, 7, string_len(pct) - 2))
                if et >= 0 { kind = 1000 + et }
            }
            if kind < 0 and pct.startsWith2("xc_") and string_len(pct) > 5 {   // a class or interface value
                let ti = ctype_index(string_slice(pct, 3, string_len(pct) - 2))
                if ti >= 0 { kind = 3 + ti }
            }
            if kind < 0 { return ParamParse { ok: false, names: names, kinds: kinds } }
            if string_len(name) == 0 { return ParamParse { ok: false, names: names, kinds: kinds } }
            names = appendString(names, name)
            kinds = appendInt(kinds, kind)
            start = i + 1
        }
        i = i + 1
    }
    return ParamParse { ok: true, names: names, kinds: kinds }
}

// Does the body mention `name` as an identifier? Used to marshal the entry's
// argv only when `main` actually reads its args parameter (so an entry that
// ignores args carries no argv setup).
predicate bodyUsesName(toks: Token[], name: String) {
    let i = 0
    let n = tokenArrLen(toks)
    while i < n {
        let t = tokenArrGet(toks, i)
        if t.kind == 1 and t.text == name { return true }
        i = i + 1
    }
    return false
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
    let arrRet = retC.startsWith2("xc_arr_")
    if retC != "xc_integer_t" and retC != "xc_bool_t" and retC != "xc_string_t" and retC != "xc_number_t" and not arrRet { return FuncLower { ok: false, fn: dummyFn() } }
    let retSig = "i64"
    if arrRet { retSig = "arr" }
    let names0: String[] = []
    let slots0: Integer[] = []
    let kinds0: Integer[] = []
    let pkinds: Integer[] = []
    let nslots = 0
    let nxreg = 0
    let ndreg = 0
    let entryArgsName = ""            // set when the entry marshals argv into a String[]
    if isEntry {
        // The loader hands the entry argc in x0 and argv in x1. If `main` declares
        // a single String[] parameter, spill those two as hidden Integer params and
        // marshal them into the array with a runtime call; otherwise ignore them.
        let ep = parseNativeParams(paramStr)
        if ep.ok and stringArrLen(ep.names) == 1 and intArrGet(ep.kinds, 0) == strArrKind() and bodyUsesName(bodyTokens, stringArrGet(ep.names, 0)) {
            names0 = appendString(names0, "__argc")   // slot 0 <- x0
            slots0 = appendInt(slots0, 0)
            kinds0 = appendInt(kinds0, 0)
            pkinds = appendInt(pkinds, 1)
            names0 = appendString(names0, "__argv")   // slot 1 <- x1
            slots0 = appendInt(slots0, 1)
            kinds0 = appendInt(kinds0, 0)
            pkinds = appendInt(pkinds, 1)
            names0 = appendString(names0, stringArrGet(ep.names, 0))   // args at slots 2,3,4
            slots0 = appendInt(slots0, 2)
            kinds0 = appendInt(kinds0, strArrKind())
            nslots = 5
            nxreg = 2
            entryArgsName = stringArrGet(ep.names, 0)
        }
    }
    if not isEntry {
        let pp = parseNativeParams(paramStr)
        if not pp.ok { return FuncLower { ok: false, fn: dummyFn() } }
        names0 = pp.names
        let np = stringArrLen(pp.names)
        let i = 0
        while i < np {
            let kind = intArrGet(pp.kinds, i)
            slots0 = appendInt(slots0, nslots)
            kinds0 = appendInt(kinds0, kind)
            if kind == numKind() {                      // a Number param: one slot from a d-register (paramKinds -1)
                pkinds = appendInt(pkinds, 0 - 1)
                nslots = nslots + 1
                ndreg = ndreg + 1
            } else {
                if isArr(kind) {                        // an array param: a pointer in one register (paramKinds -2)
                    pkinds = appendInt(pkinds, 0 - 2)
                    nslots = nslots + 3
                    nxreg = nxreg + 1
                } else {
                    let w = slotWidth(kind)             // paramKinds carries the slot width (x-registers to spill)
                    pkinds = appendInt(pkinds, w)
                    nslots = nslots + w
                    nxreg = nxreg + w
                }
            }
            i = i + 1
        }
        if nxreg > 8 or ndreg > 8 { return FuncLower { ok: false, fn: dummyFn() } }
    }
    let insns0: XInsn[] = []
    let ps0 = PS { toks: bodyTokens, pos: 0, insns: insns0, nextSlot: nslots, resultTemp: 0, ok: true, names: names0, slots: slots0, nextLabel: 0, lastRet: false, kinds: kinds0, resultKind: 0 }
    if string_len(entryArgsName) > 0 {           // args = xstd_args(argc, argv) -> slots 2,3,4
        let aa: Integer[] = []
        aa = appendInt(aa, 0)
        aa = appendInt(aa, 1)
        ps0 = psEmitCallF(ps0, "xstd_args", aa, zeroFlags(2), 2, strArrKind())
    }
    let ps = parseStmts(ps0)
    if not ps.ok { return FuncLower { ok: false, fn: dummyFn() } }
    if not ps.lastRet { return FuncLower { ok: false, fn: dummyFn() } }
    let blocks0: XBlock[] = []
    let blocks = appendXBlock(blocks0, XBlock { id: 0, insns: ps.insns })
    return FuncLower { ok: true, fn: XFunc { name: name, params: names0, paramKinds: pkinds, ret: retSig, blocks: blocks, nTemps: ps.nextSlot, frame: 0 } }
}

// Lower a class method to <Class>_<method>. `this` (the object pointer) is the
// first parameter, in slot 0; declared parameters follow. A void method (no
// return) gets a trailing return so the epilogue runs.
mapper lowerMethod(className: String, ci: Integer, meth: MethodSpec) -> FuncLower {
    let retC = meth.retCtype
    let arrRet = retC.startsWith2("xc_arr_")
    let retSig = "i64"
    if arrRet { retSig = "arr" }
    let isVoid = retC != "xc_integer_t" and retC != "xc_bool_t" and retC != "xc_string_t" and retC != "xc_number_t" and not arrRet
    let pp = parseNativeParams(meth.params)
    if not pp.ok { return FuncLower { ok: false, fn: dummyFn() } }
    let names0: String[] = []
    let slots0: Integer[] = []
    let kinds0: Integer[] = []
    let pkinds: Integer[] = []
    names0 = appendString(names0, "this")
    slots0 = appendInt(slots0, 0)
    kinds0 = appendInt(kinds0, 3 + ci)     // a class value, for field access
    pkinds = appendInt(pkinds, 1)          // `this` occupies one x-register (the pointer)
    let nslots = 1
    let nxreg = 1
    let ndreg = 0
    let np = stringArrLen(pp.names)
    let i = 0
    while i < np {
        let kd = intArrGet(pp.kinds, i)
        names0 = appendString(names0, stringArrGet(pp.names, i))
        slots0 = appendInt(slots0, nslots)
        kinds0 = appendInt(kinds0, kd)
        if kd == numKind() {                  // a Number param: one slot from a d-register
            pkinds = appendInt(pkinds, 0 - 1)
            nslots = nslots + 1
            ndreg = ndreg + 1
        } else {
            if isArr(kd) {                    // an array param: a pointer in one register
                pkinds = appendInt(pkinds, 0 - 2)
                nslots = nslots + 3
                nxreg = nxreg + 1
            } else {
                let w = slotWidth(kd)
                pkinds = appendInt(pkinds, w)
                nslots = nslots + w
                nxreg = nxreg + w
            }
        }
        i = i + 1
    }
    if nxreg > 8 or ndreg > 8 { return FuncLower { ok: false, fn: dummyFn() } }
    let insns0: XInsn[] = []
    let ps0 = parseStmts(PS { toks: meth.bodyTokens, pos: 0, insns: insns0, nextSlot: nslots, resultTemp: 0, ok: true, names: names0, slots: slots0, nextLabel: 0, lastRet: false, kinds: kinds0, resultKind: 0 })
    if not ps0.ok { return FuncLower { ok: false, fn: dummyFn() } }
    let ps = ps0
    if not ps0.lastRet {
        if isVoid { ps = psEmit(ps0, xi_ret2(xtemp(0), false)) } else { return FuncLower { ok: false, fn: dummyFn() } }
    }
    let blocks0: XBlock[] = []
    let blocks = appendXBlock(blocks0, XBlock { id: 0, insns: ps.insns })
    return FuncLower { ok: true, fn: XFunc { name: className + "_" + meth.name, params: names0, paramKinds: pkinds, ret: retSig, blocks: blocks, nTemps: ps.nextSlot, frame: 0 } }
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
        if fctype == "xc_number_t" { fk = numKind() }        // a double: one slot, float-typed
        if fctype.startsWith2("xc_arr_") { fk = 2  fw = 3 }
        ctype_add_field(ti, fname, fk, fw)
    }
}

// Split "a:ct,b:ct" into ["a:ct", "b:ct"]; an empty string yields no fields.
mapper splitCommas(s: String) -> String[] {
    let out: String[] = []
    let n = string_len(s)
    let start = 0
    let i = 0
    while i <= n {
        if i == n or string_char_at(s, i) == 44 {            // ',' or end
            if i > start { out = appendString(out, string_slice(s, start, i)) }
            start = i + 1
        }
        i = i + 1
    }
    return out
}

// Register sum types. A sum value is inline [tag, payload...]: the type is a
// ctype of isRef 3 whose width is 1 (tag) + the widest variant's payload. Each
// variant records its tag and a payload compound (its fields), keyed by name.
producer registerSums(prog: Program) {
    var_reset()
    for t in prog.types {
        if t.isSum {
            let si = ctype_add(t.name, 3)
            let tag = 0
            let maxPay = 0
            for v in t.variants {
                let bar = findChar(v, 124)                    // '|' separating name from fields
                let vname = string_slice(v, 0, bar)
                let fstr = string_slice(v, bar + 1, string_len(v))
                let payTi = 0 - 1
                let payW = 0
                if string_len(fstr) > 0 {
                    payTi = ctype_add(t.name + "$" + vname, 0)
                    addFields(payTi, splitCommas(fstr))
                    payW = ctype_width(payTi)
                }
                var_add(vname, si, tag, payTi)
                if payW > maxPay { maxPay = payW }
                tag = tag + 1
            }
            ctype_set_width(si, 1 + maxPay)
        }
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
    for ifc in prog.ifaces { ctype_add(ifc.name, 2) }          // interfaces (dispatch targets)
    registerSums(prog)                                         // sum types + their variants
    for c in prog.classes { ctype_add(c.name, 1) }             // names first (so deps can resolve)
    iface_impl_reset()                                         // which classes implement each interface
    for c in prog.classes {
        let ci = ctype_index(c.name)
        for impl in c.implNames {
            let ii = ctype_index(impl)
            if ii >= 0 { iface_impl_add(ii, ci) }
        }
    }
    sing_reset()
    for m in prog.modules {
        for b in m.bindings {
            bind_add(b.ifaceName, b.concreteName)
            let sk = b.scopeKind
            if string_len(sk) == 0 { sk = m.defaultScope }
            if sk == "singleton" { sing_mark(b.concreteName) }      // shares one instance
        }
    }
    for c in prog.classes {                                    // then fields: deps, then state
        let ci = ctype_index(c.name)
        for dep in c.depList {
            if dep.form == "list" {                            // I[]: an array of all implementors
                let ii = ctype_index(dep.ifaceName)
                if ii >= 0 { ctype_add_field(ci, dep.name, 1000 + ii, 3) }
            } else {                                           // a single dep: a pointer to its concrete class
                let dci = concreteClassOf(dep.ifaceName)
                if dci >= 0 { ctype_add_field(ci, dep.name, 3 + dci, 1) }
            }
        }
        addFields(ci, c.stateFields)
    }
    registerStateDefaults(prog)
}

// Record non-zero constant state defaults (`state { n: Integer = 5 }`). The
// stateInit token stream is `name [= expr] [,]` per field; only a single Integer
// or `true` literal is treated as a constant (calloc already gives 0 / "" / [] /
// false, so the common zero defaults need nothing).
producer registerStateDefaults(prog: Program) {
    for c in prog.classes {
        let ci = ctype_index(c.name)
        let toks = c.stateInit
        let n = tokenArrLen(toks)
        let i = 0
        while i < n {
            let fname = tokenArrGet(toks, i).text
            i = i + 1
            if i < n and tokenArrGet(toks, i).kind == 111 {          // '='
                i = i + 1
                if i < n {
                    let t = tokenArrGet(toks, i)
                    let val = 0
                    let isConst = false
                    if t.kind == 2 { val = digitsToInt(t.text)  isConst = true }
                    if t.kind == 236 { val = 1  isConst = true }     // true
                    let endsHere = i + 1 >= n
                    if i + 1 < n and tokenArrGet(toks, i + 1).kind == 106 { endsHere = true }
                    if isConst and endsHere and val != 0 { ctype_set_field_default(ci, fname, val) }
                }
                while i < n and tokenArrGet(toks, i).kind != 106 { i = i + 1 }   // skip to ','
            }
            if i < n and tokenArrGet(toks, i).kind == 106 { i = i + 1 }          // ','
        }
    }
}

// A callee's return kind for the sig registry: 0 Integer/void, 1 String, 2 Number.
mapper retKindOfCtype(retC: String) -> Integer {
    if retC == "xc_string_t" { return 1 }
    if retC == "xc_number_t" { return numKind() }
    if retC == "xc_arr_integer_t" { return 2 }
    if retC == "xc_arr_string_t" { return strArrKind() }
    if retC.startsWith2("xc_arr_") {
        let et = ctype_index(string_slice(retC, 7, string_len(retC) - 2))
        if et >= 0 { return 1000 + et }
    }
    return 0
}

// Record every callee's return kind so calls can size and place their result.
producer registerSigs(prog: Program) {
    fnsig_reset()
    fnsig_add("xstd_concat", 1)
    fnsig_add("xstd_alloc", 0)
    fnsig_add("xstd_singleton_get", 0)
    fnsig_add("xstd_singleton_set", 0)
    fnsig_add("xstd_strlen", 0)
    fnsig_add("xstd_str_char_at", 0)
    fnsig_add("xstd_str_slice", 1)
    fnsig_add("xstd_str_eq", 0)
    fnsig_add("xstd_args", strArrKind())      // argv marshalled into a String[] (x8 return)
    for f in prog.functions { fnsig_add(f.name, retKindOfCtype(f.retCtype)) }
    for x in prog.externs { fnsig_add(x.name, retKindOfCtype(x.retCtype)) }
    for c in prog.classes {
        for meth in c.methList { fnsig_add(c.name + "_" + meth.name, retKindOfCtype(meth.retCtype)) }
    }
}

// Lower the whole program: main (the entry) plus every top-level function. Any
// function outside the supported subset refuses the native build.
producer lowerProgram(prog: Program) -> LowerResult {
    registerTypes(prog)
    registerSigs(prog)
    let funcs0: XFunc[] = []
    let funcs = funcs0
    let lm = lowerFunc("main", prog.entrySpec.params, prog.entrySpec.retCtype, prog.entrySpec.bodyTokens, true)
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
    externNames = appendString(externNames, "xstd_strlen")   // string operations
    externNames = appendString(externNames, "xstd_str_char_at")
    externNames = appendString(externNames, "xstd_str_slice")
    externNames = appendString(externNames, "xstd_str_eq")
    externNames = appendString(externNames, "xstd_args")     // argv -> String[] for the entry
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
