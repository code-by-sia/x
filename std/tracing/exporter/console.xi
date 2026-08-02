// std/tracing/exporter/console — prints each finished span as one Json line
// through the injected Logger. Zero setup, for local development. It is the only
// exporter the umbrella import pulls in, so a plain app auto-injects it.
import "std/tracing/ports.xi"
import "std/tracing/encode.xi"
import "std/log.xi"
import "std/json.xi"

class ConsoleSpanExporter implements SpanExporter {
    deps { logger: Logger }
    producer export(spans: List<SpanData>) -> Bool {
        let i = 0
        while i < spans.len() {
            logger.info(json.stringify(spanToJson(spans.get(i))))
            i = i + 1
        }
        return true
    }
    consumer shutdown() { }
}
