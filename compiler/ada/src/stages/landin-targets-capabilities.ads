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

   type Backend_Kind is (No_Backend, Linux_X86_64_ELF);

   function Backend_For (Facts : Target_Facts) return Backend_Kind;

   --  The GNU configuration triplet the platform's toolchain is installed
   --  under, so that R1.80 can find an assembler and linker by the
   --  convention every GNU toolchain already follows: cross tools carry the
   --  `--target` argument as a prefix, which is why the pinned GNAT appears
   --  as `x86_64-pc-linux-gnu-gcc` on Linux and
   --  `aarch64-apple-darwin24.6.0-gcc` on this macOS host.  Both were
   --  measured in their own environment rather than recalled.
   --
   --  One spelling, carried verbatim, and deliberately not canonicalised.
   --  The same machine is `x86_64-pc-linux-gnu` to the pinned GNAT,
   --  `x86_64-linux-gnu` to Debian's cross packages and
   --  `x86_64-unknown-linux-gnu` to LLVM, and Autoconf's own manual says
   --  "You should not attempt to duplicate the canonicalization done by
   --  `config.sub' in your own code".  A host whose toolchain uses another
   --  spelling names it on the command line; recognising aliases here would
   --  be the second authority this compiler refuses everywhere else.
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
