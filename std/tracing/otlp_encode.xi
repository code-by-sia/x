// std/tracing/otlp_encode — SpanData to OTLP/JSON (the OpenTelemetry wire form a
// Collector, Jaeger or Tempo understands). Note two OTLP/JSON rules: 64-bit
// times are encoded as strings, and every attribute value is wrapped in a typed
// envelope ({ "stringValue": ... } here).
import "std/tracing/model.xi"
import "std/json.xi"
import "std/convert.xi"
import "std/text.xi"

// The instrumentation scope version reported to the collector.
mapper otlpScopeVersion() -> String => "0.1.0"

// One OTLP attribute: { "key": k, "value": { "stringValue": v } }.
producer otlpAttr(key: String, val: String) -> Json {
    let v = json.object()
    v = json.set(v, "stringValue", json.str(val))
    let a = json.object()
    a = json.set(a, "key", json.str(key))
    a = json.set(a, "value", v)
    return a
}

producer otlpAttrList(attrs: List<Attribute>) -> Json {
    let arr = json.array()
    let i = 0
    while i < attrs.len() {
        let at = attrs.get(i)
        arr = json.push(arr, otlpAttr(at.key, at.value))
        i = i + 1
    }
    return arr
}

// One OTLP span object.
producer otlpSpan(sd: SpanData) -> Json {
    let o = json.object()
    o = json.set(o, "traceId", json.str(sd.context.traceId))
    o = json.set(o, "spanId", json.str(sd.context.spanId))
    if text.length(sd.parentSpanId) > 0 { o = json.set(o, "parentSpanId", json.str(sd.parentSpanId)) }
    o = json.set(o, "name", json.str(sd.name))
    o = json.set(o, "kind", json.int(kindCode(sd.kind)))
    o = json.set(o, "startTimeUnixNano", json.str(int_to_string(sd.startNanos)))   // string per OTLP/JSON
    o = json.set(o, "endTimeUnixNano", json.str(int_to_string(sd.endNanos)))
    o = json.set(o, "attributes", otlpAttrList(sd.attributes))
    if sd.events.len() > 0 {
        let evs = json.array()
        let j = 0
        while j < sd.events.len() {
            let ev = sd.events.get(j)
            let eo = json.object()
            eo = json.set(eo, "name", json.str(ev.name))
            eo = json.set(eo, "timeUnixNano", json.str(int_to_string(ev.timeNanos)))
            eo = json.set(eo, "attributes", otlpAttrList(ev.attributes))
            evs = json.push(evs, eo)
            j = j + 1
        }
        o = json.set(o, "events", evs)
    }
    let st = json.object()
    st = json.set(st, "code", json.int(statusCodeNum(sd.status)))
    if text.length(sd.statusMsg) > 0 { st = json.set(st, "message", json.str(sd.statusMsg)) }
    o = json.set(o, "status", st)
    return o
}

// The full request body: resourceSpans -> scopeSpans -> spans, with the service
// name on the resource.
producer otlpPayload(spans: List<SpanData>, serviceName: String) -> Json {
    let resAttrs = json.push(json.array(), otlpAttr("service.name", serviceName))
    let resource = json.set(json.object(), "attributes", resAttrs)

    let scopeObj = json.object()
    scopeObj = json.set(scopeObj, "name", json.str("std/tracing"))
    scopeObj = json.set(scopeObj, "version", json.str(otlpScopeVersion()))

    let spanArr = json.array()
    let i = 0
    while i < spans.len() {
        spanArr = json.push(spanArr, otlpSpan(spans.get(i)))
        i = i + 1
    }

    let scopeSpans = json.object()
    scopeSpans = json.set(scopeSpans, "scope", scopeObj)
    scopeSpans = json.set(scopeSpans, "spans", spanArr)

    let resourceSpans = json.object()
    resourceSpans = json.set(resourceSpans, "resource", resource)
    resourceSpans = json.set(resourceSpans, "scopeSpans", json.push(json.array(), scopeSpans))

    let root = json.object()
    root = json.set(root, "resourceSpans", json.push(json.array(), resourceSpans))
    return root
}
