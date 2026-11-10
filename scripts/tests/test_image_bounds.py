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
        sizes = {"u8": 1, "u16": 2, "u32": 4, "u64": 8, "cell": 8, "wide": 24}
        for name, (source, _, written, kind) in image_bounds.shapes(1).items():
            match = re.search(r"mut image: \[(\d+)\](?:\[(\d+)\])?(\w+)", source)
            extent = int(match.group(1)) * int(match.group(2) or 1) * sizes[match.group(3)]
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


class Measured(unittest.TestCase):
    def test_a_talkative_driver_ends_and_its_last_lines_are_kept(self):
        #  More than a pipe holds: with a pipe nobody read this never ended.
        code = ("import sys\n"
                "for line in range(8000):\n"
                "    sys.stderr.write('image.s:%d: Error: no such instruction\\n' % line)\n"
                "raise SystemExit(1)\n")
        status, peak, _, said = image_bounds.peak_of([sys.executable, "-c", code], ".")
        self.assertEqual(status, 1)
        self.assertGreater(peak, 0)
        self.assertTrue(said.endswith("image.s:7999: Error: no such instruction"), said)
        self.assertLessEqual(len(said.splitlines()), 12)

    def test_a_driver_that_does_not_end_is_ended(self):
        status, _, seconds, _ = image_bounds.peak_of(
            [sys.executable, "-c", "import time; time.sleep(600)"], ".", seconds=0.5)
        self.assertLess(status, 0)
        self.assertLess(seconds, 300)


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
