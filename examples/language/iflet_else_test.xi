// Regression: `if let ... { } else { }` must run exactly one branch. A codegen
// bug emitted `else;` followed by a separate unconditional block, so the else
// body ran even when the optional was present (compound-typed optionals hit it).
type Box = { v: Integer }

mapper boxIf(present: Bool) -> Box? {
    if present { return Box { v: 42 } }
    return none
}

mapper firstEven() -> Integer? { return 2 }

test "if let runs only the then-branch when the value is present (compound)" {
    let hit = 0
    if let b = boxIf(true) { hit = b.v } else { hit = 0 - 1 }
    assertEq(hit, 42)
}

test "if let runs only the else-branch when the value is absent (compound)" {
    let hit = 0
    if let b = boxIf(false) { hit = b.v } else { hit = 0 - 1 }
    assertEq(hit, 0 - 1)
}

test "if let with else works for a primitive optional too" {
    let r = 0
    if let n = firstEven() { r = n } else { r = 0 - 1 }
    assertEq(r, 2)
}

module App {}
