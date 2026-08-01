// =============================================================
// loadtest — load/perf testing for Xi example projects (the `LoadTest` module)
//
//   loadtest --compile <file.xi> [more.xi ...]        compiler stress test
//   loadtest --bench   <file.xi> [--iters N]          run-binary benchmark
//   loadtest --http    <file.xi> [--url U] [--requests N]   HTTP load test
//
// Reads XC (compiler path) and XC_RUNTIME from the environment, like xi/xt.
// Dogfoods the standard library: std/time, std/http, std/convert, std/io.
// =============================================================

import "std/time.xi"
import "std/http.xi"
import "std/convert.xi"
import "std/io.xi"

extern "C" {
    mapper   run_command(cmd: String) -> Integer
    producer file_read_all(path: String) -> String
    mapper   get_env(name: String, dflt: String) -> String
    mapper   string_len(s: String) -> Integer
    mapper   string_char_at(s: String, i: Integer) -> Integer
    mapper   string_slice(s: String, from: Integer, to: Integer) -> String
}

// ── small helpers ─────────────────────────────────────────────────
mapper stripXi(path: String) -> String {
    let n = string_len(path)
    if n > 3 and string_char_at(path, n-3) == 46 and string_char_at(path, n-2) == 120 and string_char_at(path, n-1) == 105 {
        return string_slice(path, 0, n-3)
    }
    return path
}
mapper baseName(path: String) -> String {
    let n = string_len(path)
    let lastSp = 0 - 1
    let i = 0
    while i < n { if string_char_at(path, i) == 47 { lastSp = i }  i = i + 1 }
    return stripXi(string_slice(path, lastSp + 1, n))
}
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
mapper countLines(s: String) -> Integer {
    let n = string_len(s)
    let c = 0
    let i = 0
    while i < n { if string_char_at(s, i) == 10 { c = c + 1 }  i = i + 1 }
    return c
}
mapper parseIntOr(s: String, dflt: Integer) -> Integer {
    let n = string_len(s)
    if n == 0 { return dflt }
    let v = 0
    let i = 0
    while i < n {
        let c = string_char_at(s, i)
        if c >= 48 and c <= 57 { v = v * 10 + (c - 48) } else { return dflt }
        i = i + 1
    }
    return v
}
mapper us(ns: Integer) -> String { return convert.intToString(ns / 1000) + "us" }

// Compile a file (keeping the generated C) and return the binary path, or "".
producer compileFile(file: String) -> String {
    let xc = get_env("XC", "compiler/xc")
    let rt = get_env("XC_RUNTIME", "runtime")
    let cmd = "XC_OUT=/tmp XC_KEEP_C=1 XC_RUNTIME='" + rt + "' '" + xc + "' '" + file + "' >/tmp/lt.log 2>&1"
    if run_command(cmd) != 0 { return "" }
    let bin = builtPath(file_read_all("/tmp/lt.log"))
    if string_len(bin) == 0 { bin = "/tmp/" + baseName(file) }
    return bin
}

interface LoadTester {
    producer compileStress(args: String[], start: Integer) -> Integer
    producer bench(file: String, iters: Integer) -> Integer
    producer httpLoad(file: String, url: String, requests: Integer) -> Integer
}

class XiLoadTester implements LoadTester {
    deps {}

    // Compile each file, reporting compile time + generated-C size + ok/fail.
    producer compileStress(args: String[], start: Integer) -> Integer {
        let i = start
        let total = 0
        let fails = 0
        let slowest = ""
        let slowestNs = 0
        while i < args.len {
            let f = args.data[i]
            let t0 = time.nowNanos()
            let bin = compileFile(f)
            let dt = time.nowNanos() - t0
            total = total + 1
            if string_len(bin) == 0 {
                io.println("  FAIL  " + f)
                fails = fails + 1
            } else {
                let lines = countLines(file_read_all("/tmp/" + baseName(f) + ".gen.c"))
                io.println("  ok    " + f + "   " + convert.intToString(dt / 1000000) + " ms   " + convert.intToString(lines) + " C lines")
            }
            if dt > slowestNs { slowestNs = dt  slowest = f }
            i = i + 1
        }
        io.println("compile-stress: " + convert.intToString(total) + " file(s), " + convert.intToString(fails) + " failed; slowest " + slowest + " (" + convert.intToString(slowestNs / 1000000) + " ms)")
        if fails > 0 { return 1 }
        return 0
    }

    // Compile once, run the binary `iters` times, report min/mean/max run time.
    producer bench(file: String, iters: Integer) -> Integer {
        let bin = compileFile(file)
        if string_len(bin) == 0 { io.println("loadtest: compile failed: " + file)  return 1 }
        let minNs = 1000000000000
        let maxNs = 0
        let sumNs = 0
        let i = 0
        while i < iters {
            let t0 = time.nowNanos()
            run_command("'" + bin + "' >/dev/null 2>&1")
            let dt = time.nowNanos() - t0
            if dt < minNs { minNs = dt }
            if dt > maxNs { maxNs = dt }
            sumNs = sumNs + dt
            i = i + 1
        }
        io.println("bench " + file + " x" + convert.intToString(iters) + ":   min " + us(minNs) + "   mean " + us(sumNs / iters) + "   max " + us(maxNs))
        return 0
    }

    // Compile + start the server, fire `requests` sequential GETs, report
    // throughput + latency. (Concurrency via --conns is a future enhancement.)
    producer httpLoad(file: String, url: String, requests: Integer) -> Integer {
        let bin = compileFile(file)
        if string_len(bin) == 0 { io.println("loadtest: compile failed: " + file)  return 1 }
        let rt = get_env("XC_RUNTIME", "runtime")
        run_command("( XC_RUNTIME='" + rt + "' '" + bin + "' >/tmp/loadtest-srv.log 2>&1 & echo $! >/tmp/loadtest.pid )")
        time.sleepMs(700)            // give the server a moment to bind
        let minNs = 1000000000000
        let maxNs = 0
        let sumNs = 0
        let errors = 0
        let i = 0
        let t0all = time.nowNanos()
        while i < requests {
            let t0 = time.nowNanos()
            let r = http.get(url)
            let dt = time.nowNanos() - t0
            if isErr(r) {
                errors = errors + 1
            } else {
                if dt < minNs { minNs = dt }
                if dt > maxNs { maxNs = dt }
                sumNs = sumNs + dt
            }
            i = i + 1
        }
        let elapsed = time.nowNanos() - t0all
        run_command("kill $(cat /tmp/loadtest.pid) 2>/dev/null")
        let ok = requests - errors
        io.println("http-load " + url + ":   " + convert.intToString(requests) + " req, " + convert.intToString(errors) + " errors")
        if ok > 0 {
            let rps = ok * 1000000000 / elapsed
            io.println("   " + convert.intToString(rps) + " req/s   min " + us(minNs) + "   mean " + us(sumNs / ok) + "   max " + us(maxNs))
        }
        return 0
    }
}

module LoadTest {
    id           = "loadtest"
    name         = "Xi Load Tester"
    description  = "Load/perf testing for Xi projects: compile-stress, run-bench, and HTTP load."
    version      = "0.1.13"
    license      = "Apache 2.0"
    includes     = []
    excludes     = []
    dependencies = []

    bind LoadTester -> XiLoadTester as singleton

    entry main(args: String[]) -> Integer {
        let lt = LoadTest.resolve(LoadTester)
        if args.len < 2 {
            io.println("usage:")
            io.println("  loadtest --compile <file.xi> [more.xi ...]")
            io.println("  loadtest --bench   <file.xi> [--iters N]")
            io.println("  loadtest --http    <file.xi> [--url URL] [--requests N]")
            return 1
        }
        let mode = args.data[1]
        if mode == "--compile" {
            if args.len < 3 { io.println("loadtest --compile needs at least one file")  return 1 }
            return lt.compileStress(args, 2)
        }
        if mode == "--bench" {
            if args.len < 3 { io.println("loadtest --bench needs a file")  return 1 }
            let iters = 20
            if args.len >= 5 and args.data[3] == "--iters" { iters = parseIntOr(args.data[4], 20) }
            return lt.bench(args.data[2], iters)
        }
        if mode == "--http" {
            if args.len < 3 { io.println("loadtest --http needs a file")  return 1 }
            let url = "http://127.0.0.1:8080/"
            let requests = 200
            let i = 3
            while i + 1 < args.len {
                if args.data[i] == "--url" { url = args.data[i + 1] }
                if args.data[i] == "--requests" { requests = parseIntOr(args.data[i + 1], 200) }
                i = i + 1
            }
            return lt.httpLoad(args.data[2], url, requests)
        }
        io.println("loadtest: unknown mode " + mode)
        return 1
    }
}
