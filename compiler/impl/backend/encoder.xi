// The ISA seam — XIR to machine code, one instruction set per implementation.
//
// `code` is a list of 32-bit instruction words (AArch64 is fixed-width), the
// object writer appends each little-endian. Register allocation is spill
// everything: each XIR slot has an 8-byte stack home, every instruction loads
// its operands into x9/x10, computes, and stores the result back. Every function
// saves fp/lr (calls clobber lr) and lays its slots below them. Internal
// branches are resolved in a second pass; calls are left as relocations for the
// linker (linkModule), which concatenates the functions and patches each BL.

type XReloc = { at: Integer, sym: String, kind: String, addend: Integer }
type EncodedFunc = { name: String, code: Integer[], relocs: XReloc[] }
type EncodedModule = { funcs: EncodedFunc[], entry: String }
type EncResult = { words: Integer[], sites: Integer[], syms: String[], strSites: Integer[], strIds: Integer[] }
// The linked code plus what the writer must patch: `extSites`/`extSyms` are the
// external-call BL placeholders and their C symbols; `strSites`/`strIds` are the
// string-address adrp/add placeholders and their string-pool ids.
type LinkedCode = { words: Integer[], entryWord: Integer, ok: Bool, missing: String, extSites: Integer[], extSyms: String[], strSites: Integer[], strIds: Integer[] }

interface InsnEncoder {
    mapper   archName() -> String
    producer encode(f: XFunc) -> EncodedFunc
}

// ── AArch64 instruction encoders (words built with +/*, verified vs a disassembler) ──
mapper aMovz(reg: Integer, imm: Integer, hw: Integer) -> Integer => 3531603968 + hw * 2097152 + imm * 32 + reg
mapper aMovk(reg: Integer, imm: Integer, hw: Integer) -> Integer => 4068474880 + hw * 2097152 + imm * 32 + reg
mapper aStrSp(rt: Integer, off: Integer)  -> Integer => 4177526784 + (off / 8) * 1024 + 31 * 32 + rt
mapper aLdrSp(rt: Integer, off: Integer)  -> Integer => 4181721088 + (off / 8) * 1024 + 31 * 32 + rt
// Double-precision FP load/store and arithmetic (d-registers), validated against
// the assembler.  ldr/str dRt,[sp,#off];  f<op> dRd,dRn,dRm.
mapper aStrD(rt: Integer, off: Integer)   -> Integer => 4244635648 + (off / 8) * 1024 + 31 * 32 + rt
mapper aLdrD(rt: Integer, off: Integer)   -> Integer => 4248829952 + (off / 8) * 1024 + 31 * 32 + rt
mapper aFadd(rd: Integer, rn: Integer, rm: Integer) -> Integer => 509618176 + rm * 65536 + rn * 32 + rd
mapper aFsub(rd: Integer, rn: Integer, rm: Integer) -> Integer => 509622272 + rm * 65536 + rn * 32 + rd
mapper aFmul(rd: Integer, rn: Integer, rm: Integer) -> Integer => 509609984 + rm * 65536 + rn * 32 + rd
mapper aFdiv(rd: Integer, rn: Integer, rm: Integer) -> Integer => 509614080 + rm * 65536 + rn * 32 + rd
mapper aAdd(rd: Integer, rn: Integer, rm: Integer) -> Integer => 2332033024 + rm * 65536 + rn * 32 + rd
mapper aSub(rd: Integer, rn: Integer, rm: Integer) -> Integer => 3405774848 + rm * 65536 + rn * 32 + rd
mapper aMul(rd: Integer, rn: Integer, rm: Integer) -> Integer => 2600468480 + rm * 65536 + 31 * 1024 + rn * 32 + rd
mapper aSdiv(rd: Integer, rn: Integer, rm: Integer) -> Integer => 2596277248 + rm * 65536 + rn * 32 + rd
mapper aMsub(rd: Integer, rn: Integer, rm: Integer, ra: Integer) -> Integer => 2600501248 + rm * 65536 + ra * 1024 + rn * 32 + rd
mapper aCmp(rn: Integer, rm: Integer) -> Integer => 3942645760 + rm * 65536 + rn * 32 + 31
mapper aCset(rd: Integer, inv: Integer) -> Integer => 2594113504 + inv * 4096 + rd
mapper aSubSp(imm: Integer) -> Integer => 3506438144 + imm * 1024 + 31 * 32 + 31
mapper aAddSp(imm: Integer) -> Integer => 2432696320 + imm * 1024 + 31 * 32 + 31
mapper aB(disp: Integer) -> Integer {
    let imm = disp
    if imm < 0 { imm = imm + 67108864 }      // 2^26
    return 335544320 + imm
}
mapper aBl(disp: Integer) -> Integer {
    let imm = disp
    if imm < 0 { imm = imm + 67108864 }
    return 2483027968 + imm                  // 0x94000000
}
mapper aCbz(rt: Integer, disp: Integer) -> Integer {
    let imm = disp
    if imm < 0 { imm = imm + 524288 }        // 2^19
    return 3019898880 + imm * 32 + rt
}
// adrp Xd, #imm21 (page-relative); ldr Xt,[Xn,#off]; br Xn — the import stub.
mapper aAdrp(rd: Integer, imm21: Integer) -> Integer {
    let lo = imm21 % 4
    let hi = (imm21 / 4) % 524288
    return 2415919104 + lo * 536870912 + hi * 32 + rd    // 0x90000000
}
mapper aLdr(rt: Integer, rn: Integer, off: Integer) -> Integer => 4181721088 + (off / 8) * 1024 + rn * 32 + rt
mapper aStr(rt: Integer, rn: Integer, off: Integer) -> Integer => 4177526784 + (off / 8) * 1024 + rn * 32 + rt
mapper aAddShift(rd: Integer, rn: Integer, rm: Integer, sh: Integer) -> Integer => 2332033024 + rm * 65536 + sh * 1024 + rn * 32 + rd  // ADD Xd,Xn,Xm,LSL #sh
mapper aAddImm(rd: Integer, rn: Integer, imm: Integer) -> Integer => 2432696320 + imm * 1024 + rn * 32 + rd   // 0x91000000

mapper invCond(op: String) -> Integer {
    if op == "eq"  { return 1 }
    if op == "ne"  { return 0 }
    if op == "slt" { return 10 }
    if op == "sle" { return 12 }
    if op == "sgt" { return 13 }
    return 11   // sge
}
predicate isCmp(op: String) {
    return op == "eq" or op == "ne" or op == "slt" or op == "sle" or op == "sgt" or op == "sge"
}

mapper matConst(ws: Integer[], reg: Integer, val: Integer) -> Integer[] {
    let out = appendInt(ws, aMovz(reg, val % 65536, 0))
    let v1 = val / 65536
    if v1 % 65536 != 0 { out = appendInt(out, aMovk(reg, v1 % 65536, 1)) }
    let v2 = v1 / 65536
    if v2 % 65536 != 0 { out = appendInt(out, aMovk(reg, v2 % 65536, 2)) }
    let v3 = v2 / 65536
    if v3 % 65536 != 0 { out = appendInt(out, aMovk(reg, v3 % 65536, 3)) }
    return out
}

// Emit one straight-line (non-branch, non-label, non-call) instruction. `locals`
// is the byte size of the local frame below the saved fp/lr.
mapper emitInsn(ws: Integer[], ins: XInsn, locals: Integer) -> Integer[] {
    if ins.op == "const" {
        let w1 = matConst(ws, 9, ins.a.imm)
        return appendInt(w1, aStrSp(9, ins.dst * 8))
    }
    if ins.op == "fconst" {                               // build the 64-bit double pattern in x9, store its bits
        let w0 = appendInt(ws, aMovz(9, ins.a.imm, 0))
        let w1 = w0
        if ins.b.imm != 0 { w1 = appendInt(w0, aMovk(9, ins.b.imm, 1)) }
        let w2 = w1
        if ins.tlabel != 0 { w2 = appendInt(w1, aMovk(9, ins.tlabel, 2)) }
        let w3 = w2
        if ins.flabel != 0 { w3 = appendInt(w2, aMovk(9, ins.flabel, 3)) }
        return appendInt(w3, aStrSp(9, ins.dst * 8))
    }
    if ins.op == "fadd" or ins.op == "fsub" or ins.op == "fmul" or ins.op == "fdiv" {
        let w1 = appendInt(ws, aLdrD(0, ins.a.id * 8))
        let w2 = appendInt(w1, aLdrD(1, ins.b.id * 8))
        let w3 = w2
        if ins.op == "fadd" { w3 = appendInt(w2, aFadd(0, 0, 1)) }
        if ins.op == "fsub" { w3 = appendInt(w2, aFsub(0, 0, 1)) }
        if ins.op == "fmul" { w3 = appendInt(w2, aFmul(0, 0, 1)) }
        if ins.op == "fdiv" { w3 = appendInt(w2, aFdiv(0, 0, 1)) }
        return appendInt(w3, aStrD(0, ins.dst * 8))
    }
    if ins.op == "copy" {
        let w1 = appendInt(ws, aLdrSp(9, ins.a.id * 8))
        return appendInt(w1, aStrSp(9, ins.dst * 8))
    }
    if ins.op == "astorec" {
        let w1 = appendInt(ws, aLdrSp(9, ins.a.id * 8))       // data pointer
        let w2 = appendInt(w1, aLdrSp(10, ins.b.id * 8))      // value
        return appendInt(w2, aStr(10, 9, ins.tlabel * 8))     // ptr[idx] = value
    }
    if ins.op == "aload" {
        let w1 = appendInt(ws, aLdrSp(9, ins.a.id * 8))       // data pointer
        let w2 = appendInt(w1, aLdrSp(10, ins.b.id * 8))      // index
        let w3 = appendInt(w2, aAddShift(9, 9, 10, 3))        // pointer + index*8
        let w4 = appendInt(w3, aLdr(11, 9, 0))                // load element
        return appendInt(w4, aStrSp(11, ins.dst * 8))
    }
    if ins.op == "aloadc" {
        let w1 = appendInt(ws, aLdrSp(9, ins.a.id * 8))       // object pointer
        let w2 = appendInt(w1, aLdr(11, 9, ins.tlabel * 8))   // load field at constant offset
        return appendInt(w2, aStrSp(11, ins.dst * 8))
    }
    if ins.op == "ret" {
        let w1 = ws
        if ins.typ == "f64" { w1 = appendInt(ws, aLdrD(0, ins.a.id * 8)) }            // Number: d0
        else { w1 = appendInt(ws, aLdrSp(0, ins.a.id * 8)) }
        let w1b = w1
        if ins.typ == "str" { w1b = appendInt(w1, aLdrSp(1, (ins.a.id + 1) * 8)) }   // String: also x1
        let w2 = w1b
        if locals > 0 { w2 = appendInt(w1b, aAddSp(locals)) }
        let w3 = appendInt(w2, 2831252477)                // ldp x29,x30,[sp],#16
        return appendInt(w3, 3596551104)                  // ret
    }
    if isCmp(ins.op) {
        let w1 = appendInt(ws, aLdrSp(9, ins.a.id * 8))
        let w2 = appendInt(w1, aLdrSp(10, ins.b.id * 8))
        let w3 = appendInt(w2, aCmp(9, 10))
        let w4 = appendInt(w3, aCset(9, invCond(ins.op)))
        return appendInt(w4, aStrSp(9, ins.dst * 8))
    }
    let w1 = appendInt(ws, aLdrSp(9, ins.a.id * 8))
    let w2 = appendInt(w1, aLdrSp(10, ins.b.id * 8))
    let w3 = w2
    if ins.op == "add" { w3 = appendInt(w2, aAdd(9, 9, 10)) }
    if ins.op == "sub" { w3 = appendInt(w2, aSub(9, 9, 10)) }
    if ins.op == "mul" { w3 = appendInt(w2, aMul(9, 9, 10)) }
    if ins.op == "sdiv" { w3 = appendInt(w2, aSdiv(9, 9, 10)) }
    if ins.op == "smod" {
        let wd = appendInt(w2, aSdiv(11, 9, 10))
        w3 = appendInt(wd, aMsub(9, 11, 10, 9))
    }
    return appendInt(w3, aStrSp(9, ins.dst * 8))
}

// Encode one function: prologue (save fp/lr, reserve locals, spill params), body
// with internal branches resolved, epilogue folded into each `ret`. Calls are
// emitted as BL placeholders and returned as (site, symbol) for the linker.
mapper encodeArm64(f: XFunc) -> EncResult {
    let locals = alignUp(f.nTemps * 8, 16)

    let maxLabel = 0 - 1
    for blk in f.blocks {
        for ins in blk.insns {
            if ins.op == "label" and ins.tlabel > maxLabel { maxLabel = ins.tlabel }
        }
    }
    let labelPos: Integer[] = []
    let li = 0
    while li <= maxLabel { labelPos = appendInt(labelPos, 0)  li = li + 1 }

    let ws: Integer[] = []
    ws = appendInt(ws, 2847898621)                        // stp x29,x30,[sp,#-16]!
    if locals > 0 { ws = appendInt(ws, aSubSp(locals)) }
    let np = stringArrLen(f.params)                                        // spill params to slots
    let preg = 0                                                           // integer arg registers x0..
    let dreg = 0                                                           // float arg registers d0..
    let pslot = 0
    let pi = 0
    while pi < np {
        let pw = intArrGet(f.paramKinds, pi)                               // slot width, or -1 for a Number (d-register)
        if pw < 0 {
            ws = appendInt(ws, aStrD(dreg, pslot * 8))
            dreg = dreg + 1  pslot = pslot + 1
        } else {
            let pj = 0
            while pj < pw { ws = appendInt(ws, aStrSp(preg + pj, (pslot + pj) * 8))  pj = pj + 1 }
            preg = preg + pw  pslot = pslot + pw
        }
        pi = pi + 1
    }

    let fWord: Integer[] = []
    let fTarget: Integer[] = []
    let fKind: Integer[] = []
    let fReg: Integer[] = []
    let cSites: Integer[] = []
    let cSyms: String[] = []
    let strSites: Integer[] = []
    let strIds: Integer[] = []

    for blk in f.blocks {
        for ins in blk.insns {
            if ins.op == "label" {
                labelPos = setInt(labelPos, ins.tlabel, intArrLen(ws))
            } else {
                if ins.op == "straddr" {
                    strSites = appendInt(strSites, intArrLen(ws))
                    strIds = appendInt(strIds, ins.a.imm)
                    ws = appendInt(ws, 0)                        // adrp placeholder
                    ws = appendInt(ws, 0)                        // add  placeholder
                    ws = appendInt(ws, aStrSp(9, ins.dst * 8))   // store pointer
                } else {
                if ins.op == "br" {
                    fWord = appendInt(fWord, intArrLen(ws))
                    fTarget = appendInt(fTarget, ins.tlabel)
                    fKind = appendInt(fKind, 0)
                    fReg = appendInt(fReg, 0)
                    ws = appendInt(ws, 0)
                } else {
                    if ins.op == "brz" {
                        ws = appendInt(ws, aLdrSp(9, ins.a.id * 8))
                        fWord = appendInt(fWord, intArrLen(ws))
                        fTarget = appendInt(fTarget, ins.tlabel)
                        fKind = appendInt(fKind, 1)
                        fReg = appendInt(fReg, 9)
                        ws = appendInt(ws, 0)
                    } else {
                        if ins.op == "call" {
                            let xr = 0                          // integer arg registers x0..
                            let dr = 0                          // float arg registers d0..
                            for a in ins.args {
                                if a.kind == "ftemp" {
                                    ws = appendInt(ws, aLdrD(dr, a.id * 8))
                                    dr = dr + 1
                                } else {
                                    ws = appendInt(ws, aLdrSp(xr, a.id * 8))
                                    xr = xr + 1
                                }
                            }
                            cSites = appendInt(cSites, intArrLen(ws))
                            cSyms = appendString(cSyms, ins.callee)
                            ws = appendInt(ws, 0)                       // bl placeholder
                            if ins.typ == "f64" { ws = appendInt(ws, aStrD(0, ins.dst * 8)) }          // Number result: d0
                            else { ws = appendInt(ws, aStrSp(0, ins.dst * 8)) }                        // store x0
                            if ins.typ == "str" { ws = appendInt(ws, aStrSp(1, (ins.dst + 1) * 8)) }   // string: also x1 (len)
                        } else {
                            ws = emitInsn(ws, ins, locals)
                        }
                    }
                }
                }
            }
        }
    }

    let k = 0
    while k < intArrLen(fWord) {
        let wi = intArrGet(fWord, k)
        let disp = intArrGet(labelPos, intArrGet(fTarget, k)) - wi
        if intArrGet(fKind, k) == 0 { ws = setInt(ws, wi, aB(disp)) }
        else { ws = setInt(ws, wi, aCbz(intArrGet(fReg, k), disp)) }
        k = k + 1
    }
    return EncResult { words: ws, sites: cSites, syms: cSyms, strSites: strSites, strIds: strIds }
}

mapper lookupOff(names: String[], offs: Integer[], name: String) -> Integer {
    let i = 0
    let n = stringArrLen(names)
    while i < n {
        if stringArrGet(names, i) == name { return intArrGet(offs, i) }
        i = i + 1
    }
    return 0 - 1
}

// Concatenate the encoded functions and patch each BL. Internal calls become a
// direct BL to the callee; a call to a declared extern is recorded as an
// external site (the writer routes it through an import stub); anything else is
// an unresolved-symbol error.
mapper linkModule(em: EncodedModule, externNames: String[]) -> LinkedCode {
    let allWords: Integer[] = []
    let fnames: String[] = []
    let foffs: Integer[] = []
    for f in em.funcs {
        fnames = appendString(fnames, f.name)
        foffs = appendInt(foffs, intArrLen(allWords))
        for w in f.code { allWords = appendInt(allWords, w) }
    }
    let extSites: Integer[] = []
    let extSyms: String[] = []
    let strSites: Integer[] = []
    let strIds: Integer[] = []
    let fi = 0
    for f in em.funcs {
        let base = intArrGet(foffs, fi)
        for r in f.relocs {
            let site = base + r.at
            if r.kind == "straddr" {
                strSites = appendInt(strSites, site)
                strIds = appendInt(strIds, r.addend)
            } else {
                let callee = lookupOff(fnames, foffs, r.sym)
                if callee >= 0 {
                    allWords = setInt(allWords, site, aBl(callee - site))
                } else {
                    if strIn(externNames, r.sym) {
                        extSites = appendInt(extSites, site)
                        extSyms = appendString(extSyms, "_" + r.sym)   // macOS C symbol
                    } else {
                        return LinkedCode { words: allWords, entryWord: 0, ok: false, missing: r.sym, extSites: extSites, extSyms: extSyms, strSites: strSites, strIds: strIds }
                    }
                }
            }
        }
        fi = fi + 1
    }
    let entryWord = lookupOff(fnames, foffs, em.entry)
    if entryWord < 0 { return LinkedCode { words: allWords, entryWord: 0, ok: false, missing: em.entry, extSites: extSites, extSyms: extSyms, strSites: strSites, strIds: strIds } }
    return LinkedCode { words: allWords, entryWord: entryWord, ok: true, missing: "", extSites: extSites, extSyms: extSyms, strSites: strSites, strIds: strIds }
}

// AArch64 (arm64) — the host architecture.
class Arm64Encoder implements InsnEncoder {
    deps {}
    mapper archName() -> String => "arm64"

    producer encode(f: XFunc) -> EncodedFunc {
        let er = encodeArm64(f)
        let relocs: XReloc[] = []
        let i = 0
        while i < intArrLen(er.sites) {
            relocs = appendXReloc(relocs, XReloc { at: intArrGet(er.sites, i), sym: stringArrGet(er.syms, i), kind: "call26", addend: 0 })
            i = i + 1
        }
        let j = 0
        while j < intArrLen(er.strSites) {
            relocs = appendXReloc(relocs, XReloc { at: intArrGet(er.strSites, j), sym: "", kind: "straddr", addend: intArrGet(er.strIds, j) })
            j = j + 1
        }
        return EncodedFunc { name: f.name, code: er.words, relocs: relocs }
    }
}
