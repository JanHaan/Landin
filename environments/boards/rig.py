#!/usr/bin/env python3
"""The rig's own setup operations, beside the board tools.

    python3 environments/boards/rig.py load-probehive --bitstream PATH
    python3 environments/boards/rig.py record-probehive-load --bitstream PATH --reason TEXT
    python3 environments/boards/rig.py verify

probehive's Arty holds its bitstream in SRAM, and the gateware names itself
with the constant LiteX identifier "probehive", so which bitstream is loaded
cannot be read back from it.  These commands keep the answer instead, in
RIG_STATE/probehive-loaded.json: the loaded file's SHA-256, when, the kernel
boot it was loaded in, and the Arty FTDI's USB bus and device numbers then.

`load-probehive` takes the rig lock, refuses a bitstream other than the one
environments/boards/rig.json pins, loads it with `openFPGALoader -b arty`
and records it; it is the only command here that touches the Arty.
`record-probehive-load` records a bitstream the operator says is already
loaded, with the reason, and loads nothing.  `verify`, which the gate runs
before any hardware, accepts the record only while its hash is the pin,
its boot is the current one and the Arty has not enumerated again since:
a new device number means it may have lost power, and its bitstream with it.

Nothing here needs more than the standard library, so
scripts/tests/test_board_rig.py runs it with a fake sysfs, boot id and
loader.
"""

import argparse
import datetime
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import common  # noqa: E402
from common import NeedsOperator, ToolMismatch, Unavailable, require  # noqa: E402

RIG = HERE / 'rig.json'
LOADED = 'probehive-loaded.json'
USB_SYSFS = Path('/sys/bus/usb/devices')
BOOT_ID = Path('/proc/sys/kernel/random/boot_id')
PROBEHIVE_FILES = ('flake.nix', 'flake.lock', 'scripts/dap_bridge.py', 'scripts/dap_udp.py',
                   'scripts/gpio.py', 'build/slots_ci/generated/rig.json',
                   'build/slots_ci/generated/csr.json')
SHA256 = set('0123456789abcdef')


def is_sha256(value):
    return isinstance(value, str) and len(value) == 64 and set(value) <= SHA256


def load_rig(path=RIG):
    """environments/boards/rig.json, refused unless its shape is the one
    format_version 1 describes; the ports are checked by gate.py."""
    try:
        rig = json.loads(Path(path).read_text())
    except (OSError, ValueError) as error:
        raise common.Failed('cannot read the rig description %s: %s' % (path, error)) from error
    require(isinstance(rig, dict) and rig.get('format_version') == 1,
            'the rig description %s is not format_version 1' % path)
    require(isinstance(rig.get('arty_serial'), str) and rig['arty_serial'],
            'the rig description names no arty_serial')
    hive = rig.get('probehive')
    require(isinstance(hive, dict) and isinstance(hive.get('files'), dict)
            and isinstance(hive.get('bitstream'), dict),
            'the rig description has no probehive files and bitstream')
    require(isinstance(hive.get('commit'), str) and len(hive['commit']) == 40,
            'the rig description pins no probehive commit')
    require(sorted(hive['files']) == sorted(PROBEHIVE_FILES)
            and all(is_sha256(value) for value in hive['files'].values()),
            'the rig description must pin the SHA-256 of exactly %s' % ', '.join(PROBEHIVE_FILES))
    require(is_sha256(hive['bitstream'].get('sha256')) and isinstance(hive['bitstream'].get('path'), str),
            'the rig description pins no bitstream SHA-256')
    require(isinstance(rig.get('ports'), dict) and rig['ports'], 'the rig description has no ports')
    return rig


def probehive_files(rig, directory):
    """Each pinned probehive runtime file under DIRECTORY with its expected
    and actual SHA-256; refuses an absent one as a setup the rig lacks and
    a different one as a mismatch."""
    directory = Path(directory)
    checked = {}
    for name, expected in sorted(rig['probehive']['files'].items()):
        path = directory / name
        require(path.is_file(), 'the probehive runtime at %s has no %s: install probehive %s there'
                % (directory, name, rig['probehive']['commit']), common.NeedsSetup)
        checked[name] = dict(expected=expected, actual=common.sha(path))
    wrong = [name for name, entry in checked.items() if entry['expected'] != entry['actual']]
    require(not wrong, 'the probehive runtime at %s is not commit %s: %s differ from the pins in'
            ' environments/boards/rig.json; install the pinned runtime'
            % (directory, rig['probehive']['commit'], ', '.join(wrong)), ToolMismatch)
    return checked


def boot_id(path=BOOT_ID):
    return Path(path).read_text().strip()


def arty(serial, sysfs=USB_SYSFS):
    """Where the Arty's FTDI is now: its sysfs name and path and its bus
    and device numbers, which change whenever it enumerates again."""
    location = common.device_location(serial, sysfs)
    require(location is not None, 'no USB device with serial %s, the Arty, is attached' % serial,
            Unavailable)
    device = Path(sysfs) / location
    try:
        busnum = int((device / 'busnum').read_text().strip())
        devnum = int((device / 'devnum').read_text().strip())
    except (OSError, ValueError) as error:
        raise Unavailable('cannot read the Arty\'s bus and device numbers at %s: %s'
                          % (device, error)) from error
    return dict(serial=serial, location=location, sysfs_path=str(device.resolve()),
                busnum=busnum, devnum=devnum)


def pinned_bitstream(rig, bitstream):
    """The SHA-256 of BITSTREAM, refused unless it is the pinned one."""
    bitstream = Path(bitstream)
    require(bitstream.is_file(), 'no bitstream file %s' % bitstream)
    found, pinned = common.sha(bitstream), rig['probehive']['bitstream']['sha256']
    require(found == pinned, 'the bitstream %s has SHA-256 %s, not %s, the one'
            ' environments/boards/rig.json pins for probehive %s'
            % (bitstream, found, pinned, rig['probehive']['commit']), ToolMismatch)
    return found


def record(rig, bitstream, method, reason, sysfs, boot_id_path, now):
    return dict(format_version=1, sha256=pinned_bitstream(rig, bitstream),
                bitstream=str(Path(bitstream).resolve()), method=method, reason=reason,
                loaded_at=now().isoformat(timespec='seconds'), boot_id=boot_id(boot_id_path),
                probehive_commit=rig['probehive']['commit'], arty=arty(rig['arty_serial'], sysfs))


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc)


def load_probehive(bitstream, rig, state=None, loader='openFPGALoader', run=subprocess.run,
                   lock=None, sysfs=USB_SYSFS, boot_id_path=BOOT_ID, now=utc_now):
    """Load the pinned BITSTREAM into the Arty under the rig lock and
    record it."""
    state = Path(common.RIG_STATE if state is None else state)
    with (lock or common.rig_lock('rig.py load-probehive')):
        pinned_bitstream(rig, bitstream)
        arty(rig['arty_serial'], sysfs)
        loaded = run([str(loader), '-b', 'arty', str(bitstream)])
        require(loaded.returncode == 0, '%s -b arty %s failed (%d); nothing was recorded'
                % (loader, bitstream, loaded.returncode))
        kept = record(rig, bitstream, 'openFPGALoader -b arty', None, sysfs, boot_id_path, now)
        common.write_state(state / LOADED, json.dumps(kept, indent=2) + '\n', state)
    return kept


def record_load(bitstream, reason, rig, state=None, lock=None, sysfs=USB_SYSFS,
                boot_id_path=BOOT_ID, now=utc_now):
    """Record that the pinned BITSTREAM is already loaded, as the operator
    says for REASON, without loading anything."""
    require(reason and reason.strip(), 'say why the loaded bitstream is known: --reason TEXT')
    state = Path(common.RIG_STATE if state is None else state)
    with (lock or common.rig_lock('rig.py record-probehive-load')):
        kept = record(rig, bitstream, 'recorded by the operator', ' '.join(reason.split()),
                      sysfs, boot_id_path, now)
        common.write_state(state / LOADED, json.dumps(kept, indent=2) + '\n', state)
    return kept


def verify(rig, state=None, sysfs=USB_SYSFS, boot_id_path=BOOT_ID):
    """The load record, accepted only while it names the pinned bitstream,
    the current boot and the Arty as it enumerated then."""
    state = Path(common.RIG_STATE if state is None else state)
    path = state / LOADED
    load = ('load it with `python3 environments/boards/rig.py load-probehive --bitstream PATH`,'
            ' or, if the Arty runs the pinned bitstream already, record that with'
            ' `python3 environments/boards/rig.py record-probehive-load --bitstream PATH'
            ' --reason TEXT`')
    try:
        kept = json.loads(path.read_text())
    except FileNotFoundError:
        raise NeedsOperator('no record of the bitstream loaded into probehive\'s Arty at %s; %s'
                            % (path, load)) from None
    except (OSError, ValueError) as error:
        raise NeedsOperator('the load record %s cannot be read: %s; %s' % (path, error, load)) from error
    require(isinstance(kept, dict) and kept.get('format_version') == 1
            and isinstance(kept.get('arty'), dict),
            'the load record %s is not format_version 1; %s' % (path, load), NeedsOperator)
    pinned = rig['probehive']['bitstream']['sha256']
    require(kept.get('sha256') == pinned, 'the loaded bitstream %s is not %s, the one'
            ' environments/boards/rig.json pins; %s' % (kept.get('sha256'), pinned, load), ToolMismatch)
    current = boot_id(boot_id_path)
    require(kept.get('boot_id') == current, 'the bitstream was recorded in boot %s, and this is'
            ' boot %s: the Arty may have lost power and its bitstream since; check it, then %s'
            % (kept.get('boot_id'), current, load), NeedsOperator)
    now = arty(rig['arty_serial'], sysfs)
    then = kept['arty']
    moved = [field for field in ('location', 'busnum', 'devnum') if then.get(field) != now[field]]
    require(not moved, 'the Arty enumerated again since its bitstream was recorded (%s, then %s, now'
            ' %s): it may have lost power and its bitstream; check it, then %s'
            % (', '.join(moved), ', '.join(str(then.get(field)) for field in moved),
               ', '.join(str(now[field]) for field in moved), load), NeedsOperator)
    return kept


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--rig', type=Path, default=RIG, help='the rig description')
    commands = parser.add_subparsers(dest='command', required=True)
    load = commands.add_parser('load-probehive', help='load the pinned bitstream and record it')
    load.add_argument('--bitstream', type=Path, required=True)
    load.add_argument('--loader', default='openFPGALoader')
    vouch = commands.add_parser('record-probehive-load',
                                help='record the pinned bitstream as loaded, loading nothing')
    vouch.add_argument('--bitstream', type=Path, required=True)
    vouch.add_argument('--reason', required=True, help='how the operator knows it is loaded')
    commands.add_parser('verify', help='check the load record against the pin, the boot and the Arty')
    args = parser.parse_args(argv)
    try:
        rig = load_rig(args.rig)
        if args.command == 'load-probehive':
            kept = load_probehive(args.bitstream, rig, loader=args.loader)
        elif args.command == 'record-probehive-load':
            kept = record_load(args.bitstream, args.reason, rig)
        else:
            kept = verify(rig)
    except common.Failed as error:
        print('rig.py %s: %s' % (common.outcome_of(error), error), file=sys.stderr)
        return 1
    print(json.dumps(kept, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
