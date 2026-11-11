--  `refine site` (D1292): resolve a panic site, or a caller's three
--  coordinates, against the build that made them.
--
--  The artifact is what the compilation wrote: an ELF executable or
--  firmware image, a thin arm64 Mach-O executable, or the assembly of
--  `--emit=asm`.  Its source table is the `.sources.json` beside it
--  unless Map_Path names another.  The table resolves nothing for a
--  build it was not written with: an ELF's identity is its
--  `.landin_id` section or its GNU build ID, a Mach-O's its
--  `__TEXT,__landin_id` section, and assembly's its SHA-256.  Every
--  file is read through Host, and nothing is written.

with Landin.Driver;
with Landin.Platform;

package Landin.Commands.Sites is

   --  Operands is what follows the artifact: one site number, or a file
   --  number, a line and a column.  Dsym_Path, when not "", is the dSYM
   --  DWARF file a Mach-O executable must share its UUID with.
   procedure Resolve
     (Artifact, Map_Path, Dsym_Path : String;
      Operands : Landin.Platform.Path_List;
      Host     : Landin.Platform.Filesystem'Class;
      Result   : in out Landin.Driver.Outcome);

end Landin.Commands.Sites;
