// std/tracing/sampling — ratio and off samplers. Opt in and bind one; the
// umbrella's AlwaysOnSampler stays the default:
//
//     import "std/tracing/sampling.xi"
//     module App { bind Sampler -> RatioSampler }   // ratio from TracingConfig
//
// The decision is head-based (made once at the root) and stable per trace: it is
// derived from the trace id, so every service in a trace agrees, and children
// inherit the root's flag through the propagated context.
import "std/tracing/ports.xi"
import "std/tracing/config.xi"
import "std/text.xi"

// Value of the first n hex digits of s (used to derive a stable fraction).
mapper hexPrefixVal(s: String, n: Integer) -> Integer {
    let v = 0
    let i = 0
    let lim = n
    if text.length(s) < lim { lim = text.length(s) }
    while i < lim {
        let c = text.charAt(s, i)
        let d = 0
        if c >= 48 and c <= 57 { d = c - 48 }
        else if c >= 97 and c <= 102 { d = c - 97 + 10 }
        else if c >= 65 and c <= 70 { d = c - 65 + 10 }
        v = v * 16 + d
        i = i + 1
    }
    return v
}

// True for roughly `ratio` of trace ids, decided from the id's first 16 bits so
// the choice is stable for a whole trace. Pure, so it is unit-testable directly.
predicate ratioDecision(traceId: String, ratio: Number) -> Bool {
    if ratio >= 1.0 { return true }
    if ratio <= 0.0 { return false }
    let v = hexPrefixVal(traceId, 4)              // 0 .. 65535
    return (v / 65536.0) < ratio
}

class RatioSampler implements Sampler {
    deps { config: TracingConfig }
    predicate shouldSample(traceId: String, name: String, kind: SpanKind) -> Bool => ratioDecision(traceId, config.tracing().sampleRatio)
    mapper    describe() -> String => "ratio"
}

class AlwaysOffSampler implements Sampler {
    deps {}
    predicate shouldSample(traceId: String, name: String, kind: SpanKind) -> Bool => false
    mapper    describe() -> String => "always-off"
}
