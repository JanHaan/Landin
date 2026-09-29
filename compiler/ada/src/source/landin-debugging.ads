--  Optional off-target source metadata.  Identities are the compilation's
--  snapshots, not filenames or a debugger-specific numbering.  The tree is
--  read only for source names and lexical extents; IR owns represented types.
--  The snapshots are the compilation's own, reached through its source set
--  and never copied, so this can hold nothing past the compilation.
with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;
with Landin.Provenance;
with Landin.Source;
with Landin.Source.Names;
with Landin.Source.Sets;
with Landin.Syntax.Forest;

package Landin.Debugging is

   type Information
     (Trees   : not null access constant Landin.Syntax.Forest.Table;
      Sources : not null access constant Landin.Source.Sets.Source_Set)
   is tagged limited private;

   --  Describes the next of Sources' snapshots, which must be that one.
   procedure Append
     (Into : in out Information; Snapshot : Landin.Source.Snapshot);
   function Count (Info : Information) return Natural;
   function Source
     (Info : aliased Information; Id : Landin.Source.Source_Id)
      return Landin.Source.Snapshot_Reference;

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

   package Name_Vectors is new Ada.Containers.Vectors
     (Positive, Landin.Source.Names.Name_Id,
      "=" => Landin.Source.Names."=");
   package Result_Vectors is new Ada.Containers.Vectors
     (Positive, Name_Vectors.Vector, "=" => Name_Vectors."=");

   type Information
     (Trees   : not null access constant Landin.Syntax.Forest.Table;
      Sources : not null access constant Landin.Source.Sets.Source_Set)
   is tagged limited record
      Described : Natural := 0;
      Compile_Directory : Ada.Strings.Unbounded.Unbounded_String;
      Result_Names : Result_Vectors.Vector;
   end record;

end Landin.Debugging;
