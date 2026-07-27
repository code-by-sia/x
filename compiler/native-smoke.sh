#!/usr/bin/env bash
# Smoke test for the native backend (`xc --backend native`): build a handful of
# integer-return programs straight to native executables — no cc, ld, or
# codesign — run each, and assert the exit code and (on macOS) a valid code
# signature. Also asserts an unsupported program is rejected with no binary.
#
#   ./compiler/native-smoke.sh
#
# Reads XC (compiler) and XC_RUNTIME from the environment, defaulting to the
# in-tree build.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export XC_RUNTIME="${XC_RUNTIME:-$ROOT/runtime}"
XC="${XC:-$ROOT/compiler/xc}"
unset XC_HELPERS                       # compiler-only; must not leak into user builds
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fail=0

# Integer-return expressions: literals and arithmetic (+ - * and parentheses),
# checked against the expected exit code and (on macOS) a valid signature.
n=0
smoke() {  # $1 = expression, $2 = expected exit code
    n=$((n+1))
    printf 'module M { id = "e%s"\n entry main(args: String[]) -> Integer { return %s } }\n' "$n" "$1" > "$W/e$n.xi"
    XC_OUT="$W" "$XC" --backend native "$W/e$n.xi" >/dev/null 2>&1
    "$W/e$n"; got=$?
    if [ "$got" -ne "$2" ]; then echo "  ✗ '$1' -> exit $got (want $2)"; fail=1; return; fi
    if [ "$(uname)" = "Darwin" ] && ! codesign -v "$W/e$n" >/dev/null 2>&1; then
        echo "  ✗ '$1' -> exit ok but signature invalid"; fail=1; return
    fi
    echo "  ✓ '$1' -> exit $got, signed"
}
smoke "0" 0
smoke "42" 42
smoke "200" 200
smoke "6 * 7" 42
smoke "2 + 3 * 4" 14
smoke "(2 + 3) * 4" 20
smoke "100 - 58" 42
smoke "1000 * 1000" 64      # 1000000 mod 256, exercises wraparound
smoke "20 / 4" 5
smoke "17 % 5" 2

# Locals + control flow, checked against an expected exit code.
flow() {  # $1 = body, $2 = expected
    n=$((n+1))
    printf 'module M { id = "f%s"\n entry main(args: String[]) -> Integer {\n%s\n } }\n' "$n" "$1" > "$W/f$n.xi"
    XC_OUT="$W" "$XC" --backend native "$W/f$n.xi" >/dev/null 2>&1
    "$W/f$n"; got=$?
    if [ "$got" -ne "$2" ]; then echo "  ✗ [flow $n] -> exit $got (want $2)"; fail=1; return; fi
    echo "  ✓ [flow $n] -> exit $got"
}
flow 'let s = 0
let i = 1
while i <= 10 { s = s + i  i = i + 1 }
return s' 55
flow 'let n = 5
let f = 1
while n > 1 { f = f * n  n = n - 1 }
return f' 120
flow 'let a = 3
let b = 4
let m = a
if b > m { m = b }
return m' 4

# Function calls + recursion.
call() {  # $1 = full module source, $2 = expected
    n=$((n+1))
    printf '%s\n' "$1" > "$W/c$n.xi"
    XC_OUT="$W" "$XC" --backend native "$W/c$n.xi" >/dev/null 2>&1
    "$W/c$n"; got=$?
    if [ "$got" -ne "$2" ]; then echo "  ✗ [call $n] -> exit $got (want $2)"; fail=1; return; fi
    echo "  ✓ [call $n] -> exit $got"
}
call 'mapper fact(n: Integer) -> Integer { if n <= 1 { return 1 }  return n * fact(n - 1) }
module M { entry main(args: String[]) -> Integer { return fact(5) } }' 120
call 'mapper add(a: Integer, b: Integer) -> Integer { return a + b }
module M { entry main(args: String[]) -> Integer { return add(add(10, 20), 12) } }' 42

# External call via a dyld import (native-only: libc putchar), checked by output.
printf 'extern "C" { producer putchar(c: Integer) -> Integer }\nmodule M { entry main(args: String[]) -> Integer { putchar(79)  putchar(75)  putchar(10)  return 0 } }\n' > "$W/imp.xi"
XC_OUT="$W" "$XC" --backend native "$W/imp.xi" >/dev/null 2>&1
out=$("$W/imp" 2>/dev/null)
if [ "$out" = "OK" ]; then echo "  ✓ import: putchar prints \"OK\""; else echo "  ✗ import: putchar printed \"$out\""; fail=1; fi

# Runtime call via the runtime dylib (xstd_put_int), checked by output.
[ -f "$ROOT/runtime/runtime.dylib" ] || cc -dynamiclib -std=c99 -O2 -w \
    -install_name "$ROOT/runtime/runtime.dylib" "$ROOT/runtime/runtime.c" \
    -o "$ROOT/runtime/runtime.dylib" -lm -lpthread 2>/dev/null
printf 'extern "C" { producer xstd_put_int(n: Integer) }\nmodule M { entry main(args: String[]) -> Integer { xstd_put_int(42)  return 0 } }\n' > "$W/rt.xi"
XC_OUT="$W" "$XC" --backend native "$W/rt.xi" >/dev/null 2>&1
rtout=$("$W/rt" 2>/dev/null)
if [ "$rtout" = "42" ]; then echo "  ✓ runtime call: xstd_put_int prints 42"; else echo "  ✗ runtime call printed \"$rtout\""; fail=1; fi

# String literal passed to a runtime string call (native hello world).
printf 'extern "C" { producer xstd_put_str(s: String) }\nmodule M { entry main(args: String[]) -> Integer { xstd_put_str("hi\\n")  return 0 } }\n' > "$W/hw.xi"
XC_OUT="$W" "$XC" --backend native "$W/hw.xi" >/dev/null 2>&1
hwout=$("$W/hw" 2>/dev/null)
if [ "$hwout" = "hi" ]; then echo "  ✓ string: xstd_put_str prints hi"; else echo "  ✗ string printed \"$hwout\""; fail=1; fi

# String locals + concatenation.
printf 'extern "C" { producer xstd_put_str(s: String) }\nmodule M { entry main(args: String[]) -> Integer { let a = "foo"  let b = "bar"  xstd_put_str(a + b + "\\n")  return 0 } }\n' > "$W/cat.xi"
XC_OUT="$W" "$XC" --backend native "$W/cat.xi" >/dev/null 2>&1
catout=$("$W/cat" 2>/dev/null)
if [ "$catout" = "foobar" ]; then echo "  ✓ string concat: foobar"; else echo "  ✗ concat printed \"$catout\""; fail=1; fi

# String parameter + String return.
printf 'extern "C" { producer xstd_put_str(s: String) }\nmapper greet(name: String) -> String { return "hi " + name }\nmodule M { entry main(args: String[]) -> Integer { xstd_put_str(greet("bob"))  return 0 } }\n' > "$W/fn.xi"
XC_OUT="$W" "$XC" --backend native "$W/fn.xi" >/dev/null 2>&1
fnout=$("$W/fn" 2>/dev/null)
if [ "$fnout" = "hi bob" ]; then echo "  ✓ string fn: greet(\"bob\")"; else echo "  ✗ string fn printed \"$fnout\""; fail=1; fi

# Integer array: literal, .len, and indexing in a loop.
printf 'extern "C" { producer xstd_put_int(n: Integer) }\nmodule M { entry main(args: String[]) -> Integer { let a = [4, 5, 6]  let s = 0  let i = 0  while i < a.len { s = s + a.data[i]  i = i + 1 }  xstd_put_int(s)  return 0 } }\n' > "$W/arr.xi"
XC_OUT="$W" "$XC" --backend native "$W/arr.xi" >/dev/null 2>&1
arrout=$("$W/arr" 2>/dev/null)
if [ "$arrout" = "15" ]; then echo "  ✓ array: sum [4,5,6] = 15"; else echo "  ✗ array printed \"$arrout\""; fail=1; fi

# Compound type: construction and field access.
printf 'type P = { x: Integer, y: Integer }\nextern "C" { producer xstd_put_int(n: Integer) }\nmodule M { entry main(args: String[]) -> Integer { let p = P { x: 20, y: 22 }  xstd_put_int(p.x + p.y)  return 0 } }\n' > "$W/st.xi"
XC_OUT="$W" "$XC" --backend native "$W/st.xi" >/dev/null 2>&1
stout=$("$W/st" 2>/dev/null)
if [ "$stout" = "42" ]; then echo "  ✓ struct: P{20,22}.x + .y = 42"; else echo "  ✗ struct printed \"$stout\""; fail=1; fi

# Interface + class: resolve, method dispatch, and state.
printf 'interface Counter { consumer inc()  projector get() -> Integer }\nclass Ctr implements Counter { deps {} state { n: Integer = 0 }\n consumer inc() { this.n = this.n + 1 }  projector get() -> Integer => this.n }\nextern "C" { producer xstd_put_int(n: Integer) }\nmodule M { bind Counter -> Ctr\n entry main(args: String[]) -> Integer { let c = M.resolve(Counter)  c.inc()  c.inc()  c.inc()  xstd_put_int(c.get())  return 0 } }\n' > "$W/if.xi"
XC_OUT="$W" "$XC" --backend native "$W/if.xi" >/dev/null 2>&1
ifout=$("$W/if" 2>/dev/null)
if [ "$ifout" = "3" ]; then echo "  ✓ interface: counter inc x3 -> 3"; else echo "  ✗ interface printed \"$ifout\""; fail=1; fi

# Dependency injection: a class with an injected dependency.
printf 'interface Adder { mapper add(a: Integer, b: Integer) -> Integer }\nclass RealAdder implements Adder { deps {} mapper add(a: Integer, b: Integer) -> Integer { return a + b } }\ninterface Calc { mapper compute() -> Integer }\nclass RealCalc implements Calc { deps { adder: Adder } mapper compute() -> Integer { return adder.add(19, 23) } }\nextern "C" { producer xstd_put_int(n: Integer) }\nmodule M { bind Adder -> RealAdder  bind Calc -> RealCalc\n entry main(args: String[]) -> Integer { let c = M.resolve(Calc)  xstd_put_int(c.compute())  return 0 } }\n' > "$W/di.xi"
XC_OUT="$W" "$XC" --backend native "$W/di.xi" >/dev/null 2>&1
diout=$("$W/di" 2>/dev/null)
if [ "$diout" = "42" ]; then echo "  ✓ DI: injected adder -> 42"; else echo "  ✗ DI printed \"$diout\""; fail=1; fi

# Singleton: two resolves share one instance (state accumulates).
printf 'interface Counter { consumer inc()  projector get() -> Integer }\nclass Ctr implements Counter { deps {} state { n: Integer = 0 } consumer inc() { this.n = this.n + 1 }  projector get() -> Integer => this.n }\nextern "C" { producer xstd_put_int(n: Integer) }\nmodule M { bind Counter -> Ctr as singleton\n entry main(args: String[]) -> Integer { let a = M.resolve(Counter)  a.inc()  a.inc()  let b = M.resolve(Counter)  b.inc()  xstd_put_int(b.get())  return 0 } }\n' > "$W/sg.xi"
XC_OUT="$W" "$XC" --backend native "$W/sg.xi" >/dev/null 2>&1
sgout=$("$W/sg" 2>/dev/null)
if [ "$sgout" = "3" ]; then echo "  ✓ singleton: shared instance -> 3"; else echo "  ✗ singleton printed \"$sgout\""; fail=1; fi

# Polymorphic dispatch: an interface value dispatches to the bound implementor at
# runtime. Flipping the bind must flip the result with no change to the caller.
poly() {  # $1 = bound class, $2 = expected
    printf 'interface Speaker { projector level() -> Integer }\nclass Loud implements Speaker { deps {} state {} projector level() -> Integer { return 7 } }\nclass Quiet implements Speaker { deps {} state {} projector level() -> Integer { return 3 } }\nmapper speak(s: Speaker) -> Integer { return s.level() }\nextern "C" { producer xstd_put_int(n: Integer) }\nmodule M { bind Speaker -> %s\n entry main(args: String[]) -> Integer { let s = M.resolve(Speaker)  xstd_put_int(speak(s))  return 0 } }\n' "$1" > "$W/poly.xi"
    XC_OUT="$W" "$XC" --backend native "$W/poly.xi" >/dev/null 2>&1
    out=$("$W/poly" 2>/dev/null)
    if [ "$out" = "$2" ]; then echo "  ✓ dispatch: bind Speaker->$1 -> $out"; else echo "  ✗ dispatch: bind Speaker->$1 printed \"$out\" (want $2)"; fail=1; fi
}
poly Loud 7
poly Quiet 3

# List injection: an I[] dependency collects one of every implementor; the loop
# dispatches .area() to each concrete type (9 + 12 = 21).
printf 'interface Shape { projector area() -> Integer }\nclass Sq implements Shape { deps {} state {} projector area() -> Integer { return 9 } }\nclass Rc implements Shape { deps {} state {} projector area() -> Integer { return 12 } }\ninterface Report { projector total() -> Integer }\nclass Summer implements Report { deps { shapes: Shape[] } projector total() -> Integer { let s = 0  let i = 0  while i < shapes.len { s = s + shapes.data[i].area()  i = i + 1 }  return s } }\nextern "C" { producer xstd_put_int(n: Integer) }\nmodule M { bind Report -> Summer\n entry main(args: String[]) -> Integer { let r = M.resolve(Report)  xstd_put_int(r.total())  return 0 } }\n' > "$W/lst.xi"
XC_OUT="$W" "$XC" --backend native "$W/lst.xi" >/dev/null 2>&1
lstout=$("$W/lst" 2>/dev/null)
if [ "$lstout" = "21" ]; then echo "  ✓ list injection: Shape[] areas 9+12 = 21"; else echo "  ✗ list injection printed \"$lstout\""; fail=1; fi

# Generic interface: Box<Integer> and Box<String> monomorphize to distinct
# concrete interfaces, each auto-wired to its sole implementor and dispatched.
printf 'interface Box<T> { mapper get() -> T }\nclass IntBox implements Box<Integer> { deps {} mapper get() -> Integer => 42 }\nclass StrBox implements Box<String> { deps {} mapper get() -> String => "ok" }\ninterface Runner { mapper run() -> Integer }\nclass IntRunner implements Runner { deps { b: Box<Integer> } mapper run() -> Integer => b.get() }\ninterface Teller { mapper tell() -> String }\nclass StrTeller implements Teller { deps { b: Box<String> } mapper tell() -> String => b.get() }\nextern "C" { producer xstd_put_int(n: Integer)  producer xstd_put_str(s: String) }\nmodule M { bind Runner -> IntRunner  bind Teller -> StrTeller\n entry main(args: String[]) -> Integer { let r = M.resolve(Runner)  let t = M.resolve(Teller)  xstd_put_int(r.run())  xstd_put_str(t.tell())  return 0 } }\n' > "$W/gen.xi"
XC_OUT="$W" "$XC" --backend native "$W/gen.xi" >/dev/null 2>&1
genout=$("$W/gen" 2>/dev/null | tr '\n' ' ')
if [ "$genout" = "42 ok" ]; then echo "  ✓ generics: Box<Integer>->42, Box<String>->ok"; else echo "  ✗ generics printed \"$genout\""; fail=1; fi

# Sum types + match: a tagged value passed by value, deconstructed by variant.
printf 'type Expr = | Lit { v: Integer } | Add { a: Integer, b: Integer } | Zero\nmapper eval(e: Expr) -> Integer { match e { Lit l -> { return l.v }  Add p -> { return p.a + p.b }  Zero -> { return 0 } }  return 0 - 1 }\nextern "C" { producer xstd_put_int(n: Integer) }\nmodule M { entry main(args: String[]) -> Integer { xstd_put_int(eval(Lit { v: 7 }))  xstd_put_int(eval(Add { a: 20, b: 22 }))  xstd_put_int(eval(Zero))  return 0 } }\n' > "$W/sm.xi"
XC_OUT="$W" "$XC" --backend native "$W/sm.xi" >/dev/null 2>&1
smout=$("$W/sm" 2>/dev/null | tr '\n' ' ')
if [ "$smout" = "7 42 0 " ]; then echo "  ✓ sum types: Lit 7, Add 20+22, Zero -> 7 42 0"; else echo "  ✗ sum types printed \"$smout\""; fail=1; fi

# Number (double) arithmetic and functions: fadd/fmul/fdiv over FP registers,
# with Number parameters and returns travelling in d-registers.
printf 'mapper scale(x: Number, k: Number) -> Number { return x * k }\nextern "C" { producer xstd_put_num(n: Number) }\nmodule M { entry main(args: String[]) -> Integer { xstd_put_num(2.0 * 3.0)  xstd_put_num(10.0 / 4.0)  xstd_put_num(scale(3.0, 4.0))  return 0 } }\n' > "$W/nm.xi"
XC_OUT="$W" "$XC" --backend native "$W/nm.xi" >/dev/null 2>&1
nmout=$("$W/nm" 2>/dev/null | tr '\n' ' ')
if [ "$nmout" = "6 2.5 12 " ]; then echo "  ✓ number: 2*3=6, 10/4=2.5, scale(3,4)=12"; else echo "  ✗ number printed \"$nmout\""; fail=1; fi

# Number comparisons: fcmp drives if/else and while over doubles.
printf 'mapper rel(x: Number, y: Number) -> Integer { if x < y { return 1 }  if x > y { return 2 }  return 3 }\nextern "C" { producer xstd_put_int(n: Integer) }\nmodule M { entry main(args: String[]) -> Integer { xstd_put_int(rel(1.0, 2.0))  xstd_put_int(rel(3.5, 1.0))  xstd_put_int(rel(2.0, 2.0))  return 0 } }\n' > "$W/nc.xi"
XC_OUT="$W" "$XC" --backend native "$W/nc.xi" >/dev/null 2>&1
ncout=$("$W/nc" 2>/dev/null | tr '\n' ' ')
if [ "$ncout" = "1 2 3 " ]; then echo "  ✓ number compare: <, >, == -> 1 2 3"; else echo "  ✗ number compare printed \"$ncout\""; fail=1; fi

# for x in <array>: index walk over Integer[] and (with dispatch) a ref array.
printf 'extern "C" { producer xstd_put_int(n: Integer) }\nmodule M { entry main(args: String[]) -> Integer { let s = 0  for x in [4, 5, 6] { s = s + x }  xstd_put_int(s)  return 0 } }\n' > "$W/fe.xi"
XC_OUT="$W" "$XC" --backend native "$W/fe.xi" >/dev/null 2>&1
feout=$("$W/fe" 2>/dev/null)
if [ "$feout" = "15" ]; then echo "  ✓ for-in: sum [4,5,6] = 15"; else echo "  ✗ for-in printed \"$feout\""; fail=1; fi

# String operations: by-value equality, length, and slicing via the runtime.
printf 'extern "C" { producer xstd_put_int(n: Integer)  producer xstd_put_str(s: String) }\nmodule M { entry main(args: String[]) -> Integer { let a = "hello"  let b = "hel" + "lo"  if a == b { xstd_put_int(1) }  xstd_put_int(string_len(a))  xstd_put_str(string_slice(a, 1, 4))  return 0 } }\n' > "$W/so.xi"
XC_OUT="$W" "$XC" --backend native "$W/so.xi" >/dev/null 2>&1
soout=$("$W/so" 2>/dev/null | tr '\n' ' ')
if [ "$soout" = "1 5 ell" ]; then echo "  ✓ string ops: ==, len 5, slice ell"; else echo "  ✗ string ops printed \"$soout\""; fail=1; fi

# String extension method (predicate with a `this` receiver, Bool return) — the
# same startsWith2 pattern the compiler itself uses.
printf 'predicate String.startsWith2(prefix: String) { let pl = string_len(prefix)  if string_len(this) < pl { return false }  return string_slice(this, 0, pl) == prefix }\nextern "C" { producer xstd_put_int(n: Integer) }\nmodule M { entry main(args: String[]) -> Integer { let s = "hello world"  if s.startsWith2("hello") { xstd_put_int(1) }  if s.startsWith2("bye") { xstd_put_int(9) } else { xstd_put_int(0) }  return 0 } }\n' > "$W/xm.xi"
XC_OUT="$W" "$XC" --backend native "$W/xm.xi" >/dev/null 2>&1
xmout=$("$W/xm" 2>/dev/null | tr '\n' ' ')
if [ "$xmout" = "1 0 " ]; then echo "  ✓ extension method: s.startsWith2 -> 1, 0"; else echo "  ✗ extension method printed \"$xmout\""; fail=1; fi

# Array parameter + Integer[] extension method (receiver passed as three slots).
printf 'mapper total(xs: Integer[]) -> Integer { let s = 0  for x in xs { s = s + x }  return s }\nmapper Integer[].maxOr(f: Integer) -> Integer { let m = f  for x in this { if x > m { m = x } }  return m }\nextern "C" { producer xstd_put_int(n: Integer) }\nmodule M { entry main(args: String[]) -> Integer { xstd_put_int(total([1, 2, 3, 4]))  let a = [3, 9, 2, 7]  xstd_put_int(a.maxOr(0))  return 0 } }\n' > "$W/ap.xi"
XC_OUT="$W" "$XC" --backend native "$W/ap.xi" >/dev/null 2>&1
apout=$("$W/ap" 2>/dev/null | tr '\n' ' ')
if [ "$apout" = "10 9 " ]; then echo "  ✓ array param + ext: total=10, maxOr=9"; else echo "  ✗ array param printed \"$apout\""; fail=1; fi

# Unsupported program: must fail and leave no binary.
printf 'import "std/io.xi"\nmodule M { id = "px"\n entry main(args: String[]) -> Integer { io.println("x") return 0 } }\n' > "$W/px.xi"
XC_OUT="$W" "$XC" --backend native "$W/px.xi" >/dev/null 2>&1
if [ $? -eq 0 ] || [ -x "$W/px" ]; then echo "  ✗ unsupported program was not rejected"; fail=1
else echo "  ✓ unsupported program rejected, no binary"; fi

if [ "$fail" -eq 0 ]; then echo "native-smoke: all checks passed"; else echo "native-smoke: FAILURES"; fi
exit $fail
