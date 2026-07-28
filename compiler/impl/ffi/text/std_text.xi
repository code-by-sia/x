// StdText — the default Text: wraps the string/character FFI. The externs are
// declared here, at the top of their implementation; the class methods use them
// (method names differ from the externs, so a bare call hits the free extern).
//
// Only the irreducible string primitives stay in C (raw byte access, allocation,
// integer formatting). The character predicates and `findChar` are pure logic
// over a char code / the primitives, so they are Xi.
extern "C" {
    mapper string_char_at(s: String, i: Integer) -> Integer
    mapper string_len(s: String) -> Integer
    mapper string_slice(s: String, from: Integer, to: Integer) -> String
    mapper int_to_string(n: Integer) -> String
}

// ASCII character classes (the C locale the compiler runs in resolves the libc
// versions to exactly these ranges).
predicate is_digit(c: Integer) -> Bool { return c >= 48 and c <= 57 }                               // 0-9
predicate is_alpha(c: Integer) -> Bool { return (c >= 65 and c <= 90) or (c >= 97 and c <= 122) }   // A-Z a-z
predicate is_alnum(c: Integer) -> Bool { return is_alpha(c) or is_digit(c) }
predicate is_space_c(c: Integer) -> Bool { return c == 32 or (c >= 9 and c <= 13) }                 // space, \t \n \v \f \r

// First index of char code `c` in `s`, or `s`'s length when absent.
mapper findChar(s: String, c: Integer) -> Integer {
    let n = string_len(s)
    let i = 0
    while i < n {
        if string_char_at(s, i) == c { return i }
        i = i + 1
    }
    return n
}

class StdText implements Text {
    deps {}
    mapper    len(s: String) -> Integer { return string_len(s) }
    mapper    charAt(s: String, i: Integer) -> Integer { return string_char_at(s, i) }
    mapper    slice(s: String, from: Integer, to: Integer) -> String { return string_slice(s, from, to) }
    mapper    indexOf(s: String, c: Integer) -> Integer { return findChar(s, c) }
    mapper    fromInt(n: Integer) -> String { return int_to_string(n) }
    predicate isAlpha(c: Integer) -> Bool { return is_alpha(c) }
    predicate isDigit(c: Integer) -> Bool { return is_digit(c) }
    predicate isAlnum(c: Integer) -> Bool { return is_alnum(c) }
    predicate isSpace(c: Integer) -> Bool { return is_space_c(c) }
}
