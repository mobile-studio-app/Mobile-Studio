#!/usr/bin/env python3
"""Zeroes the file offset of zero-fill sections in a Mach-O binary (thin or fat).

Old toolchains left a non-zero offset on zero-fill sections such as __DATA,__thread_bss.
Newer dyld (iOS 27) refuses to load such a binary ("has a zero-fill section type, but offset
field is not zero"). The offset is meaningless for zero-fill sections, so zeroing it is safe.
The binary must be signed again afterwards (sideloading does that).

usage: patch-zerofill-offsets.py <binary>
"""
import struct
import sys

LC_SEGMENT_64 = 0x19
ZEROFILL_TYPES = {0x1, 0xC, 0x12}   # S_ZEROFILL, S_GB_ZEROFILL, S_THREAD_LOCAL_ZEROFILL


def patch_thin(data, base):
    magic = struct.unpack_from('<I', data, base)[0]
    if magic != 0xFEEDFACF:
        raise SystemExit(f'not a 64-bit little-endian Mach-O at {base:#x} (magic {magic:#x})')
    ncmds = struct.unpack_from('<I', data, base + 16)[0]
    offset = base + 32
    patched = 0
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from('<II', data, offset)
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from('<I', data, offset + 64)[0]
            section = offset + 72
            for _ in range(nsects):
                name = data[section:section + 16].rstrip(b'\0').decode()
                file_offset = struct.unpack_from('<I', data, section + 48)[0]
                flags = struct.unpack_from('<I', data, section + 64)[0]
                if (flags & 0xFF) in ZEROFILL_TYPES and file_offset != 0:
                    struct.pack_into('<I', data, section + 48, 0)
                    print(f'  {name}: offset {file_offset:#x} -> 0')
                    patched += 1
                section += 80
        offset += cmdsize
    return patched


def main(path):
    with open(path, 'rb') as f:
        data = bytearray(f.read())
    magic = struct.unpack_from('>I', data, 0)[0]
    if magic in (0xCAFEBABE, 0xCAFEBABF):
        count = struct.unpack_from('>I', data, 4)[0]
        wide = magic == 0xCAFEBABF
        patched = 0
        for i in range(count):
            entry = 8 + i * (32 if wide else 20)
            arch_offset = struct.unpack_from('>Q' if wide else '>I', data, entry + 8)[0]
            patched += patch_thin(data, arch_offset)
    else:
        patched = patch_thin(data, 0)
    with open(path, 'wb') as f:
        f.write(data)
    print(f'{path}: {patched} section(s) patched')


if __name__ == '__main__':
    main(sys.argv[1])
