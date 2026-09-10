--  Optional off-target source metadata.  Identities are the compilation's
--  snapshots, not filenames or a debugger-specific numbering.  The tree is
--  read only for source names and lexical extents; IR owns represented types.
with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;
with Landin.Provenance;
with Landin.Source;
with Landin.Source.Names;
with Landin.Syntax.Forest;

package Landin.Debugging is

   type Information
     (Trees : not null access constant Landin.Syntax.Forest.Table)
   is tagged limited private;

   procedure Append
     (Into : in out Information; Snapshot : Landin.Source.Snapshot);
   function Count (Info : Information) return Natural;
   function Source
     (Info : Information; Id : Landin.Source.Source_Id)
      return Landin.Source.Snapshot;

   procedure Set_Directory (Into : in out Information; Path : String);
   function Directory (Info : Information) return String;

   --  Named-result labels belong to the selected source signature, which
   --  can rename an indirect callee's results.  No represented type or
   --  layout is copied from the checker into this optional name snapshot.
   procedure Append_Result_Name
     (Into : in out Information;
      Binding : Landin.Provenance.Declaration_Id;
      Name : Landin.Source.Names.Name_Id);
   function Result_Name
     (Info : Information;
      Binding : Landin.Provenance.Declaration_Id;
      Index : Positive) return Landin.Source.Names.Name_Id;

private

   package Snapshot_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Landin.Source.Snapshot,
      "=" => Landin.Source."=");

   package Name_Vectors is new Ada.Containers.Vectors
     (Positive, Landin.Source.Names.Name_Id,
      "=" => Landin.Source.Names."=");
   package Result_Vectors is new Ada.Containers.Vectors
     (Positive, Name_Vectors.Vector, "=" => Name_Vectors."=");

   type Information
     (Trees : not null access constant Landin.Syntax.Forest.Table)
   is tagged limited record
      Snapshots : Snapshot_Vectors.Vector;
      Compile_Directory : Ada.Strings.Unbounded.Unbounded_String;
      Result_Names : Result_Vectors.Vector;
   end record;

end Landin.Debugging;
