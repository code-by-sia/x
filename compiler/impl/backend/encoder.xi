// The ISA seam — XIR to machine code, one instruction set per implementation.
//
// An `InsnEncoder` takes a lowered `XFunc` and produces its machine code plus the
// relocations the linker must patch. It knows one architecture; adding x86-64
// later means a second implementation behind this interface, unchanged above.
//
// `code` is a list of 32-bit instruction words (AArch64 is fixed-width); the
// object writer appends each little-endian.
//
// Register allocation is the simplest correct scheme: spill everything. Each XIR
// temp gets an 8-byte stack slot at offset id*8; every instruction loads its
// operands into scratch registers, computes, and stores the result back. No
// liveness, no allocator — correctness first; a real allocator is a later step.
// x9/x10 are the scratch registers; x0 carries the function result.

type XReloc = { at: Integer, sym: String, kind: String, addend: Integer }
type EncodedFunc = { name: String, code: Integer[], relocs: XReloc[] }
type EncodedModule = { funcs: EncodedFunc[], entry: String }

interface InsnEncoder {
    mapper   archName() -> String
    producer encode(f: XFunc) -> EncodedFunc
}

// ── AArch64 instruction encoders ───────────────────────────────────
// Words are composed with + and * (Xi has no bitwise ops); the fields never
// overlap, so addition is OR. Field multipliers: <<5 = *32, <<10 = *1024,
// <<16 = *65536, <<21 = *2097152. Verified against a disassembler.
mapper aMovz(reg: Integer, imm: Integer, hw: Integer) -> Integer => 3531603968 + hw * 2097152 + imm * 32 + reg
mapper aMovk(reg: Integer, imm: Integer, hw: Integer) -> Integer => 4068474880 + hw * 2097152 + imm * 32 + reg
mapper aStrSp(rt: Integer, off: Integer)  -> Integer => 4177526784 + (off / 8) * 1024 + 31 * 32 + rt
mapper aLdrSp(rt: Integer, off: Integer)  -> Integer => 4181721088 + (off / 8) * 1024 + 31 * 32 + rt
mapper aAdd(rd: Integer, rn: Integer, rm: Integer) -> Integer => 2332033024 + rm * 65536 + rn * 32 + rd
mapper aSub(rd: Integer, rn: Integer, rm: Integer) -> Integer => 3405774848 + rm * 65536 + rn * 32 + rd
mapper aMul(rd: Integer, rn: Integer, rm: Integer) -> Integer => 2600468480 + rm * 65536 + 31 * 1024 + rn * 32 + rd
mapper aSubSp(imm: Integer) -> Integer => 3506438144 + imm * 1024 + 31 * 32 + 31
mapper aAddSp(imm: Integer) -> Integer => 2432696320 + imm * 1024 + 31 * 32 + 31

// Materialise a non-negative constant into `reg`: movz the low 16 bits, then
// movk each higher non-zero 16-bit chunk. (Literals are always non-negative;
// subtraction that yields a negative value is computed at run time.)
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

// Emit one XIR instruction under the spill-everything model.
mapper emitInsn(ws: Integer[], ins: XInsn, frame: Integer) -> Integer[] {
    if ins.op == "const" {
        let w1 = matConst(ws, 9, ins.a.imm)
        return appendInt(w1, aStrSp(9, ins.dst * 8))
    }
    if ins.op == "ret" {
        let w1 = appendInt(ws, aLdrSp(0, ins.a.id * 8))   // x0 = slot(a)
        let w2 = w1
        if frame > 0 { w2 = appendInt(w1, aAddSp(frame)) }
        return appendInt(w2, 3596551104)                  // ret
    }
    // binary op: load both operands, compute in x9, store to the result slot
    let w1 = appendInt(ws, aLdrSp(9, ins.a.id * 8))
    let w2 = appendInt(w1, aLdrSp(10, ins.b.id * 8))
    let w3 = w2
    if ins.op == "add" { w3 = appendInt(w2, aAdd(9, 9, 10)) }
    if ins.op == "sub" { w3 = appendInt(w2, aSub(9, 9, 10)) }
    if ins.op == "mul" { w3 = appendInt(w2, aMul(9, 9, 10)) }
    return appendInt(w3, aStrSp(9, ins.dst * 8))
}

// AArch64 (arm64) — the host architecture.
class Arm64Encoder implements InsnEncoder {
    deps {}

    mapper archName() -> String => "arm64"

    producer encode(f: XFunc) -> EncodedFunc {
        let frame = alignUp(f.nTemps * 8, 16)
        let ws: Integer[] = []
        if frame > 0 { ws = appendInt(ws, aSubSp(frame)) }   // prologue
        for blk in f.blocks {
            for ins in blk.insns {
                ws = emitInsn(ws, ins, frame)
            }
        }
        return EncodedFunc { name: f.name, code: ws, relocs: [] }
    }
}
