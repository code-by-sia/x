// The ratio-sampling decision: full/none edges, stability per trace, and that a
// low-prefix trace is kept while a high-prefix one is dropped at 0.5.
import "std/tracing/sampling.xi"

test "ratio 1.0 keeps everything and 0.0 keeps nothing" {
    assert ratioDecision("ffffffffffffffffffffffffffffffff", 1.0) : "1.0 keeps all"
    assert not ratioDecision("00000000000000000000000000000000", 0.0) : "0.0 keeps none"
}

test "the decision is stable for a given trace id" {
    let t = "8000abcdef0123456789abcdef012345"
    assertEq(ratioDecision(t, 0.5), ratioDecision(t, 0.5))
    assertEq(ratioDecision(t, 0.3), ratioDecision(t, 0.3))
}

test "a low-prefix trace is kept and a high-prefix trace dropped at 0.5" {
    // first 4 hex -> fraction: 0000 -> 0.0 (< 0.5, kept); ffff -> ~1.0 (>= 0.5, dropped)
    assert ratioDecision("0000ffffffffffffffffffffffffffff", 0.5) : "low prefix kept"
    assert not ratioDecision("ffffffffffffffffffffffffffffffff", 0.5) : "high prefix dropped"
    // 4000 -> 0.25 (< 0.5 kept); c000 -> 0.75 (>= 0.5 dropped)
    assert ratioDecision("4000000000000000000000000000000a", 0.5) : "0.25 kept"
    assert not ratioDecision("c000000000000000000000000000000a", 0.5) : "0.75 dropped"
}

module App {}
