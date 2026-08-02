// Every mechanic is an interface, so a program can replace any of them with a
// bind: the exporter, the sampler, the id generator, the clock, or the whole
// Tracer. These tests bind user-supplied versions and show they take over.
import "std/tracing/testing.xi"

// A user's sampler that keeps tracing structurally on but emits nothing.
class OffSampler implements Sampler {
    deps {}
    predicate shouldSample(traceId: String, name: String, kind: SpanKind) -> Bool => false
    mapper    describe() -> String => "off"
}

// A user's id generator with fixed ids.
class ConstIds implements IdGenerator {
    deps {}
    producer newTraceId() -> String => "11111111111111111111111111111111"
    producer newSpanId() -> String  => "2222222222222222"
}

test "a bound sampler replaces the default" (tracer: Tracer as singleton, sink: SpanSink as singleton) {
    sink.reset()
    tracer.enable()
    let s = tracer.start("x", SpanServer)
    tracer.end(s)
    tracer.flush()
    assertEq(sink.count(), 0)          // OffSampler decided not to record it
}

test "a bound id generator replaces the default" (tracer: Tracer as singleton) {
    tracer.enable()
    let s = tracer.start("x", SpanServer)
    assertEq(tracer.contextOf(s).traceId, "11111111111111111111111111111111")
    assertEq(tracer.contextOf(s).spanId, "2222222222222222")
    tracer.end(s)
}

module App {}

module Test {
    bind SpanExporter -> InMemorySpanExporter
    bind SpanSink     -> MemorySink as singleton
    bind Sampler      -> OffSampler          // replaces AlwaysOnSampler
    bind IdGenerator  -> ConstIds            // replaces RandomIdGenerator
}
