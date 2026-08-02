// xc parser — declarations: func/type/iface/dep/class/entry
// (part of the parser — spliced via the xc.xi manifest)

// Parse one function/method signature + body → FuncSpec
type FuncResult = { spec: FuncSpec, ps: PState, table: DecisionTable, hasTable: Bool, outType: TypeSpec, hasOutType: Bool }

mapper parseFunc(ps: PState, isAsync: Bool, isCreator: Bool) -> FuncResult {
    let kindStr = ""
    let ps2 = ps

    if isCreator {
        kindStr = "creator"
        if peek(ps2).kind == 212 { ps2 = advance(ps2) }  // consume "creator"
    } else {
        let kr = parseFuncKind(ps2)
        kindStr = kr.kind
        ps2 = kr.ps
    }

    // optional function-level deps block, before the name:
    //   kind { d: I, ... } name(...)   — full form (where / or / list disambiguation)
    //   kind (d: I, ...)  name(...)    — simple form (plain deps, no guards)
    let fdeps: DepSpec[] = []
    if peek(ps2).kind == 102 {  // { ... }
        ps2 = advance(ps2)
        while peek(ps2).kind != 103 and peek(ps2).kind != 0 {
            let dr = parseDep(ps2)
            fdeps = appendDepSpec(fdeps, dr.spec)
            ps2 = dr.ps
        }
        if peek(ps2).kind == 103 { ps2 = advance(ps2) }  // }
    } else {
        if peek(ps2).kind == 100 {  // ( ... ) — simple deps
            ps2 = advance(ps2)
            while peek(ps2).kind != 101 and peek(ps2).kind != 0 {
                let dr = parseDep(ps2)
                fdeps = appendDepSpec(fdeps, dr.spec)
                ps2 = dr.ps
            }
            if peek(ps2).kind == 101 { ps2 = advance(ps2) }  // )
        }
    }

    // name — may be an extension function `Type.method` (e.g. `Integer.double`,
    // `Person.fullName`) or on an array type `Type[].method` (e.g.
    // `Token[].kindAt`). The receiver is passed as a `this` parameter; the
    // function is named `<recvXtype>__<method>` (the xtype a receiver carries).
    let nameTok = peek(ps2)
    ps2 = advance(ps2)
    let fname = nameTok.text
    let extThis = ""
    let arrRecv = false
    if peek(ps2).kind == 104 and peekAt(ps2, 1).kind == 105 {   // `Type[]` receiver
        arrRecv = true
        ps2 = advance(advance(ps2))            // past `[` `]`
    }
    if peek(ps2).kind == 107 {                 // '.'  -> extension on a type
        let recvCtype = identToCtype(nameTok.text)
        if nameTok.kind >= 260 and nameTok.kind <= 269 { recvCtype = primKindToCtype(nameTok.kind) }
        let xkey = nameTok.text                // the xtype the extension is keyed on
        if arrRecv {
            let elemSuf = nameTok.text         // user type: keep the name (xc_arr_Token_t)
            if nameTok.kind >= 260 and nameTok.kind <= 269 { elemSuf = ctypeSuffix(primKindToCtype(nameTok.kind)) }
            recvCtype = "xc_arr_" + elemSuf + "_t"
            xkey = "arr_" + elemSuf
        }
        ps2 = advance(ps2)                     // '.'
        fname = xkey + "__" + peek(ps2).text
        ps2 = advance(ps2)                     // method name
        extThis = recvCtype + " this"
    }

    // (params) — table-form decisions have none (columns are declared in the body)
    let pr = ParamResult { params: "", ps: ps2 }
    if peek(ps2).kind == 100 {  // (
        ps2 = advance(ps2)
        pr = parseParams(ps2)
        ps2 = pr.ps
        if peek(ps2).kind == 101 { ps2 = advance(ps2) }  // )
    }
    // extension: prepend the receiver as `this` (so `this`/`this.field` just work)
    if string_len(extThis) > 0 {
        if string_len(pr.params) > 0 { pr = ParamResult { params: extThis + ", " + pr.params, ps: pr.ps } }
        else { pr = ParamResult { params: extThis, ps: pr.ps } }
    }

    // -> rettype
    let rr = parseRetType(ps2)
    ps2 = rr.ps

    let retCtype = retCtypeFor(kindStr, rr.ctype)

    // optional `interrupts T, ...` effect annotation (parsed; checking is future)
    if peek(ps2).kind == 281 {
        ps2 = advance(ps2)
        while peek(ps2).kind != 102 and peek(ps2).kind != 242 and peek(ps2).kind != 0 {
            ps2 = advance(ps2)
        }
    }

    // `listener` subscription clause:  on "topic.name"
    let topic = ""
    if kindStr == "listener" {
        if peek(ps2).kind == 1 and peek(ps2).text == "on" {
            ps2 = advance(ps2)
            if peek(ps2).kind == 4 {   // string literal
                topic = peek(ps2).text
                ps2 = advance(ps2)
            }
        }
    }

    // optional `where <guard>` before the body
    let hasWhere = false
    let whereTokens: Token[] = []
    if peek(ps2).kind == 242 {  // where
        ps2 = advance(ps2)
        hasWhere = true
        // collect guard tokens until the body: a `{` block or an `=>` inline body
        while peek(ps2).kind != 102 and peek(ps2).kind != 110 and peek(ps2).kind != 0 {
            whereTokens = appendToken(whereTokens, peek(ps2))
            ps2 = advance(ps2)
        }
    }

    // body { ... }  (decisions: when-form desugars to if/return tokens; table-form
    // is kept structurally and emitted directly by codegen)
    let emptyStrs0: String[] = []
    let emptyToks0: Token[] = []
    let emptyRows0: DecisionRow[] = []
    let dTable = DecisionTable { name: "", params: "", policy: "first", agg: "", outNames: emptyStrs0, outCtypes: emptyStrs0, retElem: "", retCtype: "", isMulti: false, rows: emptyRows0 }
    let dOutType = TypeSpec { name: "", isCompound: false, baseCtype: "", fields: emptyStrs0, hasWhere: false, whereSrc: "", whereTokens: emptyToks0, isSum: false, variants: [] }
    let hasTable = false
    let hasOutType = false
    let br = parseBody(ps2)
    // Inline body: `=> expr` (single line) is sugar for `{ return expr }`.
    if kindStr != "decision" and peek(ps2).kind == 110 {
        let ips = advance(ps2)                 // consume =>
        let ln0 = peek(ips).line
        let bt: Token[] = []
        bt = appendToken(bt, mkTok(221, "return", ln0))
        // Collect the inline expression. A `}` at brace-depth 0 closes the
        // enclosing scope (e.g. a one-line class method) — stop without
        // consuming it. Braces opened within the expr (struct literals) nest.
        let depth = 0
        let running = true
        while running and peek(ips).kind != 0 and peek(ips).line == ln0 {
            let ct = peek(ips)
            if ct.kind == 103 and depth == 0 {
                running = false
            } else {
                if ct.kind == 102 { depth = depth + 1 }
                if ct.kind == 103 { depth = depth - 1 }
                bt = appendToken(bt, ct)
                ips = advance(ips)
            }
        }
        br = BodyResult { bodyTokens: bt, ps: ips }
    }
    if kindStr == "decision" {
        let dr = parseDecision(nameTok.text, ps2)
        br = BodyResult { bodyTokens: dr.bodyTokens, ps: dr.ps }
        if dr.isTable {
            pr = ParamResult { params: dr.params, ps: pr.ps }   // in-columns become params
            retCtype = dr.retCtype                              // result type by policy/out
            dTable = dr.table
            hasTable = true
            dOutType = dr.outType
            hasOutType = dr.hasOutType
        }
    }
    ps2 = br.ps

    let spec = FuncSpec {
        isCreator: isCreator,
        isAsync: isAsync,
        kind: kindStr,
        name: fname,
        params: pr.params,
        retCtype: retCtype,
        bodyTokens: br.bodyTokens,
        hasWhere: hasWhere,
        whereTokens: whereTokens,
        fnDeps: fdeps,
        topic: topic
    }
    return FuncResult { spec: spec, ps: ps2, table: dTable, hasTable: hasTable, outType: dOutType, hasOutType: hasOutType }
}

// Parse one method spec from an interface (no body)
type SigResult = { spec: MethodSpec, ps: PState }

mapper parseSig(ps: PState, isAsync: Bool) -> SigResult {
    let kr = parseFuncKind(ps)
    let ps2 = kr.ps
    let nameTok = peek(ps2)
    ps2 = advance(ps2)
    if peek(ps2).kind == 100 { ps2 = advance(ps2) }
    let pr = parseParams(ps2)
    ps2 = pr.ps
    if peek(ps2).kind == 101 { ps2 = advance(ps2) }
    let rr = parseRetType(ps2)
    ps2 = rr.ps
    let retCtype = retCtypeFor(kr.kind, rr.ctype)
    let spec = MethodSpec {
        isAsync: isAsync, kind: kr.kind,
        name: nameTok.text, params: pr.params, retCtype: retCtype,
        bodyTokens: [], topic: "", hasWhere: false, whereTokens: [], fnDeps: []
    }
    return SigResult { spec: spec, ps: ps2 }
}

// ── Top-level declaration parsers ─────────────────────────────────

// Skip tokens inside a balanced block (depth-tracked with { })
mapper skipBlock(ps: PState) -> PState {
    if peek(ps).kind != 102 { return ps }  // no opening {
    let ps2 = advance(ps)
    let depth = 1
    while depth > 0 and peek(ps2).kind != 0 {
        if peek(ps2).kind == 102 { depth = depth + 1 }
        if peek(ps2).kind == 103 { depth = depth - 1 }
        ps2 = advance(ps2)
    }
    return ps2
}

// Parse `type Name = TypeExpr (where Expr)?`
type TypeResult2 = { spec: TypeSpec, ps: PState }

mapper parseTypeDecl(ps: PState) -> TypeResult2 {
    let ps2 = advance(ps)  // consume "type"
    let name = peek(ps2).text
    ps2 = advance(ps2)
    if peek(ps2).kind == 111 { ps2 = advance(ps2) }  // =

    let fields: String[] = []

    // Compound type: { field : type, ... }
    if peek(ps2).kind == 102 {
        ps2 = advance(ps2)  // consume {
        while peek(ps2).kind != 103 and peek(ps2).kind != 0 {
            let fname = peek(ps2).text
            ps2 = advance(ps2)
            if peek(ps2).kind == 108 { ps2 = advance(ps2) }  // :
            let tr = parseTypeExpr(ps2)
            ps2 = tr.ps
            fields = appendString(fields, fname + ":" + tr.ctype)
            if peek(ps2).kind == 106 { ps2 = advance(ps2) }  // ,
        }
        if peek(ps2).kind == 103 { ps2 = advance(ps2) }  // }
        let spec = TypeSpec {
            name: name, isCompound: true,
            baseCtype: "", fields: fields,
            hasWhere: false, whereSrc: "", whereTokens: [],
            isSum: false, variants: []
        }
        return TypeResult2 { spec: spec, ps: ps2 }
    }

    // Sum / algebraic type:  = | Variant { fields } | Variant2 | ...
    if peek(ps2).kind == 125 {   // leading `|`
        let variants: String[] = []
        while peek(ps2).kind == 125 {
            ps2 = advance(ps2)                       // consume `|`
            let vname = peek(ps2).text
            ps2 = advance(ps2)
            let vfields = ""
            if peek(ps2).kind == 102 {               // optional { fields }
                ps2 = advance(ps2)
                let first = true
                while peek(ps2).kind != 103 and peek(ps2).kind != 0 {
                    let fname = peek(ps2).text
                    ps2 = advance(ps2)
                    if peek(ps2).kind == 108 { ps2 = advance(ps2) }  // :
                    let ftr = parseTypeExpr(ps2)
                    ps2 = ftr.ps
                    if not first { vfields = vfields + "," }
                    vfields = vfields + fname + ":" + ftr.ctype
                    first = false
                    if peek(ps2).kind == 106 { ps2 = advance(ps2) }  // ,
                }
                if peek(ps2).kind == 103 { ps2 = advance(ps2) }      // }
            }
            variants = appendString(variants, vname + "|" + vfields)
        }
        let spec = TypeSpec {
            name: name, isCompound: false,
            baseCtype: "", fields: [],
            hasWhere: false, whereSrc: "", whereTokens: [],
            isSum: true, variants: variants
        }
        return TypeResult2 { spec: spec, ps: ps2 }
    }

    // Refined type: BaseType (where expr)?
    let tr = parseTypeExpr(ps2)
    ps2 = tr.ps
    let hasWhere = false
    let whereTokens: Token[] = []
    if peek(ps2).kind == 242 {  // where
        hasWhere = true
        ps2 = advance(ps2)
        // collect tokens until the next top-level declaration starts
        while peek(ps2).kind != 0 and not isDeclStart(peek(ps2)) {
            whereTokens = appendToken(whereTokens, peek(ps2))
            ps2 = advance(ps2)
        }
    }
    let spec = TypeSpec {
        name: name, isCompound: false,
        baseCtype: tr.ctype, fields: fields,
        hasWhere: hasWhere, whereSrc: "", whereTokens: whereTokens,
        isSum: false, variants: []
    }
    return TypeResult2 { spec: spec, ps: ps2 }
}

decision isDeclStart(tok: Token) -> Bool {
    when tok.kind == 200 => true   // type
    when tok.kind == 280 => true   // interrupt
    when tok.kind == 288 => true   // atom
    when tok.kind == 289 => true   // state
    when tok.kind == 292 => true   // machine
    when tok.kind == 296 => true   // event
    when tok.kind == 201 => true   // interface
    when tok.kind == 202 => true   // class
    when tok.kind == 210 => true   // module
    when tok.kind == 219 => true   // entry
    when tok.kind == 212 => true   // creator
    when tok.kind == 213 => true   // mapper
    when tok.kind == 214 => true   // projector
    when tok.kind == 215 => true   // predicate
    when tok.kind == 216 => true   // consumer
    when tok.kind == 217 => true   // producer
    when tok.kind == 218 => true   // reducer
    when tok.kind == 256 => true   // decision
    when tok.kind == 230 => true   // async
    when tok.kind == 235 => true   // extern
    when tok.kind == 245 => true   // export
    else                 => false
}

// Parse `interface Name (extends A, B)? { methods... }`
type IfaceResult = { spec: IfaceSpec, ps: PState }

mapper parseIface(ps: PState) -> IfaceResult {
    let ps2 = advance(ps)  // consume "interface"
    let name = peek(ps2).text
    ps2 = advance(ps2)

    // optional generic params:  interface Name<TKey, TEntity> { ... }
    let typeParams: String[] = []
    if peek(ps2).kind == 114 {   // '<'
        ps2 = advance(ps2)
        while peek(ps2).kind != 115 and peek(ps2).kind != 0 {
            if peek(ps2).kind == 1 { typeParams = appendString(typeParams, peek(ps2).text) }
            ps2 = advance(ps2)
            if peek(ps2).kind == 106 { ps2 = advance(ps2) }   // ','
        }
        if peek(ps2).kind == 115 { ps2 = advance(ps2) }       // '>'
    }

    let exNames: String[] = []
    let exArgs: String[] = []
    if peek(ps2).kind == 204 {  // extends
        ps2 = advance(ps2)
        let running = true
        while running and peek(ps2).kind == 1 {
            exNames = appendString(exNames, peek(ps2).text)
            ps2 = advance(ps2)
            // optional type args on the extended interface: extends Base<A, B>
            let ar = parseTypeArgs(ps2)
            exArgs = appendString(exArgs, ar.args)
            ps2 = ar.ps
            if peek(ps2).kind == 106 { ps2 = advance(ps2) } else { running = false }
        }
    }

    let methList: MethodSpec[] = []
    if peek(ps2).kind == 102 { ps2 = advance(ps2) }  // {
    while peek(ps2).kind != 103 and peek(ps2).kind != 0 {
        let isAsync = false
        if peek(ps2).kind == 230 {
            isAsync = true
            ps2 = advance(ps2)
        }
        let kr = parseFuncKind(ps2)
        if kr.ok {
            let sr = parseSig(ps2, isAsync)
            ps2 = sr.ps
            // Optional default implementation: a `{ ... }` block or an `=> expr`
            // inline body after the signature. Classes that don't override the
            // method use it.
            let ms = sr.spec
            if peek(ps2).kind == 102 {
                let br = parseBody(ps2)
                ms = MethodSpec {
                    isAsync: ms.isAsync, kind: ms.kind, name: ms.name,
                    params: ms.params, retCtype: ms.retCtype,
                    bodyTokens: br.bodyTokens, topic: ms.topic,
                    hasWhere: false, whereTokens: [], fnDeps: ms.fnDeps
                }
                ps2 = br.ps
            } else {
            if peek(ps2).kind == 110 {   // `=> expr` — desugar to `return expr`
                let ips = advance(ps2)
                let ln0 = peek(ips).line
                let bt: Token[] = []
                bt = appendToken(bt, mkTok(221, "return", ln0))
                let depth = 0
                let running = true
                while running and peek(ips).kind != 0 and peek(ips).line == ln0 {
                    let ct = peek(ips)
                    if ct.kind == 103 and depth == 0 { running = false } else {
                        if ct.kind == 102 { depth = depth + 1 }
                        if ct.kind == 103 { depth = depth - 1 }
                        bt = appendToken(bt, ct)
                        ips = advance(ips)
                    }
                }
                ms = MethodSpec {
                    isAsync: ms.isAsync, kind: ms.kind, name: ms.name,
                    params: ms.params, retCtype: ms.retCtype,
                    bodyTokens: bt, topic: ms.topic,
                    hasWhere: false, whereTokens: [], fnDeps: ms.fnDeps
                }
                ps2 = ips
            }
            }
            methList = appendMethodSpec(methList, ms)
        } else {
            ps2 = advance(ps2)  // skip unknown
        }
    }
    if peek(ps2).kind == 103 { ps2 = advance(ps2) }  // }

    let spec = IfaceSpec { name: name, extendsNames: exNames, methList: methList,
                           typeParams: typeParams, extendsArgs: exArgs }
    return IfaceResult { spec: spec, ps: ps2 }
}

// Parse an optional `<Arg1, Arg2>` type-argument list; returns the comma-joined
// args ("" if there was no `<`). Args are type names (concrete or type vars).
type TypeArgsResult = { args: String, ps: PState }
mapper parseTypeArgs(ps: PState) -> TypeArgsResult {
    if peek(ps).kind != 114 { return TypeArgsResult { args: "", ps: ps } }   // no '<'
    let ps2 = advance(ps)
    let out = ""
    // Capture each token's text (a type name may be an identifier like `User` or
    // a primitive-type keyword like `Integer`/`String`); commas separate args.
    while peek(ps2).kind != 115 and peek(ps2).kind != 0 {
        if peek(ps2).kind == 106 { out = out + "," } else { out = out + peek(ps2).text }
        ps2 = advance(ps2)
    }
    if peek(ps2).kind == 115 { ps2 = advance(ps2) }       // '>'
    return TypeArgsResult { args: out, ps: ps2 }
}

// Parse one dependency:  name: Type [ [] | ? | where <cond> | or Alt ]
type DepResult = { spec: DepSpec, ps: PState }

mapper parseDep(ps: PState) -> DepResult {
    let ps2 = ps
    let dname = peek(ps2).text
    ps2 = advance(ps2)
    if peek(ps2).kind == 108 { ps2 = advance(ps2) }  // :
    let dtTok = peek(ps2)
    let ifName = ""
    if dtTok.kind == 1 { ifName = dtTok.text }
    let tr = parseTypeExpr(ps2)
    ps2 = tr.ps
    let dctype = tr.ctype

    // a generic interface dependency:  d: CrudRepository<Integer, User>
    // -> resolve to the monomorphized concrete interface CrudRepository_Integer_User.
    if peek(ps2).kind == 114 {   // '<'
        let ga = parseTypeArgs(ps2)
        ps2 = ga.ps
        ifName = ifName + "_" + ga.args.replaceAll(",", "_")
        dctype = "xc_" + ifName + "_t"
    }

    let form = "single"
    if dctype.startsWith2("xc_arr_") { form = "list" }
    if dctype.startsWith2("xc_opt_") { form = "opt" }

    // optional `as singleton` — mark this dependency's binding as a shared
    // singleton at the injection site (no module `bind ... as singleton` needed).
    let scopeKind = ""
    if peek(ps2).kind == 209 and peekAt(ps2, 1).kind == 239 {   // as singleton
        scopeKind = "singleton"
        ps2 = advance(ps2)
        ps2 = advance(ps2)
    }

    let orAlt = ""
    let whereToks: Token[] = []
    if peek(ps2).kind == 242 {        // where <cond>
        form = "where"
        ps2 = advance(ps2)
        let collecting = true
        while collecting and peek(ps2).kind != 0 {
            let k = peek(ps2).kind
            let nextDep = false
            if k == 1 and peekAt(ps2, 1).kind == 108 { nextDep = true }  // IDENT ':'
            if k == 103 or k == 106 or nextDep {
                collecting = false
            } else {
                whereToks = appendToken(whereToks, peek(ps2))
                ps2 = advance(ps2)
            }
        }
    } else {
        if peek(ps2).kind == 226 {    // or <Alt>
            form = "or"
            ps2 = advance(ps2)
            orAlt = peek(ps2).text
            ps2 = advance(ps2)
        } else {
            if peek(ps2).kind == 206 { // legacy `when { ... }` — ignored (auto/bind)
                ps2 = advance(ps2)
                ps2 = skipBlock(ps2)
            }
        }
    }
    if peek(ps2).kind == 106 { ps2 = advance(ps2) }  // optional ,

    let spec = DepSpec {
        name: dname, ctype: dctype, ifaceName: ifName, hasWhen: false,
        form: form, orAlt: orAlt, whereTokens: whereToks, scopeKind: scopeKind
    }
    return DepResult { spec: spec, ps: ps2 }
}

// Parse `class Name implements A, B { deps { ... } methods... }`
type ClassResult = { spec: ClassSpec, ps: PState }

mapper parseClass(ps: PState) -> ClassResult {
    let ps2 = advance(ps)   // "class"
    let name = peek(ps2).text
    ps2 = advance(ps2)

    // implements  (each interface may carry type args: implements Base<Integer, User>)
    let implNames: String[] = []
    let implArgs:  String[] = []
    if peek(ps2).kind == 203 {  // implements
        ps2 = advance(ps2)
        let running = true
        while running and peek(ps2).kind == 1 {
            implNames = appendString(implNames, peek(ps2).text)
            ps2 = advance(ps2)
            let ar = parseTypeArgs(ps2)
            implArgs = appendString(implArgs, ar.args)
            ps2 = ar.ps
            if peek(ps2).kind == 106 { ps2 = advance(ps2) } else { running = false }
        }
    }

    if peek(ps2).kind == 102 { ps2 = advance(ps2) }  // {

    // deps block
    let depList: DepSpec[] = []
    if peek(ps2).kind == 205 {  // deps
        ps2 = advance(ps2)
        if peek(ps2).kind == 102 { ps2 = advance(ps2) }  // {
        while peek(ps2).kind != 103 and peek(ps2).kind != 0 {
            let dr = parseDep(ps2)
            depList = appendDepSpec(depList, dr.spec)
            ps2 = dr.ps
        }
        if peek(ps2).kind == 103 { ps2 = advance(ps2) }  // }
    }

    // optional mutable state block:  state { name: Type = expr, ... }
    let stateFields: String[] = []
    let stateInit: Token[] = []
    if peek(ps2).kind == 289 and peekAt(ps2, 1).kind == 102 {   // state {
        ps2 = advance(ps2)   // state
        ps2 = advance(ps2)   // {
        while peek(ps2).kind != 103 and peek(ps2).kind != 0 {
            let fname = peek(ps2).text
            stateInit = appendToken(stateInit, peek(ps2))   // name
            ps2 = advance(ps2)
            if peek(ps2).kind == 108 { ps2 = advance(ps2) }   // :
            let ftr = parseTypeExpr(ps2)
            ps2 = ftr.ps
            stateFields = appendString(stateFields, fname + ":" + ftr.ctype)
            if peek(ps2).kind == 111 {                        // =
                stateInit = appendToken(stateInit, peek(ps2))
                ps2 = advance(ps2)
            }
            let depth = 0
            let coll = true
            while coll {
                let it = peek(ps2)
                if it.kind == 0 { coll = false }
                else { if depth == 0 and (it.kind == 106 or it.kind == 103) { coll = false }
                else {
                    // Track (), [], {} and <> so a comma inside a generic default
                    // (e.g. `= empty Map<String, Integer>`) does not end the field.
                    if it.kind == 100 or it.kind == 104 or it.kind == 102 or it.kind == 114 { depth = depth + 1 }
                    if it.kind == 101 or it.kind == 105 or it.kind == 103 or it.kind == 115 { depth = depth - 1 }
                    stateInit = appendToken(stateInit, it)
                    ps2 = advance(ps2)
                } }
            }
            if peek(ps2).kind == 106 {                        // ,
                stateInit = appendToken(stateInit, peek(ps2))
                ps2 = advance(ps2)
            }
        }
        if peek(ps2).kind == 103 { ps2 = advance(ps2) }       // }
    }

    // methods and creators
    let methList: MethodSpec[] = []
    while peek(ps2).kind != 103 and peek(ps2).kind != 0 {
        let isAsync = false
        if peek(ps2).kind == 230 {
            isAsync = true
            ps2 = advance(ps2)
        }
        // creator
        if peek(ps2).kind == 212 {
            let fr = parseFunc(ps2, isAsync, true)
            ps2 = fr.ps
            let ms = MethodSpec {
                isAsync: isAsync, kind: "creator",
                name: fr.spec.name, params: fr.spec.params,
                retCtype: fr.spec.retCtype, bodyTokens: fr.spec.bodyTokens,
                topic: "", hasWhere: false, whereTokens: [], fnDeps: fr.spec.fnDeps
            }
            methList = appendMethodSpec(methList, ms)
        } else {
            let kr = parseFuncKind(ps2)
            if kr.ok {
                let fr = parseFunc(ps2, isAsync, false)
                ps2 = fr.ps
                let ms = MethodSpec {
                    isAsync: isAsync, kind: fr.spec.kind,
                    name: fr.spec.name, params: fr.spec.params,
                    retCtype: fr.spec.retCtype, bodyTokens: fr.spec.bodyTokens,
                    topic: fr.spec.topic,
                    hasWhere: fr.spec.hasWhere, whereTokens: fr.spec.whereTokens,
                    fnDeps: fr.spec.fnDeps
                }
                methList = appendMethodSpec(methList, ms)
            } else {
                ps2 = advance(ps2)
            }
        }
    }
    if peek(ps2).kind == 103 { ps2 = advance(ps2) }  // }

    let spec = ClassSpec { name: name, implNames: implNames, depList: depList, methList: methList, stateFields: stateFields, stateInit: stateInit, implArgs: implArgs }
    return ClassResult { spec: spec, ps: ps2 }
}

// Parse an `entry` declaration (peek at `entry`): optional `{deps}` / `(deps)`,
// name, `(params)`, return type, body. Usable top-level or inside a `module`.
type EntryParse = { spec: FuncSpec, ps: PState }
mapper parseEntry(ps: PState, isAsync: Bool) -> EntryParse {
    let ps2 = advance(ps)   // `entry`
    let edeps: DepSpec[] = []
    if peek(ps2).kind == 102 {                  // { deps }
        ps2 = advance(ps2)
        while peek(ps2).kind != 103 and peek(ps2).kind != 0 {
            let dr = parseDep(ps2)
            edeps = appendDepSpec(edeps, dr.spec)
            ps2 = dr.ps
        }
        if peek(ps2).kind == 103 { ps2 = advance(ps2) }
    } else {
        if peek(ps2).kind == 100 {              // ( deps )
            ps2 = advance(ps2)
            while peek(ps2).kind != 101 and peek(ps2).kind != 0 {
                let dr = parseDep(ps2)
                edeps = appendDepSpec(edeps, dr.spec)
                ps2 = dr.ps
            }
            if peek(ps2).kind == 101 { ps2 = advance(ps2) }
        }
    }
    let nameTok = peek(ps2)
    ps2 = advance(ps2)
    if peek(ps2).kind == 100 { ps2 = advance(ps2) }
    let pr = parseParams(ps2)
    ps2 = pr.ps
    if peek(ps2).kind == 101 { ps2 = advance(ps2) }
    let rr = parseRetType(ps2)
    ps2 = rr.ps
    let br = parseBody(ps2)
    ps2 = br.ps
    let spec = FuncSpec {
        isCreator: false, isAsync: isAsync, kind: "entry", name: nameTok.text,
        params: pr.params, retCtype: retCtypeFor("entry", rr.ctype),
        bodyTokens: br.bodyTokens, hasWhere: false, whereTokens: [], fnDeps: edeps, topic: ""
    }
    return EntryParse { spec: spec, ps: ps2 }
}

