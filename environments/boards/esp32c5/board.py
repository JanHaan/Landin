#!/usr/bin/env python3
"""Run the ESP32-C5 board port from SRAM by default and check its physical oracle.

The default --mode=ram consumes --bundle or builds with --refine, then
uses --ram-loader for a warm halt/load/resume session with SRAM readback.
The resident flash image stays in place; RAM runs do not reset through
the ROM, write flash or cycle power, and do not prove a cold boot.
Explicit --mode=boot flashes the image, checks its ROM/cold boot and
restores --fixed-image (or the bundle's resident image), cold-starting it
and checking readiness afterward, subject to the USB stop guard.
--image-control and --recover require --mode=boot.

    python3 environments/boards/esp32c5/board.py --refine REFINE \
        --probe-rs PROBE_RS --ram-loader LOADER --output NEW_DIRECTORY

A developer tool, not a compiler dependency: refine builds the image at
--level=rv32imac through devices/descriptions/esp32c5, and this checks what
the board does with it.  The board is an Olimex ESP32-C5-DevKit-Lipo with
two USB-C ports on a hub uhubctl can switch: the chip's own
USB-Serial-JTAG, which probe-rs reaches, and a CH340X bridge on UART0,
GPIO11 transmitting and GPIO12 receiving, whose DTR and RTS drive EN and
the GPIO28 boot strap through the board's auto-reset transistors.  The
bridge has no USB serial of its own, so its tty is found by the hub port
it is plugged into, and it is opened with DTR and RTS inactive.

In boot mode, either port powers the board, so both are cut and restored
together, and the chip runs before either has enumerated. The boot from
power-on is shown by what the chip recorded, its reset cause and the
application's own reading of it, running and counting, read over JTAG; then, with the tty
open, RTS alone pulls EN low, a chip-enable reset with GPIO28 high, and the
ROM's log of that boot, which it reports as a power-on reset, is read
(D724).  The other steps are environments/boards/esp.py's, and the oracle
is written from what the host sent, the ESP32-C5 TRM v1.1 and ESP-IDF
v6.1's image format; see environments/boards/esp32c5/README.md.
"""

import argparse
import struct
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

    def mtvt(self, elf, names):
        # The CLIC's table of handler addresses, 64-byte aligned (Register
        # 2.10): word i is where an interrupt of identity i whose SHV is
        # set enters (Register 2.66), a stub of compiler-owned code for
        # each handled identity and the unhandled entry for every other
        # (D830).
        address = names['_landin_firmware_vector_addresses']
        require(address % 64 == 0, 'the table of addresses %#x is not 64-byte aligned' % address)
        words = struct.unpack('<%dI' % IDENTITIES, common.loaded(elf, address, 4 * IDENTITIES))
        for identity, word in enumerate(words):
            stub = names.get('_landin_firmware_slot_%d' % identity)
            require(stub is not None or identity not in HANDLED,
                    'identity %d has no stub of its own' % identity)
            expected = stub if identity in HANDLED else names['_landin_firmware_unhandled']
            require(word == expected, 'word %d of the table of addresses is %#x, not %#x'
                    % (identity, word, expected))
        return address

    def boot(self, frame):
        # CLICINT18 and 17 as the core read them back, which the probe's
        # system bus access cannot reach: the timer's SHV set, so the CLIC
        # takes it through mtvt's table, and UART0's clear, for the common
        # entry (D830).
        require('x' in frame and 'y' in frame, 'the boot frame carries no CLICINT words')
        require(frame['x'] & SHV, 'CLICINT%d reads %#x: the timer is not hardware vectored'
                % (VECTORED, frame['x']))
        require(not frame['y'] & SHV, 'CLICINT%d reads %#x: UART0 is hardware vectored'
                % (COMMON_ENTRY, frame['y']))
        return dict(clicint={str(VECTORED): '%#010x' % frame['x'],
                             str(COMMON_ENTRY): '%#010x' % frame['y']})

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
    parser.add_argument('--console-hub', default='.4',
                        help="the CH340X bridge's hub, as uhubctl -l names it or relative to the"
                             ' cascade')
    parser.add_argument('--console-port', type=int, default=3,
                        help="the CH340X bridge's port on its hub")
    parser.add_argument('--console-device', default='1a86:7523',
                        help='what the bridge\'s port must show before it is switched')
    parser.add_argument('--console-guard-port', type=int, default=4,
                        help="a port of the bridge's hub never switched")
    parser.add_argument('--console-guard-device', default='E8:3D:C1:F5:C4:EC',
                        help="what that port must show, or the bridge's hub is not switched")
    parser.add_argument('--enumerate-seconds', type=float, default=60.0,
                        help="how long the hub may take to list the board again, and its tty"
                             ' to appear')
    parser.add_argument('--reset-seconds', type=float, default=0.1,
                        help='how long RTS holds EN low for the chip-enable reset')
    args = parser.parse_args()
    common.board_preflight(args, 'esp32c5')
    # The console's tty, and the JTAG's that --recover opens, belong to
    # --hub-group (D836).
    common.rerun_in_group(args.hub_group)
    common.place_hubs(parser, args, 'hub', 'console_hub')
    esp.required_tools(args)
    console_location = '%s.%d' % (args.console_hub, args.console_port)
    jtag_location = '%s.%d' % (args.hub, args.port)

    def console_for(run):
        path = common.wait_for_tty_at(console_location, args.enumerate_seconds)
        console = common.TtyConsole(path, quiet=True)
        lines = common.modem_lines(console.fd)
        require(not lines['dtr'] and not lines['rts'], 'the tty left %s active' % lines)
        return console

    def settle(run):
        common.wait_for_hub(common.InGroup(run, args.hub_group), args.hub,
                            [(args.port, args.serial), (args.guard_port, args.guard_device)],
                            args.enumerate_seconds)

    def cycle(run, open_console, probe, names):
        # Both USB-C ports power the board, so the chip is running before
        # either port has enumerated: the boot from power-on is shown by
        # what the chip itself recorded, read over JTAG, and the ROM's log
        # is read after a chip-enable reset through RTS with the tty open.
        hub = common.InGroup(run, args.hub_group)
        guard = (args.guard_port, args.guard_device)
        console_guard = (args.console_guard_port, args.console_guard_device)

        def off():
            common.switch_ports(hub, args.hub, [args.port], 'off', keeps=guard,
                                holds=[(args.port, args.serial)])
            common.wait_for_hub(hub, args.console_hub, [console_guard], args.enumerate_seconds)
            common.switch_ports(hub, args.console_hub, [args.console_port], 'off',
                                keeps=console_guard,
                                holds=[(args.console_port, args.console_device)],
                                name='power-off-console')

        def on():
            common.switch_ports(hub, args.console_hub, [args.console_port], 'on',
                                keeps=console_guard, name='power-on-console')
            common.wait_for_hub(hub, args.hub, [guard], args.enumerate_seconds)
            common.switch_ports(hub, args.hub, [args.port], 'on', keeps=guard)
        # The two ports are on two hubs, so they are switched one after the
        # other, each while the other is already off or not yet on: the
        # board has power from neither between the two offs and the two ons.
        esp.paced(args, 'power off', off)
        time.sleep(args.off_seconds)
        common.wait_for_hub(hub, args.hub, [guard], args.enumerate_seconds)
        common.wait_for_hub(hub, args.console_hub, [console_guard], args.enumerate_seconds)
        esp.paced(args, 'power on', on)
        settle(run)
        common.wait_for_tty_at(jtag_location, args.enumerate_seconds)
        power_on = power_on_boot(probe, names) if names else None
        console = open_console(run)
        if names is None:
            # A control's image: a refused one leaves the ROM resetting the
            # chip over and over, each time writing its log, which is read
            # without a reset of the tool's own.
            try:
                console.wait(lambda s: b'ESP-ROM' in s, args.control_seconds, 'a ROM log')
                return console, None
            except common.Failed:
                pass
        esp.paced(args, 'chip-enable reset',
                  lambda: chip_enable_reset(console.fd, args.reset_seconds))
        return console, power_on

    return esp.run_board(C5(), args, console_for, cycle, settle)


# LP_CLKRST_RESET_CAUSE (the C5's TRM v1.1, Register 9.90): the cause in
# bits 4:0, 0x01 the chip reset a power-on is (9.1.4, Table 9.1-1).
RESET_CAUSE = 0x600b0410
# The CLIC's 48 identities (2.8.2.3, Table 2.8-1), of which the port
# handles 17, UART0's, and 18, the system timer's.
IDENTITIES = 48
HANDLED = (17, 18)
# CLICINT i, the word of clicintip, clicintie, clicintattr and clicintctl
# (2.8.2.6, Register 2.66): clicintattr's SHV is bit 16 of the word.  The
# port vectors the timer's, 18, by hardware through mtvt, and leaves
# UART0's, 17, to the common entry (D830); its boot frame carries both
# words, x and y.
SHV = 1 << 16
VECTORED, COMMON_ENTRY = 18, 17


def power_on_boot(probe, names):
    """The boot from power-on, read over JTAG before anything resets the
    chip again: the reset cause the program read first, the chip's own
    register, the application running and its timer advancing."""
    cause = probe.read_words('jtag-reset-cause', RESET_CAUSE, 1)[0] & 0x1f
    reason = probe.read_words('jtag-boot-reason', names['boot_reason'], 1)[0]
    state = probe.read_words('jtag-app-state', names['app_state'], 1)[0]
    first = probe.read_words('jtag-timer-first', names['timer_events'], 1)[0]
    time.sleep(0.2)
    second = probe.read_words('jtag-timer-second', names['timer_events'], 1)[0]
    require(cause == esp.POWER_ON and reason == esp.POWER_ON,
            'after power-on the reset cause reads %#x and the program read %#x, not 0x1'
            % (cause, reason))
    require(state == 2, 'the application is in state %d, not 2: running' % state)
    require(second > first, 'the timer did not advance: %d, then %d' % (first, second))
    trap = esp.trap_cells(probe, names)
    require(trap['count'] == 0, 'the unhandled entry took a trap: mcause %#x at %#x'
            % (trap['cause'], trap['pc']))
    return dict(reset_cause=cause, boot_reason=reason, app_state=state,
                timer_events=[first, second], trap_count=0)


def chip_enable_reset(fd, seconds):
    """EN low through RTS alone, DTR inactive, so GPIO28 stays high and the
    ROM boots from flash: the board's auto-reset transistors pull EN low
    only while RTS is active and DTR is not."""
    lines = common.modem_lines(fd)
    require(not lines['dtr'], 'DTR is active; GPIO28 would select download mode')
    common.set_lines(fd, rts=True)
    time.sleep(seconds)
    common.set_lines(fd, rts=False)




if __name__ == '__main__':
    sys.exit(common.tool_main(main))
