"""The bounded QEMU remote-protocol oracle; no guest instructions are changed."""
import json
import os
import socket
import subprocess
import time


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


def observe(qemu, chip, elf, symbols, output, timeout=20):
    """Stop before the compiler's stopped loop and read independent trap cells."""
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen(1)
    os.set_inheritable(listener.fileno(), True)
    port = listener.getsockname()[1]
    command = [str(qemu), '-M', chip, '-nographic', '-monitor', 'none',
               '-serial', 'none', '-kernel', str(elf), '-S',
               '-chardev', 'socket,id=gdb,fd=%d,server=on,wait=off,nodelay=on'
               % listener.fileno(), '-gdb', 'chardev:gdb']
    tick = time.monotonic()
    with (output / 'qemu.log').open('w') as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                                   pass_fds=(listener.fileno(),), start_new_session=True)
        listener.close()
        connection = None
        remote = None
        try:
            connection = socket.create_connection(('127.0.0.1', port), timeout=timeout)
            connection.settimeout(timeout)
            remote = Remote(connection)
            remote.command('qSupported')
            stop = symbols['_landin_firmware_stopped']
            if remote.command('Z0,%x,3' % stop) != 'OK':
                raise RuntimeError('QEMU refused the stopped-label breakpoint')
            bottom = symbols['_landin_firmware_stack_bottom']
            guard = bytes.fromhex('3cc35aa5') * 4
            if remote.command('M%x,%x:%s' % (bottom, len(guard), guard.hex())) != 'OK':
                raise RuntimeError('QEMU refused the stack guard write')
            stopped = remote.command('c')
            if not stopped.startswith(('S05', 'T05')):
                raise RuntimeError('QEMU stopped unexpectedly: ' + stopped)
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
            return {'values': values, 'remote': remote.transcript,
                    'qemu_command': command, 'elapsed_seconds': time.monotonic() - tick}
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
