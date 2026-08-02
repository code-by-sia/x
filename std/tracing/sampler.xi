// std/tracing/sampler — the default sampler. Records every span; ratio-based and
// off samplers arrive with the sampling stage.
import "std/tracing/ports.xi"

class AlwaysOnSampler implements Sampler {
    deps {}
    predicate shouldSample(traceId: String, name: String, kind: SpanKind) -> Bool => true
    mapper    describe() -> String => "always-on"
}
