// std/tracing/logs — trace-correlated logging. TraceLog wraps the injected
// Logger and appends the active span's ids, so a log line can be tied back to
// its trace:
//
//     class OrderService {
//         deps { log: TraceLog }
//         consumer place() { log.info("placing order") }   // -> "... trace_id=<id> span_id=<id>"
//     }
//
// It is a distinct interface (not a Logger replacement) to avoid a decorator
// depending on itself; when no span is active the message is logged unchanged.
import "std/tracing.xi"
import "std/log.xi"
import "std/text.xi"

// Append trace correlation to a message, but only while a trace is active.
mapper correlate(msg: String, traceId: String, spanId: String) -> String {
    if text.length(traceId) == 0 { return msg }
    return msg + " trace_id=" + traceId + " span_id=" + spanId
}

interface TraceLog {
    consumer info(msg: String)
    consumer warn(msg: String)
    consumer error(msg: String)
}

class DefaultTraceLog implements TraceLog {
    deps { logger: Logger, tracer: Tracer as singleton }
    consumer info(msg: String)  { logger.info(correlate(msg, tracer.currentTraceId(), tracer.currentSpanId())) }
    consumer warn(msg: String)  { logger.warn(correlate(msg, tracer.currentTraceId(), tracer.currentSpanId())) }
    consumer error(msg: String) { logger.error(correlate(msg, tracer.currentTraceId(), tracer.currentSpanId())) }
}
