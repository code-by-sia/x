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

for v in 0 1 42 99 200; do
    printf 'module M { id = "e%s"\n entry main(args: String[]) -> Integer { return %s } }\n' "$v" "$v" > "$W/e$v.xi"
    XC_OUT="$W" "$XC" --backend native "$W/e$v.xi" >/dev/null 2>&1
    "$W/e$v"; got=$?
    if [ "$got" -ne "$v" ]; then echo "  ✗ return $v -> exit $got"; fail=1; continue; fi
    if [ "$(uname)" = "Darwin" ] && ! codesign -v "$W/e$v" >/dev/null 2>&1; then
        echo "  ✗ return $v -> exit ok but signature invalid"; fail=1; continue
    fi
    echo "  ✓ return $v -> exit $got, signed"
done

# Unsupported program: must fail and leave no binary.
printf 'import "std/io.xi"\nmodule M { id = "px"\n entry main(args: String[]) -> Integer { io.println("x") return 0 } }\n' > "$W/px.xi"
XC_OUT="$W" "$XC" --backend native "$W/px.xi" >/dev/null 2>&1
if [ $? -eq 0 ] || [ -x "$W/px" ]; then echo "  ✗ unsupported program was not rejected"; fail=1
else echo "  ✓ unsupported program rejected, no binary"; fi

if [ "$fail" -eq 0 ]; then echo "native-smoke: all checks passed"; else echo "native-smoke: FAILURES"; fi
exit $fail
