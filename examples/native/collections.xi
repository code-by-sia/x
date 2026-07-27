// Arrays whose elements span more than one slot, compiled to native code.
//
//   xc --backend native examples/native/collections.xi
//   ./build/collections    # prints: 6, 10
//
// A String element is a pointer plus a length (two slots); a compound element is
// laid out inline (its field width). The array's { data, len, cap } fat pointer
// stores each element at index * elementWidth, and `for x in xs` binds the loop
// variable to a full element. No cc/ld/codesign.
type Point = { x: Integer, y: Integer }

mapper totalLength(words: String[]) -> Integer {
    let total = 0
    for w in words { total = total + string_len(w) }
    return total
}

extern "C" { producer xstd_put_int(n: Integer) }

module M {
    id = "collections"
    entry main(args: String[]) -> Integer {
        xstd_put_int(totalLength(["a", "bb", "ccc"]))       // 1 + 2 + 3 = 6

        let points = [ Point { x: 1, y: 2 }, Point { x: 3, y: 4 } ]
        let sum = 0
        for p in points { sum = sum + p.x + p.y }           // 1+2+3+4
        xstd_put_int(sum)                                    // 10
        return 0
    }
}
