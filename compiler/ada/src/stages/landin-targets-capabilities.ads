with Landin.Memory;
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
   function Memory_Access
     (Facts : Target_Facts; Op : Landin.Memory.Operation;
      Width : Scalar_Size) return Boolean;

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
     (No_Backend, X86_64_ELF, Darwin_Arm64_Mach_O, Arm64_ELF,
      Cortex_M0_ELF);

   function Backend_For (Facts : Target_Facts) return Backend_Kind;

   --  The operating system whose C library a hosted program runs on, which
   --  is what the runtime bridge's errno function and `open` flags are
   --  facts about.  Neither the object format nor the C ABI decides it:
   --  FreeBSD's objects are ELF and its errno function is Darwin's.  A
   --  target with no hosted runtime has none.
   type Hosted_System is (No_Hosted_System, Linux, Darwin, FreeBSD);

   function Hosted_System_Of (Facts : Target_Facts) return Hosted_System;

   --  The target's toolchain triplet.  Linux and Cortex-M use it as the
   --  prefix of their GNU compiler driver: `x86_64-pc-linux-gnu-gcc`,
   --  `aarch64-linux-gnu-gcc` or `arm-none-eabi-gcc`.  Darwin carries
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
