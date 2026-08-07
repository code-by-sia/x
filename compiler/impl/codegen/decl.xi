// xc codegen — typedefs, compound/sum bodies, interfaces, vtables
// (part of the xc code generator — Program -> C99; spliced via codegen.xi)

// Refined-type aliases (typedef base) — must precede array typedefs.
// An alias whose target is an array/optional type (e.g. `type People = Person[]`).
// These reference xc_arr_*/xc_opt_* and so must be emitted AFTER those typedefs
// (see genAliasTypedefs); they are skipped by the array/opt/result/refined passes.
// True if the C base type is a container monomorphization (array, or a
// collection alias like xc_Map_*/xc_List_*). Such aliases must be emitted after
// genArrTypedefs, which defines those underlying typedefs.
predicate isCollectionCtype(b: String) {
    return b.startsWith2("xc_arr_")
        or b.startsWith2("xc_Map_")
        or b.startsWith2("xc_List_")
        or b.startsWith2("xc_Set_")
        or b.startsWith2("xc_Stack_")
        or b.startsWith2("xc_Queue_")
        or b.startsWith2("xc_SortedQueue_")
        or b.startsWith2("xc_Future_")
        or b.startsWith2("xc_Query_")
}

predicate isCompositeAlias(ts: TypeSpec) {
    if ts.isCompound { return false }
    return isCollectionCtype(ts.baseCtype)
}

mapper genRefinedTypedefs(prog: Program) -> String {
    let out = "/* === Refined type aliases === */\n"
    let i = 0
    let n = typeSpecLen(prog.types)
    while i < n {
        let ts = typeSpecGet(prog.types, i)
        if not ts.isCompound and not ts.isSum and not isCompositeAlias(ts) {
            out = out + "typedef " + ts.baseCtype + " xc_" + ts.name + "_t;\n"
        }
        i = i + 1
    }
    return out + "\n"
}

// Aliases to array/optional types, emitted after genArrTypedefs/genOptTypedefs
// so the target xc_arr_*/xc_opt_* typedefs already exist.
mapper genAliasTypedefs(prog: Program) -> String {
    let out = "/* === Array/optional type aliases === */\n"
    let i = 0
    let n = typeSpecLen(prog.types)
    while i < n {
        let ts = typeSpecGet(prog.types, i)
        if isCompositeAlias(ts) {
            out = out + "typedef " + ts.baseCtype + " xc_" + ts.name + "_t;\n"
        }
        i = i + 1
    }
    return out + "\n"
}

// Full compound struct bodies + sum-type tagged unions, emitted in declaration
// order so a type may embed any earlier-declared type by value.
mapper genCompoundBodies(prog: Program) -> String {
    let out = "/* === Compound + sum type bodies === */\n"
    let i = 0
    let n = typeSpecLen(prog.types)
    while i < n {
        let ts = typeSpecGet(prog.types, i)
        if ts.isCompound {
            out = out + "struct xc_" + ts.name + "_s {\n"
            let fi = 0
            let fn2 = stringArrLen(ts.fields)
            while fi < fn2 {
                let field = stringArrGet(ts.fields, fi)
                let colonPos = findChar(field, 58)
                let fname = string_slice(field, 0, colonPos)
                let fctype = string_slice(field, colonPos + 1, string_len(field))
                out = out + "    " + fctype + " " + fname + ";\n"
                fi = fi + 1
            }
            out = out + "};\n"
        }
        if ts.isSum { out = out + sumBody(ts) }
        i = i + 1
    }
    return out + "\n"
}

// One sum type's tag #defines + tagged-union struct body.
mapper sumBody(ts: TypeSpec) -> String {
    let out = ""
    let vn = stringArrLen(ts.variants)
    let vi = 0
    while vi < vn {
        let v = stringArrGet(ts.variants, vi)
        let bar = findChar(v, 124)
        out = out + "#define xc_" + ts.name + "_" + string_slice(v, 0, bar) + " " + int_to_string(vi) + "\n"
        vi = vi + 1
    }
    out = out + "struct xc_" + ts.name + "_s {\n    int tag;\n"
    let anyFields = false
    vi = 0
    while vi < vn {
        let v = stringArrGet(ts.variants, vi)
        let bar = findChar(v, 124)
        if string_len(string_slice(v, bar + 1, string_len(v))) > 0 { anyFields = true }
        vi = vi + 1
    }
    if anyFields {
        out = out + "    union {\n"
        vi = 0
        while vi < vn {
            let v = stringArrGet(ts.variants, vi)
            let bar = findChar(v, 124)
            let vname = string_slice(v, 0, bar)
            let fstr = string_slice(v, bar + 1, string_len(v))
            if string_len(fstr) > 0 {
                out = out + "        struct { " + fstr.sumFieldsToCFor(ts.name) + "} " + vname + ";\n"
            }
            vi = vi + 1
        }
        out = out + "    } u;\n"
    }
    return out + "};\n"
}

// Boxing helpers for recursive sum types: a variant field whose type is the
// enclosing sum itself is stored as a pointer; construction goes through
// xc_box_<Sum>, which copies the value to the heap. One helper per sum type
// that has at least one self-referential payload field.
mapper genSumBoxHelpers(prog: Program) -> String {
    let out = ""
    let i = 0
    let n = typeSpecLen(prog.types)
    while i < n {
        let ts = typeSpecGet(prog.types, i)
        if ts.isSum and prog.sumHasBoxedFields(ts.name) {
            out = out + "static xc_" + ts.name + "_t* xc_box_" + ts.name + "(xc_" + ts.name + "_t v) {\n"
                      + "    xc_" + ts.name + "_t* p = (xc_" + ts.name + "_t*)xc_obj_alloc(sizeof(v));\n"
                      + "    if (!p) abort();\n    *p = v;\n    return p;\n}\n"
        }
        i = i + 1
    }
    if string_len(out) > 0 { out = "/* === Recursive sum-type boxing === */\n" + out + "\n" }
    return out
}

// Tagged-union bodies for sum types: an int tag plus a union of the payload
// structs (only variants that carry fields), and a #define per variant tag.
mapper genForwardDecls(prog: Program) -> String {
    let out = "/* === Forward declarations === */\n"
    // Compound types (so array typedefs can use xc_T_t* before the full body)
    let t = 0
    let tn = typeSpecLen(prog.types)
    while t < tn {
        let ts = typeSpecGet(prog.types, t)
        if ts.isCompound {
            out = out + "typedef struct xc_" + ts.name + "_s xc_" + ts.name + "_t;\n"
        }
        if ts.isSum {
            out = out + "typedef struct xc_" + ts.name + "_s xc_" + ts.name + "_t;\n"
        }
        t = t + 1
    }
    let i = 0
    let n = classSpecLen(prog.classes)
    while i < n {
        let cs = classSpecGet(prog.classes, i)
        out = out + "typedef struct xc_" + cs.name + "_s xc_" + cs.name + "_t;\n"
        i = i + 1
    }
    let j = 0
    let m = ifaceSpecLen(prog.ifaces)
    while j < m {
        let is2 = ifaceSpecGet(prog.ifaces, j)
        out = out + "typedef struct xc_" + is2.name + "_vtable_s xc_" + is2.name + "_vtable_t;\n"
        out = out + "typedef struct xc_" + is2.name + "_s xc_" + is2.name + "_t;\n"
        j = j + 1
    }
    return out + "\n"
}

mapper genIfaceDecls(prog: Program) -> String {
    let out = "/* === Interfaces === */\n"
    let i = 0
    let n = ifaceSpecLen(prog.ifaces)
    while i < n {
        let is2 = ifaceSpecGet(prog.ifaces, i)
        out = out + "struct xc_" + is2.name + "_vtable_s {\n"
        let mi = 0
        let mn = methodSpecLen(is2.methList)
        while mi < mn {
            let ms = methodSpecGet(is2.methList, mi)
            let pstr = ms.params
            if string_len(pstr) > 0 { pstr = ", " + pstr }
            out = out + "    " + ms.retCtype + " (*" + ms.name + ")(void* self" + pstr + ");\n"
            mi = mi + 1
        }
        out = out + "};\n"
        out = out + "struct xc_" + is2.name + "_s { void* self; const xc_" + is2.name + "_vtable_t* vtable; };\n\n"
        i = i + 1
    }
    return out + "\n"
}

// Default implementations for interface methods declared with a `{ ... }` body.
// A class that doesn't override the method gets this in its vtable slot. `self`
// is opaque here (the concrete type is unknown), so a default body cannot touch
// instance fields — it works over its parameters (and may return a constant).
mapper genIfaceDefaults(prog: Program) -> String {
    let out = "/* === Interface default methods === */\n"
    let i = 0
    let n = ifaceSpecLen(prog.ifaces)
    while i < n {
        let is2 = ifaceSpecGet(prog.ifaces, i)
        let mi = 0
        let mn = methodSpecLen(is2.methList)
        while mi < mn {
            let ms = methodSpecGet(is2.methList, mi)
            if tokenArrLen(ms.bodyTokens) > 0 {
                let pstr = ms.params
                if string_len(pstr) > 0 { pstr = ", " + pstr }
                let tag = is2.name + "_" + ms.name
                out = out + hoistCatches(prog, ms.bodyTokens, tag)
                out = out + hoistParallel(prog, ms.bodyTokens, tag)
                out = out + hoistLambdas(prog, ms.bodyTokens, tag)
                out = out + "static " + ms.retCtype + " xc_" + is2.name + "_" + ms.name + "_default_impl(void* self_ptr" + pstr + ") {\n"
                out = out + "    (void)self_ptr;\n"
                out = out + captureDecls(ms.bodyTokens)
                let ctx = seedCaptures(((prog.newCtx().seedParams(ms.params)).withRet(ms.retCtype)).withTag(tag), ms.bodyTokens)
                out = out + genBody2(ms.bodyTokens, ctx)
                out = out + "}\n\n"
            }
            mi = mi + 1
        }
        i = i + 1
    }
    return out + "\n"
}

mapper genClassStructs(prog: Program) -> String {
    let out = "/* === Class structs === */\n"
    let i = 0
    let n = classSpecLen(prog.classes)
    while i < n {
        let cs = classSpecGet(prog.classes, i)
        out = out + "struct xc_" + cs.name + "_s {\n"
        let di = 0
        let dn = depSpecLen(cs.depList)
        while di < dn {
            let dep = depSpecGet(cs.depList, di)
            out = out + "    " + dep.ctype + " " + dep.name + ";\n"
            di = di + 1
        }
        // mutable instance state: "name:ctype" -> `ctype name;`
        let si = 0
        let sn = stringArrLen(cs.stateFields)
        while si < sn {
            let f = stringArrGet(cs.stateFields, si)
            let colon = findChar(f, 58)
            out = out + "    " + string_slice(f, colon + 1, string_len(f)) + " " + string_slice(f, 0, colon) + ";\n"
            si = si + 1
        }
        out = out + "};\n\n"
        i = i + 1
    }
    return out + "\n"
}

// Find the concrete class bound to an interface in a module
mapper findBinding(prog: Program, moduleName: String, ifaceName: String) -> String {
    let i = 0
    let n = moduleSpecLen(prog.modules)
    while i < n {
        let mod = moduleSpecGet(prog.modules, i)
        if mod.name == moduleName {
            let j = 0
            let m = bindSpecLen(mod.bindings)
            while j < m {
                let b = bindSpecGet(mod.bindings, j)
                if b.ifaceName == ifaceName {
                    return b.concreteName
                }
                j = j + 1
            }
        }
        i = i + 1
    }
    return ""
}

mapper findScope(prog: Program, moduleName: String, ifaceName: String) -> String {
    let i = 0
    let n = moduleSpecLen(prog.modules)
    while i < n {
        let mod = moduleSpecGet(prog.modules, i)
        if mod.name == moduleName {
            let j = 0
            let m = bindSpecLen(mod.bindings)
            while j < m {
                let b = bindSpecGet(mod.bindings, j)
                if b.ifaceName == ifaceName {
                    return b.scopeKind
                }
                j = j + 1
            }
        }
        i = i + 1
    }
    if prog.isDepMarkedSingleton(ifaceName) { return "singleton" }
    return "transient"
}

// Find a class spec by name
mapper findClass(prog: Program, name: String) -> ClassSpec {
    let i = 0
    let n = classSpecLen(prog.classes)
    while i < n {
        let cs = classSpecGet(prog.classes, i)
        if cs.name == name {
            return cs
        }
        i = i + 1
    }
    return ClassSpec { name: "", implNames: [], depList: [], methList: [], stateFields: [], stateInit: [] }
}

predicate isInterface(prog: Program, name: String) {
    let i = 0
    let n = ifaceSpecLen(prog.ifaces)
    while i < n {
        let is2 = ifaceSpecGet(prog.ifaces, i)
        if is2.name == name { return true }
        i = i + 1
    }
    return false
}

// Return type (X name) of interface method, or "" if not found.
// `predicate` methods return Bool.
mapper ifaceMethodRet(prog: Program, iface: String, method: String) -> String {
    let i = 0
    let n = ifaceSpecLen(prog.ifaces)
    while i < n {
        let is2 = ifaceSpecGet(prog.ifaces, i)
        if is2.name == iface {
            let mi = 0
            let mn = methodSpecLen(is2.methList)
            while mi < mn {
                let ms = methodSpecGet(is2.methList, mi)
                if ms.name == method {
                    if ms.kind == "predicate" { return "Bool" }
                    return prog.resolveX(ms.retCtype.ctypeToXName())
                }
                mi = mi + 1
            }
        }
        i = i + 1
    }
    return ""
}

// ── Automatic dependency resolution ───────────────────────────────
predicate classImplements(cs: ClassSpec, iface: String) {
    let i = 0
    let n = stringArrLen(cs.implNames)
    while i < n {
        if stringArrGet(cs.implNames, i) == iface { return true }
        i = i + 1
    }
    return false
}

// All classes implementing interface I, in declaration order.
mapper implementorsOf(prog: Program, iface: String) -> String[] {
    let out: String[] = []
    let i = 0
    let n = classSpecLen(prog.classes)
    while i < n {
        let cs = classSpecGet(prog.classes, i)
        if classImplements(cs, iface) { out = appendString(out, cs.name) }
        i = i + 1
    }
    return out
}

// Concrete class explicitly bound to I in any module, or "".
mapper bindFor(prog: Program, iface: String) -> String {
    // `module Test` bindings are ignored in normal builds and take precedence in
    // test builds (XC_TEST), layered over `module App` (and any other module).
    let testMode = prog.inTestMode()
    let i = 0
    let n = moduleSpecLen(prog.modules)
    let found = ""
    let testFound = ""
    while i < n {
        let mod = moduleSpecGet(prog.modules, i)
        let isTest = (mod.name == "Test")
        let j = 0
        let m = bindSpecLen(mod.bindings)
        while j < m {
            let b = bindSpecGet(mod.bindings, j)
            if b.ifaceName == iface {
                if isTest { testFound = b.concreteName } else { found = b.concreteName }
            }
            j = j + 1
        }
        i = i + 1
    }
    if testMode and string_len(testFound) > 0 { return testFound }
    return found
}

// Does any class declare a dependency on `iface` as `d: I as singleton`? Such a
// marker binds `iface` as a singleton at the injection site, so no module-level
// `bind I -> Impl as singleton` is required.
predicate Program.isDepMarkedSingleton(iface: String) {
    let i = 0
    let n = classSpecLen(this.classes)
    while i < n {
        let cs = classSpecGet(this.classes, i)
        let di = 0
        let dn = depSpecLen(cs.depList)
        while di < dn {
            let dep = depSpecGet(cs.depList, di)
            if dep.ifaceName == iface and dep.scopeKind == "singleton" { return true }
            di = di + 1
        }
        i = i + 1
    }
    return false
}

mapper bindScopeFor(prog: Program, iface: String) -> String {
    let i = 0
    let n = moduleSpecLen(prog.modules)
    let found = ""
    while i < n {
        let mod = moduleSpecGet(prog.modules, i)
        let j = 0
        let m = bindSpecLen(mod.bindings)
        while j < m {
            let b = bindSpecGet(mod.bindings, j)
            if b.ifaceName == iface { found = b.scopeKind }
            j = j + 1
        }
        i = i + 1
    }
    // A `d: I as singleton` marker on any dep upgrades I to singleton scope.
    if found != "singleton" and prog.isDepMarkedSingleton(iface) { return "singleton" }
    // No explicit bind: a module's `scope = ...` is the program-wide default, so
    // auto-resolved interfaces (never named in a `bind`) follow it too.
    if string_len(found) == 0 { return prog.defaultScope() }
    return found
}

// The declared default DI scope (`scope = ...` on any module), or "" when no
// module sets one. Last declaration wins, matching bind resolution.
mapper Program.defaultScope() -> String {
    let i = 0
    let n = moduleSpecLen(this.modules)
    let out = ""
    while i < n {
        let ds = moduleSpecGet(this.modules, i).defaultScope
        if string_len(ds) > 0 { out = ds }
        i = i + 1
    }
    return out
}

// The single chosen implementor of I: explicit bind wins; else the sole (or
// first) implementor; else "" when nothing implements I.
mapper chosenImpl(prog: Program, iface: String) -> String {
    let b = bindFor(prog, iface)
    if string_len(b) > 0 { return b }
    let impls = implementorsOf(prog, iface)
    if stringArrLen(impls) > 0 { return stringArrGet(impls, 0) }
    return ""
}

predicate isResolvable(prog: Program, iface: String) {
    if string_len(bindFor(prog, iface)) > 0 { return true }
    if stringArrLen(implementorsOf(prog, iface)) > 0 { return true }
    if string_len(prog.configPathFor(iface)) > 0 { return true }   // config-backed
    return false
}

// For `I or J`: bind wins; else the sole implementor other than J; else J.
mapper orChoose(prog: Program, iface: String, alt: String) -> String {
    let b = bindFor(prog, iface)
    if string_len(b) > 0 { return b }
    let impls = implementorsOf(prog, iface)
    let pick = ""
    let count = 0
    let i = 0
    let n = stringArrLen(impls)
    while i < n {
        let c = stringArrGet(impls, i)
        if c != alt {
            pick = c
            count = count + 1
        }
        i = i + 1
    }
    if count == 1 { return pick }
    return alt
}

mapper genVtablesAndCasters(prog: Program) -> String {
    let out = "/* === Method forward decls and vtables === */\n"
    // Forward-declare all _impl functions
    let i = 0
    let n = classSpecLen(prog.classes)
    while i < n {
        let cs = classSpecGet(prog.classes, i)
        let mi = 0
        let mn = methodSpecLen(cs.methList)
        while mi < mn {
            let ms = methodSpecGet(cs.methList, mi)
            if ms.kind != "creator" {
                let pstr = ms.params
                if string_len(pstr) > 0 { pstr = ", " + pstr }
                out = out + "static " + ms.retCtype + " xc_" + cs.name + "_" + ms.name + "_impl(void* self_ptr" + pstr + ");\n"
            }
            mi = mi + 1
        }
        i = i + 1
    }
    out = out + "\n"

    // Vtable instances + casters
    let ci = 0
    let cn2 = classSpecLen(prog.classes)
    while ci < cn2 {
        let cs = classSpecGet(prog.classes, ci)
        let ii = 0
        let iN = stringArrLen(cs.implNames)
        while ii < iN {
            let ifname = stringArrGet(cs.implNames, ii)
            // Find interface methods
            let ifSpec = IfaceSpec { name: "", extendsNames: [], methList: [] }
            let fi = 0
            let fn2 = ifaceSpecLen(prog.ifaces)
            while fi < fn2 {
                let cand = ifaceSpecGet(prog.ifaces, fi)
                if cand.name == ifname { ifSpec = cand }
                fi = fi + 1
            }
            out = out + "static const xc_" + ifname + "_vtable_t xc_" + cs.name + "_" + ifname + "_vtable = {\n"
            let mi = 0
            let mn = methodSpecLen(ifSpec.methList)
            while mi < mn {
                let ms = methodSpecGet(ifSpec.methList, mi)
                // The class's own impl if it overrides the method; otherwise the
                // interface's default impl (for methods with a default body).
                let target = "xc_" + cs.name + "_" + ms.name + "_impl"
                if countMethodName(cs, ms.name) == 0 and tokenArrLen(ms.bodyTokens) > 0 {
                    target = "xc_" + ifname + "_" + ms.name + "_default_impl"
                }
                out = out + "    ." + ms.name + " = (void*)" + target + ",\n"
                mi = mi + 1
            }
            out = out + "};\n"
            out = out + "static inline xc_" + ifname + "_t xc_" + cs.name + "_as_" + ifname + "(xc_" + cs.name + "_t* self) {\n"
            out = out + "    return (xc_" + ifname + "_t){ .self = self, .vtable = &xc_" + cs.name + "_" + ifname + "_vtable };\n"
            out = out + "}\n\n"
            ii = ii + 1
        }
        ci = ci + 1
    }
    return out + "\n"
}

