// =============================================================
// xi — the X REPL and run tool, written in X
//
// Manifest for the `xi` binary. The REPL is standalone: it shells out to the
// `xc` compiler to build sessions, so it imports only its own parts. As with
// xc.xi, each interface / class lives in its own file.
//
//   repl/runner.xi    the session loop, file runner and test runner (helpers)
//   repl/repl.xi      the Repl interface
//   repl/xi_repl.xi   the XiRepl implementation
// =============================================================

import "impl/strings.xi"
import "repl/runner.xi"
import "repl/repl.xi"
import "repl/xi_repl.xi"

// ── composition root (in the manifest, not a part file — see xc.xi) ──
module Xi {
    id           = "xi"
    name         = "Xi REPL & Runner"
    description  = "The Xi REPL and run tool: run files, start a session, install, pack."
    version      = "0.1.14"
    license      = "Apache 2.0"
    includes     = []
    excludes     = []
    dependencies = []

    bind Repl -> XiRepl as singleton

    async entry main(args: String[]) -> Integer {
        let xi = Xi.resolve(Repl)
        return xi.run(args)
    }
}
