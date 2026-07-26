// Native-backend primitives — the thin C shims the encoder and object writer
// stand on (defined in xc_helpers.c, compiled into `xc`). Everything above this
// line is pure Xi layout logic; these provide only the mechanics Xi lacks: a
// growable byte buffer, SHA-256 for the code-signature slots, and a raw
// executable file write. Byte splitting (u32/u64, LE and BE) happens in C
// because Xi has no bitwise/shift operators.
extern "C" {
    mapper   appendInt(arr: Integer[], v: Integer) -> Integer[]
    mapper   intArrLen(arr: Integer[]) -> Integer
    mapper   intArrGet(arr: Integer[], i: Integer) -> Integer
    mapper   setInt(arr: Integer[], i: Integer, v: Integer) -> Integer[]
    // Heap append for the XIR types — an array that escapes its function (the
    // lowered module) must be heap-built, never an array literal.
    mapper   appendXInsn(arr: XInsn[], v: XInsn) -> XInsn[]
    mapper   appendXBlock(arr: XBlock[], v: XBlock) -> XBlock[]
    mapper   appendXFunc(arr: XFunc[], v: XFunc) -> XFunc[]
    mapper   appendXVal(arr: XVal[], v: XVal) -> XVal[]
    mapper   appendXReloc(arr: XReloc[], v: XReloc) -> XReloc[]
    mapper   appendEncodedFunc(arr: EncodedFunc[], v: EncodedFunc) -> EncodedFunc[]

    producer xcb_new() -> Integer                       // fresh buffer handle
    producer xcb_u8(h: Integer, v: Integer)             // append one byte
    producer xcb_u32(h: Integer, v: Integer)            // append u32 little-endian
    producer xcb_u64(h: Integer, v: Integer)            // append u64 little-endian
    producer xcb_u32be(h: Integer, v: Integer)          // append u32 big-endian
    producer xcb_u64be(h: Integer, v: Integer)          // append u64 big-endian
    producer xcb_zeros(h: Integer, n: Integer)          // append n zero bytes
    producer xcb_ascii(h: Integer, s: String)           // append a string's bytes (no NUL)
    producer xcb_len(h: Integer) -> Integer             // current length
    producer xcb_sha256_append(h: Integer, from: Integer, to: Integer)  // append SHA-256 of buf[from,to)
    producer xcb_ascii_unescape(h: Integer, s: String)                  // append s with \n \t ... resolved
    mapper   unescapedLen(s: String) -> Integer                         // byte length after unescaping
    producer strpool_reset()                                            // clear the string-constant pool
    mapper   strpool_add(s: String) -> Integer                          // add a raw literal, return its id
    mapper   strpool_len() -> Integer
    mapper   strpool_get(i: Integer) -> String
    producer fnsig_reset()                                              // clear the return-kind registry
    producer fnsig_add(name: String, retKind: Integer)                  // record a callee's return kind (0 int, 1 String, 2 Number)
    mapper   fnsig_ret_str(name: String) -> Integer                     // 1 if the callee returns a String
    mapper   fnsig_ret_num(name: String) -> Integer                     // 1 if the callee returns a Number
    producer ctype_reset()                                              // clear the compound-type registry
    producer ctype_add(name: String, isRef: Integer) -> Integer         // register a type (1=class, 2=interface), return index
    mapper   ctype_is_ref(ti: Integer) -> Integer                       // 1 = class (heap pointer), 2 = interface
    mapper   ctype_name(ti: Integer) -> String                          // the type's name
    producer ctype_add_field(ti: Integer, fname: String, fkind: Integer, fwidth: Integer)
    mapper   ctype_index(name: String) -> Integer                       // type index, or -1
    mapper   ctype_width(ti: Integer) -> Integer                        // total slot width
    producer ctype_set_width(ti: Integer, w: Integer)                   // override a type's slot width (sum: 1 tag + payload)
    producer var_reset()                                                // clear the sum-variant registry
    producer var_add(name: String, sumTi: Integer, tag: Integer, payTi: Integer)   // register a variant
    mapper   var_sum_of(name: String) -> Integer                        // the sum type index for a variant name, or -1
    mapper   var_tag_of(name: String) -> Integer                        // the variant's tag, or -1
    mapper   var_pay_of(name: String) -> Integer                        // the variant's payload compound index, or -1
    mapper   f64_chunk(text: String, i: Integer) -> Integer             // i-th 16-bit chunk of a float literal's IEEE-754 bits
    mapper   ctype_field_off(ti: Integer, fname: String) -> Integer     // field slot offset, or -1
    mapper   ctype_field_kind(ti: Integer, fname: String) -> Integer    // field kind (0/1/2)
    mapper   ctype_nfields(ti: Integer) -> Integer                      // number of fields
    mapper   ctype_field_kind_at(ti: Integer, f: Integer) -> Integer    // kind of field f
    mapper   ctype_field_off_at(ti: Integer, f: Integer) -> Integer     // slot offset of field f
    producer bind_reset()                                               // clear the interface->class binds
    producer bind_add(iface: String, cls: String)                       // record a bind
    mapper   bind_class(iface: String) -> String                        // the class bound to iface, or ""
    producer sing_reset()                                               // clear the singleton registry
    producer sing_mark(cls: String) -> Integer                          // mark a class singleton, return its index
    mapper   sing_index(cls: String) -> Integer                         // singleton index, or -1
    producer iface_impl_reset()                                         // clear the interface->implementors registry
    producer iface_impl_add(ii: Integer, ci: Integer)                   // record: class ci implements interface ii
    mapper   iface_nimpls(ii: Integer) -> Integer                       // how many classes implement interface ii
    mapper   iface_impl_at(ii: Integer, k: Integer) -> Integer          // class index of the k-th implementor, or -1
    producer xcb_write_exec(h: Integer, path: String) -> Integer        // write + chmod +x; 0 = ok
}

// Decimal value of an integer-literal token's text (non-negative).
mapper digitsToInt(s: String) -> Integer {
    let n = string_len(s)
    let v = 0
    let i = 0
    while i < n {
        let c = string_char_at(s, i)
        if c >= 48 and c <= 57 { v = v * 10 + (c - 48) }
        i = i + 1
    }
    return v
}

// Round x up to a multiple of a (a a power of two is not required).
mapper alignUp(x: Integer, a: Integer) -> Integer {
    let r = x % a
    if r == 0 { return x }
    return x + (a - r)
}
