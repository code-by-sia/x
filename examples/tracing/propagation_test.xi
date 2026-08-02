// W3C Trace Context: inject/extract round-trips, malformed headers are refused,
// and a remote parent continues the same trace into a local child span.
import "std/tracing/testing.xi"

test "inject then extract round-trips the context" (prop: Propagator) {
    let ctx = SpanContext { traceId: "0af7651916cd43dd8448eb211c80319c", spanId: "b7ad6b7169203331", sampled: true }
    let hdr = prop.inject(ctx)
    assertEq(hdr, "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01")
    if let got = prop.extract(hdr) {
        assertEq(got.traceId, ctx.traceId)
        assertEq(got.spanId, ctx.spanId)
        assert got.sampled : "sampled flag should survive"
    } else {
        assert false : "extract should succeed on a valid header"
    }
}

test "the unsampled flag round-trips as 00" (prop: Propagator) {
    let ctx = SpanContext { traceId: "0af7651916cd43dd8448eb211c80319c", spanId: "b7ad6b7169203331", sampled: false }
    assertEq(prop.inject(ctx), "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-00")
    if let got = prop.extract(prop.inject(ctx)) { assert not got.sampled : "should be unsampled" }
    else { assert false : "extract should succeed" }
}

test "malformed headers are rejected" (prop: Propagator) {
    if let x = prop.extract("") { assert false : "empty must be none" } else { assert true }
    if let x = prop.extract("garbage") { assert false : "garbage must be none" } else { assert true }
    if let x = prop.extract("00-xyz-b7ad6b7169203331-01") { assert false : "wrong length" } else { assert true }
    if let x = prop.extract("00-00000000000000000000000000000000-b7ad6b7169203331-01") { assert false : "zero trace id invalid" } else { assert true }
    if let x = prop.extract("00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-0z") { assert false : "non-hex flags" } else { assert true }
}

test "a remote parent continues the trace into a local child" (tracer: Tracer as singleton, prop: Propagator, sink: SpanSink as singleton) {
    sink.reset()
    tracer.enable()
    let remote = SpanContext { traceId: "0af7651916cd43dd8448eb211c80319c", spanId: "b7ad6b7169203331", sampled: true }
    if let parent = prop.extract(prop.inject(remote)) {          // service A -> header -> service B
        let server = tracer.startChild(parent, "GET /orders", SpanServer)
        tracer.end(server)
        tracer.flush()
        let sd = sink.all().get(0)
        assertEq(sd.context.traceId, remote.traceId)             // same trace across the boundary
        assertEq(sd.parentSpanId, remote.spanId)                 // parented to the remote span
        assert sd.context.spanId != remote.spanId : "child has its own span id"
    } else {
        assert false : "extract should succeed"
    }
}

module App {}

module Test {
    bind SpanExporter -> InMemorySpanExporter
    bind SpanSink     -> MemorySink as singleton
}
