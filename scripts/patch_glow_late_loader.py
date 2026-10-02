#!/usr/bin/env python3
import hashlib
import json
import struct
import sys

from glow_macho import (
    CPU_TYPE_ARM64, LC_CODE_SIGNATURE, LC_DYSYMTAB, LC_MAIN, LC_ROUTINES_64,
    LC_SEGMENT_64, LC_SYMTAB, MH_EXECUTE, MH_OBJECT, S_INIT_FUNC_OFFSETS,
    SECTION_TYPE, dylib_loads, is_zero_fill, parse_macho,
    section_data, sections_named, unique,
)

N_TYPE = 0x0E
N_UNDF = 0x00
N_SECT = 0x0E
VM_PROT_EXECUTE = 0x4
S_ATTR_SOME_INSTRUCTIONS = 0x00000400
SECTION_RECORD_SIZE = 80
HEADER_SIZE = 32
SEGMENT_HEADER_SIZE = 72
INITIALIZER_SIZE = 4
CODE_ALIGNMENT = 16
INIT_ALIGNMENT = 4
RTLD_FORBIDDEN = (
    "GlowCompat", "InertControl", "NoStartup", "LateLoader", "Bootstrap",
    "Diagnostic", "Helper", "TestControl",
)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def align(value, alignment):
    return (value + alignment - 1) & ~(alignment - 1)


def parse_symbols(data, command):
    symoff, nsyms, stroff, strsize = struct.unpack_from("<4I", command["raw"], 8)
    if symoff + nsyms * 16 > len(data) or stroff + strsize > len(data):
        raise ValueError("symbol table extends beyond the object file")
    symbols = []
    for index in range(nsyms):
        strx, ntype, section_index, desc, value = struct.unpack_from("<IBBHQ", data, symoff + index * 16)
        if strx >= strsize:
            name = ""
        else:
            end = data.find(b"\0", stroff + strx, stroff + strsize)
            if end < 0:
                raise ValueError("unterminated symbol name")
            name = data[stroff + strx:end].decode("ascii", "strict")
        symbols.append({"name": name, "type": ntype, "section": section_index,
                        "desc": desc, "value": value})
    return symbols


def object_loader(obj):
    meta = parse_macho(obj)
    if meta["cpu"] != CPU_TYPE_ARM64 or meta["filetype"] != MH_OBJECT:
        raise ValueError("loader input must be a thin arm64 MH_OBJECT")
    code = unique(sections_named(meta, "__TEXT", "__glow_code"), "loader __glow_code section")
    if code["flags"] & SECTION_TYPE != 0 or not code["flags"] & S_ATTR_SOME_INSTRUCTIONS:
        raise ValueError("loader code section has unexpected section attributes")
    if not code["size"] or code["nreloc"] == 0:
        raise ValueError("loader code or relocations are missing")
    if code["reloff"] + code["nreloc"] * 8 > len(obj):
        raise ValueError("loader relocation table extends beyond the object")
    if any(section["name"] == "__mod_init_func" for section in meta["sections"]):
        raise ValueError("loader object unexpectedly contains static initializers")
    if any(section is not code and section["size"] and not is_zero_fill(section)
           for section in meta["sections"]):
        raise ValueError("loader object has additional file-backed sections")

    symbols = parse_symbols(obj, unique([c for c in meta["commands"] if c["cmd"] == LC_SYMTAB], "LC_SYMTAB"))
    dysym = unique([c for c in meta["commands"] if c["cmd"] == LC_DYSYMTAB], "LC_DYSYMTAB")
    (ilocalsym, nlocalsym, iextdefsym, nextdefsym, iundefsym, nundefsym,
     tocoff, ntoc, modtaboff, nmodtab, extrefsymoff, nextrefsyms,
     indirectsymoff, nindirectsyms, extreloff, nextrel, locreloff, nlocrel) = \
        struct.unpack_from("<18I", dysym["raw"], 8)
    undefined = sorted(symbol["name"] for symbol in symbols
                       if symbol["type"] & N_TYPE == N_UNDF and symbol["name"])
    if undefined != ["_dlsym"]:
        raise ValueError(f"loader must have only _dlsym undefined; found {undefined}")
    init_symbols = [symbol for symbol in symbols if symbol["name"] == "_glow_late_initializer"]
    initializer = unique(init_symbols, "glow_late_initializer symbol")
    if initializer["type"] & N_TYPE != N_SECT or initializer["section"] < 1 or \
            initializer["section"] > len(meta["sections"]):
        raise ValueError("loader initializer is not a defined section symbol")
    if meta["sections"][initializer["section"] - 1] is not code:
        raise ValueError("loader initializer is outside __glow_code")
    function_offset = initializer["value"] - code["addr"]
    if function_offset < 0 or function_offset + 4 > code["size"] or function_offset & 3:
        raise ValueError("loader initializer address is invalid or unaligned")

    indirect_end = indirectsymoff + nindirectsyms * 4
    if indirect_end > len(obj):
        raise ValueError("indirect symbol table extends beyond the object")
    indirect = struct.unpack_from(f"<{nindirectsyms}I", obj, indirectsymoff) if nindirectsyms else ()
    relocations = []
    blob = bytearray(section_data(obj, code))
    for index in range(code["nreloc"]):
        address, info = struct.unpack_from("<iI", obj, code["reloff"] + index * 8)
        symbol_index = info & 0x00FFFFFF
        pcrel = (info >> 24) & 1
        length = (info >> 25) & 3
        external = (info >> 27) & 1
        kind = (info >> 28) & 0xF
        if kind not in (2, 3, 4) or length != 2 or not external or \
                address < 0 or address + 4 > len(blob) or symbol_index >= len(symbols):
            raise ValueError(f"unsupported loader relocation at {address:#x} ({info:#x})")
        target = symbols[symbol_index]
        if (kind in (2, 3) and pcrel != 1) or (kind == 4 and pcrel != 0):
            raise ValueError(f"invalid PC-relative bit for loader relocation {kind}")
        if target["type"] & N_TYPE == N_SECT:
            if target["section"] < 1 or target["section"] > len(meta["sections"]) or \
                    meta["sections"][target["section"] - 1] is not code:
                raise ValueError(f"loader relocation leaves __glow_code: {target['name']}")
        elif target["name"] != "_dlsym" or kind != 2:
            raise ValueError(f"unexpected unresolved loader symbol: {target['name']}")
        relocations.append({"address": address, "kind": kind, "target": target})

    if not any(r["kind"] == 2 and r["target"]["name"] == "_dlsym" for r in relocations):
        raise ValueError("loader must call dlsym through Facebook's existing stub")
    for relocation in relocations:
        if relocation["kind"] == 3 and not any(
                other["kind"] == 4 and other["target"]["name"] == relocation["target"]["name"] and
                other["address"] == relocation["address"] + 4 for other in relocations):
            raise ValueError(f"unpaired PAGE21 relocation for {relocation['target']['name']}")
    return meta, code, bytes(blob), function_offset, symbols, relocations


def find_symbol_stub(data, meta, wanted_name):
    symtab = unique([c for c in meta["commands"] if c["cmd"] == LC_SYMTAB], "LC_SYMTAB")
    dysym = unique([c for c in meta["commands"] if c["cmd"] == LC_DYSYMTAB], "LC_DYSYMTAB")
    symbols = parse_symbols(data, symtab)
    fields = struct.unpack_from("<18I", dysym["raw"], 8)
    indirect_offset, indirect_count = fields[12], fields[13]
    if indirect_offset + indirect_count * 4 > len(data):
        raise ValueError("indirect symbol table extends beyond the executable")
    indirect = struct.unpack_from(f"<{indirect_count}I", data, indirect_offset) if indirect_count else ()
    for section in meta["sections"]:
        if section["segment"] != "__TEXT" or section["name"] != "__stubs":
            continue
        reserved1, stride = struct.unpack_from("<II", section["raw"], 68)
        if stride == 0 or reserved1 + section["size"] // stride > len(indirect):
            raise ValueError("invalid __stubs indirect-symbol range")
        for index in range(section["size"] // stride):
            symbol_index = indirect[reserved1 + index]
            if symbol_index & 0x80000000:
                continue
            if symbol_index >= len(symbols):
                raise ValueError("__stubs refers to an invalid symbol index")
            if symbols[symbol_index]["name"] == wanted_name:
                return section["addr"] + index * stride
    raise ValueError(f"Facebook executable has no {wanted_name} stub")


def validate_launch_dependencies(meta):
    loads = dylib_loads(meta)
    glow = [command for command in loads if command["path"] == "@rpath/Glow.dylib"]
    if len(glow) != 1:
        raise ValueError(f"expected exactly one @rpath/Glow.dylib load command, found {len(glow)}")
    for command in loads:
        path = command["path"]
        if "GlowCompat" in path:
            raise ValueError("GlowCompat must not be a Facebook launch-time dependency")
        if any(token in path for token in RTLD_FORBIDDEN):
            raise ValueError(f"forbidden helper/diagnostic load command: {path}")


def named_section(meta, name):
    return unique(sections_named(meta, "__TEXT", name), f"__TEXT,{name}")


def make_section(name, address, size, file_offset, align_exponent, flags):
    if len(name.encode("ascii")) > 16:
        raise ValueError(f"Mach-O section name is too long: {name}")
    raw = struct.pack("<16s16sQQIIIIIIII", name.encode().ljust(16, b"\0"),
                      b"__TEXT", address, size, file_offset, align_exponent,
                      0, 0, flags, 0, 0, 0)
    if len(raw) != SECTION_RECORD_SIZE:
        raise ValueError("section_64 record construction failed")
    return raw


def find_text_and_code_space(data, meta, text):
    text_end = text["fileoff"] + text["filesize"]
    if text_end > len(data) or text["fileoff"] > text_end:
        raise ValueError("__TEXT file mapping extends beyond the executable")
    if text["initprot"] & VM_PROT_EXECUTE == 0 or text["maxprot"] & VM_PROT_EXECUTE == 0:
        raise ValueError("__TEXT is not mapped as executable")
    if text["vmsize"] < text["filesize"]:
        raise ValueError("__TEXT virtual mapping is smaller than its file mapping")

    text_sections = [section for section in text["sections"] if section["size"] and not is_zero_fill(section)]
    if not text_sections:
        raise ValueError("__TEXT has no file-backed sections")
    last_section_end = max(section["offset"] + section["size"] for section in text_sections)
    for section in text_sections:
        start, end = section["offset"], section["offset"] + section["size"]
        if start < text["fileoff"] or end > text_end:
            raise ValueError(f"__TEXT section {section['name']} lies outside its segment")
        expected_vm = text["vm"] + start - text["fileoff"]
        if section["addr"] != expected_vm:
            raise ValueError(f"__TEXT section {section['name']} has an inconsistent VM/file mapping")

    tail_start = align(last_section_end, CODE_ALIGNMENT)
    return text_end, last_section_end, tail_start


def check_header_slack(data, meta, added_bytes):
    file_sections = [section for section in meta["sections"]
                     if section["size"] and not is_zero_fill(section) and section["offset"]]
    if not file_sections:
        raise ValueError("no file-backed sections found for header slack validation")
    first_section = min(section["offset"] for section in file_sections)
    command_end = meta["command_end"]
    if first_section < command_end or any(data[command_end:first_section]):
        raise ValueError("load-command padding before the first section is not verified zero space")
    slack = first_section - command_end
    if slack < added_bytes:
        raise ValueError(f"insufficient Mach-O header slack: need {added_bytes}, have {slack}")
    return first_section, slack


def compare_original_sections(before_data, before_meta, after_data, after_meta):
    before_segments = [segment for segment in before_meta["segments"]]
    after_segments = [segment for segment in after_meta["segments"]]
    if len(before_segments) != len(after_segments):
        raise ValueError("segment count changed")
    for before, after in zip(before_segments, after_segments):
        if before["name"] != after["name"]:
            raise ValueError("segment order changed")
        old_sections = before.get("sections", [])
        new_sections = after.get("sections", [])
        if len(new_sections) < len(old_sections):
            raise ValueError("an existing section was removed")
        if any(old["raw"] != new["raw"] for old, new in zip(old_sections, new_sections)):
            raise ValueError(f"an existing section record changed in {before['name']}")
        for old in old_sections:
            if section_data(before_data, old) != section_data(after_data, old):
                raise ValueError(f"existing section bytes changed: {old['segment']},{old['name']}")


def patch_bytes(original, obj):
    meta = parse_macho(original)
    if meta["cpu"] != CPU_TYPE_ARM64 or meta["filetype"] != MH_EXECUTE or not meta["flags"] & 0x200000:
        raise ValueError("target must be an arm64 PIE executable")
    if any(command["cmd"] == LC_ROUTINES_64 for command in meta["commands"]):
        raise ValueError("target contains LC_ROUTINES_64; refusing ambiguous initializer setup")
    if len(sections_named(meta, "__TEXT", "__glow_code")) or len(sections_named(meta, "__TEXT", "__glow_init")):
        raise ValueError("target already contains Glow late-loader sections; refusing to double-patch")
    validate_launch_dependencies(meta)
    unique([c for c in meta["commands"] if c["cmd"] == LC_CODE_SIGNATURE], "LC_CODE_SIGNATURE")
    if "@executable_path/Frameworks" not in [c.get("path") for c in meta["commands"]]:
        raise ValueError("target lacks the expected @executable_path/Frameworks runpath")
    for section in meta["sections"]:
        section_data(original, section)
    main_command = unique([c for c in meta["commands"] if c["cmd"] == LC_MAIN], "LC_MAIN")
    text_command = unique([c for c in meta["commands"] if c["cmd"] == LC_SEGMENT_64 and c["raw"][8:24].split(b"\0", 1)[0] == b"__TEXT"], "__TEXT segment")
    text = text_command["segment"]
    if text_command["size"] != SEGMENT_HEADER_SIZE + text["nsects"] * SECTION_RECORD_SIZE:
        raise ValueError("__TEXT segment command has unexpected trailing bytes")
    if text["fileoff"] != 0:
        raise ValueError("unsupported __TEXT mapping: fileoff must be zero for this loader format")
    if len(sections_named(meta, "__TEXT", "__init_offsets")) != 1:
        raise ValueError("expected one original __TEXT,__init_offsets section")
    original_init = named_section(meta, "__init_offsets")
    original_gcc = named_section(meta, "__gcc_except_tab")
    original_text = named_section(meta, "__text")
    if original_init["flags"] & SECTION_TYPE != S_INIT_FUNC_OFFSETS or \
            original_init["size"] == 0 or original_init["size"] % INITIALIZER_SIZE:
        raise ValueError("existing __init_offsets section has an unexpected type or size")
    if original_init["offset"] + original_init["size"] > len(original):
        raise ValueError("original initializer table extends beyond the executable")
    first_section, header_slack = check_header_slack(original, meta, SECTION_RECORD_SIZE * 2)
    text_end, last_section_end, code_offset = find_text_and_code_space(original, meta, text)
    loader_meta, loader_section, code_blob, initializer_offset, symbols, relocations = object_loader(obj)
    init_offset = align(code_offset + len(code_blob), INIT_ALIGNMENT)
    end_offset = init_offset + INITIALIZER_SIZE
    if end_offset > text_end or end_offset > text["fileoff"] + text["vmsize"]:
        raise ValueError("verified executable __TEXT tail is too small for the loader")
    if any(original[code_offset:end_offset]):
        raise ValueError("selected __TEXT tail contains non-zero data")

    code_vm = text["vm"] + code_offset - text["fileoff"]
    init_vm = text["vm"] + init_offset - text["fileoff"]
    function_vm = code_vm + initializer_offset
    preferred_base = text["vm"] - text["fileoff"]
    init_value = function_vm - preferred_base
    if init_value < 0 or init_value > 0xFFFFFFFF or init_value & 3:
        raise ValueError("initializer target cannot be represented as a uint32 image-relative offset")

    resolved_stubs = {}
    resolved_targets = {}
    relocated_code = bytearray(code_blob)
    for relocation in relocations:
        address, kind, target = relocation["address"], relocation["kind"], relocation["target"]
        target_name = target["name"]
        place = code_vm + address
        target_is_section = target["type"] & N_TYPE == N_SECT
        target_offset = target["value"] - loader_section["addr"]
        if target_is_section and not 0 <= target_offset < loader_section["size"]:
            raise ValueError(f"loader symbol is outside __glow_code: {target_name}")

        if kind == 2:
            target_address = (find_symbol_stub(original, meta, target_name)
                              if not target_is_section else code_vm + target_offset)
            delta = target_address - place
            if delta & 3 or not -(1 << 27) <= delta < (1 << 27):
                raise ValueError(f"ARM64 branch target is out of range: {target_name}")
            word = struct.unpack_from("<I", relocated_code, address)[0]
            if word & 0x7C000000 != 0x14000000:
                raise ValueError(f"branch relocation is not a B/BL instruction: {word:#x}")
            word = (word & 0xFC000000) | ((delta >> 2) & 0x03FFFFFF)
            struct.pack_into("<I", relocated_code, address, word)
            resolved_targets[address] = target_address
            if not target_is_section:
                resolved_stubs[target_name] = target_address
        elif kind == 3:
            if not target_is_section:
                raise ValueError("PAGE21 relocation has an external target")
            target_address = code_vm + target_offset
            word = struct.unpack_from("<I", relocated_code, address)[0]
            if word & 0x9F000000 != 0x90000000:
                raise ValueError(f"PAGE21 relocation is not ADRP: {word:#x}")
            if ((word >> 29) & 3) | (((word >> 5) & 0x7FFFF) << 2):
                raise ValueError("PAGE21 relocation has an unsupported addend")
            page_delta = ((target_address & ~0xFFF) - (place & ~0xFFF)) >> 12
            if not -(1 << 20) <= page_delta < (1 << 20):
                raise ValueError(f"PAGE21 target is out of range: {target_name}")
            immediate = page_delta & 0x1FFFFF
            word &= ~0x60FFFFE0
            word |= ((immediate & 3) << 29) | (((immediate >> 2) & 0x7FFFF) << 5)
            struct.pack_into("<I", relocated_code, address, word)
            resolved_targets[address] = target_address
        else:
            if not target_is_section:
                raise ValueError("PAGEOFF12 relocation has an external target")
            target_address = code_vm + target_offset
            word = struct.unpack_from("<I", relocated_code, address)[0]
            if word & 0x7F000000 != 0x11000000 or word & 0x00400000:
                raise ValueError(f"PAGEOFF12 relocation is not an unshifted ADD: {word:#x}")
            if word >> 10 & 0xFFF:
                raise ValueError("PAGEOFF12 relocation has an unsupported addend")
            word = (word & ~0x003FFC00) | ((target_address & 0xFFF) << 10)
            struct.pack_into("<I", relocated_code, address, word)
            resolved_targets[address] = target_address

    code_record = make_section("__glow_code", code_vm, len(relocated_code), code_offset, 2,
                               S_ATTR_SOME_INSTRUCTIONS)
    # S_INIT_FUNC_OFFSETS is recognized by section type; the unique name avoids modifying the original table.
    init_record = make_section("__glow_init", init_vm, INITIALIZER_SIZE, init_offset, 2,
                               S_INIT_FUNC_OFFSETS)
    new_commands = []
    for command in meta["commands"]:
        raw = command["raw"]
        if command is text_command:
            raw = bytearray(raw)
            raw.extend(code_record)
            raw.extend(init_record)
            struct.pack_into("<I", raw, 4, len(raw))
            struct.pack_into("<I", raw, 64, text["nsects"] + 2)
            raw = bytes(raw)
        new_commands.append(raw)
    command_bytes = b"".join(new_commands)
    new_sizeofcmds = meta["sizeofcmds"] + SECTION_RECORD_SIZE * 2
    if len(command_bytes) != new_sizeofcmds:
        raise ValueError("expanded load-command size is inconsistent")
    new_command_end = HEADER_SIZE + len(command_bytes)
    if new_command_end > first_section:
        raise ValueError("expanded load commands would overlap the first file-backed section")

    patched = bytearray(original)
    patched[HEADER_SIZE:new_command_end] = command_bytes
    struct.pack_into("<I", patched, 20, new_sizeofcmds)
    patched[code_offset:code_offset + len(relocated_code)] = relocated_code
    struct.pack_into("<I", patched, init_offset, init_value)
    patched = bytes(patched)

    final_meta = parse_macho(patched)
    if final_meta["ncmds"] != meta["ncmds"] or final_meta["sizeofcmds"] != new_sizeofcmds:
        raise ValueError("Mach-O header command counts changed unexpectedly")
    if next(c["raw"] for c in final_meta["commands"] if c["cmd"] == LC_MAIN) != main_command["raw"]:
        raise ValueError("LC_MAIN entrypoint changed")
    for before, after in zip(meta["commands"], final_meta["commands"]):
        if before is text_command:
            old_prefix = bytearray(before["raw"])
            new_prefix = bytearray(after["raw"][:len(before["raw"])])
            struct.pack_into("<I", old_prefix, 4, 0)
            struct.pack_into("<I", new_prefix, 4, 0)
            struct.pack_into("<I", old_prefix, 64, 0)
            struct.pack_into("<I", new_prefix, 64, 0)
            if old_prefix != new_prefix or len(after["raw"]) != len(before["raw"]) + 160:
                raise ValueError("pre-existing __TEXT segment fields changed")
        elif before["raw"] != after["raw"]:
            raise ValueError("a pre-existing load command changed")
    compare_original_sections(original, meta, patched, final_meta)

    final_code = unique(sections_named(final_meta, "__TEXT", "__glow_code"), "new __glow_code")
    final_init = unique(sections_named(final_meta, "__TEXT", "__glow_init"), "new __glow_init")
    if (final_code["addr"], final_code["offset"], final_code["size"], final_code["flags"]) != \
            (code_vm, code_offset, len(relocated_code), S_ATTR_SOME_INSTRUCTIONS):
        raise ValueError("new __glow_code section is malformed")
    if (final_init["addr"], final_init["offset"], final_init["size"], final_init["flags"]) != \
            (init_vm, init_offset, INITIALIZER_SIZE, S_INIT_FUNC_OFFSETS):
        raise ValueError("new __glow_init section is malformed")
    if struct.unpack_from("<I", patched, init_offset)[0] != init_value or \
            preferred_base + init_value != function_vm or \
            not code_vm <= function_vm < code_vm + len(relocated_code):
        raise ValueError("new initializer offset does not resolve into __glow_code")

    report = {
        "architecture": "arm64",
        "input_sha256": sha256(original),
        "patched_sha256_before_signing": sha256(patched),
        "preferred_base": hex(preferred_base),
        "ncmds": meta["ncmds"],
        "sizeofcmds_before": meta["sizeofcmds"],
        "sizeofcmds_after": new_sizeofcmds,
        "text_vmaddr": hex(text["vm"]),
        "text_filesize": hex(text["filesize"]),
        "text_vmsize": hex(text["vmsize"]),
        "original_text_sections": text["nsects"],
        "header_slack_bytes": header_slack,
        "header_slack_used_bytes": 160,
        "first_file_section_offset": hex(first_section),
        "text_last_section_end": hex(last_section_end),
        "text_zero_tail_bytes": text_end - last_section_end,
        "glow_code": {"vm": hex(code_vm), "fileoff": hex(code_offset),
                      "size": hex(len(relocated_code)), "flags": hex(S_ATTR_SOME_INSTRUCTIONS)},
        "glow_init": {"vm": hex(init_vm), "fileoff": hex(init_offset),
                      "size": INITIALIZER_SIZE, "flags": hex(S_INIT_FUNC_OFFSETS),
                      "raw_uint32": hex(init_value), "target_vm": hex(function_vm)},
        "original_initializer_count": original_init["size"] // INITIALIZER_SIZE,
        "original_initializer_sha256": sha256(section_data(original, original_init)),
        "gcc_except_tab_sha256": sha256(section_data(original, original_gcc)),
        "facebook_text_sha256": sha256(section_data(original, original_text)),
        "original_section_records_preserved": True,
        "original_load_commands_preserved": True,
        "resolved_stubs": {name: hex(address) for name, address in resolved_stubs.items()},
        "relocation_counts": {str(kind): sum(r["kind"] == kind for r in relocations)
                               for kind in (2, 3, 4)},
        "verification": "PASS",
    }
    return patched, report


def patch(input_path, object_path, output_path):
    with open(input_path, "rb") as source:
        original = source.read()
    with open(object_path, "rb") as source:
        obj = source.read()
    patched, report = patch_bytes(original, obj)
    with open(output_path, "xb") as output:
        output.write(patched)
    report["output"] = output_path
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("usage: patch_glow_late_loader.py Facebook-executable GlowLateLoader.o output-executable")
    try:
        patch(*sys.argv[1:])
    except (OSError, ValueError, StopIteration, struct.error) as error:
        raise SystemExit(f"Glow late-loader patch failed closed: {error}")
