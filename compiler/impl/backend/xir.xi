// XIR — the Xi Intermediate Representation, the seam between the language and a
// native code backend.
//
// The C backend walks tokens straight to C text: the C compiler owns everything
// below the source level, so there is nothing in between. A native backend has
// no such partner — it must own instruction selection, register allocation and
// encoding itself, and that is unmanageable directly off the token stream. XIR
// is the small, explicit form those passes consume.
//
// Shape: a module of functions, each a list of basic blocks, each a linear list
// of three-address instructions over integer-numbered temporaries. It is
// deliberately **not** SSA — values that live across blocks go through an
// `alloca` slot with `load`/`store`, which naive codegen lowers correctly with
// no phi handling. An SSA form and a real optimizer can come later; correctness
// first.
//
// Machine types are coarse on purpose: everything the language has today lowers
// to one of these.
//   "i64"   integers, booleans, and pointers (String/struct handles included)
//   "f64"   floating point
//   "ptr"   an address (an i64 by another name, kept distinct for readability)
//   "void"  no result

// An instruction operand.
//   "imm"   a literal integer, in `imm`
//   "temp"  the result of an earlier instruction, by `id`
//   "arg"   an incoming function argument, by `id` (its index)
//   "sym"   a symbol reference (a function or global), by `sym`
//   "none"  absent (e.g. the operand of a `void` return)
type XVal = {
    kind: String,
    imm:  Integer,
    id:   Integer,
    sym:  String
}

mapper ximm(n: Integer)   -> XVal => XVal { kind: "imm",  imm: n, id: 0,  sym: "" }
mapper xtemp(id: Integer) -> XVal => XVal { kind: "temp", imm: 0, id: id, sym: "" }
mapper xarg(i: Integer)   -> XVal => XVal { kind: "arg",  imm: 0, id: i,  sym: "" }
mapper xsym(s: String)    -> XVal => XVal { kind: "sym",  imm: 0, id: 0,  sym: s  }
mapper xnone()            -> XVal => XVal { kind: "none", imm: 0, id: 0,  sym: "" }

// One three-address instruction. `dst` is the result temp id, or -1 when the
// instruction produces no value (store / ret / br / brcond, or a void call).
//
// Opcodes:
//   const                       dst = imm(a)
//   add sub mul sdiv smod       dst = a op b
//   and or  xor shl ashr lshr   dst = a op b   (bitwise / shifts)
//   eq ne slt sle sgt sge       dst = (a cmp b) ? 1 : 0
//   load                        dst = *a          (width from `typ`)
//   store                       *a = b
//   alloca                      dst = &slot       (a.imm bytes on the frame)
//   call                        dst = callee(args...)   (dst = -1 if void)
//   ret                         return a          (a = none() for void)
//   br                          goto tlabel
//   brcond                      if a then goto tlabel else goto flabel
type XInsn = {
    op:     String,
    typ:    String,
    dst:    Integer,
    a:      XVal,
    b:      XVal,
    args:   XVal[],
    callee: String,
    tlabel: Integer,
    flabel: Integer
}

// A basic block: a straight-line run of instructions ending in a terminator
// (ret / br / brcond). `id` is the block's index within its function.
type XBlock = { id: Integer, insns: XInsn[] }

// A function. `name` is the final symbol (already mangled, e.g. the C name the
// runtime and other Xi code will call). `params`/`ret` are machine types.
// `nTemps` is how many temp ids were handed out; `frame` is the stack-slot byte
// count reserved for allocas (filled in during lowering).
type XFunc = {
    name:       String,
    params:     String[],
    paramKinds: Integer[],   // per param: 1 = String (two registers/slots), 0 = Integer
    ret:        String,
    blocks:     XBlock[],
    nTemps:     Integer,
    frame:      Integer
}

// A whole compilation unit. `externs` are symbols referenced but defined
// elsewhere (the prebuilt runtime object supplies them). `entry` is the symbol
// the loader jumps to.
type XModule = {
    funcs:   XFunc[],
    externs: String[],
    entry:   String
}

mapper emptyXModule() -> XModule => XModule { funcs: [], externs: [], entry: "" }

// ── instruction builders (keep lowering readable) ──────────────────
mapper xi_const(dst: Integer, n: Integer) -> XInsn =>
    XInsn { op: "const", typ: "i64", dst: dst, a: ximm(n), b: xnone(), args: [], callee: "", tlabel: 0, flabel: 0 }

mapper xi_bin(op: String, dst: Integer, a: XVal, b: XVal) -> XInsn =>
    XInsn { op: op, typ: "i64", dst: dst, a: a, b: b, args: [], callee: "", tlabel: 0, flabel: 0 }

mapper xi_ret(a: XVal) -> XInsn =>
    XInsn { op: "ret", typ: "void", dst: 0 - 1, a: a, b: xnone(), args: [], callee: "", tlabel: 0, flabel: 0 }

// A return whose value is a String is marked so the epilogue loads x0 and x1.
mapper xi_ret2(a: XVal, isStr: Bool) -> XInsn {
    let t = "i64"
    if isStr { t = "str" }
    return XInsn { op: "ret", typ: t, dst: 0 - 1, a: a, b: xnone(), args: [], callee: "", tlabel: 0, flabel: 0 }
}

mapper xi_call(dst: Integer, callee: String, args: XVal[], typ: String) -> XInsn =>
    XInsn { op: "call", typ: typ, dst: dst, a: xnone(), b: xnone(), args: args, callee: callee, tlabel: 0, flabel: 0 }

mapper xi_br(target: Integer) -> XInsn =>
    XInsn { op: "br", typ: "void", dst: 0 - 1, a: xnone(), b: xnone(), args: [], callee: "", tlabel: target, flabel: 0 }

mapper xi_brcond(a: XVal, t: Integer, f: Integer) -> XInsn =>
    XInsn { op: "brcond", typ: "void", dst: 0 - 1, a: a, b: xnone(), args: [], callee: "", tlabel: t, flabel: f }

// mem[dst] = mem[src] — a slot-to-slot copy (used to write a local's slot).
mapper xi_copy(dst: Integer, src: Integer) -> XInsn =>
    XInsn { op: "copy", typ: "i64", dst: dst, a: xtemp(src), b: xnone(), args: [], callee: "", tlabel: 0, flabel: 0 }

// mem[dst] = (mem[a] <cmp> mem[b]) ? 1 : 0 — `op` is eq/ne/slt/sle/sgt/sge.
mapper xi_cmp(op: String, dst: Integer, a: Integer, b: Integer) -> XInsn =>
    XInsn { op: op, typ: "i64", dst: dst, a: xtemp(a), b: xtemp(b), args: [], callee: "", tlabel: 0, flabel: 0 }

// A branch target marker (emits no code; records its word offset).
mapper xi_label(id: Integer) -> XInsn =>
    XInsn { op: "label", typ: "void", dst: 0 - 1, a: xnone(), b: xnone(), args: [], callee: "", tlabel: id, flabel: 0 }

// Branch to `target` label if mem[a] == 0.
mapper xi_brz(a: Integer, target: Integer) -> XInsn =>
    XInsn { op: "brz", typ: "void", dst: 0 - 1, a: xtemp(a), b: xnone(), args: [], callee: "", tlabel: target, flabel: 0 }

// mem[dst] = address of string constant `strid` (resolved to the __TEXT pool).
mapper xi_straddr(dst: Integer, strid: Integer) -> XInsn =>
    XInsn { op: "straddr", typ: "ptr", dst: dst, a: ximm(strid), b: xnone(), args: [], callee: "", tlabel: 0, flabel: 0 }
