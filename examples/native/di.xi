// Dependency injection, compiled to native code.
//
//   xc --backend native examples/native/di.xi
//   ./build/di                # prints: 42
//
// A class's dependencies are stored in its instance and constructed
// recursively when it is resolved. A method reaches an injected dependency by
// its bare name and calls through it. No cc, ld, or codesign.
interface Adder {
    mapper add(a: Integer, b: Integer) -> Integer
}

class RealAdder implements Adder {
    deps {}
    mapper add(a: Integer, b: Integer) -> Integer => a + b
}

interface Calc {
    mapper compute() -> Integer
}

class RealCalc implements Calc {
    deps { adder: Adder }
    mapper compute() -> Integer => adder.add(20, 22)
}

extern "C" { producer xstd_put_int(n: Integer) }

module App {
    id = "di"
    bind Adder -> RealAdder
    bind Calc  -> RealCalc

    entry main(args: String[]) -> Integer {
        let c = App.resolve(Calc)
        xstd_put_int(c.compute())
        return 0
    }
}
