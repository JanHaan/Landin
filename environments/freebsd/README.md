# FreeBSD VMs

[`vm.py`](vm.py) verifies official release image and base-system archives
against [`lock.json`](lock.json), extracts a private cross sysroot and boots
an architecture-specific QEMU guest from a fresh overlay. It never modifies
the downloaded disk image. The BASIC-CI image enables root SSH with an empty
password; the supervisor exposes it only on a loopback port and tears down
the VM on success or failure. This is test provisioning, outside the
compiler's `Landin.Platform` host boundary.

Each lane raises the guest's data-size ceiling to 4 GiB and removes the
process soft data limit. The unchanged displacement-limit fixture declares
a 2 GiB global array; FreeBSD arm64's default 1 GiB ceiling refuses that
executable before it reaches `main`. This reserves virtual address space,
not 4 GiB of guest RAM.

See the [execution lanes](../../compiler/tests/freebsd/README.md) for commands,
feature confirmation, verdicts and retained evidence.
