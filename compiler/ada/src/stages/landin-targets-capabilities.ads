with Landin.Memory;
with Landin.Targets.Levels;
--  Target backend availability.
--
--  This is a separate authority from Target_Facts: machine width and
--  alignment do not imply that the compiler has an object emitter or the
--  external tools needed to finish a program for that machine.
--
--  The triplet is here for that reason and not on Target_Facts, whose own
--  header says a description "says what the machine can hold and how it
--  must be aligned, and nothing about what a program may name".  A
--  toolchain's installed name is neither of those; it is exactly the
--  "external tools needed to finish a program" this package was created to
--  hold apart.

package Landin.Targets.Capabilities is

   --  Admitted source contracts, independent of instruction selection.
   --  The read-modify-writes, exchange, add and compare-exchange, are the
   --  one checking rule a level decides (D255, D690): RV32 admits them at
   --  a level with `a` and refuses them below it.  Every other operation
   --  and width is the target's alone, the same at each of its levels.
   function Memory_Access
     (Facts : Target_Facts; Level : Landin.Targets.Levels.Feature_Level;
      Op : Landin.Memory.Operation; Width : Scalar_Size) return Boolean
     with Pre => Landin.Targets.Levels.Belongs_To (Level, Facts);

   --  Whether some level of the target admits the access: what the
   --  target-neutral IR is held to, which no level reaches (D690), and
   --  what a register's volatile access needs, which no level changes.
   function Memory_Access_At_Some_Level
     (Facts : Target_Facts; Op : Landin.Memory.Operation;
      Width : Scalar_Size) return Boolean;

   --  The levels of the target that admit the access, comma separated, or
   --  "" when none does: what a refusal at another level offers instead.
   function Levels_Admitting
     (Facts : Target_Facts; Op : Landin.Memory.Operation;
      Width : Scalar_Size) return String;

   --  The critical section a program without an atomic access uses
   --  instead, as a refusal names it (D500, D690): the firmware platform
   --  module's, which masks the core's interrupts.  "" on a target with
   --  every access, which needs none.
   function Critical_Section (Facts : Target_Facts) return String;

   --  D450: whether the target's backend emits compiler.stack_prepare and
   --  compiler.stack_switch.  D450 admits both on every target with a
   --  native backend and neither on synthetic-32; each backend is enabled
   --  here once it emits them, and until then the checker refuses the two
   --  builtins on its targets as not yet emitted there.
   function Stack_Switching (Facts : Target_Facts) return Boolean;

   --  An ABI identity describes the intended boundary. Each implemented
   --  capability must be enabled explicitly; equal LP64 widths prove none.
   function C_Signatures (Facts : Target_Facts) return Boolean;
   function C_Records (Facts : Target_Facts) return Boolean;
   function C_Variadic_Calls (Facts : Target_Facts) return Boolean;

   type Object_Format is (No_Object_Format, ELF, Mach_O);
   function Object_Format_Of (Facts : Target_Facts) return Object_Format;

   type Debug_Format is
     (No_Debug_Format, ELF_DWARF, Mach_O_DWARF, ELF_DWARF_Lines);
   function Debug_Format_Of (Facts : Target_Facts) return Debug_Format;

   --  Logical external names acquire the platform prefix exactly once.
   --  Compiler-local labels and assembler quoting are separate concerns.
   function Link_Symbol (Facts : Target_Facts; Name : String) return String;

   type Backend_Kind is
     (No_Backend, X86_64_ELF, Darwin_Arm64_Mach_O, Arm64_ELF, RV64_ELF,
      Cortex_M0_ELF, RV32_ELF);

   function Backend_For (Facts : Target_Facts) return Backend_Kind;

   --  Whether the target's backend emits assembly yet.  RV32's backend is
   --  named before its emitter exists, so its programs check, configure
   --  and lower to IR, and the driver refuses to emit them.
   function Emits (Facts : Target_Facts) return Boolean
     is (Backend_For (Facts) not in No_Backend | RV32_ELF);

   --  D537: how far the backend's addressing of static data reaches, which
   --  bounds the written images of a program with no firmware profile:
   --  2 GiB under x86-64's small code model, Darwin's static image and
   --  RV64's AUIPC, 4 GiB under arm64's ADRP on ELF, and the 32-bit address
   --  space on Cortex-M, whose literal pools hold whole addresses, and on
   --  RV32, where AUIPC's 32-bit reach is the whole space.
   function Image_Reach (Facts : Target_Facts) return Byte_Count
     with Pre => Backend_For (Facts) /= No_Backend;

   --  What sets Image_Reach, as a refusal names it: "x86-64's small code
   --  model reaches on linux-x86-64".
   function Image_Reach_Source (Facts : Target_Facts) return String
     with Pre => Backend_For (Facts) /= No_Backend;

   --  The budget of a program with no firmware profile: its written images
   --  within Image_Reach, and its zero images within the address space.
   function Image_Budget_Of (Facts : Target_Facts) return Image_Budget
     with Pre => Backend_For (Facts) /= No_Backend;

   --  Whether the backend writes an immutable image that is wholly zero
   --  into the object, as firmware does into flash, rather than reserving
   --  it as it reserves a mutable one.
   function Writes_Zero_Constants (Facts : Target_Facts) return Boolean;

   --  The operating system whose C library a hosted program runs on, which
   --  `compiler.os` names to source: `platform/libc` selects its errno
   --  function and `open` flags by it.  Neither the object format nor the
   --  C ABI decides it: FreeBSD's objects are ELF and its errno function is
   --  Darwin's.  A target with no hosted system has none.
   type Hosted_System is (No_Hosted_System, Linux, Darwin, FreeBSD);

   function Hosted_System_Of (Facts : Target_Facts) return Hosted_System;

   --  The target's toolchain triplet.  Linux and firmware use it as the
   --  prefix of their GNU compiler driver: `x86_64-pc-linux-gnu-gcc`,
   --  `aarch64-linux-gnu-gcc`, `arm-eabi-gcc` or `riscv64-elf-gcc`, whose
   --  multilibs build rv32 as well (D660).  Darwin carries
   --  `arm64-apple-darwin` as target metadata but defaults independently
   --  to Apple's `/usr/bin/clang`.
   --
   --  One spelling, carried verbatim, and deliberately not canonicalised.
   --  The same machine is `x86_64-pc-linux-gnu` to the pinned GNAT,
   --  `x86_64-linux-gnu` to Debian's cross packages and
   --  `x86_64-unknown-linux-gnu` to LLVM, and Autoconf's own manual says
   --  "You should not attempt to duplicate the canonicalization done by
   --  `config.sub' in your own code".  A host whose toolchain uses another
   --  spelling names a driver on the command line; recognising aliases here
   --  would be the second authority this compiler refuses everywhere else.
   --
   --  It is not a target name.  `--target=` still takes this repository's
   --  own names, so a triplet never becomes a second way to spell one.
   --
   --  A target with no backend has no triplet, and the empty string is what
   --  says so: nothing can be finished for a machine nothing emits for.
   function Triplet (Facts : Target_Facts) return String
     with Post => (Triplet'Result = "") =
                  (Backend_For (Facts) = No_Backend);

end Landin.Targets.Capabilities;
