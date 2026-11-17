"""measure_costs.py's readers over listings and images written here."""

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import measure  # noqa: E402
import measure_costs  # noqa: E402
from test_compare_images import FUNC, OBJECT, elf  # noqa: E402

#  An arm-eabi-objdump listing: a routine of the backend's own form, and a
#  C runtime helper, which is not counted.
THUMB = """
00000c64 <words>:
     c64:\tpush\t{r4, r5, r6, r7}
     c68:\tmov\tr6, sp
     c6e:\tadds\tr6, #36\t@ 0x24
     c70:\tstr\tr0, [r6, #0]
     c72:\tldr\tr2, [r6, #0]
     c74:\tldr\tr0, [r2, #0]
     c76:\tadds\tr0, r0, r2
     c78:\tldr\tr7, [pc, #0]\t@ (c94 <Lcm_step_297>)
     c7a:\tbx\tr7
     c94:\t.word\t0x00000ce9

00000d00 <__udivsi3>:
     d00:\tmovs\tr2, #0
     d02:\tmov\tr6, sp
"""

#  riscv64-linux-gnu-objdump: t0 forms a home's address, then holds a
#  value, after which a load through it is not the stack's.
RISCV = """
0000000000010190 <in_set>:
   10190:\taddi\tt0,s0,-288
   10194:\tsd\ts8,0(t0)
   10198:\tld\tt0,-176(s0)
   1019c:\tld\ta0,0(t0)
   101a0:\tauipc\ts10,0x0
   101a4:\taddi\ts10,s10,10 # 10246 <in_set+0xb6>
   101a8:\tjr\ts10
   101ac:\tadd\ta0,a0,a1
"""

X86 = """
0000000000400200 <in_set>:
  400200:\tpush   %rbp
  400201:\tmov    %rsp,%rbp
  400208:\tmov    %rbx,-0x10(%rbp)
  40020c:\tmov    (%rcx,%rsi,8),%rbx
  400210:\taddsd  %xmm9,%xmm14
"""


class Classes(unittest.TestCase):
    def test_thumb_homes_their_addresses_and_far_jumps(self):
        counts = measure_costs.classify("cortex-m0", THUMB)
        self.assertEqual({name: counts[name] for name in
                          ("stack", "address", "far", "other", "instructions")},
                         {"stack": 3, "address": 2, "far": 2, "other": 2,
                          "instructions": 9})
        self.assertEqual(counts["stack_share"], 33.3)

    def test_riscv_tracks_an_address_register_until_it_is_written(self):
        counts = measure_costs.classify("linux-rv64", RISCV)
        self.assertEqual((counts["stack"], counts["address"], counts["far"],
                          counts["other"]), (2, 1, 3, 2))

    def test_x86_counts_frame_operands_and_pushes(self):
        counts = measure_costs.classify("linux-x86-64", X86)
        self.assertEqual((counts["stack"], counts["other"]), (2, 3))

    def test_a_target_without_classes_is_refused(self):
        with self.assertRaises(measure.Failure):
            measure_costs.classify("synthetic-32", THUMB)


REPORT = {"items": [{"item": 1, "name": "main.in_set"},
                    {"item": 2, "name": "core.mem.copy"},
                    {"item": 3, "name": "core.text.copy"}],
          "build": {"routines": [
              {"item": item, "instructions": count, "stack_loads": loads,
               "stack_stores": stores, "direct_calls": 0, "indirect_calls": 0,
               "spill_bytes": 0, "frame_bytes": 16}
              for item, count, loads, stores in ((1, 40, 6, 4), (2, 50, 10, 5),
                                                 (3, 10, 0, 0))]}}


class Reports(unittest.TestCase):
    def test_totals_give_the_stack_share(self):
        sums = measure_costs.totals(measure_costs.report_routines(REPORT))
        self.assertEqual((sums["routines"], sums["instructions"],
                          sums["stack_share"]), (3, 100, 25.0))

    def test_a_shared_last_name_is_reached_only_whole(self):
        named = measure_costs.by_symbol(measure_costs.report_routines(REPORT))
        self.assertEqual(named["in_set"]["instructions"], 40)
        self.assertNotIn("copy", named)
        self.assertEqual(named["core.mem.copy"]["instructions"], 50)

    def test_top_reads_routine_bytes_from_the_image(self):
        image = elf([(0x100, bytes(96), 96)],
                    [("in_set", 0x101, 64, FUNC, 1), ("core.mem.copy", 0x141, 24, FUNC, 1),
                     ("table", 0x160, 8, OBJECT, 1)])
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "core.elf"
            path.write_bytes(image)
            self.assertEqual(measure_costs.elf_functions(path),
                             [("in_set", 0x100, 64), ("core.mem.copy", 0x140, 24)])
            rows = measure_costs.top(path, REPORT, 1)
        self.assertEqual(rows, [{"symbol": "in_set", "bytes": 64, "instructions": 40,
                                 "stack_loads": 6, "stack_stores": 4}])


if __name__ == "__main__":
    unittest.main()
