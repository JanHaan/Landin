--  Stage seams.
--
--  A compilation is a context that stages read and add to; a stage is an
--  interface with a name and a Run.  No stage knows which stage runs next,
--  and no stage owns the report.  That is what makes it possible to replace
--  one stage with a Landin implementation later without agreeing on a
--  serialised protocol now.
--
--  A compilation also owns everything the stages build that outlives the
--  stage that built it, and R1.50 is where that became four things rather
--  than one.  Run takes Item as an `in` parameter of a limited interface,
--  so a stage cannot keep anything in itself; a Stage_Reference is a
--  library-level access type, so a stage object cannot be a local of one
--  compilation either.  Between them those two facts say where a tree can
--  live: not in the stage, and not in a Run that ends before the next
--  stage starts.  It lives here.
--
--  What that costs, said plainly.  This package gains one with clause per
--  representation -- the trees at R1.50, the types at R1.60, the IR at
--  R1.70 -- and a reader will ask whether a context that knows all of them
--  is still a seam.  It is, and the line is exact: this package may depend
--  on a representation and may never depend on a stage.  Ada enforces that
--  for this specification only, because a parent's spec may not with its
--  own child -- a parent's *body* may, so `landin-stages.adb` growing a
--  `with Landin.Stages.Syntax` to build a default pipeline is how the rule
--  would actually be broken, and nothing but this paragraph stops it.  The
--  other half is that nothing here asks which stages exist or what order
--  they run in, and Landin.Driver is what owns that.
--
--  The four are reached and not copied, because each is limited and each
--  means nothing away from the compilation that issued its numbers: a
--  Name_Id names a spelling in one table, a Declaration_Id a row in one
--  site table, a Node_Id a node in one tree.  They are allocated once by
--  Create and never freed, which is the decision Landin.Source already
--  recorded for a snapshot's bytes and for the same reason.

with Ada.Containers.Vectors;

with Landin.Diagnostics;
with Landin.Provenance;
with Landin.Resolution;
with Landin.Source;
with Landin.Source.Names;
with Landin.Source.Sets;
with Landin.Syntax.Forest;
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

   ---------------------------------------------------------------------
   --  What the stages build
   --
   --  Each is an `in out` context and a reference out, so the mode says
   --  what the caller is about to do with it.  A reader that only renders
   --  needs none of them.
   ---------------------------------------------------------------------

   --  The identities every name in this compilation was interned in.  One
   --  per compilation and not one per stage: the scan interns before any
   --  tree exists, every tree then holds numbers rather than bytes, and a
   --  number outlives the stage that issued it.
   function Identities (Context : in out Compilation)
     return not null access Landin.Source.Names.Table;

   --  Where each declared thing is written.  R1.50 is its first writer.
   function Sites (Context : in out Compilation)
     return not null access Landin.Provenance.Table;

   --  One tree per source, kept for the whole compilation.
   function Trees (Context : in out Compilation)
     return not null access Landin.Syntax.Forest.Table;

   --  What every name in those trees means.
   function Meanings (Context : in out Compilation)
     return not null access Landin.Resolution.Table;

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

   --  Allocated by Create, never freed; see the header.
   type Names_Access      is access Landin.Source.Names.Table;
   type Sites_Access      is access Landin.Provenance.Table;
   type Forest_Access     is access Landin.Syntax.Forest.Table;
   type Resolution_Access is access Landin.Resolution.Table;

   type Compilation is limited record
      Facts   : Landin.Targets.Target_Facts;
      Sources : Landin.Source.Sets.Source_Set;
      Reports : Landin.Diagnostics.Diagnostic_List;
      Named   : Names_Access      := null;
      Written : Sites_Access      := null;
      Parsed  : Forest_Access     := null;
      Meant   : Resolution_Access := null;
   end record;

end Landin.Stages;
