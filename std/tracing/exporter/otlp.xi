// std/tracing/exporter/otlp — export spans to an OpenTelemetry collector over
// HTTP (OTLP/JSON). Opt in by importing this file and binding it; a plain app
// keeps the console exporter.
//
//     import "std/tracing.xi"
//     import "std/tracing/exporter/otlp.xi"
//     module App { bind SpanExporter -> OtlpHttpSpanExporter as singleton }
//
// The endpoint and service name come from TracingConfig (std/tracing/config.xi),
// so pointing at a real collector is a config change.
import "std/tracing/ports.xi"
import "std/tracing/otlp_encode.xi"
import "std/tracing/config.xi"
import "std/http.xi"
import "std/json.xi"

class OtlpHttpSpanExporter implements SpanExporter {
    deps { config: TracingConfig }
    producer export(spans: List<SpanData>) -> Bool {
        if spans.len() == 0 { return true }
        let s = config.tracing()
        let body = json.stringify(otlpPayload(spans, s.serviceName))
        let resp = http.post(s.endpoint + "/v1/traces", body, "application/json")
        if isErr(resp) { return false }
        return resp.value.status >= 200 and resp.value.status < 300
    }
    consumer shutdown() { }
}
