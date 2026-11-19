--  What a command produced: its exit status, the text asked for, the
--  report a person reads and the same report as data.  `refine` and every
--  split command answer with one, so a split shares it without linking
--  the driver, whose body withs the whole compiler (D1543).

with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;
with Landin.Diagnostics;
with Landin.Platform;
with Landin.Source;

package Landin.Outcomes is

   --  Exit statuses are part of the interface a test asserts, so they are
   --  named rather than spelled at each return.
   Status_Success   : constant := 0;
   Status_Reported  : constant := 1;
   Status_Misuse    : constant := 2;

   --  Unexpected compiler exceptions become an outcome with the source
   --  diagnostics already collected, followed by the defect report.
   --  Known resource/tool failures retain their dedicated executable paths.
   --  This is Sysexits' EX_SOFTWARE, distinct from a source refusal.
   Status_Defect    : constant := 70;

   --  Report is the rendering a person reads.  Found is the same report as
   --  data, in the order it was rendered, and Named is the path each source
   --  it points at was read from, indexed by Source_Id: a client that
   --  applies a fix, or hands one to an editor, needs both, and must not
   --  be made to read them back out of the text.
   package Position_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Landin.Source.Position,
      "=" => Landin.Source."=");

   type Outcome is record
      Status : Natural := Status_Success;
      Output : Ada.Strings.Unbounded.Unbounded_String;
      Report : Ada.Strings.Unbounded.Unbounded_String;
      Found  : Landin.Diagnostics.Diagnostic_List;
      Named  : Landin.Platform.Path_List;
      Positions : Position_Vectors.Vector;
      Trace  : Ada.Strings.Unbounded.Unbounded_String;
      --  Internal transport for command tracing. Tool arguments use private
      --  paths; the public trace names their deterministic destinations.
      Trace_Physical_Paths : Landin.Platform.Path_List;
      Trace_Logical_Paths : Landin.Platform.Path_List;
      --  D526: what `refine run` runs once the report above is written,
      --  and the private directory it is in, removed after it.  Empty
      --  when there is nothing to run.
      Launch_Program   : Ada.Strings.Unbounded.Unbounded_String;
      Launch_Arguments : Landin.Platform.Path_List;
      Launch_Directory : Ada.Strings.Unbounded.Unbounded_String;
      --  D1384: when not empty, Launch_Program is a command `refine`
      --  dispatched, in no private directory, run with this setting,
      --  `NAME=VALUE`, in its environment (D1486).
      Launch_Setting   : Ada.Strings.Unbounded.Unbounded_String;
   end record;

end Landin.Outcomes;
