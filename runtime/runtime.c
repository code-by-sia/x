/*
 * runtime.c — X language runtime support implementation
 *
 * Contains functions that cannot be inlined in the header.
 */
#include "runtime.h"
#include <ctype.h>
#include <errno.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>

static xc_string_t xc_str_copy(const char* p, xc_size_t n);  /* defined below */

/* ─── Simple regex matching ──────────────────────────────────────────────── */

/*
 * Minimal regex engine supporting the constructs used in X refined types:
 *   .   any character
 *   *   zero or more of previous
 *   +   one or more of previous
 *   ?   zero or one of previous
 *   ^   start anchor (beginning of string)
 *   $   end anchor (end of string)
 *   [^...] negated character class
 *   \s  whitespace   \S  non-whitespace
 *   [...]  character class
 * All other characters are literal.
 *
 * This is not a full POSIX regex but covers the examples in the spec.
 */

static int regex_match_here(const char* re, const char* text);

static int regex_match_star(int c, const char* re, const char* text) {
    do {
        if (regex_match_here(re, text)) return 1;
    } while (*text != '\0' && (*text++ == c || c == '.'));
    return 0;
}

static int regex_match_plus(int c, const char* re, const char* text) {
    while (*text != '\0' && (*text == c || c == '.')) {
        text++;
        if (regex_match_here(re, text)) return 1;
    }
    return 0;
}

static int regex_char_in_class(const char* cls, char c, int *adv) {
    /* cls points after '['; returns 1 if c is in class, sets *adv to length consumed */
    int negate = 0;
    const char* p = cls;
    if (*p == '^') { negate = 1; p++; }
    int matched = 0;
    while (*p && *p != ']') {
        if (*(p+1) == '-' && *(p+2) && *(p+2) != ']') {
            if (c >= *p && c <= *(p+2)) matched = 1;
            p += 3;
        } else if (*p == '\\' && *(p+1)) {
            p++;
            switch (*p) {
                case 's': if (isspace(c)) matched = 1; break;
                case 'S': if (!isspace(c)) matched = 1; break;
                case 'd': if (isdigit(c)) matched = 1; break;
                case 'w': if (isalnum(c) || c == '_') matched = 1; break;
            }
            p++;
        } else {
            if (*p == c) matched = 1;
            p++;
        }
    }
    if (*p == ']') p++;
    *adv = (int)(p - cls);
    return negate ? !matched : matched;
}

static int regex_match_here(const char* re, const char* text) {
    if (re[0] == '\0') return 1;
    if (re[0] == '$' && re[1] == '\0') return *text == '\0';

    if (re[0] == '\\' && re[1] != '\0') {
        int matches = 0;
        switch (re[1]) {
            case 's': matches = isspace((unsigned char)*text); break;
            case 'S': matches = *text && !isspace((unsigned char)*text); break;
            case 'd': matches = isdigit((unsigned char)*text); break;
            case 'D': matches = *text && !isdigit((unsigned char)*text); break;
            case 'w': matches = isalnum((unsigned char)*text) || *text == '_'; break;
            case 'W': matches = *text && !isalnum((unsigned char)*text) && *text != '_'; break;
            default:  matches = (*text == re[1]); break;
        }
        if (re[2] == '*') return regex_match_star(re[1], re+3, text);
        if (re[2] == '+') return regex_match_plus(re[1], re+3, text);
        if (re[2] == '?') {
            if (matches && regex_match_here(re+3, text+1)) return 1;
            return regex_match_here(re+3, text);
        }
        return matches && regex_match_here(re+2, text+1);
    }

    if (re[0] == '[') {
        int adv = 0;
        int m = regex_char_in_class(re+1, *text, &adv);
        const char* after_class = re + 1 + adv;
        if (*after_class == '*') return regex_match_star('.', after_class+1, text);
        if (*after_class == '+') return regex_match_plus('.', after_class+1, text);
        if (*after_class == '?') {
            if (m && *text && regex_match_here(after_class+1, text+1)) return 1;
            return regex_match_here(after_class+1, text);
        }
        return *text && m && regex_match_here(after_class, text+1);
    }

    if (re[1] == '*') return regex_match_star(re[0], re+2, text);
    if (re[1] == '+') return regex_match_plus(re[0], re+2, text);
    if (re[1] == '?') {
        if ((*text == re[0] || re[0] == '.') && *text && regex_match_here(re+2, text+1)) return 1;
        return regex_match_here(re+2, text);
    }
    if ((re[0] == '.' && *text) || re[0] == *text)
        return regex_match_here(re+1, text+1);
    return 0;
}

xc_bool_t xc_string_matches(xc_string_t s, const char* pattern) {
    /* Null-terminate the string for regex matching */
    char* text = (char*)malloc(s.len + 1);
    if (!text) return false;
    memcpy(text, s.data, s.len);
    text[s.len] = '\0';

    int result = 0;
    if (pattern[0] == '^') {
        result = regex_match_here(pattern+1, text);
    } else {
        /* Try at each position */
        const char* t = text;
        do {
            if (regex_match_here(pattern, t)) { result = 1; break; }
        } while (*t++ != '\0');
    }
    free(text);
    return (xc_bool_t)result;
}

/* ─── File I/O ───────────────────────────────────────────────────────────── */

/* FFI bridge: Xi String <-> C cstring (const char*). Non-inline so user `extern
   "C"` declarations can link against them. xstd_cstr returns a NUL-terminated
   copy (heap); xstd_from_cstr copies the C string into a managed Xi string.

   xstd_cstr allocates from the *active arena* (per-request / per-thread / scope)
   like every other Xi value, so the copy is reclaimed in bulk when that arena is
   destroyed. It previously used plain malloc with no owner, which leaked one
   buffer per call — a server doing `toCString(sql)` on every query grew without
   bound under load. Callers must NOT free() the result; it is arena-owned.
   (The internal xc_string_to_cstr below stays plain malloc: its callers free it
   explicitly, and freeing an arena pointer would corrupt the heap.) */
const char* xstd_cstr(xc_string_t s) {
    char* buf = (char*)xc_heap_alloc(s.len + 1);
    if (!buf) abort();
    if (s.len) memcpy(buf, s.data, s.len);
    buf[s.len] = '\0';
    return buf;
}
xc_string_t xstd_from_cstr(const char* p) { return xc_string_from_cstr(p ? p : ""); }

xc_string_t file_read_all(xc_string_t path) {
    char* cpath = xc_string_to_cstr(path);
    FILE* fp = fopen(cpath, "rb");
    free(cpath);
    if (!fp) {
        fprintf(stderr, "xc: cannot open file: ");
        fwrite(path.data, 1, path.len, stderr);
        fprintf(stderr, "\n");
        abort();
    }
    if (fseek(fp, 0, SEEK_END) != 0) abort();
    long size = ftell(fp);
    if (size < 0) abort();
    rewind(fp);
    char* buf = (char*)xc_heap_alloc((size_t)size + 1);
    if (!buf) abort();
    (void)fread(buf, 1, (size_t)size, fp);
    buf[size] = '\0';
    fclose(fp);
    return (xc_string_t){ .data = buf, .len = (xc_size_t)size };
}

/* ─── Diagnostics ────────────────────────────────────────────────────────── */

static char xc_diag_file[4096] = "<input>";

void diag_set_file(xc_string_t path) {
    size_t n = path.len < sizeof(xc_diag_file) - 1 ? path.len : sizeof(xc_diag_file) - 1;
    if (n) memcpy(xc_diag_file, path.data, n);
    xc_diag_file[n] = '\0';
}

void diag_error(xc_integer_t line, xc_string_t msg) {
    fprintf(stderr, "xc: %s:%lld: error: %.*s\n",
            xc_diag_file, (long long)line, (int)msg.len, msg.data);
    exit(1);
}

/* Non-fatal diagnostic (compile continues). */
void diag_warn(xc_integer_t line, xc_string_t msg) {
    fprintf(stderr, "xc: %s:%lld: warning: %.*s\n",
            xc_diag_file, (long long)line, (int)msg.len, msg.data);
}

/* ─── Interrupts ─────────────────────────────────────────────────────────── */

xc_handler_t* xc_handlers = NULL;

xc_handler_t* xc_int_find(int type_id) {
    xc_handler_t* h = xc_handlers;
    while (h) { if (h->type_id == type_id) return h; h = h->prev; }
    return NULL;
}

void xc_int_unhandled(const char* name) {
    fprintf(stderr, "xc: unhandled interrupt: %s\n", name);
    exit(1);
}

xc_bool_t file_write(xc_string_t path, xc_string_t content) {
    char* cpath = xc_string_to_cstr(path);
    FILE* fp = fopen(cpath, "w");
    free(cpath);
    if (!fp) return false;
    fwrite(content.data, 1, content.len, fp);
    fclose(fp);
    return true;
}

xc_bool_t file_writeln(xc_string_t path, xc_string_t line) {
    char* cpath = xc_string_to_cstr(path);
    FILE* fp = fopen(cpath, "a");
    free(cpath);
    if (!fp) return false;
    fwrite(line.data, 1, line.len, fp);
    fputc('\n', fp);
    fclose(fp);
    return true;
}

/* ─── Filesystem ─────────────────────────────────────────────────────────── */

xc_bytes_t xstd_read_bytes(xc_string_t path) {
    char* cpath = xc_string_to_cstr(path);
    FILE* fp = fopen(cpath, "rb");
    free(cpath);
    if (!fp) return bytes_empty();
    if (fseek(fp, 0, SEEK_END) != 0) { fclose(fp); return bytes_empty(); }
    long size = ftell(fp);
    if (size < 0) { fclose(fp); return bytes_empty(); }
    rewind(fp);
    unsigned char* buf = (unsigned char*)malloc((size_t)size ? (size_t)size : 1);
    if (!buf) abort();
    (void)fread(buf, 1, (size_t)size, fp);
    fclose(fp);
    return (xc_bytes_t){ .data = buf, .len = (xc_size_t)size };
}

xc_bool_t xstd_write_bytes(xc_string_t path, xc_bytes_t b) {
    char* cpath = xc_string_to_cstr(path);
    FILE* fp = fopen(cpath, "wb");
    free(cpath);
    if (!fp) return false;
    if (b.len) fwrite(b.data, 1, b.len, fp);
    fclose(fp);
    return true;
}

xc_bool_t xstd_is_dir(xc_string_t path) {
    char* p = xc_string_to_cstr(path); struct stat st; int r = stat(p, &st); free(p);
    return r == 0 && S_ISDIR(st.st_mode);
}

xc_bool_t xstd_is_file(xc_string_t path) {
    char* p = xc_string_to_cstr(path); struct stat st; int r = stat(p, &st); free(p);
    return r == 0 && S_ISREG(st.st_mode);
}

xc_integer_t xstd_file_size(xc_string_t path) {
    char* p = xc_string_to_cstr(path); struct stat st; int r = stat(p, &st); free(p);
    return r == 0 ? (xc_integer_t)st.st_size : -1;
}

xc_integer_t xstd_mtime(xc_string_t path) {
    char* p = xc_string_to_cstr(path); struct stat st; int r = stat(p, &st); free(p);
    return r == 0 ? (xc_integer_t)st.st_mtime : -1;
}

xc_bool_t xstd_remove(xc_string_t path) {
    char* p = xc_string_to_cstr(path);
    int r = remove(p);            /* removes files and empty dirs */
    free(p);
    return r == 0;
}

xc_bool_t xstd_rename(xc_string_t from, xc_string_t to) {
    char* a = xc_string_to_cstr(from); char* b = xc_string_to_cstr(to);
    int r = rename(a, b);
    free(a); free(b);
    return r == 0;
}

xc_bool_t xstd_mkdir(xc_string_t path) {
    char* p = xc_string_to_cstr(path);
    int r = mkdir(p, 0777);
    free(p);
    return r == 0;
}

xc_bool_t xstd_mkdir_all(xc_string_t path) {
    char* p = xc_string_to_cstr(path);
    int ok = 1;
    for (char* s = p + 1; *s; s++) {
        if (*s == '/') {
            *s = '\0';
            if (mkdir(p, 0777) != 0 && errno != EEXIST) { ok = 0; break; }
            *s = '/';
        }
    }
    if (ok && mkdir(p, 0777) != 0 && errno != EEXIST) ok = 0;
    free(p);
    return ok != 0;
}

xc_string_t xstd_cwd(void) {
    char buf[4096];
    if (getcwd(buf, sizeof(buf))) return xc_str_copy(buf, strlen(buf));
    return xc_str_copy("", 0);
}

/* Directory entries (excluding "." and ".."), as String[]. Empty if not a dir. */
xc_arr_string_t xstd_list_dir(xc_string_t path) {
    xc_arr_string_t out = { NULL, 0, 0 };
    char* p = xc_string_to_cstr(path);
    DIR* d = opendir(p);
    free(p);
    if (!d) return out;
    struct dirent* e;
    while ((e = readdir(d)) != NULL) {
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;
        if (out.len == out.cap) {
            xc_size_t nc = out.cap ? out.cap * 2 : 8;
            out.data = (xc_string_t*)realloc(out.data, nc * sizeof(xc_string_t));
            if (!out.data) abort();
            out.cap = nc;
        }
        out.data[out.len++] = xc_str_copy(e->d_name, strlen(e->d_name));
    }
    closedir(d);
    return out;
}

/* ─── Networking (TCP, blocking) ─────────────────────────────────────────── */

xc_integer_t xstd_tcp_connect(xc_string_t host, xc_integer_t port) {
    char* h = xc_string_to_cstr(host);
    char portstr[16]; snprintf(portstr, sizeof(portstr), "%ld", (long)port);
    struct addrinfo hints, *res, *rp;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM;
    int gai = getaddrinfo(h, portstr, &hints, &res);
    free(h);
    if (gai != 0) return -1;
    int fd = -1;
    for (rp = res; rp; rp = rp->ai_next) {
        fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
        if (fd < 0) continue;
        if (connect(fd, rp->ai_addr, rp->ai_addrlen) == 0) break;
        close(fd); fd = -1;
    }
    freeaddrinfo(res);
    return (xc_integer_t)fd;
}

xc_integer_t xstd_tcp_listen(xc_integer_t port, xc_integer_t backlog) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int yes = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr; memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons((unsigned short)port);
    if (bind(fd, (struct sockaddr*)&addr, sizeof(addr)) != 0) { close(fd); return -1; }
    if (listen(fd, (int)backlog) != 0) { close(fd); return -1; }
    return (xc_integer_t)fd;
}

xc_integer_t xstd_tcp_accept(xc_integer_t fd) {
    return (xc_integer_t)accept((int)fd, NULL, NULL);
}

/* The local port a socket is bound to (useful after listening on port 0). */
xc_integer_t xstd_sock_port(xc_integer_t fd) {
    struct sockaddr_in addr; socklen_t len = sizeof(addr);
    if (getsockname((int)fd, (struct sockaddr*)&addr, &len) != 0) return -1;
    return (xc_integer_t)ntohs(addr.sin_port);
}

xc_integer_t xstd_sock_send(xc_integer_t fd, xc_bytes_t data) {
    return (xc_integer_t)send((int)fd, data.data, data.len, 0);
}

xc_bytes_t xstd_sock_recv(xc_integer_t fd, xc_integer_t max) {
    if (max <= 0) return bytes_empty();
    unsigned char* buf = (unsigned char*)xc_heap_alloc((size_t)max);
    if (!buf) abort();
    ssize_t n = recv((int)fd, buf, (size_t)max, 0);
    if (n <= 0) { free(buf); return bytes_empty(); }
    return (xc_bytes_t){ .data = buf, .len = (xc_size_t)n };
}

xc_bool_t xstd_sock_close(xc_integer_t fd) {
    return close((int)fd) == 0;
}

/* ─── REPL / tooling helpers ─────────────────────────────────────────────── */

static int g_stdin_eof = 0;

/* Read one line from stdin (newline stripped). Sets the EOF flag on end. */
xc_string_t read_line(void) {
    char buf[16384];
    if (!fgets(buf, sizeof(buf), stdin)) {
        g_stdin_eof = 1;
        return (xc_string_t){ .data = "", .len = 0 };
    }
    size_t n = strlen(buf);
    if (n && buf[n-1] == '\n') buf[--n] = '\0';
    char* c = (char*)xc_heap_alloc(n + 1);
    if (!c) abort();
    memcpy(c, buf, n + 1);
    return (xc_string_t){ .data = c, .len = n };
}

xc_bool_t stdin_eof(void) { return (xc_bool_t)g_stdin_eof; }

void flush_out(void) { fflush(stdout); }

/* Run a shell command; return 0 on success, 1 otherwise. */
xc_integer_t run_command(xc_string_t cmd) {
    char* c = xc_string_to_cstr(cmd);
    int rc = system(c);
    free(c);
    return (xc_integer_t)(rc == 0 ? 0 : 1);
}

/* Read an environment variable, or the given default if unset/empty. */
xc_string_t get_env(xc_string_t name, xc_string_t dflt) {
    char* nm = xc_string_to_cstr(name);
    const char* v = getenv(nm);
    free(nm);
    if (!v || !v[0]) return dflt;
    return xc_string_from_cstr(strdup(v));
}

/* ─── String helpers (non-inline) ────────────────────────────────────────── */

xc_string_t xc_string_substring(xc_string_t s, xc_size_t from, xc_size_t to) {
    if (from > s.len) from = s.len;
    if (to > s.len) to = s.len;
    if (from > to) to = from;
    return xc_string_from_buf(s.data + from, to - from);
}

xc_string_t xc_string_trim(xc_string_t s) {
    const char* p = s.data;
    const char* end = s.data + s.len;
    while (p < end && isspace((unsigned char)*p)) p++;
    while (end > p && isspace((unsigned char)*(end-1))) end--;
    return xc_string_from_buf(p, (xc_size_t)(end - p));
}

xc_bool_t xc_string_starts_with(xc_string_t s, xc_string_t prefix) {
    if (prefix.len > s.len) return false;
    return memcmp(s.data, prefix.data, prefix.len) == 0;
}

xc_bool_t xc_string_ends_with(xc_string_t s, xc_string_t suffix) {
    if (suffix.len > s.len) return false;
    return memcmp(s.data + s.len - suffix.len, suffix.data, suffix.len) == 0;
}

xc_bool_t xc_string_contains(xc_string_t haystack, xc_string_t needle) {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    for (xc_size_t i = 0; i + needle.len <= haystack.len; i++) {
        if (memcmp(haystack.data + i, needle.data, needle.len) == 0) return true;
    }
    return false;
}

/* ─── String + number conversion ─────────────────────────────────────────── */

xc_opt_number_t xc_parse_number(xc_string_t s) {
    char* buf = xc_string_to_cstr(s);
    char* end;
    errno = 0;
    double val = strtod(buf, &end);
    free(buf);
    if (errno != 0 || end == buf) return (xc_opt_number_t){ .has_value = false };
    return (xc_opt_number_t){ .has_value = true, .value = val };
}

xc_opt_integer_t xc_parse_integer(xc_string_t s) {
    char* buf = xc_string_to_cstr(s);
    char* end;
    errno = 0;
    long long val = strtoll(buf, &end, 10);
    free(buf);
    if (errno != 0 || end == buf) return (xc_opt_integer_t){ .has_value = false };
    return (xc_opt_integer_t){ .has_value = true, .value = (xc_integer_t)val };
}

/* ─── Standard library primitives (xstd_*) ──────────────────────────────────
 * Clean, X-friendly signatures (Integer/Number/Bool/String) wrapping libc/libm
 * and the existing runtime, so the X-source stdlib in std/*.x can extern them. */
#include <time.h>

/* math */
xc_number_t xstd_sqrt (xc_number_t x)              { return sqrt(x); }
xc_number_t xstd_pow  (xc_number_t x, xc_number_t y){ return pow(x, y); }
xc_number_t xstd_exp  (xc_number_t x)              { return exp(x); }
xc_number_t xstd_ln   (xc_number_t x)              { return log(x); }
xc_number_t xstd_log10(xc_number_t x)              { return log10(x); }
xc_number_t xstd_sin  (xc_number_t x)              { return sin(x); }
xc_number_t xstd_cos  (xc_number_t x)              { return cos(x); }
xc_number_t xstd_tan  (xc_number_t x)              { return tan(x); }
xc_number_t xstd_floor(xc_number_t x)              { return floor(x); }
xc_number_t xstd_ceil (xc_number_t x)              { return ceil(x); }
xc_number_t xstd_round(xc_number_t x)              { return round(x); }
xc_number_t xstd_fabs (xc_number_t x)              { return fabs(x); }
xc_number_t xstd_pi   (void)                       { return 3.14159265358979323846; }
xc_number_t xstd_e    (void)                       { return 2.71828182845904523536; }

/* text */
xc_integer_t xstd_strlen(xc_string_t s) { return (xc_integer_t)s.len; }

xc_integer_t xstd_char_at(xc_string_t s, xc_integer_t i) {
    if (i < 0 || (xc_size_t)i >= s.len) return -1;
    return (xc_integer_t)(unsigned char)s.data[i];
}

xc_string_t xstd_substring(xc_string_t s, xc_integer_t from, xc_integer_t to) {
    if (from < 0) from = 0;
    if (to > (xc_integer_t)s.len) to = (xc_integer_t)s.len;
    if (from >= to) return (xc_string_t){ .data = "", .len = 0 };
    xc_size_t n = (xc_size_t)(to - from);
    char* b = (char*)xc_heap_alloc(n + 1);
    if (!b) abort();
    memcpy(b, s.data + from, n); b[n] = '\0';
    return (xc_string_t){ .data = b, .len = n };
}

xc_string_t xstd_trim(xc_string_t s) {
    xc_size_t a = 0, b = s.len;
    while (a < b && isspace((unsigned char)s.data[a])) a++;
    while (b > a && isspace((unsigned char)s.data[b-1])) b--;
    return xstd_substring(s, (xc_integer_t)a, (xc_integer_t)b);
}

xc_bool_t xstd_starts_with(xc_string_t s, xc_string_t p) {
    if (p.len > s.len) return false;
    return memcmp(s.data, p.data, p.len) == 0;
}
xc_bool_t xstd_ends_with(xc_string_t s, xc_string_t p) {
    if (p.len > s.len) return false;
    return memcmp(s.data + s.len - p.len, p.data, p.len) == 0;
}
xc_integer_t xstd_index_of(xc_string_t s, xc_string_t n) {
    if (n.len == 0) return 0;
    if (n.len > s.len) return -1;
    for (xc_size_t i = 0; i + n.len <= s.len; i++)
        if (memcmp(s.data + i, n.data, n.len) == 0) return (xc_integer_t)i;
    return -1;
}
xc_bool_t xstd_contains(xc_string_t s, xc_string_t n) { return xstd_index_of(s, n) >= 0; }

/* Character-level helpers (operate on a char code, as from text.charAt). */
xc_bool_t xstd_is_alpha(xc_integer_t c) { return (xc_bool_t)(isalpha((int)c) != 0); }
xc_bool_t xstd_is_digit(xc_integer_t c) { return (xc_bool_t)(isdigit((int)c) != 0); }
xc_bool_t xstd_is_alnum(xc_integer_t c) { return (xc_bool_t)(isalnum((int)c) != 0); }
xc_bool_t xstd_is_space(xc_integer_t c) { return (xc_bool_t)(isspace((int)c) != 0); }
/* Index of the first occurrence of char code `c` in `s`, or -1. */
xc_integer_t xstd_index_of_char(xc_string_t s, xc_integer_t c) {
    for (xc_size_t i = 0; i < s.len; i++)
        if ((unsigned char)s.data[i] == (unsigned char)c) return (xc_integer_t)i;
    return -1;
}
/* One-character string from a char code. */
xc_string_t xstd_from_char(xc_integer_t c) {
    char* b = (char*)xc_heap_alloc(2);
    if (!b) abort();
    b[0] = (char)c; b[1] = '\0';
    return (xc_string_t){ .data = b, .len = 1 };
}

xc_string_t xstd_to_upper(xc_string_t s) {
    char* b = (char*)xc_heap_alloc(s.len + 1); if (!b) abort();
    for (xc_size_t i = 0; i < s.len; i++) b[i] = (char)toupper((unsigned char)s.data[i]);
    b[s.len] = '\0';
    return (xc_string_t){ .data = b, .len = s.len };
}
xc_string_t xstd_to_lower(xc_string_t s) {
    char* b = (char*)xc_heap_alloc(s.len + 1); if (!b) abort();
    for (xc_size_t i = 0; i < s.len; i++) b[i] = (char)tolower((unsigned char)s.data[i]);
    b[s.len] = '\0';
    return (xc_string_t){ .data = b, .len = s.len };
}
xc_string_t xstd_repeat(xc_string_t s, xc_integer_t n) {
    if (n <= 0 || s.len == 0) return (xc_string_t){ .data = "", .len = 0 };
    /* `s.len * n` is attacker-reachable whenever the count comes from input. An
       overflowing product used to wrap to a small size, under-allocate, and then
       let the copy loop write far past the block — refuse it instead. */
    if ((xc_size_t)n > ((xc_size_t)-1 - 1) / s.len) {
        fprintf(stderr, "xc: repeat(): result too large (%llu x %llu)\n",
                (unsigned long long)s.len, (unsigned long long)n);
        abort();
    }
    xc_size_t total = s.len * (xc_size_t)n;
    char* b = (char*)xc_heap_alloc(total + 1); if (!b) abort();
    for (xc_integer_t i = 0; i < n; i++) memcpy(b + (xc_size_t)i * s.len, s.data, s.len);
    b[total] = '\0';
    return (xc_string_t){ .data = b, .len = total };
}
xc_string_t xstd_replace(xc_string_t s, xc_string_t a, xc_string_t b) {
    if (a.len == 0) return s;
    /* count occurrences */
    xc_size_t count = 0;
    for (xc_size_t i = 0; i + a.len <= s.len; ) {
        if (memcmp(s.data + i, a.data, a.len) == 0) { count++; i += a.len; } else i++;
    }
    if (count == 0) return s;
    xc_size_t out_len = s.len + count * (b.len > a.len ? (b.len - a.len) : 0)
                              - count * (a.len > b.len ? (a.len - b.len) : 0);
    char* out = (char*)xc_heap_alloc(out_len + 1); if (!out) abort();
    xc_size_t oi = 0;
    for (xc_size_t i = 0; i < s.len; ) {
        if (i + a.len <= s.len && memcmp(s.data + i, a.data, a.len) == 0) {
            memcpy(out + oi, b.data, b.len); oi += b.len; i += a.len;
        } else out[oi++] = s.data[i++];
    }
    out[oi] = '\0';
    return (xc_string_t){ .data = out, .len = oi };
}

/* Heap-copy a byte range into a fresh NUL-terminated xc_string_t. */
/* ─── Per-thread arena (share-nothing thread cleanup) ─────────────────────────
 * Value allocations (strings, JSON nodes — things that are never individually
 * freed) come from the current thread's arena when one is active. A spawned
 * thread runs with its own arena and the whole arena is freed when the thread
 * finishes, reclaiming everything that thread allocated. The main thread has no
 * arena (xc_tls_arena == NULL), so its allocations are plain malloc / leak-on-
 * exit exactly as before — non-threaded programs are unaffected. This is safe
 * because threads are share-nothing: data crossing a channel is *copied* (the
 * channel node and the recv result are independent allocations), so nothing a
 * thread frees on exit is still referenced elsewhere. */
typedef struct xc_ablock { struct xc_ablock* next; size_t used, cap; } xc_ablock;
typedef struct xc_arena  { xc_ablock* head; } xc_arena;
static __thread xc_arena* xc_tls_arena = NULL;

static void* xc_arena_alloc(size_t n) {
    xc_arena* a = xc_tls_arena;
    if (!a) return malloc(n);                 /* main / no arena: leak-on-exit */
    n = (n + 7) & ~((size_t)7);               /* 8-byte align */
    if (!a->head || a->head->used + n > a->head->cap) {
        size_t cap = n > 65536 ? n : 65536;
        xc_ablock* b = (xc_ablock*)malloc(sizeof(xc_ablock) + cap);
        if (!b) abort();
        b->next = a->head; b->used = 0; b->cap = cap; a->head = b;
    }
    void* p = (char*)(a->head + 1) + a->head->used;
    a->head->used += n;
    return p;
}
static xc_arena* xc_arena_new(void) {
    xc_arena* a = (xc_arena*)malloc(sizeof(xc_arena)); if (!a) abort();
    a->head = NULL; return a;
}
static void xc_arena_destroy(xc_arena* a) {
    xc_ablock* b = a->head;
    while (b) { xc_ablock* nx = b->next; free(b); b = nx; }
    free(a);
}
/* Arena-aware grow. With an active arena we can't realloc a bump-allocated
   block, so allocate a fresh one and copy the live prefix; the old block is
   reclaimed when the arena is destroyed. Without an arena, plain realloc. Used
   by the JSON object/array backing arrays (xj_grow) and the stringify buffer
   (xj_sb) — request-scoped scratch whose result is copied out before the arena
   is freed. (oldn = bytes to preserve.) */
static void* xc_arena_regrow(void* old, size_t oldn, size_t newn) {
    if (!xc_tls_arena) return realloc(old, newn);
    void* p = xc_arena_alloc(newn);
    if (old && oldn) memcpy(p, old, oldn);
    return p;
}
/* ── Container buffer allocation (List/Stack/Queue/SortedQueue/Set/Map) ──────
 * Provenance follows the *container*, decided at construction: a container
 * created inside a request/thread/scope arena keeps its backing storage in the
 * (current) arena — so per-request collections are reclaimed in bulk instead of
 * leaking — while a container created outside any arena (module singletons,
 * main-thread state) stays on plain malloc/realloc forever, so mutating it from
 * inside a request never moves its storage into memory that dies with the
 * request. If an arena-born container is grown when no arena is active, its
 * buffer is copied out to malloc and the container becomes malloc-owned from
 * then on (flag flips) — the old block belongs to its (gone) arena.        */
static void* xc_cbuf_grow(int* arena_flag, void* old, size_t oldn, size_t newn) {
    if (!*arena_flag) { void* p = realloc(old, newn); if (!p) abort(); return p; }
    if (xc_tls_arena) {
        void* p = xc_arena_alloc(newn);
        if (old && oldn) memcpy(p, old, oldn);
        return p;
    }
    void* p = malloc(newn); if (!p) abort();
    if (old && oldn) memcpy(p, old, oldn);
    *arena_flag = 0;                     /* copied out: malloc-owned from now on */
    return p;
}
/* zeroed variant for hash tables; same provenance rules */
static void* xc_cbuf_alloc0(int* arena_flag, size_t n) {
    if (*arena_flag && xc_tls_arena) { void* p = xc_arena_alloc(n); memset(p, 0, n); return p; }
    void* p = calloc(n, 1); if (!p) abort();
    *arena_flag = 0;
    return p;
}
/* ── Reference counting (Phase 3; opt-in via -DXC_ARC) ───────────────────────
 * See runtime.h for the model. With XC_ARC off these are malloc / no-ops, so
 * behaviour and generated output are unchanged. */
#ifdef XC_ARC
#define XC_RC_MAGIC    0x58524321u   /* "XRC!" */
#define XC_RC_IMMORTAL 0xFFFFFFFFu
void* xc_rc_alloc(size_t n) {
    xc_rc_hdr* h = (xc_rc_hdr*)malloc(sizeof(xc_rc_hdr) + n); if (!h) abort();
    h->rc = 1; h->magic = XC_RC_MAGIC; return (void*)(h + 1);
}
void* xc_rc_immortal(size_t n) {
    xc_rc_hdr* h = (xc_rc_hdr*)malloc(sizeof(xc_rc_hdr) + n); if (!h) abort();
    h->rc = XC_RC_IMMORTAL; h->magic = XC_RC_MAGIC; return (void*)(h + 1);
}
void xc_retain(const void* p) {
    if (!p) return;
    xc_rc_hdr* h = ((xc_rc_hdr*)p) - 1;
    if (h->magic == XC_RC_MAGIC && h->rc != XC_RC_IMMORTAL) h->rc++;
}
void xc_release(const void* p) {
    if (!p) return;
    xc_rc_hdr* h = ((xc_rc_hdr*)p) - 1;
    if (h->magic == XC_RC_MAGIC && h->rc != XC_RC_IMMORTAL && --h->rc == 0) free(h);
}
#else
void* xc_rc_alloc(size_t n)    { return malloc(n); }
void* xc_rc_immortal(size_t n) { return malloc(n); }
void  xc_retain(const void* p)  { (void)p; }
void  xc_release(const void* p) { (void)p; }
#endif

/* Public boxed-instance allocator. Generated xc_new_<Class> calls this (it lives
   in a separate translation unit and can't see the static arena helpers), so DI
   instances created inside a thread/request arena are reclaimed with it; on the
   main thread (no arena) it is an rc-managed block under XC_ARC, else plain
   malloc, exactly as before. */
/* General value allocator: the active thread/request/scope arena when one is
   installed (reclaimed in bulk by that arena), else an rc-managed block under
   XC_ARC / plain malloc otherwise. Used for strings, conversions, and boxed
   instances so they are all reclaimed by an enclosing arena. */
void* xc_heap_alloc(size_t n) {
    if (xc_tls_arena) return xc_arena_alloc(n);
    return xc_rc_alloc(n);
}
void* xc_obj_alloc(size_t n) { return xc_heap_alloc(n); }

/* ── `scope { }` block: a user-marked arena freed when the block ends ─────────
 * enter installs a fresh arena (everything allocated inside comes from it) and
 * returns the previous one; leave frees the block's arena and restores it. This
 * lets a long-running main-thread loop reclaim each iteration without ARC. Same
 * share-nothing rule as the other arenas: a value that must outlive the scope
 * has to be copied out (e.g. returned into an outer-thread/heap value). */
void* xc_scope_enter(void) {
    xc_arena* prev = xc_tls_arena;
    xc_tls_arena = xc_arena_new();
    return (void*)prev;
}
void xc_scope_leave(void* prev) {
    xc_arena* cur = xc_tls_arena;
    xc_tls_arena = (xc_arena*)prev;
    if (cur) xc_arena_destroy(cur);
}

static xc_string_t xc_str_copy(const char* p, xc_size_t n) {
    /* In an arena (thread/request) the arena owns it; otherwise it's an
       rc-managed block under XC_ARC (plain malloc when XC_ARC is off). */
    char* buf = (char*)(xc_tls_arena ? xc_arena_alloc(n + 1) : xc_rc_alloc(n + 1));
    if (!buf) abort();
    if (n) memcpy(buf, p, n);
    buf[n] = '\0';
    return (xc_string_t){ .data = buf, .len = n };
}

xc_arr_string_t xstd_split(xc_string_t s, xc_string_t sep) {
    xc_arr_string_t out = { NULL, 0, 0 };
    if (sep.len == 0) {                 /* empty separator -> [s] */
        out.data = (xc_string_t*)xc_heap_alloc(sizeof(xc_string_t)); if (!out.data) abort();
        out.data[0] = xc_str_copy(s.data, s.len); out.len = 1; out.cap = 1;
        return out;
    }
    xc_size_t count = 1;                /* pieces = occurrences + 1 */
    for (xc_size_t i = 0; i + sep.len <= s.len; ) {
        if (memcmp(s.data + i, sep.data, sep.len) == 0) { count++; i += sep.len; } else i++;
    }
    out.data = (xc_string_t*)xc_heap_alloc(count * sizeof(xc_string_t)); if (!out.data) abort();
    out.cap = count;
    xc_size_t start = 0, idx = 0;
    for (xc_size_t i = 0; i + sep.len <= s.len; ) {
        if (memcmp(s.data + i, sep.data, sep.len) == 0) {
            out.data[idx++] = xc_str_copy(s.data + start, i - start);
            i += sep.len; start = i;
        } else i++;
    }
    out.data[idx++] = xc_str_copy(s.data + start, s.len - start);
    out.len = idx;
    return out;
}

xc_string_t xstd_join(xc_arr_string_t parts, xc_string_t sep) {
    if (parts.len == 0) return xc_str_copy("", 0);
    xc_size_t total = 0;
    for (xc_size_t i = 0; i < parts.len; i++) total += parts.data[i].len;
    total += sep.len * (parts.len - 1);
    char* buf = (char*)xc_heap_alloc(total + 1); if (!buf) abort();
    xc_size_t oi = 0;
    for (xc_size_t i = 0; i < parts.len; i++) {
        if (i) { memcpy(buf + oi, sep.data, sep.len); oi += sep.len; }
        memcpy(buf + oi, parts.data[i].data, parts.data[i].len); oi += parts.data[i].len;
    }
    buf[oi] = '\0';
    return (xc_string_t){ .data = buf, .len = oi };
}

/* convert / parse */
xc_bool_t xstd_num_ok(xc_string_t s) {
    char* buf = xc_string_to_cstr(s); char* e; errno = 0;
    (void)strtod(buf, &e);
    xc_bool_t ok = (errno == 0 && e != buf && *e == '\0' && s.len > 0);
    free(buf); return ok;
}
xc_number_t xstd_to_number(xc_string_t s) {
    char* buf = xc_string_to_cstr(s); double v = strtod(buf, NULL); free(buf); return v;
}
xc_bool_t xstd_int_ok(xc_string_t s) {
    char* buf = xc_string_to_cstr(s); char* e; errno = 0;
    (void)strtoll(buf, &e, 10);
    xc_bool_t ok = (errno == 0 && e != buf && *e == '\0' && s.len > 0);
    free(buf); return ok;
}
xc_integer_t xstd_to_integer(xc_string_t s) {
    char* buf = xc_string_to_cstr(s); long long v = strtoll(buf, NULL, 10); free(buf);
    return (xc_integer_t)v;
}

/* filesystem */
xc_bool_t xstd_file_exists(xc_string_t path) {
    char* p = xc_string_to_cstr(path); FILE* f = fopen(p, "rb"); free(p);
    if (f) { fclose(f); return true; }
    return false;
}

/* process */
void xstd_exit(xc_integer_t code) { exit((int)code); }

/* time */
/* ─── Process metrics (std/monitor) ───────────────────────────────────────────
 * Resident/peak memory, uptime, and the request counter the built-in server
 * bumps. Everything here is read-only introspection of this process, so an
 * app can expose a health/metrics endpoint without an external agent. */
#include <sys/resource.h>
#if defined(__APPLE__)
#include <mach/mach.h>
#endif

static xc_integer_t xw_started_ms = 0;      /* set on first use / server start */
static xc_integer_t xw_request_count = 0;   /* bumped per served request */

/* User-registered health statuses and gauges (std/monitor).
 *
 * A HealthCheck implementor is the pull model: monitor calls it per request.
 * These are the push model, for anything the app already knows — set a status
 * or a number from wherever you detect it and the endpoints report it. Nothing
 * about a database (or any other subsystem) is assumed by the runtime; the app
 * decides what exists. Entries are keyed by name and updated in place.
 * Single-writer, like the rest of the built-in server. */
#define XM_MAX 64
typedef struct { char* name; int up; } xm_status;
typedef struct { char* name; xc_integer_t value; } xm_gauge;
static xm_status xm_statuses[XM_MAX]; static int xm_status_n = 0;
static xm_gauge  xm_gauges[XM_MAX];   static int xm_gauge_n  = 0;

static char* xm_dup(xc_string_t s) {
    char* p = (char*)malloc(s.len + 1); if (!p) abort();
    if (s.len) memcpy(p, s.data, s.len);
    p[s.len] = '\0'; return p;
}
static int xm_same(const char* a, xc_string_t b) {
    return strlen(a) == b.len && memcmp(a, b.data, b.len) == 0;
}

void xstd_mon_set_status(xc_string_t name, xc_bool_t up) {
    for (int i = 0; i < xm_status_n; i++)
        if (xm_same(xm_statuses[i].name, name)) { xm_statuses[i].up = up ? 1 : 0; return; }
    if (xm_status_n >= XM_MAX) return;
    xm_statuses[xm_status_n].name = xm_dup(name);
    xm_statuses[xm_status_n].up = up ? 1 : 0;
    xm_status_n++;
}
xc_integer_t xstd_mon_status_count(void)          { return xm_status_n; }
xc_string_t  xstd_mon_status_name(xc_integer_t i) {
    if (i < 0 || i >= xm_status_n) return xc_str_copy("", 0);
    return xc_string_from_cstr(xm_statuses[i].name);
}
xc_bool_t    xstd_mon_status_up(xc_integer_t i)   {
    return (i >= 0 && i < xm_status_n) ? (xc_bool_t)xm_statuses[i].up : (xc_bool_t)0;
}

void xstd_mon_set_gauge(xc_string_t name, xc_integer_t value) {
    for (int i = 0; i < xm_gauge_n; i++)
        if (xm_same(xm_gauges[i].name, name)) { xm_gauges[i].value = value; return; }
    if (xm_gauge_n >= XM_MAX) return;
    xm_gauges[xm_gauge_n].name = xm_dup(name);
    xm_gauges[xm_gauge_n].value = value;
    xm_gauge_n++;
}
xc_integer_t xstd_mon_gauge_count(void)           { return xm_gauge_n; }
xc_string_t  xstd_mon_gauge_name(xc_integer_t i)  {
    if (i < 0 || i >= xm_gauge_n) return xc_str_copy("", 0);
    return xc_string_from_cstr(xm_gauges[i].name);
}
xc_integer_t xstd_mon_gauge_value(xc_integer_t i) {
    return (i >= 0 && i < xm_gauge_n) ? xm_gauges[i].value : 0;
}

/* ─── Promotion: move a value out of the active arena ─────────────────────────
 * A value allocated in a request/thread arena dies when that arena is destroyed.
 * Storing one into something longer-lived — a singleton's `state`, a container
 * created outside the arena — leaves a dangling pointer, which reads as garbage
 * rather than failing loudly. Codegen calls these when a value crosses into
 * long-lived storage; with no arena active they are a no-op, so a CLI pays
 * nothing. `xc_rc_alloc` is the non-arena allocator, so the copy outlives every
 * arena. */
xc_string_t xc_promote_string(xc_string_t s) {
    if (!xc_tls_arena || !s.data) return s;      /* no arena: already long-lived */
    char* b = (char*)xc_rc_alloc(s.len + 1); if (!b) abort();
    if (s.len) memcpy(b, s.data, s.len);
    b[s.len] = '\0';
    return (xc_string_t){ .data = b, .len = s.len };
}

/* Deep-copy a Json tree out of the arena. A node's children, key strings and
   string payloads are all arena-allocated, so a shallow copy would still dangle;
   this rebuilds the whole tree with the non-arena allocator. Declared later than
   the json internals it touches, so it is defined beside them (see xj_promote). */
xc_Json_t xc_promote_json(xc_Json_t v);

xc_bytes_t xc_promote_bytes(xc_bytes_t b) {
    if (!xc_tls_arena || !b.data) return b;
    unsigned char* p = (unsigned char*)xc_rc_alloc(b.len ? b.len : 1); if (!p) abort();
    if (b.len) memcpy(p, b.data, b.len);
    return (xc_bytes_t){ .data = p, .len = b.len };
}

xc_integer_t xstd_mem_rss(void) {
#if defined(__APPLE__)
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t n = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &n) == KERN_SUCCESS)
        return (xc_integer_t)info.resident_size;
    return 0;
#else
    /* Linux: field 2 of /proc/self/statm is resident pages. */
    FILE* fp = fopen("/proc/self/statm", "r");
    if (!fp) return 0;
    long total = 0, res = 0;
    if (fscanf(fp, "%ld %ld", &total, &res) != 2) { fclose(fp); return 0; }
    fclose(fp);
    return (xc_integer_t)res * (xc_integer_t)sysconf(_SC_PAGESIZE);
#endif
}

xc_integer_t xstd_mem_peak(void) {
    struct rusage ru;
    if (getrusage(RUSAGE_SELF, &ru) != 0) return 0;
#if defined(__APPLE__)
    return (xc_integer_t)ru.ru_maxrss;              /* bytes on macOS */
#else
    return (xc_integer_t)ru.ru_maxrss * 1024;       /* kilobytes on Linux */
#endif
}

/* CPU time consumed by this process, in milliseconds (user and system). Read
   from getrusage, so it is real accounting rather than a sampled guess. */
xc_integer_t xstd_cpu_user_ms(void) {
    struct rusage ru;
    if (getrusage(RUSAGE_SELF, &ru) != 0) return 0;
    return (xc_integer_t)ru.ru_utime.tv_sec * 1000 + (xc_integer_t)(ru.ru_utime.tv_usec / 1000);
}
xc_integer_t xstd_cpu_system_ms(void) {
    struct rusage ru;
    if (getrusage(RUSAGE_SELF, &ru) != 0) return 0;
    return (xc_integer_t)ru.ru_stime.tv_sec * 1000 + (xc_integer_t)(ru.ru_stime.tv_usec / 1000);
}

xc_integer_t xstd_uptime_ms(void) {
    xc_integer_t now = xstd_now_nanos() / 1000000;
    if (xw_started_ms == 0) xw_started_ms = now;
    return now - xw_started_ms;
}
void         xstd_mark_start(void)      { xw_started_ms = xstd_now_nanos() / 1000000; }
void         xstd_put_int(xc_integer_t n) { printf("%lld\n", (long long)n); }
void         xstd_put_str(xc_string_t s) { fwrite(s.data, 1, s.len, stdout); }
xc_string_t  xstd_concat(xc_string_t a, xc_string_t b) { return xc_string_concat(a, b); }
xc_integer_t xstd_alloc(xc_integer_t n) { return (xc_integer_t)(intptr_t)calloc(1, (size_t)n); }
xc_integer_t xstd_request_count(void)   { return xw_request_count; }

xc_integer_t xstd_now_nanos(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (xc_integer_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}
void xstd_sleep_ms(xc_integer_t ms) {
    if (ms < 0) return;
    struct timespec ts; ts.tv_sec = ms / 1000; ts.tv_nsec = (ms % 1000) * 1000000L;
    nanosleep(&ts, NULL);
}

/* ─── JSON (std/json — serialization) ────────────────────────────────────────
 * A small, self-contained JSON DOM: build values programmatically, stringify
 * them, and parse text back into a tree. Referenced from X as the `Json` type.
 */
enum { XJ_NULL = 0, XJ_BOOL = 1, XJ_NUMBER = 2, XJ_STRING = 3,
       XJ_ARRAY = 4, XJ_OBJECT = 5, XJ_ERROR = 6 };

struct xc_json_node {
    int kind;
    xc_bool_t b;          /* XJ_BOOL   */
    xc_number_t num;      /* XJ_NUMBER */
    char* str;            /* XJ_STRING (NUL-terminated, owned) */
    struct xc_json_node** items;  /* XJ_ARRAY / XJ_OBJECT values */
    char** keys;                  /* XJ_OBJECT keys (parallel to items) */
    long len, cap;
};

static struct xc_json_node* xj_alloc(int kind) {
    struct xc_json_node* n = (struct xc_json_node*)xc_arena_alloc(sizeof(*n));
    if (!n) abort();
    memset(n, 0, sizeof(*n));
    n->kind = kind;
    return n;
}

xc_Json_t xstd_json_null(void)            { return xj_alloc(XJ_NULL); }
xc_Json_t xstd_json_bool(xc_bool_t v)     { struct xc_json_node* n = xj_alloc(XJ_BOOL); n->b = v; return n; }
xc_Json_t xstd_json_number(xc_number_t v) { struct xc_json_node* n = xj_alloc(XJ_NUMBER); n->num = v; return n; }
xc_Json_t xstd_json_array(void)           { return xj_alloc(XJ_ARRAY); }
xc_Json_t xstd_json_object(void)          { return xj_alloc(XJ_OBJECT); }

static char* xj_strdup_n(const char* p, size_t n) {
    char* s = (char*)malloc(n + 1); if (!s) abort();
    if (n) memcpy(s, p, n);
    s[n] = '\0';
    return s;
}
/* Arena-aware copy for JSON/YAML *node* contents (string values, object keys,
   yaml line text). These live exactly as long as their arena-allocated node
   (xj_alloc), are never freed or realloc'd individually, so they belong in the
   same region — and so a per-request/-thread arena reclaims them too. Falls back
   to malloc when no arena is active (main thread), matching prior behaviour.
   NOT used for event topic/type (which must outlive a request) nor for the
   stringify accumulator / parse scratch (which are realloc'd or free'd). */
static char* xj_adup_n(const char* p, size_t n) {
    char* s = (char*)xc_arena_alloc(n + 1); if (!s) abort();
    if (n) memcpy(s, p, n);
    s[n] = '\0';
    return s;
}
xc_Json_t xstd_json_string(xc_string_t v) {
    struct xc_json_node* n = xj_alloc(XJ_STRING);
    n->str = xj_adup_n(v.data, v.len);
    return n;
}

/* See the forward declaration near xc_promote_string. Copies with xc_rc_alloc
   (the non-arena allocator) so the result outlives any arena; a no-op when no
   arena is active, since the tree is already long-lived. */
static char* xj_rc_dup(const char* p) {
    if (!p) return NULL;
    size_t n = strlen(p);
    char* d = (char*)xc_rc_alloc(n + 1); if (!d) abort();
    memcpy(d, p, n); d[n] = '\0';
    return d;
}
xc_Json_t xc_promote_json(xc_Json_t v) {
    if (!xc_tls_arena || !v) return v;
    struct xc_json_node* n = (struct xc_json_node*)xc_rc_alloc(sizeof(*n));
    if (!n) abort();
    memset(n, 0, sizeof(*n));
    n->kind = v->kind; n->b = v->b; n->num = v->num;
    n->str = xj_rc_dup(v->str);
    n->len = v->len; n->cap = v->len;
    if (v->len > 0) {
        n->items = (struct xc_json_node**)xc_rc_alloc((size_t)v->len * sizeof(*n->items));
        n->keys  = (char**)xc_rc_alloc((size_t)v->len * sizeof(*n->keys));
        if (!n->items || !n->keys) abort();
        for (long i = 0; i < v->len; i++) {
            n->items[i] = xc_promote_json(v->items[i]);
            n->keys[i]  = v->keys ? xj_rc_dup(v->keys[i]) : NULL;
        }
    }
    return n;
}

static void xj_grow(struct xc_json_node* c) {
    if (c->len < c->cap) return;
    long ncap = c->cap ? c->cap * 2 : 4;
    c->items = (struct xc_json_node**)xc_arena_regrow(c->items, (size_t)c->len * sizeof(*c->items), (size_t)ncap * sizeof(*c->items));
    c->keys  = (char**)xc_arena_regrow(c->keys, (size_t)c->len * sizeof(*c->keys), (size_t)ncap * sizeof(*c->keys));
    if (!c->items || !c->keys) abort();
    c->cap = ncap;
}

xc_Json_t xstd_json_push(xc_Json_t arr, xc_Json_t v) {
    if (!arr || arr->kind != XJ_ARRAY) return arr;
    xj_grow(arr);
    arr->keys[arr->len] = NULL;
    arr->items[arr->len] = v;
    arr->len++;
    return arr;
}

xc_Json_t xstd_json_set(xc_Json_t obj, xc_string_t key, xc_Json_t v) {
    if (!obj || obj->kind != XJ_OBJECT) return obj;
    char* k = xj_adup_n(key.data, key.len);
    for (long i = 0; i < obj->len; i++) {       /* replace existing key */
        if (strcmp(obj->keys[i], k) == 0) {
            obj->items[i] = v;
            if (!xc_tls_arena) free(k);         /* arena-owned copies are reclaimed in bulk */
            return obj;
        }
    }
    xj_grow(obj);
    obj->keys[obj->len] = k;
    obj->items[obj->len] = v;
    obj->len++;
    return obj;
}

/* introspection */
xc_integer_t xstd_json_kind(xc_Json_t v)   { return v ? (xc_integer_t)v->kind : XJ_ERROR; }
xc_integer_t xstd_json_length(xc_Json_t v) { return (v && (v->kind == XJ_ARRAY || v->kind == XJ_OBJECT)) ? (xc_integer_t)v->len : 0; }
xc_bool_t    xstd_json_ok(xc_Json_t v)     { return v && v->kind != XJ_ERROR; }

xc_Json_t xstd_json_at(xc_Json_t arr, xc_integer_t i) {
    if (!arr || arr->kind != XJ_ARRAY || i < 0 || i >= arr->len) return xstd_json_null();
    return arr->items[i];
}
xc_Json_t xstd_json_get(xc_Json_t obj, xc_string_t key) {
    if (!obj || obj->kind != XJ_OBJECT) return xstd_json_null();
    for (long i = 0; i < obj->len; i++)
        if (strlen(obj->keys[i]) == key.len && memcmp(obj->keys[i], key.data, key.len) == 0)
            return obj->items[i];
    return xstd_json_null();
}
xc_bool_t xstd_json_has(xc_Json_t obj, xc_string_t key) {
    if (!obj || obj->kind != XJ_OBJECT) return false;
    for (long i = 0; i < obj->len; i++)
        if (strlen(obj->keys[i]) == key.len && memcmp(obj->keys[i], key.data, key.len) == 0)
            return true;
    return false;
}
xc_string_t xstd_json_key_at(xc_Json_t obj, xc_integer_t i) {
    if (!obj || obj->kind != XJ_OBJECT || i < 0 || i >= obj->len) return xc_str_copy("", 0);
    return xc_str_copy(obj->keys[i], strlen(obj->keys[i]));
}
/* The as_* readers are lenient: when a value arrives as a different JSON kind
 * (e.g. path/query/header params are always strings), coerce it. This is what
 * lets `json as T` decode "42" into an Integer field, "true" into a Bool, etc. */
xc_string_t xstd_json_as_string(xc_Json_t v) {
    if (!v) return xc_str_copy("", 0);
    if (v->kind == XJ_STRING && v->str) return xc_str_copy(v->str, strlen(v->str));
    if (v->kind == XJ_NUMBER) {
        char b[32]; double n = v->num;
        if (n == (double)(long long)n) snprintf(b, sizeof b, "%lld", (long long)n);
        else snprintf(b, sizeof b, "%g", n);
        return xc_str_copy(b, strlen(b));
    }
    if (v->kind == XJ_BOOL) return v->b ? xc_str_copy("true", 4) : xc_str_copy("false", 5);
    return xc_str_copy("", 0);
}
/* Like xstd_json_as_string, but the returned buffer is a fresh copy detached
 * from the JSON node. Allocated like every other Xi string (the active
 * request/thread/scope arena when one is installed, else rc/malloc), so decoded
 * rows are reclaimed with their request instead of leaking one copy per field
 * per request. Same share-nothing rule as all string values: a decoded value
 * that must outlive the request/thread has to be copied into the owner. */
xc_string_t xstd_json_as_string_owned(xc_Json_t v) {
    xc_string_t s = xstd_json_as_string(v);
    char* buf = (char*)xc_heap_alloc(s.len + 1);
    if (!buf) abort();
    if (s.len) memcpy(buf, s.data, s.len);
    buf[s.len] = '\0';
    return (xc_string_t){ .data = buf, .len = s.len };
}
xc_number_t xstd_json_as_number(xc_Json_t v) {
    if (!v) return 0.0;
    if (v->kind == XJ_NUMBER) return v->num;
    if (v->kind == XJ_STRING && v->str) return atof(v->str);
    if (v->kind == XJ_BOOL) return v->b ? 1.0 : 0.0;
    return 0.0;
}
xc_bool_t xstd_json_as_bool(xc_Json_t v) {
    if (!v) return false;
    if (v->kind == XJ_BOOL) return v->b;
    if (v->kind == XJ_NUMBER) return v->num != 0.0;
    if (v->kind == XJ_STRING && v->str) return (strcmp(v->str, "true") == 0 || strcmp(v->str, "1") == 0);
    return false;
}

/* ── stringify ── */
typedef struct { char* buf; size_t len, cap; } xj_sb;
static void xj_sb_putn(xj_sb* s, const char* p, size_t n) {
    if (s->len + n + 1 > s->cap) {
        size_t nc = s->cap ? s->cap : 64;
        while (s->len + n + 1 > nc) nc *= 2;
        s->buf = (char*)xc_arena_regrow(s->buf, s->len, nc); if (!s->buf) abort();
        s->cap = nc;
    }
    memcpy(s->buf + s->len, p, n); s->len += n; s->buf[s->len] = '\0';
}
static void xj_sb_put(xj_sb* s, const char* p) { xj_sb_putn(s, p, strlen(p)); }
static void xj_sb_putc(xj_sb* s, char c) { xj_sb_putn(s, &c, 1); }
static void xj_write_string(xj_sb* s, const char* p, size_t n) {
    xj_sb_putc(s, '"');
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)p[i];
        switch (c) {
            case '"':  xj_sb_put(s, "\\\""); break;
            case '\\': xj_sb_put(s, "\\\\"); break;
            case '\n': xj_sb_put(s, "\\n");  break;
            case '\t': xj_sb_put(s, "\\t");  break;
            case '\r': xj_sb_put(s, "\\r");  break;
            case '\b': xj_sb_put(s, "\\b");  break;
            case '\f': xj_sb_put(s, "\\f");  break;
            default:
                if (c < 0x20) { char u[8]; snprintf(u, sizeof(u), "\\u%04x", c); xj_sb_put(s, u); }
                else xj_sb_putc(s, (char)c);
        }
    }
    xj_sb_putc(s, '"');
}
static void xj_write(xj_sb* s, struct xc_json_node* v, int pretty, int depth) {
    if (!v) { xj_sb_put(s, "null"); return; }
    switch (v->kind) {
        case XJ_NULL:  xj_sb_put(s, "null"); break;
        case XJ_BOOL:  xj_sb_put(s, v->b ? "true" : "false"); break;
        case XJ_NUMBER: {
            char buf[64];
            if (v->num == (xc_integer_t)v->num) snprintf(buf, sizeof(buf), "%lld", (long long)(xc_integer_t)v->num);
            else snprintf(buf, sizeof(buf), "%g", v->num);
            xj_sb_put(s, buf);
            break;
        }
        case XJ_STRING: xj_write_string(s, v->str ? v->str : "", v->str ? strlen(v->str) : 0); break;
        case XJ_ARRAY:
        case XJ_OBJECT: {
            int obj = (v->kind == XJ_OBJECT);
            xj_sb_putc(s, obj ? '{' : '[');
            for (long i = 0; i < v->len; i++) {
                if (i) xj_sb_putc(s, ',');
                if (pretty) { xj_sb_putc(s, '\n'); for (int d = 0; d <= depth; d++) xj_sb_put(s, "  "); }
                if (obj) { xj_write_string(s, v->keys[i], strlen(v->keys[i])); xj_sb_put(s, pretty ? ": " : ":"); }
                xj_write(s, v->items[i], pretty, depth + 1);
            }
            if (pretty && v->len) { xj_sb_putc(s, '\n'); for (int d = 0; d < depth; d++) xj_sb_put(s, "  "); }
            xj_sb_putc(s, obj ? '}' : ']');
            break;
        }
        default: xj_sb_put(s, "null");
    }
}
xc_string_t xstd_json_stringify(xc_Json_t v) {
    xj_sb s = { NULL, 0, 0 }; xj_write(&s, v, 0, 0);
    if (!s.buf) return xc_str_copy("", 0);
    return (xc_string_t){ .data = s.buf, .len = s.len };
}
xc_string_t xstd_json_pretty(xc_Json_t v) {
    xj_sb s = { NULL, 0, 0 }; xj_write(&s, v, 1, 0);
    if (!s.buf) return xc_str_copy("", 0);
    return (xc_string_t){ .data = s.buf, .len = s.len };
}

/* ── parse ── */
/* `depth` bounds nesting: xj_parse_value recurses per `[`/`{`, so a deeply
   nested document from an untrusted source (a request body, a config file)
   would otherwise exhaust the C stack and crash the process.

   Tunable per service with XI_JSON_MAX_DEPTH. Read once and clamped: a value
   below the floor would reject ordinary documents, and one above the ceiling
   would put the stack back within reach of the very input this guards. */
#define XJ_DEPTH_DEFAULT 200
#define XJ_DEPTH_MIN      16
#define XJ_DEPTH_MAX   10000
static int xj_module_depth = 0;   /* set by a module's `jsonMaxDepth = N` */
void xstd_set_json_max_depth(xc_integer_t n) { if (n > 0) xj_module_depth = (int)n; }
static int xj_max_depth(void) {
    static int cached = 0;
    if (cached) return cached;
    /* Precedence: environment (deploy-time override) > module declaration >
       built-in default. Clamped either way. */
    int v = xj_module_depth > 0 ? xj_module_depth : XJ_DEPTH_DEFAULT;
    if (v < XJ_DEPTH_MIN) v = XJ_DEPTH_MIN;
    if (v > XJ_DEPTH_MAX) v = XJ_DEPTH_MAX;
    const char* e = getenv("XI_JSON_MAX_DEPTH");
    if (e && *e) {
        long n = strtol(e, NULL, 10);
        if (n > 0) {
            if (n < XJ_DEPTH_MIN) n = XJ_DEPTH_MIN;
            if (n > XJ_DEPTH_MAX) n = XJ_DEPTH_MAX;
            v = (int)n;
        }
    }
    cached = v;
    return cached;
}
typedef struct { const char* p; const char* end; int err; int depth; } xj_parser;
static void xj_skip_ws(xj_parser* P) {
    while (P->p < P->end && (*P->p == ' ' || *P->p == '\t' || *P->p == '\n' || *P->p == '\r')) P->p++;
}
static struct xc_json_node* xj_parse_value(xj_parser* P);
static char* xj_parse_raw_string(xj_parser* P, size_t* outn) {
    /* assumes *P->p == '"' */
    P->p++;
    xj_sb s = { NULL, 0, 0 };
    while (P->p < P->end && *P->p != '"') {
        char c = *P->p++;
        if (c == '\\' && P->p < P->end) {
            char e = *P->p++;
            switch (e) {
                case 'n': xj_sb_putc(&s, '\n'); break;
                case 't': xj_sb_putc(&s, '\t'); break;
                case 'r': xj_sb_putc(&s, '\r'); break;
                case 'b': xj_sb_putc(&s, '\b'); break;
                case 'f': xj_sb_putc(&s, '\f'); break;
                case '/': xj_sb_putc(&s, '/');  break;
                case '"': xj_sb_putc(&s, '"');  break;
                case '\\': xj_sb_putc(&s, '\\'); break;
                case 'u': {
                    if (P->end - P->p >= 4) {
                        char h[5]; memcpy(h, P->p, 4); h[4] = '\0'; P->p += 4;
                        unsigned cp = (unsigned)strtol(h, NULL, 16);
                        if (cp < 0x80) xj_sb_putc(&s, (char)cp);
                        else if (cp < 0x800) { char u[2] = { (char)(0xC0|(cp>>6)), (char)(0x80|(cp&0x3F)) }; xj_sb_putn(&s, u, 2); }
                        else { char u[3] = { (char)(0xE0|(cp>>12)), (char)(0x80|((cp>>6)&0x3F)), (char)(0x80|(cp&0x3F)) }; xj_sb_putn(&s, u, 3); }
                    }
                    break;
                }
                default: xj_sb_putc(&s, e);
            }
        } else { xj_sb_putc(&s, c); }
    }
    if (P->p < P->end && *P->p == '"') P->p++; else P->err = 1;
    if (!s.buf) { s.buf = xj_strdup_n("", 0); s.len = 0; }
    *outn = s.len;
    return s.buf;
}
static struct xc_json_node* xj_parse_value(xj_parser* P) {
    xj_skip_ws(P);
    if (P->p >= P->end) { P->err = 1; return xj_alloc(XJ_ERROR); }
    if (P->depth >= xj_max_depth()) { P->err = 1; return xj_alloc(XJ_ERROR); }
    char c = *P->p;
    if (c == '"') {
        size_t n; char* str = xj_parse_raw_string(P, &n);
        struct xc_json_node* node = xj_alloc(XJ_STRING); node->str = str; return node;
    }
    if (c == '{') {
        P->p++; P->depth++;
        struct xc_json_node* obj = xj_alloc(XJ_OBJECT);
        xj_skip_ws(P);
        if (P->p < P->end && *P->p == '}') { P->p++; P->depth--; return obj; }
        while (P->p < P->end) {
            xj_skip_ws(P);
            if (*P->p != '"') { P->err = 1; break; }
            size_t kn; char* key = xj_parse_raw_string(P, &kn);
            xj_skip_ws(P);
            if (P->p < P->end && *P->p == ':') P->p++; else { P->err = 1; free(key); break; }
            struct xc_json_node* val = xj_parse_value(P);
            xj_grow(obj); obj->keys[obj->len] = key; obj->items[obj->len] = val; obj->len++;
            xj_skip_ws(P);
            if (P->p < P->end && *P->p == ',') { P->p++; continue; }
            if (P->p < P->end && *P->p == '}') { P->p++; break; }
            P->err = 1; break;
        }
        P->depth--;
        return obj;
    }
    if (c == '[') {
        P->p++; P->depth++;
        struct xc_json_node* arr = xj_alloc(XJ_ARRAY);
        xj_skip_ws(P);
        if (P->p < P->end && *P->p == ']') { P->p++; P->depth--; return arr; }
        while (P->p < P->end) {
            struct xc_json_node* val = xj_parse_value(P);
            xj_grow(arr); arr->keys[arr->len] = NULL; arr->items[arr->len] = val; arr->len++;
            xj_skip_ws(P);
            if (P->p < P->end && *P->p == ',') { P->p++; continue; }
            if (P->p < P->end && *P->p == ']') { P->p++; break; }
            P->err = 1; break;
        }
        P->depth--;
        return arr;
    }
    if (c == 't') { if (P->end - P->p >= 4 && memcmp(P->p, "true", 4) == 0)  { P->p += 4; struct xc_json_node* n = xj_alloc(XJ_BOOL); n->b = true; return n; } P->err = 1; return xj_alloc(XJ_ERROR); }
    if (c == 'f') { if (P->end - P->p >= 5 && memcmp(P->p, "false", 5) == 0) { P->p += 5; struct xc_json_node* n = xj_alloc(XJ_BOOL); n->b = false; return n; } P->err = 1; return xj_alloc(XJ_ERROR); }
    if (c == 'n') { if (P->end - P->p >= 4 && memcmp(P->p, "null", 4) == 0)  { P->p += 4; return xj_alloc(XJ_NULL); } P->err = 1; return xj_alloc(XJ_ERROR); }
    if (c == '-' || (c >= '0' && c <= '9')) {
        const char* start = P->p;
        if (*P->p == '-') P->p++;
        while (P->p < P->end && ((*P->p >= '0' && *P->p <= '9') || *P->p == '.' || *P->p == 'e' || *P->p == 'E' || *P->p == '+' || *P->p == '-')) P->p++;
        char* tmp = xj_strdup_n(start, (size_t)(P->p - start));
        struct xc_json_node* n = xj_alloc(XJ_NUMBER); n->num = strtod(tmp, NULL); free(tmp);
        return n;
    }
    P->err = 1; return xj_alloc(XJ_ERROR);
}
xc_Json_t xstd_json_parse(xc_string_t s) {
    xj_parser P; P.p = s.data; P.end = s.data + s.len; P.err = 0; P.depth = 0;
    struct xc_json_node* v = xj_parse_value(&P);
    xj_skip_ws(&P);
    if (P.err) { v->kind = XJ_ERROR; }
    return v;
}

/* ─── Event system (std/events) ──────────────────────────────────────────────
 * A type-erased event envelope (topic + type name + an opaque pointer to a
 * heap-owned copy of the typed payload) plus an in-memory FIFO. The default
 * in-process transport moves envelopes through the queue WITHOUT serialization;
 * external transports serialize/deserialize the payload (via generated codecs).
 */
struct xc_event_env {
    char* topic;
    char* type;
    void* payload;     /* heap-owned copy of the typed value */
};

xc_Event_t xstd_event_make(xc_string_t topic, xc_string_t type, void* payload) {
    struct xc_event_env* e = (struct xc_event_env*)malloc(sizeof(*e));
    if (!e) abort();
    e->topic   = xj_strdup_n(topic.data, topic.len);
    e->type    = xj_strdup_n(type.data, type.len);
    e->payload = payload;
    return e;
}
xc_string_t xstd_event_topic(xc_Event_t e)   { return xc_str_copy(e->topic, strlen(e->topic)); }
xc_string_t xstd_event_type(xc_Event_t e)    { return xc_str_copy(e->type, strlen(e->type)); }
void*       xstd_event_payload(xc_Event_t e)  { return e->payload; }

/* In-memory FIFO of envelopes (the default transport's queue). Guarded by a
   mutex+condvar so a worker thread (Events.runAsync) can drain it while other
   threads publish; the sync path (Events.run) uses the same locks. */
static xc_Event_t* xc_eq = NULL;
static long xc_eq_head = 0, xc_eq_len = 0, xc_eq_cap = 0;
static pthread_mutex_t xc_eq_mtx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  xc_eq_cv  = PTHREAD_COND_INITIALIZER;
static int xc_eq_closed = 0;

static void xc_eq_enq(xc_Event_t e) {            /* caller holds the lock */
    if (xc_eq_head + xc_eq_len >= xc_eq_cap) {
        if (xc_eq_head > 0) {                       /* compact toward the front */
            memmove(xc_eq, xc_eq + xc_eq_head, (size_t)xc_eq_len * sizeof(xc_Event_t));
            xc_eq_head = 0;
        }
        if (xc_eq_len >= xc_eq_cap) {               /* still full -> grow */
            xc_eq_cap = xc_eq_cap ? xc_eq_cap * 2 : 16;
            xc_eq = (xc_Event_t*)realloc(xc_eq, (size_t)xc_eq_cap * sizeof(xc_Event_t));
            if (!xc_eq) abort();
        }
    }
    xc_eq[xc_eq_head + xc_eq_len] = e;
    xc_eq_len++;
}
static xc_Event_t xc_eq_deq(void) {              /* caller holds the lock */
    if (xc_eq_len == 0) return NULL;
    xc_Event_t e = xc_eq[xc_eq_head];
    xc_eq_head++; xc_eq_len--;
    if (xc_eq_len == 0) xc_eq_head = 0;
    return e;
}

void xstd_eventq_push(xc_Event_t e) {
    pthread_mutex_lock(&xc_eq_mtx);
    xc_eq_enq(e);
    pthread_cond_signal(&xc_eq_cv);
    pthread_mutex_unlock(&xc_eq_mtx);
}
xc_integer_t xstd_eventq_len(void) {
    pthread_mutex_lock(&xc_eq_mtx);
    long n = xc_eq_len;
    pthread_mutex_unlock(&xc_eq_mtx);
    return (xc_integer_t)n;
}
xc_Event_t xstd_eventq_shift(void) {             /* non-blocking */
    pthread_mutex_lock(&xc_eq_mtx);
    xc_Event_t e = xc_eq_deq();
    pthread_mutex_unlock(&xc_eq_mtx);
    return e;
}
/* Block until an event is available, or NULL once the queue is closed+drained. */
xc_Event_t xstd_eventq_pop_blocking(void) {
    pthread_mutex_lock(&xc_eq_mtx);
    while (xc_eq_len == 0 && !xc_eq_closed) pthread_cond_wait(&xc_eq_cv, &xc_eq_mtx);
    xc_Event_t e = xc_eq_deq();
    pthread_mutex_unlock(&xc_eq_mtx);
    return e;
}
/* Stop async pumps: mark closed and wake all waiters. */
void xstd_eventq_close(void) {
    pthread_mutex_lock(&xc_eq_mtx);
    xc_eq_closed = 1;
    pthread_cond_broadcast(&xc_eq_cv);
    pthread_mutex_unlock(&xc_eq_mtx);
}

/* ─── YAML & XML (std/yaml, std/xml) ─────────────────────────────────────────
 * Both reuse the JSON value tree (xc_json_node) as a generic document model:
 * stringify walks the tree; parse builds one. Supported subsets are documented
 * in docs/serialization.md.
 */

static void xj_num_str(char* buf, xc_number_t n) {
    if (n == (xc_integer_t)n) snprintf(buf, 64, "%lld", (long long)(xc_integer_t)n);
    else snprintf(buf, 64, "%g", n);
}
static int xj_is_scalar(struct xc_json_node* v) { return v && v->kind <= XJ_STRING; }

/* infer a scalar node from raw text (null/bool/number, else string; strips quotes) */
static struct xc_json_node* xj_scalar_from_text(const char* s, size_t n) {
    while (n > 0 && (s[0]==' '||s[0]=='\t')) { s++; n--; }
    while (n > 0 && (s[n-1]==' '||s[n-1]=='\t')) n--;
    if (n >= 2 && ((s[0]=='"'&&s[n-1]=='"')||(s[0]=='\''&&s[n-1]=='\''))) {
        struct xc_json_node* nd = xj_alloc(XJ_STRING); nd->str = xj_adup_n(s+1, n-2); return nd;
    }
    if (n == 0) { struct xc_json_node* nd = xj_alloc(XJ_STRING); nd->str = xj_adup_n("",0); return nd; }
    if ((n==4 && memcmp(s,"null",4)==0) || (n==1 && s[0]=='~')) return xj_alloc(XJ_NULL);
    if (n==4 && memcmp(s,"true",4)==0)  { struct xc_json_node* nd=xj_alloc(XJ_BOOL); nd->b=1; return nd; }
    if (n==5 && memcmp(s,"false",5)==0) { struct xc_json_node* nd=xj_alloc(XJ_BOOL); nd->b=0; return nd; }
    if (n < 63) { char tmp[64]; memcpy(tmp,s,n); tmp[n]='\0'; char* e; errno=0;
        double d = strtod(tmp,&e); if (e==tmp+n && e!=tmp && errno==0) {
            struct xc_json_node* nd=xj_alloc(XJ_NUMBER); nd->num=d; return nd; } }
    { struct xc_json_node* nd=xj_alloc(XJ_STRING); nd->str=xj_adup_n(s,n); return nd; }
}
static void xj_obj_set_n(struct xc_json_node* o, const char* k, size_t kn, struct xc_json_node* v) {
    xj_grow(o); o->keys[o->len]=xj_adup_n(k,kn); o->items[o->len]=v; o->len++;
}
static void xj_arr_push_n(struct xc_json_node* a, struct xc_json_node* v) {
    xj_grow(a); a->keys[a->len]=NULL; a->items[a->len]=v; a->len++;
}

/* ── YAML stringify (block style) ── */
static int xj_yaml_needs_quote(const char* s) {
    if (!s || !*s) return 1;
    size_t n = strlen(s);
    if (s[0]==' ' || s[n-1]==' ') return 1;
    for (size_t i=0;i<n;i++) { char c=s[i];
        if (c==':'||c=='#'||c=='\n'||c=='['||c==']'||c=='{'||c=='}'||c==','||c=='"'||c=='\''||(c=='-'&&i==0)) return 1; }
    if (!strcmp(s,"true")||!strcmp(s,"false")||!strcmp(s,"null")||!strcmp(s,"~")) return 1;
    { char* e; errno=0; strtod(s,&e); if (*e=='\0' && e!=s) return 1; }
    return 0;
}
static void xj_yaml_str(xj_sb* sb, const char* s) {
    if (xj_yaml_needs_quote(s)) {
        xj_sb_putc(sb,'"');
        for (const char* p=s; p && *p; p++) {
            if (*p=='"'||*p=='\\') xj_sb_putc(sb,'\\');
            if (*p=='\n') { xj_sb_put(sb,"\\n"); continue; }
            xj_sb_putc(sb,*p);
        }
        xj_sb_putc(sb,'"');
    } else xj_sb_put(sb, s?s:"");
}
static void xj_yaml_scalar(xj_sb* sb, struct xc_json_node* v) {
    char b[64];
    switch (v->kind) {
        case XJ_NULL:   xj_sb_put(sb,"null"); break;
        case XJ_BOOL:   xj_sb_put(sb, v->b?"true":"false"); break;
        case XJ_NUMBER: xj_num_str(b,v->num); xj_sb_put(sb,b); break;
        case XJ_STRING: xj_yaml_str(sb, v->str); break;
        default:        xj_sb_put(sb,"null");
    }
}
static void xj_yaml_block(xj_sb* sb, struct xc_json_node* v, int indent) {
    int obj = (v->kind == XJ_OBJECT);
    for (long i=0;i<v->len;i++) {
        for (int k=0;k<indent;k++) xj_sb_putc(sb,' ');
        if (obj) { xj_yaml_str(sb, v->keys[i]); xj_sb_putc(sb,':'); } else { xj_sb_putc(sb,'-'); }
        struct xc_json_node* c = v->items[i];
        if (xj_is_scalar(c)) { xj_sb_putc(sb,' '); xj_yaml_scalar(sb,c); xj_sb_putc(sb,'\n'); }
        else if (c->len==0) { xj_sb_put(sb, c->kind==XJ_ARRAY?" []\n":" {}\n"); }
        else { xj_sb_putc(sb,'\n'); xj_yaml_block(sb,c,indent+2); }
    }
}
xc_string_t xstd_yaml_stringify(xc_Json_t v) {
    xj_sb s={0,0,0};
    if (!v) return xc_str_copy("null\n",5);
    if (xj_is_scalar(v)) { xj_yaml_scalar(&s,v); xj_sb_putc(&s,'\n'); }
    else if (v->len==0) { xj_sb_put(&s, v->kind==XJ_ARRAY?"[]\n":"{}\n"); }
    else xj_yaml_block(&s,v,0);
    if (!s.buf) return xc_str_copy("",0);
    return (xc_string_t){ .data=s.buf, .len=s.len };
}

/* ── YAML parse (block subset: maps, seqs, scalars, nesting, # comments) ── */
typedef struct { int indent; int seq; char* content; } xy_line;
static long xy_key_colon(const char* s) {
    int q = 0;
    for (long i=0; s[i]; i++) { char c=s[i];
        if (q) { if (c==q) q=0; continue; }
        if (c=='"'||c=='\'') { q=c; continue; }
        if (c==':' && (s[i+1]=='\0'||s[i+1]==' ')) return i;
    }
    return -1;
}
static struct xc_json_node* xy_parse_block(xy_line* L, long n, long* i, int minIndent) {
    (void)minIndent;
    if (*i >= n) return xj_alloc(XJ_NULL);
    int ci = L[*i].indent;
    if (L[*i].seq) {
        struct xc_json_node* arr = xj_alloc(XJ_ARRAY);
        while (*i < n && L[*i].seq && L[*i].indent == ci) {
            char* rest = L[*i].content;
            if (rest[0] == '\0') {
                (*i)++;
                if (*i < n && L[*i].indent > ci) xj_arr_push_n(arr, xy_parse_block(L,n,i,ci+1));
                else xj_arr_push_n(arr, xj_alloc(XJ_NULL));
            } else {
                L[*i].seq = 0; L[*i].indent = ci + 2;       /* reinterpret inline content */
                xj_arr_push_n(arr, xy_parse_block(L,n,i,ci+1));
            }
        }
        return arr;
    }
    long colon = xy_key_colon(L[*i].content);
    if (colon < 0) { struct xc_json_node* v = xj_scalar_from_text(L[*i].content, strlen(L[*i].content)); (*i)++; return v; }
    struct xc_json_node* obj = xj_alloc(XJ_OBJECT);
    while (*i < n && !L[*i].seq && L[*i].indent == ci) {
        char* line = L[*i].content;
        long c2 = xy_key_colon(line);
        if (c2 < 0) break;
        const char* ks = line; long kn = c2;
        while (kn > 0 && ks[0]==' ') { ks++; kn--; }
        while (kn > 0 && ks[kn-1]==' ') kn--;
        if (kn >= 2 && ((ks[0]=='"'&&ks[kn-1]=='"')||(ks[0]=='\''&&ks[kn-1]=='\''))) { ks++; kn-=2; }
        const char* rest = line + c2 + 1;
        while (*rest == ' ') rest++;
        (*i)++;
        if (*rest == '\0') {
            if (*i < n && L[*i].indent > ci) xj_obj_set_n(obj, ks, (size_t)kn, xy_parse_block(L,n,i,ci+1));
            else xj_obj_set_n(obj, ks, (size_t)kn, xj_alloc(XJ_NULL));
        } else {
            xj_obj_set_n(obj, ks, (size_t)kn, xj_scalar_from_text(rest, strlen(rest)));
        }
    }
    return obj;
}
xc_Json_t xstd_yaml_parse(xc_string_t src) {
    xy_line* L = (xy_line*)malloc(sizeof(xy_line) * (src.len + 2)); if (!L) abort();
    long n = 0; size_t i = 0;
    while (i < src.len) {
        size_t start=i; while (i<src.len && src.data[i]!='\n') i++;
        size_t end=i; if (i<src.len) i++;
        size_t p=start; int indent=0;
        while (p<end && (src.data[p]==' '||src.data[p]=='\t')) { p++; indent++; }
        if (p>=end || src.data[p]=='#') continue;
        size_t e=end; while (e>p && (src.data[e-1]==' '||src.data[e-1]=='\r')) e--;
        int seq=0;
        if (src.data[p]=='-' && (p+1>=e || src.data[p+1]==' ')) { seq=1; p++; if (p<e && src.data[p]==' ') p++; }
        L[n].indent=indent; L[n].seq=seq; L[n].content=xj_adup_n(src.data+p, e-p); n++;
    }
    if (n == 0) { free(L); return xj_alloc(XJ_NULL); }
    long idx = 0;
    xc_Json_t r = xy_parse_block(L, n, &idx, 0);
    free(L);
    return r;
}

/* ── XML stringify (element-tree convention) ── */
static void xx_escape(xj_sb* sb, const char* s) {
    for (; s && *s; s++) switch (*s) {
        case '<': xj_sb_put(sb,"&lt;");  break;
        case '>': xj_sb_put(sb,"&gt;");  break;
        case '&': xj_sb_put(sb,"&amp;"); break;
        case '"': xj_sb_put(sb,"&quot;");break;
        default:  xj_sb_putc(sb,*s);
    }
}
static void xx_scalar(xj_sb* sb, struct xc_json_node* v) {
    char b[64];
    switch (v->kind) {
        case XJ_BOOL:   xj_sb_put(sb, v->b?"true":"false"); break;
        case XJ_NUMBER: xj_num_str(b,v->num); xj_sb_put(sb,b); break;
        case XJ_STRING: xx_escape(sb, v->str); break;
        default: break;
    }
}
static void xx_emit(xj_sb* sb, struct xc_json_node* v, const char* tag, int indent) {
    if (v && v->kind == XJ_ARRAY) { for (long i=0;i<v->len;i++) xx_emit(sb, v->items[i], tag, indent); return; }
    for (int k=0;k<indent;k++) xj_sb_putc(sb,' ');
    xj_sb_putc(sb,'<'); xj_sb_put(sb,tag); xj_sb_putc(sb,'>');
    if (!v || xj_is_scalar(v)) { if (v) xx_scalar(sb,v); }
    else {
        xj_sb_putc(sb,'\n');
        for (long i=0;i<v->len;i++) xx_emit(sb, v->items[i], v->keys[i]?v->keys[i]:"item", indent+2);
        for (int k=0;k<indent;k++) xj_sb_putc(sb,' ');
    }
    xj_sb_putc(sb,'<'); xj_sb_putc(sb,'/'); xj_sb_put(sb,tag); xj_sb_put(sb,">\n");
}
xc_string_t xstd_xml_stringify_as(xc_Json_t v, xc_string_t root) {
    xj_sb s={0,0,0};
    char* r = xc_string_to_cstr(root);
    if (v && v->kind == XJ_ARRAY) {
        xj_sb_putc(&s,'<'); xj_sb_put(&s,r); xj_sb_put(&s,">\n");
        for (long i=0;i<v->len;i++) xx_emit(&s, v->items[i], "item", 2);
        xj_sb_putc(&s,'<'); xj_sb_putc(&s,'/'); xj_sb_put(&s,r); xj_sb_put(&s,">\n");
    } else xx_emit(&s, v, r, 0);
    free(r);
    if (!s.buf) return xc_str_copy("",0);
    return (xc_string_t){ .data=s.buf, .len=s.len };
}
xc_string_t xstd_xml_stringify(xc_Json_t v) { return xstd_xml_stringify_as(v, xc_string_from_cstr("root")); }

/* ── XML parse (elements, text, nesting; repeated tags -> array; attrs ignored) ── */
typedef struct { const char* p; const char* end; } xx_parser;
static void xx_decode_into(xj_sb* sb, const char* s, size_t n) {
    for (size_t i=0;i<n;i++) {
        if (s[i]=='&') {
            if (i+3<n && memcmp(s+i,"&lt;",4)==0)  { xj_sb_putc(sb,'<'); i+=3; continue; }
            if (i+3<n && memcmp(s+i,"&gt;",4)==0)  { xj_sb_putc(sb,'>'); i+=3; continue; }
            if (i+4<n && memcmp(s+i,"&amp;",5)==0) { xj_sb_putc(sb,'&'); i+=4; continue; }
            if (i+5<n && memcmp(s+i,"&quot;",6)==0){ xj_sb_putc(sb,'"'); i+=5; continue; }
            if (i+5<n && memcmp(s+i,"&apos;",6)==0){ xj_sb_putc(sb,'\''); i+=5; continue; }
        }
        xj_sb_putc(sb, s[i]);
    }
}
static void xx_ws_misc(xx_parser* P) {
    for (;;) {
        while (P->p<P->end && (*P->p==' '||*P->p=='\t'||*P->p=='\n'||*P->p=='\r')) P->p++;
        if (P->end-P->p>=4 && memcmp(P->p,"<!--",4)==0) { P->p+=4; while (P->p<P->end && !(P->end-P->p>=3 && memcmp(P->p,"-->",3)==0)) P->p++; if (P->p<P->end) P->p+=3; continue; }
        if (P->end-P->p>=2 && (memcmp(P->p,"<?",2)==0 || memcmp(P->p,"<!",2)==0)) { while (P->p<P->end && *P->p!='>') P->p++; if (P->p<P->end) P->p++; continue; }
        break;
    }
}
static void xx_obj_add(struct xc_json_node* obj, const char* k, size_t kn, struct xc_json_node* child) {
    for (long i=0;i<obj->len;i++) {
        if (obj->keys[i] && strlen(obj->keys[i])==kn && memcmp(obj->keys[i],k,kn)==0) {
            struct xc_json_node* ex = obj->items[i];
            if (ex->kind == XJ_ARRAY) xj_arr_push_n(ex, child);
            else { struct xc_json_node* a=xj_alloc(XJ_ARRAY); xj_arr_push_n(a,ex); xj_arr_push_n(a,child); obj->items[i]=a; }
            return;
        }
    }
    xj_obj_set_n(obj, k, kn, child);
}
static struct xc_json_node* xx_element(xx_parser* P, const char** tag, size_t* tlen) {
    P->p++;                                   /* '<' */
    const char* ns = P->p;
    while (P->p<P->end && *P->p!=' '&&*P->p!='\t'&&*P->p!='\n'&&*P->p!='\r'&&*P->p!='>'&&*P->p!='/') P->p++;
    *tag = ns; *tlen = (size_t)(P->p - ns);
    while (P->p<P->end && *P->p!='>'&&*P->p!='/') P->p++;     /* skip attributes */
    int self = 0;
    if (P->p<P->end && *P->p=='/') { self=1; P->p++; }
    if (P->p<P->end && *P->p=='>') P->p++;
    if (self) { struct xc_json_node* nd=xj_alloc(XJ_STRING); nd->str=xj_adup_n("",0); return nd; }
    struct xc_json_node* obj = xj_alloc(XJ_OBJECT);
    xj_sb text = {0,0,0};
    int hasChild = 0;
    while (P->p < P->end) {
        if (*P->p == '<') {
            if (P->end-P->p>=2 && P->p[1]=='/') { while (P->p<P->end && *P->p!='>') P->p++; if (P->p<P->end) P->p++; break; }
            if (P->end-P->p>=4 && memcmp(P->p,"<!--",4)==0) { xx_ws_misc(P); continue; }
            hasChild = 1;
            const char* ct; size_t cl;
            struct xc_json_node* child = xx_element(P, &ct, &cl);
            xx_obj_add(obj, ct, cl, child);
        } else {
            const char* ts = P->p; while (P->p<P->end && *P->p!='<') P->p++;
            xx_decode_into(&text, ts, (size_t)(P->p - ts));
        }
    }
    if (!hasChild) {
        struct xc_json_node* v = xj_scalar_from_text(text.buf?text.buf:"", text.len);
        if (text.buf) free(text.buf);
        return v;
    }
    if (text.buf) free(text.buf);
    return obj;
}
xc_Json_t xstd_xml_parse(xc_string_t src) {
    xx_parser P; P.p=src.data; P.end=src.data+src.len;
    xx_ws_misc(&P);
    if (P.p>=P.end || *P.p!='<') return xj_alloc(XJ_ERROR);
    const char* tag; size_t tl;
    return xx_element(&P, &tag, &tl);         /* returns the root element's value */
}

/* ─── Cryptography (std/crypto) ───────────────────────────────────────────────
 * Self-contained, dependency-light hashing, HMAC, hex/base64, and CSPRNG bytes.
 * Operate on xc_bytes_t; digests are heap-allocated fresh buffers.
 */
static xc_bytes_t xc_bytes_new(const unsigned char* p, size_t n) {
    unsigned char* b = (unsigned char*)xc_heap_alloc(n ? n : 1);
    if (!b) abort();
    if (n && p) memcpy(b, p, n);
    return (xc_bytes_t){ .data = b, .len = n };
}

/* ---- SHA-256 (FIPS 180-4) ---- */
#define XROR32(x,n) (((x) >> (n)) | ((x) << (32 - (n))))
static const uint32_t XK256[64] = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2 };
typedef struct { uint32_t s[8]; uint64_t len; unsigned char buf[64]; size_t n; } xsha256;
static void xsha256_block(xsha256* c, const unsigned char* p) {
    uint32_t w[64];
    for (int i=0;i<16;i++) w[i]=((uint32_t)p[i*4]<<24)|((uint32_t)p[i*4+1]<<16)|((uint32_t)p[i*4+2]<<8)|p[i*4+3];
    for (int i=16;i<64;i++){ uint32_t s0=XROR32(w[i-15],7)^XROR32(w[i-15],18)^(w[i-15]>>3);
        uint32_t s1=XROR32(w[i-2],17)^XROR32(w[i-2],19)^(w[i-2]>>10); w[i]=w[i-16]+s0+w[i-7]+s1; }
    uint32_t a=c->s[0],b=c->s[1],cc=c->s[2],d=c->s[3],e=c->s[4],f=c->s[5],g=c->s[6],h=c->s[7];
    for (int i=0;i<64;i++){ uint32_t S1=XROR32(e,6)^XROR32(e,11)^XROR32(e,25); uint32_t ch=(e&f)^((~e)&g);
        uint32_t t1=h+S1+ch+XK256[i]+w[i]; uint32_t S0=XROR32(a,2)^XROR32(a,13)^XROR32(a,22);
        uint32_t maj=(a&b)^(a&cc)^(b&cc); uint32_t t2=S0+maj; h=g;g=f;f=e;e=d+t1;d=cc;cc=b;b=a;a=t1+t2; }
    c->s[0]+=a;c->s[1]+=b;c->s[2]+=cc;c->s[3]+=d;c->s[4]+=e;c->s[5]+=f;c->s[6]+=g;c->s[7]+=h;
}
static void xsha256_init(xsha256* c){ c->s[0]=0x6a09e667;c->s[1]=0xbb67ae85;c->s[2]=0x3c6ef372;c->s[3]=0xa54ff53a;
    c->s[4]=0x510e527f;c->s[5]=0x9b05688c;c->s[6]=0x1f83d9ab;c->s[7]=0x5be0cd19;c->len=0;c->n=0; }
static void xsha256_update(xsha256* c,const unsigned char* p,size_t n){ c->len+=n;
    while(n){ size_t k=64-c->n; if(k>n)k=n; memcpy(c->buf+c->n,p,k); c->n+=k;p+=k;n-=k; if(c->n==64){xsha256_block(c,c->buf);c->n=0;} } }
static void xsha256_final(xsha256* c, unsigned char* out){ uint64_t bits=c->len*8; unsigned char pad=0x80;
    xsha256_update(c,&pad,1); unsigned char z=0; while(c->n!=56) xsha256_update(c,&z,1);
    unsigned char L[8]; for(int i=0;i<8;i++) L[i]=(unsigned char)(bits>>(56-8*i)); xsha256_update(c,L,8);
    for(int i=0;i<8;i++){ out[i*4]=(unsigned char)(c->s[i]>>24);out[i*4+1]=(unsigned char)(c->s[i]>>16);
        out[i*4+2]=(unsigned char)(c->s[i]>>8);out[i*4+3]=(unsigned char)c->s[i]; } }
xc_bytes_t xstd_sha256(xc_bytes_t in){ xsha256 c; xsha256_init(&c); xsha256_update(&c,in.data,in.len);
    unsigned char d[32]; xsha256_final(&c,d); return xc_bytes_new(d,32); }

/* ---- SHA-1 (FIPS 180) ---- */
#define XROL32(x,n) (((x) << (n)) | ((x) >> (32 - (n))))
typedef struct { uint32_t s[5]; uint64_t len; unsigned char buf[64]; size_t n; } xsha1;
static void xsha1_block(xsha1* c, const unsigned char* p){
    uint32_t w[80];
    for(int i=0;i<16;i++) w[i]=((uint32_t)p[i*4]<<24)|((uint32_t)p[i*4+1]<<16)|((uint32_t)p[i*4+2]<<8)|p[i*4+3];
    for(int i=16;i<80;i++) w[i]=XROL32(w[i-3]^w[i-8]^w[i-14]^w[i-16],1);
    uint32_t a=c->s[0],b=c->s[1],cc=c->s[2],d=c->s[3],e=c->s[4];
    for(int i=0;i<80;i++){ uint32_t f,k;
        if(i<20){f=(b&cc)|((~b)&d);k=0x5a827999;}
        else if(i<40){f=b^cc^d;k=0x6ed9eba1;}
        else if(i<60){f=(b&cc)|(b&d)|(cc&d);k=0x8f1bbcdc;}
        else{f=b^cc^d;k=0xca62c1d6;}
        uint32_t t=XROL32(a,5)+f+e+k+w[i]; e=d;d=cc;cc=XROL32(b,30);b=a;a=t; }
    c->s[0]+=a;c->s[1]+=b;c->s[2]+=cc;c->s[3]+=d;c->s[4]+=e;
}
static void xsha1_init(xsha1* c){ c->s[0]=0x67452301;c->s[1]=0xEFCDAB89;c->s[2]=0x98BADCFE;c->s[3]=0x10325476;c->s[4]=0xC3D2E1F0;c->len=0;c->n=0; }
static void xsha1_update(xsha1* c,const unsigned char* p,size_t n){ c->len+=n;
    while(n){ size_t k=64-c->n; if(k>n)k=n; memcpy(c->buf+c->n,p,k); c->n+=k;p+=k;n-=k; if(c->n==64){xsha1_block(c,c->buf);c->n=0;} } }
static void xsha1_final(xsha1* c, unsigned char* out){ uint64_t bits=c->len*8; unsigned char pad=0x80;
    xsha1_update(c,&pad,1); unsigned char z=0; while(c->n!=56) xsha1_update(c,&z,1);
    unsigned char L[8]; for(int i=0;i<8;i++) L[i]=(unsigned char)(bits>>(56-8*i)); xsha1_update(c,L,8);
    for(int i=0;i<5;i++){ out[i*4]=(unsigned char)(c->s[i]>>24);out[i*4+1]=(unsigned char)(c->s[i]>>16);
        out[i*4+2]=(unsigned char)(c->s[i]>>8);out[i*4+3]=(unsigned char)c->s[i]; } }
xc_bytes_t xstd_sha1(xc_bytes_t in){ xsha1 c; xsha1_init(&c); xsha1_update(&c,in.data,in.len);
    unsigned char d[20]; xsha1_final(&c,d); return xc_bytes_new(d,20); }

/* ---- MD5 (RFC 1321) ---- */
static const uint32_t XMD5K[64]={
    0xd76aa478,0xe8c7b756,0x242070db,0xc1bdceee,0xf57c0faf,0x4787c62a,0xa8304613,0xfd469501,
    0x698098d8,0x8b44f7af,0xffff5bb1,0x895cd7be,0x6b901122,0xfd987193,0xa679438e,0x49b40821,
    0xf61e2562,0xc040b340,0x265e5a51,0xe9b6c7aa,0xd62f105d,0x02441453,0xd8a1e681,0xe7d3fbc8,
    0x21e1cde6,0xc33707d6,0xf4d50d87,0x455a14ed,0xa9e3e905,0xfcefa3f8,0x676f02d9,0x8d2a4c8a,
    0xfffa3942,0x8771f681,0x6d9d6122,0xfde5380c,0xa4beea44,0x4bdecfa9,0xf6bb4b60,0xbebfbc70,
    0x289b7ec6,0xeaa127fa,0xd4ef3085,0x04881d05,0xd9d4d039,0xe6db99e5,0x1fa27cf8,0xc4ac5665,
    0xf4292244,0x432aff97,0xab9423a7,0xfc93a039,0x655b59c3,0x8f0ccc92,0xffeff47d,0x85845dd1,
    0x6fa87e4f,0xfe2ce6e0,0xa3014314,0x4e0811a1,0xf7537e82,0xbd3af235,0x2ad7d2bb,0xeb86d391 };
static const int XMD5S[64]={7,12,17,22,7,12,17,22,7,12,17,22,7,12,17,22,
    5,9,14,20,5,9,14,20,5,9,14,20,5,9,14,20,
    4,11,16,23,4,11,16,23,4,11,16,23,4,11,16,23,
    6,10,15,21,6,10,15,21,6,10,15,21,6,10,15,21};
typedef struct { uint32_t s[4]; uint64_t len; unsigned char buf[64]; size_t n; } xmd5;
static void xmd5_block(xmd5* c,const unsigned char* p){
    uint32_t m[16]; for(int i=0;i<16;i++) m[i]=(uint32_t)p[i*4]|((uint32_t)p[i*4+1]<<8)|((uint32_t)p[i*4+2]<<16)|((uint32_t)p[i*4+3]<<24);
    uint32_t a=c->s[0],b=c->s[1],cc=c->s[2],d=c->s[3];
    for(int i=0;i<64;i++){ uint32_t f; int g;
        if(i<16){f=(b&cc)|((~b)&d);g=i;}
        else if(i<32){f=(d&b)|((~d)&cc);g=(5*i+1)&15;}
        else if(i<48){f=b^cc^d;g=(3*i+5)&15;}
        else{f=cc^(b|(~d));g=(7*i)&15;}
        uint32_t t=d; d=cc; cc=b; uint32_t x=a+f+XMD5K[i]+m[g]; b=b+XROL32(x,XMD5S[i]); a=t; }
    c->s[0]+=a;c->s[1]+=b;c->s[2]+=cc;c->s[3]+=d;
}
static void xmd5_init(xmd5* c){ c->s[0]=0x67452301;c->s[1]=0xefcdab89;c->s[2]=0x98badcfe;c->s[3]=0x10325476;c->len=0;c->n=0; }
static void xmd5_update(xmd5* c,const unsigned char* p,size_t n){ c->len+=n;
    while(n){ size_t k=64-c->n; if(k>n)k=n; memcpy(c->buf+c->n,p,k); c->n+=k;p+=k;n-=k; if(c->n==64){xmd5_block(c,c->buf);c->n=0;} } }
static void xmd5_final(xmd5* c, unsigned char* out){ uint64_t bits=c->len*8; unsigned char pad=0x80;
    xmd5_update(c,&pad,1); unsigned char z=0; while(c->n!=56) xmd5_update(c,&z,1);
    unsigned char L[8]; for(int i=0;i<8;i++) L[i]=(unsigned char)(bits>>(8*i)); xmd5_update(c,L,8);
    for(int i=0;i<4;i++){ out[i*4]=(unsigned char)c->s[i];out[i*4+1]=(unsigned char)(c->s[i]>>8);
        out[i*4+2]=(unsigned char)(c->s[i]>>16);out[i*4+3]=(unsigned char)(c->s[i]>>24); } }
xc_bytes_t xstd_md5(xc_bytes_t in){ xmd5 c; xmd5_init(&c); xmd5_update(&c,in.data,in.len);
    unsigned char d[16]; xmd5_final(&c,d); return xc_bytes_new(d,16); }

/* ---- HMAC-SHA256 (RFC 2104) ---- */
xc_bytes_t xstd_hmac_sha256(xc_bytes_t key, xc_bytes_t msg){
    unsigned char k[64]; memset(k,0,64);
    if(key.len>64){ xsha256 c; xsha256_init(&c); xsha256_update(&c,key.data,key.len); unsigned char kd[32]; xsha256_final(&c,kd); memcpy(k,kd,32); }
    else memcpy(k,key.data,key.len);
    unsigned char ipad[64],opad[64];
    for(int i=0;i<64;i++){ ipad[i]=k[i]^0x36; opad[i]=k[i]^0x5c; }
    unsigned char inner[32];
    { xsha256 c; xsha256_init(&c); xsha256_update(&c,ipad,64); xsha256_update(&c,msg.data,msg.len); xsha256_final(&c,inner); }
    unsigned char out[32];
    { xsha256 c; xsha256_init(&c); xsha256_update(&c,opad,64); xsha256_update(&c,inner,32); xsha256_final(&c,out); }
    return xc_bytes_new(out,32);
}

/* ---- hex ---- */
xc_string_t xstd_hex(xc_bytes_t b){
    static const char* H="0123456789abcdef";
    char* s=(char*)xc_heap_alloc(b.len*2+1); if(!s) abort();
    for(size_t i=0;i<b.len;i++){ s[i*2]=H[b.data[i]>>4]; s[i*2+1]=H[b.data[i]&15]; }
    s[b.len*2]='\0'; return (xc_string_t){ .data=s, .len=b.len*2 };
}
static int xhexv(char c){ if(c>='0'&&c<='9')return c-'0'; if(c>='a'&&c<='f')return c-'a'+10; if(c>='A'&&c<='F')return c-'A'+10; return -1; }
xc_bytes_t xstd_unhex(xc_string_t s){
    size_t n=s.len/2; unsigned char* b=(unsigned char*)xc_heap_alloc(n?n:1); if(!b) abort();
    for(size_t i=0;i<n;i++){ int hi=xhexv(s.data[i*2]); int lo=xhexv(s.data[i*2+1]); b[i]=(unsigned char)(((hi<0?0:hi)<<4)|(lo<0?0:lo)); }
    return (xc_bytes_t){ .data=b, .len=n };
}

/* ---- base64 (standard alphabet, padded) ---- */
xc_string_t xstd_base64(xc_bytes_t in){
    static const char* A="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t olen=((in.len+2)/3)*4; char* o=(char*)xc_heap_alloc(olen+1); if(!o) abort();
    size_t j=0; size_t i=0;
    while(i+3<=in.len){ uint32_t v=(in.data[i]<<16)|(in.data[i+1]<<8)|in.data[i+2];
        o[j++]=A[(v>>18)&63];o[j++]=A[(v>>12)&63];o[j++]=A[(v>>6)&63];o[j++]=A[v&63]; i+=3; }
    if(in.len-i==1){ uint32_t v=in.data[i]<<16; o[j++]=A[(v>>18)&63];o[j++]=A[(v>>12)&63];o[j++]='=';o[j++]='='; }
    else if(in.len-i==2){ uint32_t v=(in.data[i]<<16)|(in.data[i+1]<<8); o[j++]=A[(v>>18)&63];o[j++]=A[(v>>12)&63];o[j++]=A[(v>>6)&63];o[j++]='='; }
    o[j]='\0'; return (xc_string_t){ .data=o, .len=j };
}
static int xb64v(char c){ if(c>='A'&&c<='Z')return c-'A'; if(c>='a'&&c<='z')return c-'a'+26; if(c>='0'&&c<='9')return c-'0'+52; if(c=='+')return 62; if(c=='/')return 63; return -1; }
xc_bytes_t xstd_unbase64(xc_string_t s){
    unsigned char* o=(unsigned char*)xc_heap_alloc(s.len/4*3+3); if(!o) abort();
    size_t j=0; int q[4]; int qn=0;
    for(size_t i=0;i<s.len;i++){ char c=s.data[i]; if(c=='='||c=='\n'||c=='\r'||c==' ') continue; int v=xb64v(c); if(v<0) continue;
        q[qn++]=v; if(qn==4){ o[j++]=(unsigned char)((q[0]<<2)|(q[1]>>4)); o[j++]=(unsigned char)((q[1]<<4)|(q[2]>>2)); o[j++]=(unsigned char)((q[2]<<6)|q[3]); qn=0; } }
    if(qn>=2){ o[j++]=(unsigned char)((q[0]<<2)|(q[1]>>4)); if(qn>=3) o[j++]=(unsigned char)((q[1]<<4)|(q[2]>>2)); }
    return (xc_bytes_t){ .data=o, .len=j };
}

/* ---- CSPRNG bytes (/dev/urandom) ---- */
xc_bytes_t xstd_random_bytes(xc_integer_t n){
    if(n<0) n=0; unsigned char* b=(unsigned char*)xc_heap_alloc((size_t)(n?n:1)); if(!b) abort();
    FILE* f=fopen("/dev/urandom","rb");
    if(f){ size_t got=fread(b,1,(size_t)n,f); fclose(f); if(got==(size_t)n) return (xc_bytes_t){ .data=b, .len=(size_t)n }; }
    for(xc_integer_t i=0;i<n;i++) b[i]=(unsigned char)(rand()&0xff);   /* fallback */
    return (xc_bytes_t){ .data=b, .len=(size_t)n };
}

/* ─── Web server (std/web) ────────────────────────────────────────────────────
 * A minimal blocking HTTP/1.1 server. The compiler generates a dispatcher that
 * matches (method, path) to a route handler and registers it via
 * xstd_web_set_dispatch; xstd_web_serve runs the accept loop.
 */
struct xc_web_request {
    char* method; char* path; char* query; char* headers; char* body; size_t blen;
    char* pk[16]; char* pv[16]; int pn;   /* captured path params */
};
struct xc_web_response { int status; char* body; size_t blen; char* ctype; };

static xc_string_t xw_str(const char* s) { return xc_str_copy(s ? s : "", s ? strlen(s) : 0); }
xc_string_t xstd_req_method(xc_Request_t r) { return xw_str(r->method); }
xc_string_t xstd_req_path(xc_Request_t r)   { return xw_str(r->path); }
xc_string_t xstd_req_body(xc_Request_t r)   { return xc_str_copy(r->body ? r->body : "", r->blen); }

xc_string_t xstd_req_param(xc_Request_t r, xc_string_t name) {
    for (int i = 0; i < r->pn; i++)
        if (strlen(r->pk[i]) == name.len && memcmp(r->pk[i], name.data, name.len) == 0) return xw_str(r->pv[i]);
    return xw_str("");
}
/* find "name=value" in a urlencoded-ish query string (no %-decoding) */
static xc_string_t xw_kv(const char* hay, const char* sep, xc_string_t name) {
    if (!hay) return xw_str("");
    size_t nl = name.len;
    const char* p = hay;
    while (*p) {
        const char* amp = strstr(p, sep);
        const char* end = amp ? amp : p + strlen(p);
        const char* eq = memchr(p, '=', (size_t)(end - p));
        if (eq && (size_t)(eq - p) == nl && memcmp(p, name.data, nl) == 0)
            return xc_str_copy(eq + 1, (size_t)(end - eq - 1));
        if (!amp) break;
        p = amp + strlen(sep);
    }
    return xw_str("");
}
xc_string_t xstd_req_query(xc_Request_t r, xc_string_t name) { return xw_kv(r->query, "&", name); }
xc_string_t xstd_req_header(xc_Request_t r, xc_string_t name) {
    /* headers are "Key: Value\r\n..."; case-insensitive key match */
    if (!r->headers) return xw_str("");
    const char* p = r->headers;
    while (*p) {
        const char* eol = strstr(p, "\r\n"); const char* end = eol ? eol : p + strlen(p);
        const char* colon = memchr(p, ':', (size_t)(end - p));
        if (colon && (size_t)(colon - p) == name.len) {
            int ok = 1;
            for (size_t i = 0; i < name.len; i++) if (tolower((unsigned char)p[i]) != tolower((unsigned char)name.data[i])) { ok = 0; break; }
            if (ok) { const char* v = colon + 1; while (v < end && *v == ' ') v++; return xc_str_copy(v, (size_t)(end - v)); }
        }
        if (!eol) break;
        p = eol + 2;
    }
    return xw_str("");
}
/* Each request source as a flat Json object (values are strings; `json as T`
 * coerces them). Keeps path/query/header parsing in the library, decoded generally. */
xc_Json_t xstd_req_params_json(xc_Request_t r) {
    xc_Json_t o = xstd_json_object();
    for (int i = 0; i < r->pn; i++)
        o = xstd_json_set(o, xw_str(r->pk[i]), xstd_json_string(xw_str(r->pv[i])));
    return o;
}
xc_Json_t xstd_req_query_json(xc_Request_t r) {
    xc_Json_t o = xstd_json_object();
    if (!r->query) return o;
    const char* p = r->query;
    while (*p) {
        const char* amp = strchr(p, '&');
        const char* end = amp ? amp : p + strlen(p);
        const char* eq = memchr(p, '=', (size_t)(end - p));
        if (eq) {
            xc_string_t k = xc_str_copy(p, (size_t)(eq - p));
            xc_string_t v = xc_str_copy(eq + 1, (size_t)(end - eq - 1));
            o = xstd_json_set(o, k, xstd_json_string(v));
        }
        if (!amp) break;
        p = amp + 1;
    }
    return o;
}
xc_Json_t xstd_req_headers_json(xc_Request_t r) {
    xc_Json_t o = xstd_json_object();
    if (!r->headers) return o;
    const char* p = r->headers;
    while (*p) {
        const char* eol = strstr(p, "\r\n");
        const char* end = eol ? eol : p + strlen(p);
        const char* colon = memchr(p, ':', (size_t)(end - p));
        if (colon) {
            size_t klen = (size_t)(colon - p);
            char* kbuf = (char*)malloc(klen + 1); if (!kbuf) abort();
            for (size_t i = 0; i < klen; i++) {
                char c = p[i];
                if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');   /* lowercase */
                if (c == '-') c = '_';                                  /* dash -> underscore */
                kbuf[i] = c;
            }
            const char* v = colon + 1; while (v < end && *v == ' ') v++;
            o = xstd_json_set(o, xc_str_copy(kbuf, klen), xstd_json_string(xc_str_copy(v, (size_t)(end - v))));
            free(kbuf);
        }
        if (!eol) break;
        p = eol + 2;
    }
    return o;
}
xc_Response_t xstd_resp(xc_integer_t status, xc_string_t body, xc_string_t ctype) {
    struct xc_web_response* r = (struct xc_web_response*)malloc(sizeof(*r)); if (!r) abort();
    r->status = (int)status; r->blen = body.len;
    r->body = (char*)malloc(body.len ? body.len : 1); if (!r->body) abort();
    if (body.len) memcpy(r->body, body.data, body.len);
    r->ctype = xc_string_to_cstr(ctype);
    return r;
}
/* match method (case-insensitive) and a "/a/:id/b" pattern against the request,
   capturing :params into the request on success */
xc_bool_t xstd_web_match(xc_Request_t req, xc_string_t method, xc_string_t pattern) {
    if (strlen(req->method) != method.len) return false;
    for (size_t i = 0; i < method.len; i++)
        if (tolower((unsigned char)req->method[i]) != tolower((unsigned char)method.data[i])) return false;
    req->pn = 0;
    const char* pp = req->path;
    char pat[1024]; size_t pl = pattern.len < 1023 ? pattern.len : 1023;
    memcpy(pat, pattern.data, pl); pat[pl] = '\0';
    const char* qp = pat;
    /* walk segments of both, split on '/' */
    while (1) {
        while (*pp == '/') pp++;
        while (*qp == '/') qp++;
        if (*pp == '\0' && *qp == '\0') return true;
        if (*pp == '\0' || *qp == '\0') return false;
        const char* ps = pp; while (*pp && *pp != '/') pp++;
        const char* qs = qp; while (*qp && *qp != '/') qp++;
        size_t plen2 = (size_t)(pp - ps), qlen = (size_t)(qp - qs);
        if (qlen > 0 && qs[0] == ':') {
            if (req->pn < 16) { req->pk[req->pn] = xj_strdup_n(qs + 1, qlen - 1); req->pv[req->pn] = xj_strdup_n(ps, plen2); req->pn++; }
        } else {
            if (plen2 != qlen || memcmp(ps, qs, plen2) != 0) return false;
        }
    }
}

static xc_Response_t (*xc_web_dispatch_fn)(xc_Request_t) = NULL;
void xstd_web_set_dispatch(xc_Response_t (*fn)(xc_Request_t)) { xc_web_dispatch_fn = fn; }

/* Handler-interface model: a mutable response the handler fills in. */
void xstd_resp_set(xc_HttpResponse_t r, xc_integer_t status, xc_string_t body, xc_string_t ctype) {
    r->status = (int)status; r->blen = body.len;
    if (r->body) free(r->body);                  /* a handler may set the response twice */
    r->body = (char*)malloc(body.len ? body.len : 1); if (!r->body) abort();
    if (body.len) memcpy(r->body, body.data, body.len);
    if (r->ctype) free(r->ctype);
    r->ctype = xc_string_to_cstr(ctype);
}
xc_integer_t xstd_resp_status(xc_HttpResponse_t r) { return (xc_integer_t)r->status; }

static void (*xc_web_handler_fn)(xc_HttpRequest_t, xc_HttpResponse_t) = NULL;
void xstd_web_set_handler(void (*fn)(xc_HttpRequest_t, xc_HttpResponse_t)) { xc_web_handler_fn = fn; }

/* Content-Length from a complete header block (case-insensitive, portable). */
/* Largest request the built-in server will buffer (headers + body). Beyond this
   the connection is dropped rather than grown without bound.

   Tunable per service with XI_MAX_REQUEST (bytes) — raise it for an endpoint
   that legitimately accepts large uploads, lower it to tighten the blast radius
   of a hostile client. Read once and floored so it can never be set small
   enough to reject a normal request's headers. */
#define XW_REQUEST_DEFAULT (32u * 1024u * 1024u)
#define XW_REQUEST_MIN     (64u * 1024u)
static size_t xw_module_request = 0;   /* set by a module's `maxRequestBytes = N` */
void xstd_set_max_request(xc_integer_t n) { if (n > 0) xw_module_request = (size_t)n; }
static size_t xw_max_request(void) {
    static size_t cached = 0;
    if (cached) return cached;
    /* Precedence: environment > module declaration > built-in default. */
    size_t v = xw_module_request > 0 ? xw_module_request : XW_REQUEST_DEFAULT;
    if (v < XW_REQUEST_MIN) v = XW_REQUEST_MIN;
    const char* e = getenv("XI_MAX_REQUEST");
    if (e && *e) {
        long long n = strtoll(e, NULL, 10);
        if (n > 0) v = (size_t)n < XW_REQUEST_MIN ? XW_REQUEST_MIN : (size_t)n;
    }
    cached = v;
    return cached;
}

static long xw_content_length(const char* hdr) {
    const char* p = hdr;
    while (*p) {
        const char* eol = strstr(p, "\r\n"); const char* end = eol ? eol : p + strlen(p);
        const char* colon = memchr(p, ':', (size_t)(end - p));
        if (colon && (size_t)(colon - p) == 14) {
            const char* k = "content-length"; int ok = 1;
            for (size_t i = 0; i < 14; i++) if (tolower((unsigned char)p[i]) != k[i]) { ok = 0; break; }
            if (ok) { const char* v = colon + 1; while (*v == ' ') v++; return strtol(v, NULL, 10); }
        }
        if (!eol) break;
        p = eol + 2;
    }
    return 0;
}

static const char* xw_reason(int s) {
    switch (s) { case 200: return "OK"; case 201: return "Created"; case 204: return "No Content";
        case 400: return "Bad Request"; case 401: return "Unauthorized"; case 403: return "Forbidden";
        case 404: return "Not Found"; case 500: return "Internal Server Error"; default: return "OK"; }
}
/* Per-connection handling, parameterised over read/write so the same logic
   serves plaintext sockets and TLS sessions. */
typedef long (*xw_rd_fn)(void* conn, char* buf, long n);
typedef long (*xw_wr_fn)(void* conn, const char* buf, long n);

static void xw_serve_conn(void* conn, xw_rd_fn rd, xw_wr_fn wr) {
    size_t cap = 8192, len = 0; char* buf = (char*)malloc(cap);
    if (!buf) abort();
    long need_total = -1; size_t hdr_end = 0;
    while (1) {
        /* Keep room for the read AND the NUL terminator written below: the old
           `len + 4096 > cap` allowed len to reach exactly cap, so `buf[len]`
           wrote one byte past the block on a request with >=8 KB of headers. */
        if (len + 4096 + 1 > cap) {
            cap *= 2;
            char* nb = (char*)realloc(buf, cap);
            if (!nb) { free(buf); return; }
            buf = nb;
        }
        /* Bound the request: an attacker-supplied Content-Length (or a socket
           that never closes) otherwise grows this buffer until the process dies. */
        if (len > xw_max_request()) { free(buf); return; }
        long n = rd(conn, buf + len, 4096);
        if (n <= 0) break;
        len += (size_t)n;
        if (hdr_end == 0) {
            buf[len] = '\0';
            char* h = strstr(buf, "\r\n\r\n");
            if (h) {
                hdr_end = (size_t)(h - buf) + 4;
                long clen = xw_content_length(buf);
                if (clen > 0 && (size_t)clen > xw_max_request()) { free(buf); return; }
                need_total = (long)hdr_end + (clen > 0 ? clen : 0);
            }
        }
        if (need_total >= 0 && (long)len >= need_total) break;
    }
    if (len == 0) { free(buf); return; }
    buf[len] = '\0';
    struct xc_web_request req; memset(&req, 0, sizeof(req));
    char* sp1 = strchr(buf, ' ');
    char* sp2 = sp1 ? strchr(sp1 + 1, ' ') : NULL;
    char* eol = strstr(buf, "\r\n");
    if (sp1 && sp2 && eol) {
        req.method = xj_strdup_n(buf, (size_t)(sp1 - buf));
        char* path = xj_strdup_n(sp1 + 1, (size_t)(sp2 - sp1 - 1));
        char* q = strchr(path, '?');
        if (q) { *q = '\0'; req.query = xj_strdup_n(q + 1, strlen(q + 1)); } else req.query = xj_strdup_n("", 0);
        req.path = path;
        req.headers = xj_strdup_n(eol + 2, hdr_end > (size_t)(eol + 2 - buf) ? (size_t)(buf + hdr_end - 2 - (eol + 2)) : 0);
        req.body = xj_strdup_n(buf + hdr_end, len - hdr_end);
        req.blen = len - hdr_end;
    }
    xw_request_count++;
    struct xc_web_response rs; memset(&rs, 0, sizeof(rs));
    struct xc_web_response* resp = NULL;
    /* Per-request arena (memory-management Phase 1). The handler's value
       allocations — strings (xc_str_copy), JSON nodes (xj_alloc) — come from a
       region that is freed once the response is on the wire, so a long-running
       server reclaims each request instead of leaking it. This is safe because
       the response body/ctype are malloc'd *copies* (see xstd_resp_set), so they
       outlive the arena; only a value the handler stashes into global state would
       dangle — the same share-nothing rule the per-thread arena already relies
       on. prev/restore keeps it correct if serve runs inside a thread arena. */
    xc_arena* prevArena = xc_tls_arena;
    xc_arena* reqArena  = xc_arena_new();
    xc_tls_arena = reqArena;
    if (xc_web_handler_fn && req.method) {
        xc_web_handler_fn(&req, &rs);
        resp = &rs;
    } else if (xc_web_dispatch_fn && req.method) {
        resp = xc_web_dispatch_fn(&req);
    }
    int has = resp && resp->status != 0;
    int status = has ? resp->status : 404;
    const char* body = has ? resp->body : "Not Found";
    size_t blen = has ? resp->blen : 9;
    const char* ctype = (has && resp->ctype) ? resp->ctype : "text/plain";
    char head[512];
    int hl = snprintf(head, sizeof(head),
        "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n",
        status, xw_reason(status), ctype, blen);
    wr(conn, head, hl);
    if (blen) wr(conn, body, (long)blen);
    /* Response sent: reclaim the request arena and the per-request malloc'd
       parts (response body/ctype copies, the dispatch-allocated struct, and the
       parsed request fields — all previously leaked once per request). */
    if (resp) {
        if (resp->body)  free(resp->body);
        if (resp->ctype) free(resp->ctype);
        if (resp != &rs) free(resp);     /* dispatch path malloc'd the struct */
    }
    free(req.method); free(req.path); free(req.query); free(req.headers); free(req.body);
    xc_tls_arena = prevArena;
    xc_arena_destroy(reqArena);
    free(buf);
}

static long xw_fd_rd(void* c, char* b, long n) { return (long)recv((int)(intptr_t)c, b, (size_t)n, 0); }
static long xw_fd_wr(void* c, const char* b, long n) { return (long)send((int)(intptr_t)c, b, (size_t)n, 0); }

/* Cooperative shutdown for the blocking serve loops. web.shutdown() sets the
   flag and closes the listening socket, which unblocks the accept() so the loop
   can return. Safe to call from another thread (e.g. a runWithDelay timer). */
static volatile int xw_stop = 0;
static int xw_listen_fd = -1;
void xstd_web_shutdown(void) {
    xw_stop = 1;
    int fd = xw_listen_fd;
    xw_listen_fd = -1;
    if (fd >= 0) { shutdown(fd, SHUT_RDWR); close(fd); }
}

void xstd_web_serve(xc_integer_t port) {
    int fd = (int)xstd_tcp_listen(port, 64);
    if (fd < 0) { fprintf(stderr, "web: cannot listen on port %lld\n", (long long)port); return; }
    xw_stop = 0;
    xw_listen_fd = fd;
    fprintf(stderr, "web: serving on http://0.0.0.0:%lld\n", (long long)port);
    while (!xw_stop) {
        int c = accept(fd, NULL, NULL);
        if (c < 0) { if (xw_stop) break; continue; }
        xw_serve_conn((void*)(intptr_t)c, xw_fd_rd, xw_fd_wr);
        close(c);
    }
    if (xw_listen_fd >= 0) { close(xw_listen_fd); xw_listen_fd = -1; }
    fprintf(stderr, "web: shut down\n");
}

/* ─── HTTPS (opt-in: build with XC_TLS=1, needs OpenSSL) ─────────────────────── */
#ifdef XC_HAVE_TLS
#include <openssl/ssl.h>
#include <openssl/err.h>
static long xw_ssl_rd(void* c, char* b, long n) { int r = SSL_read((SSL*)c, b, (int)n); return r; }
static long xw_ssl_wr(void* c, const char* b, long n) { int r = SSL_write((SSL*)c, b, (int)n); return (long)r; }
void xstd_web_serve_tls(xc_integer_t port, xc_string_t certPath, xc_string_t keyPath) {
    SSL_load_error_strings();
    SSL_library_init();
    SSL_CTX* ctx = SSL_CTX_new(TLS_server_method());
    if (!ctx) { fprintf(stderr, "web: TLS context init failed\n"); return; }
    char* cert = xc_string_to_cstr(certPath);
    char* key  = xc_string_to_cstr(keyPath);
    if (SSL_CTX_use_certificate_file(ctx, cert, SSL_FILETYPE_PEM) <= 0 ||
        SSL_CTX_use_PrivateKey_file(ctx, key, SSL_FILETYPE_PEM) <= 0) {
        fprintf(stderr, "web: cannot load cert/key (%s, %s)\n", cert, key);
        SSL_CTX_free(ctx); free(cert); free(key); return;
    }
    free(cert); free(key);
    int fd = (int)xstd_tcp_listen(port, 64);
    if (fd < 0) { fprintf(stderr, "web: cannot listen on port %lld\n", (long long)port); SSL_CTX_free(ctx); return; }
    fprintf(stderr, "web: serving on https://0.0.0.0:%lld\n", (long long)port);
    for (;;) {
        int c = accept(fd, NULL, NULL);
        if (c < 0) continue;
        SSL* ssl = SSL_new(ctx);
        SSL_set_fd(ssl, c);
        if (SSL_accept(ssl) > 0) {
            xw_serve_conn(ssl, xw_ssl_rd, xw_ssl_wr);
        }
        SSL_shutdown(ssl);
        SSL_free(ssl);
        close(c);
    }
}
/* HTTPS client: TCP-connect, TLS handshake (with SNI), send the request, read
   the whole response, return it as a string. "" on failure. */
xc_string_t xstd_https_fetch(xc_string_t host, xc_integer_t port, xc_string_t request) {
    int fd = (int)xstd_tcp_connect(host, port);
    if (fd < 0) return xc_str_copy("", 0);
    SSL_load_error_strings();
    SSL_library_init();
    SSL_CTX* ctx = SSL_CTX_new(TLS_client_method());
    if (!ctx) { close(fd); return xc_str_copy("", 0); }
    SSL* ssl = SSL_new(ctx);
    SSL_set_fd(ssl, fd);
    char* hn = xc_string_to_cstr(host);
    SSL_set_tlsext_host_name(ssl, hn);   /* SNI */
    if (SSL_connect(ssl) <= 0) { free(hn); SSL_free(ssl); SSL_CTX_free(ctx); close(fd); return xc_str_copy("", 0); }
    free(hn);
    SSL_write(ssl, request.data, (int)request.len);
    size_t cap = 8192, len = 0; char* buf = (char*)malloc(cap);
    for (;;) {
        if (len + 4096 > cap) { cap *= 2; buf = (char*)realloc(buf, cap); }
        int n = SSL_read(ssl, buf + len, 4096);
        if (n <= 0) break;
        len += (size_t)n;
    }
    xc_string_t out = xc_str_copy(buf, len);
    free(buf);
    SSL_shutdown(ssl); SSL_free(ssl); SSL_CTX_free(ctx); close(fd);
    return out;
}
#else
void xstd_web_serve_tls(xc_integer_t port, xc_string_t certPath, xc_string_t keyPath) {
    (void)port; (void)certPath; (void)keyPath;
    fprintf(stderr, "web: TLS not built in — recompile with XC_TLS=1 (needs OpenSSL)\n");
}
xc_string_t xstd_https_fetch(xc_string_t host, xc_integer_t port, xc_string_t request) {
    (void)host; (void)port; (void)request;
    fprintf(stderr, "http: TLS not built in — recompile with XC_TLS=1 for https\n");
    return xc_str_copy("", 0);
}
#endif

/* ─── HTTP/2 server (opt-in: XC_HTTP2=1, needs OpenSSL + nghttp2) ────────────── */
#if defined(XC_HAVE_TLS) && defined(XC_HAVE_HTTP2)
#include <nghttp2/nghttp2.h>

struct h2_stream {
    int32_t id;
    char* method; char* path; char* query;
    char* headers; size_t hlen, hcap;     /* "k: v\r\n" block */
    char* body;    size_t blen, bcap;
    char* resp;    size_t rlen, roff;     /* response body to stream out */
};
static struct h2_stream* h2_stream_new(int32_t id) {
    struct h2_stream* s = (struct h2_stream*)calloc(1, sizeof(*s)); if (!s) abort();
    s->id = id; return s;
}
static void h2_stream_free(struct h2_stream* s) {
    if (!s) return;
    free(s->method); free(s->path); free(s->query); free(s->headers);
    free(s->body); free(s->resp); free(s);
}
static void h2_append(char** buf, size_t* len, size_t* cap, const char* d, size_t n) {
    if (*len + n + 1 > *cap) { *cap = (*cap ? *cap * 2 : 256); if (*cap < *len + n + 1) *cap = *len + n + 1; *buf = (char*)realloc(*buf, *cap); }
    memcpy(*buf + *len, d, n); *len += n; (*buf)[*len] = '\0';
}

static ssize_t h2_send_cb(nghttp2_session* s, const uint8_t* data, size_t len, int flags, void* user) {
    (void)s; (void)flags;
    int n = SSL_write((SSL*)user, data, (int)len);
    if (n <= 0) return NGHTTP2_ERR_CALLBACK_FAILURE;
    return (ssize_t)n;
}
static int h2_on_begin_headers(nghttp2_session* s, const nghttp2_frame* frame, void* user) {
    (void)user;
    if (frame->hd.type == NGHTTP2_HEADERS && frame->headers.cat == NGHTTP2_HCAT_REQUEST) {
        struct h2_stream* st = h2_stream_new(frame->hd.stream_id);
        nghttp2_session_set_stream_user_data(s, frame->hd.stream_id, st);
    }
    return 0;
}
static int h2_on_header(nghttp2_session* s, const nghttp2_frame* frame,
                        const uint8_t* name, size_t namelen,
                        const uint8_t* value, size_t valuelen, uint8_t flags, void* user) {
    (void)flags; (void)user;
    struct h2_stream* st = (struct h2_stream*)nghttp2_session_get_stream_user_data(s, frame->hd.stream_id);
    if (!st) return 0;
    if (namelen == 7 && memcmp(name, ":method", 7) == 0) {
        st->method = xj_strdup_n((const char*)value, valuelen);
    } else if (namelen == 5 && memcmp(name, ":path", 5) == 0) {
        const char* q = (const char*)memchr(value, '?', valuelen);
        if (q) {
            st->path  = xj_strdup_n((const char*)value, (size_t)(q - (const char*)value));
            st->query = xj_strdup_n(q + 1, valuelen - (size_t)(q - (const char*)value) - 1);
        } else {
            st->path = xj_strdup_n((const char*)value, valuelen);
            st->query = xj_strdup_n("", 0);
        }
    } else if (namelen > 0 && name[0] != ':') {
        h2_append(&st->headers, &st->hlen, &st->hcap, (const char*)name, namelen);
        h2_append(&st->headers, &st->hlen, &st->hcap, ": ", 2);
        h2_append(&st->headers, &st->hlen, &st->hcap, (const char*)value, valuelen);
        h2_append(&st->headers, &st->hlen, &st->hcap, "\r\n", 2);
    }
    return 0;
}
static int h2_on_data_chunk(nghttp2_session* s, uint8_t flags, int32_t sid,
                            const uint8_t* data, size_t len, void* user) {
    (void)flags; (void)user;
    struct h2_stream* st = (struct h2_stream*)nghttp2_session_get_stream_user_data(s, sid);
    if (st) h2_append(&st->body, &st->blen, &st->bcap, (const char*)data, len);
    return 0;
}
static ssize_t h2_data_read(nghttp2_session* s, int32_t sid, uint8_t* buf, size_t length,
                            uint32_t* data_flags, nghttp2_data_source* source, void* user) {
    (void)s; (void)sid; (void)user;
    struct h2_stream* st = (struct h2_stream*)source->ptr;
    size_t remain = st->rlen - st->roff;
    size_t n = remain < length ? remain : length;
    if (n) memcpy(buf, st->resp + st->roff, n);
    st->roff += n;
    if (st->roff >= st->rlen) *data_flags |= NGHTTP2_DATA_FLAG_EOF;
    return (ssize_t)n;
}
static void h2_respond(nghttp2_session* s, struct h2_stream* st) {
    struct xc_web_request req; memset(&req, 0, sizeof(req));
    req.method  = st->method  ? st->method  : (char*)"GET";
    req.path    = st->path    ? st->path    : (char*)"/";
    req.query   = st->query   ? st->query   : (char*)"";
    req.headers = st->headers ? st->headers : (char*)"";
    req.body    = st->body; req.blen = st->blen;
    struct xc_web_response rs; memset(&rs, 0, sizeof(rs));
    if (xc_web_handler_fn) xc_web_handler_fn(&req, &rs);
    int has = rs.status != 0;
    int status = has ? rs.status : 404;
    const char* body = has ? rs.body : "Not Found";
    size_t blen = has ? rs.blen : 9;
    const char* ctype = (has && rs.ctype) ? rs.ctype : "text/plain";
    st->resp = (char*)malloc(blen ? blen : 1); if (blen) memcpy(st->resp, body, blen);
    st->rlen = blen; st->roff = 0;
    char sstr[8]; snprintf(sstr, sizeof(sstr), "%d", status);
    char clen[24]; snprintf(clen, sizeof(clen), "%zu", blen);
    nghttp2_nv nv[3];
    nv[0].name = (uint8_t*)":status";        nv[0].value = (uint8_t*)sstr;  nv[0].namelen = 7;  nv[0].valuelen = strlen(sstr);  nv[0].flags = NGHTTP2_NV_FLAG_NONE;
    nv[1].name = (uint8_t*)"content-type";   nv[1].value = (uint8_t*)ctype; nv[1].namelen = 12; nv[1].valuelen = strlen(ctype); nv[1].flags = NGHTTP2_NV_FLAG_NONE;
    nv[2].name = (uint8_t*)"content-length"; nv[2].value = (uint8_t*)clen;  nv[2].namelen = 14; nv[2].valuelen = strlen(clen);  nv[2].flags = NGHTTP2_NV_FLAG_NONE;
    nghttp2_data_provider prd; prd.source.ptr = st; prd.read_callback = h2_data_read;
    nghttp2_submit_response(s, st->id, nv, 3, &prd);
}
static int h2_on_frame_recv(nghttp2_session* s, const nghttp2_frame* frame, void* user) {
    (void)user;
    if ((frame->hd.type == NGHTTP2_DATA || frame->hd.type == NGHTTP2_HEADERS) &&
        (frame->hd.flags & NGHTTP2_FLAG_END_STREAM)) {
        struct h2_stream* st = (struct h2_stream*)nghttp2_session_get_stream_user_data(s, frame->hd.stream_id);
        if (st) h2_respond(s, st);
    }
    return 0;
}
static int h2_on_stream_close(nghttp2_session* s, int32_t sid, uint32_t ec, void* user) {
    (void)ec; (void)user;
    h2_stream_free((struct h2_stream*)nghttp2_session_get_stream_user_data(s, sid));
    return 0;
}
static int h2_alpn_cb(SSL* ssl, const unsigned char** out, unsigned char* outlen,
                      const unsigned char* in, unsigned int inlen, void* arg) {
    (void)ssl; (void)arg;
    if (nghttp2_select_next_protocol((unsigned char**)out, outlen, in, inlen) != 1)
        return SSL_TLSEXT_ERR_NOACK;
    return SSL_TLSEXT_ERR_OK;
}
static void h2_serve_conn(SSL* ssl) {
    nghttp2_session_callbacks* cbs;
    nghttp2_session_callbacks_new(&cbs);
    nghttp2_session_callbacks_set_send_callback(cbs, h2_send_cb);
    nghttp2_session_callbacks_set_on_begin_headers_callback(cbs, h2_on_begin_headers);
    nghttp2_session_callbacks_set_on_header_callback(cbs, h2_on_header);
    nghttp2_session_callbacks_set_on_data_chunk_recv_callback(cbs, h2_on_data_chunk);
    nghttp2_session_callbacks_set_on_frame_recv_callback(cbs, h2_on_frame_recv);
    nghttp2_session_callbacks_set_on_stream_close_callback(cbs, h2_on_stream_close);
    nghttp2_session* session;
    nghttp2_session_server_new(&session, cbs, ssl);
    nghttp2_session_callbacks_del(cbs);
    nghttp2_submit_settings(session, NGHTTP2_FLAG_NONE, NULL, 0);
    if (nghttp2_session_send(session) != 0) { nghttp2_session_del(session); return; }
    for (;;) {
        char buf[16384];
        int n = SSL_read(ssl, buf, sizeof(buf));
        if (n <= 0) break;
        ssize_t rv = nghttp2_session_mem_recv(session, (const uint8_t*)buf, (size_t)n);
        if (rv < 0) break;
        if (nghttp2_session_send(session) != 0) break;
        if (nghttp2_session_want_read(session) == 0 && nghttp2_session_want_write(session) == 0) break;
    }
    nghttp2_session_del(session);
}
void xstd_web_serve_http2(xc_integer_t port, xc_string_t certPath, xc_string_t keyPath) {
    SSL_load_error_strings(); SSL_library_init();
    SSL_CTX* ctx = SSL_CTX_new(TLS_server_method());
    if (!ctx) { fprintf(stderr, "web: TLS context init failed\n"); return; }
    char* cert = xc_string_to_cstr(certPath);
    char* key  = xc_string_to_cstr(keyPath);
    if (SSL_CTX_use_certificate_file(ctx, cert, SSL_FILETYPE_PEM) <= 0 ||
        SSL_CTX_use_PrivateKey_file(ctx, key, SSL_FILETYPE_PEM) <= 0) {
        fprintf(stderr, "web: cannot load cert/key (%s, %s)\n", cert, key);
        SSL_CTX_free(ctx); free(cert); free(key); return;
    }
    free(cert); free(key);
    SSL_CTX_set_alpn_select_cb(ctx, h2_alpn_cb, NULL);
    int fd = (int)xstd_tcp_listen(port, 64);
    if (fd < 0) { fprintf(stderr, "web: cannot listen on port %lld\n", (long long)port); SSL_CTX_free(ctx); return; }
    fprintf(stderr, "web: serving HTTP/2 on https://0.0.0.0:%lld\n", (long long)port);
    for (;;) {
        int c = accept(fd, NULL, NULL);
        if (c < 0) continue;
        SSL* ssl = SSL_new(ctx);
        SSL_set_fd(ssl, c);
        if (SSL_accept(ssl) > 0) {
            const unsigned char* alpn = NULL; unsigned int alpnlen = 0;
            SSL_get0_alpn_selected(ssl, &alpn, &alpnlen);
            if (alpn && alpnlen == 2 && memcmp(alpn, "h2", 2) == 0) {
                h2_serve_conn(ssl);
            } else {
                xw_serve_conn(ssl, xw_ssl_rd, xw_ssl_wr);   /* HTTP/1.1 fallback over TLS */
            }
        }
        SSL_shutdown(ssl); SSL_free(ssl); close(c);
    }
}
#else
void xstd_web_serve_http2(xc_integer_t port, xc_string_t certPath, xc_string_t keyPath) {
    (void)port; (void)certPath; (void)keyPath;
    fprintf(stderr, "web: HTTP/2 not built in — recompile with XC_HTTP2=1 (needs OpenSSL + nghttp2)\n");
}
#endif

/* ─── Threading (std/thread) ──────────────────────────────────────────────────
 * Share-nothing OS threads over thread-safe channels. A `parallel { }` block is
 * lifted by the compiler to a void*(void*) function and started here; the
 * returned handle supports cooperative stop, join, and a running check. The
 * current thread's control block is kept in thread-local storage so a body can
 * call thread.stopped().
 */
struct xc_chan_node { char* data; size_t len; struct xc_chan_node* next; };
struct xc_chan {
    pthread_mutex_t m; pthread_cond_t cv;
    struct xc_chan_node* head; struct xc_chan_node* tail; int closed;
};
struct xc_thread {
    pthread_t tid; volatile int stop; volatile int done;
    void* (*fn)(void*); void* arg;
};

xc_Channel_t xstd_chan_new(void) {
    struct xc_chan* c = (struct xc_chan*)calloc(1, sizeof(*c)); if (!c) abort();
    pthread_mutex_init(&c->m, NULL); pthread_cond_init(&c->cv, NULL);
    return c;
}
void xstd_chan_send(xc_Channel_t c, xc_string_t s) {
    struct xc_chan_node* n = (struct xc_chan_node*)malloc(sizeof(*n)); if (!n) abort();
    n->len = s.len; n->data = (char*)malloc(s.len ? s.len : 1); if (!n->data) abort();
    if (s.len) memcpy(n->data, s.data, s.len);
    n->next = NULL;
    pthread_mutex_lock(&c->m);
    if (c->tail) c->tail->next = n; else c->head = n;
    c->tail = n;
    pthread_cond_signal(&c->cv);
    pthread_mutex_unlock(&c->m);
}
xc_string_t xstd_chan_recv(xc_Channel_t c) {
    pthread_mutex_lock(&c->m);
    while (!c->head && !c->closed) pthread_cond_wait(&c->cv, &c->m);
    if (!c->head) { pthread_mutex_unlock(&c->m); return xc_str_copy("", 0); }
    struct xc_chan_node* n = c->head;
    c->head = n->next; if (!c->head) c->tail = NULL;
    pthread_mutex_unlock(&c->m);
    xc_string_t r = xc_str_copy(n->data, n->len);
    free(n->data); free(n);
    return r;
}
void xstd_chan_close(xc_Channel_t c) {
    pthread_mutex_lock(&c->m);
    c->closed = 1;
    pthread_cond_broadcast(&c->cv);
    pthread_mutex_unlock(&c->m);
}

static pthread_key_t xc_thread_key;
static pthread_once_t xc_thread_key_once = PTHREAD_ONCE_INIT;
static void xc_thread_key_init(void) { pthread_key_create(&xc_thread_key, NULL); }

static volatile xc_integer_t xc_thread_spawned = 0;   /* std/monitoring/thread */
static volatile xc_integer_t xc_thread_live = 0;
static void* xc_thread_trampoline(void* p) {
    struct xc_thread* t = (struct xc_thread*)p;
    pthread_setspecific(xc_thread_key, t);
    xc_arena* arena = xc_arena_new();   /* this thread's value allocations */
    xc_tls_arena = arena;
    t->fn(t->arg);
    xc_tls_arena = NULL;
    xc_arena_destroy(arena);            /* free everything the thread allocated */
    t->done = 1;
    xc_thread_live--;
    return NULL;
}
xc_Thread_t xstd_thread_spawn(void* (*fn)(void*), void* arg) {
    pthread_once(&xc_thread_key_once, xc_thread_key_init);
    struct xc_thread* t = (struct xc_thread*)calloc(1, sizeof(*t)); if (!t) abort();
    t->fn = fn; t->arg = arg;
    if (pthread_create(&t->tid, NULL, xc_thread_trampoline, t) != 0) { free(t); return NULL; }
    xc_thread_spawned++;
    xc_thread_live++;
    return t;
}

/* Thread counts, for std/monitoring/thread. Plain counters bumped either side of
   a spawn; `live` drops when the trampoline finishes. */
xc_integer_t xstd_thread_spawned_count(void) { return xc_thread_spawned; }
xc_integer_t xstd_thread_live_count(void)    { return xc_thread_live < 0 ? 0 : xc_thread_live; }
void xstd_thread_stop(xc_Thread_t t) { if (t) t->stop = 1; }
void xstd_thread_wait(xc_Thread_t t) { if (t) pthread_join(t->tid, NULL); }

/* ─── Future<T>: async result handle ────────────────────────────────────────
 * The worker runs without a per-thread arena, so everything it allocates leaks
 * onto the shared heap and outlives the await (the result must escape).         */
struct xc_future { pthread_t tid; void* (*fn)(void*); void* arg; void* result; volatile int done; };
static void* xc_future_trampoline(void* p) {
    struct xc_future* f = (struct xc_future*)p;
    f->result = f->fn(f->arg);   /* allocate-and-leak: no arena to destroy */
    f->done = 1;
    return NULL;
}
xc_Future_t xstd_future_spawn(void* (*fn)(void*), void* arg) {
    struct xc_future* f = (struct xc_future*)calloc(1, sizeof(*f)); if (!f) abort();
    f->fn = fn; f->arg = arg;
    if (pthread_create(&f->tid, NULL, xc_future_trampoline, f) != 0) { free(f); abort(); }
    return f;
}
void* xstd_future_await(xc_Future_t f) {
    if (!f) return NULL;
    pthread_join(f->tid, NULL);
    return f->result;
}
xc_bool_t xstd_future_done(xc_Future_t f) { return f ? (f->done != 0) : true; }

/* ─── Scheduled jobs: a minimal cron scheduler ──────────────────────────────
 * Each of the 5 cron fields is parsed into a bitmask of matching values; the
 * scheduler wakes ~once a second and fires any job whose mask matches the
 * current local minute (deduped so a job fires at most once per minute).        */
/* A job is either cron (min..dow masks) or a fixed millisecond interval
 * (interval_ms > 0, next due at next_ms on the monotonic ms clock). */
typedef struct { uint64_t min, hour, dom, mon, dow; void (*fn)(void); long last;
                 long interval_ms; long long next_ms; } xc_sched_job;
static xc_sched_job xc_sched_jobs[128];
static int xc_sched_n = 0;

/* Parse one cron field (comma list of star, n, a-b, step forms) into a
 * bitmask of values in [lo,hi], indexed from lo. */
static uint64_t xc_cron_field(const char* s, int lo, int hi) {
    uint64_t mask = 0;
    const char* p = s;
    while (*p) {
        char term[64]; int ti = 0;
        while (*p && *p != ',') { if (ti < 63) term[ti++] = *p; p++; }
        term[ti] = 0;
        if (*p == ',') p++;
        int step = 1;
        char* slash = strchr(term, '/');
        if (slash) { step = atoi(slash + 1); *slash = 0; }
        int a, b;
        if (term[0] == '*' || term[0] == '?' || term[0] == 0) { a = lo; b = hi; }
        else {
            char* dash = strchr(term, '-');
            if (dash) { *dash = 0; a = atoi(term); b = atoi(dash + 1); }
            else { a = atoi(term); b = a; }
        }
        if (step < 1) step = 1;
        for (int v = a; v <= b; v += step) {
            int w = v;
            if (lo == 0 && hi == 6 && w == 7) w = 0;     /* dow: 7 == Sunday == 0 */
            if (w >= lo && w <= hi) mask |= (1ULL << (w - lo));
        }
    }
    return mask;
}
void xstd_sched_register(void (*fn)(void), const char* cron) {
    if (xc_sched_n >= 128) return;
    char fields[5][64]; int fi = 0, ci = 0;
    for (int k = 0; k < 5; k++) fields[k][0] = 0;
    const char* p = cron;
    while (*p && fi < 5) {
        if (*p == ' ' || *p == '\t') { if (ci > 0) { fields[fi][ci] = 0; fi++; ci = 0; } p++; continue; }
        if (ci < 63) fields[fi][ci++] = *p;
        p++;
    }
    if (ci > 0 && fi < 5) { fields[fi][ci] = 0; fi++; }
    xc_sched_job* j = &xc_sched_jobs[xc_sched_n++];
    j->min  = xc_cron_field(fields[0], 0, 59);
    j->hour = xc_cron_field(fields[1], 0, 23);
    j->dom  = xc_cron_field(fields[2], 1, 31);
    j->mon  = xc_cron_field(fields[3], 1, 12);
    j->dow  = xc_cron_field(fields[4], 0, 6);
    j->fn = fn; j->last = -1; j->interval_ms = 0; j->next_ms = 0;
}
/* Register a job that fires every `ms` milliseconds (fixed interval). */
void xstd_sched_register_interval(void (*fn)(void), long ms) {
    if (xc_sched_n >= 128) return;
    if (ms < 1) ms = 1;
    xc_sched_job* j = &xc_sched_jobs[xc_sched_n++];
    j->min = j->hour = j->dom = j->mon = j->dow = 0;
    j->fn = fn; j->last = -1; j->interval_ms = ms; j->next_ms = 0;
}
static int xc_cron_match(xc_sched_job* j, struct tm* t) {
    return (j->min  & (1ULL << (t->tm_min)))        &&
           (j->hour & (1ULL << (t->tm_hour)))       &&
           (j->dom  & (1ULL << (t->tm_mday - 1)))   &&
           (j->mon  & (1ULL << (t->tm_mon)))        &&   /* tm_mon is 0-based; mask indexed from lo=1 -> bit tm_mon */
           (j->dow  & (1ULL << (t->tm_wday)));
}
void xstd_scheduler_run(void) {
    if (xc_sched_n == 0) return;
    /* seed each interval job's first due time relative to "now" */
    long long mono = (long long)(xstd_now_nanos() / 1000000);
    for (int i = 0; i < xc_sched_n; i++)
        if (xc_sched_jobs[i].interval_ms > 0)
            xc_sched_jobs[i].next_ms = mono + xc_sched_jobs[i].interval_ms;
    for (;;) {
        time_t now = time(NULL);
        struct tm lt; localtime_r(&now, &lt);
        long minute = (long)(now / 60);
        long long mnow = (long long)(xstd_now_nanos() / 1000000);
        long sleep_ms = 1000;                 /* cron needs only ~1s resolution */
        for (int i = 0; i < xc_sched_n; i++) {
            xc_sched_job* j = &xc_sched_jobs[i];
            if (j->interval_ms > 0) {
                if (mnow >= j->next_ms) {
                    j->fn();
                    j->next_ms += j->interval_ms;
                    if (j->next_ms <= mnow) j->next_ms = mnow + j->interval_ms;  /* fell behind: don't burst */
                }
                if (j->interval_ms < sleep_ms) sleep_ms = j->interval_ms;        /* wake often enough */
            } else {
                if (j->last != minute && xc_cron_match(j, &lt)) { j->last = minute; j->fn(); }
            }
        }
        if (sleep_ms < 10) sleep_ms = 10;     /* floor: avoid a busy loop */
        if (sleep_ms > 1000) sleep_ms = 1000;
        struct timespec ts; ts.tv_sec = sleep_ms / 1000; ts.tv_nsec = (long)((sleep_ms % 1000) * 1000000L);
        nanosleep(&ts, NULL);
    }
}
xc_bool_t xstd_thread_running(xc_Thread_t t) { return t ? !t->done : false; }
xc_bool_t xstd_thread_stopped(void) {
    struct xc_thread* t = (struct xc_thread*)pthread_getspecific(xc_thread_key);
    return t ? (t->stop != 0) : false;
}

/* ─── List<T> (std/collections) ───────────────────────────────────────────────
 * Element-type-erased growable list; the compiler supplies element size and
 * casts. Stores cells contiguously (like a typed array) so iteration is tight. */
struct xc_list { char* data; xc_size_t len, cap, elem; int arena; };

xc_List_t xstd_list_new(xc_size_t elem) {
    struct xc_list* l = (struct xc_list*)xc_heap_alloc(sizeof(*l)); if (!l) abort();
    l->data = NULL; l->len = 0; l->cap = 0; l->elem = elem ? elem : 1;
    l->arena = xc_tls_arena != NULL;
    return l;
}
static void xc_list_grow(struct xc_list* l, xc_size_t need) {
    if (need <= l->cap) return;
    xc_size_t cap = l->cap ? l->cap * 2 : 8;
    if (cap < need) cap = need;
    l->data = (char*)xc_cbuf_grow(&l->arena, l->data, l->len * l->elem, cap * l->elem);
    l->cap = cap;
}
void xstd_list_push(xc_List_t l, const void* e) {
    xc_list_grow(l, l->len + 1);
    memcpy(l->data + l->len * l->elem, e, l->elem);
    l->len += 1;
}
static void xc_list_oob(xc_integer_t i, xc_size_t len) {
    fprintf(stderr, "xc: list index %lld out of bounds (len %zu)\n", (long long)i, (size_t)len);
    abort();
}
void* xstd_list_at(xc_List_t l, xc_integer_t i) {
    if (i < 0 || (xc_size_t)i >= l->len) xc_list_oob(i, l->len);
    return l->data + (xc_size_t)i * l->elem;
}
void xstd_list_set(xc_List_t l, xc_integer_t i, const void* e) {
    if (i < 0 || (xc_size_t)i >= l->len) xc_list_oob(i, l->len);
    memcpy(l->data + (xc_size_t)i * l->elem, e, l->elem);
}
xc_integer_t xstd_list_len(xc_List_t l) { return (xc_integer_t)l->len; }
void xstd_list_removeat(xc_List_t l, xc_integer_t i) {
    if (i < 0 || (xc_size_t)i >= l->len) xc_list_oob(i, l->len);
    char* slot = l->data + (xc_size_t)i * l->elem;
    memmove(slot, slot + l->elem, (l->len - (xc_size_t)i - 1) * l->elem);
    l->len -= 1;
}
void xstd_list_insert(xc_List_t l, xc_integer_t i, const void* e) {
    if (i < 0 || (xc_size_t)i > l->len) xc_list_oob(i, l->len);
    xc_list_grow(l, l->len + 1);
    char* at = l->data + (xc_size_t)i * l->elem;
    memmove(at + l->elem, at, (l->len - (xc_size_t)i) * l->elem);
    memcpy(at, e, l->elem);
    l->len += 1;
}
void xstd_list_swap(xc_List_t l, xc_integer_t i, xc_integer_t j) {
    if (i < 0 || (xc_size_t)i >= l->len) xc_list_oob(i, l->len);
    if (j < 0 || (xc_size_t)j >= l->len) xc_list_oob(j, l->len);
    if (i == j) return;
    char* a = l->data + (xc_size_t)i * l->elem;
    char* b = l->data + (xc_size_t)j * l->elem;
    for (xc_size_t k = 0; k < l->elem; k++) { char t = a[k]; a[k] = b[k]; b[k] = t; }
}
void xstd_list_clear(xc_List_t l) { l->len = 0; }

/* ─── Stack<T>: LIFO over a growable array ──────────────────────────────────── */
struct xc_stack { char* data; xc_size_t len, cap, elem; int arena; };
xc_Stack_t xstd_stack_new(xc_size_t elem) {
    struct xc_stack* s = (struct xc_stack*)xc_heap_alloc(sizeof(*s)); if (!s) abort();
    s->data = NULL; s->len = 0; s->cap = 0; s->elem = elem ? elem : 1;
    s->arena = xc_tls_arena != NULL;
    return s;
}
void xstd_stack_push(xc_Stack_t s, const void* e) {
    if (s->len + 1 > s->cap) {
        xc_size_t cap = s->cap ? s->cap * 2 : 8;
        s->data = (char*)xc_cbuf_grow(&s->arena, s->data, s->len * s->elem, cap * s->elem);
        s->cap = cap;
    }
    memcpy(s->data + s->len * s->elem, e, s->elem);
    s->len += 1;
}
void xstd_stack_pop(xc_Stack_t s, void* out) {
    if (s->len == 0) { fprintf(stderr, "xc: pop() on an empty stack\n"); abort(); }
    s->len -= 1;
    memcpy(out, s->data + s->len * s->elem, s->elem);
}
void* xstd_stack_peek(xc_Stack_t s) {
    if (s->len == 0) { fprintf(stderr, "xc: peek() on an empty stack\n"); abort(); }
    return s->data + (s->len - 1) * s->elem;
}
xc_integer_t xstd_stack_len(xc_Stack_t s) { return (xc_integer_t)s->len; }
void xstd_stack_clear(xc_Stack_t s) { s->len = 0; }

/* ─── Queue<T>: FIFO with a head index (amortised O(1) dequeue) ─────────────── */
struct xc_queue { char* data; xc_size_t head, len, cap, elem; int arena; };
xc_Queue_t xstd_queue_new(xc_size_t elem) {
    struct xc_queue* q = (struct xc_queue*)xc_heap_alloc(sizeof(*q)); if (!q) abort();
    q->data = NULL; q->head = 0; q->len = 0; q->cap = 0; q->elem = elem ? elem : 1;
    q->arena = xc_tls_arena != NULL;
    return q;
}
void xstd_queue_enqueue(xc_Queue_t q, const void* e) {
    if (q->head + q->len + 1 > q->cap) {
        if (q->head > 0) {                                /* compact: slide live region to front */
            memmove(q->data, q->data + q->head * q->elem, q->len * q->elem);
            q->head = 0;
        }
        if (q->len + 1 > q->cap) {
            xc_size_t cap = q->cap ? q->cap * 2 : 8;
            q->data = (char*)xc_cbuf_grow(&q->arena, q->data, q->len * q->elem, cap * q->elem);
            q->cap = cap;
        }
    }
    memcpy(q->data + (q->head + q->len) * q->elem, e, q->elem);
    q->len += 1;
}
void xstd_queue_dequeue(xc_Queue_t q, void* out) {
    if (q->len == 0) { fprintf(stderr, "xc: dequeue() on an empty queue\n"); abort(); }
    memcpy(out, q->data + q->head * q->elem, q->elem);
    q->head += 1; q->len -= 1;
    if (q->len == 0) q->head = 0;
}
void* xstd_queue_peek(xc_Queue_t q) {
    if (q->len == 0) { fprintf(stderr, "xc: peek() on an empty queue\n"); abort(); }
    return q->data + q->head * q->elem;
}
xc_integer_t xstd_queue_len(xc_Queue_t q) { return (xc_integer_t)q->len; }
void xstd_queue_clear(xc_Queue_t q) { q->len = 0; q->head = 0; }

/* ─── SortedQueue<T>: priority queue (binary min-heap) ──────────────────────── */
struct xc_pqueue { char* data; xc_size_t len, cap, elem; int cmp; int arena; };
/* a < b under the queue's ordering? cmp: 0 int/char/bool, 1 number, 2 String. */
static int xc_pq_less(struct xc_pqueue* h, const void* a, const void* b) {
    if (h->cmp == 1) { double x, y; memcpy(&x, a, sizeof(x)); memcpy(&y, b, sizeof(y)); return x < y; }
    if (h->cmp == 2) { xc_string_t x, y; memcpy(&x, a, sizeof(x)); memcpy(&y, b, sizeof(y)); return xc_str_cmp(x, y) < 0; }
    long long x, y; memcpy(&x, a, sizeof(x)); memcpy(&y, b, sizeof(y)); return x < y;
}
xc_SortedQueue_t xstd_pqueue_new(xc_size_t elem, int cmp) {
    struct xc_pqueue* h = (struct xc_pqueue*)xc_heap_alloc(sizeof(*h)); if (!h) abort();
    h->data = NULL; h->len = 0; h->cap = 0; h->elem = elem ? elem : 1; h->cmp = cmp;
    h->arena = xc_tls_arena != NULL;
    return h;
}
static void xc_pq_swap(struct xc_pqueue* h, xc_size_t i, xc_size_t j, char* tmp) {
    char* a = h->data + i * h->elem; char* b = h->data + j * h->elem;
    memcpy(tmp, a, h->elem); memcpy(a, b, h->elem); memcpy(b, tmp, h->elem);
}
void xstd_pqueue_push(xc_SortedQueue_t h, const void* e) {
    if (h->len + 1 > h->cap) {
        xc_size_t cap = h->cap ? h->cap * 2 : 8;
        h->data = (char*)xc_cbuf_grow(&h->arena, h->data, h->len * h->elem, cap * h->elem);
        h->cap = cap;
    }
    memcpy(h->data + h->len * h->elem, e, h->elem);
    xc_size_t i = h->len; h->len += 1;
    char* tmp = (char*)malloc(h->elem); if (!tmp) abort();
    while (i > 0) {                                       /* sift up */
        xc_size_t p = (i - 1) / 2;
        if (!xc_pq_less(h, h->data + i * h->elem, h->data + p * h->elem)) break;
        xc_pq_swap(h, i, p, tmp); i = p;
    }
    free(tmp);
}
void xstd_pqueue_pop(xc_SortedQueue_t h, void* out) {
    if (h->len == 0) { fprintf(stderr, "xc: pop() on an empty sorted queue\n"); abort(); }
    memcpy(out, h->data, h->elem);                        /* root is the minimum */
    h->len -= 1;
    if (h->len == 0) return;
    memcpy(h->data, h->data + h->len * h->elem, h->elem); /* move last to root */
    char* tmp = (char*)malloc(h->elem); if (!tmp) abort();
    xc_size_t i = 0;
    for (;;) {                                            /* sift down */
        xc_size_t l = 2 * i + 1, r = 2 * i + 2, m = i;
        if (l < h->len && xc_pq_less(h, h->data + l * h->elem, h->data + m * h->elem)) m = l;
        if (r < h->len && xc_pq_less(h, h->data + r * h->elem, h->data + m * h->elem)) m = r;
        if (m == i) break;
        xc_pq_swap(h, i, m, tmp); i = m;
    }
    free(tmp);
}
void* xstd_pqueue_peek(xc_SortedQueue_t h) {
    if (h->len == 0) { fprintf(stderr, "xc: peek() on an empty sorted queue\n"); abort(); }
    return h->data;
}
xc_integer_t xstd_pqueue_len(xc_SortedQueue_t h) { return (xc_integer_t)h->len; }
void xstd_pqueue_clear(xc_SortedQueue_t h) { h->len = 0; }

/* ─── hashing shared by Set and Map ─────────────────────────────────────────
 * Keys are hashed/compared by raw bytes, except String keys (is_str) which are
 * hashed/compared by content (xc_string_t is {data,len}, not NUL-terminated).  */
static uint64_t xc_hash_bytes(const void* p, xc_size_t n) {
    const unsigned char* b = (const unsigned char*)p;
    uint64_t h = 1469598103934665603ULL;             /* FNV-1a */
    for (xc_size_t i = 0; i < n; i++) { h ^= b[i]; h *= 1099511628211ULL; }
    return h;
}
static uint64_t xc_hash_key(const void* slot, xc_size_t sz, int is_str) {
    if (is_str) { const xc_string_t* s = (const xc_string_t*)slot; return xc_hash_bytes(s->data, s->len); }
    return xc_hash_bytes(slot, sz);
}
static int xc_key_eq(const void* a, const void* b, xc_size_t sz, int is_str) {
    if (is_str) {
        const xc_string_t* x = (const xc_string_t*)a; const xc_string_t* y = (const xc_string_t*)b;
        return x->len == y->len && (x->len == 0 || memcmp(x->data, y->data, x->len) == 0);
    }
    return memcmp(a, b, sz) == 0;
}

/* ─── Set<T> ─────────────────────────────────────────────────────────────────
 * Open-addressed hash set: state[i] is 0 empty, 1 full, 2 tombstone.           */
struct xc_set { char* slots; unsigned char* state; xc_size_t cap, len, used, elem; int is_str; int arena; };

xc_Set_t xstd_set_new(xc_size_t elem, int is_str) {
    struct xc_set* s = (struct xc_set*)xc_heap_alloc(sizeof(*s)); if (!s) abort();
    s->slots = NULL; s->state = NULL; s->cap = 0; s->len = 0; s->used = 0;
    s->elem = elem ? elem : 1; s->is_str = is_str;
    s->arena = xc_tls_arena != NULL;
    return s;
}
/* Slot for e: returns its index; *found=1 if present, else first free/tombstone. */
static xc_size_t xc_set_probe(struct xc_set* s, const void* e, int* found) {
    xc_size_t mask = s->cap - 1;
    xc_size_t i = (xc_size_t)xc_hash_key(e, s->elem, s->is_str) & mask;
    xc_size_t tomb = (xc_size_t)-1;
    for (;;) {
        if (s->state[i] == 0) { *found = 0; return tomb != (xc_size_t)-1 ? tomb : i; }
        if (s->state[i] == 2) { if (tomb == (xc_size_t)-1) tomb = i; }
        else if (xc_key_eq(s->slots + i * s->elem, e, s->elem, s->is_str)) { *found = 1; return i; }
        i = (i + 1) & mask;
    }
}
static void xc_set_resize(struct xc_set* s, xc_size_t ncap) {
    char* os = s->slots; unsigned char* ost = s->state; xc_size_t ocap = s->cap;
    int wasMalloc = !s->arena;                  /* old tables malloc-owned? */
    s->slots = (char*)xc_cbuf_alloc0(&s->arena, ncap * s->elem);
    s->state = (unsigned char*)xc_cbuf_alloc0(&s->arena, ncap);
    s->cap = ncap; s->len = 0; s->used = 0;
    for (xc_size_t i = 0; i < ocap; i++) if (ost[i] == 1) {
        int f; xc_size_t j = xc_set_probe(s, os + i * s->elem, &f);
        memcpy(s->slots + j * s->elem, os + i * s->elem, s->elem);
        s->state[j] = 1; s->len++; s->used++;
    }
    if (wasMalloc) { free(os); free(ost); }     /* arena-owned old tables die with their arena */
}
void xstd_set_add(xc_Set_t s, const void* e) {
    if (s->cap == 0) xc_set_resize(s, 8);
    else if ((s->used + 1) * 4 >= s->cap * 3) xc_set_resize(s, s->cap * 2);
    int f; xc_size_t i = xc_set_probe(s, e, &f); if (f) return;
    if (s->state[i] == 0) s->used++;
    memcpy(s->slots + i * s->elem, e, s->elem); s->state[i] = 1; s->len++;
}
xc_bool_t xstd_set_contains(xc_Set_t s, const void* e) {
    if (s->cap == 0) return false; int f; xc_set_probe(s, e, &f); return f ? true : false;
}
void xstd_set_remove(xc_Set_t s, const void* e) {
    if (s->cap == 0) return; int f; xc_size_t i = xc_set_probe(s, e, &f);
    if (!f) return; s->state[i] = 2; s->len--;
}
xc_integer_t xstd_set_len(xc_Set_t s) { return (xc_integer_t)s->len; }
void xstd_set_clear(xc_Set_t s) { if (s->state) memset(s->state, 0, s->cap); s->len = 0; s->used = 0; }
xc_List_t xstd_set_items(xc_Set_t s) {
    xc_List_t l = xstd_list_new(s->elem);
    for (xc_size_t i = 0; i < s->cap; i++) if (s->state[i] == 1) xstd_list_push(l, s->slots + i * s->elem);
    return l;
}

/* ─── Map<K,V> ───────────────────────────────────────────────────────────────
 * Parallel-array open-addressed hash map sharing Set's hashing helpers.         */
struct xc_map {
    char* kslots; char* vslots; unsigned char* state;
    xc_size_t cap, len, used, ksize, vsize; int kis_str; int arena;
};

xc_Map_t xstd_map_new(xc_size_t ks, xc_size_t vs, int kis_str) {
    struct xc_map* m = (struct xc_map*)xc_heap_alloc(sizeof(*m)); if (!m) abort();
    m->kslots = NULL; m->vslots = NULL; m->state = NULL;
    m->cap = 0; m->len = 0; m->used = 0;
    m->ksize = ks ? ks : 1; m->vsize = vs ? vs : 1; m->kis_str = kis_str;
    m->arena = xc_tls_arena != NULL;
    return m;
}
static xc_size_t xc_map_probe(struct xc_map* m, const void* k, int* found) {
    xc_size_t mask = m->cap - 1;
    xc_size_t i = (xc_size_t)xc_hash_key(k, m->ksize, m->kis_str) & mask;
    xc_size_t tomb = (xc_size_t)-1;
    for (;;) {
        if (m->state[i] == 0) { *found = 0; return tomb != (xc_size_t)-1 ? tomb : i; }
        if (m->state[i] == 2) { if (tomb == (xc_size_t)-1) tomb = i; }
        else if (xc_key_eq(m->kslots + i * m->ksize, k, m->ksize, m->kis_str)) { *found = 1; return i; }
        i = (i + 1) & mask;
    }
}
static void xc_map_resize(struct xc_map* m, xc_size_t ncap) {
    char* ok = m->kslots; char* ov = m->vslots; unsigned char* ost = m->state; xc_size_t ocap = m->cap;
    int wasMalloc = !m->arena;                  /* old tables malloc-owned? */
    m->kslots = (char*)xc_cbuf_alloc0(&m->arena, ncap * m->ksize);
    m->vslots = (char*)xc_cbuf_alloc0(&m->arena, ncap * m->vsize);
    m->state = (unsigned char*)xc_cbuf_alloc0(&m->arena, ncap);
    m->cap = ncap; m->len = 0; m->used = 0;
    for (xc_size_t i = 0; i < ocap; i++) if (ost[i] == 1) {
        int f; xc_size_t j = xc_map_probe(m, ok + i * m->ksize, &f);
        memcpy(m->kslots + j * m->ksize, ok + i * m->ksize, m->ksize);
        memcpy(m->vslots + j * m->vsize, ov + i * m->vsize, m->vsize);
        m->state[j] = 1; m->len++; m->used++;
    }
    if (wasMalloc) { free(ok); free(ov); free(ost); }   /* arena-owned old tables die with their arena */
}
void xstd_map_put(xc_Map_t m, const void* k, const void* v) {
    if (m->cap == 0) xc_map_resize(m, 8);
    else if ((m->used + 1) * 4 >= m->cap * 3) xc_map_resize(m, m->cap * 2);
    int f; xc_size_t i = xc_map_probe(m, k, &f);
    if (!f) {
        if (m->state[i] == 0) m->used++;
        memcpy(m->kslots + i * m->ksize, k, m->ksize); m->state[i] = 1; m->len++;
    }
    memcpy(m->vslots + i * m->vsize, v, m->vsize);
}
static void xc_map_missing(void) { fprintf(stderr, "xc: map key not found\n"); abort(); }
void* xstd_map_get(xc_Map_t m, const void* k) {
    if (m->cap == 0) xc_map_missing();
    int f; xc_size_t i = xc_map_probe(m, k, &f); if (!f) xc_map_missing();
    return m->vslots + i * m->vsize;
}
void* xstd_map_getor(xc_Map_t m, const void* k, void* def) {
    if (m->cap == 0) return def;
    int f; xc_size_t i = xc_map_probe(m, k, &f);
    return f ? (void*)(m->vslots + i * m->vsize) : def;
}
xc_bool_t xstd_map_has(xc_Map_t m, const void* k) {
    if (m->cap == 0) return false; int f; xc_map_probe(m, k, &f); return f ? true : false;
}
void xstd_map_remove(xc_Map_t m, const void* k) {
    if (m->cap == 0) return; int f; xc_size_t i = xc_map_probe(m, k, &f);
    if (!f) return; m->state[i] = 2; m->len--;
}
xc_integer_t xstd_map_len(xc_Map_t m) { return (xc_integer_t)m->len; }
void xstd_map_clear(xc_Map_t m) { if (m->state) memset(m->state, 0, m->cap); m->len = 0; m->used = 0; }
xc_List_t xstd_map_keys(xc_Map_t m) {
    xc_List_t l = xstd_list_new(m->ksize);
    for (xc_size_t i = 0; i < m->cap; i++) if (m->state[i] == 1) xstd_list_push(l, m->kslots + i * m->ksize);
    return l;
}
xc_List_t xstd_map_values(xc_Map_t m) {
    xc_List_t l = xstd_list_new(m->vsize);
    for (xc_size_t i = 0; i < m->cap; i++) if (m->state[i] == 1) xstd_list_push(l, m->vslots + i * m->vsize);
    return l;
}

/* ─── assert + test runner ───────────────────────────────────────────────── */
static jmp_buf     xc_test_buf;       /* abort-current-test target */
static int         xc_test_active = 0;
static const char* xc_test_name = "";
static long        xc_test_total = 0;
static long        xc_test_passed = 0;

/* Common failure path: under the test runner record + abort just this test;
 * otherwise print to stderr and abort the program. */
static void xc_assert_fail(const char* detail, const char* file, long long line) {
    if (xc_test_active) {
        fprintf(stdout, "not ok - %s\n    %s  (%s:%lld)\n", xc_test_name, detail, file, (long long)line);
        fflush(stdout);
        longjmp(xc_test_buf, 1);     /* abandon this test, run the next */
    }
    fprintf(stderr, "xc: assertion failed: %s  (%s:%lld)\n", detail, file, (long long)line);
    abort();
}
void xc_assert(xc_bool_t cond, const char* text, const char* file, long long line) {
    if (cond) return;
    char buf[640]; snprintf(buf, sizeof buf, "assert %s", text);
    xc_assert_fail(buf, file, line);
}
void xc_assert_msg(xc_bool_t cond, const char* text, const char* msg, const char* file, long long line) {
    if (cond) return;
    char buf[768]; snprintf(buf, sizeof buf, "assert %s  —  %s", text, msg);
    xc_assert_fail(buf, file, line);
}
/* assertEq(actual, expected) / assertNe(a, b): values already stringified. */
void xc_assert_eq(xc_bool_t eq, xc_string_t a, xc_string_t b, xc_bool_t negate,
                  const char* file, long long line) {
    int pass = negate ? !eq : eq;
    if (pass) return;
    char buf[768];
    if (negate) snprintf(buf, sizeof buf, "assertNe: both values were %.*s", (int)a.len, a.data);
    else        snprintf(buf, sizeof buf, "assertEq: expected %.*s, got %.*s",
                         (int)b.len, b.data, (int)a.len, a.data);
    xc_assert_fail(buf, file, line);
}
void xc_assert_close(xc_bool_t ok, xc_string_t a, xc_string_t b, xc_string_t eps,
                     const char* file, long long line) {
    if (ok) return;
    char buf[768];
    snprintf(buf, sizeof buf, "assertClose: %.*s and %.*s differ by more than %.*s",
             (int)a.len, a.data, (int)b.len, b.data, (int)eps.len, eps.data);
    xc_assert_fail(buf, file, line);
}
/* assertOk: want_ok=1 (fail with the Err message); assertErr: want_ok=0. */
void xc_assert_ok(xc_bool_t is_ok, xc_string_t err, xc_bool_t want_ok,
                  const char* file, long long line) {
    if (want_ok ? is_ok : !is_ok) return;
    char buf[768];
    if (want_ok) snprintf(buf, sizeof buf, "assertOk: got Err(%.*s)", (int)err.len, err.data);
    else         snprintf(buf, sizeof buf, "assertErr: expected Err, got Ok");
    xc_assert_fail(buf, file, line);
}

xc_bool_t xc_test_filter(const char* name) {
    const char* f = getenv("XC_TEST_FILTER");
    if (!f || !*f) return true;
    return strstr(name, f) != NULL;
}
void xc_test_run(const char* name, void (*fn)(void)) {
    if (!xc_test_filter(name)) return;   /* XC_TEST_FILTER selects by substring */
    xc_test_total += 1;
    xc_test_name = name;
    if (setjmp(xc_test_buf) == 0) {
        xc_test_active = 1;
        fn();
        xc_test_active = 0;
        xc_test_passed += 1;
        fprintf(stdout, "ok - %s\n", name);
    } else {
        xc_test_active = 0;          /* failure already reported by xc_assert */
    }
    fflush(stdout);
}

int xc_test_summary(void) {
    long failed = xc_test_total - xc_test_passed;
    fprintf(stdout, "\n%ld tests, %ld passed, %ld failed\n",
            xc_test_total, xc_test_passed, failed);
    fflush(stdout);
    return failed == 0 ? 0 : 1;
}

/* ─── std/config: read + parse a config file by extension ───────────────────── */
xc_Json_t xstd_config_parse(xc_string_t path) {
    xc_string_t src = file_read_all(path);
    const char* d = path.data;
    xc_size_t L = path.len;
    if (L >= 5 && memcmp(d + L - 5, ".json", 5) == 0) return xstd_json_parse(src);
    if (L >= 4 && memcmp(d + L - 4, ".xml",  4) == 0) return xstd_xml_parse(src);
    return xstd_yaml_parse(src);   /* .yaml / .yml / default */
}

/* ─── std/config: background file watcher -> ConfigChanged event ─────────────
 * Polls the file's mtime; on change pushes a `ConfigChanged { file: String }`
 * event on the given topic. The payload layout is a single xc_string_t, which
 * matches xc_ConfigChanged_t, so the generated dispatch reads `.file` directly. */
typedef struct { xc_string_t path; xc_string_t topic; xc_integer_t mtime; } xc_cfg_watch_t;

static void* xc_config_watch_thread(void* arg) {
    xc_cfg_watch_t* w = (xc_cfg_watch_t*)arg;
    for (;;) {
        struct timespec ts; ts.tv_sec = 1; ts.tv_nsec = 0;
        nanosleep(&ts, NULL);
        xc_integer_t m = xstd_mtime(w->path);
        if (m != 0 && m != w->mtime) {
            w->mtime = m;
            xc_string_t* pl = (xc_string_t*)malloc(sizeof(xc_string_t));
            if (pl) {
                *pl = w->path;                              /* ConfigChanged.file */
                xstd_eventq_push(xstd_event_make(w->topic, xc_string_from_cstr("ConfigChanged"), pl));
            }
        }
    }
    return NULL;
}

void xstd_config_watch(xc_string_t path, xc_string_t topic) {
    xc_cfg_watch_t* w = (xc_cfg_watch_t*)malloc(sizeof(xc_cfg_watch_t));
    if (!w) return;
    w->path  = xc_str_copy(path.data, path.len);
    w->topic = xc_str_copy(topic.data, topic.len);
    w->mtime = xstd_mtime(path);
    pthread_t th;
    if (pthread_create(&th, NULL, xc_config_watch_thread, w) == 0) pthread_detach(th);
}
