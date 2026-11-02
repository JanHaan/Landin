#!/usr/bin/env python3
"""Flash the prototype-1 board port to an ESP32-C5, boot it from power-on
through its ROM and check its trace against the physical oracle.

    python3 environments/boards/esp32c5/board.py --refine REFINE \
        --probe-rs PROBE_RS --output NEW_DIRECTORY

A developer tool, not a compiler dependency: refine builds the image at
--level=rv32imac through devices/descriptions/esp32c5, and this checks what
the board does with it.  The board is an Olimex ESP32-C5-DevKit-Lipo with
two USB-C ports on a hub uhubctl can switch: the chip's own
USB-Serial-JTAG, which probe-rs reaches, and a CH340X bridge on UART0,
GPIO11 transmitting and GPIO12 receiving, whose DTR and RTS drive EN and
the GPIO28 boot strap through the board's auto-reset transistors.  The
bridge has no USB serial of its own, so its tty is found by the hub port
it is plugged into, and it is opened with DTR and RTS inactive.  Both
ports are cut, so the board loses all its power; the steps are
environments/boards/esp.py's, and the oracle is written from what the host
sent, the ESP32-C5 TRM v1.1 and ESP-IDF v6.1's image format; see
environments/boards/esp32c5/README.md.
"""

import argparse
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import common  # noqa: E402
import esp  # noqa: E402
from common import require  # noqa: E402


class C5(esp.Chip):
    name = 'esp32c5'
    probe_chip = 'esp32c5'
    level = 'rv32imac'
    # The description's compiler.esp_image (D707): esp_chip_id_t 23, v1.0
    # to v1.99, read at flash offset 0x2000; SRAM's origin, where the
    # image's entry word is (D686).
    chip_id, min_revision, max_revision, offset = 23, 100, 199, 0x2000
    origin = 0x40800000
    # GPIO24, bit 24 of GPIO_IN_REG (Register 8.8).
    indicator = 0x01000000
    # CLIC identities 17 and 18 in mcause's exception code, bits 11:0,
    # beside its interrupt bit; the CLIC's other mcause fields, the
    # previous level and mode, are not the interrupt's (2.8.2).
    uart_cause, timer_cause, cause_mask = 0x80000011, 0x80000012, 0x80000fff
    a_extension = True
    cells = {'word_cell': ('d', 4), 'byte_cell': ('f', 1)}

    def mtvec(self, sections, names):
        # CLIC mode, 3, over compiler-owned trap entry, 64-byte aligned
        # (D680; the C5's TRM v1.1, 2.8.2).
        address = names['_landin_firmware_trap']
        require(address % 64 == 0, 'the trap entry %#x is not 64-byte aligned' % address)
        return address | 3

    def atomics(self, x, y):
        # The add returns x and leaves x + y; the first compare-exchange
        # finds x + y and stores x ^ y; the second expects x + y, finds
        # x ^ y and stores nothing; the byte cell's add returns x and leaves
        # x + y, wrapped to eight bits.
        return dict(p=x, q=x + y, r=x ^ y, d=x ^ y, e=x, f=(x + y) & 0xff)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    esp.arguments(parser, C5)
    parser.add_argument('--probe', default='303a:1001:D0:CF:13:E0:87:F0',
                        help="probe-rs's --probe for the board's USB-Serial-JTAG")
    parser.add_argument('--port', type=int, default=3, help="the board's JTAG port on the hub")
    parser.add_argument('--serial', default='D0:CF:13:E0:87:F0',
                        help="the USB serial the JTAG port must show before it is switched")
    parser.add_argument('--console-port', type=int, default=4,
                        help="the CH340X bridge's port on the same hub")
    parser.add_argument('--console-device', default='1a86:7523',
                        help='what the bridge\'s port must show before it is switched')
    parser.add_argument('--console-first', action='store_true',
                        help="restore the bridge's port first and open its tty before the"
                             " board's port, for a board that the bridge's port does not power")
    parser.add_argument('--enumerate-seconds', type=float, default=10.0,
                        help="how long the bridge's tty may take to appear")
    args = parser.parse_args()
    esp.required_tools(args)
    location = '%s.%d' % (args.hub, args.console_port)

    def console_for(run):
        path = common.wait_for_tty_at(location, args.enumerate_seconds)
        console = common.TtyConsole(path, quiet=True)
        lines = common.modem_lines(console.fd)
        require(not lines['dtr'] and not lines['rts'], 'the tty left %s active' % lines)
        return console

    def cycle(run, open_console):
        hub = common.InGroup(run, args.hub_group)
        both = [args.console_port, args.port]
        holds = [(args.port, args.serial), (args.console_port, args.console_device)]
        common.switch_ports(hub, args.hub, both, 'off', holds=holds,
                            keeps=(args.guard_port, args.guard_device))
        time.sleep(args.off_seconds)
        if args.console_first:
            common.switch_ports(hub, args.hub, [args.console_port], 'on',
                                keeps=(args.guard_port, args.guard_device), name='power-on-console')
            console = open_console(run)
            common.switch_ports(hub, args.hub, [args.port], 'on',
                                keeps=(args.guard_port, args.guard_device))
            return console
        common.switch_ports(hub, args.hub, both, 'on', keeps=(args.guard_port, args.guard_device))
        return open_console(run)

    return esp.run_board(C5(), args, console_for, cycle)


if __name__ == '__main__':
    sys.exit(main())
