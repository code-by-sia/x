// Trace correlation: the current-context accessors track the active span, and
// correlate() appends ids only while a trace is active.
import "std/tracing/logs.xi"
import "std/tracing/testing.xi"

test "current trace/span id track the active span" (tracer: Tracer as singleton) {
    tracer.enable()
    assertEq(tracer.currentTraceId(), "")               // nothing active
    let s = tracer.start("op", SpanServer)
    assertEq(tracer.currentTraceId(), tracer.contextOf(s).traceId)
    assertEq(tracer.currentSpanId(), tracer.contextOf(s).spanId)
    let child = tracer.start("inner", SpanInternal)
    assertEq(tracer.currentSpanId(), tracer.contextOf(child).spanId)   // innermost is current
    tracer.end(child)
    assertEq(tracer.currentSpanId(), tracer.contextOf(s).spanId)       // back to the parent
    tracer.end(s)
    assertEq(tracer.currentTraceId(), "")               // nothing active again
}

test "correlate appends ids only when a trace is active" {
    assertEq(correlate("hi", "", ""), "hi")
    assertEq(correlate("hi", "abc123", "def456"), "hi trace_id=abc123 span_id=def456")
}

module App {}

module Test {
    bind SpanExporter -> InMemorySpanExporter
    bind SpanSink     -> MemorySink as singleton
}
