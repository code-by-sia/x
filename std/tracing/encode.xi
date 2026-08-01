// std/tracing/encode — turn a finished span into Json. The console exporter uses
// the flat form here; the OTLP exporter (a later module) reuses the same field
// values in the OpenTelemetry envelope.
import "std/tracing/model.xi"
import "std/json.xi"

// A finished span as a flat Json object: identity, timing, kind, status, and its
// attributes as a nested object.
producer spanToJson(sd: SpanData) -> Json {
    let o = json.object()
    o = json.set(o, "name", json.str(sd.name))
    o = json.set(o, "traceId", json.str(sd.context.traceId))
    o = json.set(o, "spanId", json.str(sd.context.spanId))
    o = json.set(o, "parentSpanId", json.str(sd.parentSpanId))
    o = json.set(o, "kind", json.str(kindName(sd.kind)))
    o = json.set(o, "startNanos", json.int(sd.startNanos))
    o = json.set(o, "endNanos", json.int(sd.endNanos))
    o = json.set(o, "durationNanos", json.int(sd.endNanos - sd.startNanos))
    o = json.set(o, "status", json.int(statusCodeNum(sd.status)))
    if string_len(sd.statusMsg) > 0 { o = json.set(o, "statusMessage", json.str(sd.statusMsg)) }
    let a = json.object()
    let i = 0
    while i < sd.attributes.len() {
        let at = sd.attributes.get(i)
        a = json.set(a, at.key, json.str(at.value))
        i = i + 1
    }
    o = json.set(o, "attributes", a)
    if sd.events.len() > 0 {
        let evs = json.array()
        let j = 0
        while j < sd.events.len() {
            let ev = sd.events.get(j)
            let eo = json.object()
            eo = json.set(eo, "name", json.str(ev.name))
            eo = json.set(eo, "timeNanos", json.int(ev.timeNanos))
            evs = json.push(evs, eo)
            j = j + 1
        }
        o = json.set(o, "events", evs)
    }
    return o
}
