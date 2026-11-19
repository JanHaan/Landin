--  The reader of a program's source table (D192, D1292): a panic site,
--  or a caller's three coordinates, resolved against the build that made
--  them.  `refine site` and `refine-dap` both read tables through it.
--
--  It takes no compilation: Landin.Source_Maps writes a table from one
--  and keeps the front end (D1423), and this reads what was written.
--
--  The artifact is what the compilation wrote: an ELF executable or
--  firmware image, a thin arm64 Mach-O executable, or the assembly of
--  `--emit=asm`.  Its source table is the `.sources.json` beside it
--  unless Map_Path names another.  The table resolves nothing for a
--  build it was not written with: an ELF's identity is its
--  `.landin_id` section or its GNU build ID, a Mach-O's its
--  `__TEXT,__landin_id` section, and assembly's its SHA-256.  Every
--  file is read through Host, and nothing is written.

with Ada.Strings.Unbounded;
with Interfaces;
with Landin.Diagnostics.Catalogue;
with Landin.Platform;

package Landin.Site_Tables is

   type Answer_Kind is (Resolved, Refusal, Misuse);

   type Answer is record
      Kind    : Answer_Kind := Resolved;
      --  A refusal's code and message.
      Code    : Landin.Diagnostics.Catalogue.Code_Name :=
        Landin.Diagnostics.Catalogue.Site_Unresolved;
      Message : Ada.Strings.Unbounded.Unbounded_String;
      --  A resolved position: the path as the table's bytes hold it, the
      --  line and column, and for a panic site the check that failed.
      Path    : Ada.Strings.Unbounded.Unbounded_String;
      Line    : Natural := 0;
      Column  : Natural := 0;
      Reason  : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  Operands is what follows the artifact: one site number, or a file
   --  number, a line and a column; any other count is Misuse.  Dsym_Path,
   --  when not "", is the dSYM DWARF file a Mach-O executable must share
   --  its UUID with.
   function Resolve
     (Artifact, Map_Path, Dsym_Path : String;
      Operands : Landin.Platform.Path_List;
      Host     : Landin.Platform.Filesystem'Class) return Answer;

   --  The panic site a `panic_handler` received.
   function Resolve_Site
     (Artifact, Map_Path : String;
      Site : Interfaces.Unsigned_32;
      Host : Landin.Platform.Filesystem'Class) return Answer;

   --  A resolved answer as `refine site` prints it, without the line end:
   --  `PATH:LINE:COLUMN`, and ` (REASON)` after a panic site's.
   function Text (Of_Answer : Answer) return String;

end Landin.Site_Tables;
