// std/tracing/testing — an in-memory exporter for asserting on emitted spans.
// Import it only from tests; a normal app never sees it, so the console exporter
// stays the single SpanExporter and auto-injects.
//
//     module Test {
//         bind SpanExporter -> InMemorySpanExporter
//         bind SpanSink     -> MemorySink as singleton
//     }
//
//     test "..." (tracer: Tracer as singleton, sink: SpanSink as singleton) { ... }
import "std/tracing.xi"

// A shared store the exporter writes to and the test reads from. A single
// interface with a single implementation, so both sides share one singleton.
interface SpanSink {
    consumer  record(sd: SpanData)
    projector count() -> Integer
    producer  all() -> List<SpanData>
    consumer  reset()
}

class MemorySink implements SpanSink {
    deps {}
    state { spans: List<SpanData> = empty List<SpanData> }
    consumer  record(sd: SpanData) { this.spans.push(sd) }
    projector count() -> Integer => this.spans.len()
    producer  all() -> List<SpanData> => this.spans
    consumer  reset() { this.spans.clear() }
}

// Records every exported span into the shared sink instead of printing it.
class InMemorySpanExporter implements SpanExporter {
    deps { sink: SpanSink }
    producer export(spans: List<SpanData>) -> Bool {
        let i = 0
        while i < spans.len() {
            sink.record(spans.get(i))
            i = i + 1
        }
        return true
    }
    consumer shutdown() { }
}
