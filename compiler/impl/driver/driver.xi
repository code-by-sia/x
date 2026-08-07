// xc driver — multi-file import resolution + entry point
// ── Main entry ────────────────────────────────────────────────────

// ── Multi-file support: import resolution ────────────────────────
//
// `import "path.xi"` (top level) splices another file's declarations into the
// compilation unit.  Imports are resolved recursively and de-duplicated by
// path, so a diamond of imports includes each file once.  `namespace a.b`
// prefixes a file's top-level symbol names with `a_b__` so independently
// authored files can reuse short names without colliding (see applyNamespace).

// LoadResult carries the merged tokens, the visited-paths set (dedup), and a
// registry mapping qualified names "ns.Name" -> mangled "ns__Name" so that
// cross-file references can be collapsed after all files are merged.
type LoadResult = {
    tokens:  Token[],
    visited: String[],
    qnames:  String[],   // "ns.Name"
    qrepl:   String[]    // parallel: "ns__Name"
}

mapper concatTokens(a: Token[], b: Token[]) -> Token[] {
    let out = a
    let i = 0
    let n = tokenArrLen(b)
    while i < n {
        out = appendToken(out, tokenArrGet(b, i))
        i = i + 1
    }
    return out
}

mapper lastSlash(s: String) -> Integer {
    let n = string_len(s)
    let last = 0 - 1
    let i = 0
    while i < n {
        if string_char_at(s, i) == 47 { last = i }
        i = i + 1
    }
    return last
}

mapper dirOf(path: String) -> String {
    let ls = lastSlash(path)
    if ls < 0 { return "" }
    return string_slice(path, 0, ls)
}

mapper joinPath(dir: String, rel: String) -> String {
    if string_len(dir) == 0 { return rel }
    if string_len(rel) > 0 {
        if string_char_at(rel, 0) == 47 { return rel }
    }
    return dir + "/" + rel
}

mapper dropLast(a: String[]) -> String[] {
    let out: String[] = []
    let n = stringArrLen(a)
    let i = 0
    while i < n - 1 { out = appendString(out, stringArrGet(a, i))  i = i + 1 }
    return out
}

// Canonicalize a path: collapse `.` and `..` segments and `//`, so that the same
// file reached via different spellings (e.g. `a/./b`, `a/x/../b`, `./a/b`) maps
// to one key. This makes import de-duplication (the `visited` set) reliable.
mapper canonPath(p: String) -> String {
    let n = string_len(p)
    let abs = false
    if n > 0 and string_char_at(p, 0) == 47 { abs = true }
    let parts: String[] = []
    let start = 0
    let i = 0
    while i <= n {
        let atSep = false
        if i == n { atSep = true } else { if string_char_at(p, i) == 47 { atSep = true } }
        if atSep {
            if i > start {
                let seg = string_slice(p, start, i)
                if seg == "." {
                    // drop
                } else {
                    if seg == ".." {
                        let pl = stringArrLen(parts)
                        if pl > 0 and stringArrGet(parts, pl - 1) != ".." {
                            parts = dropLast(parts)
                        } else {
                            if not abs { parts = appendString(parts, "..") }
                        }
                    } else {
                        parts = appendString(parts, seg)
                    }
                }
            }
            start = i + 1
        }
        i = i + 1
    }
    let m = stringArrLen(parts)
    if m == 0 {
        if abs { return "/" }
        return "."
    }
    let out = ""
    if abs { out = "/" }
    let j = 0
    while j < m {
        if j > 0 { out = out + "/" }
        out = out + stringArrGet(parts, j)
        j = j + 1
    }
    return out
}

// Resolve an import: first relative to the importing file, then relative to the
// standard-library/search root in $XC_STD (default ".").  This lets programs
// `import "std/math.xi"` from anywhere the library is installed.
mapper resolveImport(dir: String, rel: String) -> String {
    let local = joinPath(dir, rel)
    if xstd_file_exists(local) { return local }
    let alt = joinPath(get_env("XC_STD", "."), rel)
    if xstd_file_exists(alt) { return alt }
    return local
}

predicate isDeclKw(k: Integer) {
    if k == 200 { return true }   // type
    if k == 201 { return true }   // interface
    if k == 202 { return true }   // class
    if k == 212 { return true }   // creator
    if k == 213 { return true }   // mapper
    if k == 214 { return true }   // projector
    if k == 215 { return true }   // predicate
    if k == 216 { return true }   // consumer
    if k == 217 { return true }   // producer
    if k == 218 { return true }   // reducer
    return false
}

// The dotted namespace name as written (e.g. "app.util"), or "" if none.
mapper scanNamespaceName(toks: Token[]) -> String {
    let i = 0
    let n = tokenArrLen(toks)
    while i < n {
        if tokenArrGet(toks, i).kind == 255 {   // namespace
            let name = ""
            let j = i + 1
            let cont = true
            while cont and j < n {
                let t = tokenArrGet(toks, j)
                if t.kind == 1 { name = name + t.text }
                else { if t.kind == 107 { name = name + "." } else { cont = false } }
                if cont { j = j + 1 }
            }
            return name
        }
        i = i + 1
    }
    return ""
}

// "app.util" -> "app_util"  (C-safe prefix)
mapper nsPrefixOf(nsName: String) -> String {
    let out = ""
    let i = 0
    let n = string_len(nsName)
    while i < n {
        let c = string_char_at(nsName, i)
        if c == 46 { out = out + "_" } else { out = out + string_slice(nsName, i, i + 1) }
        i = i + 1
    }
    return out
}

// Collect TOP-LEVEL declared names of a file (depth 0 only, so method names
// inside classes/interfaces are NOT namespaced — that would break dispatch).
mapper collectExports(toks: Token[]) -> String[] {
    let out: String[] = []
    let depth = 0
    let i = 0
    let n = tokenArrLen(toks)
    while i < n {
        let k = tokenArrGet(toks, i).kind
        if k == 102 {
            depth = depth + 1
        } else {
            if k == 103 {
                depth = depth - 1
            } else {
                if depth == 0 and isDeclKw(k) {
                    // The name follows the keyword, unless a function-level deps
                    // block `kind { ... } name(...)` comes first — skip over it.
                    let ni = i + 1
                    if tokenArrGet(toks, ni).kind == 102 {
                        let d2 = 1
                        ni = ni + 1
                        while d2 > 0 and ni < n {
                            let kk = tokenArrGet(toks, ni).kind
                            if kk == 102 { d2 = d2 + 1 }
                            if kk == 103 { d2 = d2 - 1 }
                            ni = ni + 1
                        }
                    }
                    let nameTok = tokenArrGet(toks, ni)
                    if nameTok.kind == 1 { out = appendString(out, nameTok.text) }
                }
            }
        }
        i = i + 1
    }
    return out
}

mapper renameTok(t: Token, prefix: String, exports: String[]) -> Token {
    if t.kind == 1 and strArrContains(exports, t.text) {
        return Token { kind: 1, text: prefix + "__" + t.text, line: t.line, file: t.file }
    }
    return t
}

// Tag every token of a freshly-lexed file with its source path, so codegen can
// emit `#line` directives that point C compiler errors back at the Xi source.
mapper stampFile(toks: Token[], path: String) -> Token[] {
    let out: Token[] = []
    let i = 0
    let n = tokenArrLen(toks)
    while i < n {
        let t = tokenArrGet(toks, i)
        out = appendToken(out, Token { kind: t.kind, text: t.text, line: t.line, file: path })
        i = i + 1
    }
    return out
}

// Read `path`, recursively splice imports, strip import/namespace lines, and
// apply namespace prefixing.  Returns merged tokens (no trailing EOF) plus the
// qualified-name registry for cross-file reference collapsing.
// Typed empty String[] (a bare `[]` is only valid in a typed context, not as
// a call argument, so we build it via a return-cast here).
creator emptyStrings() -> String[] => []


mapper concatStrings(a: String[], b: String[]) -> String[] {
    let out = a
    let i = 0
    let n = stringArrLen(b)
    while i < n {
        out = appendString(out, stringArrGet(b, i))
        i = i + 1
    }
    return out
}

// Collapse cross-file qualified references: IDENT(ns) '.' IDENT(name) whose
// "ns.name" is in the registry becomes a single IDENT(ns__name).
mapper collapseQualified(toks: Token[], qnames: String[], qrepl: String[]) -> Token[] {
    let out: Token[] = []
    let i = 0
    let n = tokenArrLen(toks)
    while i < n {
        let t = tokenArrGet(toks, i)
        if t.kind == 1 and i + 2 < n {
            let dot = tokenArrGet(toks, i + 1)
            let nm = tokenArrGet(toks, i + 2)
            if dot.kind == 107 and nm.kind == 1 {
                let q = t.text + "." + nm.text
                let idx = strArrIndexOf(qnames, q)
                if idx >= 0 {
                    out = appendToken(out, Token { kind: 1, text: stringArrGet(qrepl, idx), line: t.line, file: t.file })
                    i = i + 3
                } else {
                    out = appendToken(out, t)
                    i = i + 1
                }
            } else {
                out = appendToken(out, t)
                i = i + 1
            }
        } else {
            out = appendToken(out, t)
            i = i + 1
        }
    }
    return out
}

mapper strArrIndexOf(arr: String[], s: String) -> Integer {
    let i = 0
    let n = stringArrLen(arr)
    while i < n {
        if stringArrGet(arr, i) == s { return i }
        i = i + 1
    }
    return 0 - 1
}

// ── Module includes/excludes: glob-gather a module's source files ───────────
mapper baseNameOf(p: String) -> String {
    let n = string_len(p)
    let s = 0
    let i = 0
    while i < n { if string_char_at(p, i) == 47 { s = i + 1 }  i = i + 1 }
    return string_slice(p, s, n)
}
// A small glob matcher: `**`/`*` = all; `dir/**` = subtree; `dir/*` = one level;
// `*.ext` = by extension; otherwise an exact path or basename.
predicate globMatch(pat: String, rel: String) {
    let p = pat
    if p.startsWith2("./") { p = string_slice(p, 2, string_len(p)) }
    if p == "**" or p == "*" or string_len(p) == 0 { return true }
    if p.endsWith2("/**") {
        let pre = string_slice(p, 0, string_len(p) - 3)
        if rel == pre { return true }
        return rel.startsWith2(pre + "/")
    }
    if p.endsWith2("/*") {
        return rel.startsWith2(string_slice(p, 0, string_len(p) - 1))
    }
    if p.startsWith2("*.") {
        return rel.endsWith2(string_slice(p, 1, string_len(p)))
    }
    if p == rel { return true }
    if baseNameOf(rel) == p { return true }
    return false
}
predicate matchesAny(pats: String[], rel: String) {
    let i = 0
    let n = stringArrLen(pats)
    while i < n { if globMatch(stringArrGet(pats, i), rel) { return true }  i = i + 1 }
    return false
}
// True if `path` contains any .xi file (used to detect installed ./modules deps).
predicate dirHasXi(path: String) {
    return run_command("find '" + path + "' -name '*.xi' 2>/dev/null | grep -q .") == 0
}
predicate containsSub(s: String, sub: String) {
    let n = string_len(s)
    let m = string_len(sub)
    if m == 0 { return true }
    let i = 0
    while i + m <= n {
        if string_slice(s, i, i + m) == sub { return true }
        i = i + 1
    }
    return false
}
mapper splitLines(s: String) -> String[] {
    let out: String[] = []
    let n = string_len(s)
    let start = 0
    let i = 0
    while i < n {
        if string_char_at(s, i) == 10 {
            if i > start { out = appendString(out, string_slice(s, start, i)) }
            start = i + 1
        }
        i = i + 1
    }
    if n > start { out = appendString(out, string_slice(s, start, n)) }
    return out
}
mapper relPath(base: String, path: String) -> String {
    let pre = base + "/"
    if path.startsWith2(pre) { return string_slice(path, string_len(pre), string_len(path)) }
    if path.startsWith2("./") { return string_slice(path, 2, string_len(path)) }
    return path
}
// Union of includes / excludes declared by the program's (non-Test) modules.
mapper moduleGlobs(prog: Program, which: Integer) -> String[] {
    let out: String[] = []
    let i = 0
    let n = moduleSpecLen(prog.modules)
    while i < n {
        let mod = moduleSpecGet(prog.modules, i)
        if mod.name != "Test" {
            let lst = mod.includes
            if which == 1 { lst = mod.excludes }
            out = concatStrings(out, lst)
        }
        i = i + 1
    }
    return out
}

// ── Dependencies: `xi install` fetches module dependency archives ────────────
// Download one archive URL and extract it into ./modules (handles .tar.gz / .zip).
producer installOne(url: String) -> Integer {
    system.stdout.writeln("  fetching " + url)
    let sh = "set -e; mkdir -p modules; tmp=$(mktemp -d); "
    sh = sh + "if ! curl -fsSL '" + url + "' -o \"$tmp/a\"; then echo '  download failed'; rm -rf \"$tmp\"; exit 1; fi; "
    sh = sh + "case '" + url + "' in "
    sh = sh + "*.zip) unzip -oq \"$tmp/a\" -d modules ;; "
    sh = sh + "*) tar -xzf \"$tmp/a\" -C modules ;; "
    sh = sh + "esac; rm -rf \"$tmp\""
    return run_command(sh)
}

// Parse a module file and fetch every URL in its `dependencies` field.
producer installDeps(srcPath: String) -> Integer {
    let loader = Compile.resolve(ModuleLoader)
    let lr = loader.load(srcPath, emptyStrings())
    let collapsed = collapseQualified(lr.tokens, lr.qnames, lr.qrepl)
    let tokens = appendToken(collapsed, Token { kind: 0, text: "", line: 0 })
    let prog = parseProgram(tokens)
    let total = 0
    let fails = 0
    let i = 0
    let n = moduleSpecLen(prog.modules)
    while i < n {
        let deps = moduleSpecGet(prog.modules, i).dependencies
        let j = 0
        let dn = stringArrLen(deps)
        while j < dn {
            total = total + 1
            if installOne(stringArrGet(deps, j)) != 0 { fails = fails + 1 }
            j = j + 1
        }
        i = i + 1
    }
    if total == 0 {
        system.stdout.writeln("xi install: no dependencies declared in " + srcPath)
        return 0
    }
    system.stdout.writeln("xi install: " + int_to_string(total - fails) + "/" + int_to_string(total) + " fetched into ./modules")
    if fails > 0 { return 1 }
    return 0
}

// `xc --install` with no file: install deps for every buildable module found.
producer installAll() -> Integer {
    run_command("find . -name '*.xi' -not -path '*/build/*' -not -path '*/modules/*' -not -path '*/.git/*' | sort > /tmp/xi-inst.txt 2>/dev/null")
    let files = splitLines(file_read_all("/tmp/xi-inst.txt"))
    let xc = Compile.resolve(Compiler)
    let fails = 0
    let i = 0
    let n = stringArrLen(files)
    while i < n {
        let f = stringArrGet(files, i)
        if xc.isBuildable(f) {
            if installDeps(f) != 0 { fails = fails + 1 }
        }
        i = i + 1
    }
    if fails > 0 { return 1 }
    return 0
}

// ── `xc --pack` : build a shareable library archive ─────────────────────────
// Find the first .xi declaring a `library { }` block (for `xi pack` with no arg).
producer findLibraryFile() -> String {
    run_command("find . -name '*.xi' -not -path '*/modules/*' -not -path '*/build/*' -not -path '*/dist/*' -not -path '*/.git/*' | sort > /tmp/xi-pack-find.txt 2>/dev/null")
    let files = splitLines(file_read_all("/tmp/xi-pack-find.txt"))
    let i = 0
    let n = stringArrLen(files)
    while i < n {
        let f = stringArrGet(files, i)
        if containsSub(file_read_all(f), "library") {
            let loader = Compile.resolve(ModuleLoader)
            let lr = loader.load(f, emptyStrings())
            let collapsed = collapseQualified(lr.tokens, lr.qnames, lr.qrepl)
            let toks = appendToken(collapsed, Token { kind: 0, text: "", line: 0 })
            let prog = parseProgram(toks)
            if moduleSpecLen(prog.libraries) > 0 { return f }
        }
        i = i + 1
    }
    return ""
}
// name.xi -> name  (drop a trailing .xi for the default library id)
mapper stripXiExt(s: String) -> String {
    if s.endsWith2(".xi") { return string_slice(s, 0, string_len(s) - 3) }
    return s
}
// Gather the library's source per its includes/excludes and tar it into
// dist/<id>-<version>.tar.gz — a source archive ready to host and depend on.
producer packLibrary(srcPath: String) -> Integer {
    let path = srcPath
    if string_len(path) == 0 { path = findLibraryFile() }
    if string_len(path) == 0 {
        system.stdout.writeln("xi pack: no `library { }` manifest found (pass a file, or add a library block)")
        return 1
    }
    let loader = Compile.resolve(ModuleLoader)
    let lr = loader.load(path, emptyStrings())
    let collapsed = collapseQualified(lr.tokens, lr.qnames, lr.qrepl)
    let tokens = appendToken(collapsed, Token { kind: 0, text: "", line: 0 })
    let prog = parseProgram(tokens)
    if moduleSpecLen(prog.libraries) == 0 {
        system.stdout.writeln("xi pack: no `library { }` block in " + path)
        return 1
    }
    let lib = moduleSpecGet(prog.libraries, 0)
    let id = lib.id
    if string_len(id) == 0 { id = stripXiExt(baseNameOf(path)) }
    let ver = lib.version
    if string_len(ver) == 0 { ver = "0.0.0" }
    let inc = lib.includes
    if stringArrLen(inc) == 0 { inc = ["./**"] }
    let exc = lib.excludes
    let base = dirOf(path)
    if string_len(base) == 0 { base = "." }
    run_command("find '" + base + "' -name '*.xi' | sort > /tmp/xi-pack.txt 2>/dev/null")
    let files = splitLines(file_read_all("/tmp/xi-pack.txt"))
    let list = ""
    let count = 0
    let i = 0
    let n = stringArrLen(files)
    while i < n {
        let f = stringArrGet(files, i)
        let rel = relPath(base, f)
        if string_len(rel) > 0 and not rel.startsWith2("modules/") and not rel.startsWith2("dist/") and not rel.startsWith2("build/") and matchesAny(inc, rel) and not matchesAny(exc, rel) {
            list = list + rel + "\n"
            count = count + 1
        }
        i = i + 1
    }
    if count == 0 {
        system.stdout.writeln("xi pack: no source files matched includes/excludes")
        return 1
    }
    file_write("/tmp/xi-pack-list.txt", list)
    let out = "dist/" + id + "-" + ver + ".tar.gz"
    let sh = "mkdir -p dist && tar -czf '" + out + "' -C '" + base + "' -T /tmp/xi-pack-list.txt"
    if run_command(sh) != 0 {
        system.stdout.writeln("xi pack: tar failed")
        return 1
    }
    system.stdout.writeln("xi pack: wrote " + out + "  (" + int_to_string(count) + " files, library " + id + " " + ver + ")")
    return 0
}

// The toolchain version (kept in sync with the xi tool); printed by `xc version`.
mapper xcVersion() -> String { return "0.1.14" }

// The release codename, shown alongside the version.
mapper xcCodename() -> String { return "Berlin" }

// The value of a `--target <t>` / `--target=<t>` flag anywhere in args, or "".
mapper argTarget(args: String[]) -> String {
    let i = 1
    while i < args.len {
        let a = args.data[i]
        if a == "--target" and i + 1 < args.len { return args.data[i + 1] }
        if a.startsWith2("--target=") { return string_slice(a, 9, string_len(a)) }
        i = i + 1
    }
    return ""
}

// The value of a `--backend <b>` / `--backend=<b>` flag anywhere in args, or "".
mapper argBackend(args: String[]) -> String {
    let i = 1
    while i < args.len {
        let a = args.data[i]
        if a == "--backend" and i + 1 < args.len { return args.data[i + 1] }
        if a.startsWith2("--backend=") { return string_slice(a, 10, string_len(a)) }
        i = i + 1
    }
    return ""
}

// Is a bare flag present anywhere in the argument list?
predicate argHas(args: String[], flag: String) {
    let i = 1
    while i < args.len {
        if args.data[i] == flag { return true }
        i = i + 1
    }
    return false
}

// Every positional argument (subcommand or source paths), skipping flags: a
// `--target <t>` pair and bare `--…` switches. `xc a.xi b.xi` yields both, so
// one invocation can build several modules.
mapper cliSources(args: String[]) -> String[] {
    let out: String[] = []
    let i = 1
    while i < args.len {
        let a = args.data[i]
        if a == "--target" or a == "--backend" {
            i = i + 2
        } else {
            if a.startsWith2("--target=") or a.startsWith2("--backend=") or a == "--verbose" {
                i = i + 1
            } else {
                out = appendString(out, a)
                i = i + 1
            }
        }
    }
    return out
}

// The first positional argument (subcommand or source path), skipping over a
// `--target <t>` pair so `xc --target wasm app.xi` resolves `app.xi`.
mapper cliSource(args: String[]) -> String {
    let srcs = cliSources(args)
    if stringArrLen(srcs) == 0 { return "" }
    return stringArrGet(srcs, 0)
}


// The first non-empty module `id` in the program (used as the binary name), or "".
mapper moduleId(prog: Program) -> String {
    let i = 0
    let n = moduleSpecLen(prog.modules)
    while i < n {
        let m = moduleSpecGet(prog.modules, i)
        if string_len(m.id) > 0 { return m.id }
        i = i + 1
    }
    return ""
}

// Base name of a path: drop the directory and a trailing ".x" or ".xi".
mapper baseName(path: String) -> String {
    let ls = lastSlash(path)
    let start = ls + 1
    let n = string_len(path)
    let nm = string_slice(path, start, n)
    let m = string_len(nm)
    // ".xi"  (46='.', 120='x', 105='i')
    if m > 3 {
        if string_char_at(nm, m - 3) == 46 and string_char_at(nm, m - 2) == 120 and string_char_at(nm, m - 1) == 105 {
            return string_slice(nm, 0, m - 3)
        }
    }
    // ".x"
    if m > 2 {
        if string_char_at(nm, m - 2) == 46 and string_char_at(nm, m - 1) == 120 {
            return string_slice(nm, 0, m - 2)
        }
    }
    return nm
}
