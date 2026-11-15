"""FreeBSD release images and VM transport; no compiler host adapter lives here."""
from contextlib import contextmanager
import hashlib
import json
import lzma
import os
from pathlib import Path
import re
import shlex
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.request

HERE = Path(__file__).resolve().parent
LOCK = json.loads((HERE / 'lock.json').read_text())


def require(ok, message):
    if not ok:
        raise ValueError(message)


def sha(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def download(url, destination, digest):
    if not destination.exists():
        temporary = destination.with_suffix(destination.suffix + '.part')
        with urllib.request.urlopen(url, timeout=60) as src, temporary.open('wb') as dst:
            shutil.copyfileobj(src, dst)
        require(sha(temporary) == digest, 'download checksum: ' + url)
        temporary.rename(destination)
    require(sha(destination) == digest, 'cached checksum: ' + str(destination))


def prepare(arch, cache, *, image=True):
    cache.mkdir(parents=True, exist_ok=True)
    release = LOCK['release']
    directory = 'amd64' if arch == 'amd64' else 'aarch64'
    machine = 'amd64' if arch == 'amd64' else 'arm64-aarch64'
    compressed = cache / (arch + '.raw.xz')
    if image:
        download(f'https://download.freebsd.org/releases/CI-IMAGES/{release}/{directory}/Latest/'
                 f'FreeBSD-{release}-{machine}-BASIC-CI.raw.xz', compressed, LOCK[arch]['image'])
    raw = cache / (arch + '.raw')
    if image and not raw.exists():
        temporary = raw.with_suffix('.part')
        with lzma.open(compressed, 'rb') as src, temporary.open('wb') as dst:
            # Preserve the disk image's holes rather than allocating six GB.
            while block := src.read(1024 * 1024):
                if not any(block):
                    dst.seek(len(block), 1)
                else:
                    dst.write(block)
            dst.truncate()
        temporary.rename(raw)
    base = cache / (arch + '-base.txz')
    base_url = ('amd64' if arch == 'amd64' else 'arm64/aarch64')
    download(f'https://download.freebsd.org/releases/{base_url}/{release}/base.txz',
             base, LOCK[arch]['base'])
    sysroot = cache / (arch + '-sysroot')
    if not (sysroot / '.ready').exists():
        sysroot.mkdir(exist_ok=True)
        subprocess.run(['bsdtar', '-xf', base, '-C', sysroot,
                        './lib', './usr/lib', './usr/include'], check=True)
        for path in sysroot.rglob('*'):
            if path.is_symlink() and os.readlink(path).startswith('/'):
                target = sysroot / os.readlink(path).lstrip('/')
                path.unlink()
                path.symlink_to(os.path.relpath(target, path.parent))
        (sysroot / '.ready').write_text(LOCK[arch]['base'] + '\n')
    require((sysroot / '.ready').read_text().strip() == LOCK[arch]['base'],
            'sysroot belongs to another release')
    return raw, sysroot


class Guest:
    """Commands in a guest over SSH.

    A guest this module booted is reached with the key made for its boot
    and held to the host key it reported on its console; `ssh` is a
    caller's whole transport; a bare port is a development VM reached with
    the caller's own identity and known hosts.
    """

    def __init__(self, port=None, *, ssh=None, sudo=False, identity=None, known_hosts=None):
        self.port = port
        self.sudo = sudo
        if ssh:
            self.ssh = shlex.split(ssh)
            return
        self.ssh = ['ssh', '-o', 'BatchMode=yes', '-o', 'LogLevel=ERROR', '-o', 'ConnectTimeout=5']
        if identity is not None:
            for path in (identity, known_hosts):
                # ssh reads whitespace as a list separator and % as a token.
                require(not set(str(path)) & set(' \t"%'), 'unusable SSH key path: ' + str(path))
            self.ssh[1:1] = ['-F', 'none', '-i', str(identity), '-o', 'IdentitiesOnly=yes',
                             '-o', 'UserKnownHostsFile=' + str(known_hosts),
                             '-o', 'GlobalKnownHostsFile=/dev/null',
                             '-o', 'StrictHostKeyChecking=yes', '-o', 'CheckHostIP=no',
                             '-o', 'HostKeyAlgorithms=ssh-ed25519',
                             '-o', 'PreferredAuthentications=publickey']
        self.ssh += ['-p', str(port), 'root@127.0.0.1']

    def run(self, command, *, input=None, timeout=900):
        if self.sudo:
            command = 'sudo -n /bin/sh -c ' + shlex.quote(command)
        return subprocess.run([*self.ssh, command], input=input, capture_output=True,
                              timeout=timeout, check=False)

    def checked(self, command, *, input=None, timeout=900):
        result = self.run(command, input=input, timeout=timeout)
        require(result.returncode == 0, f'guest command failed: {command}\n'
                + (result.stdout + result.stderr).decode(errors='replace')[-4000:])
        return result.stdout

    def put(self, source, destination):
        with source.open('rb') as f:
            self.checked('cat > ' + shlex.quote(str(destination)), input=f.read())


def client_key(directory):
    """A key pair made for one boot, in the caller's private directory."""
    key = directory / 'client'
    subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-C', 'landin-freebsd-lane',
                    '-f', str(key)], check=True, capture_output=True)
    public = (directory / 'client.pub').read_text().strip()
    require(re.fullmatch(r'ssh-ed25519 [A-Za-z0-9+/]+=* landin-freebsd-lane', public),
            'ssh-keygen made an unexpected key: ' + public)
    return key, public


#  What the guest's sshd must say once admission has closed its login.
#  OpenSSH prints prohibit-password by its older name.
ADMITTED = {'permitrootlogin': ('without-password', 'prohibit-password'),
            'passwordauthentication': ('no',), 'kbdinteractiveauthentication': ('no',),
            'permitemptypasswords': ('no',), 'authenticationmethods': ('publickey',)}


def admission(client_public):
    """Commands typed at the guest's root console before any port reaches it.

    The release image admits root over SSH with an empty password.  These
    admit only the boot's client key instead, and the last prints the host
    key the guest made at its first boot, which the client then holds it to.
    """
    commands = [
        'umask 077 && mkdir -p /root/.ssh',
        "printf '%s\\n' " + shlex.quote(client_public) + ' > /root/.ssh/authorized_keys',
        "sed -i '' -E '/^(PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication"
        "|PermitEmptyPasswords|AuthenticationMethods)[[:space:]]/d' /etc/ssh/sshd_config",
        "printf '%s\\n' 'PermitRootLogin prohibit-password' 'PasswordAuthentication no'"
        " 'KbdInteractiveAuthentication no' >> /etc/ssh/sshd_config",
        "printf '%s\\n' 'PermitEmptyPasswords no' 'AuthenticationMethods publickey'"
        " >> /etc/ssh/sshd_config",
        'sshd -t && service sshd restart',
        'sshd -T | grep -E ' + shlex.quote('^(' + '|'.join(ADMITTED) + ') '),
        'cat /etc/ssh/ssh_host_ed25519_key.pub',
    ]
    return commands


class Console:
    """The guest's serial console, on a socket in the caller's private directory.

    Each command is framed by markers the shell computes, so the echo of the
    typed line never matches them.
    """
    LINE = 240  # below FreeBSD's MAX_CANON of 255 bytes for a typed line

    def __init__(self, path, process, deadline):
        self.process, self.deadline, self.received = process, deadline, bytearray()
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        while True:
            self.alive()
            try:
                self.socket.connect(str(path))
                break
            except (FileNotFoundError, ConnectionRefusedError):
                time.sleep(0.05)

    def alive(self):
        require(self.process.poll() is None, 'VM exited before it was admitted; see qemu.log')
        require(time.monotonic() < self.deadline, 'FreeBSD VM did not become ready; see console.log')

    def expect(self, pattern, start=0):
        while True:
            found = re.search(pattern, self.received[start:])
            if found:
                return start + found.start(), start + found.end(), found
            self.alive()
            self.socket.settimeout(1)
            try:
                piece = self.socket.recv(65536)
            except socket.timeout:
                continue
            require(piece, 'the VM closed its console before it was admitted; see console.log')
            self.received.extend(piece)

    def type(self, line):
        require(len(line) < self.LINE, 'console line too long: ' + line)
        self.socket.sendall(line.encode() + b'\r')

    def login(self):
        _, end, _ = self.expect(rb'login: ')
        self.type('root')
        self.expect(rb'# ', end)

    @staticmethod
    def frame(command):
        return "printf '%s-%s\\n' LANDIN BEGIN; " + command + "; printf '%s-%s %s\\n' LANDIN END $?"

    def command(self, command):
        mark = len(self.received)
        self.type(self.frame(command))
        _, begin, _ = self.expect(rb'LANDIN-BEGIN\r?\n', mark)
        end, _, found = self.expect(rb'LANDIN-END (\d+)', begin)
        output = bytes(self.received[begin:end]).decode(errors='replace')
        require(found.group(1) == b'0', f'guest console command failed: {command}\n{output}')
        return output

    def close(self):
        self.socket.close()


def admit(console, client_public):
    """Log in at the console, admit the client key alone, return the host key."""
    console.login()
    outputs = [console.command(command) for command in admission(client_public)]
    said = dict(line.strip().split(None, 1) for line in outputs[-2].splitlines()
                if len(line.split()) == 2)
    require(all(said.get(key) in values for key, values in ADMITTED.items()),
            'guest sshd still admits more than the boot key: ' + repr(said))
    keys = re.findall(r'^(ssh-ed25519 [A-Za-z0-9+/]+=*)', outputs[-1], re.MULTILINE)
    require(len(keys) == 1, 'guest reported no single ed25519 host key: ' + outputs[-1])
    return keys[0]


def forward(path, port):
    """Ask QEMU's monitor to forward a loopback port to the admitted guest."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as monitor:
        monitor.settimeout(30)
        monitor.connect(str(path))
        def reply():
            data = bytearray()
            while not data.endswith(b'(qemu) '):
                piece = monitor.recv(4096)
                require(piece, 'QEMU closed its monitor')
                data.extend(piece)
            return re.sub(rb'\x1b\[[0-9;]*[A-Za-z]', b'', bytes(data)).decode(errors='replace')
        reply()
        monitor.sendall(f'hostfwd_add net0 tcp:127.0.0.1:{port}-:22\n'.encode())
        reply()
        monitor.sendall(b'info usernet\n')
        table = reply()
    return re.search(rf'HOST_FORWARD\]\s+-?\d+\s+127\.0\.0\.1\s+{port}\s+10\.0\.2\.15\s+22\b', table) is not None


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def chardev_path(path):
    # QEMU's option syntax doubles a comma inside a value.
    return str(path).replace(',', ',,')


def qemu_argv(arch, overlay, output, private):
    """The guest's command line: its console and monitor are sockets in the
    private directory, and its network forwards no port until admission."""
    common = ['-m', '2048', '-smp', '2', '-display', 'none',
              '-chardev', 'socket,id=console,server=on,wait=off,path='
              + chardev_path(private / 'console.sock') + ',logfile=' + chardev_path(output / 'console.log'),
              '-serial', 'chardev:console',
              '-monitor', 'unix:' + chardev_path(private / 'monitor.sock') + ',server=on,wait=off',
              '-netdev', 'user,id=net0', '-device', 'virtio-net-pci,netdev=net0']
    if arch == 'amd64':
        require(os.access('/dev/kvm', os.R_OK | os.W_OK), 'x86-64 guest requires accessible KVM')
        return ['qemu-system-x86_64', '-accel', 'kvm', '-cpu', 'host', *common,
                '-drive', f'file={chardev_path(overlay)},format=qcow2,if=virtio']
    firmware = next((p for p in (Path('/usr/share/AAVMF/AAVMF_CODE.fd'),
                      Path('/usr/share/qemu/edk2-aarch64-code.fd')) if p.is_file()), None)
    if os.environ.get('LANDIN_FREEBSD_EFI'):
        firmware = Path(os.environ['LANDIN_FREEBSD_EFI'])
    require(firmware is not None and firmware.is_file(), 'arm64 UEFI firmware missing')
    return ['qemu-system-aarch64', '-machine', 'virt', '-cpu', 'max', '-bios', str(firmware),
            *common, '-drive', f'file={chardev_path(overlay)},format=qcow2,if=none,id=hd0',
            '-device', 'virtio-blk-pci,drive=hd0']


@contextmanager
def boot(arch, image, output, *, port=None):
    # An explicitly supplied port is a development VM (including an SSH tunnel
    # to a local Mac); recurring lanes always provision their own fresh overlay.
    if port:
        yield Guest(port)
        return
    overlay = output / 'guest.qcow2'
    subprocess.run(['qemu-img', 'create', '-f', 'qcow2', '-F', 'raw', '-b', image,
                    overlay], check=True, capture_output=True)
    #  The boot's key, the guest's console and QEMU's monitor are in a
    #  directory only this user can enter, and outside the retained output.
    with tempfile.TemporaryDirectory(prefix='landin-freebsd-') as private:
        private = Path(private)
        identity, public = client_key(private)
        argv = qemu_argv(arch, overlay, output, private)
        (output / 'vm-command.json').write_text(json.dumps(argv, indent=2) + '\n')
        with (output / 'qemu.log').open('wb') as log:
            process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 600
                console = Console(private / 'console.sock', process, deadline)
                try:
                    host_key = admit(console, public)
                finally:
                    console.close()
                for _ in range(8):
                    # Bind-and-close can lose the port to another process; the
                    # pinned host key keeps whoever took it from answering.
                    port = free_port()
                    if forward(private / 'monitor.sock', port):
                        break
                else:
                    raise ValueError('QEMU could not forward a loopback port to the guest')
                known_hosts = private / 'known_hosts'
                known_hosts.write_text(f'[127.0.0.1]:{port} {host_key}\n')
                guest = Guest(port, identity=identity, known_hosts=known_hosts)
                while True:
                    require(process.poll() is None, 'VM exited: ' + (output / 'qemu.log').read_text())
                    if guest.run('true', timeout=10).returncode == 0:
                        break
                    require(time.monotonic() < deadline, 'FreeBSD VM did not answer SSH; see console.log')
                    time.sleep(2)
                yield guest
            finally:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
