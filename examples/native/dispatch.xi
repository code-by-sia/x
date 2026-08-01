// Polymorphic dispatch, compiled to native code.
//
//   xc --backend native examples/native/dispatch.xi
//   ./build/dispatch        # prints: 7
//
// `speak` takes a Speaker interface value and calls `s.level()`. Which method
// runs is decided at runtime from the object itself, not at compile time: each
// instance carries a class-index header, and the call is a compare-and-branch
// over the interface's implementors. Rebinding Speaker to Quiet makes the same
// `speak` print 3 with no other change. No vtable in the binary, no cc/ld.
interface Speaker {
    projector level() -> Integer
}

class Loud implements Speaker {
    deps {}
    state {}
    projector level() -> Integer { return 7 }
}

class Quiet implements Speaker {
    deps {}
    state {}
    projector level() -> Integer { return 3 }
}

mapper speak(s: Speaker) -> Integer { return s.level() }

extern "C" { producer xstd_put_int(n: Integer) }

module App {
    id = "dispatch"
    bind Speaker -> Loud

    entry main(args: String[]) -> Integer {
        let s = App.resolve(Speaker)   // a Loud, seen only as a Speaker
        xstd_put_int(speak(s))         // dispatched to Loud.level at runtime -> 7
        return 0
    }
}
