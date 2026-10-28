# FreeBSD hosted execution

`check.py` emits with Linux `refine`, Clang and a checksum-locked FreeBSD
sysroot, then executes in a FreeBSD VM. The gate reports runtime, native
LLDB and C ABI verdicts separately for amd64 and arm64, each job emitting
and executing its own lane; an emitted result is not an execution verdict.
The emulated arm64 runtime lane runs as `--shard=1/2` and `--shard=2/2`:
each shard takes alternate whole fixtures of the selection, with all their
levels and profiles, and the first also checks the source verdicts, so the
two jobs together are the lane. A shard cannot combine with `--case` or a
transferred payload. The sysroot and optional local VM base come from official 14.4 release files; hashes are in
[`environments/freebsd/lock.json`](../../../environments/freebsd/lock.json).

The gate runs each lane in one GitHub-hosted Linux x86-64 job, which emits
and then boots a fresh VM from the locked 14.4 image, as a local run does: amd64
under KVM with host CPU passthrough, arm64 under QEMU's `max` CPU in system
emulation, because the hosted arm64 images expose no KVM.
A guest C probe confirms every additional selected
feature before any higher-level Landin program executes: CPUID plus XCR0
for x86-64-v3, and `elf_aux_info(AT_HWCAP)` for LSE, CRC32 and RDM. Lack of
support fails, with no skipped higher-level verdict. The emulated `max`
CPU's confirmed LSE supplies the capable arm64 execution lane.

Runtime and ABI selection reads fixture metadata and fails when empty.
The two I/O fixtures that use Linux `/sys` and `/dev/full` reuse the existing
portable C fault-endpoint adapter with ELF interposition names; ordinary paths
reach FreeBSD libc through its documented
[`RTLD_NEXT` search](https://man.freebsd.org/cgi/man.cgi?query=dlsym&sektion=3),
and source, errno, status and output oracles stay intact. Runtime
runs four ordinary profiles and two additional specialization profiles where
requested; it also checks applicable positive and negative source verdicts.
Fixtures naming the architecture's higher level run at default, explicit
baseline and higher level. The linked shift/atomic images must show BMI2 or
LSE only at the higher level, and the arm64 baseline must contain exclusive
loops. A separate assembler control refuses the higher instruction below its
level and accepts it at that level. Both architectures execute
`assembly-operands`; the compiler backend suite mutates an operand and requires
an IR register refusal under each FreeBSD description.

ABI peers are compiled separately as C objects, using FreeBSD headers, before
linkage with Landin assembly. Required sets cover scalar and floating values,
`layout(c)` records, imported and exported calls, callbacks and variadic bank
exhaustion. LLDB runs natively inside each VM at four profiles and checks source
stops, nested frames, callee and caller locals, step-out unwinding and final
status. The FreeBSD startup objects contribute debug ranges before Landin's
object, exercising section-relocated lexical ranges. At the same profiles it
runs the stack switch's session (D469), `runtime/stack-switch-frames`
stopped in a fibre and stepped through two switches: the guest's LLDB has no
Python, so its commands step a switch by the count of the switch routine's
instructions, which emission reads from the image with the LLVM object
tools, and `compiler/tests/debugging/switch_frames.py` holds the
transcript.

For a complete local lane, install Clang 19, LLD, LLVM object tools, GNU as,
QEMU system emulators, arm64 UEFI firmware, the iPXE ROMs QEMU's virtio network
device loads (`ipxe-qemu` on Ubuntu, which installs it only as a recommendation
for arm64) and bsdtar, then run:

```sh
python3 compiler/tests/freebsd/check.py --arch=amd64 --kind=runtime \
    --refine=compiler/ada/build/linux-amd64/release/bin/refine \
    --output=/tmp/freebsd-runtime
```

On Linux, `nix develop` provides what emission needs, so `--prepare-only` runs
there with the lane's defaults: `clang-19`, `ld.lld-19` and `llvm-objdump-19`
from the flake's LLVM 19 under Ubuntu's names, GNU as and bsdtar. Its
`clang-19` takes the bare compiler, with the wrapper's resource directory, for
a command that names a target or a sysroot, as every FreeBSD compilation does,
because nixpkgs' wrapper adds the host's glibc to a FreeBSD build; a host
program gets the wrapper, as `bindings/test.py` needs. The shell does not
provide the system emulators and firmware that run the guests.

Select `arm64`, `abi` or `debugger` for the other lanes. `--case=NAME` is exact
and visibly filtered. `--ssh-port=PORT` uses an existing development VM;
`--prepare-only` emits and inspects a payload without executing it.
`--prepared=DIR --runner-ssh='ssh ... ci@freebsd-vm'` consumes it through the
supplied VM transport, verifies payload and executable hashes and the CI
revision, and uses guest sudo. Exact emission source paths resolve through a
temporary alias to the isolated payload. Guest identity, feature probes, source verdicts,
build/disassembly logs, debugger transcripts, output/status files and summary
hashes are retained by the gate for fourteen days. They are gate evidence,
not revision acceptance.

The [release image setup](https://github.com/freebsd/freebsd-src/blob/releng/14.4/release/tools/basic-ci.conf),
[auxiliary-vector API](https://man.freebsd.org/cgi/man.cgi?query=elf_aux_info&sektion=3)
and [arm64 capability definitions](https://github.com/freebsd/freebsd-src/blob/releng/14.4/sys/arm64/include/elf.h)
are FreeBSD's own contracts.
