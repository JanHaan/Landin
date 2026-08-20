--  Root of the Landin bootstrap compiler.
--
--  This package deliberately declares nothing but the namespace and the
--  exceptions that separate a defect from a diagnosis.  Anything with an
--  opinion about the Landin language belongs in a child package, and
--  anything with an opinion about a host belongs under Landin.Platform.

package Landin is
   pragma Pure;

   --  Raised when the compiler has caught itself doing something it
   --  believes impossible.  A source program must never be able to raise
   --  it: an ill-formed program is data, not an exception.
   Compiler_Defect : exception;

   --  Raised when the host, not the program, ran out of something.
   Host_Exhausted : exception;

   --  Raised when an external assembler, linker or other tool could not be
   --  run at all, or failed in a way the compiler cannot describe as a
   --  source diagnostic.
   External_Tool_Failed : exception;

end Landin;
