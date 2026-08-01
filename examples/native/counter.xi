// Interfaces, classes, state, and dependency resolution, compiled to native code.
//
//   xc --backend native examples/native/counter.xi
//   ./build/counter           # prints: 3
//
// A class instance is a heap pointer; its state lives on the heap (zeroed on
// allocation), and `this.field` reads and writes it. With a single bind per
// interface the concrete type is known statically, so M.resolve(I) allocates the
// bound class and method calls dispatch directly (no vtable). No cc, ld, or
// codesign.
interface Counter {
    consumer inc()
    projector get() -> Integer
}

class Ctr implements Counter {
    deps {}
    state { n: Integer = 0 }

    consumer inc() { this.n = this.n + 1 }
    projector get() -> Integer => this.n
}

extern "C" { producer xstd_put_int(n: Integer) }

module Counting {
    id = "counter"
    bind Counter -> Ctr

    entry main(args: String[]) -> Integer {
        let c = Counting.resolve(Counter)
        c.inc()
        c.inc()
        c.inc()
        xstd_put_int(c.get())
        return 0
    }
}
