// Boolean operators (`and`, `or`, `not`) and unary minus, compiled natively.
//
//   xc --backend native examples/native/logic.xi
//   ./build/logic ; echo $?      # -> 42
//
// `and` / `or` short-circuit exactly like the C backend: the guard below reads
// s only while the length check holds, so `charAt` never runs past the end.
// `not` is `(x == 0)` and unary `-x` is `0 - x`; both lower to a few arm64
// instructions with no cc, ld, or codesign. Drop `--backend native` to build
// the same program through the default C backend.
extern "C" { mapper xstd_str_char_at(s: String, i: Integer) -> Integer }

// First char of s, but only when i is in range — the `and` guards the read.
mapper charOr(s: String, i: Integer, dflt: Integer) -> Integer {
    if i >= 0 and i < string_len(s) {
        return xstd_str_char_at(s, i)
    }
    return dflt
}

module Logic {
    id = "logic"

    entry main(args: String[]) -> Integer {
        let ok = true
        let bad = false
        let n = 20

        // and / or / not over Bool locals and comparisons.
        if ok and not bad and (n > 10 or n < 0) {
            n = n + 2                       // 22
        }

        // Short-circuit: "hi" has length 2, so charAt(9) is never evaluated.
        let safe = charOr("hi", 9, 20)      // 20 (out of range -> default)
        let h    = charOr("hi", 0, 0)       // 104 = 'h'

        // Unary minus and a not that stays false.
        let m = -8 + 8                      // 0
        if not (h == 104) { m = 999 }       // skipped

        return n + safe + m                 // 22 + 20 + 0 = 42
    }
}
