--  D192's optional, off-target file-name table. Numbers in a caller value
--  are compilation source identities; this artifact resolves those names.
--  The digest binds the table to the emitted assembly and is also supplied
--  to the target toolchain for an ELF build ID or Mach-O identity section.

with Ada.Strings.Unbounded;
with Landin.Stages;
with Landin.Panics;
with Landin.Source;
with Landin.Source_Digests;

package Landin.Source_Maps is
   --  D422: where a library module's files are recorded.  Debug
   --  information and this table name a file of `core`, `hosted` or
   --  `platform` by this prefix, its module path and its own name,
   --  `/landin-library/core/vec/vec.ldn`, never by where the library was
   --  installed; a debugger maps the prefix to the directory
   --  `refine version` names.  Every other file keeps the path it was read
   --  from, which is how a debugger finds it beside the compilation
   --  directory.
   Library_Prefix : constant String := "/landin-library";

   function Recorded_Name
     (Context : aliased in out Landin.Stages.Compilation;
      Id      : Landin.Source.Source_Id) return String;

   type Artifact is record
      Build_Id : String (1 .. 64);
      JSON : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  Append the identity to Assembly in place.  Its original bytes enter
   --  Build_Id; the complete result enters assembly_sha256.
   function Create
     (Context : in out Landin.Stages.Compilation;
      Assembly : in out Ada.Strings.Unbounded.Unbounded_String;
      All_Sources : Boolean := False;
      Panic : access constant Landin.Panics.Plan := null;
      Digests : access Landin.Source_Digests.Cache := null) return Artifact;
end Landin.Source_Maps;
