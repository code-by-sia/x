// The ISA seam — XIR to machine code, one instruction set per implementation.
//
// `code` is a list of 32-bit instruction words (AArch64 is fixed-width), the
// object writer appends each little-endian. Register allocation is spill
// everything: each XIR slot has an 8-byte stack home, every instruction loads
// its operands into x9/x10, computes, and stores the result back. Branches are
// resolved in a second pass once every label's word offset is known.

type XReloc = { at: Integer, sym: String, kind: String, addend: Integer }
type EncodedFunc = { name: String, code: Integer[], relocs: XReloc[] }
type EncodedModule = { funcs: EncodedFunc[], entry: String }

interface InsnEncoder {
    mapper   archName() -> String
    producer encode(f: XFunc) -> EncodedFunc
}

// ── AArch64 instruction encoders (words built with +/*, verified vs a disassembler) ──
mapper aMovz(reg: Integer, imm: Integer, hw: Integer) -> Integer => 3531603968 + hw * 2097152 + imm * 32 + reg
mapper aMovk(reg: Integer, imm: Integer, hw: Integer) -> Integer => 4068474880 + hw * 2097152 + imm * 32 + reg
mapper aStrSp(rt: Integer, off: Integer)  -> Integer => 4177526784 + (off / 8) * 1024 + 31 * 32 + rt
mapper aLdrSp(rt: Integer, off: Integer)  -> Integer => 4181721088 + (off / 8) * 1024 + 31 * 32 + rt
mapper aAdd(rd: Integer, rn: Integer, rm: Integer) -> Integer => 2332033024 + rm * 65536 + rn * 32 + rd
mapper aSub(rd: Integer, rn: Integer, rm: Integer) -> Integer => 3405774848 + rm * 65536 + rn * 32 + rd
mapper aMul(rd: Integer, rn: Integer, rm: Integer) -> Integer => 2600468480 + rm * 65536 + 31 * 1024 + rn * 32 + rd
mapper aSdiv(rd: Integer, rn: Integer, rm: Integer) -> Integer => 2596277248 + rm * 65536 + rn * 32 + rd
mapper aMsub(rd: Integer, rn: Integer, rm: Integer, ra: Integer) -> Integer => 2600501248 + rm * 65536 + ra * 1024 + rn * 32 + rd
mapper aCmp(rn: Integer, rm: Integer) -> Integer => 3942645760 + rm * 65536 + rn * 32 + 31   // SUBS XZR,Xn,Xm
mapper aCset(rd: Integer, inv: Integer) -> Integer => 2594113504 + inv * 4096 + rd            // CSINC Xd,XZR,XZR,inv
mapper aSubSp(imm: Integer) -> Integer => 3506438144 + imm * 1024 + 31 * 32 + 31
mapper aAddSp(imm: Integer) -> Integer => 2432696320 + imm * 1024 + 31 * 32 + 31
mapper aB(disp: Integer) -> Integer {
    let imm = disp
    if imm < 0 { imm = imm + 67108864 }     // 2^26, 26-bit two's complement
    return 335544320 + imm                  // 0x14000000
}
mapper aCbz(rt: Integer, disp: Integer) -> Integer {
    let imm = disp
    if imm < 0 { imm = imm + 524288 }       // 2^19
    return 3019898880 + imm * 32 + rt       // 0xB4000000
}

// CSET uses the inverted condition. eq->NE(1) ne->EQ(0) slt->GE(10) sle->GT(12)
// sgt->LE(13) sge->LT(11).
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

// Materialise a non-negative constant into `reg`: movz low 16 bits, movk higher chunks.
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

// Emit one straight-line (non-branch, non-label) instruction.
mapper emitInsn(ws: Integer[], ins: XInsn, frame: Integer) -> Integer[] {
    if ins.op == "const" {
        let w1 = matConst(ws, 9, ins.a.imm)
        return appendInt(w1, aStrSp(9, ins.dst * 8))
    }
    if ins.op == "copy" {
        let w1 = appendInt(ws, aLdrSp(9, ins.a.id * 8))
        return appendInt(w1, aStrSp(9, ins.dst * 8))
    }
    if ins.op == "ret" {
        let w1 = appendInt(ws, aLdrSp(0, ins.a.id * 8))
        let w2 = w1
        if frame > 0 { w2 = appendInt(w1, aAddSp(frame)) }
        return appendInt(w2, 3596551104)                  // ret
    }
    if isCmp(ins.op) {
        let w1 = appendInt(ws, aLdrSp(9, ins.a.id * 8))
        let w2 = appendInt(w1, aLdrSp(10, ins.b.id * 8))
        let w3 = appendInt(w2, aCmp(9, 10))
        let w4 = appendInt(w3, aCset(9, invCond(ins.op)))
        return appendInt(w4, aStrSp(9, ins.dst * 8))
    }
    // add / sub / mul
    let w1 = appendInt(ws, aLdrSp(9, ins.a.id * 8))
    let w2 = appendInt(w1, aLdrSp(10, ins.b.id * 8))
    let w3 = w2
    if ins.op == "add" { w3 = appendInt(w2, aAdd(9, 9, 10)) }
    if ins.op == "sub" { w3 = appendInt(w2, aSub(9, 9, 10)) }
    if ins.op == "mul" { w3 = appendInt(w2, aMul(9, 9, 10)) }
    if ins.op == "sdiv" { w3 = appendInt(w2, aSdiv(9, 9, 10)) }
    if ins.op == "smod" {
        let wd = appendInt(w2, aSdiv(11, 9, 10))       // x11 = x9 / x10
        w3 = appendInt(wd, aMsub(9, 11, 10, 9))        // x9 = x9 - x11 * x10
    }
    return appendInt(w3, aStrSp(9, ins.dst * 8))
}

// Two-pass: emit words (branches as placeholders, labels record their offset),
// then patch each branch with the resolved displacement.
mapper encodeArm64(f: XFunc) -> Integer[] {
    let frame = alignUp(f.nTemps * 8, 16)

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
    if frame > 0 { ws = appendInt(ws, aSubSp(frame)) }
    let fWord: Integer[] = []      // word index of each branch placeholder
    let fTarget: Integer[] = []    // its target label
    let fKind: Integer[] = []      // 0 = b, 1 = cbz
    let fReg: Integer[] = []       // cbz test register

    for blk in f.blocks {
        for ins in blk.insns {
            if ins.op == "label" {
                labelPos = setInt(labelPos, ins.tlabel, intArrLen(ws))
            } else {
                if ins.op == "br" {
                    fWord = appendInt(fWord, intArrLen(ws))
                    fTarget = appendInt(fTarget, ins.tlabel)
                    fKind = appendInt(fKind, 0)
                    fReg = appendInt(fReg, 0)
                    ws = appendInt(ws, 0)
                } else {
                    if ins.op == "brz" {
                        ws = appendInt(ws, aLdrSp(9, ins.a.id * 8))   // load condition
                        fWord = appendInt(fWord, intArrLen(ws))       // cbz placeholder follows
                        fTarget = appendInt(fTarget, ins.tlabel)
                        fKind = appendInt(fKind, 1)
                        fReg = appendInt(fReg, 9)
                        ws = appendInt(ws, 0)
                    } else {
                        ws = emitInsn(ws, ins, frame)
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
    return ws
}

// AArch64 (arm64) — the host architecture.
class Arm64Encoder implements InsnEncoder {
    deps {}
    mapper archName() -> String => "arm64"
    producer encode(f: XFunc) -> EncodedFunc =>
        EncodedFunc { name: f.name, code: encodeArm64(f), relocs: [] }
}
