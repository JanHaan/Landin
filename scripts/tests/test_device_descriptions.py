"""The generated half of a device description has one text (D542).

`devices/descriptions/rp2040/interrupts.ldn` was written by hand from the
pinned SVD.  This renders the form D542 states from that SVD, with nothing
of the compiler's, and requires the file's bytes to be the rendering, so a
generator that reproduces the file reproduces the form.
"""

import hashlib
import unittest
import xml.etree.ElementTree as ElementTree
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SVD = ROOT / "devices/inputs/RP2040.svd"
INTERRUPTS = ROOT / "devices/descriptions/rp2040/interrupts.ldn"

CORES = {"CM0": "cortex-m0", "CM0PLUS": "cortex-m0plus",
         "CM3": "cortex-m3", "CM4": "cortex-m4", "CM7": "cortex-m7"}


def text_of(element, name):
    found = element.find(name)
    return None if found is None or found.text is None else found.text.strip()


def render(raw):
    device = ElementTree.fromstring(raw)
    name = text_of(device, "name")
    first = "-- Interrupts of the " + name + ", from its SVD"
    clauses = [label + " " + value for label, value in
               (("vendor", text_of(device, "vendor")),
                ("version", text_of(device, "version"))) if value]
    lines = [first + (": " + ", ".join(clauses) if clauses else "") + ".",
             "-- SVD SHA-256 " + hashlib.sha256(raw).hexdigest() + "."]
    licence = device.find("licenseText")
    if licence is not None and licence.text:
        lines += ["-- " + line.strip() for line in licence.text.splitlines()
                  if line.strip()]
    lines += ["-- Generated from the SVD; memory.ldn beside it is written"
              " by hand.", ""]
    cpu = device.find("cpu")
    pairs = set()
    for peripheral in device.iter("peripheral"):
        for interrupt in peripheral.findall("interrupt"):
            pairs.add((int(text_of(interrupt, "value"), 0),
                       text_of(interrupt, "name")))
    declared = int(text_of(cpu, "deviceNumInterrupts") or "0", 0)
    count = 16 + max(declared, max(value for value, _ in pairs) + 1)
    lines += ['compiler.device("%s")' % name.lower(),
              'compiler.core("%s")' % CORES[text_of(cpu, "name")],
              "compiler.vectors(%d)" % count]
    lines += ['compiler.interrupt("%s", %d)' % (interrupt, value)
              for value, interrupt in
              sorted(pairs, key=lambda pair: (pair[0], pair[1].encode()))]
    return "\n".join(lines) + "\n"


class GeneratedHalf(unittest.TestCase):
    def test_rp2040_interrupts_are_the_form(self):
        self.assertEqual(INTERRUPTS.read_bytes(),
                         render(SVD.read_bytes()).encode("ascii"))

    def test_the_form_names_usbctrl_at_irq_five(self):
        # [1990]'s reference reserves slot 21; RP2040 implements it.
        self.assertIn('compiler.interrupt("USBCTRL_IRQ", 5)\n',
                      INTERRUPTS.read_text())


if __name__ == "__main__":
    unittest.main()
