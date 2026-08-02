// std/tracing/ids — the default id generator and clock. Random ids are drawn
// from crypto and formatted as lowercase hex, exactly the OpenTelemetry shape.
import "std/tracing/ports.xi"
import "std/crypto.xi"
import "std/time.xi"

// 128-bit trace ids and 64-bit span ids as hex (32 and 16 characters).
class RandomIdGenerator implements IdGenerator {
    deps {}
    producer newTraceId() -> String => crypto.randomHex(16)
    producer newSpanId() -> String  => crypto.randomHex(8)
}

// Wall-clock nanoseconds since the Unix epoch, for span start and end.
class SystemTraceClock implements TraceClock {
    deps {}
    producer nowNanos() -> Integer => time.nowNanos()
}
