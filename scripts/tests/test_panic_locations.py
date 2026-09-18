"""Independent off-target panic map identity and coordinate controls."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class PanicLocations(unittest.TestCase):
    def test_coordinates_and_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            assembly = root / 'program.s'
            assembly.write_bytes(b'assembly\n')
            table = root / 'program.sources.json'
            path = b'folder:with"quotes/\xff.ldn'
            table.write_text(json.dumps({
                'build_id': 'a' * 64,
                'assembly_sha256': hashlib.sha256(assembly.read_bytes()).hexdigest(),
                'files': [{'file_id': 2, 'path_hex': path.hex(),
                           'panic_base': 101, 'byte_length': 19,
                           'line_offsets': [0, 5, 12]}]}))
            command = [sys.executable, ROOT / 'scripts/source-location.py', table]
            for kind, name in enumerate(('out_of_range', 'overflow',
                                         'bad_conversion', 'unreachable')):
                args = command + ['--panic-site', str(101 + 4 * 14 + kind)]
                result = subprocess.run(args + ['--assembly', assembly],
                                        capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, path + f':3:3 ({name})\n'.encode())
                for identity in ([], ['--build-id', 'b' * 64]):
                    self.assertNotEqual(subprocess.run(args + identity,
                        capture_output=True, timeout=10).returncode, 0)
            for site in (0, -1, 100, 181, 2**32):
                result = subprocess.run(command + ['--panic-site', str(site),
                    '--assembly', assembly], capture_output=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
            assembly.write_bytes(b'other assembly\n')
            self.assertNotEqual(subprocess.run(command + ['--panic-site', '101',
                '--assembly', assembly], capture_output=True, timeout=10).returncode, 0)


if __name__ == '__main__':
    unittest.main()
