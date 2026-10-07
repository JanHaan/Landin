# FreeBSD VMs

[`vm.py`](vm.py) verifies official release image and base-system archives
against [`lock.json`](lock.json), extracts a private cross sysroot and boots
an architecture-specific QEMU guest from a fresh overlay. It never modifies
the downloaded disk image. The BASIC-CI image enables root SSH with an empty
password; the supervisor exposes it only on a loopback port and tears down
the VM on success or failure. This is test provisioning, outside the
compiler's `Landin.Platform` host boundary.

Each lane ensures a guest data-size ceiling of at least 4 GiB and removes the
process soft data limit. The unchanged displacement-limit fixture declares
a 2 GiB global array; FreeBSD arm64's default 1 GiB ceiling refuses that
executable before it reaches `main`. This reserves virtual address space,
not 4 GiB of guest RAM. A temporary ceiling change is restored after the lane.

The recurring gate emits payloads on Linux x86-64, then uses the supplied
`freebsd-amd64` and `freebsd-arm64` self-hosted Linux controllers. Their
FreeBSD 15.1 guests use KVM and host CPU passthrough. These execution jobs
consume the pinned 14.4 sysroot's binaries; they do not compile Landin in
FreeBSD. Raw SSH uses the runner's existing identity and checked host key.
Guest sudo permits an isolated payload directory, exact source-path alias,
resource-limit setup and cleanup. A real directory at the source alias is
refused. The alias and payload are removed on success and failure.

See the [execution lanes](../../compiler/tests/freebsd/README.md) for commands,
feature confirmation, verdicts and retained evidence.
