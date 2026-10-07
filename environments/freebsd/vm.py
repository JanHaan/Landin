"""FreeBSD release images and VM transport; no compiler host adapter lives here."""
from contextlib import contextmanager
import hashlib
import json
import lzma
import os
from pathlib import Path
import shlex
import shutil
import socket
import subprocess
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
    def __init__(self, port=None, *, ssh=None, sudo=False):
        self.port = port
        self.sudo = sudo
        self.ssh = shlex.split(ssh) if ssh else ['ssh', '-o', 'BatchMode=yes', '-o', 'LogLevel=ERROR',
                    '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null',
                    '-o', 'ConnectTimeout=5', '-p', str(port), 'root@127.0.0.1']

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


@contextmanager
def boot(arch, image, output, *, port=None):
    # An explicitly supplied port is a development VM (including an SSH tunnel
    # to a local Mac); recurring lanes always provision their own fresh overlay.
    if port:
        yield Guest(port)
        return
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    overlay = output / 'guest.qcow2'
    subprocess.run(['qemu-img', 'create', '-f', 'qcow2', '-F', 'raw', '-b', image,
                    overlay], check=True, capture_output=True)
    network = ['-netdev', f'user,id=net0,hostfwd=tcp:127.0.0.1:{port}-:22',
               '-device', 'virtio-net-pci,netdev=net0']
    common = ['-m', '2048', '-smp', '2', '-display', 'none', '-monitor', 'none',
              '-serial', 'file:' + str(output / 'console.log'), *network]
    if arch == 'amd64':
        require(os.access('/dev/kvm', os.R_OK | os.W_OK), 'x86-64 guest requires accessible KVM')
        argv = ['qemu-system-x86_64', '-accel', 'kvm', '-cpu', 'host', *common,
                '-drive', f'file={overlay},format=qcow2,if=virtio']
    else:
        firmware = next((p for p in (Path('/usr/share/AAVMF/AAVMF_CODE.fd'),
                          Path('/usr/share/qemu/edk2-aarch64-code.fd')) if p.is_file()), None)
        if os.environ.get('LANDIN_FREEBSD_EFI'):
            firmware = Path(os.environ['LANDIN_FREEBSD_EFI'])
        require(firmware is not None and firmware.is_file(), 'arm64 UEFI firmware missing')
        argv = ['qemu-system-aarch64', '-machine', 'virt', '-cpu', 'max', '-bios', firmware,
                *common, '-drive', f'file={overlay},format=qcow2,if=none,id=hd0',
                '-device', 'virtio-blk-pci,drive=hd0']
    (output / 'vm-command.json').write_text(json.dumps(list(map(str, argv)), indent=2) + '\n')
    with (output / 'qemu.log').open('wb') as log:
        process = subprocess.Popen(list(map(str, argv)), stdout=log, stderr=log)
        try:
            guest = Guest(port)
            deadline = time.monotonic() + 600
            while time.monotonic() < deadline:
                require(process.poll() is None, 'VM exited: ' + (output / 'qemu.log').read_text())
                if guest.run('true', timeout=10).returncode == 0:
                    break
                time.sleep(2)
            else:
                raise ValueError('FreeBSD VM did not become ready; see console.log')
            yield guest
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
