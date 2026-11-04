"""Shared physical orchestration for the two cacheless Xtensa board ports.

The compiler and the RAM helper own architectural entry. This tool owns the
chip-specific image, USB identities and physical oracle under the common lock.
"""
import argparse
from pathlib import Path
import time

import common
import esp
from common import require


class Xtensa(esp.Chip):
    target = 'xtensa'
    vector_register = 'vecbase'
    entry_at_origin = False
    uart_cause, timer_cause = 1 << 1, 1 << 23
    uart_cause_mask, timer_cause_mask = uart_cause, timer_cause
    cause_mask = 0xffffffff
    cells = {'byte_cell': ('b', 1), 'half_cell': ('h', 2), 'word_cell': ('w', 4)}

    def mtvec(self, sections, names):
        address, _, size = sections['.isr_vector']
        require(address == self.origin and address % 1024 == 0 and size == 1024,
                'Xtensa vectors are not the exact aligned 1 KiB architectural block')
        require(names['_landin_firmware_vectors'] == address, 'VECBASE symbol disagrees with vectors')
        return address

    def boot(self, frame):
        require(frame.get('d') == 0 and frame.get('f') == 0,
                'startup did not establish the supported disabled-cache state')
        require(frame.get('p') == 0x86, 'CPU1 hardware stall is not retained')
        return dict(cache_enables=[frame['d'], frame['f']], cpu1_stall=frame['p'])

    def atomics(self, x, y):
        return dict(b=x, h=(x << 8) | y, w=(x << 24) | (y << 16) | (y << 8) | x)


class ESP32(Xtensa):
    name = probe_chip = 'esp32'
    power_on_names = ('POWERON_RESET',)
    level = 'xtensa-esp32'
    tool_prefixes = ('xtensa-esp32-elf-',)
    chip_id, min_revision, max_revision, offset = 0, 0, 399, 0x1000
    origin = 0x40080000
    indicator = 1 << 22
    reset_cause = 0x3ff48034
    probe_default = '0000:0002:10.42.0.50/4'
    hub_default, port_default, serial_default = '.3.4', 4, '1a86:7523'
    console_hub_default, console_port_default = '.3.4', 4
    guard_port_default, guard_device_default = 1, '1366:0105'
    console_guard_port_default, console_guard_device_default = 1, '1366:0105'


class ESP32S3(Xtensa):
    name = probe_chip = 'esp32s3'
    level = 'xtensa-esp32s3'
    tool_prefixes = ('xtensa-esp32s3-elf-',)
    chip_id, min_revision, max_revision, offset = 9, 0, 99, 0
    origin = 0x40378000
    # GPIO38's bank-one bit, normalized by the source for its active-low LED.
    indicator = 1 << 6
    reset_cause = 0x60008038
    probe_default = '303a:1001:E8:3D:C1:F5:C4:EC'
    hub_default, port_default, serial_default = '.4', 4, 'E8:3D:C1:F5:C4:EC'
    console_hub_default, console_port_default = '.4', 2
    guard_port_default, guard_device_default = 3, '1a86:7523'
    console_guard_port_default, console_guard_device_default = 3, '1a86:7523'


def power_on_boot(probe, chip, names):
    """Observe actual power-on before opening the board-powered UART bridge."""
    cause = probe.read_words('jtag-cold-reset-cause', chip.reset_cause, 1)[0] & 0x3f
    require(cause == esp.POWER_ON, 'cold reset cause is %#x, not power-on' % cause)
    if common.FIXED_READY_SYMBOL in names:
        ready = probe.read_words('jtag-cold-fixed-ready', names[common.FIXED_READY_SYMBOL], 1)[0]
        require(ready == common.FIXED_READY_MAGIC, 'cold resident startup did not reach its park loop')
        return dict(reset_cause=cause, resident_ready=ready)
    reason = probe.read_words('jtag-cold-boot-reason', names['boot_reason'], 1)[0]
    state = probe.read_words('jtag-cold-app-state', names['app_state'], 1)[0]
    first = probe.read_words('jtag-cold-timer-first', names['timer_events'], 1)[0]
    time.sleep(0.2)
    second = probe.read_words('jtag-cold-timer-second', names['timer_events'], 1)[0]
    require(reason == esp.POWER_ON and state == 2 and second > first,
            'the actual cold application did not record power-on and advance its timer')
    require(esp.trap_cells(probe, names)['count'] == 0, 'the cold application trapped')
    return dict(reset_cause=cause, boot_reason=reason, app_state=state,
                timer_events=[first, second], trap_count=0)


def main(chip_class, description):
    chip = chip_class()
    parser = argparse.ArgumentParser(description=description,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    esp.arguments(parser, chip_class)
    parser.set_defaults(hub=chip.hub_default, guard_port=chip.guard_port_default,
                        guard_device=chip.guard_device_default)
    parser.add_argument('--probe', default=chip.probe_default)
    parser.add_argument('--port', type=int, default=chip.port_default)
    parser.add_argument('--serial', default=chip.serial_default,
                        help='identity at the powered port, checked before any switching')
    parser.add_argument('--console-hub', default=chip.console_hub_default)
    parser.add_argument('--console-port', type=int, default=chip.console_port_default)
    parser.add_argument('--console-device', default='1a86:7523')
    parser.add_argument('--console-guard-port', type=int, default=chip.console_guard_port_default)
    parser.add_argument('--console-guard-device', default=chip.console_guard_device_default)
    parser.add_argument('--enumerate-seconds', type=float, default=60)
    parser.add_argument('--reset-seconds', type=float, default=0.1)
    args = parser.parse_args()
    common.board_preflight(args, chip.name)
    common.rerun_in_group(args.hub_group)
    common.place_hubs(parser, args, 'hub', 'console_hub')
    esp.required_tools(args)
    require(not args.recover, 'Xtensa recovery is an explicit setup operation; this tool does not enter download mode')
    require(not args.image_control, 'Xtensa ROM corruption controls need their chip-specific oracle; no control is flashed')
    board_location = '%s.%d' % (args.hub, args.port)
    console_location = '%s.%d' % (args.console_hub, args.console_port)
    dual = board_location != console_location
    guard = (args.guard_port, args.guard_device)
    console_guard = (args.console_guard_port, args.console_guard_device)

    def console_for(run):
        path = common.wait_for_tty_at(console_location, args.enumerate_seconds)
        console = common.TtyConsole(path, quiet=True)
        lines = common.modem_lines(console.fd)
        require(not lines['dtr'] and not lines['rts'], 'the UART bridge asserted reset or the boot strap')
        return console

    def settle(run):
        hub = common.InGroup(run, args.hub_group)
        common.wait_for_hub(hub, args.hub, [(args.port, args.serial), guard], args.enumerate_seconds)
        if dual:
            common.wait_for_hub(hub, args.console_hub,
                                [(args.console_port, args.console_device), console_guard], args.enumerate_seconds)
        common.wait_for_tty_at(console_location, args.enumerate_seconds)

    def cycle(run, open_console, probe, names):
        hub = common.InGroup(run, args.hub_group)

        def off():
            if dual:
                common.switch_ports(hub, args.console_hub, [args.console_port], 'off',
                                    holds=[(args.console_port, args.console_device)], keeps=console_guard)
            common.switch_ports(hub, args.hub, [args.port], 'off',
                                holds=[(args.port, args.serial)], keeps=guard)

        def on():
            if dual:
                common.switch_ports(hub, args.console_hub, [args.console_port], 'on', keeps=console_guard)
            common.switch_ports(hub, args.hub, [args.port], 'on', keeps=guard)

        esp.paced(args, 'power off', off)
        time.sleep(args.off_seconds)
        esp.paced(args, 'power on', on)
        settle(run)
        cold = power_on_boot(probe, chip, names) if names else None
        console = open_console(run)
        # The USB UART enumerates after ROM output. Observe true POR above,
        # then collect the full ROM trace from a separate EN reset. DTR stays
        # inactive so GPIO0 cannot request download mode.
        def enable_reset():
            require(not common.modem_lines(console.fd)['dtr'], 'DTR would select download mode')
            common.set_lines(console.fd, rts=True)
            time.sleep(args.reset_seconds)
            common.set_lines(console.fd, rts=False)
        esp.paced(args, 'chip-enable reset', enable_reset)
        return console, cold

    return esp.run_board(chip, args, console_for, cycle, settle)
