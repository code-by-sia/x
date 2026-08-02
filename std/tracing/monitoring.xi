// std/tracing/monitoring — surface tracing in the std/monitoring report, without
// either module depending on the other's internals. Import it and the span count
// joins /monitor/metrics under "tracing", the same way WebMonitoring adds "web".
import "std/monitoring.xi"
import "std/tracing.xi"
import "std/json.xi"

class TracingMonitoring implements Monitoring {
    deps { tracer: Tracer as singleton }
    mapper    name() -> String => "tracing"
    consumer  startMonitor() { }
    producer  healthy() -> Bool => true
    producer  metrics() -> Json {
        let o = json.object()
        o = json.set(o, "spans", json.int(tracer.spanCount()))
        o = json.set(o, "enabled", json.of(tracer.isEnabled()))
        return o
    }
}
