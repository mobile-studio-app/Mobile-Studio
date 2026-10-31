//! Rewrites a macOS ARM64 program so iOS's dyld loads it as a library in DuoCode's process.
//!
//! - An executable becomes a dylib: its file type changes, __PAGEZERO shrinks to one page
//!   (a 4 GB reservation would fail inside an app), and it gets an LC_ID_DYLIB.
//! - The platform becomes iOS, and macOS framework paths (X.framework/Versions/A/X) become
//!   iOS ones (X.framework/X).
//! - Every library and symbol it imports becomes weak, so something iOS lacks (FSEvents,
//!   AppKit) doesn't stop it loading; DuoCode points those at a function that reports it.
//! - The address and name of every symbol it imports are listed, for DuoCode to redirect the
//!   ones a program in an app can't have to itself (exit, stdin/stdout, its arguments...).

use std::fmt;

const MH_MAGIC_64: u32 = 0xfeed_facf;
const FAT_MAGIC: u32 = 0xcafe_babe;
const FAT_MAGIC_64: u32 = 0xcafe_babf;
const CPU_TYPE_ARM64: u32 = 0x0100_000c;
const CPU_TYPE_X86_64: u32 = 0x0100_0007;
const CPU_SUBTYPE_ARM64E: u32 = 2;

const MH_EXECUTE: u32 = 2;
const MH_DYLIB: u32 = 6;
const MH_BUNDLE: u32 = 8;
const MH_PIE: u32 = 0x0020_0000;
const MH_NO_REEXPORTED_DYLIBS: u32 = 0x0010_0000;

const LC_SEGMENT_64: u32 = 0x19;
const LC_LOAD_DYLIB: u32 = 0xc;
const LC_ID_DYLIB: u32 = 0xd;
const LC_LOAD_DYLINKER: u32 = 0xe;
const LC_LOAD_WEAK_DYLIB: u32 = 0x8000_0018;
const LC_REEXPORT_DYLIB: u32 = 0x8000_001f;
const LC_LAZY_LOAD_DYLIB: u32 = 0x20;
const LC_LOAD_UPWARD_DYLIB: u32 = 0x8000_0023;
const LC_MAIN: u32 = 0x8000_0028;
const LC_BUILD_VERSION: u32 = 0x32;
const LC_VERSION_MIN_MACOSX: u32 = 0x24;
const LC_VERSION_MIN_IPHONEOS: u32 = 0x25;
const LC_CODE_SIGNATURE: u32 = 0x1d;
const LC_DYLD_INFO: u32 = 0x22;
const LC_DYLD_INFO_ONLY: u32 = 0x8000_0022;
const LC_DYLD_CHAINED_FIXUPS: u32 = 0x8000_0034;

const PLATFORM_MACOS: u32 = 1;
const PLATFORM_IOS: u32 = 2;
const IOS_14: u32 = 14 << 16;
const IOS_17: u32 = 17 << 16;

const LIBSYSTEM: &str = "/usr/lib/libSystem.B.dylib";

#[derive(Debug)]
pub struct Error(pub String);

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str(&self.0)
    }
}

fn fail<T>(message: impl Into<String>) -> Result<T, Error> {
    Err(Error(message.into()))
}

/// A symbol the program imports, at `offset` from the start of its image.
#[derive(Debug, Clone, PartialEq)]
pub struct Import {
    pub offset: u64,
    pub name: String,
    pub library: String,
    /// It was weak to begin with: the program copes with it missing.
    pub weak: bool,
}

#[derive(Debug)]
pub struct Prepared {
    pub data: Vec<u8>,
    /// main()'s offset from the start of the image (executables only).
    pub entry: Option<u64>,
    pub imports: Vec<Import>,
    /// Libraries it loads that aren't part of iOS (ones shipped beside it).
    pub own_libraries: Vec<String>,
}

impl Prepared {
    /// What DuoCode's loader reads: "entry <hex>", "library <path>" for each library it ships
    /// with, then "import <hex> <w|s> <symbol> <library>" lines (w: weak to begin with).
    pub fn describe(&self) -> String {
        let mut out = String::new();
        if let Some(entry) = self.entry {
            out += &format!("entry {entry:x}\n");
        }
        for library in &self.own_libraries {
            out += &format!("library {library}\n");
        }
        for import in &self.imports {
            out += &format!("import {:x} {} {} {}\n", import.offset, if import.weak { "w" } else { "s" }, import.name, import.library);
        }
        out
    }
}

fn u16_at(data: &[u8], at: usize) -> Result<u16, Error> {
    data.get(at..at + 2).map(|b| u16::from_le_bytes([b[0], b[1]])).ok_or_else(|| Error("The program is cut short.".into()))
}

fn u32_at(data: &[u8], at: usize) -> Result<u32, Error> {
    data.get(at..at + 4).map(|b| u32::from_le_bytes(b.try_into().unwrap())).ok_or_else(|| Error("The program is cut short.".into()))
}

fn u64_at(data: &[u8], at: usize) -> Result<u64, Error> {
    data.get(at..at + 8).map(|b| u64::from_le_bytes(b.try_into().unwrap())).ok_or_else(|| Error("The program is cut short.".into()))
}

fn be32_at(data: &[u8], at: usize) -> Result<u32, Error> {
    data.get(at..at + 4).map(|b| u32::from_be_bytes(b.try_into().unwrap())).ok_or_else(|| Error("The program is cut short.".into()))
}

fn be64_at(data: &[u8], at: usize) -> Result<u64, Error> {
    data.get(at..at + 8).map(|b| u64::from_be_bytes(b.try_into().unwrap())).ok_or_else(|| Error("The program is cut short.".into()))
}

fn put32(data: &mut [u8], at: usize, value: u32) {
    data[at..at + 4].copy_from_slice(&value.to_le_bytes());
}

fn put64(data: &mut [u8], at: usize, value: u64) {
    data[at..at + 8].copy_from_slice(&value.to_le_bytes());
}

fn c_string(data: &[u8], at: usize) -> Result<String, Error> {
    let rest = data.get(at..).ok_or_else(|| Error("A name points outside the program.".into()))?;
    let end = rest.iter().position(|&b| b == 0).unwrap_or(rest.len());
    Ok(String::from_utf8_lossy(&rest[..end]).into_owned())
}

/// The ARM64 Mach-O in `data` (picked out of a universal binary), or why there isn't one.
pub fn arm64_slice(data: &[u8]) -> Result<Vec<u8>, Error> {
    if data.len() < 32 {
        return fail("It isn't a program.");
    }
    let be = be32_at(data, 0)?;
    if be == FAT_MAGIC || be == FAT_MAGIC_64 {
        let count = be32_at(data, 4)? as usize;
        // Java class files share the magic number; they'd have a huge "count".
        if count > 0 && count < 32 {
            let wide = be == FAT_MAGIC_64;
            let stride = if wide { 32 } else { 20 };
            let mut found = None;
            for i in 0..count {
                let at = 8 + i * stride;
                let cpu = be32_at(data, at)?;
                let subtype = be32_at(data, at + 4)? & 0x00ff_ffff;
                let (offset, size) = if wide {
                    (be64_at(data, at + 8)? as usize, be64_at(data, at + 16)? as usize)
                } else {
                    (be32_at(data, at + 8)? as usize, be32_at(data, at + 12)? as usize)
                };
                if cpu == CPU_TYPE_ARM64 && subtype != CPU_SUBTYPE_ARM64E {
                    found = Some((offset, size));
                }
            }
            let Some((offset, size)) = found else {
                return fail("It has no ARM64 version (it's built only for Intel Macs).");
            };
            let slice = data.get(offset..offset + size).ok_or_else(|| Error("The program is cut short.".into()))?;
            return arm64_slice(slice);
        }
    }
    match u32_at(data, 0)? {
        MH_MAGIC_64 => match u32_at(data, 4)? {
            CPU_TYPE_ARM64 if u32_at(data, 8)? & 0x00ff_ffff == CPU_SUBTYPE_ARM64E => fail("It's built for arm64e, which only Apple's own code can use."),
            CPU_TYPE_ARM64 => Ok(data.to_vec()),
            CPU_TYPE_X86_64 => fail("It's built only for Intel Macs."),
            _ => fail("It's built for a processor iPhones don't have."),
        },
        0xfeed_face => fail("It's a 32-bit program."),
        _ if data.starts_with(b"\x7fELF") => fail("It's a Linux program, not a macOS one."),
        _ if data.starts_with(b"MZ") => fail("It's a Windows program, not a macOS one."),
        _ if data.starts_with(b"#!") => fail("It's a script, not a program."),
        _ => fail("It isn't a macOS program."),
    }
}

/// /System/Library/Frameworks/X.framework/Versions/A/X -> /System/Library/Frameworks/X.framework/X
fn ios_library_path(path: &str) -> String {
    if let Some(at) = path.find(".framework/Versions/") {
        let after = &path[at + ".framework/Versions/".len()..];
        if let Some(slash) = after.find('/') {
            return format!("{}.framework/{}", &path[..at], &after[slash + 1..]);
        }
    }
    path.to_string()
}

fn is_system_library(path: &str) -> bool {
    path.starts_with("/usr/lib/") || path.starts_with("/System/")
}

struct Segment {
    name: String,
    vmaddr: u64,
    fileoff: u64,
    filesize: u64,
}

fn read_uleb(data: &[u8], at: &mut usize) -> Result<u64, Error> {
    let mut value = 0u64;
    let mut shift = 0;
    loop {
        let byte = *data.get(*at).ok_or_else(|| Error("The program's symbol table is cut short.".into()))?;
        *at += 1;
        if shift < 64 {
            value |= ((byte & 0x7f) as u64) << shift;
        }
        shift += 7;
        if byte & 0x80 == 0 {
            return Ok(value);
        }
    }
}

fn read_sleb(data: &[u8], at: &mut usize) -> Result<i64, Error> {
    let mut value = 0i64;
    let mut shift = 0;
    loop {
        let byte = *data.get(*at).ok_or_else(|| Error("The program's symbol table is cut short.".into()))?;
        *at += 1;
        if shift < 64 {
            value |= ((byte & 0x7f) as i64) << shift;
        }
        shift += 7;
        if byte & 0x80 == 0 {
            if shift < 64 && byte & 0x40 != 0 {
                value |= -1i64 << shift;
            }
            return Ok(value);
        }
    }
}

fn library_name(libraries: &[String], ordinal: i64) -> String {
    match ordinal {
        0 => "self".into(),
        -1 => "main".into(),
        -2 | -3 => "flat".into(),
        n if n > 0 => libraries.get(n as usize - 1).cloned().unwrap_or_else(|| "?".into()),
        _ => "?".into(),
    }
}

/// Binds in classic dyld info (bind and lazy bind opcodes). Marks each symbol weak.
fn dyld_info_binds(data: &mut [u8], start: usize, size: usize, segments: &[Segment], base: u64,
                   libraries: &[String], imports: &mut Vec<Import>) -> Result<(), Error> {
    let end = start.checked_add(size).filter(|&e| e <= data.len()).ok_or_else(|| Error("The program's symbol table is outside it.".into()))?;
    let mut at = start;
    let mut ordinal: i64 = 0;
    let mut name = String::new();
    let mut weak = false;
    let mut segment = 0usize;
    let mut offset = 0u64;
    let mut record = |segment: usize, offset: u64, name: &str, ordinal: i64, weak: bool| -> Result<(), Error> {
        let seg = segments.get(segment).ok_or_else(|| Error("A symbol refers to a missing segment.".into()))?;
        imports.push(Import { offset: seg.vmaddr.wrapping_add(offset).wrapping_sub(base), name: name.to_string(), library: library_name(libraries, ordinal), weak });
        Ok(())
    };
    while at < end {
        let byte = data[at];
        at += 1;
        let immediate = byte & 0x0f;
        match byte & 0xf0 {
            0x00 => {} // DONE (lazy binds separate entries with it)
            0x10 => ordinal = immediate as i64,
            0x20 => ordinal = read_uleb(data, &mut at)? as i64,
            0x30 => ordinal = if immediate == 0 { 0 } else { (0xf0 | immediate) as i8 as i64 },
            0x40 => {
                // SET_SYMBOL_TRAILING_FLAGS_IMM: the flags live in this byte. 0x1 = weak import.
                weak = byte & 0x01 != 0;
                data[at - 1] = byte | 0x01;
                name = c_string(data, at)?;
                at += name.len() + 1;
            }
            0x50 => {}
            0x60 => { read_sleb(data, &mut at)?; }
            0x70 => {
                segment = immediate as usize;
                offset = read_uleb(data, &mut at)?;
            }
            0x80 => offset = offset.wrapping_add(read_uleb(data, &mut at)?),
            0x90 => {
                record(segment, offset, &name, ordinal, weak)?;
                offset = offset.wrapping_add(8);
            }
            0xa0 => {
                record(segment, offset, &name, ordinal, weak)?;
                offset = offset.wrapping_add(8).wrapping_add(read_uleb(data, &mut at)?);
            }
            0xb0 => {
                record(segment, offset, &name, ordinal, weak)?;
                offset = offset.wrapping_add(8 + immediate as u64 * 8);
            }
            0xc0 => {
                let count = read_uleb(data, &mut at)?;
                let skip = read_uleb(data, &mut at)?;
                for _ in 0..count.min(1 << 24) {
                    record(segment, offset, &name, ordinal, weak)?;
                    offset = offset.wrapping_add(8).wrapping_add(skip);
                }
            }
            _ => return fail(format!("It uses a kind of symbol binding DuoCode doesn't know (0x{byte:02x}).")),
        }
    }
    Ok(())
}

/// Binds in chained fixups (newer linkers). Marks each import weak.
fn chained_binds(data: &mut [u8], start: usize, segments: &[Segment], base: u64,
                 libraries: &[String], imports: &mut Vec<Import>) -> Result<(), Error> {
    let starts_offset = u32_at(data, start + 4)? as usize;
    let imports_offset = u32_at(data, start + 8)? as usize;
    let symbols_offset = u32_at(data, start + 12)? as usize;
    let count = u32_at(data, start + 16)? as usize;
    let format = u32_at(data, start + 20)?;
    if u32_at(data, start + 24)? != 0 {
        return fail("Its symbol names are compressed, which DuoCode can't read.");
    }
    // The import table: (library ordinal, name) per import, and the weak bit set on each.
    let mut table = Vec::with_capacity(count);
    for i in 0..count {
        let (ordinal, name_offset, weak) = match format {
            1 | 2 => {
                let at = start + imports_offset + i * if format == 1 { 4 } else { 8 };
                let value = u32_at(data, at)?;
                put32(data, at, value | 0x100);
                ((value & 0xff) as u8 as i8 as i64, (value >> 9) as usize, value & 0x100 != 0)
            }
            3 => {
                let at = start + imports_offset + i * 16;
                let value = u64_at(data, at)?;
                put64(data, at, value | 0x1_0000);
                ((value & 0xffff) as u16 as i16 as i64, (value >> 32) as usize, value & 0x1_0000 != 0)
            }
            _ => return fail(format!("It uses an import format DuoCode doesn't know ({format}).")),
        };
        table.push((ordinal, c_string(data, start + symbols_offset + name_offset)?, weak));
    }
    // Walk the chains to find where each import is used.
    let image = start + starts_offset;
    let segment_count = u32_at(data, image)? as usize;
    for s in 0..segment_count {
        let info = u32_at(data, image + 4 + s * 4)? as usize;
        if info == 0 {
            continue;
        }
        let at = image + info;
        let page_size = u16_at(data, at + 4)? as u64;
        let pointer_format = u16_at(data, at + 6)?;
        let page_count = u16_at(data, at + 20)? as usize;
        if pointer_format != 2 && pointer_format != 6 {
            return fail(format!("It uses a pointer format DuoCode doesn't know ({pointer_format})."));
        }
        let segment = segments.get(s).ok_or_else(|| Error("A fixup refers to a missing segment.".into()))?;
        for page in 0..page_count {
            let page_start = u16_at(data, at + 22 + page * 2)?;
            if page_start == 0xffff {
                continue;
            }
            let mut offset = page as u64 * page_size + page_start as u64;
            loop {
                let file_at = (segment.fileoff + offset) as usize;
                if offset >= segment.filesize {
                    return fail("A fixup chain runs off its segment.");
                }
                let value = u64_at(data, file_at)?;
                if value >> 63 == 1 {
                    let index = (value & 0xff_ffff) as usize;
                    let (ordinal, name, weak) = table.get(index).ok_or_else(|| Error("A fixup names a missing import.".into()))?;
                    imports.push(Import { offset: segment.vmaddr + offset - base, name: name.clone(), library: library_name(libraries, *ordinal), weak: *weak });
                }
                let next = (value >> 51) & 0xfff;
                if next == 0 {
                    break;
                }
                offset += next * 4;
            }
        }
    }
    Ok(())
}

/// Prepares an ARM64 Mach-O (a program, dylib or bundle) for loading in DuoCode. `id_name`
/// names the library an executable becomes; keep it short (7 characters always fit).
pub fn prepare(mut data: Vec<u8>, id_name: &str) -> Result<Prepared, Error> {
    if u32_at(&data, 0)? != MH_MAGIC_64 {
        return fail("It isn't a 64-bit macOS program.");
    }
    let filetype = u32_at(&data, 12)?;
    if filetype != MH_EXECUTE && filetype != MH_DYLIB && filetype != MH_BUNDLE {
        return fail("It isn't a program or a library.");
    }
    let ncmds = u32_at(&data, 16)? as usize;
    let sizeofcmds = u32_at(&data, 20)? as usize;
    if 32 + sizeofcmds > data.len() {
        return fail("Its header is cut short.");
    }

    let mut segments = Vec::new();
    let mut libraries = Vec::new();
    let mut own_libraries = Vec::new();
    let mut entry = None;
    let mut first_section = usize::MAX;
    let mut page_zero = None;
    let mut dylinker = None;
    let mut has_signature = false;
    let mut has_id = false;
    let mut dyld_info = None;
    let mut chained = None;

    let mut at = 32;
    for _ in 0..ncmds {
        let cmd = u32_at(&data, at)?;
        let size = u32_at(&data, at + 4)? as usize;
        if size < 8 || at + size > 32 + sizeofcmds {
            return fail("Its load commands are damaged.");
        }
        match cmd {
            LC_SEGMENT_64 => {
                let name = c_string(&data[at + 8..at + 24], 0)?;
                let vmaddr = u64_at(&data, at + 24)?;
                let fileoff = u64_at(&data, at + 40)?;
                let filesize = u64_at(&data, at + 48)?;
                let nsects = u32_at(&data, at + 64)? as usize;
                for s in 0..nsects {
                    let section = at + 72 + s * 80;
                    let offset = u32_at(&data, section + 48)? as usize;
                    let flags = u32_at(&data, section + 64)?;
                    // Zero-fill sections take no file space.
                    if offset > 0 && !matches!(flags & 0xff, 0x1 | 0xc | 0x12) {
                        first_section = first_section.min(offset);
                    }
                }
                if name == "__PAGEZERO" && vmaddr == 0 {
                    page_zero = Some(at);
                }
                segments.push(Segment { name, vmaddr, fileoff, filesize });
            }
            LC_LOAD_DYLIB | LC_LOAD_WEAK_DYLIB | LC_REEXPORT_DYLIB | LC_LAZY_LOAD_DYLIB | LC_LOAD_UPWARD_DYLIB => {
                let name_at = at + u32_at(&data, at + 8)? as usize;
                let path = c_string(&data[..at + size], name_at)?;
                let ios = ios_library_path(&path);
                if ios != path {
                    let room = at + size - name_at;
                    data[name_at..at + size].fill(0);
                    data[name_at..name_at + ios.len().min(room - 1)].copy_from_slice(&ios.as_bytes()[..ios.len().min(room - 1)]);
                }
                // Weak: a library iOS doesn't have leaves its symbols empty instead of failing.
                if cmd == LC_LOAD_DYLIB && ios != LIBSYSTEM {
                    put32(&mut data, at, LC_LOAD_WEAK_DYLIB);
                }
                if !is_system_library(&ios) {
                    own_libraries.push(ios.clone());
                }
                libraries.push(ios);
            }
            LC_ID_DYLIB => has_id = true,
            LC_LOAD_DYLINKER => dylinker = Some((at, size)),
            LC_MAIN => entry = Some(u64_at(&data, at + 8)?),
            LC_BUILD_VERSION => {
                if u32_at(&data, at + 8)? == PLATFORM_MACOS {
                    put32(&mut data, at + 8, PLATFORM_IOS);
                    put32(&mut data, at + 12, IOS_14);
                    put32(&mut data, at + 16, IOS_17);
                }
            }
            LC_VERSION_MIN_MACOSX => {
                put32(&mut data, at, LC_VERSION_MIN_IPHONEOS);
                put32(&mut data, at + 8, IOS_14);
                put32(&mut data, at + 12, IOS_17);
            }
            LC_CODE_SIGNATURE => has_signature = true,
            LC_DYLD_INFO | LC_DYLD_INFO_ONLY => dyld_info = Some(at),
            LC_DYLD_CHAINED_FIXUPS => chained = Some(u32_at(&data, at + 8)? as usize),
            _ => {}
        }
        at += size;
    }

    let base = segments.iter().find(|s| s.name == "__TEXT").map(|s| s.vmaddr)
        .ok_or_else(|| Error("It has no code segment.".into()))?;

    let mut imports = Vec::new();
    if let Some(info) = dyld_info {
        for (offset_at, size_at) in [(16, 20), (32, 36)] {
            let start = u32_at(&data, info + offset_at)? as usize;
            let size = u32_at(&data, info + size_at)? as usize;
            if size > 0 {
                dyld_info_binds(&mut data, start, size, &segments, base, &libraries, &mut imports)?;
            }
        }
    }
    if let Some(start) = chained {
        chained_binds(&mut data, start, &segments, base, &libraries, &mut imports)?;
    }

    if filetype == MH_EXECUTE {
        // One page of __PAGEZERO, just below the code, instead of 4 GB from address 0.
        if let Some(seg) = page_zero {
            put64(&mut data, seg + 24, base - 0x4000);
            put64(&mut data, seg + 32, 0x4000);
        }
        let flags = u32_at(&data, 24)?;
        put32(&mut data, 12, MH_DYLIB);
        put32(&mut data, 24, (flags | MH_NO_REEXPORTED_DYLIBS) & !MH_PIE);

        if !has_id {
            let end = 32 + sizeofcmds;
            // The signer needs room for LC_CODE_SIGNATURE if there isn't one.
            let free = first_section.saturating_sub(end).saturating_sub(if has_signature { 0 } else { 16 });
            let name = id_name.as_bytes();
            let size = 24 + (name.len() + 1).div_ceil(8) * 8;
            let command_at = if size <= free {
                put32(&mut data, 16, ncmds as u32 + 1);
                put32(&mut data, 20, (sizeofcmds + size) as u32);
                Some((end, size))
            } else {
                // No room: LC_LOAD_DYLINKER's space is unused in a library.
                dylinker
            };
            let Some((command, size)) = command_at else {
                return fail("There's no room in its header to make it a library.");
            };
            data[command..command + size].fill(0);
            put32(&mut data, command, LC_ID_DYLIB);
            put32(&mut data, command + 4, size as u32);
            put32(&mut data, command + 8, 24);
            put32(&mut data, command + 12, 2);
            put32(&mut data, command + 16, 0x10000);
            put32(&mut data, command + 20, 0x10000);
            let room = size - 24 - 1;
            let length = name.len().min(room);
            data[command + 24..command + 24 + length].copy_from_slice(&name[..length]);
        }
    }

    Ok(Prepared { data, entry, imports, own_libraries })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn framework_paths() {
        assert_eq!(ios_library_path("/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation"),
                   "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation");
        assert_eq!(ios_library_path("/usr/lib/libSystem.B.dylib"), "/usr/lib/libSystem.B.dylib");
    }

    #[test]
    fn leb() {
        let data = [0xe5, 0x8e, 0x26];
        let mut at = 0;
        assert_eq!(read_uleb(&data, &mut at).unwrap(), 624485);
        let data = [0xc0, 0xbb, 0x78];
        let mut at = 0;
        assert_eq!(read_sleb(&data, &mut at).unwrap(), -123456);
    }
}
