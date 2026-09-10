--  D192's optional, off-target file-name table. Numbers in a caller value
--  are compilation source identities; this artifact resolves those names.
--  The digest binds the table to the emitted assembly and is also supplied
--  as the ELF build ID when the driver links an executable.

with Ada.Strings.Unbounded;
with Landin.Stages;

package Landin.Source_Maps is
   type Artifact is record
      Build_Id : String (1 .. 64);
      Assembly : Ada.Strings.Unbounded.Unbounded_String;
      JSON : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   function Create
     (Context : in out Landin.Stages.Compilation;
      Assembly : String;
      All_Sources : Boolean := False) return Artifact;
end Landin.Source_Maps;
