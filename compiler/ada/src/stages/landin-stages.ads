--  Stage seams.
--
--  A compilation is a context that stages read and add to; a stage is an
--  interface with a name and a Run.  No stage knows which stage runs next,
--  and no stage owns the report.  That is what makes it possible to replace
--  one stage with a Landin implementation later without agreeing on a
--  serialised protocol now.

with Ada.Containers.Vectors;

with Landin.Diagnostics;
with Landin.Source;
with Landin.Source.Sets;
with Landin.Targets;

package Landin.Stages is

   type Compilation (<>) is limited private;

   function Create (For_Target : Landin.Targets.Target_Facts)
     return Compilation;

   function Target (Context : Compilation) return Landin.Targets.Target_Facts;

   function Add_Source
     (Context : in out Compilation; Name : String; Text : String)
     return Landin.Source.Source_Id;

   function Source_Count (Context : Compilation) return Natural;

   function Source (Context : Compilation; Id : Landin.Source.Source_Id)
     return Landin.Source.Snapshot;

   --  Identity of the N'th source in the order it was added, so a stage
   --  reads every source once, deterministically, without being handed the
   --  set to copy or outlive.
   function Nth_Source (Context : Compilation; Index : Positive)
     return Landin.Source.Source_Id
     with Pre => Index <= Source_Count (Context);

   procedure Report
     (Context : in out Compilation; Item : Landin.Diagnostics.Diagnostic);

   function Report (Context : Compilation)
     return Landin.Diagnostics.Diagnostic_List;

   function Failed (Context : Compilation) return Boolean;

   --  Rendering lives here because the report and the sources it points at
   --  are held together, and a caller must not be handed the source set to
   --  copy or outlive.
   function Rendered_Report (Context : Compilation) return String;

   ---------------------------------------------------------------------
   --  Stages and pipelines
   ---------------------------------------------------------------------

   type Stage_Outcome is (Continue, Stop);

   type Stage is limited interface;

   function Name (Item : Stage) return String is abstract;

   procedure Run
     (Item    : Stage;
      Context : in out Compilation;
      Outcome : out Stage_Outcome) is abstract;

   type Stage_Reference is access constant Stage'Class;

   type Pipeline is limited private;

   procedure Append
     (Into : in out Pipeline; Item : not null Stage_Reference);

   function Length (Of_Pipeline : Pipeline) return Natural;

   --  Runs stages in order and stops at the first Stop.  Returns how many
   --  stages ran, so a contract test can assert that a failing stage did
   --  not let the next one run.
   function Run
     (Of_Pipeline : Pipeline; Context : in out Compilation) return Natural;

private

   package Stage_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Stage_Reference);

   type Pipeline is limited record
      Items : Stage_Vectors.Vector;
   end record;

   type Compilation is limited record
      Facts   : Landin.Targets.Target_Facts;
      Sources : Landin.Source.Sets.Source_Set;
      Reports : Landin.Diagnostics.Diagnostic_List;
   end record;

end Landin.Stages;
