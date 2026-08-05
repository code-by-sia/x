// Regression: an alias of a collection (type M = Map<K,V>, etc.) now both
// type-checks (its underlying monomorphized typedef is emitted after it is
// defined) and constructs via `empty M` (a real constructor, not a zeroed struct
// that used to crash at first use).
type User    = { name: String, age: Integer }
type UserMap = Map<String, User>       // compound value
type IntMap  = Map<String, Integer>    // primitive value
type Names   = List<String>
type Tags    = Set<String>

test "empty of a Map alias with a compound value works" {
    let m = empty UserMap
    m.put("ada", User { name: "Ada", age: 36 })
    m.put("bo", User { name: "Bo", age: 20 })
    assertEq(m.len(), 2)
    assertEq(m.get("ada").age, 36)
}

test "empty of a Map alias with a primitive value works" {
    let m = empty IntMap
    m.put("a", 5)
    m.put("a", 7)                       // overwrite
    assertEq(m.get("a"), 7)
    assertEq(m.getOr("z", -1), 0 - 1)
}

test "empty of a List alias works" {
    let ns = empty Names
    ns.push("x")
    ns.push("y")
    assertEq(ns.len(), 2)
    assertEq(ns.get(0), "x")
}

test "empty of a Set alias dedups" {
    let t = empty Tags
    t.add("a")
    t.add("a")
    t.add("b")
    assertEq(t.len(), 2)
}

module App {}
