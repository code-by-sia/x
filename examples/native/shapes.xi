// Polymorphic dispatch over an injected list of implementors, native.
//
//   xc --backend native examples/native/shapes.xi
//   ./build/shapes         # prints: 21
//
// A `Shape[]` dependency collects one instance of every class that implements
// Shape. The loop calls `.area()` on each element; the call is dispatched at
// runtime to the element's concrete class (Square -> 9, Rect -> 12, sum 21).
// One binary holds two concrete types behind one interface, with no vtable and
// no cc/ld/codesign.
interface Shape {
    projector area() -> Integer
}

class Square implements Shape {
    deps {}
    state {}
    projector area() -> Integer { return 9 }
}

class Rect implements Shape {
    deps {}
    state {}
    projector area() -> Integer { return 12 }
}

interface Report {
    projector total() -> Integer
}

class Summer implements Report {
    deps { shapes: Shape[] }
    projector total() -> Integer {
        let sum = 0
        let i = 0
        while i < shapes.len {
            sum = sum + shapes.data[i].area()   // dispatched per element at runtime
            i = i + 1
        }
        return sum
    }
}

extern "C" { producer xstd_put_int(n: Integer) }

module App {
    id = "shapes"
    bind Report -> Summer

    entry main(args: String[]) -> Integer {
        let r = App.resolve(Report)   // Summer, with every Shape injected
        xstd_put_int(r.total())
        return 0
    }
}
