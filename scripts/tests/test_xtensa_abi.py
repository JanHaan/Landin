"""The ABI peer cannot count a nonzero result or a processor trap as zero."""
from copy import deepcopy
import unittest

from environments.xtensa import abi


def observed(status=0, traps=0):
    return {'values': {'_landin_firmware_trap_count': traps,
                       '_landin_xtensa_fixture_status': status & 0xffffffff}}


class Oracle(unittest.TestCase):
    def test_success_requires_zero_and_no_processor_trap(self):
        self.assertEqual(abi.check_observation(observed(), 0), 'zero status with no trap')
        for value in (observed(37), observed(-999), observed(traps=1)):
            with self.subTest(value=value), self.assertRaises(RuntimeError):
                abi.check_observation(value, 0)

    def test_nonzero_control_is_checked_and_rejected_as_success(self):
        self.assertIn('rejected', abi.check_observation(observed(37), 37))
        with self.assertRaises(RuntimeError):
            abi.check_observation(observed(0), 37)

    def test_missing_status_is_not_an_implicit_success(self):
        value = deepcopy(observed())
        del value['values']['_landin_xtensa_fixture_status']
        with self.assertRaises(KeyError):
            abi.check_observation(value, 0)


if __name__ == '__main__':
    unittest.main()
