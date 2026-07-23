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

# Unsupported program: must fail and leave no binary.
printf 'import "std/io.xi"\nmodule M { id = "px"\n entry main(args: String[]) -> Integer { io.println("x") return 0 } }\n' > "$W/px.xi"
XC_OUT="$W" "$XC" --backend native "$W/px.xi" >/dev/null 2>&1
if [ $? -eq 0 ] || [ -x "$W/px" ]; then echo "  ✗ unsupported program was not rejected"; fail=1
else echo "  ✓ unsupported program rejected, no binary"; fi

if [ "$fail" -eq 0 ]; then echo "native-smoke: all checks passed"; else echo "native-smoke: FAILURES"; fi
exit $fail
