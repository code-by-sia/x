// Stage 1 tracing core, asserted against the in-memory exporter. Deterministic
// without fixed ids: the tests check counts, nesting, attributes, and status.
import "std/tracing/testing.xi"

test "a finished span is exported after flush" (tracer: Tracer as singleton, sink: SpanSink as singleton) {
    sink.reset()
    tracer.enable()
    let s = tracer.start("op", SpanServer)
    tracer.setAttribute(s, "k", "v")
    tracer.end(s)
    assertEq(sink.count(), 0)                      // buffered, not yet exported
    tracer.flush()
    assertEq(sink.count(), 1)
    assertEq(tracer.spanCount(), 1)
}

test "a child span is parented to the current span" (tracer: Tracer as singleton, sink: SpanSink as singleton) {
    sink.reset()
    tracer.enable()
    let root = tracer.start("root", SpanServer)
    let child = tracer.start("child", SpanInternal)
    tracer.end(child)
    tracer.end(root)
    tracer.flush()
    let spans = sink.all()
    assertEq(spans.len(), 2)
    // child ends first, so it is exported first; its parent is the root span
    let c = spans.get(0)
    let r = spans.get(1)
    assertEq(c.name, "child")
    assertEq(r.name, "root")
    assertEq(c.parentSpanId, r.context.spanId)
    assertEq(r.parentSpanId, "")                   // root has no parent
    assertEq(c.context.traceId, r.context.traceId) // same trace
}

test "attributes and events accumulate on the open span" (tracer: Tracer as singleton, sink: SpanSink as singleton) {
    sink.reset()
    tracer.enable()
    let s = tracer.start("work", SpanInternal)
    tracer.setAttribute(s, "a", "1")
    tracer.setAttribute(s, "b", "2")
    tracer.addEvent(s, "step")
    tracer.end(s)
    tracer.flush()
    let sd = sink.all().get(0)
    assertEq(sd.attributes.len(), 2)
    assertEq(sd.attributes.get(0).key, "a")
    assertEq(sd.attributes.get(1).value, "2")
    assertEq(sd.events.len(), 1)
    assertEq(sd.events.get(0).name, "step")
}

test "recordError sets Error status and an exception event" (tracer: Tracer as singleton, sink: SpanSink as singleton) {
    sink.reset()
    tracer.enable()
    let s = tracer.start("risky", SpanInternal)
    tracer.recordError(s, "boom")
    tracer.end(s)
    tracer.flush()
    let sd = sink.all().get(0)
    assertEq(statusCodeNum(sd.status), 2)          // Error
    assertEq(sd.statusMsg, "boom")
    assertEq(sd.events.get(0).name, "exception")
}

module App {}

module Test {
    bind SpanExporter -> InMemorySpanExporter
    bind SpanSink     -> MemorySink as singleton
}
