// xc codegen — expressions: args, literals, lambdas, primary
// (part of the xc code generator — Program -> C99; spliced via codegen.xi)

// ── argument list ─────────────────────────────────────────────────
mapper genArgs(toks: Token[], pos: Integer, ctx: GCtx) -> GArgs {
    let p = pos + 1
    let firstRaw = toks.textAt(p)
    let out = ""
    let first = true
    while toks.kindAt(p) != 101 and toks.kindAt(p) != 0 {
        let e = genExpr(toks, p, ctx)
        p = e.pos
        if not first { out = out + ", " }
        out = out + e.code
        first = false
        if toks.kindAt(p) == 106 { p = p + 1 }
    }
    if toks.kindAt(p) == 101 { p = p + 1 }
    return GArgs { code: out, pos: p, firstRaw: firstRaw }
}

// ── type literal:  TypeName { field: expr, ... } ──────────────────
mapper genTypeLiteral(toks: Token[], pos: Integer, ctx: GCtx) -> ExprRes {
    let typeName = toks.textAt(pos)
    let p = pos + 2
    let out = "(xc_" + typeName + "_t){ "
    let first = true
    while toks.kindAt(p) != 103 and toks.kindAt(p) != 0 {
        let fname = toks.textAt(p)
        // A field name the type doesn't declare is a typo — report it in Xi terms
        // rather than emitting a C `field designator does not refer to any field`.
        if (ctx.prog).isCompoundTypeC(typeName) and not (ctx.prog).hasFieldC(typeName, fname) {
            diag_error(tokenArrGet(toks, p).line, "type '" + typeName + "' has no field '" + fname + "'")
        }
        p = p + 1
        if toks.kindAt(p) == 108 { p = p + 1 }
        let e = genExpr(toks, p, ctx)
        p = e.pos
        if not first { out = out + ", " }
        // Construction is gated: if the field's type is a refined type, run its
        // constraint check on the assigned value.
        let chk = (ctx.prog).fieldCheckFn(typeName, fname)
        let val = e.code
        if string_len(chk) > 0 { val = chk + "(" + e.code + ")" }
        out = out + "." + fname + " = " + val
        first = false
        if toks.kindAt(p) == 106 { p = p + 1 }
    }
    if toks.kindAt(p) == 103 { p = p + 1 }
    out = out + " }"
    return ExprRes { code: out, pos: p, xtyp: typeName , owned: false }
}

// Construct a sum-type value:  Variant { f: v, ... }  or a bare  Variant.
mapper genVariantLiteral(toks: Token[], pos: Integer, ctx: GCtx) -> ExprRes {
    let vname = toks.textAt(pos)
    let sum = (ctx.prog).sumOfVariant(vname)
    if toks.kindAt(pos + 1) != 102 {                      // no payload
        return ExprRes {
            code: "(xc_" + sum + "_t){ .tag = xc_" + sum + "_" + vname + " }",
            pos: pos + 1, xtyp: sum
        , owned: false }
    }
    let p = pos + 2
    let inner = ""
    let first = true
    while toks.kindAt(p) != 103 and toks.kindAt(p) != 0 {
        let fname = toks.textAt(p)
        p = p + 1
        if toks.kindAt(p) == 108 { p = p + 1 }           // :
        let e = genExpr(toks, p, ctx)
        p = e.pos
        if not first { inner = inner + ", " }
        // a self-referential (boxed) payload field: copy the value to the heap
        let val = e.code
        if (ctx.prog).variantFieldBoxed(sum, vname, fname) {
            val = "xc_box_" + sum + "(" + val + ")"
        }
        inner = inner + "." + fname + " = " + val
        first = false
        if toks.kindAt(p) == 106 { p = p + 1 }           // ,
    }
    if toks.kindAt(p) == 103 { p = p + 1 }               // }
    return ExprRes {
        code: "(xc_" + sum + "_t){ .tag = xc_" + sum + "_" + vname + ", .u." + vname + " = { " + inner + " } }",
        pos: p, xtyp: sum
    , owned: false }
}

// ── first-class closures: lambdas `(p: T, …) => expr` ─────────────────────────
// A lambda lowers to a top-level `static R xc_lam_<tag>_<pos>(void* env, params…)`
// (emitted by hoistLambdas, keyed by token position so the value site names the
// same helper) and an xc_fn_t value { fn, env }. v1: capture-free (the body sees
// only the params) with single-token param types; call via the Fn(...) xtype.
type LamParams = { cparams: String, pctypes: String, bodyStart: Integer, ctx: GCtx }

// `pos` at the lambda's '(' — is it `( … ) =>` (a lambda) rather than a grouped
// expression?
predicate isLambdaAt(toks: Token[], pos: Integer) {
    if toks.kindAt(pos) != 100 { return false }
    let n = tokenArrLen(toks)
    let rp = pos + 1
    let pd = 1
    while rp < n and pd > 0 {
        let kk = toks.kindAt(rp)
        if kk == 100 { pd = pd + 1 }
        if kk == 101 { pd = pd - 1 }
        if pd > 0 { rp = rp + 1 }
    }
    return toks.kindAt(rp + 1) == 110   // '=>' after the matching ')'
}

mapper parseLamParams(toks: Token[], pos: Integer, prog: Program) -> LamParams {
    let p = pos + 1                        // past '('
    let cparams = ""
    let pctypes = ""
    let pctx = prog.newCtx()
    let first = true
    while toks.kindAt(p) != 101 and toks.kindAt(p) != 0 {
        if toks.kindAt(p) == 106 { p = p + 1 }    // ,
        let nm = toks.textAt(p)
        p = p + 1
        if toks.kindAt(p) == 108 { p = p + 1 }    // :
        let pc = toks.typeCtypeOf(p)
        p = p + 1                                  // single-token param type
        if not first { cparams = cparams + ", "  pctypes = pctypes + "," }
        cparams = cparams + pc + " " + nm
        pctypes = pctypes + pc
        pctx = pctx.addSym(nm, pc.ctypeToXName())
        first = false
    }
    let bs = p
    if toks.kindAt(bs) == 101 { bs = bs + 1 }      // ')'
    if toks.kindAt(bs) == 110 { bs = bs + 1 }      // '=>'
    return LamParams { cparams: cparams, pctypes: pctypes, bodyStart: bs, ctx: pctx }
}

mapper genLambda(toks: Token[], pos: Integer, ctx: GCtx) -> ExprRes {
    let lp = parseLamParams(toks, pos, ctx.prog)
    let body = genExpr(toks, lp.bodyStart, lp.ctx)
    let retC = body.xtyp.xnameToCtype()
    let id = "xc_lam_" + ctx.fnTag + "_" + int_to_string(pos)
    let fnX = "Fn(" + lp.pctypes + ")(" + retC + ")"
    return ExprRes { code: "(xc_fn_t){ (void*)" + id + ", (void*)0 }", pos: body.pos, xtyp: fnX , owned: false }
}

// Emit a top-level C function for every lambda in `toks` (mirrors hoistParallel).
mapper hoistLambdas(prog: Program, toks: Token[], tag: String) -> String {
    let out = ""
    let n = tokenArrLen(toks)
    let i = 0
    while i < n {
        if isLambdaAt(toks, i) {
            let lp = parseLamParams(toks, i, prog)
            let body = genExpr(toks, lp.bodyStart, lp.ctx)
            let retC = body.xtyp.xnameToCtype()
            let id = "xc_lam_" + tag + "_" + int_to_string(i)
            let sig = "void* __env"
            if string_len(lp.cparams) > 0 { sig = sig + ", " + lp.cparams }
            out = out + "static " + retC + " " + id + "(" + sig + ") {\n"
                      + "    (void)__env;\n    return (" + body.code + ");\n}\n"
        }
        i = i + 1
    }
    return out
}

// ── primary ───────────────────────────────────────────────────────
// Reverse of ctypeSuffix (parser/type_parser.xi): a container-name suffix back to
// its C base type, so `empty <collection-alias>` can rebuild the constructor.
mapper suffixToCtype(suf: String) -> String {
    if suf == "number" { return "xc_number_t" }
    if suf == "integer" { return "xc_integer_t" }
    if suf == "bool" { return "xc_bool_t" }
    if suf == "string" { return "xc_string_t" }
    if suf == "char" { return "xc_char_t" }
    if suf == "size" { return "xc_size_t" }
    if suf == "timestamp" { return "xc_timestamp_t" }
    return "xc_" + suf + "_t"
}

// Length of the (single-word) map-key suffix at the front of `mid`, or -1.
mapper mapKeySuffixLen(mid: String) -> Integer {
    if mid.startsWith2("string_") { return 6 }
    if mid.startsWith2("integer_") { return 7 }
    if mid.startsWith2("number_") { return 6 }
    if mid.startsWith2("bool_") { return 4 }
    if mid.startsWith2("char_") { return 4 }
    if mid.startsWith2("size_") { return 4 }
    if mid.startsWith2("timestamp_") { return 9 }
    return 0 - 1
}

// The runtime constructor for a collection base ctype (xc_Map_*/xc_List_*/…), or
// "" when `base` is not a collection. Mirrors the `empty Map<...>` / `empty
// List<...>` codegen so an alias of a collection builds a real value rather than
// a zeroed struct that crashes on first use.
mapper collectionCtor(base: String) -> String {
    if base.startsWith2("xc_Map_") {
        let mid = string_slice(base, 7, string_len(base) - 2)
        let klen = mapKeySuffixLen(mid)
        if klen < 0 { return "" }
        let kc = suffixToCtype(string_slice(mid, 0, klen))
        let vc = suffixToCtype(string_slice(mid, klen + 1, string_len(mid)))
        return "xstd_map_new(sizeof(" + kc + "), sizeof(" + vc + "), " + kc.strFlagFor() + ")"
    }
    if base.startsWith2("xc_List_") {
        let ec = suffixToCtype(string_slice(base, 8, string_len(base) - 2))
        return "xstd_list_new(sizeof(" + ec + "))"
    }
    if base.startsWith2("xc_Set_") {
        let ec = suffixToCtype(string_slice(base, 7, string_len(base) - 2))
        return "xstd_set_new(sizeof(" + ec + "), " + ec.strFlagFor() + ")"
    }
    if base.startsWith2("xc_Stack_") {
        let ec = suffixToCtype(string_slice(base, 9, string_len(base) - 2))
        return "xstd_stack_new(sizeof(" + ec + "))"
    }
    if base.startsWith2("xc_Queue_") {
        let ec = suffixToCtype(string_slice(base, 9, string_len(base) - 2))
        return "xstd_queue_new(sizeof(" + ec + "))"
    }
    if base.startsWith2("xc_SortedQueue_") {
        let ec = suffixToCtype(string_slice(base, 15, string_len(base) - 2))
        return "xstd_pqueue_new(sizeof(" + ec + "), " + ec.pqCmpKind() + ")"
    }
    return ""
}

mapper genPrimary(toks: Token[], pos: Integer, ctx: GCtx) -> ExprRes {
    let k = toks.kindAt(pos)
    let txt = toks.textAt(pos)
    // `empty T` — the zero value of T (struct all-zero, array empty, ...).
    // Contextual: only when `empty` starts a primary AND is followed by a type
    // (so `bytes.empty()` and any var/field named `empty` still work).
    if k == 1 and txt == "empty" and toks.textAt(pos + 1) == "List" and toks.kindAt(pos + 2) == 114 {
        // `empty List<T>` — a fresh, empty list
        let etk = toks.kindAt(pos + 3)
        let elemCtype = etk.primCtypeK()
        if string_len(elemCtype) == 0 { elemCtype = "xc_" + toks.textAt(pos + 3) + "_t" }
        let endp = pos + 4
        if toks.kindAt(endp) == 115 { endp = endp + 1 }   // `>`
        return ExprRes {
            code: "xstd_list_new(sizeof(" + elemCtype + "))",
            pos: endp, xtyp: "List_" + ctypeSuffix(elemCtype)
        , owned: false }
    }
    if k == 1 and txt == "empty" and toks.textAt(pos + 1) == "Set" and toks.kindAt(pos + 2) == 114 {
        // `empty Set<T>` — a fresh, empty set
        let etk = toks.kindAt(pos + 3)
        let elemCtype = etk.primCtypeK()
        if string_len(elemCtype) == 0 { elemCtype = "xc_" + toks.textAt(pos + 3) + "_t" }
        let endp = pos + 4
        if toks.kindAt(endp) == 115 { endp = endp + 1 }   // `>`
        return ExprRes {
            code: "xstd_set_new(sizeof(" + elemCtype + "), " + elemCtype.strFlagFor() + ")",
            pos: endp, xtyp: "Set_" + ctypeSuffix(elemCtype)
        , owned: false }
    }
    if k == 1 and txt == "empty" and toks.textAt(pos + 1) == "Map" and toks.kindAt(pos + 2) == 114 {
        // `empty Map<K, V>` — a fresh, empty map (K is a primitive or String)
        let ktk = toks.kindAt(pos + 3)
        let kc = ktk.primCtypeK()
        if string_len(kc) == 0 { kc = "xc_" + toks.textAt(pos + 3) + "_t" }
        let q = pos + 4
        if toks.kindAt(q) == 106 { q = q + 1 }            // `,`
        let vtk = toks.kindAt(q)
        let vc = vtk.primCtypeK()
        if string_len(vc) == 0 { vc = "xc_" + toks.textAt(q) + "_t" }
        let endp = q + 1
        if toks.kindAt(endp) == 115 { endp = endp + 1 }   // `>`
        return ExprRes {
            code: "xstd_map_new(sizeof(" + kc + "), sizeof(" + vc + "), " + kc.strFlagFor() + ")",
            pos: endp, xtyp: "Map_" + ctypeSuffix(kc) + "_" + ctypeSuffix(vc)
        , owned: false }
    }
    if k == 1 and txt == "empty" and toks.textAt(pos + 1) == "Vec" and toks.kindAt(pos + 2) == 114 {
        // `empty Vec<T>` — a fresh, empty vector (a List under the hood)
        let etk = toks.kindAt(pos + 3)
        let elemCtype = etk.primCtypeK()
        if string_len(elemCtype) == 0 { elemCtype = "xc_" + toks.textAt(pos + 3) + "_t" }
        let endp = pos + 4
        if toks.kindAt(endp) == 115 { endp = endp + 1 }   // `>`
        return ExprRes {
            code: "xstd_list_new(sizeof(" + elemCtype + "))",
            pos: endp, xtyp: "List_" + ctypeSuffix(elemCtype)
        , owned: false }
    }
    if k == 1 and txt == "empty" and toks.textAt(pos + 1) == "Stack" and toks.kindAt(pos + 2) == 114 {
        let etk = toks.kindAt(pos + 3)
        let elemCtype = etk.primCtypeK()
        if string_len(elemCtype) == 0 { elemCtype = "xc_" + toks.textAt(pos + 3) + "_t" }
        let endp = pos + 4
        if toks.kindAt(endp) == 115 { endp = endp + 1 }
        return ExprRes {
            code: "xstd_stack_new(sizeof(" + elemCtype + "))",
            pos: endp, xtyp: "Stack_" + ctypeSuffix(elemCtype)
        , owned: false }
    }
    if k == 1 and txt == "empty" and toks.textAt(pos + 1) == "Queue" and toks.kindAt(pos + 2) == 114 {
        let etk = toks.kindAt(pos + 3)
        let elemCtype = etk.primCtypeK()
        if string_len(elemCtype) == 0 { elemCtype = "xc_" + toks.textAt(pos + 3) + "_t" }
        let endp = pos + 4
        if toks.kindAt(endp) == 115 { endp = endp + 1 }
        return ExprRes {
            code: "xstd_queue_new(sizeof(" + elemCtype + "))",
            pos: endp, xtyp: "Queue_" + ctypeSuffix(elemCtype)
        , owned: false }
    }
    if k == 1 and txt == "empty" and toks.textAt(pos + 1) == "SortedQueue" and toks.kindAt(pos + 2) == 114 {
        let etk = toks.kindAt(pos + 3)
        let elemCtype = etk.primCtypeK()
        if string_len(elemCtype) == 0 { elemCtype = "xc_" + toks.textAt(pos + 3) + "_t" }
        let endp = pos + 4
        if toks.kindAt(endp) == 115 { endp = endp + 1 }
        return ExprRes {
            code: "xstd_pqueue_new(sizeof(" + elemCtype + "), " + elemCtype.pqCmpKind() + ")",
            pos: endp, xtyp: "SortedQueue_" + ctypeSuffix(elemCtype)
        , owned: false }
    }
    // ── builders: listOf(a, b, ...) / setOf(a, b, ...) / mapOf(k to v, ...) ──
    // Element/key types are inferred from the first argument (homogeneous).
    // readConfig<T>("file.{json,yaml,xml}") — read + decode a config file into T
    if k == 1 and txt == "readConfig" and toks.kindAt(pos + 1) == 114 {
        let tname = toks.textAt(pos + 2)         // T
        let q = pos + 3
        if toks.kindAt(q) == 115 { q = q + 1 }   // >
        if toks.kindAt(q) == 100 { q = q + 1 }   // (
        let pe = genExpr(toks, q, ctx)           // the path expression
        q = pe.pos
        if toks.kindAt(q) == 101 { q = q + 1 }   // )
        return ExprRes {
            code: "xc_fromjson_" + tname + "(xstd_config_parse(" + pe.code + "))",
            pos: q, xtyp: tname
        , owned: false }
    }
    if k == 1 and txt == "generateSequence" and toks.kindAt(pos + 1) == 100 {
        // generateSequence(seed) { [p =>] next } .<lazy ops> .<terminal> — a fused
        // lazy recurrence source: the value starts at `seed` and advances through
        // the inlined generator each step. Must be bounded by a take/takeWhile/
        // first in the chain, or it loops forever.
        let se = genExpr(toks, pos + 2, ctx)
        let seedX = se.xtyp
        let aq = se.pos
        if toks.kindAt(aq) == 101 { aq = aq + 1 }                 // ')'
        let bo = aq                                               // '{'
        let close = toks.matchBrace(bo)
        let arrow = lambdaArrow(toks, bo + 1, close)
        let gp = "it"
        let bstart = bo + 1
        if arrow >= 0 { gp = toks.textAt(bo + 1)  bstart = arrow + 1 }
        let gbody = genExpr(toks, bstart, ctx.addSym(gp, seedX))
        let dotp = close + 1                                      // first '.' of the chain
        return genSequenceChain(toks, dotp - 2, "", seedX, ctx, true, se.code, gbody.code, gp)
    }
    if k == 1 and txt == "listOf" and toks.kindAt(pos + 1) == 100 and toks.kindAt(pos + 2) != 101 {
        let first = genExpr(toks, pos + 2, ctx)
        let ec = first.xtyp.xnameToCtype()
        let body = "xc_List_t _t = xstd_list_new(sizeof(" + ec + ")); "
                 + "xstd_list_push(_t, (" + ec + "[]){ " + first.code + " }); "
        let p = first.pos
        while toks.kindAt(p) == 106 {
            let a = genExpr(toks, p + 1, ctx)
            body = body + "xstd_list_push(_t, (" + ec + "[]){ " + a.code + " }); "
            p = a.pos
        }
        if toks.kindAt(p) == 101 { p = p + 1 }
        return ExprRes { code: "({ " + body + "_t; })", pos: p, xtyp: "List_" + first.xtyp.arrSuffixOf() , owned: false }
    }
    if k == 1 and txt == "vecOf" and toks.kindAt(pos + 1) == 100 and toks.kindAt(pos + 2) != 101 {
        let first = genExpr(toks, pos + 2, ctx)
        let ec = first.xtyp.xnameToCtype()
        let body = "xc_List_t _t = xstd_list_new(sizeof(" + ec + ")); "
                 + "xstd_list_push(_t, (" + ec + "[]){ " + first.code + " }); "
        let p = first.pos
        while toks.kindAt(p) == 106 {
            let a = genExpr(toks, p + 1, ctx)
            body = body + "xstd_list_push(_t, (" + ec + "[]){ " + a.code + " }); "
            p = a.pos
        }
        if toks.kindAt(p) == 101 { p = p + 1 }
        return ExprRes { code: "({ " + body + "_t; })", pos: p, xtyp: "List_" + first.xtyp.arrSuffixOf() , owned: false }
    }
    if k == 1 and txt == "stackOf" and toks.kindAt(pos + 1) == 100 and toks.kindAt(pos + 2) != 101 {
        let first = genExpr(toks, pos + 2, ctx)
        let ec = first.xtyp.xnameToCtype()
        let body = "xc_Stack_t _t = xstd_stack_new(sizeof(" + ec + ")); "
                 + "xstd_stack_push(_t, (" + ec + "[]){ " + first.code + " }); "
        let p = first.pos
        while toks.kindAt(p) == 106 {
            let a = genExpr(toks, p + 1, ctx)
            body = body + "xstd_stack_push(_t, (" + ec + "[]){ " + a.code + " }); "
            p = a.pos
        }
        if toks.kindAt(p) == 101 { p = p + 1 }
        return ExprRes { code: "({ " + body + "_t; })", pos: p, xtyp: "Stack_" + first.xtyp.arrSuffixOf() , owned: false }
    }
    if k == 1 and txt == "queueOf" and toks.kindAt(pos + 1) == 100 and toks.kindAt(pos + 2) != 101 {
        let first = genExpr(toks, pos + 2, ctx)
        let ec = first.xtyp.xnameToCtype()
        let body = "xc_Queue_t _t = xstd_queue_new(sizeof(" + ec + ")); "
                 + "xstd_queue_enqueue(_t, (" + ec + "[]){ " + first.code + " }); "
        let p = first.pos
        while toks.kindAt(p) == 106 {
            let a = genExpr(toks, p + 1, ctx)
            body = body + "xstd_queue_enqueue(_t, (" + ec + "[]){ " + a.code + " }); "
            p = a.pos
        }
        if toks.kindAt(p) == 101 { p = p + 1 }
        return ExprRes { code: "({ " + body + "_t; })", pos: p, xtyp: "Queue_" + first.xtyp.arrSuffixOf() , owned: false }
    }
    if k == 1 and txt == "sortedQueueOf" and toks.kindAt(pos + 1) == 100 and toks.kindAt(pos + 2) != 101 {
        let first = genExpr(toks, pos + 2, ctx)
        let ec = first.xtyp.xnameToCtype()
        let body = "xc_SortedQueue_t _t = xstd_pqueue_new(sizeof(" + ec + "), " + ec.pqCmpKind() + "); "
                 + "xstd_pqueue_push(_t, (" + ec + "[]){ " + first.code + " }); "
        let p = first.pos
        while toks.kindAt(p) == 106 {
            let a = genExpr(toks, p + 1, ctx)
            body = body + "xstd_pqueue_push(_t, (" + ec + "[]){ " + a.code + " }); "
            p = a.pos
        }
        if toks.kindAt(p) == 101 { p = p + 1 }
        return ExprRes { code: "({ " + body + "_t; })", pos: p, xtyp: "SortedQueue_" + first.xtyp.arrSuffixOf() , owned: false }
    }
    if k == 1 and txt == "setOf" and toks.kindAt(pos + 1) == 100 and toks.kindAt(pos + 2) != 101 {
        let first = genExpr(toks, pos + 2, ctx)
        let ec = first.xtyp.xnameToCtype()
        let body = "xc_Set_t _s = xstd_set_new(sizeof(" + ec + "), " + ec.strFlagFor() + "); "
                 + "xstd_set_add(_s, (" + ec + "[]){ " + first.code + " }); "
        let p = first.pos
        while toks.kindAt(p) == 106 {
            let a = genExpr(toks, p + 1, ctx)
            body = body + "xstd_set_add(_s, (" + ec + "[]){ " + a.code + " }); "
            p = a.pos
        }
        if toks.kindAt(p) == 101 { p = p + 1 }
        return ExprRes { code: "({ " + body + "_s; })", pos: p, xtyp: "Set_" + first.xtyp.arrSuffixOf() , owned: false }
    }
    if k == 1 and txt == "mapOf" and toks.kindAt(pos + 1) == 100 and toks.kindAt(pos + 2) != 101 {
        let k1 = genAnd(toks, pos + 2, ctx)   // genAnd, not genExpr, so the `to` stays for us
        let kc = k1.xtyp.xnameToCtype()
        let q = k1.pos
        if toks.kindAt(q) == 1 and toks.textAt(q) == "to" { q = q + 1 }   // `k to v`
        let v1 = genExpr(toks, q, ctx)
        let vc = v1.xtyp.xnameToCtype()
        let body = "xc_Map_t _m = xstd_map_new(sizeof(" + kc + "), sizeof(" + vc + "), " + kc.strFlagFor() + "); "
                 + "xstd_map_put(_m, (" + kc + "[]){ " + k1.code + " }, (" + vc + "[]){ " + v1.code + " }); "
        let p = v1.pos
        while toks.kindAt(p) == 106 {
            let kk = genAnd(toks, p + 1, ctx)   // genAnd so `to` stays for us
            let qq = kk.pos
            if toks.kindAt(qq) == 1 and toks.textAt(qq) == "to" { qq = qq + 1 }
            let vv = genExpr(toks, qq, ctx)
            body = body + "xstd_map_put(_m, (" + kc + "[]){ " + kk.code + " }, (" + vc + "[]){ " + vv.code + " }); "
            p = vv.pos
        }
        if toks.kindAt(p) == 101 { p = p + 1 }
        return ExprRes { code: "({ " + body + "_m; })", pos: p, xtyp: "Map_" + k1.xtyp.arrSuffixOf() + "_" + v1.xtyp.arrSuffixOf() , owned: false }
    }
    if k == 1 and txt == "empty" {
        let nk = toks.kindAt(pos + 1)
        if nk == 1 or string_len(nk.primCtypeK()) > 0 {
            let ctype = toks.typeCtypeOf(pos + 1)
            let tp = pos + 2                     // after the base type token
            let cont = true
            while cont {
                let pk = toks.kindAt(tp)
                if pk == 127 { tp = tp + 1 }                                   // ?
                else { if pk == 126 { tp = tp + 1 }                            // !
                else { if pk == 104 and toks.kindAt(tp + 1) == 105 { tp = tp + 2 }  // []
                else { cont = false } } }
            }
            // A bare `empty <alias>` where the alias targets a collection: build
            // the real constructor, not a zeroed struct that crashes on first use.
            if nk == 1 and tp == pos + 2 {
                let ts = findTypeSpec(ctx.prog, toks.textAt(pos + 1))
                if string_len(ts.name) > 0 and not ts.isCompound and not ts.isSum {
                    let ctor = collectionCtor(ts.baseCtype)
                    if string_len(ctor) > 0 {
                        return ExprRes { code: ctor, pos: tp, xtyp: string_slice(ts.baseCtype, 3, string_len(ts.baseCtype) - 2) , owned: false }
                    }
                }
            }
            return ExprRes { code: "(" + ctype + "){0}", pos: tp, xtyp: toks.textAt(pos + 1) , owned: false }
        }
    }
    if k == 2 { return ExprRes { code: txt + "LL", pos: pos + 1, xtyp: "Integer" , owned: false } }
    if k == 3 { return ExprRes { code: txt, pos: pos + 1, xtyp: "Number" , owned: false } }
    if k == 4 { return ExprRes { code: "xc_string_from_cstr(\"" + txt + "\")", pos: pos + 1, xtyp: "String" , owned: false } }
    if k == 236 { return ExprRes { code: "true", pos: pos + 1, xtyp: "Bool" , owned: false } }
    if k == 237 { return ExprRes { code: "false", pos: pos + 1, xtyp: "Bool" , owned: false } }
    if k == 254 { return ExprRes { code: "{0}", pos: pos + 1, xtyp: "" , owned: false } }
    if k == 253 { return ExprRes { code: "input", pos: pos + 1, xtyp: "" , owned: false } }
    if k == 243 { return ExprRes { code: "value", pos: pos + 1, xtyp: ctx.lookupVar("value") , owned: false } }
    if k == 238 {
        // `this` — the receiver. In an extension method it's a seeded `this` param
        // (carrying the receiver's xtype); in a class method it's the instance,
        // which lowers to the C var `self`.
        let tt = ctx.lookupVar("this")
        if string_len(tt) > 0 { return ExprRes { code: "this", pos: pos + 1, xtyp: tt , owned: false } }
        return ExprRes { code: "self", pos: pos + 1, xtyp: "self" , owned: false }
    }
    if k == 100 {
        if isLambdaAt(toks, pos) { return genLambda(toks, pos, ctx) }
        let inner = genExpr(toks, pos + 1, ctx)
        let p2 = inner.pos
        if toks.kindAt(p2) == 101 { p2 = p2 + 1 }
        return ExprRes { code: "(" + inner.code + ")", pos: p2, xtyp: inner.xtyp , owned: false }
    }
    if k == 104 {
        // Array literal [ e1, e2, ... ]
        let p = pos + 1
        let out = ""
        let count = 0
        let firstX = ""
        let first = true
        while toks.kindAt(p) != 105 and toks.kindAt(p) != 0 {
            let e = genExpr(toks, p, ctx)
            p = e.pos
            if first { firstX = e.xtyp }
            if not first { out = out + ", " }
            out = out + e.code
            count = count + 1
            first = false
            if toks.kindAt(p) == 106 { p = p + 1 }
        }
        if toks.kindAt(p) == 105 { p = p + 1 }
        if count == 0 {
            return ExprRes { code: "{0}", pos: p, xtyp: "emptyarr" , owned: false }
        }
        let arrType = "xc_arr_" + firstX.arrSuffixOf() + "_t"
        let elemCtype = firstX.xnameToCtype()
        let code = "(" + arrType + "){ .data = (" + elemCtype + "[]){ " + out
                 + " }, .len = " + int_to_string(count) + ", .cap = " + int_to_string(count) + " }"
        return ExprRes { code: code, pos: p, xtyp: firstX.arrSuffixOf() + "[]" , owned: false }
    }
    if k == 1 {
        if isParallelAt(toks, pos) {
            // parallel [(cap,...)] { body } -> spawn a thread, yield a Thread
            let pp = parseParallelAt(toks, pos)
            let id = ctx.fnTag + "_" + int_to_string(pos)
            let args = ""
            let nc = stringArrLen(pp.caps)
            let c = 0
            while c < nc {
                if c > 0 { args = args + ", " }
                args = args + stringArrGet(pp.caps, c)
                c = c + 1
            }
            return ExprRes { code: "xc_parspawn_" + id + "(" + args + ")", pos: pp.endPos, xtyp: "Thread" , owned: false }
        }
        if toks.isRunWithDelayAt(pos) {
            // runWithDelay(ms) { body } -> run body after `ms`, yield Future<Integer>
            let dp = toks.parseDelayAt(pos)
            let id = ctx.fnTag + "_" + int_to_string(pos)
            let ms = genExpr(toks, dp.msStart, ctx)
            let caps = toks.capturesIn(dp.bodyStart, dp.bodyEnd, ctx.capNames, ctx.capTypes)
            let args = ms.code
            let nc = stringArrLen(caps.names)
            let c = 0
            while c < nc { args = args + ", " + stringArrGet(caps.names, c)  c = c + 1 }
            return ExprRes { code: "xc_delayspawn_" + id + "(" + args + ")", pos: dp.endPos, xtyp: "Future_integer" , owned: false }
        }
        if txt == "thread" {
            // built-in thread facility: thread.channel() / thread.stopped()
            return ExprRes { code: "", pos: pos + 1, xtyp: "thread:" , owned: false }
        }
        if txt == "query" and toks.kindAt(pos + 1) == 107 and toks.textAt(pos + 2) == "from" and string_len(ctx.lookupVar("query")) == 0 {
            // xi-query root:  query.from<T>("source") — seeds a reified plan
            return genQueryFrom(toks, pos, ctx)
        }
        if (ctx.prog).isVariantNameC(txt) {
            // sum-type constructor: Variant { ... } or a bare nullary Variant
            return genVariantLiteral(toks, pos, ctx)
        }
        if toks.kindAt(pos + 1) == 102 and (ctx.prog).isTypeNameC(txt) {
            return genTypeLiteral(toks, pos, ctx)
        }
        if ctx.isDepNameC(txt) {
            return ExprRes { code: "self->" + txt, pos: pos + 1, xtyp: ctx.depTypeOf(txt) , owned: false }
        }
        if txt == "system" {
            return ExprRes { code: "system", pos: pos + 1, xtyp: "ns:system" , owned: false }
        }
        if txt == "Events" {
            // built-in event facility: Events.dispatch/encode/decode/topic/type/run
            return ExprRes { code: "", pos: pos + 1, xtyp: "events:" , owned: false }
        }
        if (ctx.prog).isModuleNameC(txt) {
            return ExprRes { code: txt, pos: pos + 1, xtyp: "module:" + txt , owned: false }
        }
        if (ctx.prog).isAtomNameC(txt) {
            return ExprRes { code: "__atom_" + txt, pos: pos + 1, xtyp: "atom:" + txt , owned: false }
        }
        if (ctx.prog).isMachineTypeC(txt) {
            return ExprRes { code: txt, pos: pos + 1, xtyp: "machinetype:" + txt , owned: false }
        }
        // `ns.foo(...)` where `ns` is a std namespace that isn't imported: no
        // `ns__foo` function exists, `ns` isn't a local — report the missing import
        // in Xi terms rather than leaking a C `undeclared identifier 'ns'` error.
        if toks.kindAt(pos + 1) == 107 and string_len(ctx.lookupVar(txt)) == 0 {
            let nsImp = txt.stdNamespaceImport()
            if string_len(nsImp) > 0 and not (ctx.prog).isFuncNameC(txt + "__" + toks.textAt(pos + 2)) {
                diag_error(tokenArrGet(toks, pos).line, txt + "." + toks.textAt(pos + 2) + "(...) — the '" + txt + "' namespace isn't imported; add:  import \"" + nsImp + "\"")
            }
        }
        // Constructor `Name { ... }` for a name that resolves to nothing: neither a
        // sum-type variant (488) nor a type/event/class (492) matched, and it's not
        // a local. A capitalized name before `{` in expression position is only ever
        // a constructor, so report the unknown type in Xi terms instead of letting
        // the bare name leak out as a cryptic C `undeclared identifier` cascade.
        if toks.kindAt(pos + 1) == 102 and txt.startsUpper() and string_len(ctx.lookupVar(txt)) == 0 {
            diag_error(tokenArrGet(toks, pos).line, "unknown type '" + txt + "' — no type, event, or sum-type variant with that name is declared or imported")
        }
        return ExprRes { code: txt, pos: pos + 1, xtyp: ctx.lookupVar(txt) , owned: false }
    }
    return ExprRes { code: txt, pos: pos + 1, xtyp: "" , owned: false }
}

// ── functional API on List<T> (lambdas inlined as generated loops) ─────────
// Method names that take a `{ lambda }` (and maybe a leading `(arg)`).
predicate isListFunc(fld: String) {
    let names = [
        "map", "filter", "filterNot", "partition", "zip", "unzip", "forEach",
        "fold", "reduce", "count", "any", "all", "none", "sumOf", "joinToString",
        "mapIndexed", "takeWhile", "dropWhile", "flatMap", "take", "drop",
        "reversed", "distinct", "first", "last", "toSet", "find", "firstOrNone",
        "lastOrNone", "maxByOrNone", "minByOrNone", "average", "sorted",
        "sortedDescending", "sortedBy", "sortedByDescending", "groupBy",
        "associateBy", "associateWith", "chunked", "windowed", "sum", "min",
        "max", "minOrNone", "maxOrNone", "contains", "indexOf", "toList",
        "withIndex", "flatten", "single", "singleOrNone", "onEach", "maxOf",
        "minOf", "scan", "runningFold"
    ]
    return names.includes(fld)
}
// index of the top-level `=>` (kind 110) within (start, close), or -1.
mapper lambdaArrow(toks: Token[], start: Integer, close: Integer) -> Integer {
    let depth = 0
    let i = start
    while i < close {
        let k = toks.kindAt(i)
        if k == 102 or k == 100 or k == 104 { depth = depth + 1 }
        if k == 103 or k == 101 or k == 105 { depth = depth - 1 }
        if depth == 0 and k == 110 { return i }
        i = i + 1
    }
    return 0 - 1
}

