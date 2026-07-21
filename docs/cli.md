# CLI & REPL

The toolchain is four binaries, each built by `./compiler/bootstrap.sh` from its
own manifest + `module` (`Compile`, `Xi`, `Test`, `LoadTest`):

| Binary | Module | Role |
|--------|--------|------|
| `xc` | `Compile` | the compiler (Xi → C99 → native) |
| `xi` | `Xi` | run a file, REPL, `test`/`install`/`pack`/`skill`/`update` |
| `xt` | `Test` | dedicated test runner (same engine as `xi test`) |
| `loadtest` | `LoadTest` | load/perf testing for Xi projects |

`xc` and `xi` are installed on your `PATH` (see
[Getting started](getting-started.md)); `xt` and `loadtest` are built into
`./bin` by bootstrap.

## `xc` - the compiler

```console
$ xc <source.xi> [more.xi ...]
```

Pipeline: resolve `import`s → lex → parse → generate C → invoke `cc` →
**native executable**. The binary is written to the output directory `$XC_OUT`
(default `build/`). It's named after the source file, unless the program's
`module` declares an `id` (see [module metadata](dependency-injection.md#module-metadata)),
in which case `id` is used. The intermediate generated C is deleted after a successful
build - set `XC_KEEP_C=1` to keep it for inspection.

A successful build is **silent** - `xc` prints only errors, so it composes
cleanly in scripts and CI. Exit status is `0` on success, `1` if anything failed.

```console
$ xc greeting.xi     # -> build/greeting  (no output)
$ ./build/greeting
Good day, Ada.
```

Pass **several sources** to build several modules in one invocation. Each is
built independently; a failure doesn't stop the rest, so one run surfaces every
module's errors, and the exit status is non-zero if any failed:

```console
$ xc server.xi client.xi worker.xi      # -> build/server, build/client, build/worker
```

`--verbose` restores the step-by-step trace (also via `XC_VERBOSE=1`):

```console
$ xc --verbose greeting.xi
xc: loading + lexing greeting.xi ...
xc: parsing ...
xc: generating C ...
xc: compiling C to native binary ...
xc: built executable build/greeting
```

`xc --all` discovers every **buildable module** under the current directory (a
file with both an `entry` and a `module`) and builds each into its own binary
(named by the module `id`):

```console
$ xc --all
xc --all: built 2 module(s), 0 failed
```

A C compiler (`cc`) must be on your `PATH`, since `xc` builds the native binary by
compiling generated C. `xc version` prints the toolchain version.

### WebAssembly - `xc --target wasm`

Because `xc` compiles through portable C99, the same program can target the web.
`xc --target wasm <source.xi>` routes the generated C + runtime through
[Emscripten](https://emscripten.org) (`emcc`) and emits `build/<name>.{html,js,wasm}`
instead of a native binary:

```console
$ xc --target wasm examples/stdlib/wasm_demo.xi
xc: built WebAssembly build/wasm_demo.{html,js,wasm}
xc: serve it, e.g.  python3 -m http.server -d build  then open wasm_demo.html
```

Open the generated `.html` in a browser (`stdout`/`stderr` show in the page
console), or run the `.js` under Node. Requires `emcc` on your `PATH`
(`brew install emscripten`). The default target is `native`; pass
`--target native` to be explicit. See [WebAssembly](wasm.md) for what runs in
the browser sandbox and what doesn't.

### Native backend - `xc --backend native`

By default `xc` builds through C99 and a C compiler. `--backend native` (or
`XC_BACKEND=native`) instead emits machine code and writes the executable
itself, so the build needs no `cc` and no `ld`:

```console
$ xc --backend native examples/native/exit_code.xi
$ ./build/exit_code ; echo $?
42
```

This backend is being built in stages and currently compiles a single program
shape (an integer-literal return); anything else is reported and refused rather
than mis-compiled. The C backend stays the default. See
[Native backend](native-backend.md) for scope, the toolchain-free design, and
the roadmap.

### Dependencies - `xi install`

A module can list third-party libraries as `dependencies` (URLs to `.tar.gz` /
`.zip` source archives). `xi install [file]` downloads and extracts them into a
`modules/` directory, which `xc` then folds into the build automatically:

```console
$ xi install server.xi        # or: xi install  (every buildable module)
  fetching https://github.com/code-by-sia/xi-sqlite/archive/refs/tags/v0.1.0.tar.gz
xi install: 1/1 fetched into ./modules
$ xc server.xi                # compiles ./modules in, no extra import
```

Needs `curl` (and `unzip` for `.zip`). See
[Multi-file › Dependencies](multi-file.md#dependencies-dependencies--xi-install).

| Environment variable | Meaning | Default |
|----------------------|---------|---------|
| `XC_OUT` | output directory for the built binary | `build` |
| `XC_TARGET` | build target: `native` or `wasm` (same as `--target`) | `native` |
| `XC_KEEP_C` | keep the generated C instead of deleting it | unset |
| `XC_RUNTIME` | C runtime location (set by the installed wrapper) | bundled |
| `XC_STD` | search root for `import "std/..."` (set by the wrapper) | bundled |

> The installed `xc`/`xi` wrappers set `XC_RUNTIME` and `XC_STD` for you, so you
> normally only touch `XC_OUT`.

## `xi` - run tool & REPL

`xi` compiles and runs a file, hosts the REPL, and provides `test` / `skill` /
`update` / `version` subcommands.

### Run a file

```console
$ xi hello.xi
Hello World!
```

This compiles the file and runs the resulting binary.

### Version

```console
$ xi version          # also: xi --version, xi -v
xi 0.0.50
```

### Self-update

`xi update` downloads the latest release bundle for your platform from GitHub and
replaces the installed `xc`/`xi` binaries, `runtime/`, and `std/` **in place** -
no reinstall needed.

```console
$ xi update
xi update: checking code-by-sia/xi ...
current: 0.0.49   latest: 0.0.50
downloading xi-v0.0.50-macos-arm64.tar.gz ...
xi updated: 0.0.49 -> 0.0.50
```

It no-ops with "already up to date" when you're on the latest version. Notes:

- Works on an **installed release bundle** (the `bin/` + `libexec/` layout); run
  it from a source checkout and it reports that it can't find an install root.
- Needs write access to the install directory - use `sudo xi update` if you
  installed under a system path.
- Requires `curl` and `tar` on `PATH`. Override the source repo with
  `XI_UPDATE_REPO=owner/name`.

### Run tests

`xi test <file.xi>` compiles in test mode and runs the file's `test` cases,
printing `ok`/`not ok` per case, a summary, and a nonzero exit code if any failed.
See [Testing](testing.md).

```console
$ xi test examples/di/calc_test.xi      # one file
$ xi test --all                      # every *_test.xi under the current dir
ok - addition
...
3 tests, 3 passed, 0 failed
```

### Language guide skill

`xi skill` fetches the latest **[Xi language guide](skill.md)** (a single markdown
file documenting how to write Xi) and **prints it to stdout**. Pipe it to
a file or straight to your coding tool:

```console
$ xi skill > SKILL.md        # save it
$ xi skill | pbcopy          # or copy it to your clipboard
```

Status/errors go to stderr, so stdout is clean markdown. Requires `curl`;
override the source with `XI_SKILL_URL` (or `XI_SKILL_REPO` / `XI_SKILL_REF`).

### Interactive REPL

```console
$ xi
Xi REPL - :help for commands, :quit to exit
x> let n = 21
x> print("n = " + n)
n = 21
x> mapper dbl(x: Number) -> Number { return x * 2 }
(defined)
x> print("double = " + dbl(n))
double = 42
x> :quit
bye
```

The REPL is a **compile-and-run loop**:

- **Declarations** (`type`, `class`, `mapper`, `interface`, …) accumulate across
  the session and persist.
- **Statements** are appended to the session and the whole program is recompiled
  and re-run; only the *new* output is shown.
- Use `print(x)` to display a value (`print` takes a `String`; build one with
  `+`, e.g. `print("x = " + x)`).

| Command | Effect |
|---------|--------|
| `:help`  | show commands |
| `:reset` | clear the session |
| `:dump`  | print the accumulated program |
| `:quit`  | exit |

## Other `xi` subcommands

| Command | Effect |
|---------|--------|
| `xi test <file.xi>` / `xi test --all` | run a file's `test`s, or every `*_test.xi` in the project ([Testing](testing.md)) |
| `xi skill` | print the single-file language guide ([skill](skill.md)) |
| `xi update` | self-update the toolchain to the latest release |
| `xi version` | print the toolchain version |

## `xt` - test runner

A standalone test runner (`module Test`), the same compile-in-test-mode-and-run
engine as `xi test`, as its own binary:

```console
$ xt examples/di/calc_test.xi              # one file
$ xt examples/di/calc_test.xi --filter mul # only matching test names
$ xt --all                              # every *_test.xi under the cwd
3 tests, 3 passed, 0 failed
```

Reads `XC` (compiler path) and `XC_RUNTIME` from the environment, like `xi`.

## `loadtest` - load / perf tester

A load/performance tester for Xi projects (`module LoadTest`), built on the std
library (`std/time`, `std/http`). Three modes:

```console
$ loadtest --compile a.xi b.xi          # compiler stress: compile time + C size per file
$ loadtest --bench   app.xi --iters 50  # run-binary benchmark: min/mean/max run time
$ loadtest --http    web.xi --url http://127.0.0.1:8080/health --requests 200
http-load http://127.0.0.1:8080/health:   200 req, 0 errors
   4576 req/s   min 129us   mean 218us   max 2880us
```

The `--http` mode compiles the web example, starts its server, fires the GETs,
then stops the server. (It is sequential for now; concurrent connections are a
future enhancement.)
