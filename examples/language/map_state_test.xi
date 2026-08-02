// Regression: a Map<K, V> can be a class `state` field. The state-init parser
// now tracks <> depth, so the comma inside `= empty Map<String, Integer>` no
// longer ends the field early (which used to leave the map a null struct that
// crashed at first use).
interface Tally {
    consumer  add(k: String)
    projector count(k: String) -> Integer
    projector distinct() -> Integer
}

class MapTally implements Tally {
    deps {}
    state { counts: Map<String, Integer> = empty Map<String, Integer>, seen: Integer = 0 }
    consumer  add(k: String) { this.counts.put(k, this.counts.getOr(k, 0) + 1)  this.seen = this.seen + 1 }
    projector count(k: String) -> Integer => this.counts.getOr(k, 0)
    projector distinct() -> Integer => this.counts.len()
}

test "a Map survives as class state and accumulates" (t: Tally as singleton) {
    t.add("a")
    t.add("a")
    t.add("b")
    assertEq(t.count("a"), 2)
    assertEq(t.count("b"), 1)
    assertEq(t.count("z"), 0)      // absent key -> default via getOr
    assertEq(t.distinct(), 2)
}

module App {}
