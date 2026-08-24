--  Running an external assembler, linker or other tool.
--
--  This is the compiler's only process-spawning package, and the only place
--  that depends on a GNAT-specific unit.  Both facts are deliberate: the
--  eventual self-hosting roadmap replaces exactly this file, and nothing
--  above it, when it needs to run a tool from Landin.

package Landin.Platform.Native.Tools is

   type Native_Tool_Runner is limited new Tool_Runner with private;

   --  A tool that cannot be started at all raises External_Tool_Failed; a
   --  tool that ran and failed reports its exit code, which the driver can
   --  describe.  Capture files are temporary resources owned by this adapter.
   overriding procedure Run
     (Host      : Native_Tool_Runner;
      Program   : String;
      Arguments : Path_List;
      Result    : out Tool_Result;
      Capture   : Capture_Mode := Merged);

private

   type Native_Tool_Runner is limited new Tool_Runner with null record;

end Landin.Platform.Native.Tools;
