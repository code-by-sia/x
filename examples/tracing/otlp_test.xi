// OTLP/JSON encoding, asserted structurally (no live collector needed). A span
// is built directly so ids and times are fixed, then the payload shape and the
// OTLP conventions (kind ints, string-encoded times, typed attribute values) are
// checked by navigating the Json.
import "std/tracing.xi"
import "std/tracing/otlp_encode.xi"
import "std/json.xi"

mapper sampleSpan() -> SpanData {
    let attrs = empty List<Attribute>
    attrs.push(Attribute { key: "user.id", value: "42" })
    let evs = empty List<SpanEvent>
    evs.push(SpanEvent { name: "cache.miss", timeNanos: 1500, attributes: empty List<Attribute> })
    return SpanData {
        context: SpanContext { traceId: "0af7651916cd43dd8448eb211c80319c", spanId: "b7ad6b7169203331", sampled: true },
        parentSpanId: "", name: "checkout", kind: SpanServer,
        startNanos: 1000, endNanos: 2000, status: StatusOk, statusMsg: "",
        attributes: attrs, events: evs
    }
}

test "otlp payload has the ResourceSpans / ScopeSpans / Span shape" {
    let spans = empty List<SpanData>
    spans.push(sampleSpan())
    let payload = otlpPayload(spans, "shop")

    let rs = json.at(json.get(payload, "resourceSpans"), 0)
    let resAttr = json.at(json.get(json.get(rs, "resource"), "attributes"), 0)
    assertEq(json.getString(resAttr, "key"), "service.name")
    assertEq(json.getString(json.get(resAttr, "value"), "stringValue"), "shop")

    let ss = json.at(json.get(rs, "scopeSpans"), 0)
    assertEq(json.getString(json.get(ss, "scope"), "name"), "std/tracing")
    let span0 = json.at(json.get(ss, "spans"), 0)
    assertEq(json.getString(span0, "name"), "checkout")
    assertEq(json.getString(span0, "traceId"), "0af7651916cd43dd8448eb211c80319c")
}

test "otlp uses OTLP conventions: kind ints, string times, typed attrs" {
    let spans = empty List<SpanData>
    spans.push(sampleSpan())
    let span0 = json.at(json.get(json.at(json.get(json.at(json.get(otlpPayload(spans, "shop"), "resourceSpans"), 0), "scopeSpans"), 0), "spans"), 0)

    assertEq(json.getNumber(span0, "kind"), 2.0)                         // SpanServer -> 2
    assertEq(json.getString(span0, "startTimeUnixNano"), "1000")        // 64-bit time as a string
    assertEq(json.getString(span0, "endTimeUnixNano"), "2000")
    assertEq(json.getNumber(json.get(span0, "status"), "code"), 1.0)    // StatusOk -> 1

    let attr0 = json.at(json.get(span0, "attributes"), 0)
    assertEq(json.getString(attr0, "key"), "user.id")
    assertEq(json.getString(json.get(attr0, "value"), "stringValue"), "42")

    let ev0 = json.at(json.get(span0, "events"), 0)
    assertEq(json.getString(ev0, "name"), "cache.miss")
    assertEq(json.getString(ev0, "timeUnixNano"), "1500")
}

module App {}
