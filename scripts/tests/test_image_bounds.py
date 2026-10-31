"""The image-bounds harness's shapes and refusals, without a compiler."""

import contextlib
import io
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import image_bounds  # noqa: E402


class Shapes(unittest.TestCase):
    def test_each_shape_doubles_its_image_and_not_its_source(self):
        small, large = image_bounds.shapes(1), image_bounds.shapes(2)
        self.assertEqual(set(small), set(large))
        for name in small:
            source_1, _, written_1, kind = small[name]
            source_2, _, written_2, _ = large[name]
            self.assertEqual(written_2, 2 * written_1, name)
            self.assertLessEqual(len(source_2), len(source_1) + 2, name)
            self.assertEqual(written_1 == 0, kind == 2, name)

    def test_written_bytes_are_the_declared_extent(self):
        sizes = {"u8": 1, "u16": 2, "u32": 4, "u64": 8}
        for name, (source, _, written, kind) in image_bounds.shapes(1).items():
            match = re.search(r"\[(\d+)\](?:\[(\d+)\])?(u8|u16|u32|u64|cell)", source)
            extent = int(match.group(1)) * int(match.group(2) or 1) * sizes.get(
                match.group(3), 8)
            self.assertEqual(written, 0 if kind == 2 else extent, name)

    def test_a_program_reads_what_it_declares(self):
        hosted = image_bounds.program("linux-x86-64", "mut image: [2]u8 = [of 1]\n",
                                      "image[1]")
        self.assertIn("public main", hosted)
        firmware = image_bounds.program("cortex-m0", "mut image: [2]u8 = [of 1]\n",
                                        "image[1]")
        self.assertNotIn("main", firmware)
        self.assertIn("u32(image[1])", firmware)

    def test_reach_is_the_budget_d537_states(self):
        self.assertEqual(image_bounds.REACH["linux-x86-64"], 2 ** 31)
        self.assertEqual(image_bounds.REACH["linux-arm64"], 2 ** 32)
        self.assertEqual(image_bounds.REACH["linux-rv64"], 2 ** 31)


class Arguments(unittest.TestCase):
    def test_a_missing_driver_says_which_option_names_it(self):
        error = io.StringIO()
        with contextlib.redirect_stderr(error):
            status = image_bounds.main(["--refine=/nonexistent/refine",
                                        "--toolchain=/nonexistent/driver"])
        self.assertEqual(status, 2)
        self.assertIn("--toolchain", error.getvalue())


if __name__ == "__main__":
    unittest.main()
