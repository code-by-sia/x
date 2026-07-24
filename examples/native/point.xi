// Compound types (structs), compiled to native code.
//
//   xc --backend native examples/native/point.xi
//   ./build/point             # prints: 3 4 7
//
// A compound is a value type laid out inline across one stack slot per field
// (Integer 1, String 2, array 3). Construction fills the slots; `p.field` reads
// one at its fixed offset. No cc, ld, or codesign.
type Point = { x: Integer, y: Integer }

extern "C" { producer xstd_put_int(n: Integer)  producer xstd_put_str(s: String) }

module PointDemo {
    id = "point"

    entry main(args: String[]) -> Integer {
        let p = Point { x: 3, y: 4 }
        xstd_put_int(p.x)
        xstd_put_str(" ")
        xstd_put_int(p.y)
        xstd_put_str(" ")
        xstd_put_int(p.x + p.y)
        xstd_put_str("\n")
        return 0
    }
}
