/*
 * xc_helpers.c — typed array helpers for the X self-hosting compiler
 *
 * Appended after the generated C so it can see all struct definitions.
 * Implements every extern "C" function declared in compiler/*.x.
 *
 * Pattern:
 *   DEFINE_TYPED_ARR(ElemType, ArrType, BaseName)
 *   generates:
 *     BaseName(arr, elem) -> ArrType   (the push / append function)
 *     BaseName_len(arr) -> integer     (internal len helper)
 *     BaseName_get(arr, i) -> Elem     (internal get helper)
 *   The extern-declared xyzLen / xyzGet aliases call these.
 */

/* ─── Generic typed-array macro ─────────────────────────────────────────── */

/*
 * X arrays have VALUE semantics: a fat pointer { data, len, cap } is copied
 * by value, so many independent copies may share one `data` buffer.  Growing
 * in place (realloc) would free a buffer still referenced by other copies
 * (use-after-free).
 *
 * Append uses amortised capacity doubling so that accumulating N elements costs
 * O(N) memory and time, not O(N^2).  Two cases:
 *   - len < cap : the buffer has spare room we allocated for this purpose, so
 *     write in place and bump len.  Array *literals* always emit cap == len
 *     (no spare), so they fall to the grow branch and are never mutated — the
 *     in-place path only ever fires on an accumulator we ourselves grew.
 *   - len == cap: allocate a fresh, larger buffer, copy, and return a new fat
 *     pointer.  The old buffer is left intact (no free), preserving the value
 *     semantics of any other copies that still reference it.
 */
#define DEFINE_TYPED_ARR(ElemType, ArrType, BaseName)                         \
                                                                              \
ArrType BaseName(ArrType arr, ElemType elem) {                                \
    if (arr.len < arr.cap) {                                                  \
        arr.data[arr.len] = elem;                                             \
        arr.len += 1;                                                         \
        return arr;                                                           \
    }                                                                         \
    xc_size_t need = arr.len + 1;                                             \
    xc_size_t ncap = arr.cap ? arr.cap * 2 : 4;                               \
    if (ncap < need) ncap = need;                                             \
    ElemType* nd = (ElemType*)malloc(ncap * sizeof(ElemType));                \
    if (!nd) { fputs("xc: out of memory\n", stderr); abort(); }              \
    if (arr.len) memcpy(nd, arr.data, arr.len * sizeof(ElemType));            \
    nd[arr.len] = elem;                                                       \
    ArrType out; out.data = nd; out.len = need; out.cap = ncap;               \
    return out;                                                               \
}                                                                             \
                                                                              \
static xc_integer_t BaseName##_len(ArrType arr) {                             \
    return (xc_integer_t)arr.len;                                             \
}                                                                             \
                                                                              \
static ElemType BaseName##_get(ArrType arr, xc_integer_t i) {                 \
    if (i < 0 || (xc_size_t)i >= arr.len) {                                   \
        fprintf(stderr, "xc: index %lld out of bounds (len %zu)\n",           \
                (long long)i, arr.len);                                        \
        abort();                                                               \
    }                                                                          \
    return arr.data[(xc_size_t)i];                                            \
}

/* ─── Instantiate for every typed array used in xc.x ───────────────────── */

DEFINE_TYPED_ARR(xc_FieldSpec_t,   xc_arr_FieldSpec_t,   appendFieldSpec)
DEFINE_TYPED_ARR(xc_MethodSpec_t,  xc_arr_MethodSpec_t,  appendMethodSpec)
DEFINE_TYPED_ARR(xc_TypeSpec_t,    xc_arr_TypeSpec_t,    appendTypeSpec)
DEFINE_TYPED_ARR(xc_IfaceSpec_t,   xc_arr_IfaceSpec_t,   appendIfaceSpec)
DEFINE_TYPED_ARR(xc_DepSpec_t,     xc_arr_DepSpec_t,     appendDepSpec)
DEFINE_TYPED_ARR(xc_ClassSpec_t,   xc_arr_ClassSpec_t,   appendClassSpec)
DEFINE_TYPED_ARR(xc_BindSpec_t,    xc_arr_BindSpec_t,    appendBindSpec)
DEFINE_TYPED_ARR(xc_ModuleSpec_t,  xc_arr_ModuleSpec_t,  appendModuleSpec)
DEFINE_TYPED_ARR(xc_FuncSpec_t,    xc_arr_FuncSpec_t,    appendFuncSpec)
DEFINE_TYPED_ARR(xc_AtomSpec_t,    xc_arr_AtomSpec_t,    appendAtomSpec)
DEFINE_TYPED_ARR(xc_MachineSpec_t, xc_arr_MachineSpec_t, appendMachineSpec)
DEFINE_TYPED_ARR(xc_MachineTransition_t, xc_arr_MachineTransition_t, appendMachineTransition)
DEFINE_TYPED_ARR(xc_DecisionRow_t,   xc_arr_DecisionRow_t,   appendDecisionRow)
DEFINE_TYPED_ARR(xc_DecisionTable_t, xc_arr_DecisionTable_t, appendDecisionTable)

/* ─── Token array ────────────────────────────────────────────────────────── */

xc_arr_Token_t appendTokenC(xc_arr_Token_t arr, xc_Token_t tok) {
    if (arr.len < arr.cap) { arr.data[arr.len] = tok; arr.len += 1; return arr; }
    xc_size_t need = arr.len + 1;
    xc_size_t ncap = arr.cap ? arr.cap * 2 : 4;
    if (ncap < need) ncap = need;
    xc_Token_t* nd = (xc_Token_t*)malloc(ncap * sizeof(xc_Token_t));
    if (!nd) abort();
    if (arr.len) memcpy(nd, arr.data, arr.len * sizeof(xc_Token_t));
    nd[arr.len] = tok;
    xc_arr_Token_t out; out.data = nd; out.len = need; out.cap = ncap;
    return out;
}
xc_integer_t tokenArrLen(xc_arr_Token_t arr) { return (xc_integer_t)arr.len; }
xc_Token_t tokenArrGet(xc_arr_Token_t arr, xc_integer_t i) {
    if (i < 0 || (xc_size_t)i >= arr.len)
        return (xc_Token_t){ .kind = 0LL, .text = {NULL,0}, .line = 0LL };
    return arr.data[(xc_size_t)i];
}

/* ─── String array ───────────────────────────────────────────────────────── */

xc_arr_string_t appendString(xc_arr_string_t arr, xc_string_t s) {
    if (arr.len < arr.cap) { arr.data[arr.len] = s; arr.len += 1; return arr; }
    xc_size_t need = arr.len + 1;
    xc_size_t ncap = arr.cap ? arr.cap * 2 : 4;
    if (ncap < need) ncap = need;
    xc_string_t* nd = (xc_string_t*)malloc(ncap * sizeof(xc_string_t));
    if (!nd) abort();
    if (arr.len) memcpy(nd, arr.data, arr.len * sizeof(xc_string_t));
    nd[arr.len] = s;
    xc_arr_string_t out; out.data = nd; out.len = need; out.cap = ncap;
    return out;
}
xc_integer_t stringArrLen(xc_arr_string_t arr) { return (xc_integer_t)arr.len; }
xc_string_t stringArrGet(xc_arr_string_t arr, xc_integer_t i) {
    if (i < 0 || (xc_size_t)i >= arr.len) {
        fprintf(stderr, "stringArrGet: index %lld out of bounds (%zu)\n",
                (long long)i, arr.len);
        abort();
    }
    return arr.data[(xc_size_t)i];
}

/* ─── Len / Get aliases (match the extern "C" declarations in xc.x) ──────── */

xc_integer_t methodSpecLen(xc_arr_MethodSpec_t a) { return appendMethodSpec_len(a); }
xc_MethodSpec_t methodSpecGet(xc_arr_MethodSpec_t a, xc_integer_t i) { return appendMethodSpec_get(a, i); }

xc_integer_t depSpecLen(xc_arr_DepSpec_t a)    { return appendDepSpec_len(a); }
xc_DepSpec_t depSpecGet(xc_arr_DepSpec_t a, xc_integer_t i) { return appendDepSpec_get(a, i); }

xc_integer_t bindSpecLen(xc_arr_BindSpec_t a)  { return appendBindSpec_len(a); }
xc_BindSpec_t bindSpecGet(xc_arr_BindSpec_t a, xc_integer_t i) { return appendBindSpec_get(a, i); }

xc_integer_t typeSpecLen(xc_arr_TypeSpec_t a)  { return appendTypeSpec_len(a); }
xc_TypeSpec_t typeSpecGet(xc_arr_TypeSpec_t a, xc_integer_t i) { return appendTypeSpec_get(a, i); }

xc_integer_t ifaceSpecLen(xc_arr_IfaceSpec_t a){ return appendIfaceSpec_len(a); }
xc_IfaceSpec_t ifaceSpecGet(xc_arr_IfaceSpec_t a, xc_integer_t i) { return appendIfaceSpec_get(a, i); }

xc_integer_t classSpecLen(xc_arr_ClassSpec_t a){ return appendClassSpec_len(a); }
xc_ClassSpec_t classSpecGet(xc_arr_ClassSpec_t a, xc_integer_t i) { return appendClassSpec_get(a, i); }

xc_integer_t moduleSpecLen(xc_arr_ModuleSpec_t a) { return appendModuleSpec_len(a); }
xc_ModuleSpec_t moduleSpecGet(xc_arr_ModuleSpec_t a, xc_integer_t i) { return appendModuleSpec_get(a, i); }

xc_integer_t funcSpecLen(xc_arr_FuncSpec_t a)  { return appendFuncSpec_len(a); }
xc_FuncSpec_t funcSpecGet(xc_arr_FuncSpec_t a, xc_integer_t i) { return appendFuncSpec_get(a, i); }

xc_integer_t atomSpecLen(xc_arr_AtomSpec_t a)  { return appendAtomSpec_len(a); }
xc_AtomSpec_t atomSpecGet(xc_arr_AtomSpec_t a, xc_integer_t i) { return appendAtomSpec_get(a, i); }

xc_integer_t machineSpecLen(xc_arr_MachineSpec_t a)  { return appendMachineSpec_len(a); }
xc_MachineSpec_t machineSpecGet(xc_arr_MachineSpec_t a, xc_integer_t i) { return appendMachineSpec_get(a, i); }

xc_integer_t machineTransLen(xc_arr_MachineTransition_t a) { return appendMachineTransition_len(a); }
xc_MachineTransition_t machineTransGet(xc_arr_MachineTransition_t a, xc_integer_t i) { return appendMachineTransition_get(a, i); }

xc_integer_t decisionRowLen(xc_arr_DecisionRow_t a) { return appendDecisionRow_len(a); }
xc_DecisionRow_t decisionRowGet(xc_arr_DecisionRow_t a, xc_integer_t i) { return appendDecisionRow_get(a, i); }
xc_integer_t decisionTableLen(xc_arr_DecisionTable_t a) { return appendDecisionTable_len(a); }
xc_DecisionTable_t decisionTableGet(xc_arr_DecisionTable_t a, xc_integer_t i) { return appendDecisionTable_get(a, i); }

/* ─── String utility ─────────────────────────────────────────────────────── */

xc_integer_t findChar(xc_string_t s, xc_integer_t c) {
    for (xc_size_t i = 0; i < s.len; i++)
        if ((xc_integer_t)(unsigned char)s.data[i] == c) return (xc_integer_t)i;
    return (xc_integer_t)s.len;
}

/* ─── Invoke the C compiler to produce a native executable ──────────────────
 * Compiles the generated C (cpath) together with the X runtime into a native
 * binary (binpath).  The runtime directory is taken from the XC_RUNTIME
 * environment variable, defaulting to "xc/runtime" (relative to cwd).        */
#ifndef XC_RUNTIME_DEFAULT
#define XC_RUNTIME_DEFAULT "runtime"
#endif

/* Append the contents of `src` onto the end of file `dst`. */
static int append_file(const char* dst, const char* src) {
    FILE* in = fopen(src, "rb");
    if (!in) return 1;
    FILE* out = fopen(dst, "ab");
    if (!out) { fclose(in); return 1; }
    char buf[8192];
    size_t r;
    fputs("\n/* === appended helpers === */\n", out);
    while ((r = fread(buf, 1, sizeof(buf), in)) > 0) fwrite(buf, 1, r, out);
    fclose(in); fclose(out);
    return 0;
}

/* Scan the generated C for a `/​* XC-BUILD-FLAGS: ... *​/` marker (emitted from
   `extern "C"` build directives) and expand it into extra cc flags. Tokens:
     pkg:NAME  -> the output of `pkg-config --cflags --libs NAME`
     <other>   -> appended literally (e.g. -lsqlite3, -I/x, -L/y). */
static void xc_build_flags(const char* cpath, char* out, size_t outsz) {
    out[0] = '\0';
    FILE* f = fopen(cpath, "rb");
    if (!f) return;
    char line[4096];
    char content[2048]; content[0] = '\0';
    int scanned = 0;
    /* The marker is emitted as a top-level comment near the file head. Match
       only when the (whitespace-trimmed) line *starts* with it, so the same
       text appearing inside a string literal deep in the generated C — which
       happens when the compiler compiles its own codegen.xi — is ignored. */
    while (fgets(line, sizeof(line), f) && scanned < 60) {
        scanned++;
        const char* p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (strncmp(p, "/* XC-BUILD-FLAGS:", 18) == 0) {
            const char* m = p + 18;
            char* end = strstr(m, "*/");
            char tmp[2048];
            snprintf(tmp, sizeof(tmp), "%s", m);
            if (end) { size_t off = (size_t)(end - m); if (off < sizeof(tmp)) tmp[off] = '\0'; }
            snprintf(content, sizeof(content), "%s", tmp);
            break;
        }
    }
    fclose(f);
    if (!content[0]) return;
    size_t used = 0;
    char* save = NULL;
    char* tok = strtok_r(content, " \t\r\n", &save);
    while (tok && used + 1 < outsz) {
        if (strncmp(tok, "pkg:", 4) == 0) {
            char cmd[512];
            snprintf(cmd, sizeof(cmd), "pkg-config --cflags --libs %s 2>/dev/null", tok + 4);
            FILE* pf = popen(cmd, "r");
            if (pf) {
                char pbuf[1024];
                if (fgets(pbuf, sizeof(pbuf), pf)) {
                    pbuf[strcspn(pbuf, "\n")] = '\0';
                    int n = snprintf(out + used, outsz - used, " %s", pbuf);
                    if (n > 0) used += (size_t)n;
                }
                pclose(pf);
            }
        } else {
            int n = snprintf(out + used, outsz - used, " %s", tok);
            if (n > 0) used += (size_t)n;
        }
        tok = strtok_r(NULL, " \t\r\n", &save);
    }
}

/* Set an environment variable in the current process. The driver uses this to
   pass the selected `--target` through to compile_c (read via getenv below). */
xc_integer_t set_env(xc_string_t name, xc_string_t value) {
    char* nm = xc_string_to_cstr(name);
    char* vl = xc_string_to_cstr(value);
    int rc = setenv(nm, vl, 1);
    free(nm); free(vl);
    return (xc_integer_t)(rc == 0 ? 0 : 1);
}

xc_integer_t compile_c(xc_string_t cpath, xc_string_t binpath) {
    char* cp = xc_string_to_cstr(cpath);
    char* bp = xc_string_to_cstr(binpath);
    const char* dir = getenv("XC_RUNTIME");
    if (!dir || !dir[0]) dir = XC_RUNTIME_DEFAULT;

    /* If XC_HELPERS names a C file, append it onto the generated C so its
       definitions (which reference the generated structs) share the TU. */
    const char* helpers = getenv("XC_HELPERS");
    if (helpers && helpers[0]) append_file(cp, helpers);

    /* User FFI flags from `extern "C"` directives (link libs, -I/-L, pkg-config). */
    char extra[4096]; extra[0] = '\0';
    xc_build_flags(cp, extra, sizeof(extra));

    /* Optional TLS (std/web HTTPS): opt-in via XC_TLS so default builds stay
       dependency-light. When set, enable XC_HAVE_TLS and link OpenSSL — flags
       from pkg-config when available, else a portable fallback (incl. Homebrew). */
    char tls[2048]; tls[0] = '\0';
    const char* want_tls   = getenv("XC_TLS");
    const char* want_http2 = getenv("XC_HTTP2");   /* implies TLS */
    if ((want_tls && want_tls[0]) || (want_http2 && want_http2[0])) {
        char pkg[768] = "";
        if (system("pkg-config --exists openssl 2>/dev/null") == 0) {
            FILE* pf = popen("pkg-config --cflags --libs openssl 2>/dev/null", "r");
            if (pf) { if (fgets(pkg, sizeof(pkg), pf)) { pkg[strcspn(pkg, "\n")] = '\0'; } pclose(pf); }
        }
        if (pkg[0]) {
            snprintf(tls, sizeof(tls), "-DXC_HAVE_TLS %s", pkg);
        } else {
            /* Fallback: common Homebrew prefixes (keg-only) + plain link flags. */
            snprintf(tls, sizeof(tls),
                     "-DXC_HAVE_TLS "
                     "-I/opt/homebrew/opt/openssl@3/include -L/opt/homebrew/opt/openssl@3/lib "
                     "-I/usr/local/opt/openssl@3/include -L/usr/local/opt/openssl@3/lib "
                     "-lssl -lcrypto");
        }
        if (want_http2 && want_http2[0]) {
            char h2[768] = "";
            if (system("pkg-config --exists libnghttp2 2>/dev/null") == 0) {
                FILE* pf = popen("pkg-config --cflags --libs libnghttp2 2>/dev/null", "r");
                if (pf) { if (fgets(h2, sizeof(h2), pf)) { h2[strcspn(h2, "\n")] = '\0'; } pclose(pf); }
            }
            size_t tl = strlen(tls);
            if (h2[0]) snprintf(tls + tl, sizeof(tls) - tl, " -DXC_HAVE_HTTP2 %s", h2);
            else       snprintf(tls + tl, sizeof(tls) - tl,
                                " -DXC_HAVE_HTTP2 "
                                "-I/opt/homebrew/opt/nghttp2/include -L/opt/homebrew/opt/nghttp2/lib "
                                "-lnghttp2");
        }
    }

    /* ── WebAssembly target (XC_TARGET=wasm): compile the same generated C +
       runtime through Emscripten into <binpath>.{html,js,wasm}. Single-threaded,
       and without the native FFI/TLS link flags — host libraries (OpenSSL,
       -l<lib> from pkg-config, etc.) aren't available in the browser sandbox. */
    const char* target = getenv("XC_TARGET");
    if (target && strcmp(target, "wasm") == 0) {
        if (system("command -v emcc >/dev/null 2>&1") != 0) {
            fprintf(stderr,
                "xc: --target wasm needs Emscripten (emcc) on PATH.\n"
                "    install it with:  brew install emscripten\n"
                "    or see https://emscripten.org/docs/getting_started/downloads.html\n");
            free(cp); free(bp); return 1;
        }
        size_t wneed = strlen(cp) + strlen(bp) + 3 * strlen(dir) + 512;
        char* wcmd = (char*)malloc(wneed);
        if (!wcmd) { free(cp); free(bp); return 1; }
        snprintf(wcmd, wneed,
                 "emcc -std=c99 -O2 -w -Wno-implicit-int -Wno-implicit-function-declaration "
                 "-Wno-int-conversion -Wno-incompatible-pointer-types "
                 "-I%s %s %s/runtime.c -o %s.html -lm "
                 "-sALLOW_MEMORY_GROWTH=1 -sEXIT_RUNTIME=1 -sASYNCIFY",
                 dir, cp, dir, bp);
        int wrc = system(wcmd);
        free(wcmd); free(cp); free(bp);
        if (wrc == -1) return 1;
        return (xc_integer_t)(wrc == 0 ? 0 : 1);
    }

    /* cc -std=c99 -O2 -I<dir> <cpath> <dir>/runtime.c -o <binpath> -lm -lpthread [tls] */
    size_t need = strlen(cp) + strlen(bp) + 3 * strlen(dir) + strlen(tls) + strlen(extra) + 256;
    char* cmd = (char*)malloc(need);
    if (!cmd) { free(cp); free(bp); return 1; }
    /* -w plus explicit -Wno-* because GCC 14 (Ubuntu 24.04) promotes these to
       hard errors that -w no longer silences; macOS clang only warns. */
    snprintf(cmd, need,
             "cc -std=c99 -O2 -w -Wno-implicit-int -Wno-implicit-function-declaration "
             "-Wno-int-conversion -Wno-incompatible-pointer-types "
             "-I%s %s %s/runtime.c -o %s -lm -lpthread %s%s",
             dir, cp, dir, bp, tls, extra);

    int rc = system(cmd);
    free(cmd); free(cp); free(bp);
    if (rc == -1) return 1;
    return (xc_integer_t)(rc == 0 ? 0 : 1);
}

/* ============================================================================
 * Native backend primitives (used by impl/backend/*.xi via extern "C").
 *
 * These are compiled into `xc` itself, never into a user's output binary — the
 * native backend uses them to emit machine code and assemble a signed Mach-O
 * with no cc/ld. Provided here (not in the runtime) because only the compiler
 * builds executables:
 *   - a growable byte buffer, addressed by an integer handle;
 *   - a self-contained SHA-256 (for the ad-hoc code-signature slot hashes);
 *   - an executable file write (bytes + chmod +x).
 * Integer[]: appendInt mirrors appendString for building instruction words.
 * ==========================================================================*/
#include <sys/stat.h>
#include <stdint.h>

DEFINE_TYPED_ARR(xc_integer_t, xc_arr_integer_t, appendInt)

/* Indexed read/write for Integer[] — the encoder needs random access to patch
 * branch words after label positions are known, and the lowering keeps a
 * name->slot table in parallel arrays. setInt mutates in place (the encoder's
 * word buffer is freshly built and unshared). */
xc_integer_t intArrLen(xc_arr_integer_t a) { return (xc_integer_t)a.len; }
xc_integer_t intArrGet(xc_arr_integer_t a, xc_integer_t i) { return a.data[i]; }
xc_arr_integer_t setInt(xc_arr_integer_t a, xc_integer_t i, xc_integer_t v) { a.data[i] = v; return a; }

/* Heap append for the XIR value types, so arrays that escape a function (the
 * lowered module returned to the backend) survive — array *literals* get
 * block-scoped backing storage and must not be returned. Same pattern the
 * parser uses for its spec arrays. */
DEFINE_TYPED_ARR(xc_XInsn_t,       xc_arr_XInsn_t,       appendXInsn)
DEFINE_TYPED_ARR(xc_XBlock_t,      xc_arr_XBlock_t,      appendXBlock)
DEFINE_TYPED_ARR(xc_XFunc_t,       xc_arr_XFunc_t,       appendXFunc)
DEFINE_TYPED_ARR(xc_XVal_t,        xc_arr_XVal_t,        appendXVal)
DEFINE_TYPED_ARR(xc_XReloc_t,      xc_arr_XReloc_t,      appendXReloc)
DEFINE_TYPED_ARR(xc_EncodedFunc_t, xc_arr_EncodedFunc_t, appendEncodedFunc)

/* -- compact SHA-256 -- */
typedef struct { uint32_t s[8]; uint64_t n; unsigned char b[64]; size_t bl; } xcsha_t;
static uint32_t xcsha_ror(uint32_t x, int r) { return (x >> r) | (x << (32 - r)); }
static void xcsha_block(xcsha_t* c, const unsigned char* p) {
    static const uint32_t K[64] = {
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2 };
    uint32_t w[64];
    for (int i = 0; i < 16; i++)
        w[i] = ((uint32_t)p[i*4] << 24) | ((uint32_t)p[i*4+1] << 16) | ((uint32_t)p[i*4+2] << 8) | p[i*4+3];
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = xcsha_ror(w[i-15],7) ^ xcsha_ror(w[i-15],18) ^ (w[i-15] >> 3);
        uint32_t s1 = xcsha_ror(w[i-2],17) ^ xcsha_ror(w[i-2],19) ^ (w[i-2] >> 10);
        w[i] = w[i-16] + s0 + w[i-7] + s1;
    }
    uint32_t a=c->s[0],b=c->s[1],cc=c->s[2],d=c->s[3],e=c->s[4],f=c->s[5],g=c->s[6],h=c->s[7];
    for (int i = 0; i < 64; i++) {
        uint32_t S1 = xcsha_ror(e,6) ^ xcsha_ror(e,11) ^ xcsha_ror(e,25);
        uint32_t ch = (e & f) ^ ((~e) & g);
        uint32_t t1 = h + S1 + ch + K[i] + w[i];
        uint32_t S0 = xcsha_ror(a,2) ^ xcsha_ror(a,13) ^ xcsha_ror(a,22);
        uint32_t maj = (a & b) ^ (a & cc) ^ (b & cc);
        uint32_t t2 = S0 + maj;
        h=g; g=f; f=e; e=d+t1; d=cc; cc=b; b=a; a=t1+t2;
    }
    c->s[0]+=a; c->s[1]+=b; c->s[2]+=cc; c->s[3]+=d; c->s[4]+=e; c->s[5]+=f; c->s[6]+=g; c->s[7]+=h;
}
static void xcsha_init(xcsha_t* c) {
    c->s[0]=0x6a09e667; c->s[1]=0xbb67ae85; c->s[2]=0x3c6ef372; c->s[3]=0xa54ff53a;
    c->s[4]=0x510e527f; c->s[5]=0x9b05688c; c->s[6]=0x1f83d9ab; c->s[7]=0x5be0cd19;
    c->n=0; c->bl=0;
}
static void xcsha_update(xcsha_t* c, const unsigned char* p, size_t n) {
    c->n += n;
    while (n) { size_t k = 64 - c->bl; if (k > n) k = n;
        memcpy(c->b + c->bl, p, k); c->bl += k; p += k; n -= k;
        if (c->bl == 64) { xcsha_block(c, c->b); c->bl = 0; } }
}
static void xcsha_final(xcsha_t* c, unsigned char* out) {
    uint64_t bits = c->n * 8;                 /* capture length before padding */
    unsigned char pad = 0x80; xcsha_update(c, &pad, 1);
    unsigned char z = 0; while (c->bl != 56) xcsha_update(c, &z, 1);
    unsigned char L[8]; for (int i = 0; i < 8; i++) L[i] = (unsigned char)(bits >> (56 - 8*i));
    xcsha_update(c, L, 8);
    for (int i = 0; i < 8; i++) {
        out[i*4]   = (unsigned char)(c->s[i] >> 24); out[i*4+1] = (unsigned char)(c->s[i] >> 16);
        out[i*4+2] = (unsigned char)(c->s[i] >> 8);  out[i*4+3] = (unsigned char)(c->s[i]);
    }
}

/* -- growable byte buffer, addressed by handle -- */
#define XCB_MAX 16
static unsigned char* xcb_p[XCB_MAX];
static size_t xcb_l[XCB_MAX], xcb_c[XCB_MAX];
static int xcb_count = 0;
static void xcb_grow(int h, size_t extra) {
    if (xcb_l[h] + extra > xcb_c[h]) {
        size_t nc = xcb_c[h] ? xcb_c[h] : 256;
        while (nc < xcb_l[h] + extra) nc *= 2;
        xcb_p[h] = (unsigned char*)realloc(xcb_p[h], nc);
        xcb_c[h] = nc;
    }
}
xc_integer_t xcb_new(void) {
    int h = xcb_count++;
    xcb_p[h] = NULL; xcb_l[h] = 0; xcb_c[h] = 0;
    return (xc_integer_t)h;
}
void xcb_u8(xc_integer_t h, xc_integer_t v) { xcb_grow((int)h, 1); xcb_p[h][xcb_l[h]++] = (unsigned char)(v & 0xff); }
void xcb_u32(xc_integer_t h, xc_integer_t v)   { for (int i = 0; i < 4; i++) xcb_u8(h, (v >> (8*i)) & 0xff); }
void xcb_u64(xc_integer_t h, xc_integer_t v)   { for (int i = 0; i < 8; i++) xcb_u8(h, (v >> (8*i)) & 0xff); }
void xcb_u32be(xc_integer_t h, xc_integer_t v) { for (int i = 3; i >= 0; i--) xcb_u8(h, (v >> (8*i)) & 0xff); }
void xcb_u64be(xc_integer_t h, xc_integer_t v) { for (int i = 7; i >= 0; i--) xcb_u8(h, (v >> (8*i)) & 0xff); }
void xcb_zeros(xc_integer_t h, xc_integer_t n) { for (xc_integer_t i = 0; i < n; i++) xcb_u8(h, 0); }
void xcb_ascii(xc_integer_t h, xc_string_t s)  { for (size_t i = 0; i < s.len; i++) xcb_u8(h, (unsigned char)s.data[i]); }
xc_integer_t xcb_len(xc_integer_t h) { return (xc_integer_t)xcb_l[h]; }
void xcb_sha256_append(xc_integer_t h, xc_integer_t from, xc_integer_t to) {
    xcsha_t c; xcsha_init(&c); xcsha_update(&c, xcb_p[h] + from, (size_t)(to - from));
    unsigned char d[32]; xcsha_final(&c, d);
    xcb_grow((int)h, 32); memcpy(xcb_p[h] + xcb_l[h], d, 32); xcb_l[h] += 32;
}
/* Process-global string-constant pool for the native backend (one compile per
 * process). strpool_add stores the raw literal text (which outlives the compile
 * in the parsed program) and returns its id. */
static xc_string_t g_strpool[8192];
static int g_strpool_n = 0;
void         strpool_reset(void) { g_strpool_n = 0; }
xc_integer_t strpool_add(xc_string_t s) { g_strpool[g_strpool_n] = s; return (xc_integer_t)(g_strpool_n++); }
xc_integer_t strpool_len(void) { return (xc_integer_t)g_strpool_n; }
xc_string_t  strpool_get(xc_integer_t i) { return g_strpool[i]; }

/* Function/extern return-kind registry: 1 if the callee returns a String, so a
 * call site can size its result (x0 vs x0:x1). Names are interned by the parsed
 * program and outlive the compile. */
static xc_string_t g_fnsig_name[8192];
static int g_fnsig_ret[8192];
static int g_fnsig_n = 0;
void fnsig_reset(void) { g_fnsig_n = 0; }
void fnsig_add(xc_string_t name, xc_integer_t retStr) {
    g_fnsig_name[g_fnsig_n] = name; g_fnsig_ret[g_fnsig_n] = (int)retStr; g_fnsig_n++;
}
xc_integer_t fnsig_ret_str(xc_string_t name) {
    for (int i = g_fnsig_n - 1; i >= 0; i--) {
        if (g_fnsig_name[i].len == name.len && memcmp(g_fnsig_name[i].data, name.data, name.len) == 0)
            return g_fnsig_ret[i];
    }
    return 0;
}

/* Compound-type registry for the native backend: each type's fields, their kind
 * (0 Integer, 1 String, 2 array), and their slot offset within the value. */
#define CT_MAX 1024
#define CT_FMAX 64
static xc_string_t ct_name[CT_MAX];
static int ct_nf[CT_MAX];
static int ct_width[CT_MAX];
static xc_string_t ct_fname[CT_MAX][CT_FMAX];
static int ct_fkind[CT_MAX][CT_FMAX];
static int ct_foff[CT_MAX][CT_FMAX];
static int ct_ref[CT_MAX];   /* 1 = class (heap pointer), 2 = interface, 0 = inline compound */
static int ct_n = 0;
static int ct_streq(xc_string_t a, xc_string_t b) { return a.len == b.len && memcmp(a.data, b.data, a.len) == 0; }
void ctype_reset(void) { ct_n = 0; }
/* A class instance reserves slot 0 for a class-index header (used by dynamic
 * dispatch); its fields therefore start at offset 1. Compounds and interfaces
 * carry no header. */
xc_integer_t ctype_add(xc_string_t name, xc_integer_t isRef) { ct_name[ct_n] = name; ct_nf[ct_n] = 0; ct_width[ct_n] = ((int)isRef == 1) ? 1 : 0; ct_ref[ct_n] = (int)isRef; return (xc_integer_t)(ct_n++); }
xc_integer_t ctype_is_ref(xc_integer_t ti) { return ct_ref[(int)ti]; }
xc_string_t  ctype_name(xc_integer_t ti) { return ct_name[(int)ti]; }

/* Interface -> concrete class binding (single bind per interface). */
#define BIND_MAX 1024
static xc_string_t bind_iface[BIND_MAX], bind_cls[BIND_MAX];
static int bind_n = 0;
void bind_reset(void) { bind_n = 0; }
void bind_add(xc_string_t iface, xc_string_t cls) { bind_iface[bind_n] = iface; bind_cls[bind_n] = cls; bind_n++; }
xc_string_t bind_class(xc_string_t iface) {
    for (int i = 0; i < bind_n; i++) if (ct_streq(bind_iface[i], iface)) return bind_cls[i];
    return xc_string_from_cstr("");
}

/* Singleton classes: each shares one cached instance (indexed into the runtime
 * singleton table). */
#define SING_MAX 4096
static xc_string_t sing_name[SING_MAX];
static int sing_n = 0;
void sing_reset(void) { sing_n = 0; }
xc_integer_t sing_index(xc_string_t cls) {
    for (int i = 0; i < sing_n; i++) if (ct_streq(sing_name[i], cls)) return i;
    return -1;
}
xc_integer_t sing_mark(xc_string_t cls) {
    xc_integer_t existing = sing_index(cls);
    if (existing >= 0) return existing;
    sing_name[sing_n] = cls; return (xc_integer_t)(sing_n++);
}

/* Interface -> implementing classes (every class that `implements` it). Dynamic
 * dispatch switches over these; list injection constructs one of each. */
#define IMPL_MAX 8192
static int impl_iface[IMPL_MAX], impl_cls[IMPL_MAX];
static int impl_n = 0;
void iface_impl_reset(void) { impl_n = 0; }
void iface_impl_add(xc_integer_t ii, xc_integer_t ci) { impl_iface[impl_n] = (int)ii; impl_cls[impl_n] = (int)ci; impl_n++; }
xc_integer_t iface_nimpls(xc_integer_t ii) {
    int c = 0;
    for (int i = 0; i < impl_n; i++) if (impl_iface[i] == (int)ii) c++;
    return c;
}
xc_integer_t iface_impl_at(xc_integer_t ii, xc_integer_t k) {
    int c = 0;
    for (int i = 0; i < impl_n; i++) if (impl_iface[i] == (int)ii) { if (c == (int)k) return impl_cls[i]; c++; }
    return -1;
}
void ctype_add_field(xc_integer_t ti, xc_string_t fname, xc_integer_t fkind, xc_integer_t fwidth) {
    int t = (int)ti, f = ct_nf[t];
    ct_fname[t][f] = fname; ct_fkind[t][f] = (int)fkind; ct_foff[t][f] = ct_width[t];
    ct_width[t] += (int)fwidth; ct_nf[t]++;
}
xc_integer_t ctype_index(xc_string_t name) {
    for (int i = 0; i < ct_n; i++) if (ct_streq(ct_name[i], name)) return i;
    return -1;
}
xc_integer_t ctype_width(xc_integer_t ti) { return ct_width[(int)ti]; }
xc_integer_t ctype_field_off(xc_integer_t ti, xc_string_t fname) {
    int t = (int)ti;
    for (int f = 0; f < ct_nf[t]; f++) if (ct_streq(ct_fname[t][f], fname)) return ct_foff[t][f];
    return -1;
}
xc_integer_t ctype_field_kind(xc_integer_t ti, xc_string_t fname) {
    int t = (int)ti;
    for (int f = 0; f < ct_nf[t]; f++) if (ct_streq(ct_fname[t][f], fname)) return ct_fkind[t][f];
    return 0;
}
xc_integer_t ctype_nfields(xc_integer_t ti) { return ct_nf[(int)ti]; }
xc_integer_t ctype_field_kind_at(xc_integer_t ti, xc_integer_t f) { return ct_fkind[(int)ti][(int)f]; }
xc_integer_t ctype_field_off_at(xc_integer_t ti, xc_integer_t f) { return ct_foff[(int)ti][(int)f]; }

/* Unescape a source string literal (\n \t \r \0 \\ \" ...) — length, and append. */
xc_integer_t unescapedLen(xc_string_t s) {
    xc_integer_t n = 0;
    for (size_t i = 0; i < s.len; i++) { if (s.data[i] == '\\' && i + 1 < s.len) i++; n++; }
    return n;
}
void xcb_ascii_unescape(xc_integer_t h, xc_string_t s) {
    for (size_t i = 0; i < s.len; i++) {
        unsigned char c = (unsigned char)s.data[i];
        if (c == '\\' && i + 1 < s.len) {
            unsigned char d = (unsigned char)s.data[++i];
            if (d == 'n') c = '\n'; else if (d == 't') c = '\t';
            else if (d == 'r') c = '\r'; else if (d == '0') c = '\0'; else c = d;
        }
        xcb_u8(h, c);
    }
}
xc_integer_t xcb_write_exec(xc_integer_t h, xc_string_t path) {
    char* p = xc_string_to_cstr(path);
    FILE* f = fopen(p, "wb");
    if (!f) { free(p); return 1; }
    fwrite(xcb_p[h], 1, xcb_l[h], f);
    fclose(f);
    chmod(p, 0755);
    free(p);
    return 0;
}
