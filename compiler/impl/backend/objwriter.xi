// The object-format seam — encoded module to the bytes of a runnable file.
//
// MachoWriter assembles a complete arm64 Mach-O executable and writes it, with
// no `ld` and no `codesign`. On Apple Silicon that means the dyld + LC_MAIN
// shape (the only kind the kernel runs): __PAGEZERO / __TEXT / __LINKEDIT, a
// reference to /usr/lib/dyld and /usr/lib/libSystem.B.dylib, an empty chained-
// fixups blob (the entry imports nothing), and a self-embedded ad-hoc code
// signature — an LC_CODE_SIGNATURE SuperBlob whose CodeDirectory carries a
// SHA-256 per 4 KB page of everything before it. The kernel verifies those
// hashes at exec, so an unsigned or mis-hashed image is killed on sight.
//
// The layout was proven byte-for-byte before being ported here: every offset
// and size below is fixed for the milestone entry shape. Adding ELF later is a
// second ObjectWriter behind this interface.

interface ObjectWriter {
    mapper   formatName() -> String
    mapper   osName() -> String                 // the OS this writer produces binaries for
    // Assemble the linked code (32-bit words) into an executable at binPath, with
    // the entry at word offset `entryWord`. `extSites`/`extSyms` are the external
    // call sites and their C symbols, routed through import stubs. `runtimePath`
    // is the runtime dylib to link when a call targets it. True on success.
    producer write(code: Integer[], entryWord: Integer, extSites: Integer[], extSyms: String[], runtimePath: String, binPath: String) -> Bool
}

// Is `s` present in the string list? (A local `String[]` does not always resolve
// the `.includes` extension method, so the backend uses this directly.)
predicate strIn(arr: String[], s: String) {
    let i = 0
    let n = stringArrLen(arr)
    while i < n {
        if stringArrGet(arr, i) == s { return true }
        i = i + 1
    }
    return false
}

// Emit a 16-byte, NUL-padded name field (segment / section names).
producer emitName16(b: Integer, s: String) {
    xcb_ascii(b, s)
    xcb_zeros(b, 16 - string_len(s))
}

// Emit a segment_command_64 header (72 bytes; sections follow separately).
producer emitSeg(b: Integer, name: String, cmdsize: Integer, vmaddr: Integer, vmsize: Integer,
                 fileoff: Integer, filesize: Integer, maxprot: Integer, initprot: Integer,
                 nsects: Integer, flags: Integer) {
    xcb_u32(b, 25)              // LC_SEGMENT_64
    xcb_u32(b, cmdsize)
    emitName16(b, name)
    xcb_u64(b, vmaddr)
    xcb_u64(b, vmsize)
    xcb_u64(b, fileoff)
    xcb_u64(b, filesize)
    xcb_u32(b, maxprot)
    xcb_u32(b, initprot)
    xcb_u32(b, nsects)
    xcb_u32(b, flags)
}

// Emit a section_64 (80 bytes).
producer emitSect(b: Integer, sect: String, seg: String, addr: Integer, size: Integer,
                  offset: Integer, salign: Integer, flags: Integer) {
    emitName16(b, sect)
    emitName16(b, seg)
    xcb_u64(b, addr)
    xcb_u64(b, size)
    xcb_u32(b, offset)
    xcb_u32(b, salign)
    xcb_u32(b, 0)              // reloff
    xcb_u32(b, 0)              // nreloc
    xcb_u32(b, flags)
    xcb_u32(b, 0)             // reserved1
    xcb_u32(b, 0)             // reserved2
    xcb_u32(b, 0)             // reserved3
}

mapper importIndexOf(syms: String[], s: String) -> Integer {
    let i = 0
    let n = stringArrLen(syms)
    while i < n {
        if stringArrGet(syms, i) == s { return i }
        i = i + 1
    }
    return 0
}

class MachoWriter implements ObjectWriter {
    deps {}

    mapper formatName() -> String => "mach-o"
    mapper osName() -> String => "macos"

    producer write(code0: Integer[], entryWord: Integer, extSites: Integer[], extSyms: String[], runtimePath: String, binPath: String) -> Bool {
        // Distinct imported symbols (one __got slot + stub each).
        let importSyms: String[] = []
        let ei = 0
        while ei < stringArrLen(extSyms) {
            let s = stringArrGet(extSyms, ei)
            if not strIn(importSyms, s) { importSyms = appendString(importSyms, s) }
            ei = ei + 1
        }
        let nImports = stringArrLen(importSyms)
        let hasImports = nImports > 0
        // Runtime symbols (xstd_*) bind from the runtime dylib (2nd LC_LOAD_DYLIB,
        // ordinal 2); everything else from libSystem (ordinal 1).
        let hasRuntime = false
        let ri = 0
        while ri < nImports {
            if stringArrGet(importSyms, ri).startsWith2("_xstd_") { hasRuntime = true }
            ri = ri + 1
        }

        // Append one 3-instruction stub per import to the code.
        let code = code0
        let stubStart = intArrLen(code0)
        let sc = 0
        while sc < nImports * 3 { code = appendInt(code, 0)  sc = sc + 1 }
        let codeBytes = intArrLen(code) * 4

        let vmbase = 4294967296
        let ncmds = 12
        let sizeofcmds = 592
        if hasImports { ncmds = ncmds + 1  sizeofcmds = sizeofcmds + 152 }   // __DATA_CONST
        let rtCmdSize = alignUp(24 + string_len(runtimePath) + 1, 8)
        if hasRuntime { ncmds = ncmds + 1  sizeofcmds = sizeofcmds + rtCmdSize }
        let codeOff = alignUp(32 + sizeofcmds, 4)
        let textFilesize = alignUp(codeOff + codeBytes, 16384)
        let entryoff = codeOff + entryWord * 4

        let dataOff = textFilesize
        let gotVm = vmbase + dataOff
        let dataFilesize = 16384
        let linkeditOff = textFilesize
        if hasImports { linkeditOff = textFilesize + 16384 }

        // Encode stubs (adrp x16, got ; ldr x16,[x16] ; br x16) and route each
        // external BL to its stub.
        if hasImports {
            let s = 0
            while s < nImports {
                let stubWord = stubStart + s * 3
                let stubVm = vmbase + codeOff + stubWord * 4
                let gotSlotVm = gotVm + s * 8
                let stubPage = stubVm - (stubVm % 4096)
                let gotPage = gotSlotVm - (gotSlotVm % 4096)
                code = setInt(code, stubWord, aAdrp(16, (gotPage - stubPage) / 4096))
                code = setInt(code, stubWord + 1, aLdr(16, 16, gotSlotVm % 4096))
                code = setInt(code, stubWord + 2, 3592356352)   // br x16
                s = s + 1
            }
            let k = 0
            while k < intArrLen(extSites) {
                let stubWord = stubStart + importIndexOf(importSyms, stringArrGet(extSyms, k)) * 3
                let site = intArrGet(extSites, k)
                code = setInt(code, site, aBl(stubWord - site))
                k = k + 1
            }
        }

        // __LINKEDIT: chained fixups (with imports), empty sym/str table, signature.
        let cfLen = 48
        if hasImports {
            let symLen = 1
            let m = 0
            while m < nImports { symLen = symLen + string_len(stringArrGet(importSyms, m)) + 1  m = m + 1 }
            cfLen = alignUp(28 + (4 + 4 * 4 + 24) + nImports * 4 + symLen, 8)
        }
        let symoff = linkeditOff + cfLen
        let strsize = 8
        let codesigOff = alignUp(symoff + strsize, 16)
        let codeLimit = codesigOff
        let nCode = (codeLimit + 4095) / 4096

        let ident = baseName(binPath)
        let identLen = string_len(ident) + 1
        let cdHeaderLen = 88
        let hashOff = cdHeaderLen + identLen
        let cdTotal = hashOff + nCode * 32
        let superHdr = 20
        let codesigSize = superHdr + cdTotal
        let linkeditFilesize = (codesigOff + codesigSize) - linkeditOff
        let linkeditVmsize = alignUp(linkeditFilesize, 16384)

        let b = xcb_new()

        // ── mach_header_64 ──
        xcb_u32(b, 4277009103)     // MH_MAGIC_64
        xcb_u32(b, 16777228)       // CPU_TYPE_ARM64
        xcb_u32(b, 0)
        xcb_u32(b, 2)              // MH_EXECUTE
        xcb_u32(b, ncmds)
        xcb_u32(b, sizeofcmds)
        xcb_u32(b, 2097285)        // NOUNDEFS|DYLDLINK|TWOLEVEL|PIE
        xcb_u32(b, 0)

        // ── load commands ──
        emitSeg(b, "__PAGEZERO", 72, 0, vmbase, 0, 0, 0, 0, 0, 0)
        emitSeg(b, "__TEXT", 152, vmbase, textFilesize, 0, textFilesize, 5, 5, 1, 0)
        emitSect(b, "__text", "__TEXT", vmbase + codeOff, codeBytes, codeOff, 2, 2147484672)
        if hasImports {
            emitSeg(b, "__DATA_CONST", 152, gotVm, dataFilesize, dataOff, dataFilesize, 3, 3, 1, 16)  // SG_READ_ONLY
            emitSect(b, "__got", "__DATA_CONST", gotVm, nImports * 8, dataOff, 3, 6)                    // S_NON_LAZY_SYMBOL_POINTERS
        }
        emitSeg(b, "__LINKEDIT", 72, vmbase + linkeditOff, linkeditVmsize, linkeditOff, linkeditFilesize, 1, 1, 0, 0)

        xcb_u32(b, 2147483700)     // LC_DYLD_CHAINED_FIXUPS
        xcb_u32(b, 16)
        xcb_u32(b, linkeditOff)
        xcb_u32(b, cfLen)

        xcb_u32(b, 2)              // LC_SYMTAB
        xcb_u32(b, 24)
        xcb_u32(b, symoff)
        xcb_u32(b, 0)
        xcb_u32(b, symoff)
        xcb_u32(b, strsize)

        xcb_u32(b, 11)             // LC_DYSYMTAB
        xcb_u32(b, 80)
        xcb_zeros(b, 72)

        xcb_u32(b, 14)             // LC_LOAD_DYLINKER
        xcb_u32(b, 32)
        xcb_u32(b, 12)
        xcb_ascii(b, "/usr/lib/dyld")
        xcb_u8(b, 0)
        xcb_zeros(b, 6)

        xcb_u32(b, 12)             // LC_LOAD_DYLIB
        xcb_u32(b, 56)
        xcb_u32(b, 24)
        xcb_u32(b, 2)
        xcb_u32(b, 89063424)
        xcb_u32(b, 65536)
        xcb_ascii(b, "/usr/lib/libSystem.B.dylib")
        xcb_u8(b, 0)
        xcb_zeros(b, 5)

        if hasRuntime {            // LC_LOAD_DYLIB #2: the runtime (ordinal 2)
            xcb_u32(b, 12)
            xcb_u32(b, rtCmdSize)
            xcb_u32(b, 24)         // name offset
            xcb_u32(b, 2)          // timestamp
            xcb_u32(b, 65536)      // current version
            xcb_u32(b, 65536)      // compatibility version
            xcb_ascii(b, runtimePath)
            xcb_u8(b, 0)
            xcb_zeros(b, rtCmdSize - 24 - string_len(runtimePath) - 1)
        }

        xcb_u32(b, 50)             // LC_BUILD_VERSION
        xcb_u32(b, 24)
        xcb_u32(b, 1)
        xcb_u32(b, 1769472)
        xcb_u32(b, 1769472)
        xcb_u32(b, 0)

        xcb_u32(b, 27)             // LC_UUID
        xcb_u32(b, 24)
        xcb_ascii(b, "XiNativeBackend")
        xcb_u8(b, 0)

        xcb_u32(b, 2147483688)     // LC_MAIN
        xcb_u32(b, 24)
        xcb_u64(b, entryoff)
        xcb_u64(b, 0)

        xcb_u32(b, 29)             // LC_CODE_SIGNATURE
        xcb_u32(b, 16)
        xcb_u32(b, codesigOff)
        xcb_u32(b, codesigSize)

        // ── __TEXT body ──
        xcb_zeros(b, codeOff - xcb_len(b))
        for w in code { xcb_u32(b, w) }

        // ── __DATA_CONST: __got bind pointers ──
        if hasImports {
            xcb_zeros(b, dataOff - xcb_len(b))
            let g = 0
            while g < nImports {
                let next = 0
                if g < nImports - 1 { next = 2 }              // 8-byte stride = 2 (4-byte units)
                xcb_u32(b, g)                                 // low32: import ordinal
                xcb_u32(b, 2147483648 + next * 524288)        // high32: bind bit + next
                g = g + 1
            }
        }
        xcb_zeros(b, linkeditOff - xcb_len(b))

        // ── chained fixups ──
        if hasImports {
            let importsOff = 28 + (4 + 4 * 4 + 24)
            let symbolsOff = importsOff + nImports * 4
            xcb_u32(b, 0)                 // version
            xcb_u32(b, 28)                // starts_offset
            xcb_u32(b, importsOff)
            xcb_u32(b, symbolsOff)
            xcb_u32(b, nImports)          // imports_count
            xcb_u32(b, 1)                 // imports_format (DYLD_CHAINED_IMPORT)
            xcb_u32(b, 0)                 // symbols_format
            // starts_in_image: 4 segments, __DATA_CONST (index 2) has the fixups
            xcb_u32(b, 4)
            xcb_u32(b, 0)
            xcb_u32(b, 0)
            xcb_u32(b, 20)                // seg[2] offset (4 + 4*4)
            xcb_u32(b, 0)
            // starts_in_segment (__DATA_CONST)
            xcb_u32(b, 24)                // size
            xcb_u8(b, 0)  xcb_u8(b, 64)   // page_size 0x4000
            xcb_u8(b, 6)  xcb_u8(b, 0)    // pointer_format 6 (PTR_64_OFFSET)
            xcb_u64(b, dataOff)           // segment_offset
            xcb_u32(b, 0)                 // max_valid_pointer
            xcb_u8(b, 1)  xcb_u8(b, 0)    // page_count 1
            xcb_u8(b, 0)  xcb_u8(b, 0)    // page_start[0] 0
            // imports
            let mm = 0
            let nameOff = 1
            while mm < nImports {
                let ord = 1                                          // libSystem
                if stringArrGet(importSyms, mm).startsWith2("_xstd_") { ord = 2 }  // runtime dylib
                xcb_u32(b, ord + nameOff * 512)   // lib_ordinal | name_off<<9
                nameOff = nameOff + string_len(stringArrGet(importSyms, mm)) + 1
                mm = mm + 1
            }
            // symbols pool
            xcb_u8(b, 0)
            let mn = 0
            while mn < nImports {
                xcb_ascii(b, stringArrGet(importSyms, mn))
                xcb_u8(b, 0)
                mn = mn + 1
            }
            xcb_zeros(b, (linkeditOff + cfLen) - xcb_len(b))
        } else {
            xcb_u32(b, 0)              // version
            xcb_u32(b, 28)             // starts_offset
            xcb_u32(b, 44)             // imports_offset
            xcb_u32(b, 44)             // symbols_offset
            xcb_u32(b, 0)              // imports_count
            xcb_u32(b, 1)              // imports_format
            xcb_u32(b, 0)              // symbols_format
            xcb_u32(b, 3)              // seg_count
            xcb_u32(b, 0)
            xcb_u32(b, 0)
            xcb_u32(b, 0)
            xcb_u8(b, 0)
            xcb_zeros(b, 3)
        }

        // ── empty symbol + string table ──
        xcb_zeros(b, strsize)

        // ── pad to the signature ──
        xcb_zeros(b, codesigOff - xcb_len(b))

        // ── embedded ad-hoc signature (SuperBlob + CodeDirectory), all big-endian ──
        xcb_u32be(b, 4208856256)   // CSMAGIC_EMBEDDED_SIGNATURE (0xfade0cc0)
        xcb_u32be(b, codesigSize)
        xcb_u32be(b, 1)            // blob count
        xcb_u32be(b, 0)            // slot 0: CSSLOT_CODEDIRECTORY
        xcb_u32be(b, 20)           // offset to the CodeDirectory

        xcb_u32be(b, 4208856066)   // CSMAGIC_CODEDIRECTORY (0xfade0c02)
        xcb_u32be(b, cdTotal)      // length
        xcb_u32be(b, 132096)       // version 0x20400
        xcb_u32be(b, 2)            // flags: adhoc
        xcb_u32be(b, hashOff)      // hashOffset
        xcb_u32be(b, 88)           // identOffset
        xcb_u32be(b, 0)            // nSpecialSlots
        xcb_u32be(b, nCode)        // nCodeSlots
        xcb_u32be(b, codeLimit)    // codeLimit
        xcb_u8(b, 32)             // hashSize (SHA-256)
        xcb_u8(b, 2)              // hashType
        xcb_u8(b, 0)              // platform
        xcb_u8(b, 12)             // pageSize log2 (4096)
        xcb_u32be(b, 0)            // spare2
        xcb_u32be(b, 0)            // scatterOffset
        xcb_u32be(b, 0)            // teamOffset
        xcb_u32be(b, 0)            // spare3
        xcb_u64be(b, 0)            // codeLimit64
        xcb_u64be(b, 0)            // execSegBase
        xcb_u64be(b, textFilesize) // execSegLimit
        xcb_u64be(b, 1)            // execSegFlags: CS_EXECSEG_MAIN_BINARY
        xcb_ascii(b, ident)
        xcb_u8(b, 0)

        // code-slot hashes over [0, codeLimit), the final page hashed as-is
        let i = 0
        while i < nCode {
            let from = i * 4096
            let to = from + 4096
            if to > codeLimit { to = codeLimit }
            xcb_sha256_append(b, from, to)
            i = i + 1
        }

        return xcb_write_exec(b, binPath) == 0
    }
}
