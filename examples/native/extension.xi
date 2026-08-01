// String extension methods, compiled to native code.
//
//   xc --backend native examples/native/extension.xi
//   ./build/extension      # prints: 1, 0, h
//
// An extension method (mapper/predicate/... on a built-in type) receives the
// value as `this` and is called with method syntax. `s.startsWith2(p)` compiles
// to a call passing the receiver as the first argument; `predicate` returns a
// Bool (a one-slot Integer). This is the same pattern the Xi compiler's own
// String helpers use. No cc/ld/codesign.
predicate String.startsWith2(prefix: String) {
    let pl = string_len(prefix)
    if string_len(this) < pl { return false }
    return string_slice(this, 0, pl) == prefix
}

mapper String.firstChar() -> String {
    return string_slice(this, 0, 1)
}

extern "C" {
    producer xstd_put_int(n: Integer)
    producer xstd_put_str(s: String)
}

module M {
    id = "extension"
    entry main(args: String[]) -> Integer {
        let s = "hello world"
        if s.startsWith2("hello") { xstd_put_int(1) } else { xstd_put_int(0) }   // 1
        if s.startsWith2("world") { xstd_put_int(1) } else { xstd_put_int(0) }   // 0
        xstd_put_str(s.firstChar())                                             // h
        xstd_put_str("\n")
        return 0
    }
}
