// =============================================================
// x — the X REPL and run tool (written in X)
//
//   x                 start the interactive REPL
//   x file.x          compile file.x and run it
//
// The REPL is a compile-and-run loop: declarations accumulate across
// the session; each statement is appended and the whole session is
// recompiled and re-run, showing only the new output.  Use `print(...)`
// to display values.  Commands: :quit  :reset  :help  :dump
// =============================================================

extern "C" {
    mapper  string_len(s: String) -> Integer
    mapper  string_char_at(s: String, i: Integer) -> Integer
    mapper  string_slice(s: String, from: Integer, to: Integer) -> String
    producer read_line() -> String
    predicate stdin_eof() -> Bool
    consumer flush_out()
    mapper  run_command(cmd: String) -> Integer
    producer file_read_all(path: String) -> String
    producer file_write(path: String, content: String) -> Bool
    mapper  get_env(name: String, dflt: String) -> String
}

// ── small helpers ────────────────────────────────────────────────

mapper firstWord(s: String) -> String {
    let n = string_len(s)
    let i = 0
    // skip leading spaces
    while i < n and string_char_at(s, i) == 32 { i = i + 1 }
    let start = i
    while i < n and string_char_at(s, i) != 32 { i = i + 1 }
    return string_slice(s, start, i)
}

mapper trimLeft(s: String) -> String {
    let n = string_len(s)
    let i = 0
    while i < n and string_char_at(s, i) == 32 { i = i + 1 }
    return string_slice(s, i, n)
}

predicate isBlank(s: String) {
    let n = string_len(s)
    let i = 0
    while i < n {
        if string_char_at(s, i) != 32 { return false }
        i = i + 1
    }
    return true
}

predicate isDeclLine(s: String) {
    let kws = [
        "type", "interface", "class", "mapper", "projector", "predicate",
        "consumer", "producer", "reducer", "creator", "module", "extern",
        "import", "namespace"
    ]
    return kws.includes(firstWord(s))
}

mapper stripExt(path: String) -> String {
    let n = string_len(path)
    // ".xi"  (46='.', 120='x', 105='i')
    if n > 3 {
        if string_char_at(path, n - 3) == 46 and string_char_at(path, n - 2) == 120 and string_char_at(path, n - 1) == 105 {
            return string_slice(path, 0, n - 3)
        }
    }
    // ".x"
    if n > 2 {
        if string_char_at(path, n - 2) == 46 and string_char_at(path, n - 1) == 120 {
            return string_slice(path, 0, n - 2)
        }
    }
    return path + ".bin"
}

// Build the full program text for the current session.
mapper buildProgram(decls: String, stmts: String) -> String {
    return decls
         + "\nconsumer print(s: String) { system.stdout.writeln(s) }\n"
         + "async entry main(args: String[]) -> Integer {\n"
         + stmts
         + "    return 0\n}\n"
}

// The toolchain version. Bump this when cutting a release (matches the tag).
mapper xiVersion() -> String { return "0.1.14" }

// The release codename, shown alongside the version.
mapper xiCodename() -> String { return "Berlin" }

// Directory part of a path (everything before the last '/'); "." if none.
mapper dirOf(path: String) -> String {
    let n = string_len(path)
    let lastSp = 0 - 1
    let i = 0
    while i < n {
        if string_char_at(path, i) == 47 { lastSp = i }
        i = i + 1
    }
    if lastSp <= 0 { return "." }
    return string_slice(path, 0, lastSp)
}

// `xi update` — download the latest release bundle for this platform from GitHub
// and replace the installed xc/xi binaries, runtime, and stdlib in place.
consumer doUpdate(progPath: String) {
    let repo = get_env("XI_UPDATE_REPO", "code-by-sia/xi")
    let root = dirOf(dirOf(progPath))          // libexec/xi -> bundle root
    let sh = "set -e\n"
    sh = sh + "REPO=\"$1\"; ROOT=\"$2\"; CUR=\"$3\"\n"
    sh = sh + "if [ ! -d \"$ROOT/libexec\" ]; then w=$(command -v xi 2>/dev/null || true); if [ -n \"$w\" ]; then ROOT=$(cd \"$(dirname \"$w\")/..\" && pwd); fi; fi\n"
    sh = sh + "if [ ! -d \"$ROOT/libexec\" ]; then echo \"xi update: could not locate the install root (got: $ROOT)\"; echo \"  update works on an installed release bundle (bin/ + libexec/).\"; exit 1; fi\n"
    sh = sh + "if [ ! -w \"$ROOT/libexec\" ]; then echo \"xi update: no write permission to $ROOT (try: sudo xi update)\"; exit 1; fi\n"
    sh = sh + "os=$(uname -s); arch=$(uname -m)\n"
    sh = sh + "case \"$os\" in Linux) o=linux;; Darwin) o=macos;; *) echo \"xi update: unsupported OS: $os\"; exit 1;; esac\n"
    sh = sh + "case \"$arch\" in x86_64|amd64) a=x86_64;; arm64|aarch64) a=arm64;; *) echo \"xi update: unsupported arch: $arch\"; exit 1;; esac\n"
    sh = sh + "target=\"$o-$a\"\n"
    sh = sh + "tag=$(curl -fsSL \"https://api.github.com/repos/$REPO/releases/latest\" 2>/dev/null | grep '\"tag_name\"' | head -1 | cut -d'\"' -f4)\n"
    sh = sh + "[ -n \"$tag\" ] || { echo \"xi update: could not determine the latest release\"; exit 1; }\n"
    sh = sh + "ver=${tag#v}\n"
    sh = sh + "echo \"current: $CUR   latest: $ver\"\n"
    sh = sh + "if [ \"$ver\" = \"$CUR\" ]; then echo \"xi is already up to date.\"; exit 0; fi\n"
    sh = sh + "bundle=\"xi-$tag-$target\"\n"
    sh = sh + "url=\"https://github.com/$REPO/releases/download/$tag/$bundle.tar.gz\"\n"
    sh = sh + "tmp=$(mktemp -d \"$ROOT/.xi-update.XXXXXX\") || { echo \"xi update: cannot create a temp dir in $ROOT\"; exit 1; }\n"
    sh = sh + "echo \"downloading $bundle.tar.gz ...\"\n"
    sh = sh + "if ! curl -fsSL \"$url\" -o \"$tmp/b.tgz\"; then echo \"xi update: download failed ($url)\"; rm -rf \"$tmp\"; exit 1; fi\n"
    sh = sh + "if ! tar -xzf \"$tmp/b.tgz\" -C \"$tmp\"; then echo \"xi update: extract failed\"; rm -rf \"$tmp\"; exit 1; fi\n"
    sh = sh + "src=\"$tmp/$bundle\"\n"
    sh = sh + "if [ ! -x \"$src/libexec/xi\" ]; then echo \"xi update: unexpected bundle layout\"; rm -rf \"$tmp\"; exit 1; fi\n"
    sh = sh + "mv -f \"$src/libexec/xc\" \"$ROOT/libexec/xc\"\n"
    sh = sh + "mv -f \"$src/libexec/xi\" \"$ROOT/libexec/xi\"\n"
    sh = sh + "rm -rf \"$ROOT/runtime\" \"$ROOT/std\"\n"
    sh = sh + "mv -f \"$src/runtime\" \"$ROOT/runtime\"\n"
    sh = sh + "mv -f \"$src/std\" \"$ROOT/std\"\n"
    sh = sh + "if [ -d \"$src/bin\" ]; then cp -f \"$src/bin/xc\" \"$src/bin/xi\" \"$ROOT/bin/\" 2>/dev/null || true; fi\n"
    sh = sh + "chmod +x \"$ROOT/libexec/xc\" \"$ROOT/libexec/xi\" 2>/dev/null || true\n"
    sh = sh + "rm -rf \"$tmp\"\n"
    sh = sh + "echo \"xi updated: $CUR -> $ver\"\n"
    file_write("/tmp/xi-update.sh", sh)
    system.stdout.writeln("xi update: checking " + repo + " ...")
    flush_out()
    run_command("sh /tmp/xi-update.sh '" + repo + "' '" + root + "' '" + xiVersion() + "'")
}

// `xi skill` — fetch the latest Xi agent guide (docs/skill.md) from GitHub and
// print it to stdout, so it can be piped to a file or read by an AI agent.
// Status/errors go to stderr so stdout stays pure markdown (`xi skill > SKILL.md`).
consumer doSkill() {
    let repo = get_env("XI_SKILL_REPO", "code-by-sia/xi")
    let ref = get_env("XI_SKILL_REF", "main")
    let url = get_env("XI_SKILL_URL",
        "https://raw.githubusercontent.com/" + repo + "/" + ref + "/docs/skill.md")
    let tmp = "/tmp/xi-skill.md"
    let rc = run_command("curl -fsSL '" + url + "' -o '" + tmp + "'")
    if rc != 0 {
        system.stderr.writeln("xi skill: download failed (" + url + ")")
        system.stderr.writeln("  needs curl on PATH; override the source with XI_SKILL_URL.")
    } else {
        system.stdout.write(file_read_all(tmp))
    }
}

// Base name of a path: drop the directory and a trailing ".x".
mapper baseName(path: String) -> String {
    let n = string_len(path)
    let lastSp = 0 - 1
    let i = 0
    while i < n {
        if string_char_at(path, i) == 47 { lastSp = i }
        i = i + 1
    }
    return stripExt(string_slice(path, lastSp + 1, n))
}

// Compile the session program; return 0 on success. Writes /tmp/xrepl.x.
mapper compileSession(xc: String, rt: String, prog: String) -> Integer {
    file_write("/tmp/xrepl.x", prog)
    let cmd = "XC_OUT=/tmp XC_RUNTIME='" + rt + "' '" + xc + "' /tmp/xrepl.x >/tmp/xrepl.log 2>&1"
    return run_command(cmd)
}

// ── modes ────────────────────────────────────────────────────────

// Pull the built binary's path out of xc's "built executable <path>" line, so
// `xi file.xi` runs the right binary even when `module { id = ... }` renames it.
mapper builtPath(log: String) -> String {
    let marker = "built executable "
    let ml = string_len(marker)
    let n = string_len(log)
    let i = 0
    while i + ml <= n {
        if string_slice(log, i, i + ml) == marker {
            let j = i + ml
            let k = j
            while k < n and string_char_at(log, k) != 10 { k = k + 1 }
            return string_slice(log, j, k)
        }
        i = i + 1
    }
    return ""
}

// `xi test file.xi` — compile in test mode (XC_TEST=1) and run the test runner,
// forwarding its output and exit code (nonzero if any test failed).
producer runTests(xc: String, rt: String, path: String, filter: String) -> Integer {
    let cmd = "XC_TEST=1 XC_OUT=/tmp XC_RUNTIME='" + rt + "' '" + xc + "' '" + path + "' >/tmp/xtest.log 2>&1"
    let rc = run_command(cmd)
    let log = file_read_all("/tmp/xtest.log")
    if rc != 0 {
        system.stdout.writeln("xi test: compilation failed:")
        system.stdout.writeln(log)
        return 1
    }
    let bin = builtPath(log)
    if string_len(bin) == 0 { bin = "/tmp/" + baseName(path) }
    let pre = ""
    if string_len(filter) > 0 { pre = "XC_TEST_FILTER='" + filter + "' " }   // run only matching tests
    return run_command(pre + "'" + bin + "'")
}

// `xi test --all` — discover every *_test.xi under the current directory, run
// each, and report a project-wide pass/fail summary (nonzero exit on any fail).
producer runTestsAll(xc: String, rt: String) -> Integer {
    let sh = "set -u\n"
    sh = sh + "XC=\"$1\"; RT=\"$2\"; files=$(find . -name '*_test.xi' -not -path '*/build/*' -not -path '*/.git/*' | sort)\n"
    sh = sh + "if [ -z \"$files\" ]; then echo \"xi test: no *_test.xi files found\"; exit 0; fi\n"
    sh = sh + "fails=0; n=0\n"
    sh = sh + "for f in $files; do\n"
    sh = sh + "  n=$((n+1)); echo \"== $f ==\"\n"
    sh = sh + "  if ! XC_TEST=1 XC_OUT=/tmp XC_RUNTIME=\"$RT\" \"$XC\" \"$f\" >/tmp/xta.log 2>&1; then echo \"  compile failed:\"; cat /tmp/xta.log; fails=$((fails+1)); continue; fi\n"
    sh = sh + "  bin=$(grep 'built executable ' /tmp/xta.log | head -1 | sed 's/.*built executable //')\n"
    sh = sh + "  [ -z \"$bin\" ] && bin=\"/tmp/$(basename \"${f%.xi}\")\"\n"
    sh = sh + "  \"$bin\" || fails=$((fails+1))\n"
    sh = sh + "done\n"
    sh = sh + "echo; echo \"$n test file(s), $fails failed\"\n"
    sh = sh + "[ \"$fails\" -eq 0 ]\n"
    file_write("/tmp/xi-test-all.sh", sh)
    return run_command("sh /tmp/xi-test-all.sh '" + xc + "' '" + rt + "'")
}

consumer runFile(xc: String, rt: String, path: String) {
    let cmd = "XC_OUT=/tmp XC_RUNTIME='" + rt + "' '" + xc + "' '" + path + "' >/tmp/xrun.log 2>&1"
    let rc = run_command(cmd)
    let log = file_read_all("/tmp/xrun.log")
    if rc != 0 {
        system.stdout.writeln("x: compilation failed:")
        system.stdout.writeln(log)
    } else {
        let bin = builtPath(log)
        if string_len(bin) == 0 { bin = "/tmp/" + baseName(path) }
        run_command("'" + bin + "'")
    }
}

consumer repl(xc: String, rt: String) {
    system.stdout.writeln("Xi REPL — :help for commands, :quit to exit")
    let decls = ""
    let stmts = ""
    let prevLen = 0
    let running = true
    while running {
        system.stdout.write("x> ")
        flush_out()
        let line = read_line()
        if stdin_eof() {
            running = false
        } else {
            if isBlank(line) {
                // ignore
            } else {
                let cmd = firstWord(line)
                if cmd == ":quit" {
                    running = false
                } else {
                if cmd == ":help" {
                    system.stdout.writeln("  <decl>        define a type/function (persists)")
                    system.stdout.writeln("  <statement>   run a statement; use print(x) to show values")
                    system.stdout.writeln("  :reset        clear the session")
                    system.stdout.writeln("  :dump         show accumulated source")
                    system.stdout.writeln("  :quit         exit")
                } else {
                if cmd == ":reset" {
                    decls = ""
                    stmts = ""
                    prevLen = 0
                    system.stdout.writeln("(session cleared)")
                } else {
                if cmd == ":dump" {
                    system.stdout.writeln(buildProgram(decls, stmts))
                } else {
                    if isDeclLine(line) {
                        let trial = decls + line + "\n"
                        let rc = compileSession(xc, rt, buildProgram(trial, stmts))
                        if rc == 0 {
                            decls = trial
                            system.stdout.writeln("(defined)")
                        } else {
                            system.stdout.writeln("error:")
                            system.stdout.writeln(file_read_all("/tmp/xrepl.log"))
                        }
                    } else {
                        let trial = stmts + "    " + line + "\n"
                        let rc = compileSession(xc, rt, buildProgram(decls, trial))
                        if rc != 0 {
                            system.stdout.writeln("error:")
                            system.stdout.writeln(file_read_all("/tmp/xrepl.log"))
                        } else {
                            run_command("/tmp/xrepl >/tmp/xrepl.out 2>&1")
                            let out = file_read_all("/tmp/xrepl.out")
                            let total = string_len(out)
                            if total > prevLen {
                                system.stdout.write(string_slice(out, prevLen, total))
                                flush_out()
                            }
                            prevLen = total
                            stmts = trial
                        }
                    }
                }
                }
                }
                }
            }
        }
    }
    system.stdout.writeln("bye")
}
