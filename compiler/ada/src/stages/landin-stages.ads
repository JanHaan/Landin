--  Stage seams.
--
--  A compilation is a context that stages read and add to; a stage is an
--  interface with a name and a Run.  No stage knows which stage runs next,
--  and no stage owns the report.  That is what makes it possible to replace
--  one stage with a Landin implementation later without agreeing on a
--  serialised protocol now.
--
--  A compilation also owns everything the stages build that outlives the
--  stage that built it, and name resolution is where that became more than
--  one: the interned names, the declaration sites, the trees and what every
--  name in them means, with the checker adding what type everything has.  Run
--  takes Item as an `in` parameter of a limited interface, so a stage cannot
--  keep anything in itself; a Stage_Reference is a library-level access type,
--  so a stage object cannot be a local of one compilation either.  Between
--  them those two facts say where a tree can live: not in the stage, and not
--  in a Run that ends before the next stage starts.  It lives here.
--
--  What that costs, said plainly.  This package gains one with clause per
--  representation -- the trees, the types, the IR -- and a reader will ask
--  whether a context that knows all of them is still a seam.  It is, and the
--  line is exact: this package may depend on a representation and may never
--  depend on a stage.  Ada enforces that for this specification only, because
--  a parent's spec may not with its own child -- a parent's *body* may, so
--  `landin-stages.adb` growing a `with Landin.Stages.Syntax` to build a
--  default pipeline is how the rule would actually be broken, and nothing but
--  this paragraph stops it.  The other half is that nothing here asks which
--  stages exist or what order they run in, and Landin.Driver is what owns
--  that.
--
--  The four are reached and not copied, because each is limited and each
--  means nothing away from the compilation that issued its numbers: a
--  Name_Id names a spelling in one table, a Declaration_Id a row in one
--  site table, a Node_Id a node in one tree.
--
--  They are components of the compilation, not allocations of their own,
--  so they end when it does and a process can check one program after
--  another without keeping any of them.  A batch compiler never needed
--  that; a server that checks on every edit does.  What stops a reference
--  outliving the tables is the accessors' aliased parameter: its
--  accessibility is the caller's object, so converting the reference to
--  a library-level access type is refused where it is written.  That is
--  also why Compilation is tagged -- every parameter of a tagged type is
--  aliased, so a caller passing one along needs no keyword -- and why a
--  stage's Run takes Compilation'Class, since a primitive may dispatch on
--  one tagged type only.  The numbers themselves need no guard: an
--  identity is an integer, not an address, and it means something only
--  through an accessor on a live compilation.

with Ada.Containers.Vectors;

with Landin.Checking;
with Landin.Configuration;
with Landin.IR;
with Landin.Diagnostics;
with Landin.Modules;
with Landin.Provenance;
with Landin.Resolution;
with Landin.Source;
with Landin.Source.Names;
with Landin.Source.Sets;
with Landin.Syntax.Forest;
with Landin.Targets;
with Landin.Targets.Levels;
with Landin.Tokens.Spacing;

package Landin.Stages is

   type Compilation (<>) is tagged limited private;

   function Create (For_Target : Landin.Targets.Target_Facts)
     return Compilation;

   --  A compilation that assumes a selected CPU feature level of its
   --  target's family; the one above assumes the target's default level.
   function Create
     (For_Target : Landin.Targets.Target_Facts;
      At_Level   : Landin.Targets.Levels.Feature_Level)
     return Compilation
     with Pre => Landin.Targets.Levels.Belongs_To (At_Level, For_Target);

   function Target (Context : Compilation) return Landin.Targets.Target_Facts;

   function Level
     (Context : Compilation) return Landin.Targets.Levels.Feature_Level;

   function Add_Source
     (Context : in out Compilation; Name : String; Text : String)
     return Landin.Source.Source_Id;

   function Add_Source
     (Context : in out Compilation;
      Module  : Landin.Modules.Module_Id;
      Name    : String;
      Text    : String) return Landin.Source.Source_Id;

   function Source_Count (Context : Compilation) return Natural;

   --  By reference, and only for as long as the compilation lives.
   function Source
     (Context : aliased Compilation; Id : Landin.Source.Source_Id)
      return Landin.Source.Snapshot_Reference;

   --  The whole set, read only, for a reader that describes every source
   --  and must not outlive them: the debugging information.
   function Sources (Context : aliased Compilation)
     return not null access constant Landin.Source.Sets.Source_Set;

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
   function Identities (Context : aliased in out Compilation)
     return not null access Landin.Source.Names.Table;

   --  The reached source/module topology.  The driver records host choices;
   --  semantic stages consume this table without consulting the host.
   function Modules (Context : aliased in out Compilation)
     return not null access Landin.Modules.Table;

   --  Where each declared thing is written.  Name resolution is its first
   --  writer.
   function Sites (Context : aliased in out Compilation)
     return not null access Landin.Provenance.Table;

   --  One tree per source, kept for the whole compilation.
   function Trees (Context : aliased in out Compilation)
     return not null access Landin.Syntax.Forest.Table;

   --  The space and comments of every source, which the trees do not
   --  hold: what a formatter puts back and an editor asks about.  Nothing
   --  that decides what a program means reads it.
   function Spacing (Context : aliased in out Compilation)
     return not null access Landin.Tokens.Spacing.Table;

   --  What every name in those trees means.
   function Meanings (Context : aliased in out Compilation)
     return not null access Landin.Resolution.Table;

   --  D139's immutable active declaration view, built after syntax and
   --  target selection and read by every semantic traversal.
   function Configurations (Context : aliased in out Compilation)
     return not null access Landin.Configuration.Table;

   --  What type every node and every declaration has.
   function Types (Context : aliased in out Compilation)
     return not null access Landin.Checking.Table;

   --  The target-neutral instructions the frontend was checking towards.
   --  The last representation this package gains: the backend emits from it
   --  and keeps nothing here.
   function Code (Context : aliased in out Compilation)
     return not null access Landin.IR.Unit;

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
      Whole   : in out Compilation'Class;
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

   --  The same run, telling Watch each stage's name before it starts and
   --  again after it returns.  The watcher observes and may not change the
   --  run: it is how a measurement is attributed to a stage without any
   --  stage knowing it is being measured.
   function Run
     (Of_Pipeline : Pipeline;
      Context     : in out Compilation;
      Watch       : not null access procedure
        (Name : String; Finished : Boolean)) return Natural;

private

   package Stage_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Stage_Reference);

   type Pipeline is limited record
      Items : Stage_Vectors.Vector;
   end record;

   --  Components, not allocations: they are freed with the compilation,
   --  and each is aliased so an accessor can hand out a reference that
   --  the aliased formal keeps from outliving it; see the header.
   type Compilation is tagged limited record
      Facts   : Landin.Targets.Target_Facts;
      Assumed : Landin.Targets.Levels.Feature_Level;
      Held    : aliased Landin.Source.Sets.Source_Set;
      Reports : Landin.Diagnostics.Diagnostic_List;
      Named   : aliased Landin.Source.Names.Table;
      Grouped : aliased Landin.Modules.Table;
      Written : aliased Landin.Provenance.Table;
      Parsed  : aliased Landin.Syntax.Forest.Table;
      Spaced  : aliased Landin.Tokens.Spacing.Table;
      Meant   : aliased Landin.Resolution.Table;
      Active  : aliased Landin.Configuration.Table;
      Typed   : aliased Landin.Checking.Table;
      Lowered : aliased Landin.IR.Unit;
   end record;

end Landin.Stages;
