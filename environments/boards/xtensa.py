"""Shared physical orchestration for the two cacheless Xtensa board ports.

The compiler and the RAM helper own architectural entry. This tool owns the
chip-specific image, USB identities and physical oracle under the common lock.
"""
import argparse
from pathlib import Path
import re
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
    # UART0 on the crystal's 40 MHz, undivided; CLKDIV's 20 bits; and no
    # two stop bits, which ESP-IDF gives on this chip only through
    # RS485_CONF's DL1_EN, a register its port does not select (D960).
    line_clocks = (40000000,)
    clkdiv_most = 0xffffff
    two_stop_bits = False
    line_plan = [((921600, 8, 'none', 1), 'accepted'), ((9600, 8, 'even', 1), 'accepted'),
                 ((57600, 7, 'odd', 1), 'accepted'), ((3000000, 8, 'none', 1), 'unsupported_rate'),
                 ((115200, 8, 'none', 2), 'unsupported_format')]


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
    # UART0 on the crystal's 40 MHz, undivided, and CLKDIV's 12 bits, so
    # 9600 baud is too slow (D960).
    line_clocks = (40000000,)
    line_plan = [((460800, 8, 'none', 1), 'accepted'), ((19200, 8, 'odd', 2), 'accepted'),
                 ((57600, 7, 'even', 1), 'accepted'), ((9600, 8, 'none', 1), 'unsupported_rate'),
                 ((115200, 9, 'none', 1), 'unsupported_format')]


def power_on_boot(probe, chip, names):
    """Check cause 1 and readiness; the caller identifies POR or CHIP_PU."""
    cause = probe.read_words('jtag-cold-reset-cause', chip.reset_cause, 1)[0] & 0x3f
    expected = 'CHIP_PU' if chip.name == 'esp32' else 'power-on'
    require(cause == esp.POWER_ON, 'cold reset cause is %#x, not %s' % (cause, expected))
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


def cycle_boot(chip, args, run, open_console, probe, names, settle):
    """Board USB cycle, then the chip's explicitly identified startup proof."""
    require(args.mode == 'boot', 'a startup cycle requires --mode=boot')
    classic = chip.name == 'esp32'
    if classic:
        require(names, 'classic CHIP_PU startup needs the checked image symbols')
        require(args.reset_seconds == 0.1, 'classic CHIP_PU startup requires --reset-seconds=0.1')
    hub = common.InGroup(run, args.hub_group)
    dual = (args.hub, args.port) != (args.console_hub, args.console_port)
    guard = (args.guard_port, args.guard_device)
    console_guard = (args.console_guard_port, args.console_guard_device)

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

    esp.power_cycle(args, off, on)
    settle(run)
    args.pace.before('startup proof')
    # S3 retains the independent true-power-on proof before opening UART.
    cold = power_on_boot(probe, chip, names) if names and not classic else None
    args.pace.before('open startup console')
    console = open_console(run)
    prior = b''
    trace = None
    startup_evidence = None
    failure = None
    if classic:
        index = getattr(run, 'classic_startup_count', 0) + 1
        run.classic_startup_count = index
        trace = run.out / ('classic-startup-%d.bin' % index)
        startup_evidence = dict(startup_reset='CHIP_PU', external_jtag_powered=True,
            rail_discharge='not-established', reset_requested=False, status='not-established')

    def enable_reset():
        nonlocal prior
        require(not common.modem_lines(console.fd)['dtr'], 'DTR would select download mode')
        if classic:
            common.set_lines(console.fd, dtr=False)
            startup_evidence['reset_requested'] = True
        common.set_lines(console.fd, rts=True)
        try:
            time.sleep(args.reset_seconds)
            if classic:
                # EN is still low: preserve older bytes and start the
                # stream before release, so only this reset can satisfy it.
                with console.lock:
                    prior = bytes(console.received)
                    console.received.clear()
        finally:
            common.set_lines(console.fd, rts=False)

    try:
        esp.paced(args, 'chip-enable reset', enable_reset)
        if classic:
            fixed = common.FIXED_READY_SYMBOL in names

            def startup(body):
                log = common.rom_log(body.decode('latin-1'))
                return (log['reset'] == (esp.POWER_ON, 'POWERON_RESET')
                        and log['boot'] is not None and log['boot'][1] == 'SPI_FAST_FLASH_BOOT'
                        and log['entry'] == chip.origin + 1024
                        and (fixed or common.tagged(body, 'b')))
            console.wait(startup, 10, 'the fresh CHIP_PU ROM entry' +
                         ('' if fixed else ' and application boot frame'))
            # Entry is observable before any debug read. A fixed image must
            # have reached its marker; an app must also advance its timer.
            cold = power_on_boot(probe, chip, names)
            cold.update(startup_reset='CHIP_PU', external_jtag_powered=True,
                        rail_discharge='not-established', rom_trace=trace.name)
            startup_evidence.update(cold, status='checked')
        return console, cold
    except BaseException as error:
        failure = error
        if startup_evidence is not None:
            startup_evidence['failure'] = str(error)
        try:
            console.close()
        except OSError as cleanup:
            if startup_evidence is not None:
                startup_evidence['console_close_failure'] = str(cleanup)
            raise error from cleanup  # Keep USBGuardError's no-fallback identity.
        raise
    finally:
        if trace is not None:
            def retain():
                with console.lock:
                    received = bytes(console.received)
                trace.write_bytes(received)
                trace.with_suffix('.txt').write_text(received.decode('latin-1'))
                trace.with_name(trace.stem + '-prior.bin').write_bytes(prior)
                common.write_json(trace.with_suffix('.json'), startup_evidence)
            try:
                retain()
            except OSError as error:
                if failure is None:
                    raise
                failure.add_note('startup evidence retention failed: ' + str(error))


def inspection_contract(args):
    """Refuse workflow-changing combinations before any helper or rig access."""
    require(args.mode == 'boot', '--inspect-boot requires --mode=boot')
    require(not args.record, '--inspect-boot is observational and cannot write --record')
    require(args.bundle, '--inspect-boot needs the checked bundle prepared by environments/boards/run.py')
    require(not args.recover and not args.image_control,
            '--inspect-boot cannot run recovery or image controls')


DOWNLOAD_BOOT = re.compile(rb'boot:0x([0-9a-fA-F]+)\s+\(DOWNLOAD_BOOT(?:\([^\r\n)]*\))?\)')


def reset_diagnostic_contract(chip, args):
    """The reviewed CH340 classic-ESP32 setup, never a board acceptance run."""
    require(chip.name == 'esp32', '--diagnose-reset supports only classic ESP32')
    require(args.mode == 'boot', '--diagnose-reset requires --mode=boot')
    require(not args.record, '--diagnose-reset cannot write --record')
    require(args.bundle, '--diagnose-reset needs the checked bundle prepared by environments/boards/run.py')
    require(not args.inspect_boot, '--diagnose-reset cannot combine with --inspect-boot')
    require(not args.recover and not args.image_control,
            '--diagnose-reset cannot run recovery or image controls')
    require(args.arty_serial, '--diagnose-reset requires the off-cascade Arty guard')
    require(args.serial == args.console_device == '1a86:7523',
            '--diagnose-reset requires the reviewed CH340 identity 1a86:7523')
    require(args.hub == args.console_hub and args.port == args.console_port,
            '--diagnose-reset requires the board and CH340 at the same USB location')
    require(args.port != args.guard_port and args.console_port != args.console_guard_port,
            '--diagnose-reset cannot select a guarded USB port')


def classic_download_reset(fd):
    """Espressif esptool v5.1.0 ClassicReset, reset.py lines 91-98."""
    common.set_lines(fd, dtr=False)
    common.set_lines(fd, rts=True)
    time.sleep(0.1)
    common.set_lines(fd, dtr=True)
    common.set_lines(fd, rts=False)
    time.sleep(0.05)
    common.set_lines(fd, dtr=False)


def diagnose_reset(chip, args):
    """Confirm ROM download setup, then trace one reset-only invocation."""
    reset_diagnostic_contract(chip, args)
    identity = common.verify_ram_helper(args)
    args.output = args.output.resolve()
    args.output.mkdir(parents=True)
    run = common.Run(args.output)
    run.pace = args.pace
    trace = args.output / 'reset-trace.jsonl'
    result = dict(status='failed', scope='reset-diagnosis', mode='boot', observational=True,
        board=chip.name, helper_identity=identity, flash_written=False, power_switched=False,
        serial_reset_requested=False, core_reset_invocations=0, phases=[],
        internal_reset_attempt_limit=3, final_state='not-established')
    began = time.monotonic()
    lock = common.rig_lock('esp32 reset diagnosis')
    console = None

    def phase(name, operation):
        started = time.monotonic()
        entry = dict(name=name, status='failed')
        try:
            value = operation()
            entry['status'] = 'completed'
            return value
        finally:
            entry['seconds'] = round(time.monotonic() - started, 6)
            result['phases'].append(entry)

    try:
        elf, _, _ = esp.build(run, args, chip)  # Retain checked provenance, never flash it.
        result['bundle_elf_sha256'] = common.sha(elf)
        lock.acquire()
        args.pace.before('reset diagnostic topology')
        common.off_cascade(args.arty_serial, args.cascade)
        hub = common.InGroup(run, args.hub_group)
        phase('topology', lambda: common.wait_for_hub(hub, args.hub,
            [(args.port, args.serial), (args.guard_port, args.guard_device),
             (args.console_guard_port, args.console_guard_device)], args.enumerate_seconds))
        location = '%s.%d' % (args.console_hub, args.console_port)
        path = phase('find-console', lambda: common.wait_for_tty_at(location, args.enumerate_seconds))
        args.pace.before('open diagnostic console')
        console = common.TtyConsole(path, quiet=True)
        lines = common.modem_lines(console.fd)
        require(not lines['dtr'] and not lines['rts'], 'the diagnostic console did not open with inactive lines')
        with console.lock:
            first = len(console.received)

        def select_download():
            result['serial_reset_requested'] = True
            classic_download_reset(console.fd)
        phase('classic-download-reset', lambda: esp.paced(args, 'classic download reset', select_download))
        stream = phase('confirm-download-rom', lambda: console.wait(
            lambda body: DOWNLOAD_BOOT.search(body[first:]) is not None,
            args.control_seconds, 'ROM DOWNLOAD_BOOT after the classic reset'))[first:]
        boot = DOWNLOAD_BOOT.search(stream)
        require(boot is not None, 'the classic reset did not produce a ROM DOWNLOAD_BOOT message')
        (args.output / 'download-rom.bin').write_bytes(stream)
        result['download_rom'] = dict(confirmed=True, boot_code=int(boot.group(1), 16))
        require(common.modem_lines(console.fd) == dict(dtr=False, rts=False),
                'the classic reset did not release DTR and RTS')
        command = [args.probe_rs, '--log-file', trace, 'reset', '--method', 'core', '--core', '0',
                   '--chip', chip.probe_chip, '--probe', args.probe]

        def core_reset():
            result['core_reset_invocations'] += 1
            run.command('reset-diagnostic', command, timeout=120)
        phase('core-reset', lambda: esp.paced(args, 'diagnostic core reset', core_reset))
        require(trace.is_file() and trace.stat().st_size > 0, 'probe-rs produced no reset diagnostic trace')
        result['status'] = 'observed'
    except (common.Failed, OSError, subprocess.TimeoutExpired) as error:
        common.fail(result, error)
    finally:
        if console:
            # Deassert both lines together, including a partly completed
            # sequence. This never pulses EN to return to the old app.
            try:
                common.quiet_lines(console.fd)
                result['final_modem_lines'] = common.modem_lines(console.fd)
                require(result['final_modem_lines'] == dict(dtr=False, rts=False),
                        'diagnostic cleanup did not release DTR and RTS')
            except (common.Failed, OSError) as error:
                result['status'] = 'failed'
                result['cleanup_failure'] = str(error)
            try:
                console.close()
            except OSError as error:
                result['status'] = 'failed'
                result['console_close_failure'] = str(error)
            (args.output / 'uart.bin').write_bytes(bytes(console.received))
            (args.output / 'rom-trace.txt').write_text(bytes(console.received).decode('latin-1'))
        result['reset_trace'] = (dict(path=trace.name, bytes=trace.stat().st_size, sha256=common.sha(trace))
            if trace.is_file() else dict(path=trace.name, status='not-created'))
        common.retain_kernel_usb(args.pace, result)
        lock.release()
        result.update(seconds=round(time.monotonic() - began, 3), commands=run.commands)
        common.write_result(args.output / 'result.json', result, run)
    print('reset diagnosis %s: %s (diagnostic only; final execution state not established)' %
          (result['status'], args.output))
    return 0 if result['status'] == 'observed' else 1


def rom_trace_contract(chip, args):
    """One reviewed EN reset and bounded UART observation, no board verdict."""
    require(chip.name == 'esp32', '--trace-rom supports only classic ESP32')
    require(args.mode == 'boot', '--trace-rom requires --mode=boot')
    require(not args.record, '--trace-rom cannot write --record')
    require(args.bundle, '--trace-rom needs the checked bundle prepared by environments/boards/run.py')
    require(not args.inspect_boot and not args.diagnose_reset,
            '--trace-rom cannot combine with --inspect-boot or --diagnose-reset')
    require(not args.recover and not args.image_control,
            '--trace-rom cannot run recovery or image controls')
    require(args.arty_serial, '--trace-rom requires the off-cascade Arty guard')
    require(args.serial == args.console_device == '1a86:7523',
            '--trace-rom requires the reviewed CH340 identity 1a86:7523')
    require(args.hub == args.console_hub and args.port == args.console_port,
            '--trace-rom requires the board and CH340 at the same USB location')
    require(args.port != args.guard_port and args.console_port != args.console_guard_port,
            '--trace-rom cannot select a guarded USB port')


def trace_rom(chip, args):
    """Capture one normal-boot ROM trace; never flash, probe or switch power."""
    rom_trace_contract(chip, args)
    identity = common.verify_ram_helper(args)
    args.output = args.output.resolve()
    args.output.mkdir(parents=True)
    run = common.Run(args.output)
    run.pace = args.pace
    result = dict(status='failed', scope='rom-trace', observational=True,
        mode='boot', board=chip.name, helper_identity=identity,
        flash_written=False, power_switched=False, reset_requested=False,
        core_reset_invocations=0, capture_seconds=2.5, reset_assert_seconds=0.1,
        phases=[], line_changes=[], final_state='not-established')
    began = time.monotonic()
    lock = common.rig_lock('esp32 ROM trace')
    console = None
    first = 0

    def phase(name, operation):
        started = time.monotonic()
        entry = dict(name=name, status='failed')
        try:
            value = operation()
            entry['status'] = 'completed'
            return value
        finally:
            entry['seconds'] = round(time.monotonic() - started, 6)
            result['phases'].append(entry)

    def set_line(**setting):
        common.set_lines(console.fd, **setting)
        result['line_changes'].append(dict(setting=setting,
            seconds=round(time.monotonic() - began, 6)))

    try:
        elf, _, _ = esp.build(run, args, chip)  # Checked bundle provenance only.
        result['bundle_elf_sha256'] = common.sha(elf)
        lock.acquire()
        args.pace.before('ROM trace topology')
        common.off_cascade(args.arty_serial, args.cascade)
        hub = common.InGroup(run, args.hub_group)
        phase('topology', lambda: common.wait_for_hub(hub, args.hub,
            [(args.port, args.serial), (args.guard_port, args.guard_device),
             (args.console_guard_port, args.console_guard_device)], args.enumerate_seconds))
        location = '%s.%d' % (args.console_hub, args.console_port)
        path = phase('find-console', lambda: common.wait_for_tty_at(location, args.enumerate_seconds))
        args.pace.before('open ROM trace console')
        console = common.TtyConsole(path, quiet=True)
        result['initial_modem_lines'] = common.modem_lines(console.fd)
        require(result['initial_modem_lines'] == dict(dtr=False, rts=False),
                'the ROM trace console did not open with inactive lines')
        with console.lock:
            first = len(console.received)

        def enable_reset():
            # esptool v5.1.0 reset.py HardReset: GPIO0 stays released;
            # active RTS holds EN low, then its release starts normal boot.
            set_line(dtr=False)
            result['reset_requested'] = True
            set_line(rts=True)
            try:
                time.sleep(0.1)
            finally:
                set_line(rts=False)
            result['released_modem_lines'] = common.modem_lines(console.fd)
            require(result['released_modem_lines'] == dict(dtr=False, rts=False),
                    'the ROM trace reset did not release DTR and RTS')
        phase('chip-enable-reset', lambda: esp.paced(args, 'ROM trace EN reset', enable_reset))

        def capture():
            time.sleep(2.5)
            args.pace.check('ROM trace capture')
        phase('capture-rom', capture)
        result['status'] = 'observed'
    except (common.Failed, OSError, subprocess.TimeoutExpired) as error:
        common.fail(result, error)
    finally:
        if console:
            try:
                common.quiet_lines(console.fd)
                result['final_modem_lines'] = common.modem_lines(console.fd)
                require(result['final_modem_lines'] == dict(dtr=False, rts=False),
                        'ROM trace cleanup did not release DTR and RTS')
            except (common.Failed, OSError) as error:
                result['status'] = 'failed'
                result['cleanup_failure'] = str(error)
            try:
                console.close()
            except OSError as error:
                result['status'] = 'failed'
                result['console_close_failure'] = str(error)
            received = bytes(console.received)
            (args.output / 'uart.bin').write_bytes(received)
            (args.output / 'rom-trace.bin').write_bytes(received[first:])
            (args.output / 'rom-trace.txt').write_text(received[first:].decode('latin-1'))
            result['uart_bytes'] = len(received)
            result['rom_bytes'] = len(received) - first
        common.retain_kernel_usb(args.pace, result)
        lock.release()
        result.update(seconds=round(time.monotonic() - began, 3), commands=run.commands)
        common.write_result(args.output / 'result.json', result, run)
    print('ROM trace %s: %s (reset_requested=%s; observations only, no board verdict)' %
          (result['status'], args.output, result['reset_requested']))
    return 0 if result['status'] == 'observed' else 1


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
            for name, address, count in (
                    ('classic-rom-cache-flush', 0x40009a14, 28),
                    ('classic-rom-cache-read-disable', 0x40009ab8, 23),
                    ('classic-rom-cache-control-literals', 0x40009944, 3),
                    ('classic-rom-cache-idle-literal', 0x40009ab4, 1)):
                read(probe, name, address, count,
                     role='ROM cache implementation bytes; observations only, active image unknown')
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
        common.fail(result, error)
    finally:
        common.retain_kernel_usb(args.pace, result)
        lock.release()
        result.update(seconds=round(time.monotonic() - began, 3), commands=run.commands)
        common.write_result(args.output / 'result.json', result, run)
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
    parser.add_argument('--diagnose-reset', action='store_true',
                        help='classic ESP32 boot mode only: confirm ROM download setup and trace one reset-only invocation; no flash or record')
    parser.add_argument('--trace-rom', action='store_true',
                        help='classic ESP32 boot mode only: pulse EN once with GPIO0 released and capture 2.5 seconds of ROM UART; no flash, probe, power switch or record')
    args = parser.parse_args()
    if args.trace_rom:
        rom_trace_contract(chip, args)
    if args.diagnose_reset:
        reset_diagnostic_contract(chip, args)
    if args.inspect_boot:
        inspection_contract(args)
    common.board_preflight(args, chip.name)
    common.rerun_in_group(args.hub_group)
    if args.inspect_boot:
        esp.required_tools(args)
        return inspect_boot(chip, args)
    common.place_hubs(parser, args, 'hub', 'console_hub')
    esp.required_tools(args)
    if args.trace_rom:
        return trace_rom(chip, args)
    if args.diagnose_reset:
        return diagnose_reset(chip, args)
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
        return cycle_boot(chip, args, run, open_console, probe, names, settle)

    return esp.run_board(chip, args, console_for, cycle, settle)
