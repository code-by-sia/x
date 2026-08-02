// std/monitoring/instruments — OpenTelemetry-style metric instruments: a Meter
// that owns named counters, up-down counters, gauges, and histograms. This is
// the metrics signal, kept under std/monitoring (its natural home). Bind the
// Meter `as singleton` so its state persists; import this file and the numbers
// also join /monitor/metrics under "metrics".
//
//     class Api { deps { meter: Meter } consumer hit() { meter.counterAdd("http.requests", 1) } }
//     entry (meter: Meter as singleton) main(args: String[]) { ... }
import "std/monitoring.xi"
import "std/json.xi"

interface Meter {
    consumer  counterAdd(name: String, n: Integer)          // monotonic total += n
    consumer  upDownAdd(name: String, n: Integer)           // may increase or decrease
    consumer  gaugeSet(name: String, n: Integer)            // last-value gauge
    consumer  histogramRecord(name: String, n: Integer)     // observe a value (count/sum/min/max)
    projector counterValue(name: String) -> Integer
    projector upDownValue(name: String) -> Integer
    projector gaugeValue(name: String) -> Integer
    projector histogramCount(name: String) -> Integer
    projector histogramSum(name: String) -> Integer
    projector histogramMin(name: String) -> Integer
    projector histogramMax(name: String) -> Integer
    producer  snapshot() -> Json
}

class DefaultMeter implements Meter {
    deps {}
    state { counters: Map<String, Integer> = empty Map<String, Integer>, updowns: Map<String, Integer> = empty Map<String, Integer>, gauges: Map<String, Integer> = empty Map<String, Integer>, hCount: Map<String, Integer> = empty Map<String, Integer>, hSum: Map<String, Integer> = empty Map<String, Integer>, hMin: Map<String, Integer> = empty Map<String, Integer>, hMax: Map<String, Integer> = empty Map<String, Integer> }

    consumer counterAdd(name: String, n: Integer) { this.counters.put(name, this.counters.getOr(name, 0) + n) }
    consumer upDownAdd(name: String, n: Integer)  { this.updowns.put(name, this.updowns.getOr(name, 0) + n) }
    consumer gaugeSet(name: String, n: Integer)   { this.gauges.put(name, n) }
    consumer histogramRecord(name: String, n: Integer) {
        this.hCount.put(name, this.hCount.getOr(name, 0) + 1)
        this.hSum.put(name, this.hSum.getOr(name, 0) + n)
        if not this.hMin.has(name) or n < this.hMin.get(name) { this.hMin.put(name, n) }
        if not this.hMax.has(name) or n > this.hMax.get(name) { this.hMax.put(name, n) }
    }

    projector counterValue(name: String) -> Integer   => this.counters.getOr(name, 0)
    projector upDownValue(name: String) -> Integer     => this.updowns.getOr(name, 0)
    projector gaugeValue(name: String) -> Integer      => this.gauges.getOr(name, 0)
    projector histogramCount(name: String) -> Integer  => this.hCount.getOr(name, 0)
    projector histogramSum(name: String) -> Integer    => this.hSum.getOr(name, 0)
    projector histogramMin(name: String) -> Integer    => this.hMin.getOr(name, 0)
    projector histogramMax(name: String) -> Integer    => this.hMax.getOr(name, 0)

    producer snapshot() -> Json {
        let o = json.object()
        o = json.set(o, "counters", mapToJson(this.counters))
        o = json.set(o, "upDownCounters", mapToJson(this.updowns))
        o = json.set(o, "gauges", mapToJson(this.gauges))
        let h = json.object()
        for k in this.hCount.keys() {
            let ho = json.object()
            ho = json.set(ho, "count", json.int(this.hCount.getOr(k, 0)))
            ho = json.set(ho, "sum", json.int(this.hSum.getOr(k, 0)))
            ho = json.set(ho, "min", json.int(this.hMin.getOr(k, 0)))
            ho = json.set(ho, "max", json.int(this.hMax.getOr(k, 0)))
            h = json.set(h, k, ho)
        }
        o = json.set(o, "histograms", h)
        return o
    }
}

producer mapToJson(m: Map<String, Integer>) -> Json {
    let o = json.object()
    for k in m.keys() { o = json.set(o, k, json.int(m.getOr(k, 0))) }
    return o
}

// Surface the meter's numbers in the std/monitoring report under "metrics".
class MetricsMonitoring implements Monitoring {
    deps { meter: Meter as singleton }
    mapper    name() -> String => "metrics"
    consumer  startMonitor() { }
    producer  healthy() -> Bool => true
    producer  metrics() -> Json => meter.snapshot()
}
