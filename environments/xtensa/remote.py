"""The bounded QEMU remote-protocol oracle; no guest instructions are changed."""
import json
import os
import socket
import subprocess
import time


def configuration(chip, memory_profile='chip'):
    """Keep real chip maps separate from explicitly virtual SIM memory."""
    if chip not in ('esp32', 'esp32s3') or memory_profile not in ('chip', 'sim'):
        raise ValueError('unknown Xtensa CPU or memory profile')
    simulated = memory_profile == 'sim'
    # The pinned SIM board sizes config->sysram from -m; both exact CPU
    # configurations place it at 0x60000000. This is virtual memory only:
    # https://github.com/espressif/qemu/blob/40edccac415693c5130f91c01d84176ae6008566/hw/xtensa/sim.c
    iram, dram = ((0x60000000, 0x61000000) if simulated else
                  (0x40080000, 0x3ffb0000) if chip == 'esp32' else
                  (0x40378000, 0x3fca8000))
    return {
        'memory_profile': memory_profile,
        'evidence_scope': 'EMULATOR_ONLY' if simulated else 'CHIP_MEMORY_MAP',
        'machine': 'sim' if simulated else chip,
        'cpu': chip, 'cpu_level': 'xtensa-' + chip,
        'qemu_arguments': ['-M', 'sim', '-cpu', chip, '-m', '64M'] if simulated else ['-M', chip],
        'regions': {'IRAM': {'origin': iram, 'bytes': 16 * 1024 * 1024 if simulated else 128 * 1024},
                    'DRAM': {'origin': dram, 'bytes': 48 * 1024 * 1024 if simulated else 128 * 1024}},
        'stack_bytes': 8 * 1024 * 1024 if simulated else 16 * 1024,
        'startup': 'generic loader selects the ELF entry on reset' if simulated else 'chip ELF loader',
        **({'virtual_ram': {'origin': 0x60000000, 'bytes': 64 * 1024 * 1024}}
           if simulated else {})}


class Remote:
    def __init__(self, connection):
        self.socket = connection
        self.transcript = []

    def byte(self):
        result = self.socket.recv(1)
        if not result:
            raise RuntimeError('QEMU closed its remote-protocol connection')
        return result

    def command(self, text):
        payload = text.encode('ascii')
        packet = b'$' + payload + b'#' + ('%02x' % (sum(payload) & 255)).encode()
        self.socket.sendall(packet)
        return self.reply(text)

    def reply(self, text):
        while True:
            first = self.byte()
            if first == b'+':
                continue
            if first != b'$':
                raise RuntimeError('unexpected remote reply: ' + repr(first))
            data = bytearray()
            while (one := self.byte()) != b'#':
                data += one
            checksum = self.byte() + self.byte()
            if int(checksum, 16) != sum(data) & 255:
                raise RuntimeError('remote reply checksum mismatch')
            self.socket.sendall(b'+')
            reply = data.decode('ascii')
            self.transcript.append([text, reply])
            #  The stub can send console output before the stop packet.
            if reply.startswith('O') and reply != 'OK':
                continue
            return reply

    def memory(self, address, length):
        reply = self.command('m%x,%x' % (address, length))
        if reply.startswith('E') or len(reply) != length * 2:
            raise RuntimeError('remote memory read failed: ' + reply)
        return bytes.fromhex(reply)

    def word(self, address):
        return int.from_bytes(self.memory(address, 4), 'little')


def observe(qemu, chip, elf, symbols, output, timeout=20, extra_breakpoint=None,
            memory_profile='chip'):
    """Stop at wrapper completion or firmware failure; read independent cells."""
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen(1)
    os.set_inheritable(listener.fileno(), True)
    port = listener.getsockname()[1]
    profile = configuration(chip, memory_profile)
    image_arguments = (['-device', 'loader,file=' + str(elf).replace(',', ',,') + ',cpu-num=0']
                       if memory_profile == 'sim' else ['-kernel', str(elf)])
    command = [str(qemu), *profile['qemu_arguments'], '-nographic', '-monitor', 'none',
               '-serial', 'none', *image_arguments, '-S',
               '-chardev', 'socket,id=gdb,fd=%d,server=on,wait=off,nodelay=on'
               % listener.fileno(), '-gdb', 'chardev:gdb']
    tick = time.monotonic()
    with (output / 'qemu.log').open('w') as log:
        # Keep the guest in the logged command's process group so parent
        # cancellation reaches it even if Python cannot run its finally.
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                                   pass_fds=(listener.fileno(),))
        listener.close()
        connection = None
        remote = None
        try:
            connection = socket.create_connection(('127.0.0.1', port), timeout=timeout)
            connection.settimeout(timeout)
            remote = Remote(connection)
            remote.command('qSupported')
            startup = None
            if memory_profile == 'sim':
                # The generic loader selects e_entry on CPU reset; SIM's
                # -kernel loader loses that selection to its later reset.
                # Validate the actual starting PC before executing code.
                with elf.open('rb') as image:
                    header = image.read(28)
                if header[:6] != b'\x7fELF\x01\x01' or len(header) != 28:
                    raise RuntimeError('SIM startup requires a little-endian ELF32 image')
                entry = int.from_bytes(header[24:28], 'little')
                if entry != symbols['_landin_firmware_entry']:
                    raise RuntimeError('SIM ELF entry differs from the emitted firmware entry')
                initial = int.from_bytes(bytes.fromhex(remote.command('g'))[:4], 'little')
                if initial != entry:
                    raise RuntimeError('the generic loader did not select the SIM ELF entry')
                startup = {'initial_pc': initial, 'entry_pc': entry, 'selected_pc': initial,
                           'method': 'generic ELF loader reset'}
            stop = symbols['_landin_firmware_stopped']
            if remote.command('Z0,%x,3' % stop) != 'OK':
                raise RuntimeError('QEMU refused the stopped-label breakpoint')
            completed = symbols.get('_landin_xtensa_fixture_stopped')
            if completed is not None and remote.command('Z0,%x,3' % completed) != 'OK':
                raise RuntimeError('QEMU refused the fixture-completion breakpoint')
            if extra_breakpoint is not None and remote.command(
                    'Z0,%x,3' % extra_breakpoint) != 'OK':
                raise RuntimeError('QEMU refused the negative-control breakpoint')
            bottom = symbols['_landin_firmware_stack_bottom']
            guard = bytes.fromhex('3cc35aa5') * 4
            if remote.command('M%x,%x:%s' % (bottom, len(guard), guard.hex())) != 'OK':
                raise RuntimeError('QEMU refused the stack guard write')
            stopped = remote.command('c')
            if not stopped.startswith(('S05', 'T05')):
                raise RuntimeError('QEMU stopped unexpectedly: ' + stopped)
            # Both pinned core-esp32{,s3}/gdb-config.inc.c maps put the
            # 32-bit virtual PC at register 0, packet offset 0; see
            # https://github.com/espressif/qemu/tree/esp-develop-9.2.2-20260417/target/xtensa
            registers = bytes.fromhex(remote.command('g'))
            if len(registers) < 4:
                raise RuntimeError('QEMU returned no program counter')
            pc = int.from_bytes(registers[:4], 'little')
            values = {name: remote.word(address) for name, address in symbols.items()
                      if name in ('_landin_firmware_trap_count',
                                  '_landin_firmware_trap_cause',
                                  '_landin_firmware_trap_pc',
                                  '_landin_xtensa_fixture_status')}
            guard_after = remote.memory(bottom, len(guard))
            if guard_after != guard:
                raise RuntimeError('the guest overwrote the lowest 16 bytes of its stack reservation')
            values['stack_guard'] = guard_after.hex()
            if values.get('_landin_firmware_trap_count'):
                values['trap_instruction'] = remote.memory(
                    values['_landin_firmware_trap_pc'], 3).hex()
            result = {'values': values, 'stop_pc': pc,
                      'configuration': profile,
                      'startup': startup,
                      'expected_stops': {'firmware': stop, 'completion': completed},
                      'remote': remote.transcript, 'qemu_command': command,
                      'elapsed_seconds': time.monotonic() - tick}
            premature = (pc == stop and completed is not None
                         and not values['_landin_firmware_trap_count'])
            if premature or (pc != stop and (completed is None or pc != completed)):
                (output / 'unexpected-stop.json').write_text(
                    json.dumps(result, indent=2) + '\n')
                if premature:
                    raise RuntimeError('firmware stopped before fixture completion without a trap')
                raise RuntimeError('unexpected guest stop PC: ' + hex(pc))
            return result
        except TimeoutError:
            if remote is not None:
                connection.sendall(b'\x03')
                remote.reply('interrupt after timeout')
                remote.command('g')
                (output / 'timeout-remote.json').write_text(
                    json.dumps(remote.transcript, indent=2) + '\n')
            raise RuntimeError('guest timed out; inspect timeout-remote.json')
        finally:
            if connection is not None:
                connection.close()
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
