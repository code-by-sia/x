// std/tracing/web — a server span per HTTP request. Xi web dispatch is a set of
// where-guarded handlers rather than a middleware chain, so a handler injects a
// WebTracer and brackets its work:
//
//     class OrdersController implements WebRequestHandler {
//         deps { wt: WebTracer }
//         action handle(req: HttpRequest, res: HttpResponse) where web.route(req, "GET", "/orders/:id") {
//             let span = wt.begin(req, "GET /orders/:id")
//             // ... handle, res.send(...) ...
//             wt.finish(span, 200)
//         }
//     }
//
// begin continues an inbound trace (the traceparent header, if any) and tags the
// span with HTTP semantic-convention attributes; finish records the status.
import "std/tracing.xi"
import "std/tracing/propagation.xi"
import "std/web.xi"
import "std/convert.xi"

interface WebTracer {
    producer begin(req: HttpRequest, name: String) -> Span
    consumer finish(span: Span, statusCode: Integer)
}

class DefaultWebTracer implements WebTracer {
    deps { tracer: Tracer as singleton, prop: Propagator }

    producer begin(req: HttpRequest, name: String) -> Span {
        let span = spanFor(req.header("traceparent"), name)
        tracer.setAttribute(span, "http.request.method", req.method)
        tracer.setAttribute(span, "url.path", req.path)
        return span
    }

    // Continue the caller's trace if the header carries one, else start a root.
    producer spanFor(traceparent: String, name: String) -> Span {
        if let parent = prop.extract(traceparent) {
            return tracer.startChild(parent, name, SpanServer)
        }
        return tracer.start(name, SpanServer)
    }

    consumer finish(span: Span, statusCode: Integer) {
        tracer.setAttribute(span, "http.response.status_code", int_to_string(statusCode))
        if statusCode >= 500 {
            tracer.setStatus(span, StatusError, "server error")
        } else {
            tracer.setStatus(span, StatusOk, "")
        }
        tracer.end(span)
    }
}
