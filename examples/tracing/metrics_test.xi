// The metric instruments: counter, up-down counter, gauge, histogram, and that
// the snapshot reflects them.
import "std/monitoring/instruments.xi"
import "std/json.xi"

test "counter, up-down, gauge, and histogram aggregate" (meter: Meter as singleton) {
    meter.counterAdd("http.requests", 1)
    meter.counterAdd("http.requests", 4)
    assertEq(meter.counterValue("http.requests"), 5)

    meter.upDownAdd("queue.depth", 3)
    meter.upDownAdd("queue.depth", 0 - 1)
    assertEq(meter.upDownValue("queue.depth"), 2)

    meter.gaugeSet("temperature", 20)
    meter.gaugeSet("temperature", 25)
    assertEq(meter.gaugeValue("temperature"), 25)

    meter.histogramRecord("latency", 10)
    meter.histogramRecord("latency", 30)
    meter.histogramRecord("latency", 20)
    assertEq(meter.histogramCount("latency"), 3)
    assertEq(meter.histogramSum("latency"), 60)
    assertEq(meter.histogramMin("latency"), 10)
    assertEq(meter.histogramMax("latency"), 30)
}

test "snapshot reports each instrument" (meter: Meter as singleton) {
    meter.counterAdd("c", 7)
    meter.gaugeSet("g", 9)
    meter.histogramRecord("h", 5)
    let s = meter.snapshot()
    assertEq(json.asNumber(json.get(json.get(s, "counters"), "c")), 7.0)
    assertEq(json.asNumber(json.get(json.get(s, "gauges"), "g")), 9.0)
    assertEq(json.asNumber(json.get(json.get(json.get(s, "histograms"), "h"), "count")), 1.0)
}

module App {}
