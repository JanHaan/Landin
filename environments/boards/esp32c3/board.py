#!/usr/bin/env python3
"""Flash the prototype-1 board port to an ESP32-C3, boot it from power-on
through its ROM and check its trace against the physical oracle.

    python3 environments/boards/esp32c3/board.py --refine REFINE \
        --probe-rs PROBE_RS --output NEW_DIRECTORY

A developer tool, not a compiler dependency: refine builds the image at
--level=rv32imc through devices/descriptions/esp32c3, and this checks what
the board does with it.  The board is an Olimex ESP32-C3-DevKit-Lipo:
probe-rs reaches the chip through its own USB-Serial-JTAG, which is also
the port that powers it, on a hub uhubctl can switch, and its UART0, GPIO21
transmitting and GPIO20 receiving, is wired to a probehive slot's UART,
which the probe's bridge serves as a TCP port while the board is off and
on, so the ROM's log from power-on is read whole.  The steps are
environments/boards/esp.py's; the oracle is written from what the host
sent, the ESP32-C3 TRM v1.4 and ESP-IDF v6.1's image format, never from
the firmware's own idea of itself; see environments/boards/esp32c3/README.md.
"""

import argparse
import socket
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import common  # noqa: E402
import esp  # noqa: E402
from common import require  # noqa: E402


class C3(esp.Chip):
    name = 'esp32c3'
    probe_chip = 'esp32c3'
    level = 'rv32imc'
    # The description's compiler.esp_image (D707): esp_chip_id_t 5, ECO3
    # to v1.99, read at flash offset 0; IRAM's origin, where the image's
    # entry word is (D686).
    chip_id, min_revision, max_revision, offset = 5, 3, 199, 0x0
    origin = 0x40380000
    # GPIO10, bit 10 of GPIO_IN_REG (Register 5.9).
    indicator = 0x400
    # CPU lines 1 and 2: mcause's interrupt bit and the line (1.5.3.2).
    uart_cause, timer_cause, cause_mask = 0x80000001, 0x80000002, 0xffffffff
    a_extension = False
    cells = {'byte_cell': ('b', 1), 'half_cell': ('h', 2), 'word_cell': ('w', 4)}

    def mtvec(self, sections, names):
        # Vectored mode, 1, over the table at the profile's vector address
        # (D680; the C3's TRM v1.4, 1.5.3.2).
        address = sections['.isr_vector'][0]
        require(address == 0x40380100, 'the table is at %#x, not 0x4038_0100' % address)
        return address | 1

    def atomics(self, x, y):
        # Each load reads what the store before it wrote: the byte, the
        # half-word of x and y, and the word x y y x, most significant first.
        return dict(b=x, h=(x << 8) | y, w=(x << 24) | (y << 16) | (y << 8) | x)


def listening(port):
    with socket.socket() as probe:
        probe.settimeout(0.5)
        return probe.connect_ex(('127.0.0.1', port)) == 0


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    esp.arguments(parser, C3)
    parser.add_argument('--probe', default='303a:1001:A0:76:4E:42:57:F8',
                        help="probe-rs's --probe for the board's USB-Serial-JTAG")
    parser.add_argument('--port', type=int, default=2, help="the board's port on the hub")
    parser.add_argument('--serial', default='A0:76:4E:42:57:F8',
                        help="the USB serial the board's port must show before it is switched")
    parser.add_argument('--probehive', type=Path,
                        help='a probehive checkout, to start its bridge when none listens')
    parser.add_argument('--probe-host', default='10.42.0.50')
    parser.add_argument('--slot', type=int, default=2, help="the probehive slot wired to UART0")
    parser.add_argument('--uart-port', type=int, default=4461,
                        help="the bridge's slot 0 UART port; slot N's is this plus N")
    args = parser.parse_args()
    esp.required_tools(args)
    chip = C3()
    bridge = []

    def console_for(run):
        port = args.uart_port + args.slot
        if not listening(port):
            require(args.probehive, 'no bridge serves port %d: start one or name --probehive'
                    % port)
            bridge.append(common.ProbehiveBridge(run, args.probehive, args.probe_host,
                                                 args.slot + 1, 4441, args.uart_port))
        return common.TcpConsole(port)

    def cycle(run, open_console, probe, names):
        # The probehive UART is powered apart from the board, so the
        # console is open before the power is cut and reads the ROM's log
        # from power-on.
        console = open_console(run)
        common.power_cycle(common.InGroup(run, args.hub_group), args.hub, args.port,
                           args.off_seconds, holds=args.serial,
                           keeps=(args.guard_port, args.guard_device))
        return console, None

    try:
        return esp.run_board(chip, args, console_for, cycle)
    finally:
        for started in bridge:
            started.close()


if __name__ == '__main__':
    sys.exit(main())
