// std/tracing/ports — the seams. Every capability is an interface so it can be
// bound and faked. No namespace: user code implements these directly.
import "std/tracing/model.xi"

// What application code uses to record work: one span per unit of work. It also
// carries the lifecycle (enable / flush), so a program injects one thing.
interface Tracer {
    consumer  enable()
    predicate isEnabled() -> Bool
    producer  start(name: String, kind: SpanKind) -> Span             // root, or child of the current span
    producer  startChild(parent: SpanContext, name: String, kind: SpanKind) -> Span
    consumer  setAttribute(span: Span, key: String, val: String)
    consumer  addEvent(span: Span, name: String)
    consumer  setStatus(span: Span, code: StatusCode, message: String)
    consumer  recordError(span: Span, message: String)                // an event plus Error status
    mapper    contextOf(span: Span) -> SpanContext
    consumer  end(span: Span)                                         // finish and hand to the exporter
    consumer  flush()                                                // force export of buffered spans
    projector spanCount() -> Integer                                 // spans finished this process
}

// Receives finished spans. Adapters: console, in-memory, OTLP over HTTP.
interface SpanExporter {
    producer export(spans: List<SpanData>) -> Bool                   // true on success
    consumer shutdown()
}

// Head-based sampling decision, made once per trace at the root span.
interface Sampler {
    predicate shouldSample(traceId: String, name: String, kind: SpanKind) -> Bool
    mapper    describe() -> String
}

// Kept separate so tests can bind deterministic ids and time.
interface IdGenerator {
    producer newTraceId() -> String
    producer newSpanId() -> String
}
interface TraceClock {
    producer nowNanos() -> Integer
}
