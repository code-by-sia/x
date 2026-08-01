// std/tracing/runtime — the one stateful piece. DefaultTracer owns every open
// span, keeps them in a stack so nested spans parent correctly, and hands
// finished spans to the injected exporter. Bind it `as singleton` (or mark the
// injection `as singleton`) so its state survives across calls.
//
// A user can replace it wholesale: define a class implementing Tracer and
// `bind Tracer -> MyTracer as singleton`. Likewise the exporter, sampler, id
// generator and clock are each an interface, so any one can be swapped alone.
import "std/tracing/ports.xi"
import "std/tracing/model.xi"

// Export the buffer once it reaches this many finished spans.
mapper batchSize() -> Integer => 512

class DefaultTracer implements Tracer {
    deps {
        exporter: SpanExporter,
        sampler:  Sampler,
        ids:      IdGenerator,
        clock:    TraceClock
    }
    // open spans as a stack (top = current), the buffer flushed to the exporter,
    // and a finished-span count.
    state { on: Bool = false, active: List<SpanData> = empty List<SpanData>, finished: List<SpanData> = empty List<SpanData>, total: Integer = 0 }

    consumer  enable() { this.on = true }
    predicate isEnabled() -> Bool => this.on
    projector spanCount() -> Integer => this.total

    producer start(name: String, kind: SpanKind) -> Span {
        let traceId = ""
        let parentId = ""
        let sampled = false
        let n = this.active.len()
        if n > 0 {
            let p = this.active.get(n - 1)                 // parent = current span
            traceId = p.context.traceId
            parentId = p.context.spanId
            sampled = p.context.sampled
        } else {
            traceId = ids.newTraceId()
            sampled = sampler.shouldSample(traceId, name, kind)
        }
        return begin(traceId, parentId, sampled, name, kind)
    }

    producer startChild(parent: SpanContext, name: String, kind: SpanKind) -> Span {
        return begin(parent.traceId, parent.spanId, parent.sampled, name, kind)
    }

    // Shared span creation: mint the id, push the open span current.
    producer begin(traceId: String, parentId: String, sampled: Bool, name: String, kind: SpanKind) -> Span {
        let spanId = ids.newSpanId()
        let ctx = SpanContext { traceId: traceId, spanId: spanId, sampled: sampled }
        let sd = SpanData {
            context: ctx, parentSpanId: parentId, name: name, kind: kind,
            startNanos: clock.nowNanos(), endNanos: 0,
            status: StatusUnset, statusMsg: "",
            attributes: empty List<Attribute>, events: empty List<SpanEvent>
        }
        this.active.push(sd)
        return Span { context: ctx, id: spanId }
    }

    // Index of the open span with this id, or -1. The active set is only as deep
    // as the current span nesting, so this is a short scan.
    mapper findActive(id: String) -> Integer {
        let i = 0
        while i < this.active.len() {
            if this.active.get(i).context.spanId == id { return i }
            i = i + 1
        }
        return 0 - 1
    }

    consumer setAttribute(span: Span, key: String, val: String) {
        let i = findActive(span.id)
        if i >= 0 { this.active.get(i).attributes.push(Attribute { key: key, value: val }) }
    }

    consumer addEvent(span: Span, name: String) {
        let i = findActive(span.id)
        if i >= 0 {
            this.active.get(i).events.push(SpanEvent { name: name, timeNanos: clock.nowNanos(), attributes: empty List<Attribute> })
        }
    }

    consumer setStatus(span: Span, code: StatusCode, message: String) {
        let i = findActive(span.id)
        if i >= 0 {
            let sd = this.active.get(i)
            this.active.set(i, SpanData {
                context: sd.context, parentSpanId: sd.parentSpanId, name: sd.name, kind: sd.kind,
                startNanos: sd.startNanos, endNanos: sd.endNanos,
                status: code, statusMsg: message,
                attributes: sd.attributes, events: sd.events
            })
        }
    }

    consumer recordError(span: Span, message: String) {
        addEvent(span, "exception")
        setStatus(span, StatusError, message)
    }

    mapper contextOf(span: Span) -> SpanContext => span.context

    consumer end(span: Span) {
        let i = findActive(span.id)
        if i >= 0 {
            let sd = this.active.get(i)
            let done = SpanData {
                context: sd.context, parentSpanId: sd.parentSpanId, name: sd.name, kind: sd.kind,
                startNanos: sd.startNanos, endNanos: clock.nowNanos(),
                status: sd.status, statusMsg: sd.statusMsg,
                attributes: sd.attributes, events: sd.events
            }
            this.active.removeAt(i)
            this.total = this.total + 1
            if done.context.sampled {
                this.finished.push(done)
                if this.finished.len() >= batchSize() { flush() }
            }
        }
    }

    consumer flush() {
        if this.finished.len() > 0 {
            exporter.export(this.finished)
            this.finished.clear()
        }
    }
}
