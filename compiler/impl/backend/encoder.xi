// The ISA seam — XIR to machine code, one instruction set per implementation.
//
// An `InsnEncoder` takes a lowered `XFunc` and produces its machine code plus the
// relocations the linker must patch. It knows one architecture; adding x86-64
// later means a second implementation behind this interface, unchanged above.
//
// `code` is a list of 32-bit instruction words (AArch64 is fixed-width); the
// object writer appends each little-endian. Stage 2 grows this to real
// instruction selection and register allocation over full XIR; the milestone
// handles the entry shape `const N; ret` -> `movz w0, #N ; ret`.

// A patch site the linker resolves once the executable is laid out. Unused at
// the milestone (a `return <int>` needs no relocations); the field carries the
// design forward to Stage 1's runtime-call binding.
//   "call26" (BL imm26), "adrp21"/"pageoff12" (PC-relative pair), "abs64" (data)
type XReloc = { at: Integer, sym: String, kind: String, addend: Integer }

// One encoded function: symbol name, machine code as 32-bit words, relocations.
type EncodedFunc = { name: String, code: Integer[], relocs: XReloc[] }

// Every encoded function plus the entry symbol, ready for the object writer.
type EncodedModule = { funcs: EncodedFunc[], entry: String }

interface InsnEncoder {
    mapper   archName() -> String
    producer encode(f: XFunc) -> EncodedFunc
}

// AArch64 (arm64) — the host architecture.
//
// AArch64 has no bitwise operators in Xi, so instruction words are built with
// addition over non-overlapping fields (equivalent to OR here):
//   MOVZ Wd, #imm16 = 0x52800000 + (imm << 5) + Wd     (base 1384120320)
//   RET (to x30)    = 0xD65F03C0                         (3592355264)
class Arm64Encoder implements InsnEncoder {
    deps {}

    mapper archName() -> String => "arm64"

    producer encode(f: XFunc) -> EncodedFunc {
        // Milestone shape: a single `const N` feeding a `ret`. Materialise N in
        // w0 (the return/exit register under LC_MAIN) and return.
        let retval = 0
        for blk in f.blocks {
            for ins in blk.insns {
                if ins.op == "const" { retval = ins.a.imm }
            }
        }
        let ws: Integer[] = []
        ws = appendInt(ws, 1384120320 + retval * 32)   // movz w0, #retval (0x52800000)
        ws = appendInt(ws, 3596551104)                 // ret (0xD65F03C0)
        return EncodedFunc { name: f.name, code: ws, relocs: [] }
    }
}
