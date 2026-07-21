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
    // Assemble the encoded module into an executable at binPath. True on success.
    producer write(m: EncodedModule, binPath: String) -> Bool
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

class MachoWriter implements ObjectWriter {
    deps {}

    mapper formatName() -> String => "mach-o"

    producer write(m: EncodedModule, binPath: String) -> Bool {
        // The single entry function's code words (milestone: one function).
        let code: Integer[] = []
        for f in m.funcs { code = f.code }

        let vmbase = 4294967296                // 0x100000000
        let sizeofcmds = 592                   // fixed for the 12 load commands below
        let codeOff = alignUp(32 + sizeofcmds, 4)   // 624
        let textFilesize = 16384               // one 16 KB page
        let entryoff = codeOff
        let linkeditOff = 16384

        // __LINKEDIT contents: chained-fixups blob, empty sym/str table, signature.
        let cfLen = 48
        let symoff = linkeditOff + cfLen
        let strsize = 8
        let codesigOff = alignUp(symoff + strsize, 16)
        let codeLimit = codesigOff
        let nCode = (codeLimit + 4095) / 4096

        // CodeDirectory sizing.
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
        xcb_u32(b, 4277009103)     // MH_MAGIC_64 (0xFEEDFACF)
        xcb_u32(b, 16777228)       // CPU_TYPE_ARM64 (0x0100000C)
        xcb_u32(b, 0)              // cpusubtype
        xcb_u32(b, 2)              // MH_EXECUTE
        xcb_u32(b, 12)             // ncmds
        xcb_u32(b, sizeofcmds)
        xcb_u32(b, 2097285)        // NOUNDEFS|DYLDLINK|TWOLEVEL|PIE (0x00200085)
        xcb_u32(b, 0)              // reserved

        // ── load commands ──
        emitSeg(b, "__PAGEZERO", 72, 0, vmbase, 0, 0, 0, 0, 0, 0)
        emitSeg(b, "__TEXT", 152, vmbase, textFilesize, 0, textFilesize, 5, 5, 1, 0)
        emitSect(b, "__text", "__TEXT", vmbase + codeOff, 8, codeOff, 2, 2147484672)  // S_ATTR_PURE/SOME_INSTRUCTIONS
        emitSeg(b, "__LINKEDIT", 72, vmbase + linkeditOff, linkeditVmsize, linkeditOff, linkeditFilesize, 1, 1, 0, 0)

        xcb_u32(b, 2147483700)     // LC_DYLD_CHAINED_FIXUPS (0x80000034)
        xcb_u32(b, 16)
        xcb_u32(b, linkeditOff)    // dataoff
        xcb_u32(b, cfLen)          // datasize

        xcb_u32(b, 2)              // LC_SYMTAB
        xcb_u32(b, 24)
        xcb_u32(b, symoff)
        xcb_u32(b, 0)              // nsyms
        xcb_u32(b, symoff)         // stroff
        xcb_u32(b, strsize)

        xcb_u32(b, 11)             // LC_DYSYMTAB
        xcb_u32(b, 80)
        xcb_zeros(b, 72)           // all index/count fields zero

        xcb_u32(b, 14)             // LC_LOAD_DYLINKER
        xcb_u32(b, 32)
        xcb_u32(b, 12)             // name offset
        xcb_ascii(b, "/usr/lib/dyld")
        xcb_u8(b, 0)
        xcb_zeros(b, 6)            // pad 26 -> 32

        xcb_u32(b, 12)             // LC_LOAD_DYLIB
        xcb_u32(b, 56)
        xcb_u32(b, 24)             // name offset
        xcb_u32(b, 2)              // timestamp
        xcb_u32(b, 89063424)       // current version 1359.0.0 (1359<<16)
        xcb_u32(b, 65536)          // compatibility 1.0.0 (1<<16)
        xcb_ascii(b, "/usr/lib/libSystem.B.dylib")
        xcb_u8(b, 0)
        xcb_zeros(b, 5)            // pad 51 -> 56

        xcb_u32(b, 50)             // LC_BUILD_VERSION
        xcb_u32(b, 24)
        xcb_u32(b, 1)              // platform macOS
        xcb_u32(b, 1769472)        // minos 27.0 (27<<16)
        xcb_u32(b, 1769472)        // sdk 27.0
        xcb_u32(b, 0)              // ntools

        xcb_u32(b, 27)             // LC_UUID
        xcb_u32(b, 24)
        xcb_ascii(b, "XiNativeBackend")   // 15 bytes ...
        xcb_u8(b, 0)                        // ... + NUL = 16

        xcb_u32(b, 2147483688)     // LC_MAIN (0x80000028)
        xcb_u32(b, 24)
        xcb_u64(b, entryoff)
        xcb_u64(b, 0)              // stacksize

        xcb_u32(b, 29)             // LC_CODE_SIGNATURE
        xcb_u32(b, 16)
        xcb_u32(b, codesigOff)
        xcb_u32(b, codesigSize)

        // ── __TEXT body: pad to the entry, emit code, pad to __LINKEDIT ──
        xcb_zeros(b, codeOff - xcb_len(b))
        for w in code { xcb_u32(b, w) }
        xcb_zeros(b, linkeditOff - xcb_len(b))

        // ── chained fixups: header + starts_in_image (3 segs, no fixups) + empty symbols ──
        xcb_u32(b, 0)              // fixups_version
        xcb_u32(b, 28)             // starts_offset
        xcb_u32(b, 44)             // imports_offset
        xcb_u32(b, 44)             // symbols_offset
        xcb_u32(b, 0)              // imports_count
        xcb_u32(b, 1)              // imports_format (DYLD_CHAINED_IMPORT)
        xcb_u32(b, 0)              // symbols_format
        xcb_u32(b, 3)              // seg_count
        xcb_u32(b, 0)
        xcb_u32(b, 0)
        xcb_u32(b, 0)
        xcb_u8(b, 0)              // empty symbol pool (leading NUL)
        xcb_zeros(b, 3)           // pad 45 -> 48

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
