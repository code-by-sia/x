// The tracing bridge: the finished-span count and enabled flag surface in the
// std/monitoring report under "tracing".
import "std/tracing/monitoring.xi"
import "std/tracing/testing.xi"
import "std/monitoring.xi"
import "std/json.xi"

test "span count and enabled flag surface in the monitoring report" (mon: MonitoringRegistry as singleton, tracer: Tracer as singleton) {
    mon.enable()
    tracer.enable()
    tracer.end(tracer.start("a", SpanServer))
    tracer.end(tracer.start("b", SpanClient))
    let r = mon.report()
    let t = json.get(r, "tracing")
    assertEq(json.asNumber(json.get(t, "spans")), 2.0)
}

module App {}

module Test {
    bind SpanExporter -> InMemorySpanExporter
    bind SpanSink     -> MemorySink as singleton
}
