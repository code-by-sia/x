// Generic interfaces, compiled to native code.
//
//   xc --backend native examples/native/generic.xi
//   ./build/generic        # prints: 42, then hello
//
// A parametric interface `Box<T>` is monomorphized: `Box<Integer>` and
// `Box<String>` become two distinct concrete interfaces, each with its own
// implementor and its own return type. Each dependency auto-wires to the single
// class implementing its instantiation, and the method dispatches to it. No
// cc/ld/codesign.
interface Box<T> {
    mapper get() -> T
}

class IntBox implements Box<Integer> {
    deps {}
    mapper get() -> Integer => 42
}

class StrBox implements Box<String> {
    deps {}
    mapper get() -> String => "hello"
}

interface Runner { mapper run() -> Integer }
class IntRunner implements Runner {
    deps { b: Box<Integer> }             // auto-wired to IntBox
    mapper run() -> Integer => b.get()
}

interface Teller { mapper tell() -> String }
class StrTeller implements Teller {
    deps { b: Box<String> }              // a distinct instantiation, wired to StrBox
    mapper tell() -> String => b.get()
}

extern "C" {
    producer xstd_put_int(n: Integer)
    producer xstd_put_str(s: String)
}

module App {
    id = "generic"
    bind Runner -> IntRunner
    bind Teller -> StrTeller

    entry main(args: String[]) -> Integer {
        let r = App.resolve(Runner)
        let t = App.resolve(Teller)
        xstd_put_int(r.run())     // Box<Integer> -> 42
        xstd_put_str(t.tell())    // Box<String>  -> hello
        return 0
    }
}
