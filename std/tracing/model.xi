// std/tracing/model — the value types of a trace. Data only; the behavior lives
// in the Tracer service. No namespace: the SpanKind variants and record types
// are used directly by application code (`SpanServer`, `tracer.contextOf(span)`).

// The propagatable identity of a span. traceId is 16 bytes (32 hex chars) and
// spanId is 8 bytes (16 hex chars), matching the OpenTelemetry wire format.
type SpanContext = {
    traceId: String,
    spanId:  String,
    sampled: Bool
}

// OpenTelemetry span kinds and status. The variant names are prefixed so they do
// not collide with a user program's own sum types (variant names are global).
type SpanKind   = | SpanInternal | SpanServer | SpanClient | SpanProducer | SpanConsumer
type StatusCode = | StatusUnset | StatusOk | StatusError

type Attribute = { key: String, value: String }
type SpanEvent = { name: String, timeNanos: Integer, attributes: List<Attribute> }

// A span in progress or finished. Held by the Tracer, never by user code. The
// attributes/events are Lists so they accumulate in place while the span is open.
type SpanData = {
    context:      SpanContext,
    parentSpanId: String,
    name:         String,
    kind:         SpanKind,
    startNanos:   Integer,
    endNanos:     Integer,
    status:       StatusCode,
    statusMsg:    String,
    attributes:   List<Attribute>,
    events:       List<SpanEvent>
}

// The lightweight handle user code holds: identity only. Every mutation goes
// through the Tracer, which owns the span's state.
type Span = { context: SpanContext, id: String }


// OTLP integer encodings (span.kind, status.code) and a lowercase kind name.
mapper kindCode(k: SpanKind) -> Integer {
    match k {
        SpanInternal -> { return 1 }
        SpanServer   -> { return 2 }
        SpanClient   -> { return 3 }
        SpanProducer -> { return 4 }
        SpanConsumer -> { return 5 }
    }
    return 0
}
mapper statusCodeNum(s: StatusCode) -> Integer {
    match s {
        StatusUnset -> { return 0 }
        StatusOk    -> { return 1 }
        StatusError -> { return 2 }
    }
    return 0
}
mapper kindName(k: SpanKind) -> String {
    match k {
        SpanInternal -> { return "internal" }
        SpanServer   -> { return "server" }
        SpanClient   -> { return "client" }
        SpanProducer -> { return "producer" }
        SpanConsumer -> { return "consumer" }
    }
    return "internal"
}
