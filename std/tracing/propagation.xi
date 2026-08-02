// std/tracing/propagation — W3C Trace Context, so a trace continues across
// process boundaries. The traceparent header is fixed-width:
//
//   00-<32 hex traceId>-<16 hex spanId>-<2 hex flags>      (55 characters)
//
// version is "00"; the only defined flag bit is "sampled" (0x01). Inject turns a
// SpanContext into the header value; extract parses one back, or none if it is
// absent or malformed.
import "std/tracing/ports.xi"
import "std/tracing/model.xi"
import "std/text.xi"

interface Propagator {
    mapper inject(ctx: SpanContext) -> String
    mapper extract(traceparent: String) -> SpanContext?
}

// Every character is a lowercase-or-uppercase hex digit (and the string is not
// empty). Kept module-local with a w3c prefix to avoid a global name clash.
predicate w3cAllHex(s: String) -> Bool {
    let n = text.length(s)
    if n == 0 { return false }
    let i = 0
    while i < n {
        let c = text.charAt(s, i)
        let ok = (c >= 48 and c <= 57) or (c >= 97 and c <= 102) or (c >= 65 and c <= 70)
        if not ok { return false }
        i = i + 1
    }
    return true
}

predicate w3cAllZero(s: String) -> Bool {
    let n = text.length(s)
    let i = 0
    while i < n {
        if text.charAt(s, i) != 48 { return false }        // '0'
        i = i + 1
    }
    return true
}

class W3CPropagator implements Propagator {
    deps {}

    mapper inject(ctx: SpanContext) -> String {
        let flags = "00"
        if ctx.sampled { flags = "01" }
        return "00-" + ctx.traceId + "-" + ctx.spanId + "-" + flags
    }

    mapper extract(traceparent: String) -> SpanContext? {
        if text.length(traceparent) != 55 { return none }
        if text.charAt(traceparent, 2) != 45 { return none }   // '-'
        if text.charAt(traceparent, 35) != 45 { return none }
        if text.charAt(traceparent, 52) != 45 { return none }
        let version = text.substring(traceparent, 0, 2)
        let traceId = text.substring(traceparent, 3, 35)
        let spanId  = text.substring(traceparent, 36, 52)
        let flags   = text.substring(traceparent, 53, 55)
        if version != "00" { return none }
        if not w3cAllHex(traceId) { return none }
        if not w3cAllHex(spanId) { return none }
        if not w3cAllHex(flags) { return none }
        if w3cAllZero(traceId) { return none }                    // all-zero id is invalid
        if w3cAllZero(spanId) { return none }
        return SpanContext { traceId: traceId, spanId: spanId, sampled: flags != "00" }
    }
}
