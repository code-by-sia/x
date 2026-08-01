// Sum types and match, compiled to native code.
//
//   xc --backend native examples/native/sumtype.xi
//   ./build/sumtype        # prints: 7, 42, 0
//
// A value of a sum type is one of several variants, each carrying its own
// fields. It is laid out inline as a tag word followed by the payload; `match`
// reads the tag, branches to the arm, and binds the payload. No cc/ld/codesign.
type Expr =
    | Lit { v: Integer }
    | Add { a: Integer, b: Integer }
    | Zero

mapper eval(e: Expr) -> Integer {
    match e {
        Lit l -> { return l.v }
        Add p -> { return p.a + p.b }
        Zero  -> { return 0 }
    }
    return 0 - 1
}

extern "C" { producer xstd_put_int(n: Integer) }

module M {
    id = "sumtype"
    entry main(args: String[]) -> Integer {
        xstd_put_int(eval(Lit { v: 7 }))
        xstd_put_int(eval(Add { a: 20, b: 22 }))
        xstd_put_int(eval(Zero))
        return 0
    }
}
