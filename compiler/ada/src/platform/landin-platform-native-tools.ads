--  Running an external assembler, linker or other tool.
--
--  This is the compiler's only process-spawning package. Its host C adapter
--  owns POSIX spawn attributes and wait/signal constants; GNAT supplies path
--  lookup and temporary files. Nothing above this seam depends on either.

package Landin.Platform.Native.Tools is

   type Native_Tool_Runner is limited new Tool_Runner with private;

   --  How long a tool may run before it is stopped.  A fixture program
   --  that loops forever hung the whole gate without naming itself; a run
   --  past the limit has its process group killed and its direct child reaped,
   --  then is reported as Timed_Out, with a line in
   --  its output saying so (R4.21).  Ten minutes is far past any tool the
   --  compiler runs and any fixture the harness executes.
   --  Descendants inherit the group. This is supervision of ordinary tools,
   --  not confinement of a process that deliberately leaves its group.
   procedure Set_Limit (Host : in out Native_Tool_Runner; Seconds : Duration);

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

   type Native_Tool_Runner is limited new Tool_Runner with record
      Limit : Duration := 600.0;
   end record;

end Landin.Platform.Native.Tools;
