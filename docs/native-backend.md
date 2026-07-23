# Native backend

Xi compiles to a native binary in one of two ways, chosen per build:

- **The C backend (default).** Xi source becomes C99, which a C compiler turns into a native binary. This is mature, portable to every platform a C compiler targets, and optimizes well.
- **The native backend (`--backend native`).** Xi source becomes machine code directly, and Xi writes the executable itself. A binary built this way needs no C compiler and no linker on the machine.

```bash
xc --backend native examples/native/exit_code.xi
./build/exit_code ; echo $?      # -> 42
```

`XC_BACKEND=native` selects it through the environment, equivalent to the flag. The selector is independent of `--target` (which chooses WebAssembly versus a native OS binary).

## Why a second backend

Emitting C is a good strategy and it stays the default. The native backend exists for one goal: **a toolchain-free build**. `xc foo.xi` should produce a runnable binary on a machine that has no `cc`, no `clang`, and no `ld`. Reaching that means owning the parts a C compiler used to handle: instruction selection, machine-code encoding, and writing the executable image, including its symbol references and, on Apple platforms, its code signature.

The runtime is not rewritten for this. A prebuilt runtime object ships per platform (built once, by the maintainers, with a C compiler at release time); the native backend links it in. So the goal is "no toolchain on your machine", not "no C anywhere in the project".

## Current scope

The native backend is being built in stages behind the flag, with the C backend as the untouched default the whole way. Today it compiles an integer `entry main` body made of:

- `let` bindings, assignment, and `return`;
- `if` / `else` and `while`;
- expressions over integer literals, locals, `+ - * / %`, comparisons (`== != < <= > >=`), and parentheses.

Locals get dedicated stack slots (stable across loop iterations); expression temps get fresh slots; branches are resolved in a second pass. This exercises the whole path: parsing into the intermediate form, emitting real AArch64 with a stack frame, and assembling a complete, signed executable. Anything outside it (a call, a string, an unsupported operator) is reported and refused rather than mis-compiled:

```
xc: error: native backend: the native backend supports an integer entry body
    of let, assignment, return, if/else and while over int literals, locals,
    + - *, comparisons and parentheses; the body must end in a return
```

Every supported program is checked against the C backend for an identical result (`compiler/native-smoke.sh`). Coverage grows from here (function calls, then the runtime link) with each step diffed the same way.

## How a binary is built (arm64 macOS)

Apple Silicon sets the shape of the output. A binary must go through the dynamic loader and carry a valid code signature, or the kernel refuses to run it. The native backend produces exactly that, by hand:

1. **Lower.** The entry body is parsed into the intermediate form: three-address instructions (constants, arithmetic, comparisons, copies) plus labels and branches for control flow, ending in a return.
2. **Encode.** AArch64 is fixed 32-bit instructions. Register allocation is the simplest correct scheme, spill everything: each value gets a stack slot, and each instruction loads its operands, computes, and stores the result. Branch targets are resolved in a second pass once every label's offset is known. The final value lands in `w0`, which carries the exit status.
3. **Assemble.** A Mach-O image with `__PAGEZERO`, `__TEXT`, and `__LINKEDIT`; an `LC_MAIN` entry; references to `/usr/lib/dyld` and `/usr/lib/libSystem.B.dylib`; and an empty chained-fixups table (this program imports nothing).
4. **Sign.** An ad-hoc `LC_CODE_SIGNATURE` embedded directly: a CodeDirectory holding a SHA-256 of every page of the image. The kernel verifies these at launch. No `codesign` is invoked.
5. **Write.** The bytes go to disk, marked executable.

The layout logic lives in Xi; the machine only supplies the low-level primitives Xi lacks (a byte buffer, SHA-256, a raw file write).

The purest form of a toolchain-free binary is a static Linux ELF that makes raw system calls, needing no loader, no libc, and no signature. That is a later target; the seams (one encoder per instruction set, one writer per object format) are already in place for it.

## Roadmap

| Stage | State |
|-------|-------|
| Intermediate form and pluggable encoder / object-writer seams | done |
| `return <int>` compiles and runs, no cc/ld/codesign | done |
| Integer arithmetic (`+ - * / %`, parentheses) with a stack frame | done |
| Locals, comparisons, `if`/`else`, `while` | done |
| Function calls | next |
| Link the prebuilt runtime object | planned |
| Full language coverage, diffed against the C backend | planned |
| Self-host: compile the compiler with the native backend | planned |
| Second target (Linux ELF, x86-64) | planned |
