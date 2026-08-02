# std/tracing: OpenTelemetry-compatible distributed tracing

**Status: Stages 1-3 implemented (tracing core + W3C propagation + OTLP/HTTP
exporter with typed config); the ratio sampler and the monitoring/web bridges
are the remaining follow-ups.**

`std/tracing` gives an Xi program the tracing signal of OpenTelemetry: spans with
a trace/span identity, parent-child nesting, attributes, events, status, a
sampler, context propagation across process boundaries (W3C Trace Context), and
exporters (console, in-memory, and OTLP over HTTP to any OpenTelemetry
collector). It sits **alongside** `std/monitoring`: monitoring answers "is this
process healthy right now" with gauges and health checks, and tracing answers
"what happened on this one request, across every service it touched". A bridge
lets traced spans surface in the existing `/monitor/metrics` report so the two
are one story.

It follows the same rules as `std/monitoring`: it is a library of interfaces you
opt into, and it is **off until you enable it**. An app that imports nothing
carries no tracing surface; an app that imports but never calls `enable()` pays
nothing at runtime.

A useful property of the design: it needs **no new C or runtime code**. Every
primitive is already in the standard library: `crypto.randomHex` for ids,
`time.nowNanos` for timing, `std/http` for OTLP export and header propagation,
`std/json` for the payload, and the injected `Logger` for correlation. The whole
module is portable Xi.

## Where metrics and logs fit

"Full OpenTelemetry" is three signals. This module owns **traces**. The other
two are addressed without pulling them under a "tracing" name:

- **Metrics** already have a home. `std/monitoring` exposes `monitor.gauge(...)`
  and the `Monitoring` interface. The richer OTel instruments (counter, up-down
  counter, histogram) are a natural follow-up as `std/monitoring/instruments.xi`,
  and the OTLP exporter here is written so the same transport can carry metric
  data later.
- **Logs** are correlated, not replaced. `std/tracing` provides a `TraceContext`
  accessor and a thin `Logger` decorator that stamps every line with the active
  `trace_id` / `span_id`, so existing `logger.info(...)` calls join the trace
  without changing call sites.

The rest of this document is the tracing design.

## Enabling it (the developer experience first)

```x
import "std/tracing.xi"

async entry (tracer: Tracer, tracing: TracingRuntime as singleton) main(args: String[]) -> Integer {
    tracing.enable()                              // nothing is live until this runs

    let span = tracer.start("checkout", Server)
    tracer.setAttribute(span, "user.id", "42")
    // ... work ...
    tracer.addEvent(span, "payment.authorized")
    tracer.end(span)                              // span is sampled, then exported

    tracing.flush()                               // force any buffered export
    return 0
}

module App {
    // Choose where spans go. Omit to default to the console exporter.
    bind SpanExporter -> OtlpHttpSpanExporter as singleton
    bind Sampler      -> RatioSampler          as singleton
}
```

The endpoint, service name, and sample ratio come from config (see
[Configuration](#configuration)), so switching from console to a real collector
is a config change, not a code change.

### Replacing the defaults

Every mechanic is an interface, so a program overrides any one with a `bind`,
and the compiler injects the replacement everywhere the default would have gone:

```x
module App {
    bind Tracer       -> MyTracer         as singleton   // replace DefaultTracer wholesale
    bind SpanExporter -> MyExporter       as singleton   // send spans somewhere else
    bind Sampler      -> MySampler                        // decide what to record
    bind IdGenerator  -> MyIdGenerator                    // supply your own ids
    bind TraceClock   -> MyClock                          // control time (tests)
}
```

The defaults (`DefaultTracer`, `ConsoleSpanExporter`, `AlwaysOnSampler`,
`RandomIdGenerator`, `SystemTraceClock`) are ordinary implementations with no
special status; a bound alternative simply wins. This is what the test suite
does to inject an in-memory exporter and deterministic samplers.

## Core model (domain types)

All of these are plain value types in `std/tracing/model.xi`. They are data; the
behavior lives in the service layer.

```x
// The propagatable identity of a span. traceId is 16 bytes (32 hex chars),
// spanId is 8 bytes (16 hex chars), matching the OpenTelemetry wire format.
type SpanContext = {
    traceId: String,
    spanId:  String,
    sampled: Bool
}

type SpanKind   = | Internal | Server | Client | Producer | Consumer
type StatusCode = | Unset | Ok | Error

type Attribute  = { key: String, value: String }   // string-valued in v1
type SpanEvent  = { name: String, timeNanos: Integer, attributes: Attribute[] }

// A finished span, ready to export. Held by the runtime, not by user code.
type SpanData = {
    context:      SpanContext,
    parentSpanId: String,              // "" when this is a root span
    name:         String,
    kind:         SpanKind,
    startNanos:   Integer,
    endNanos:     Integer,
    status:       StatusCode,
    statusMsg:    String,
    attributes:   Attribute[],
    events:       SpanEvent[]
}

// Describes the entity producing the telemetry (OTel Resource).
type Resource = { serviceName: String, attributes: Attribute[] }

// The lightweight handle user code holds. It is identity only; all mutation
// goes through the Tracer, which owns the span's state (see rationale below).
type Span = { context: SpanContext, id: String }
```

`Attribute.value` is a `String` in the first version. Typed attribute values
(bool / int / double / array) are an additive follow-up; the OTLP encoder
already wraps values in a typed envelope, so widening later does not break the
wire format.

## Ports (interfaces)

`std/tracing/ports.xi`. Every seam is an interface so it can be bound and faked.

```x
// What application code uses. One span per unit of work.
interface Tracer {
    producer start(name: String, kind: SpanKind) -> Span            // root or child of current
    producer startChild(parent: SpanContext, name: String, kind: SpanKind) -> Span
    consumer setAttribute(span: Span, key: String, value: String)
    consumer addEvent(span: Span, name: String)
    consumer setStatus(span: Span, code: StatusCode, message: String)
    consumer recordError(span: Span, message: String)               // event + Error status
    mapper   contextOf(span: Span) -> SpanContext
    consumer end(span: Span)                                         // finish + hand to processor
}

// Receives finished spans. Adapters: console, in-memory, OTLP/HTTP.
interface SpanExporter {
    producer export(spans: SpanData[]) -> Bool                      // true on success
    consumer shutdown()
}

// Head-based sampling decision, made once per trace at the root.
interface Sampler {
    predicate shouldSample(traceId: String, name: String, kind: SpanKind) -> Bool
    mapper    describe() -> String                                  // for diagnostics
}

// Seams kept separate so tests get deterministic ids and time.
interface IdGenerator { producer newTraceId() -> String  producer newSpanId() -> String }
interface TraceClock  { producer nowNanos() -> Integer }

// W3C Trace Context across process boundaries.
interface Propagator {
    mapper inject(ctx: SpanContext) -> String                       // -> traceparent header value
    mapper extract(traceparent: String) -> SpanContext?             // none if absent/malformed
}

// The composition object the app enables and flushes. Holds the resource,
// the active/finished spans, and drives the processor/exporter.
interface TracingRuntime {
    consumer  enable()
    predicate isEnabled() -> Bool
    consumer  flush()                                               // force export of buffered spans
    consumer  shutdown()
    mapper    spanCount() -> Integer                                // spans finished this process
}
```

## The service layer

`std/tracing/runtime.xi`. One class, bound `as singleton`, owns all span state
and orchestrates sampling and export. This is the only stateful piece.

```x
class DefaultTracingRuntime implements TracingRuntime, Tracer {
    deps {
        exporter: SpanExporter,
        sampler:  Sampler,
        ids:      IdGenerator,
        clock:    TraceClock,
        config:   TracingConfig
    }
    state {
        on:       Bool = false
        current:  SpanContext?                 // innermost active span (sync convenience)
        active:   Map<String, SpanData>        // spanId -> in-progress span
        finished: List<SpanData>               // buffer flushed to the exporter
    }

    consumer enable() { this.on = true }
    predicate isEnabled() -> Bool => this.on

    producer start(name: String, kind: SpanKind) -> Span {
        // root, or child of `current` if one is active
        ...
    }
    consumer end(span: Span) {
        // stamp endNanos, move active -> finished, set current back to parent,
        // and when the buffer reaches the batch size, export it.
        ...
    }
    consumer flush() { exporter.export(this.finished.toArray())  this.finished.clear() }
}
```

Two processor behaviors, chosen by config:

- **Simple**: export each span the moment it ends. Lowest latency, most calls.
- **Batch** (default): buffer finished spans and flush when the batch fills or on
  `flush()` / `shutdown()`. Fewer, larger exports.

### Why the API is tracer-centric, not span-centric

OpenTelemetry's own API reads `span.setAttribute(...)`. Xi's dependency injection
resolves one instance of a class; it has no idiomatic way to hand each
dynamically created span its own injected exporter. So a span here is a small
value (`type Span`), and the mutating operations live on the injected `Tracer`,
which owns the state: `tracer.setAttribute(span, ...)`. This keeps all mutable
state in one singleton, keeps every seam injectable and fakeable, and avoids
class literals that skip state initialization. A fluent `span.setAttribute(...)`
sugar via extension methods can be added later if it proves worth the indirection.

## Context propagation (W3C Trace Context)

`std/tracing/propagation.xi` implements the standard `traceparent` header so a
trace continues across services:

```
traceparent: 00-<32 hex trace id>-<16 hex span id>-<2 hex flags>
             ^version           ^trace-id         ^parent-id     ^01 = sampled
```

**Outgoing** (this service calls another): inject the current context and send it
as a header through `std/http`.

```x
let child = tracer.start("GET inventory", Client)
let hdr   = propagator.inject(tracer.contextOf(child))       // "00-<trace>-<span>-01"
let resp  = http.requestWith("GET", url, "", "", mapOf("traceparent" to hdr))
tracer.end(child)
```

**Incoming** (a web handler): extract the parent from the request headers and
start the server span as its child.

```x
action handle(req: HttpRequest, res: HttpResponse) where web.route(req, "GET", "/orders/:id") {
    let parent = propagator.extract(web.headers(req).getOr("traceparent", ""))
    let span = if let p = parent { tracer.startChild(p, "GET /orders/:id", Server) }
               else              { tracer.start("GET /orders/:id", Server) }
    // ... handle ...
    tracer.end(span)
}
```

`std/http` gains one additive helper, `requestWith(..., headers: Map<String,String>)`,
to carry the injected header. Nothing about `traceparent` is special to it.

## Exporters

`std/tracing/exporter/`. All implement `SpanExporter`; choose one with a `bind`.

- **`ConsoleSpanExporter`** (default): prints each span as one JSON line via the
  `Logger`. Zero setup, for local development.
- **`InMemorySpanExporter`**: keeps finished spans in a `List` and exposes them
  for assertions. The key to unit-testing instrumentation.
- **`OtlpHttpSpanExporter`**: POSTs OTLP/JSON to
  `<endpoint>/v1/traces` (default `http://localhost:4318/v1/traces`) via
  `std/http`. This is the real OpenTelemetry wire, understood by the Collector,
  Jaeger, Tempo, and the vendor backends.

### OTLP/JSON mapping

`SpanData` maps to OTLP `ResourceSpans` like this (built with `std/json`):

```json
{
  "resourceSpans": [{
    "resource": {
      "attributes": [{ "key": "service.name", "value": { "stringValue": "checkout" } }]
    },
    "scopeSpans": [{
      "scope": { "name": "std/tracing", "version": "<module version>" },
      "spans": [{
        "traceId": "<32 hex>", "spanId": "<16 hex>", "parentSpanId": "<16 hex or empty>",
        "name": "checkout", "kind": 2,
        "startTimeUnixNano": "1690000000000000000",
        "endTimeUnixNano":   "1690000000123000000",
        "attributes": [{ "key": "user.id", "value": { "stringValue": "42" } }],
        "events": [{ "name": "payment.authorized", "timeUnixNano": "..." , "attributes": [] }],
        "status": { "code": 1 }
      }]
    }]
  }]
}
```

Enum encodings (from the OTLP spec):

| Xi `SpanKind` | OTLP kind | Xi `StatusCode` | OTLP status code |
| ------------- | --------- | --------------- | ---------------- |
| Internal      | 1         | Unset           | 0                |
| Server        | 2         | Ok              | 1                |
| Client        | 3         | Error           | 2                |
| Producer      | 4         |                 |                  |
| Consumer      | 5         |                 |                  |

Times are unsigned nanoseconds since the Unix epoch, stringified (OTLP/JSON
encodes 64-bit ints as strings). `time.nowNanos()` supplies them directly.

## Sampling

`std/tracing/sampler.xi`:

- **`AlwaysOnSampler`** (default): sample everything. Correct for low volume.
- **`AlwaysOffSampler`**: sample nothing (tracing structurally on, output off).
- **`RatioSampler`**: sample a fixed fraction, decided from the trace id so the
  choice is stable for the whole trace. Ratio comes from config.

Sampling is head-based and decided once at the root; children inherit the
root's `sampled` flag through the propagated context, so a trace is all-or-nothing
across services.

## Integration with std/monitoring

`std/tracing/monitoring.xi` bridges the two so tracing shows up where operators
already look, without either module depending on the other's internals:

```x
class TracingMonitoring implements Monitoring {
    deps { tracing: TracingRuntime as singleton }
    mapper    name() -> String => "tracing"
    consumer  startMonitor() { }
    producer  healthy() -> Bool => true
    producer  metrics() -> Json {
        let o = json.object()
        o = json.set(o, "spans", json.int(tracing.spanCount()))
        o = json.set(o, "enabled", json.bool(tracing.isEnabled()))
        return o
    }
}
```

Import it and the span count joins `/monitor/metrics` under `"tracing"`, exactly
like `WebMonitoring` adds `"web"`.

## Web auto-instrumentation

`std/tracing/web.xi` offers a ready-made server span per request so apps do not
hand-instrument every handler. Xi web dispatch is a set of `where`-guarded
handlers rather than a middleware chain, so the module provides two forms:

- **A wrapper helper** `traced(req, res, name) { ... }` that starts a server span
  (extracting any inbound `traceparent`), runs the block, records the response
  status, and ends the span. Explicit, no framework hook required.
- **A catch-all `TracingHandler`** bound ahead of app handlers that opens the
  span, stores its context for the request, and lets the matching handler run
  inside it. This depends on a small ordering/where-guard capability; if that
  proves awkward, the wrapper is the supported path and the catch-all is
  documented as best-effort.

Standard HTTP semantic-convention attributes (`http.request.method`,
`http.route`, `http.response.status_code`, `url.path`) are set automatically.

## Configuration

`std/tracing/config.xi` reads typed config so deployment is not a recompile:

```x
type TracingSettings = {
    serviceName: String,     // -> Resource service.name        (default: module id)
    exporter:    String,     // "console" | "otlp" | "none"      (default: "console")
    endpoint:    String,     // OTLP base URL                    (default: "http://localhost:4318")
    sampleRatio: Number,     // 0.0 .. 1.0 for RatioSampler      (default: 1.0)
    batch:       Bool        // batch vs simple processor        (default: true)
}

interface TracingConfig { mapper tracing() -> TracingSettings }

module App { bind TracingConfig -> readConfig("application.yaml") }
```

## Testing

Every seam is an interface, so a `module Test` binds deterministic doubles:

```x
module Test {
    bind SpanExporter -> InMemorySpanExporter as singleton
    bind IdGenerator  -> FixedIdGenerator             // "0000...01", "0000...02", ...
    bind TraceClock   -> StepClock                     // advances a fixed step per call
    bind Sampler      -> AlwaysOnSampler
}

test "a span records its attributes and nesting" (tracer: Tracer, sink: SpanExporter) {
    let root = tracer.start("root", Server)
    let child = tracer.start("child", Internal)        // parented to root via current
    tracer.setAttribute(child, "k", "v")
    tracer.end(child)
    tracer.end(root)
    let spans = (sink as InMemorySpanExporter).spans()
    assertEq(spans.len(), 2)
    assertEq(spans.get(0).parentSpanId, spans.get(1).context.spanId)   // child before root
}
```

Deterministic ids and clock make span output byte-stable, so exporter encoding
(including the OTLP/JSON shape) can be asserted exactly.

## File layout

```
std/tracing.xi                     // umbrella: imports the pieces, re-exports the API
std/tracing/model.xi               // SpanContext, SpanKind, StatusCode, SpanData, ...
std/tracing/ports.xi               // Tracer, SpanExporter, Sampler, IdGenerator, ...
std/tracing/runtime.xi             // DefaultTracingRuntime (Tracer + TracingRuntime)
std/tracing/ids.xi                 // RandomIdGenerator (crypto.randomHex), SystemTraceClock
std/tracing/sampler.xi             // AlwaysOn / AlwaysOff / RatioSampler
std/tracing/propagation.xi         // W3C traceparent inject/extract
std/tracing/exporter/console.xi    // ConsoleSpanExporter
std/tracing/exporter/memory.xi     // InMemorySpanExporter
std/tracing/exporter/otlp.xi       // OtlpHttpSpanExporter + OTLP/JSON encoder
std/tracing/config.xi              // TracingSettings, TracingConfig
std/tracing/monitoring.xi          // TracingMonitoring bridge to std/monitoring
std/tracing/web.xi                 // server-span helper + semantic conventions
examples/tracing/*.xi              // runnable demos
docs/tracing.md                    // this document
```

## Staged delivery

Each stage is self-contained: interfaces + implementations + `*_test.xi` +
a runnable example + docs, compiled and tested before the next.

1. **Tracing core**: model, ports, `DefaultTracingRuntime`, `RandomIdGenerator`,
   `SystemTraceClock`, `AlwaysOnSampler`, `ConsoleSpanExporter`,
   `InMemorySpanExporter`, `enable()`/`flush()`. Manual spans, nesting, attributes,
   events, status. Tests + example.
2. **Propagation**: W3C `traceparent` inject/extract, `http.requestWith`, the
   incoming-header pattern. Cross-service parenting test.
3. **OTLP exporter**: `OtlpHttpSpanExporter` + OTLP/JSON encoder, config-driven
   endpoint. Byte-exact encoder test against a fixed span.
4. **Sampling + config**: `RatioSampler`, `TracingSettings`, batch vs simple
   processor.
5. **monitoring bridge + web auto-instrumentation**: `TracingMonitoring`,
   `std/tracing/web.xi`, HTTP semantic conventions.

Then, as separate follow-ups outside `std/tracing`: OTel metric instruments in
`std/monitoring/instruments.xi` and trace-correlated logging.

## Open questions / limitations

- **Async context.** The `current` span is process-wide convenience for
  synchronous code. Xi `async` runs on worker threads; a span started on the main
  path is not implicitly current inside an `async` body. The reliable pattern is
  explicit parent passing (`startChild(parentContext, ...)`), which this design
  makes first-class. Implicit per-thread context is a later question.
- **Attribute value types.** String-only in v1; the OTLP envelope is already
  typed, so bool/int/double/array widen additively.
- **Metric and log signals.** Deliberately out of `std/tracing`; addressed in the
  sibling modules noted above so the "tracing" name stays honest.
- **Web catch-all ordering.** Depends on handler ordering guarantees; the explicit
  `traced(...)` wrapper is the guaranteed path.
