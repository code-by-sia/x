/*
 * runtime.h — X language runtime support library
 *
 * Included by every generated C file.  Defines the primitive types,
 * string/array helpers, optional-type macros, and panic machinery.
 */
#ifndef XC_RUNTIME_H
#define XC_RUNTIME_H

/*
 * Expose POSIX/Darwin APIs (clock_gettime, CLOCK_MONOTONIC, struct timespec,
 * nanosleep, strdup, ...) even under -std=c99. On glibc these are hidden unless
 * a feature-test macro is set; macOS needs _DARWIN_C_SOURCE for the same.
 * These MUST be defined before any system header is included — and runtime.h is
 * the first include in every generated C file as well as runtime.c.
 */
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif
#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE 1
#endif
#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE 1
#endif

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <ctype.h>
#include <setjmp.h>
#include <pthread.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ─── Primitive type aliases ─────────────────────────────────────────────── */

typedef double          xc_number_t;
typedef int64_t         xc_integer_t;
typedef bool            xc_bool_t;
typedef uint32_t        xc_char_t;      /* Unicode scalar value (UTF-32)    */
typedef int64_t         xc_timestamp_t; /* nanoseconds since program start  */
typedef size_t          xc_size_t;

/* ─── String type ────────────────────────────────────────────────────────── */

typedef struct {
    const char* data;   /* UTF-8, NOT guaranteed NUL-terminated              */
    xc_size_t   len;    /* byte length                                        */
} xc_string_t;

/* ── Reference counting (memory-management Phase 3; opt-in: -DXC_ARC) ──────────
 * A small header precedes every rc-managed heap block; the value pointer
 * (a string's data, an array's data, a boxed instance) points just past it, so
 * every reader is unchanged. retain/release adjust the count and free at zero.
 * Pointers without our magic — string literals in .rodata, arena blocks — are
 * not managed, so retain/release are no-ops on them (the count is "immortal").
 * With XC_ARC OFF, xc_rc_alloc is plain malloc and retain/release compile to
 * nothing, so generated programs are byte-for-byte as before. */
typedef struct { uint32_t rc; uint32_t magic; } xc_rc_hdr;
void* xc_rc_alloc(size_t n);     /* rc=1 managed block (malloc when !XC_ARC)   */
void* xc_rc_immortal(size_t n);  /* never-freed managed block                  */
void  xc_retain(const void* p);  /* ++rc on a managed block; else no-op        */
void  xc_release(const void* p); /* --rc, free at zero; else no-op             */
/* Arena-aware value allocator (the active arena, else rc/malloc). Strings and
   conversions route through it so an enclosing arena (thread/request/scope)
   reclaims them. */
void* xc_heap_alloc(size_t n);
/* Move a value out of the active arena so it can outlive it (see runtime.c).
   No-ops when no arena is active. (xc_promote_bytes is declared with Bytes.) */
xc_string_t   xc_promote_string(xc_string_t s);
/* Copy a C string into arena-aware heap memory. */
static inline xc_string_t xc_heap_strdup(const char* s) {
    size_t n = s ? strlen(s) : 0;
    char* b = (char*)xc_heap_alloc(n + 1);
    if (n) memcpy(b, s, n);
    b[n] = '\0';
    return (xc_string_t){ .data = b, .len = n };
}

/* Pair<A,B> — a runtime-generic 2-tuple. Both members are stored by value behind
   arena-aware pointers (so any A/B work without a monomorphized struct); the
   compiler tracks the concrete A/B types and casts `.first`/`.second` back. Used
   by `a to b`, zip/unzip, and partition. */
typedef struct { void* first; void* second; } xc_pair_t;
static inline xc_pair_t xc_pair_make(const void* a, xc_size_t as, const void* b, xc_size_t bs) {
    void* fa = xc_heap_alloc(as); memcpy(fa, a, as);
    void* fb = xc_heap_alloc(bs); memcpy(fb, b, bs);
    return (xc_pair_t){ .first = fa, .second = fb };
}

/* Closure value (first-class function): a code pointer plus a captured-environment
   pointer. A lambda lowers to a top-level `fn(void* env, params…)` and a heap env
   struct of by-value captures; the call site casts `fn` to the concrete signature
   recovered from the value's Fn(...) xtype and invokes `fn(env, args…)`. `env` is
   NULL for a capture-free lambda. (Foundation for the closures proposal.) */
typedef struct { void* fn; void* env; } xc_fn_t;

static inline xc_string_t xc_string_from_cstr(const char* s) {
    return (xc_string_t){ .data = s, .len = s ? strlen(s) : 0 };
}

static inline xc_string_t xc_string_from_buf(const char* data, xc_size_t len) {
    return (xc_string_t){ .data = data, .len = len };
}

/* Allocate a NUL-terminated copy (for passing to C APIs) */
static inline char* xc_string_to_cstr(xc_string_t s) {
    char* buf = (char*)malloc(s.len + 1);
    if (!buf) abort();
    memcpy(buf, s.data, s.len);
    buf[s.len] = '\0';
    return buf;
}

static inline xc_bool_t xc_string_eq(xc_string_t a, xc_string_t b) {
    return a.len == b.len && memcmp(a.data, b.data, a.len) == 0;
}

/* Lexicographic compare: <0, 0, >0 (used by List.sorted/sortedBy). */
static inline int xc_str_cmp(xc_string_t a, xc_string_t b) {
    xc_size_t n = a.len < b.len ? a.len : b.len;
    int c = (n == 0) ? 0 : memcmp(a.data, b.data, n);
    if (c != 0) return c;
    if (a.len < b.len) return -1;
    if (a.len > b.len) return 1;
    return 0;
}

/* Concatenate two strings — result is heap-allocated (arena-aware: reclaimed by
   an enclosing thread/request/scope arena, else rc-managed/malloc). */
static inline xc_string_t xc_string_concat(xc_string_t a, xc_string_t b) {
    xc_size_t len = a.len + b.len;
    char* buf = (char*)xc_heap_alloc(len + 1);
    if (!buf) abort();
    memcpy(buf, a.data, a.len);
    memcpy(buf + a.len, b.data, b.len);
    buf[len] = '\0';
    return (xc_string_t){ .data = buf, .len = len };
}

/* ─── Bytes type ─────────────────────────────────────────────────────────── */
/* A buffer of raw bytes. Like xc_string_t it is a {data,len} fat pointer passed
   by value; copies share the buffer and it is never mutated in place, so value
   semantics hold. Functions that produce new bytes heap-allocate. */
typedef struct {
    const unsigned char* data;
    xc_size_t            len;
} xc_bytes_t;

xc_bytes_t xc_promote_bytes(xc_bytes_t b);   /* see xc_promote_string */

static inline xc_integer_t bytes_len(xc_bytes_t b) { return (xc_integer_t)b.len; }

static inline xc_integer_t bytes_get(xc_bytes_t b, xc_integer_t i) {
    if (i < 0 || (xc_size_t)i >= b.len) return -1;
    return (xc_integer_t)b.data[(xc_size_t)i];
}

static inline xc_bytes_t bytes_empty(void) {
    return (xc_bytes_t){ .data = NULL, .len = 0 };
}

static inline xc_bytes_t bytes_slice(xc_bytes_t b, xc_integer_t from, xc_integer_t to) {
    if (from < 0) from = 0;
    if ((xc_size_t)to > b.len) to = (xc_integer_t)b.len;
    if (from >= to) return bytes_empty();
    return (xc_bytes_t){ .data = b.data + from, .len = (xc_size_t)(to - from) };
}

static inline xc_bytes_t bytes_concat(xc_bytes_t a, xc_bytes_t b) {
    xc_size_t len = a.len + b.len;
    unsigned char* buf = (unsigned char*)xc_heap_alloc(len ? len : 1);
    if (!buf) abort();
    if (a.len) memcpy(buf, a.data, a.len);
    if (b.len) memcpy(buf + a.len, b.data, b.len);
    return (xc_bytes_t){ .data = buf, .len = len };
}

/* Copy a string's bytes into a fresh Bytes buffer (and vice versa). */
static inline xc_bytes_t bytes_from_string(xc_string_t s) {
    unsigned char* buf = (unsigned char*)xc_heap_alloc(s.len ? s.len : 1);
    if (!buf) abort();
    if (s.len) memcpy(buf, s.data, s.len);
    return (xc_bytes_t){ .data = buf, .len = s.len };
}

static inline xc_string_t bytes_to_string(xc_bytes_t b) {
    char* buf = (char*)xc_heap_alloc(b.len + 1);
    if (!buf) abort();
    if (b.len) memcpy(buf, b.data, b.len);
    buf[b.len] = '\0';
    return (xc_string_t){ .data = buf, .len = b.len };
}

/* Bytes is a runtime primitive, so its Result/optional/array shapes live here
   (the compiler emits these only for the built-in scalars and user types). */
typedef struct { bool ok; xc_bytes_t value; xc_string_t err; } xc_res_bytes_t;
typedef struct { bool has_value; xc_bytes_t value; }           xc_opt_bytes_t;
typedef struct { xc_bytes_t* data; xc_size_t len; xc_size_t cap; } xc_arr_bytes_t;

/* JSON value — an opaque, heap-allocated DOM node used by std/json (the
   serialization library). It is referenced from X as the `Json` type; the
   struct itself is private to runtime.c. */
typedef struct xc_json_node* xc_Json_t;
xc_Json_t xc_promote_json(xc_Json_t v);   /* deep copy out of the arena */

/* Event system (std/events). An event is a type-erased envelope: a topic, the
   payload's type name, and an opaque pointer to a heap copy of the typed value.
   The default transport moves envelopes through an in-memory FIFO with no
   serialization; external transports (de)serialize the payload themselves. */
typedef struct xc_event_env* xc_Event_t;

/* Web (std/web): an HTTP request/response and a tiny HTTP/1.1 server. The
   generated router is registered via xstd_web_set_dispatch and run by serve. */
typedef struct xc_web_request*  xc_Request_t;
typedef struct xc_web_response* xc_Response_t;
xc_string_t   xstd_req_method(xc_Request_t);
xc_string_t   xstd_req_path(xc_Request_t);
xc_string_t   xstd_req_query(xc_Request_t, xc_string_t name);
xc_string_t   xstd_req_header(xc_Request_t, xc_string_t name);
xc_string_t   xstd_req_param(xc_Request_t, xc_string_t name);
xc_string_t   xstd_req_body(xc_Request_t);
xc_Json_t     xstd_req_params_json(xc_Request_t);   /* captured path params as a Json object */
xc_Json_t     xstd_req_query_json(xc_Request_t);    /* query string as a Json object */
xc_Json_t     xstd_req_headers_json(xc_Request_t);  /* headers as a Json object (names normalized) */
xc_Response_t xstd_resp(xc_integer_t status, xc_string_t body, xc_string_t ctype);
xc_bool_t     xstd_web_match(xc_Request_t, xc_string_t method, xc_string_t pattern);
void          xstd_web_set_dispatch(xc_Response_t (*fn)(xc_Request_t));
void          xstd_web_serve(xc_integer_t port);
/* Runtime limits declared in a module (`maxRequestBytes` / `jsonMaxDepth`);
   emitted into main before anything serves. The matching environment variable
   still wins, so a deployment can retune without a rebuild. */
void          xstd_set_max_request(xc_integer_t n);
void          xstd_set_json_max_depth(xc_integer_t n);

/* Handler-interface model (std/web v2): the request and a *mutable* response are
   handed to a WebRequestHandler.handle(req,res); the handler fills the response
   via xstd_resp_set. The generated dispatch is registered via xstd_web_set_handler. */
typedef struct xc_web_request*  xc_HttpRequest_t;
typedef struct xc_web_response* xc_HttpResponse_t;
void          xstd_resp_set(xc_HttpResponse_t, xc_integer_t status, xc_string_t body, xc_string_t ctype);
xc_integer_t  xstd_resp_status(xc_HttpResponse_t);
void          xstd_web_set_handler(void (*fn)(xc_HttpRequest_t, xc_HttpResponse_t));
void          xstd_web_serve_tls(xc_integer_t port, xc_string_t certPath, xc_string_t keyPath);
xc_string_t   xstd_https_fetch(xc_string_t host, xc_integer_t port, xc_string_t request);
void          xstd_web_serve_http2(xc_integer_t port, xc_string_t certPath, xc_string_t keyPath);

/* Threading (std/thread): share-nothing OS threads communicating over
   thread-safe channels. A `parallel { }` block lifts to a thread function and is
   started via xstd_thread_spawn, returning a Thread handle (stop/wait/running).
   Channels carry copied string payloads (the only thing crossing the boundary). */
typedef struct xc_chan*   xc_Channel_t;
typedef struct xc_thread* xc_Thread_t;
xc_Channel_t  xstd_chan_new(void);
void          xstd_chan_send(xc_Channel_t, xc_string_t);
xc_string_t   xstd_chan_recv(xc_Channel_t);
void          xstd_chan_close(xc_Channel_t);
xc_Thread_t   xstd_thread_spawn(void* (*fn)(void*), void* arg);
void          xstd_thread_stop(xc_Thread_t);
void          xstd_thread_wait(xc_Thread_t);
xc_bool_t     xstd_thread_running(xc_Thread_t);
xc_bool_t     xstd_thread_stopped(void);

/* ─── Future<T> (async / await) ──────────────────────────────────────────────
 * An async function call runs its body on a worker thread and returns a Future
 * immediately; `await` joins and reads the result. Unlike `parallel` threads,
 * a future's thread does NOT use a per-thread arena — its allocations leak (live
 * on the shared heap) so the result and everything it points to survive the
 * await. `fn` returns a malloc'd pointer to the T-sized result.               */
typedef struct xc_future* xc_Future_t;
typedef xc_Future_t xc_Future_integer_t;
typedef xc_Future_t xc_Future_number_t;
typedef xc_Future_t xc_Future_bool_t;
typedef xc_Future_t xc_Future_string_t;
typedef xc_Future_t xc_Future_char_t;
xc_Future_t   xstd_future_spawn(void* (*fn)(void*), void* arg);
void*         xstd_future_await(xc_Future_t);   /* join the worker, return result ptr */
xc_bool_t     xstd_future_done(xc_Future_t);    /* has it finished (non-blocking)? */

/* ─── Scheduled jobs (cron) ──────────────────────────────────────────────────
 * `scheduled name() cron "<expr>" { … }` registers a job; the scheduler fires
 * each job when local time matches its 5-field cron (min hour dom month dow).   */
void xstd_sched_register(void (*fn)(void), const char* cron);
void xstd_sched_register_interval(void (*fn)(void), long ms);   /* fixed ms interval */
void xstd_scheduler_run(void);   /* blocks forever, firing due cron + interval jobs */

xc_Event_t   xstd_event_make(xc_string_t topic, xc_string_t type, void* payload);
xc_string_t  xstd_event_topic(xc_Event_t);
xc_string_t  xstd_event_type(xc_Event_t);
void*        xstd_event_payload(xc_Event_t);
void         xstd_eventq_push(xc_Event_t);
xc_integer_t xstd_eventq_len(void);
xc_Event_t   xstd_eventq_shift(void);
xc_Event_t   xstd_eventq_pop_blocking(void);
void         xstd_eventq_close(void);

/* Number → string */
static inline xc_string_t xc_number_to_string(xc_number_t n) {
    char buf[64];
    if (n == (xc_integer_t)n)
        snprintf(buf, sizeof(buf), "%lld", (long long)(xc_integer_t)n);
    else
        snprintf(buf, sizeof(buf), "%g", n);
    return xc_heap_strdup(buf);
}

static inline xc_string_t xc_integer_to_string(xc_integer_t n) {
    char buf[32];
    snprintf(buf, sizeof(buf), "%lld", (long long)n);
    return xc_heap_strdup(buf);
}

static inline xc_string_t xc_bool_to_string(xc_bool_t b) {
    return xc_string_from_cstr(b ? "true" : "false");
}

/* Simple regex match using libc (only ^ $ . * + ? supported) */
xc_bool_t xc_string_matches(xc_string_t s, const char* pattern);

/* ─── Array type ─────────────────────────────────────────────────────────── */

typedef struct {
    xc_string_t* data;
    xc_size_t    len;
    xc_size_t    cap;
} xc_arr_string_t;

/* Arrays of primitives — so they can be struct/event fields and array literals. */
typedef struct { xc_integer_t* data; xc_size_t len; xc_size_t cap; } xc_arr_integer_t;
typedef struct { xc_number_t*  data; xc_size_t len; xc_size_t cap; } xc_arr_number_t;
typedef struct { xc_bool_t*    data; xc_size_t len; xc_size_t cap; } xc_arr_bool_t;
typedef struct { xc_char_t*    data; xc_size_t len; xc_size_t cap; } xc_arr_char_t;

typedef struct {
    void*      data;
    xc_size_t  len;
    xc_size_t  cap;
} xc_arr_any_t;

/* ─── List<T> (std/collections) ──────────────────────────────────────────────
 * A growable, mutable list. The runtime is element-type-erased (it stores
 * `elem`-sized cells); the compiler keeps the element type for safety and emits
 * the right casts, and aliases `xc_List_<T>_t` to this handle per element type.  */
typedef struct xc_list* xc_List_t;
/* Per-element aliases (all the same handle) so List<T> can be a typed param/field. */
typedef xc_List_t xc_List_integer_t;
typedef xc_List_t xc_List_number_t;
typedef xc_List_t xc_List_bool_t;
typedef xc_List_t xc_List_string_t;
typedef xc_List_t xc_List_char_t;
typedef xc_List_t xc_List_Json_t;   /* List<Json> — rows/trees as elements */
xc_List_t    xstd_list_new(xc_size_t elem);
void         xstd_list_push(xc_List_t, const void* e);
void*        xstd_list_at(xc_List_t, xc_integer_t i);     /* ptr to element (aborts OOB) */
void         xstd_list_set(xc_List_t, xc_integer_t i, const void* e);
xc_integer_t xstd_list_len(xc_List_t);
void         xstd_list_removeat(xc_List_t, xc_integer_t i);
void         xstd_list_insert(xc_List_t, xc_integer_t i, const void* e);  /* shift right; i==len appends */
void         xstd_list_swap(xc_List_t, xc_integer_t i, xc_integer_t j);
void         xstd_list_clear(xc_List_t);

/* ─── Set<T> (std/collections) ───────────────────────────────────────────────
 * A hash set of unique elements. Element-type-erased like List; `is_str` tells
 * the runtime to hash/compare String elements by content rather than by bytes. */
typedef struct xc_set* xc_Set_t;
typedef xc_Set_t xc_Set_integer_t;
typedef xc_Set_t xc_Set_number_t;
typedef xc_Set_t xc_Set_bool_t;
typedef xc_Set_t xc_Set_string_t;
typedef xc_Set_t xc_Set_char_t;
xc_Set_t     xstd_set_new(xc_size_t elem, int is_str);
void         xstd_set_add(xc_Set_t, const void* e);       /* no-op if present */
xc_bool_t    xstd_set_contains(xc_Set_t, const void* e);
void         xstd_set_remove(xc_Set_t, const void* e);    /* no-op if absent */
xc_integer_t xstd_set_len(xc_Set_t);
void         xstd_set_clear(xc_Set_t);
xc_List_t    xstd_set_items(xc_Set_t);                    /* live elements, as a List */

/* ─── Map<K,V> (std/collections) ─────────────────────────────────────────────
 * A hash map. Key-type-erased (String keys hashed/compared by content via the
 * is_str flag); the compiler aliases `xc_Map_<K>_<V>_t` per (key,value) pair.   */
typedef struct xc_map* xc_Map_t;
/* Primitive (key x value) aliases (all the same handle). */
typedef xc_Map_t xc_Map_integer_integer_t; typedef xc_Map_t xc_Map_integer_number_t;
typedef xc_Map_t xc_Map_integer_bool_t;    typedef xc_Map_t xc_Map_integer_string_t;
typedef xc_Map_t xc_Map_integer_char_t;
typedef xc_Map_t xc_Map_number_integer_t;  typedef xc_Map_t xc_Map_number_number_t;
typedef xc_Map_t xc_Map_number_bool_t;     typedef xc_Map_t xc_Map_number_string_t;
typedef xc_Map_t xc_Map_number_char_t;
typedef xc_Map_t xc_Map_bool_integer_t;    typedef xc_Map_t xc_Map_bool_number_t;
typedef xc_Map_t xc_Map_bool_bool_t;       typedef xc_Map_t xc_Map_bool_string_t;
typedef xc_Map_t xc_Map_bool_char_t;
typedef xc_Map_t xc_Map_string_integer_t;  typedef xc_Map_t xc_Map_string_number_t;
typedef xc_Map_t xc_Map_string_bool_t;     typedef xc_Map_t xc_Map_string_string_t;
typedef xc_Map_t xc_Map_string_char_t;
typedef xc_Map_t xc_Map_char_integer_t;    typedef xc_Map_t xc_Map_char_number_t;
typedef xc_Map_t xc_Map_char_bool_t;       typedef xc_Map_t xc_Map_char_string_t;
typedef xc_Map_t xc_Map_char_char_t;
xc_Map_t     xstd_map_new(xc_size_t ksize, xc_size_t vsize, int key_is_str);
void         xstd_map_put(xc_Map_t, const void* k, const void* v);   /* insert or overwrite */
void*        xstd_map_get(xc_Map_t, const void* k);                  /* ptr to value (aborts if absent) */
void*        xstd_map_getor(xc_Map_t, const void* k, void* def);     /* value ptr, or `def` if absent */
xc_bool_t    xstd_map_has(xc_Map_t, const void* k);
void         xstd_map_remove(xc_Map_t, const void* k);               /* no-op if absent */
xc_integer_t xstd_map_len(xc_Map_t);
void         xstd_map_clear(xc_Map_t);
xc_List_t    xstd_map_keys(xc_Map_t);                                /* keys, as a List<K> */
xc_List_t    xstd_map_values(xc_Map_t);                              /* values, as a List<V> */

/* ─── Stack<T> (std/collections) ─────────────────────────────────────────────
 * A LIFO stack over a growable array. Element-type-erased like List; pop/peek
 * abort on an empty stack (guard with isEmpty()/len()).                         */
typedef struct xc_stack* xc_Stack_t;
typedef xc_Stack_t xc_Stack_integer_t;
typedef xc_Stack_t xc_Stack_number_t;
typedef xc_Stack_t xc_Stack_bool_t;
typedef xc_Stack_t xc_Stack_string_t;
typedef xc_Stack_t xc_Stack_char_t;
xc_Stack_t   xstd_stack_new(xc_size_t elem);
void         xstd_stack_push(xc_Stack_t, const void* e);
void         xstd_stack_pop(xc_Stack_t, void* out);      /* copy top to out, remove (abort if empty) */
void*        xstd_stack_peek(xc_Stack_t);                /* ptr to top (abort if empty) */
xc_integer_t xstd_stack_len(xc_Stack_t);
void         xstd_stack_clear(xc_Stack_t);

/* ─── Queue<T> (std/collections) ─────────────────────────────────────────────
 * A FIFO queue with an internal head index (amortised O(1) dequeue). dequeue/
 * peek abort on an empty queue.                                                 */
typedef struct xc_queue* xc_Queue_t;
typedef xc_Queue_t xc_Queue_integer_t;
typedef xc_Queue_t xc_Queue_number_t;
typedef xc_Queue_t xc_Queue_bool_t;
typedef xc_Queue_t xc_Queue_string_t;
typedef xc_Queue_t xc_Queue_char_t;
xc_Queue_t   xstd_queue_new(xc_size_t elem);
void         xstd_queue_enqueue(xc_Queue_t, const void* e);
void         xstd_queue_dequeue(xc_Queue_t, void* out);  /* copy front to out, remove (abort if empty) */
void*        xstd_queue_peek(xc_Queue_t);                /* ptr to front (abort if empty) */
xc_integer_t xstd_queue_len(xc_Queue_t);
void         xstd_queue_clear(xc_Queue_t);

/* ─── SortedQueue<T> (std/collections) ───────────────────────────────────────
 * A priority queue (binary min-heap) over comparable elements; pop/peek return
 * the smallest. `cmp` picks the ordering: 0 = integer/char/bool, 1 = number,
 * 2 = String (by content). pop/peek abort when empty.                           */
typedef struct xc_pqueue* xc_SortedQueue_t;
typedef xc_SortedQueue_t xc_SortedQueue_integer_t;
typedef xc_SortedQueue_t xc_SortedQueue_number_t;
typedef xc_SortedQueue_t xc_SortedQueue_bool_t;
typedef xc_SortedQueue_t xc_SortedQueue_string_t;
typedef xc_SortedQueue_t xc_SortedQueue_char_t;
xc_SortedQueue_t xstd_pqueue_new(xc_size_t elem, int cmp);
void             xstd_pqueue_push(xc_SortedQueue_t, const void* e);
void             xstd_pqueue_pop(xc_SortedQueue_t, void* out);   /* copy min to out, remove (abort if empty) */
void*            xstd_pqueue_peek(xc_SortedQueue_t);             /* ptr to min (abort if empty) */
xc_integer_t     xstd_pqueue_len(xc_SortedQueue_t);
void             xstd_pqueue_clear(xc_SortedQueue_t);

/* ─── Integer ranges (1..10 / until / downTo / step) ─────────────────────────
 * `end` is exclusive; `step` is signed and non-zero. Iterated by `for x in`.    */
typedef struct { xc_integer_t start; xc_integer_t end; xc_integer_t step; } xc_range_t;

/* ─── Optional helpers ───────────────────────────────────────────────────── */

typedef struct { bool has_value; xc_number_t  value; } xc_opt_number_t;
typedef struct { bool has_value; xc_integer_t value; } xc_opt_integer_t;
typedef struct { bool has_value; xc_bool_t    value; } xc_opt_bool_t;
typedef struct { bool has_value; xc_string_t  value; } xc_opt_string_t;
typedef struct { bool has_value; xc_char_t    value; } xc_opt_char_t;
typedef struct { bool has_value; xc_size_t    value; } xc_opt_size_t;

#define XC_SOME(val)  { .has_value = true,  .value = (val) }
#define XC_NONE_VAL   { .has_value = false }

/* ─── Constraint checking ────────────────────────────────────────────────── */

#define XC_CONSTRAINT_CHECK(cond, msg) \
    do { \
        if (!(cond)) { \
            fprintf(stderr, "xc: constraint violation: %s  (at %s:%d)\n", \
                    (msg), __FILE__, __LINE__); \
            abort(); \
        } \
    } while (0)

#define XC_PANIC(msg) \
    do { \
        fprintf(stderr, "xc: panic: %s  (at %s:%d)\n", (msg), __FILE__, __LINE__); \
        abort(); \
    } while (0)

/* ─── assert + test runner ───────────────────────────────────────────────────
 * `assert <expr>` lowers to xc_assert(cond, "<source>", xc_src_file, line). In a
 * normal program a failed assert prints and aborts; under the `xi test` runner it
 * records a failure and aborts only the current test (the rest still run).       */
extern const char* xc_src_file;                       /* defined in generated C */
xc_Json_t xstd_config_parse(xc_string_t path);        /* read + parse by extension (json/yaml/xml) */
void      xstd_config_watch(xc_string_t path, xc_string_t topic);  /* poll mtime -> ConfigChanged event */
void xc_assert(xc_bool_t cond, const char* text, const char* file, long long line);
void xc_assert_msg(xc_bool_t cond, const char* text, const char* msg, const char* file, long long line);
void xc_assert_eq(xc_bool_t eq, xc_string_t a, xc_string_t b, xc_bool_t negate, const char* file, long long line);
void xc_assert_close(xc_bool_t ok, xc_string_t a, xc_string_t b, xc_string_t eps, const char* file, long long line);
void xc_assert_ok(xc_bool_t is_ok, xc_string_t err, xc_bool_t want_ok, const char* file, long long line);
void xc_test_run(const char* name, void (*fn)(void)); /* run one test, isolated */
int  xc_test_summary(void);                           /* print totals; nonzero if any failed */
xc_bool_t xc_test_filter(const char* name);           /* honor XC_TEST_FILTER (substring) */

/* ─── System I/O ─────────────────────────────────────────────────────────── */

static inline void xc_stdout_writeln(xc_string_t s) {
    fwrite(s.data, 1, s.len, stdout);
    fputc('\n', stdout);
}

static inline void xc_stdout_write(xc_string_t s) {
    fwrite(s.data, 1, s.len, stdout);
}

static inline void xc_stderr_writeln(xc_string_t s) {
    fwrite(s.data, 1, s.len, stderr);
    fputc('\n', stderr);
}

static inline xc_opt_string_t xc_stdin_readline(void) {
    char buf[4096];
    if (!fgets(buf, sizeof(buf), stdin))
        return (xc_opt_string_t){ .has_value = false };
    xc_size_t len = strlen(buf);
    if (len > 0 && buf[len-1] == '\n') buf[--len] = '\0';
    char* copy = (char*)xc_heap_alloc(len + 1);
    memcpy(copy, buf, len + 1);
    return (xc_opt_string_t){ .has_value = true,
                               .value = { .data = copy, .len = len } };
}

/* ─── Math helpers ───────────────────────────────────────────────────────── */

static inline xc_number_t  xc_math_sqrt(xc_number_t x)  { return sqrt(x);  }
static inline xc_number_t  xc_math_pow(xc_number_t x, xc_number_t y) { return pow(x,y); }
static inline xc_number_t  xc_math_abs_n(xc_number_t x) { return fabs(x);  }
static inline xc_integer_t xc_math_abs_i(xc_integer_t x){ return x < 0 ? -x : x; }
static inline xc_number_t  xc_math_floor(xc_number_t x) { return floor(x); }
static inline xc_number_t  xc_math_ceil(xc_number_t x)  { return ceil(x);  }
static inline xc_number_t  xc_math_round(xc_number_t x) { return round(x); }

/* ─── Timestamp ──────────────────────────────────────────────────────────── */

static inline xc_timestamp_t xc_time_now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (xc_timestamp_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

/* ─── Bootstrap helpers (used by xc-in-X compiler) ──────────────────────── */

/* Character at position i in string (0-terminated if out of range). */
static inline xc_integer_t string_char_at(xc_string_t s, xc_integer_t i) {
    return (i >= 0 && (xc_size_t)i < s.len)
        ? (xc_integer_t)(unsigned char)s.data[(xc_size_t)i]
        : 0;
}
static inline xc_integer_t string_len(xc_string_t s) { return (xc_integer_t)s.len; }

/* Slice [from, to) — returned string borrows from the original. */
static inline xc_string_t string_slice(xc_string_t s, xc_integer_t from, xc_integer_t to) {
    if (from < 0) from = 0;
    if ((xc_size_t)to  > s.len) to = (xc_integer_t)s.len;
    if (from >= to) return (xc_string_t){ .data = s.data, .len = 0 };
    return (xc_string_t){ .data = s.data + from, .len = (xc_size_t)(to - from) };
}

/* Character class predicates (is_alpha/is_digit/is_alnum/is_space_c) are pure
 * ASCII-range logic and now live in Xi (impl/ffi/text/std_text.xi). */

/* Integer → string conversion (heap-allocated) */
static inline xc_string_t int_to_string(xc_integer_t n) { return xc_integer_to_string(n); }
static inline xc_string_t number_to_str(xc_number_t  n) { return xc_number_to_string(n);  }

/* File I/O */
xc_string_t file_read_all(xc_string_t path);

/* FFI bridge: Xi String <-> C cstring (const char*). */
const char* xstd_cstr(xc_string_t s);
xc_string_t xstd_from_cstr(const char* p);

/* Diagnostics: set the current source file, then report an error at a line and
   exit(1) with `xc: <file>:<line>: error: <msg>`. */
void diag_set_file(xc_string_t path);
void diag_error(xc_integer_t line, xc_string_t msg);
void diag_warn(xc_integer_t line, xc_string_t msg);

/* Boxed-instance allocator used by generated xc_new_<Class>. Routes through the
   active thread/request arena (so DI instances are reclaimed with it), else
   malloc. */
void* xc_obj_alloc(size_t n);

/* `scope { }` block hooks: enter installs a fresh arena (freed at leave) and
   returns the previous one to restore. Reclaims a loop iteration on the main
   thread. */
void* xc_scope_enter(void);
void  xc_scope_leave(void* prev);

/* ─── Interrupts (resumable conditions) ──────────────────────────────────────
   A dynamic stack of handlers. `try` pushes one and setjmp()s the skip target;
   `signal` finds the nearest matching handler, calls it (stack intact) for a
   resolution (1=recover, 0=skip), then continues or longjmp()s. */
typedef int (*xc_int_fn)(void* payload);
typedef struct xc_handler {
    int                type_id;
    xc_int_fn          fn;
    jmp_buf            unwind;
    struct xc_handler* prev;
} xc_handler_t;
extern xc_handler_t* xc_handlers;
xc_handler_t* xc_int_find(int type_id);
void          xc_int_unhandled(const char* name);
/* REPL / tooling */
xc_string_t  read_line(void);
xc_bool_t    stdin_eof(void);
void         flush_out(void);
xc_integer_t run_command(xc_string_t cmd);
xc_string_t  get_env(xc_string_t name, xc_string_t dflt);

/* Standard library primitives (wrapped by std/*.x) */
xc_number_t  xstd_sqrt(xc_number_t);  xc_number_t xstd_pow(xc_number_t, xc_number_t);
xc_number_t  xstd_exp(xc_number_t);   xc_number_t xstd_ln(xc_number_t);
xc_number_t  xstd_log10(xc_number_t); xc_number_t xstd_sin(xc_number_t);
xc_number_t  xstd_cos(xc_number_t);   xc_number_t xstd_tan(xc_number_t);
xc_number_t  xstd_floor(xc_number_t); xc_number_t xstd_ceil(xc_number_t);
xc_number_t  xstd_round(xc_number_t); xc_number_t xstd_fabs(xc_number_t);
xc_number_t  xstd_pi(void);           xc_number_t xstd_e(void);
xc_integer_t xstd_strlen(xc_string_t);
xc_integer_t xstd_char_at(xc_string_t, xc_integer_t);
xc_string_t  xstd_substring(xc_string_t, xc_integer_t, xc_integer_t);
xc_string_t  xstd_trim(xc_string_t);
xc_bool_t    xstd_starts_with(xc_string_t, xc_string_t);
xc_bool_t    xstd_ends_with(xc_string_t, xc_string_t);
xc_integer_t xstd_index_of(xc_string_t, xc_string_t);
xc_bool_t    xstd_contains(xc_string_t, xc_string_t);
xc_string_t  xstd_to_upper(xc_string_t);
xc_string_t  xstd_to_lower(xc_string_t);
xc_string_t  xstd_repeat(xc_string_t, xc_integer_t);
xc_string_t  xstd_replace(xc_string_t, xc_string_t, xc_string_t);
xc_arr_string_t xstd_split(xc_string_t s, xc_string_t sep);
xc_string_t  xstd_join(xc_arr_string_t parts, xc_string_t sep);
xc_bool_t    xstd_num_ok(xc_string_t);  xc_number_t  xstd_to_number(xc_string_t);
xc_bool_t    xstd_int_ok(xc_string_t);  xc_integer_t xstd_to_integer(xc_string_t);
xc_bool_t    xstd_file_exists(xc_string_t);
/* filesystem */
xc_bytes_t   xstd_read_bytes(xc_string_t path);
xc_bool_t    xstd_write_bytes(xc_string_t path, xc_bytes_t b);
xc_bool_t    xstd_is_dir(xc_string_t path);
xc_bool_t    xstd_is_file(xc_string_t path);
xc_integer_t xstd_file_size(xc_string_t path);
xc_integer_t xstd_mtime(xc_string_t path);
xc_bool_t    xstd_remove(xc_string_t path);
xc_bool_t    xstd_rename(xc_string_t from, xc_string_t to);
xc_bool_t    xstd_mkdir(xc_string_t path);
xc_bool_t    xstd_mkdir_all(xc_string_t path);
xc_string_t  xstd_cwd(void);
xc_arr_string_t xstd_list_dir(xc_string_t path);
/* networking (TCP, blocking) */
xc_integer_t xstd_tcp_connect(xc_string_t host, xc_integer_t port);
xc_integer_t xstd_tcp_listen(xc_integer_t port, xc_integer_t backlog);
xc_integer_t xstd_tcp_accept(xc_integer_t fd);
xc_integer_t xstd_sock_port(xc_integer_t fd);
xc_integer_t xstd_sock_send(xc_integer_t fd, xc_bytes_t data);
xc_bytes_t   xstd_sock_recv(xc_integer_t fd, xc_integer_t max);
xc_bool_t    xstd_sock_close(xc_integer_t fd);
void         xstd_exit(xc_integer_t);
xc_integer_t xstd_now_nanos(void);
void         xstd_sleep_ms(xc_integer_t);
xc_bool_t   file_write(xc_string_t path, xc_string_t content);
xc_bool_t   file_writeln(xc_string_t path, xc_string_t line);  /* appends newline */

/* Array helpers for bootstrap compiler (typed push) */
typedef struct { xc_string_t* data; xc_size_t len; xc_size_t cap; } xc_arr_string_heap_t;

/* ─── Array literal helpers ──────────────────────────────────────────────── */

/* Build an array fat pointer from a literal element list.
 * Usage:  XC_ARRAY_LIT(xc_Player_t, elem1, elem2, elem3)             */
#define XC_ARRAY_LIT(ElemType, ...) \
    ((struct { ElemType* data; xc_size_t len; xc_size_t cap; }){ \
        .data = (ElemType[]){ __VA_ARGS__ }, \
        .len  = sizeof((ElemType[]){ __VA_ARGS__ }) / sizeof(ElemType), \
        .cap  = sizeof((ElemType[]){ __VA_ARGS__ }) / sizeof(ElemType) \
    })

/* Empty typed array. */
#define XC_ARRAY_EMPTY(ElemType) \
    ((struct { ElemType* data; xc_size_t len; xc_size_t cap; }){ \
        .data = NULL, .len = 0, .cap = 0 \
    })

/* ─── Optional helpers ───────────────────────────────────────────────────── */

/* String-aware + operator: both sides must already be xc_string_t.
 * The X compiler emits explicit xc_number_to_string / xc_integer_to_string
 * wrapping when it knows one operand is not a string.               */
#define xc_string_add(a, b) xc_string_concat((a), (b))

/* ─── Process ────────────────────────────────────────────────────────────── */

static inline void xc_process_exit(xc_integer_t code) {
    exit((int)code);
}

#ifdef __cplusplus
}
#endif

#endif /* XC_RUNTIME_H */
