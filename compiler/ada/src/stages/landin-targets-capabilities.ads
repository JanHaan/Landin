--  Target backend availability.
--
--  This is a separate authority from Target_Facts: machine width and
--  alignment do not imply that the compiler has an object emitter or the
--  external tools needed to finish a program for that machine.

package Landin.Targets.Capabilities is

   type Backend_Kind is (No_Backend, Linux_X86_64_ELF);

   function Backend_For (Facts : Target_Facts) return Backend_Kind;

end Landin.Targets.Capabilities;
