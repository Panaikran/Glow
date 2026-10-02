import struct

MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
MH_OBJECT = 1
MH_EXECUTE = 2

LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
LC_DYSYMTAB = 0xB
LC_CODE_SIGNATURE = 0x1D
LC_MAIN = 0x80000028
LC_ROUTINES_64 = 0x1A
LC_RPATH = 0x8000001C
LC_DYLIB_COMMANDS = {
    0xC,          # LC_LOAD_DYLIB
    0x18 | 0x80000000,  # LC_LOAD_WEAK_DYLIB
    0x1F | 0x80000000,  # LC_REEXPORT_DYLIB
    0x20,         # LC_LAZY_LOAD_DYLIB
    0x23 | 0x80000000,  # LC_LOAD_UPWARD_DYLIB
}

SECTION_TYPE = 0xFF
S_INIT_FUNC_OFFSETS = 0x16
S_ZEROFILL = 0x1
S_GB_ZEROFILL = 0xC
S_THREAD_LOCAL_ZEROFILL = 0x12
ZERO_FILL_TYPES = {S_ZEROFILL, S_GB_ZEROFILL, S_THREAD_LOCAL_ZEROFILL}


def cstr(raw):
    return raw.split(b"\0", 1)[0].decode("ascii", "strict")


def parse_macho(data):
    if len(data) < 32:
        raise ValueError("truncated Mach-O header")
    magic, cpu, subtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from(
        "<8I", data, 0
    )
    if magic != MH_MAGIC_64:
        raise ValueError("expected a little-endian 64-bit Mach-O")
    command_end = 32 + sizeofcmds
    if command_end > len(data):
        raise ValueError("load-command area extends beyond the file")

    commands = []
    segments = []
    sections = []
    position = 32
    for _ in range(ncmds):
        if position + 8 > command_end:
            raise ValueError("truncated load command")
        command, command_size = struct.unpack_from("<II", data, position)
        if command_size < 8 or command_size & 7 or position + command_size > command_end:
            raise ValueError("invalid 64-bit load-command size")
        raw = bytes(data[position:position + command_size])
        item = {"cmd": command, "size": command_size, "pos": position, "raw": raw}

        if command == LC_SEGMENT_64:
            if command_size < 72:
                raise ValueError("truncated LC_SEGMENT_64")
            name, vmaddr, vmsize, fileoff, filesize, maxprot, initprot, nsects, segflags = \
                struct.unpack_from("<16sQQQQiiII", raw, 8)
            minimum_size = 72 + nsects * 80
            if minimum_size != command_size:
                raise ValueError("LC_SEGMENT_64 section table size is inconsistent")
            segment = {
                "name": cstr(name), "vm": vmaddr, "vmsize": vmsize,
                "fileoff": fileoff, "filesize": filesize,
                "maxprot": maxprot, "initprot": initprot,
                "nsects": nsects, "flags": segflags, "raw": raw,
                "command": item,
            }
            item["segment"] = segment
            segments.append(segment)
            for index in range(nsects):
                offset = 72 + index * 80
                (sectname, segname, address, size, file_offset, align,
                 reloff, nreloc, section_flags, reserved1, reserved2, reserved3) = \
                    struct.unpack_from("<16s16sQQIIIIIIII", raw, offset)
                section = {
                    "name": cstr(sectname), "segment": cstr(segname),
                    "addr": address, "size": size, "offset": file_offset,
                    "align": align, "reloff": reloff, "nreloc": nreloc,
                    "flags": section_flags, "raw": raw[offset:offset + 80],
                    "segment_info": segment,
                }
                segment.setdefault("sections", []).append(section)
                sections.append(section)

        elif command in LC_DYLIB_COMMANDS:
            if command_size < 24:
                raise ValueError("truncated dylib load command")
            name_offset = struct.unpack_from("<I", raw, 8)[0]
            item["path"] = command_string(raw, name_offset)
        elif command == LC_RPATH:
            if command_size < 12:
                raise ValueError("truncated LC_RPATH")
            name_offset = struct.unpack_from("<I", raw, 8)[0]
            item["path"] = command_string(raw, name_offset)

        commands.append(item)
        position += command_size

    if position != command_end:
        raise ValueError("ncmds and sizeofcmds do not agree")
    return {
        "cpu": cpu, "subtype": subtype, "filetype": filetype,
        "ncmds": ncmds, "sizeofcmds": sizeofcmds, "flags": flags,
        "reserved": reserved, "command_end": command_end,
        "commands": commands, "segments": segments, "sections": sections,
    }


def command_string(raw, offset):
    if offset < 8 or offset >= len(raw):
        raise ValueError("load-command string offset is outside the command")
    end = raw.find(b"\0", offset)
    if end < 0:
        raise ValueError("unterminated load-command string")
    return cstr(raw[offset:end])


def unique(items, label):
    if len(items) != 1:
        raise ValueError(f"expected one {label}, found {len(items)}")
    return items[0]


def sections_named(meta, segment_name, section_name):
    return [section for section in meta["sections"]
            if section["segment"] == segment_name and section["name"] == section_name]


def section_data(data, section):
    section_type = section["flags"] & SECTION_TYPE
    if section_type in ZERO_FILL_TYPES:
        return b""
    start, end = section["offset"], section["offset"] + section["size"]
    if start < 0 or end < start or end > len(data):
        raise ValueError(f"section {section['segment']},{section['name']} is outside the file")
    return data[start:end]


def dylib_loads(meta):
    return [command for command in meta["commands"] if command["cmd"] in LC_DYLIB_COMMANDS]


def is_zero_fill(section):
    return (section["flags"] & SECTION_TYPE) in ZERO_FILL_TYPES
