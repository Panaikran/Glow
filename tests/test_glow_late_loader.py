import os
import sys
import unittest
import copy
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from glow_macho import CPU_TYPE_ARM64, S_INIT_FUNC_OFFSETS, parse_macho, section_data, sections_named, unique
from patch_glow_late_loader import check_header_slack, find_text_and_code_space, patch_bytes
from verify_glow_late_loader import (
    verify_header_slack, verify_launch_dependencies, verify_loader_sections,
)


def configured_inputs(testcase):
    executable = os.environ.get("GLOW_TEST_EXECUTABLE")
    loader_object = os.environ.get("GLOW_TEST_OBJECT")
    if not executable or not loader_object:
        testcase.skipTest("set GLOW_TEST_EXECUTABLE and GLOW_TEST_OBJECT for the target-Mach-O checks")
    return Path(executable).read_bytes(), Path(loader_object).read_bytes()


class GlowLateLoaderTests(unittest.TestCase):
    def test_parses_facebook_arm64_pie_baseline(self):
        executable, _ = configured_inputs(self)
        meta = parse_macho(executable)
        self.assertEqual(meta["cpu"], CPU_TYPE_ARM64)
        self.assertEqual(meta["filetype"], 2)
        text = unique([segment for segment in meta["segments"] if segment["name"] == "__TEXT"], "__TEXT")
        initializer = unique(sections_named(meta, "__TEXT", "__init_offsets"), "__init_offsets")
        self.assertEqual(initializer["flags"] & 0xFF, S_INIT_FUNC_OFFSETS)
        self.assertEqual(initializer["size"] % 4, 0)
        self.assertGreater(text["vmsize"], 0)

    def test_patch_adds_two_sections_and_preserves_initializers(self):
        executable, loader_object = configured_inputs(self)
        before = parse_macho(executable)
        old_initializer = unique(sections_named(before, "__TEXT", "__init_offsets"), "__init_offsets")
        old_bytes = section_data(executable, old_initializer)
        patched, _ = patch_bytes(executable, loader_object)
        after = parse_macho(patched)
        self.assertEqual(after["ncmds"], before["ncmds"])
        self.assertEqual(after["sizeofcmds"], before["sizeofcmds"] + 160)
        self.assertEqual(len(after["sections"]), len(before["sections"]) + 2)
        self.assertEqual(section_data(patched, unique(sections_named(after, "__TEXT", "__init_offsets"), "__init_offsets")), old_bytes)
        code = unique(sections_named(after, "__TEXT", "__glow_code"), "__glow_code")
        init = unique(sections_named(after, "__TEXT", "__glow_init"), "__glow_init")
        value = int.from_bytes(section_data(patched, init), "little")
        base = unique([segment for segment in after["segments"] if segment["name"] == "__TEXT"], "__TEXT")["vm"]
        self.assertGreaterEqual(base + value, code["addr"])
        self.assertLess(base + value, code["addr"] + code["size"])

    def test_launch_verifier_rejects_compat_dependency(self):
        loads = {"commands": [
            {"cmd": 0x80000018, "path": "@rpath/Glow.dylib"},
            {"cmd": 0x80000018, "path": "@rpath/GlowCompat.dylib"},
        ]}
        with self.assertRaisesRegex(ValueError, "must not launch-load"):
            verify_launch_dependencies(loads)

    def test_verifier_rejects_overlapping_code_region(self):
        executable, loader_object = configured_inputs(self)
        before = parse_macho(executable)
        patched, _ = patch_bytes(executable, loader_object)
        after = parse_macho(patched)
        code = unique(sections_named(after, "__TEXT", "__glow_code"), "__glow_code")
        text_section = unique(sections_named(before, "__TEXT", "__text"), "__text")
        with self.assertRaisesRegex(ValueError, "overlaps existing content"):
            text_section["size"] = code["offset"] - text_section["offset"] + 4
            verify_loader_sections(patched, after, before)

    def test_patcher_rejects_nonzero_or_overlapping_tail(self):
        executable, loader_object = configured_inputs(self)
        meta = parse_macho(executable)
        text = unique([segment for segment in meta["segments"] if segment["name"] == "__TEXT"], "__TEXT")
        _, _, code_offset = find_text_and_code_space(executable, meta, text)
        damaged = bytearray(executable)
        damaged[code_offset] = 0xA5
        with self.assertRaisesRegex(ValueError, "tail contains non-zero data"):
            patch_bytes(bytes(damaged), loader_object)

    def test_header_slack_check_fails_closed(self):
        data = bytes(256)
        meta = {"command_end": 64, "sections": [{"offset": 128, "size": 4, "flags": 0}]}
        with self.assertRaisesRegex(ValueError, "insufficient Mach-O header slack"):
            check_header_slack(data, meta, 80)

    def test_verifier_rejects_insufficient_header_slack(self):
        executable, loader_object = configured_inputs(self)
        patched, _ = patch_bytes(executable, loader_object)
        baseline_meta = parse_macho(executable)
        patched_meta = parse_macho(patched)
        short = copy.copy(baseline_meta)
        first_section = min(section["offset"] for section in baseline_meta["sections"]
                            if section["size"] and section["offset"])
        short["command_end"] = first_section - 159
        with self.assertRaisesRegex(ValueError, "does not have verified header slack"):
            verify_header_slack(executable, short, patched, patched_meta)

    def test_patcher_rejects_running_twice(self):
        executable, loader_object = configured_inputs(self)
        patched, _ = patch_bytes(executable, loader_object)
        with self.assertRaisesRegex(ValueError, "already contains Glow late-loader sections"):
            patch_bytes(patched, loader_object)


if __name__ == "__main__":
    unittest.main()
