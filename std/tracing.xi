// std/tracing — OpenTelemetry-compatible distributed tracing for Xi.
//
// Import this to get the tracing API and the default wiring: a random id
// generator, a system clock, an always-on sampler, and the console exporter.
// Inject the Tracer `as singleton` and enable it:
//
//     import "std/tracing.xi"
//
//     async entry (tracer: Tracer as singleton) main(args: String[]) -> Integer {
//         tracer.enable()
//         let s = tracer.start("checkout", SpanServer)
//         tracer.setAttribute(s, "user.id", "42")
//         tracer.end(s)
//         tracer.flush()
//         return 0
//     }
//     module App {}
//
// Nothing is live until `enable()` runs. To send spans to a collector instead of
// the console, bind a different SpanExporter (a later module ships the OTLP one).
// See docs/tracing.md for the full design.
import "std/tracing/model.xi"
import "std/tracing/ports.xi"
import "std/tracing/encode.xi"
import "std/tracing/ids.xi"
import "std/tracing/sampler.xi"
import "std/tracing/propagation.xi"
import "std/tracing/exporter/console.xi"
import "std/tracing/runtime.xi"
