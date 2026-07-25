// Singleton dependency injection, compiled to native code.
//
//   xc --backend native examples/native/singleton.xi
//   ./build/singleton         # prints: 3
//
// `as singleton` shares one instance across every resolve: the first request
// constructs and caches it, later requests reuse it, so state accumulates.
// (Transient binding would print 1.) No cc, ld, or codesign.
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

module App {
    id = "singleton"
    bind Counter -> Ctr as singleton

    entry main(args: String[]) -> Integer {
        let a = App.resolve(Counter)
        a.inc()
        a.inc()
        let b = App.resolve(Counter)   // the same instance as a
        b.inc()
        xstd_put_int(b.get())
        return 0
    }
}
