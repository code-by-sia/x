#!/usr/bin/env bash
# Build the X compiler. There is no checked-in C seed: we download the matching
# released `xc` binary, use it to compile compiler/xc.xi into a fresh `xc`, then
# rebuild that from source with itself (self-host). The released seed only kicks
# off the first compile — the shipped compiler/xc is built from current source.
#
#   ./compiler/bootstrap.sh
#
# Seed selection is controlled by compiler/fetch-seed.sh (XC_SEED /
# XC_BOOTSTRAP_VERSION / XC_BOOTSTRAP_REPO). Requires curl, tar and a C compiler.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export XC_RUNTIME="$ROOT/runtime"
export XC_OUT="$ROOT/build"          # all build artifacts land here
HELP="$ROOT/compiler/xc_helpers.c"
mkdir -p "$XC_OUT"

echo "==> [seed] fetching a released compiler to bootstrap from ..."
SEED="$("$ROOT/compiler/fetch-seed.sh")"
echo "    seed: $SEED"

echo "==> [stage1] seed compiler builds xc from compiler/xc.xi ..."
XC_HELPERS="$HELP" "$SEED" compiler/xc.xi >/dev/null
cp "$XC_OUT/xc" compiler/xc
echo "    built compiler/xc"

echo "==> [stage2] xc rebuilds itself from compiler/xc.xi ..."
XC_HELPERS="$HELP" ./compiler/xc compiler/xc.xi >/dev/null
cp "$XC_OUT/xc" compiler/xc
echo "    compiler/xc is now built from source by itself"

echo "==> Building the REPL / run tool 'xi' from compiler/xi.xi ..."
./compiler/xc compiler/xi.xi >/dev/null
mkdir -p bin
cp "$XC_OUT/xi" bin/xi
echo "    built ./bin/xi"

echo "==> Building the test runner 'xt' from compiler/test.xi ..."
./compiler/xc compiler/test.xi >/dev/null
cp "$XC_OUT/xt" bin/xt
echo "    built ./bin/xt"

echo "==> Building the load tester 'loadtest' from compiler/loadtest.xi ..."
./compiler/xc compiler/loadtest.xi >/dev/null
cp "$XC_OUT/loadtest" bin/loadtest
echo "    built ./bin/loadtest"

echo "==> Building runtime.dylib (native backend runtime link) ..."
cc -dynamiclib -std=c99 -O2 -w -install_name "$ROOT/runtime/runtime.dylib" \
   "$ROOT/runtime/runtime.c" -o "$ROOT/runtime/runtime.dylib" -lm -lpthread
echo "    built runtime/runtime.dylib"

echo "Bootstrap complete. The compiler is built from current Xi source."
echo "  ./compiler/xc <file.xi>   compile to a native binary"
echo "  ./bin/xi                 start the REPL"
echo "  ./bin/xi <file.xi>        compile and run a file"
echo "  ./bin/xt <file.xi>    run a *_test.xi test file"
