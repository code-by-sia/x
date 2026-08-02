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

// One instrument, stored in a flat list (a Map cannot yet be class state). kind:
// 0 counter, 1 up-down, 2 gauge, 3 histogram. value holds the counter/gauge
// number; count/sum/lo/hi hold the histogram aggregate.
type Instrument = { name: String, kind: Integer, value: Integer, count: Integer, sum: Integer, lo: Integer, hi: Integer }

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
    state { items: List<Instrument> = empty List<Instrument> }

    // Index of the (name, kind) instrument, or -1.
    mapper find(name: String, kind: Integer) -> Integer {
        let i = 0
        while i < this.items.len() {
            let it = this.items.get(i)
            if it.kind == kind and it.name == name { return i }
            i = i + 1
        }
        return 0 - 1
    }

    // Add to a counter-like instrument (counter or up-down), creating it if new.
    consumer accumulate(name: String, kind: Integer, n: Integer) {
        let i = find(name, kind)
        if i >= 0 {
            let it = this.items.get(i)
            this.items.set(i, Instrument { name: name, kind: kind, value: it.value + n, count: 0, sum: 0, lo: 0, hi: 0 })
        } else {
            this.items.push(Instrument { name: name, kind: kind, value: n, count: 0, sum: 0, lo: 0, hi: 0 })
        }
    }

    consumer counterAdd(name: String, n: Integer) { accumulate(name, 0, n) }
    consumer upDownAdd(name: String, n: Integer)  { accumulate(name, 1, n) }

    consumer gaugeSet(name: String, n: Integer) {
        let i = find(name, 2)
        if i >= 0 {
            this.items.set(i, Instrument { name: name, kind: 2, value: n, count: 0, sum: 0, lo: 0, hi: 0 })
        } else {
            this.items.push(Instrument { name: name, kind: 2, value: n, count: 0, sum: 0, lo: 0, hi: 0 })
        }
    }

    consumer histogramRecord(name: String, n: Integer) {
        let i = find(name, 3)
        if i >= 0 {
            let it = this.items.get(i)
            let lo = it.lo
            let hi = it.hi
            if n < lo { lo = n }
            if n > hi { hi = n }
            this.items.set(i, Instrument { name: name, kind: 3, value: 0, count: it.count + 1, sum: it.sum + n, lo: lo, hi: hi })
        } else {
            this.items.push(Instrument { name: name, kind: 3, value: 0, count: 1, sum: n, lo: n, hi: n })
        }
    }

    projector valueOf(name: String, kind: Integer) -> Integer {
        let i = find(name, kind)
        if i >= 0 { return this.items.get(i).value }
        return 0
    }
    projector counterValue(name: String) -> Integer => valueOf(name, 0)
    projector upDownValue(name: String) -> Integer   => valueOf(name, 1)
    projector gaugeValue(name: String) -> Integer    => valueOf(name, 2)

    projector histogramCount(name: String) -> Integer {
        let i = find(name, 3)
        if i >= 0 { return this.items.get(i).count }
        return 0
    }
    projector histogramSum(name: String) -> Integer {
        let i = find(name, 3)
        if i >= 0 { return this.items.get(i).sum }
        return 0
    }
    projector histogramMin(name: String) -> Integer {
        let i = find(name, 3)
        if i >= 0 { return this.items.get(i).lo }
        return 0
    }
    projector histogramMax(name: String) -> Integer {
        let i = find(name, 3)
        if i >= 0 { return this.items.get(i).hi }
        return 0
    }

    producer snapshot() -> Json {
        let counters = json.object()
        let updowns  = json.object()
        let gauges   = json.object()
        let hists    = json.object()
        let i = 0
        while i < this.items.len() {
            let it = this.items.get(i)
            if it.kind == 0 { counters = json.set(counters, it.name, json.int(it.value)) }
            else if it.kind == 1 { updowns = json.set(updowns, it.name, json.int(it.value)) }
            else if it.kind == 2 { gauges = json.set(gauges, it.name, json.int(it.value)) }
            else {
                let ho = json.object()
                ho = json.set(ho, "count", json.int(it.count))
                ho = json.set(ho, "sum", json.int(it.sum))
                ho = json.set(ho, "min", json.int(it.lo))
                ho = json.set(ho, "max", json.int(it.hi))
                hists = json.set(hists, it.name, ho)
            }
            i = i + 1
        }
        let o = json.object()
        o = json.set(o, "counters", counters)
        o = json.set(o, "upDownCounters", updowns)
        o = json.set(o, "gauges", gauges)
        o = json.set(o, "histograms", hists)
        return o
    }
}

// Surface the meter's numbers in the std/monitoring report under "metrics".
class MetricsMonitoring implements Monitoring {
    deps { meter: Meter as singleton }
    mapper    name() -> String => "metrics"
    consumer  startMonitor() { }
    producer  healthy() -> Bool => true
    producer  metrics() -> Json => meter.snapshot()
}
