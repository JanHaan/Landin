# FreeBSD hosted execution

`check.py` emits with Linux `refine`, Clang and a checksum-locked FreeBSD
sysroot, then executes in a fresh FreeBSD VM. The gate reports six independent
jobs: runtime, native LLDB and C ABI, each on amd64 and arm64. The VM base and
sysroot come from official 14.4 release files; hashes are in
[`environments/freebsd/lock.json`](../../../environments/freebsd/lock.json).

The amd64 VM uses KVM and the host CPU. The arm64 VM uses QEMU's `max` CPU
under system emulation. A guest C probe confirms every additional selected
feature before any higher-level Landin program executes: CPUID plus XCR0
for x86-64-v3, and `elf_aux_info(AT_HWCAP)` for LSE, CRC32 and RDM. Lack of
support fails, with no skipped higher-level verdict. The recurring VM's
confirmed LSE supplies the capable execution lane.

Runtime and ABI selection reads fixture metadata and fails when empty. Runtime
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
object, exercising section-relocated lexical ranges.

For a complete local lane, install Clang 19, LLD, LLVM object tools, GNU as,
QEMU system emulators, arm64 UEFI firmware and bsdtar, then run:

```sh
python3 compiler/tests/freebsd/check.py --arch=amd64 --kind=runtime \
    --refine=compiler/ada/build/linux-amd64/release/bin/refine \
    --output=/tmp/freebsd-runtime
```

Select `arm64`, `abi` or `debugger` for the other lanes. `--case=NAME` is exact
and visibly filtered. `--ssh-port=PORT` uses an existing development VM;
recurring jobs always provision their own fresh overlay. The VM SSH endpoint
is bound only to loopback. Guest identity, feature probes, source verdicts,
build/disassembly logs, debugger transcripts, output/status files and summary
hashes are retained by the gate for fourteen days. They are gate evidence,
not revision acceptance.

The [release image setup](https://github.com/freebsd/freebsd-src/blob/releng/14.4/release/tools/basic-ci.conf),
[auxiliary-vector API](https://man.freebsd.org/cgi/man.cgi?query=elf_aux_info&sektion=3)
and [arm64 capability definitions](https://github.com/freebsd/freebsd-src/blob/releng/14.4/sys/arm64/include/elf.h)
are FreeBSD's own contracts.
