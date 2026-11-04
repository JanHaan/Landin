"""Installed-tool verification shared with the retained embedded environment."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(ROOT / 'environments/cortex-m'))
from setup import (AREAS, ESPRESSIF_XTENSA, XTENSA, installed_tools,  # noqa: E402
                   inventory, sha, supported_host, xtensa_archive)
from run import current_lock, unchanged  # noqa: E402


class Tools:
    def __init__(self, root=None, qemu=None):
        self.root = installed_tools(root) if root is not None else None
        self.before = None
        self.installed = None
        if self.root is not None:
            supported_host()
            self.installed = json.loads((self.root / 'installation.json').read_text())
            current_lock(self.root, self.installed)
            expected = {key: xtensa_archive()[key] for key in ('version', 'sha256')}
            if self.installed.get('xtensa') != expected:
                raise RuntimeError('installed Xtensa archive differs from environments/pins.sh; '
                                   'install a fresh --tools root with cortex-m/setup.py')
            self.before = {area: inventory(self.root / area) for area in AREAS}
            unchanged(self.root, self.installed, self.before)
            selected = self.root / ESPRESSIF_XTENSA / 'bin/qemu-system-xtensa'
            if qemu is not None and Path(qemu).resolve() != selected.resolve():
                raise RuntimeError('--qemu differs from the locked --tools QEMU')
            self.qemu = selected
            os.environ['PATH'] = str(self.root / XTENSA / 'bin') + os.pathsep + os.environ['PATH']
            libraries = self.root / 'root/usr/lib/x86_64-linux-gnu'
            os.environ['LD_LIBRARY_PATH'] = str(libraries) + ':' + str(libraries / 'pulseaudio')
        elif qemu is not None:
            self.qemu = Path(qemu).resolve()
        else:
            raise RuntimeError('pass --tools DIRECTORY, or --qemu PATH for a focused run')
        self.record = {'locked_installation': self.installed, 'tools': {}}
        self.check('qemu', self.qemu, ['--version'], '9.2.2 (esp_develop_9.2.2_20260417)')
        for chip in ('esp32', 'esp32s3'):
            prefix = 'xtensa-' + chip + '-elf-'
            for tool, expected in (('gcc', '16.1.0'), ('as', '2.46')):
                path = shutil.which(prefix + tool)
                if path is None:
                    raise RuntimeError('missing ' + prefix + tool + '; install the pinned tool wrappers')
                if self.root and not Path(path).resolve().is_relative_to(self.root / XTENSA):
                    raise RuntimeError('selected tool is outside the locked Xtensa installation: ' + path)
                self.check(chip + '-' + tool, Path(path), ['--version'], expected)
            directory = subprocess.check_output([prefix + 'gcc', '-mabi=windowed',
                                                  '-print-multi-directory'], text=True).strip()
            if directory != chip:
                raise RuntimeError('wrong Xtensa configuration/multilib: ' + prefix + directory)
            self.record['tools'][chip + '-multilib'] = directory

    def check(self, name, path, arguments, expected):
        result = subprocess.run([str(path), *arguments], text=True, capture_output=True, timeout=30)
        if result.returncode or expected not in result.stdout:
            raise RuntimeError(name + ' version mismatch: ' + result.stdout + result.stderr)
        self.record['tools'][name] = {'path': str(path), 'sha256': sha(path),
                                      'version': result.stdout.strip()}

    def finish(self, output):
        if self.root:
            after = {area: inventory(self.root / area) for area in AREAS}
            if after != self.before:
                raise RuntimeError('locked tool installation changed during execution')
        (output / 'tools.json').write_text(json.dumps(self.record, indent=2) + '\n')
