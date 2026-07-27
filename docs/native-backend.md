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

The native backend is being built in stages behind the flag, with the C backend as the untouched default the whole way. Today it compiles `Integer`- and `String`-typed functions: `main` plus any top-level function whose parameters and return are `Integer` or `String`. A body may use:

- `let` bindings (with or without a `: Type` annotation, which types an empty array and promotes an `Integer` initializer to a `Number`), assignment, and `return`;
- `if` / `else` and `while`;
- calls to other integer functions (including recursion and mutual recursion);
- calls to declared `extern "C"` functions with integer or string-literal arguments (bound from libSystem or the runtime by dyld — see below);
- string literals, string locals, and string concatenation with `+` (a String value is a pointer plus a length, two registers / two stack slots; concatenation calls the runtime);
- string operations: by-value equality `==` / `!=` (compares bytes, not pointers), `string_len`, `string_char_at`, and `string_slice`, each dispatched to a runtime symbol;
- extension methods on a scalar receiver (`String`, `Integer`, `Number`) or an array (`Integer[]`, an interface array): `recv.method(args)` calls the `<Type>__method` function with the receiver as the first argument, so the compiler's own `s.startsWith2(...)`-style helpers compile; a `predicate` returns a `Bool` (a one-slot Integer, with `true` / `false` literals);
- array parameters and returns (AAPCS): an array argument is passed by pointer (a copy is not needed since the value's slots are already contiguous), and an array return travels through the `x8` indirect-result register into a caller-allocated buffer. This is the same convention a C compiler uses, so the native backend can both take/return arrays between its own functions and call C functions like `appendInt(arr, v) -> arr` that build arrays functionally;
- arrays with elements of any width: `Integer[]` (one slot), `String[]` (a pointer plus a length, two slots), and arrays of a compound type (laid out inline) all share the `{ data, len, cap }` fat pointer; literals, `.len`, `.data[i]` reads, `xs.data[i] = v` element stores, `for x in`, and by-value parameters store and load each element at `index * elementWidth`;
- compound types (`type T = { ... }`) with Integer, String, and array fields: construction `T { f: v, ... }` and field access `t.f` (laid out inline, one region per field);
- interfaces and classes: `Module.resolve(I)` returns an instance of the bound class, method calls dispatch to it, and methods read and write `this.field` on the heap-allocated (zero-initialized) state;
- dependency injection: a class's `deps { d: I }` are stored in its instance and constructed recursively on resolve; a method reaches a dependency by its bare name;
- singletons: `bind I -> C as singleton` (or a `scope = singleton` module) shares one instance across every resolve, built lazily on first use;
- polymorphic dispatch: an interface-typed value (a parameter of interface type, or an element of an injected list) calls a method that is resolved at runtime from the object, not the call site. Each instance carries a class-index header word; the call is a compare-and-branch over the interface's implementors to an ordinary static call, so there is no vtable in the binary and no function-pointer relocation;
- list injection: a `deps { xs: I[] }` dependency is built as an array holding one instance of every class that implements `I`; `xs.len` and `xs.data[i]` iterate it, and a method call on an element dispatches polymorphically;
- `for x in <array>`: an index walk over an `Integer[]` or a ref array; the loop variable is bound to each element with its kind, so `x.method()` on an interface array dispatches per element;
- generic interfaces: a parametric `interface Box<T>` is monomorphized (before either backend runs) into a distinct concrete interface per instantiation, so `Box<Integer>` and `Box<String>` are separate interfaces with separate implementors and return types; an unbound dependency auto-wires to the single class implementing its instantiation;
- sum types and `match`: a `type T = | A { ... } | B | ...` value is laid out inline as a tag word plus the widest variant's payload; a variant is constructed by name (`A { f: v }` or a nullary `B`), passed by value, and deconstructed with `match`, which tests the tag and binds the payload in each arm;
- `Number` (IEEE-754 double) arithmetic and comparison: a literal is materialized into a stack slot, `+ - * /` are the hardware double instructions over the FP registers, and `== != < <= > >=` lower to `fcmp`; an `Integer` operand mixed with a `Number` is promoted with `scvtf` (so `2.0 + 3` and `3 < 4.5` work); `Number` parameters, returns, arguments, and fields all travel in `d`-registers per the calling convention, in a register bank separate from the integer arguments (so `f(a: Integer, x: Number, b: Integer)` puts `a`/`b` in `x`-registers and `x` in a `d`-register);
- expressions over integer literals, parameters, locals, `+ - * / %`, comparisons (`== != < <= > >=`), and parentheses.

Locals and parameters get dedicated stack slots (stable across loop iterations); expression temps get fresh slots; branches are resolved in a second pass, and calls follow the AArch64 convention (args in `x0`..`x7`, result in `x0`, `fp`/`lr` saved). The backend lays the functions out and patches every `BL` itself. Anything outside the subset (a string, a non-integer function, an unsupported operator) is reported and refused rather than mis-compiled:

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

The purest form of a toolchain-free binary is a static Linux ELF that makes raw system calls, needing no loader, no libc, and no signature. That is a later target; the seams are already in place for it.

## Targeting other architectures

The backend is organized around two interfaces: `InsnEncoder` (an instruction set) and `ObjectWriter` (an object format for an OS). It is injected every implementor of each, and selects the pair matching the target: the encoder whose `archName()` equals the target arch, and the writer whose `osName()` equals the target os. The target defaults to the host and is overridable with `XC_ARCH` and `XC_OS`.

Supporting a new arch_os is therefore additive: write an `InsnEncoder` for the instruction set (e.g. x86-64) and, if needed, an `ObjectWriter` for the format (e.g. ELF for Linux), and they are discovered and selected automatically. Today the set is `Arm64Encoder` + `MachoWriter` (arm64/macos).

## Roadmap

| Stage | State |
|-------|-------|
| Intermediate form and pluggable encoder / object-writer seams | done |
| `return <int>` compiles and runs, no cc/ld/codesign | done |
| Integer arithmetic (`+ - * / %`, parentheses) with a stack frame | done |
| Locals, comparisons, `if`/`else`, `while` | done |
| Function calls (params, recursion, AArch64 convention) | done |
| External calls via dyld imports (stubs, `__got`, chained fixups) | done |
| Link the runtime (`xstd_*` bound from runtime.dylib) | done |
| String literals (constant pool, passed as pointer + length) | done |
| String variables and concatenation | done |
| String parameters and returns (functions over strings) | done |
| Integer arrays: literals, `.len`, `.data[i]` | done |
| Compound types: construction and field access | done |
| Interfaces + classes: resolve, method dispatch, state (single bind, static) | done |
| Dependency injection (`deps`, recursive construction) | done |
| Singletons (shared instance, lazy) | done |
| Polymorphic dispatch (interface values, runtime method selection) | done |
| List injection (`I[]` dependency of all implementors) | done |
| Generic interfaces (monomorphized, auto-wired) | done |
| Sum types and `match` (tag + payload, variant patterns) | done |
| `Number` (double) arithmetic, comparison, parameters, returns, fields | done |
| Full language coverage, diffed against the C backend | planned |
| Self-host: compile the compiler with the native backend | planned |
| Second target (Linux ELF, x86-64) | planned |
