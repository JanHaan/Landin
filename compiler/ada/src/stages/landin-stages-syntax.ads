--  The syntax stage.
--
--  The first stage that reads Landin rather than describing the chassis: it
--  scans every source in the compilation, reports what the scan could not
--  read, parses what it produced, and reports what the parse could not
--  read.  Both halves report, and in that order, so a file with an
--  unreadable byte and a missing `then` says both things rather than
--  stopping at the first.
--
--  It keeps nothing of its own.  The tree of each source goes into the
--  compilation's forest and the identities it interned are the
--  compilation's too, because both outlive this Run: the stage that
--  resolves names runs after it returns, and a Name_Id in a tree names a
--  spelling in one table.  The stage object holds nothing at all, which is
--  what lets one library-level instance serve every compilation.

package Landin.Stages.Syntax is

   type Instance is limited new Landin.Stages.Stage with null record;

   overriding function Name (Item : Instance) return String;

   overriding procedure Run
     (Item    : Instance;
      Context : in out Compilation;
      Outcome : out Stage_Outcome);

end Landin.Stages.Syntax;
