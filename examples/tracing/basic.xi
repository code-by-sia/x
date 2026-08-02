// A first trace: a root span with a nested child, attributes, an event, and a
// status. Run it and each finished span prints as one Json line.
//
//   xi examples/tracing/basic.xi
//
// The child is parented to the root automatically because the tracer threads a
// current-span stack; nothing is passed by hand.
import "std/tracing.xi"
import "std/log.xi"
import "std/convert.xi"

async entry (tracer: Tracer as singleton, logger: Logger) main(args: String[]) -> Integer {
    tracer.enable()

    let root = tracer.start("checkout", SpanServer)
    tracer.setAttribute(root, "user.id", "42")

    let db = tracer.start("db.query", SpanClient)          // child of "checkout"
    tracer.setAttribute(db, "db.system", "sqlite")
    tracer.addEvent(db, "row.fetched")
    tracer.setStatus(db, StatusOk, "")
    tracer.end(db)

    tracer.addEvent(root, "payment.authorized")
    tracer.setStatus(root, StatusOk, "")
    tracer.end(root)

    tracer.flush()
    logger.info("finished spans: " + int_to_string(tracer.spanCount()))
    return 0
}

module App {
    id = "tracing_basic"
}
