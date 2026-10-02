#!/usr/bin/env python3
import hashlib
import json
import plistlib
import struct
import sys
import zipfile

from glow_macho import (
    CPU_TYPE_ARM64, LC_CODE_SIGNATURE, LC_DYLIB_COMMANDS, LC_MAIN,
    LC_ROUTINES_64, LC_SEGMENT_64, LC_RPATH, MH_EXECUTE,
    S_INIT_FUNC_OFFSETS, SECTION_TYPE, dylib_loads, is_zero_fill,
    parse_macho, section_data, sections_named, unique,
)

VM_PROT_EXECUTE = 0x4
S_ATTR_SOME_INSTRUCTIONS = 0x400
FORBIDDEN_ARTIFACTS = (
    "GlowCompat_NoStartup", "InertControl", "GlowNavDiagnostics",
    "GlowLateLoader.dylib", "LateLoader.dylib", "Bootstrap.dylib",
    "Diagnostic", "Helper", "TestControl",
)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def verify_launch_dependencies(meta):
    loads = dylib_loads(meta)
    glow = [command for command in loads if command["path"] == "@rpath/Glow.dylib"]
    compat = [command for command in loads if "GlowCompat.dylib" in command["path"]]
    if len(glow) != 1:
        raise ValueError(f"expected exactly one Glow load command, found {len(glow)}")
    if compat:
        raise ValueError("Facebook must not launch-load GlowCompat")
    for command in loads:
        if any(token in command["path"] for token in FORBIDDEN_ARTIFACTS):
            raise ValueError(f"forbidden helper or diagnostic load command: {command['path']}")
    return loads


def app_paths(names):
    return sorted({name.split("/", 2)[1] for name in names
                   if name.startswith("Payload/") and name.count("/") >= 2 and
                   name.split("/", 2)[1].endswith(".app")})


def archive_member(archive, app, relative):
    path = f"Payload/{app}/{relative}"
    matches = [name for name in archive.namelist() if name == path]
    return unique(matches, f"archive member {path}")


def app_binary(archive, app, relative):
    member = archive_member(archive, app, relative)
    return member, archive.read(member)


def verify_signed_arm64(data, label):
    meta = parse_macho(data)
    if meta["cpu"] != CPU_TYPE_ARM64:
        raise ValueError(f"{label} is not arm64")
    unique([command for command in meta["commands"] if command["cmd"] == LC_CODE_SIGNATURE],
           f"{label} LC_CODE_SIGNATURE")
    return meta


def verify_header_slack(base_data, base, final_data, final):
    file_sections = [section for section in base["sections"] if section["size"] and not is_zero_fill(section)
                     and section["offset"]]
    if not file_sections:
        raise ValueError("baseline has no file-backed sections")
    first_section = min(section["offset"] for section in file_sections)
    if first_section - base["command_end"] < 160 or any(base_data[base["command_end"]:first_section]):
        raise ValueError("baseline does not have verified header slack for two section records")
    if final["command_end"] > first_section or any(final_data[final["command_end"]:first_section]):
        raise ValueError("patched load commands exceed or corrupt verified header slack")


def verify_loader_sections(data, meta, baseline):
    code = unique(sections_named(meta, "__TEXT", "__glow_code"), "__glow_code")
    init = unique(sections_named(meta, "__TEXT", "__glow_init"), "__glow_init")
    text = unique([segment for segment in meta["segments"] if segment["name"] == "__TEXT"], "__TEXT")
    preferred_base = text["vm"] - text["fileoff"]
    if text["initprot"] & VM_PROT_EXECUTE == 0 or text["maxprot"] & VM_PROT_EXECUTE == 0:
        raise ValueError("__TEXT is not executable")
    if not code["size"] or code["flags"] & S_ATTR_SOME_INSTRUCTIONS == 0:
        raise ValueError("__glow_code is empty or not marked as instructions")
    if code["offset"] < text["fileoff"] or code["offset"] + code["size"] > text["fileoff"] + text["filesize"]:
        raise ValueError("__glow_code lies outside mapped/file-backed __TEXT")
    if code["addr"] != text["vm"] + code["offset"] - text["fileoff"]:
        raise ValueError("__glow_code VM/file mapping is inconsistent")
    if init["size"] != 4 or init["flags"] & SECTION_TYPE != S_INIT_FUNC_OFFSETS:
        raise ValueError("__glow_init must be one S_INIT_FUNC_OFFSETS uint32 entry")
    if init["offset"] & 3 or init["addr"] != text["vm"] + init["offset"] - text["fileoff"]:
        raise ValueError("__glow_init mapping or alignment is invalid")
    if init["offset"] + init["size"] > text["fileoff"] + text["filesize"]:
        raise ValueError("__glow_init lies outside mapped/file-backed __TEXT")
    initializer_offset = struct.unpack_from("<I", data, init["offset"])[0]
    initializer_vm = preferred_base + initializer_offset
    if initializer_vm & 3 or not code["addr"] <= initializer_vm < code["addr"] + code["size"]:
        raise ValueError("initializer offset does not resolve into __glow_code")
    if code["offset"] + code["size"] > init["offset"] or \
            any(data[code["offset"] + code["size"]:init["offset"]]):
        raise ValueError("Glow code/init sections overlap or contain unexpected padding")

    old_text_sections = [section for section in baseline["sections"]
                         if section["segment"] == "__TEXT" and section["size"] and not is_zero_fill(section)]
    if not old_text_sections:
        raise ValueError("baseline __TEXT has no file-backed sections")
    old_text_end = max(section["offset"] + section["size"] for section in old_text_sections)
    aligned_end = (old_text_end + 15) & ~15
    if code["offset"] < aligned_end or any(data[old_text_end:code["offset"]]):
        raise ValueError("__glow_code overlaps existing content or uses non-zero __TEXT padding")
    original_init = unique(sections_named(meta, "__TEXT", "__init_offsets"), "original __init_offsets")
    if not original_init["size"] or original_init["size"] % 4:
        raise ValueError("original __init_offsets table is malformed")
    return {
        "code": code,
        "init": init,
        "text": text,
        "initializer_offset": initializer_offset,
        "initializer_vm": initializer_vm,
        "preferred_base": preferred_base,
        "original_init": original_init,
        "original_init_count": original_init["size"] // 4,
    }


def verify_main_executable(final_data, baseline_data):
    baseline = parse_macho(baseline_data)
    if baseline["cpu"] != CPU_TYPE_ARM64 or baseline["filetype"] != MH_EXECUTE:
        raise ValueError("baseline executable is not arm64 MH_EXECUTE")
    verify_launch_dependencies(baseline)
    if any(section["name"] in ("__glow_code", "__glow_init") for section in baseline["sections"]):
        raise ValueError("baseline executable is already patched")
    meta = verify_signed_arm64(final_data, "Facebook executable")
    compare_presigned_executable(baseline_data, baseline, final_data, meta)
    loads = verify_launch_dependencies(meta)
    if any(command["cmd"] == LC_ROUTINES_64 for command in meta["commands"]):
        raise ValueError("LC_ROUTINES_64 is not allowed")
    loader = verify_loader_sections(final_data, meta, baseline)
    if "@executable_path/Frameworks" not in [command["path"] for command in meta["commands"]
                                             if command["cmd"] == LC_RPATH]:
        raise ValueError("@executable_path/Frameworks rpath is missing")
    return meta, loads, loader, baseline


def compare_presigned_executable(base_data, base, final_data, final):
    if base["cpu"] != final["cpu"] or base["filetype"] != final["filetype"] or \
            base["ncmds"] != final["ncmds"] or final["sizeofcmds"] != base["sizeofcmds"] + 160:
        raise ValueError("main Mach-O header changed beyond the two section records")
    old_text = unique([segment for segment in base["segments"] if segment["name"] == "__TEXT"], "base __TEXT")
    new_text = unique([segment for segment in final["segments"] if segment["name"] == "__TEXT"], "final __TEXT")
    if new_text["nsects"] != old_text["nsects"] + 2 or len(new_text["raw"]) != len(old_text["raw"]) + 160:
        raise ValueError("__TEXT section count or command size does not match the patch")
    old_text_header = bytearray(old_text["raw"][:72])
    new_text_header = bytearray(new_text["raw"][:72])
    struct.pack_into("<I", old_text_header, 4, 0)
    struct.pack_into("<I", new_text_header, 4, 0)
    struct.pack_into("<I", old_text_header, 64, 0)
    struct.pack_into("<I", new_text_header, 64, 0)
    if old_text_header != new_text_header:
        raise ValueError("__TEXT segment mapping/protection fields changed")
    verify_header_slack(base_data, base, final_data, final)

    if len(base["segments"]) != len(final["segments"]):
        raise ValueError("segment count changed")
    for old_segment, new_segment in zip(base["segments"], final["segments"]):
        if old_segment["name"] != new_segment["name"]:
            raise ValueError("segment order changed")
        old_sections, new_sections = old_segment.get("sections", []), new_segment.get("sections", [])
        if len(new_sections) < len(old_sections):
            raise ValueError(f"an existing section was removed from {old_segment['name']}")
        for old_section, new_section in zip(old_sections, new_sections):
            if old_section["raw"] != new_section["raw"] or \
                    section_data(base_data, old_section) != section_data(final_data, new_section):
                raise ValueError(f"an existing section changed: {old_segment['name']},{old_section['name']}")
        if old_segment["name"] == "__TEXT":
            if len(new_sections) != len(old_sections) + 2 or \
                    [section["raw"] for section in new_sections[:len(old_sections)]] != \
                    [section["raw"] for section in old_sections]:
                raise ValueError("pre-existing __TEXT section records changed")
        elif old_segment["name"] == "__LINKEDIT":
            # Re-signing may extend __LINKEDIT for a new ad-hoc signature.
            old_prefix, new_prefix = bytearray(old_segment["raw"]), bytearray(new_segment["raw"])
            struct.pack_into("<Q", old_prefix, 32, 0)
            struct.pack_into("<Q", new_prefix, 32, 0)
            struct.pack_into("<Q", old_prefix, 48, 0)
            struct.pack_into("<Q", new_prefix, 48, 0)
            if old_prefix != new_prefix:
                raise ValueError("__LINKEDIT changed beyond signing-related sizes")
            if [section["raw"] for section in old_segment.get("sections", [])] != \
                    [section["raw"] for section in new_segment.get("sections", [])]:
                raise ValueError("__LINKEDIT section records changed")
        elif old_segment["raw"] != new_segment["raw"]:
            raise ValueError(f"pre-existing segment changed: {old_segment['name']}")

    for old_command, new_command in zip(base["commands"], final["commands"]):
        if old_command["cmd"] != new_command["cmd"]:
            raise ValueError("load-command order changed")
        if old_command["cmd"] not in (LC_SEGMENT_64, LC_CODE_SIGNATURE) and \
                old_command["raw"] != new_command["raw"]:
            raise ValueError(f"pre-existing load command changed: {old_command['cmd']:#x}")
        if old_command["cmd"] == LC_SEGMENT_64 and old_command["raw"][8:24] != b"__TEXT\0".ljust(16, b"\0") and \
                old_command["raw"][8:24] != b"__LINKEDIT\0".ljust(16, b"\0") and \
                old_command["raw"] != new_command["raw"]:
            raise ValueError("pre-existing segment command changed")
    old_loads = [(command["cmd"], command["path"]) for command in dylib_loads(base)]
    new_loads = [(command["cmd"], command["path"]) for command in dylib_loads(final)]
    if old_loads != new_loads:
        raise ValueError("dylib load commands changed")
    old_rpaths = [command["path"] for command in base["commands"] if command["cmd"] == LC_RPATH]
    new_rpaths = [command["path"] for command in final["commands"] if command["cmd"] == LC_RPATH]
    if old_rpaths != new_rpaths:
        raise ValueError("runpaths changed")
    old_main = unique([command for command in base["commands"] if command["cmd"] == LC_MAIN], "base LC_MAIN")
    new_main = unique([command for command in final["commands"] if command["cmd"] == LC_MAIN], "final LC_MAIN")
    if old_main["raw"] != new_main["raw"]:
        raise ValueError("entrypoint changed")

    for name in ("__init_offsets", "__gcc_except_tab", "__text"):
        old = unique(sections_named(base, "__TEXT", name), f"base __TEXT,{name}")
        new = unique(sections_named(final, "__TEXT", name), f"final __TEXT,{name}")
        if old["raw"] != new["raw"] or section_data(base_data, old) != section_data(final_data, new):
            raise ValueError(f"pre-existing __TEXT,{name} changed")


def verify_ipa(ipa_path, baseline_executable_path):
    with open(baseline_executable_path, "rb") as source:
        baseline_data = source.read()

    with zipfile.ZipFile(ipa_path) as archive:
        bad_member = archive.testzip()
        if bad_member:
            raise ValueError(f"IPA CRC error in {bad_member}")
        names = archive.namelist()
        apps = app_paths(names)
        app = unique(apps, "Payload app bundle")
        for token in FORBIDDEN_ARTIFACTS:
            if any(token.lower() in name.lower() for name in names):
                raise ValueError(f"forbidden diagnostic/helper artifact is packaged: {token}")

        info_data = archive.read(archive_member(archive, app, "Info.plist"))
        plist = plistlib.loads(info_data)
        executable_name = plist.get("CFBundleExecutable")
        if not isinstance(executable_name, str) or not executable_name:
            raise ValueError("CFBundleExecutable is missing from Info.plist")
        executable_member, executable_data = app_binary(archive, app, executable_name)
        executable, final_loads, loader, baseline = verify_main_executable(executable_data, baseline_data)
        code, init, init_table = loader["code"], loader["init"], loader["original_init"]
        gcc = unique(sections_named(executable, "__TEXT", "__gcc_except_tab"), "__gcc_except_tab")
        fb_text = unique(sections_named(executable, "__TEXT", "__text"), "Facebook __text")

        glow_member, glow_data = app_binary(archive, app, "Frameworks/Glow.dylib")
        compat_member, compat_data = app_binary(archive, app, "Frameworks/GlowCompat.dylib")
        framework_prefix = f"Payload/{app}/Frameworks/"
        for filename in ("Glow.dylib", "GlowCompat.dylib"):
            copies = [name for name in names if name.startswith(framework_prefix) and
                      name.rsplit("/", 1)[-1] == filename]
            if len(copies) != 1:
                raise ValueError(f"expected exactly one Frameworks/{filename}, found {len(copies)}")
        glow_meta = verify_signed_arm64(glow_data, "Glow.dylib")
        compat_meta = verify_signed_arm64(compat_data, "GlowCompat.dylib")
        glow_deps = [command["path"] for command in dylib_loads(glow_meta)]
        compat_deps = [command["path"] for command in dylib_loads(compat_meta)]
        if "@rpath/CydiaSubstrate.framework/CydiaSubstrate" not in glow_deps:
            raise ValueError("Glow's expected CydiaSubstrate dependency is missing")
        if not any(name.endswith("/Frameworks/CydiaSubstrate.framework/CydiaSubstrate") for name in names):
            raise ValueError("Glow's CydiaSubstrate framework binary is missing")
        if any("substrate" in dependency.lower() or dependency.endswith("/Glow.dylib")
               for dependency in compat_deps):
            raise ValueError("GlowCompat has a forbidden Glow/Substrate link dependency")
        if any("libsubstrate" in dependency.lower() for dependency in glow_deps):
            raise ValueError("Glow has an unexpected libsubstrate dependency")

        frameworks = [name for name in names if "/Frameworks/" in name and name.endswith(".dylib")]
        for name in frameworks:
            if any(token.lower() in name.lower() for token in FORBIDDEN_ARTIFACTS):
                raise ValueError(f"forbidden helper dylib is present: {name}")

        result = {
            "verification": "PASS",
            "ipa": ipa_path,
            "ipa_sha256": sha256(open(ipa_path, "rb").read()),
            "facebook_executable": executable_member,
            "facebook_sha256": sha256(executable_data),
            "architecture": "arm64",
            "load_commands": executable["ncmds"],
            "glow_load_commands": len([c for c in final_loads if c["path"] == "@rpath/Glow.dylib"]),
            "compat_load_commands": len([c for c in final_loads if "GlowCompat.dylib" in c["path"]]),
            "lc_routines_64": 0,
            "glow": {"path": glow_member, "sha256": sha256(glow_data), "architecture": "arm64"},
            "glowcompat": {"path": compat_member, "sha256": sha256(compat_data), "architecture": "arm64"},
            "glow_code": {"vm": hex(code["addr"]), "fileoff": hex(code["offset"]),
                          "size": hex(code["size"]), "flags": hex(code["flags"])},
            "glow_init": {"vm": hex(init["addr"]), "fileoff": hex(init["offset"]),
                          "size": init["size"], "flags": hex(init["flags"]),
                          "raw_uint32": hex(loader["initializer_offset"]),
                          "target_vm": hex(loader["initializer_vm"])},
            "original_initializer_count": init_table["size"] // 4,
            "original_initializer_sha256": sha256(section_data(executable_data, init_table)),
            "gcc_except_tab_sha256": sha256(section_data(executable_data, gcc)),
            "facebook_text_sha256": sha256(section_data(executable_data, fb_text)),
            "original_initializer_matches_baseline":
                section_data(baseline_data, unique(sections_named(baseline, "__TEXT", "__init_offsets"),
                                                    "baseline __init_offsets")) ==
                section_data(executable_data, init_table),
            "original_init_offsets_sha256_matches_baseline":
                sha256(section_data(baseline_data, unique(sections_named(baseline, "__TEXT", "__init_offsets"),
                                                            "baseline __init_offsets"))) ==
                sha256(section_data(executable_data, init_table)),
            "rpaths": [command["path"] for command in executable["commands"] if command["cmd"] == LC_RPATH],
            "signatures_present": True,
            "zip_integrity": "PASS",
        }
        if not result["original_initializer_matches_baseline"]:
            raise ValueError("original initializer table differs from baseline")
        return result


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: verify_glow_late_loader.py production.ipa baseline-facebook-executable")
    try:
        print(json.dumps(verify_ipa(sys.argv[1], sys.argv[2]), indent=2))
    except (OSError, ValueError, KeyError, struct.error, zipfile.BadZipFile) as error:
        raise SystemExit(f"Glow late-loader verification failed: {error}")
