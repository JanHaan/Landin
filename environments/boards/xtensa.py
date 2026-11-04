"""Shared physical orchestration for the two cacheless Xtensa board ports.

The compiler and the RAM helper own architectural entry. This tool owns the
chip-specific image, USB identities and physical oracle under the common lock.
"""
import argparse
from pathlib import Path
import struct
import subprocess
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


def inspection_contract(args):
    """Refuse workflow-changing combinations before any helper or rig access."""
    require(args.mode == 'boot', '--inspect-boot requires --mode=boot')
    require(not args.record, '--inspect-boot is observational and cannot write --record')
    require(args.bundle, '--inspect-boot needs the checked bundle prepared by environments/boards/run.py')
    require(not args.recover and not args.image_control,
            '--inspect-boot cannot run recovery or image controls')


def rom_table_count(address):
    """Reviewed S3 DRAM window or exact pinned ROM table, at most 64 bytes."""
    # The pinned ESP32-S3 ROM ELF defines cache_internal_func_obj here,
    # inside immutable DROM PT_LOAD [0x3ff18c00, 0x3ff1eb3c).
    if address == 0x3ff1e2b4:
        return 16
    return min(16, (0x3fcf0000 - address) // 4) if (
        address % 4 == 0 and 0x3fce0000 <= address < 0x3fcf0000) else 0


def inspect_boot(chip, args):
    """Observe the current board once; never establish or repair startup."""
    inspection_contract(args)
    identity = common.verify_ram_helper(args)  # No probe is opened by --describe.
    args.output = args.output.resolve()
    args.output.mkdir(parents=True)
    run = common.Run(args.output)
    run.pace = args.pace
    result = dict(status='failed', scope='boot-inspection', observational=True,
                  board=chip.name, active_image='not-established', helper_identity=identity,
                  flash_written=False, reset_requested=False, power_switched=False,
                  observations=[])
    began = time.monotonic()
    lock = common.rig_lock('%s boot inspection' % chip.name)

    def read(probe, name, address, count=1, role='chip state'):
        observation = dict(name=name, address=address, count=count, role=role)
        started = time.monotonic()
        try:
            words = probe.read_words('inspect-' + name, address, count)
            observation.update(words=words, bytes_le=struct.pack('<%dI' % count, *words).hex())
            return words
        except (common.Failed, OSError, subprocess.TimeoutExpired) as error:
            observation['error'] = str(error)
            raise
        finally:
            observation['seconds'] = round(time.monotonic() - started, 6)
            result['observations'].append(observation)

    try:
        elf, _, _ = esp.build(run, args, chip)  # Consume the checked bundle only.
        names = args.prepared_bundle['symbols']
        result['symbol_image_sha256'] = common.sha(elf)
        fixed_marker = common.fixed_marker_address(common.fixed_elf(args, chip.name))
        probe = common.Probe(run, args.probe_rs, chip.probe_chip, args.probe,
                             ram_loader=args.ram_loader, read_mode='boot-read')
        lock.acquire()
        args.pace.before('boot inspection')
        reset = read(probe, 'reset-cause', chip.reset_cause)[0]
        result['reset_cause'] = dict(raw=reset, code=reset & 0x3f)
        if chip.name == 'esp32':
            # ESP-IDF fff9895c82d744c7237be8847347bdd1b07c6643,
            # gpio_reg.h GPIO_STRAP_REG and rtc_cntl_reg.h RTC_CNTL_SDIO_CONF_REG.
            read(probe, 'gpio-strap', 0x3ff44038, role='latched straps; read only')
            read(probe, 'rtc-sdio-conf', 0x3ff48074, role='VDD_SDIO configuration; read only')
            caches = (('pro-cache', 0x3ff00040, 8), ('app-cache', 0x3ff00058, 8))
            clocks = (('apb-clock', 0x3ff66000, 0x3ff), ('rtc-clock', 0x3ff48070, 3 << 27))
            options_address, stall_address = 0x3ff48000, 0x3ff480ac
        else:
            caches = (('data-cache', 0x600c4000, 1), ('instruction-cache', 0x600c4060, 1))
            clocks = (('system-clock', 0x600c0060, 0xfff),)
            options_address, stall_address = 0x60008000, 0x600080bc
        result['caches'] = {name: dict(address=address, raw=(value := read(probe, name, address)[0]),
                                      mask=mask, enabled=bool(value & mask))
                            for name, address, mask in caches}
        result['clocks'] = {name: dict(address=address, raw=(value := read(probe, name, address)[0]),
                                      mask=mask, masked=value & mask)
                            for name, address, mask in clocks}
        options = read(probe, 'cpu1-stall-c0', options_address)[0]
        stall = read(probe, 'cpu1-stall-c1', stall_address)[0]
        code = (((stall >> 20) & 0x3f) << 2) | (options & 3)
        result['cpu1'] = dict(stall_code=code, cpu1_stalled=code == 0x86,
            options_address=options_address, options_value=options, options_mask=3,
            stall_address=stall_address, stall_value=stall, stall_mask=0x3f << 20)
        read(probe, 'fixed-marker', fixed_marker, role='bundled fixed ELF address; active image unknown')
        for cell in esp.TRAP_CELLS:
            read(probe, 'trap-' + cell, names['_landin_firmware_trap_' + cell],
                 role='bundled application ELF address; active image unknown')
        if chip.name == 'esp32s3':
            for address in (0x400016f4, 0x40001868, 0x40001880):
                read(probe, 'literal-%08x' % address, address, role='ROM veneer literal; observational')
            for name, address in [('veneer-400016f8', 0x400016f8), ('veneer-4000186c', 0x4000186c),
                    ('veneer-40001884', 0x40001884), ('prologue-4004eaec', 0x4004eaec),
                    ('prologue-4004f2b8', 0x4004f2b8), ('prologue-4004f32c', 0x4004f32c)]:
                read(probe, name, address, 4, role='ROM bytes; observational')
            pointer = read(probe, 'rom-table-pointer', 0x3fceffc4)[0]
            count = rom_table_count(pointer)
            result['rom_table'] = dict(pointer=pointer, bound=[0x3fce0000, 0x3fcf0000],
                                       pinned_rom_table=0x3ff1e2b4, maximum_bytes=64,
                                       callbacks_dereferenced=False)
            if count:
                result['rom_table']['callback_words'] = read(probe, 'rom-table', pointer, count,
                    role='ROM callback table words; targets not dereferenced')
            else:
                result['rom_table']['skipped'] = 'pointer is outside the reviewed DRAM window and exact pinned ROM table'
        result['status'] = 'observed'
    except (common.Failed, OSError, subprocess.TimeoutExpired) as error:
        result['failure'] = str(error)
    finally:
        common.retain_kernel_usb(args.pace, result)
        lock.release()
        result.update(seconds=round(time.monotonic() - began, 3), commands=run.commands)
        common.write_json(args.output / 'result.json', result)
    print('boot inspection %s: %s (observations only; active image not established)' %
          (result['status'], args.output))
    return 0 if result['status'] == 'observed' else 1


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
    parser.add_argument('--inspect-boot', action='store_true',
                        help='with --mode=boot, observe current state without flashing, resetting or switching power; no record')
    args = parser.parse_args()
    if args.inspect_boot:
        inspection_contract(args)
    common.board_preflight(args, chip.name)
    common.rerun_in_group(args.hub_group)
    if args.inspect_boot:
        esp.required_tools(args)
        return inspect_boot(chip, args)
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
