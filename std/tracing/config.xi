// std/tracing/config — typed settings so switching console -> collector, or
// changing the sample rate, is configuration rather than a recompile.
//
// The default is code-provided (a local collector, sample everything). Override
// by binding readConfig, or your own TracingConfig:
//
//     module App { bind TracingConfig -> readConfig("application.yaml") }
//
// with, in application.yaml:
//
//     tracing:
//       serviceName: shop
//       endpoint:    http://otel-collector:4318
//       sampleRatio: 0.1

type TracingSettings = {
    serviceName: String,      // Resource service.name
    endpoint:    String,      // OTLP base URL; the exporter POSTs <endpoint>/v1/traces
    sampleRatio: Number       // 0.0 .. 1.0, used by the ratio sampler
}

interface TracingConfig {
    mapper tracing() -> TracingSettings
}

class DefaultTracingConfig implements TracingConfig {
    deps {}
    mapper tracing() -> TracingSettings {
        return TracingSettings { serviceName: "xi-service", endpoint: "http://localhost:4318", sampleRatio: 1.0 }
    }
}
