--  The syntax stage.
--
--  The first stage that reads Landin rather than describing the chassis: it
--  scans every source in the compilation, reports what the scan could not
--  read, parses what it produced, and reports what the parse could not
--  read.  Both halves report, and in that order, so a file with an
--  unreadable byte and a missing `then` says both things rather than
--  stopping at the first.
--
--  It keeps nothing.  A parse produces a tree and this stage drops it,
--  because nothing reads one yet and where trees live for a whole
--  compilation is a question R1.50 has to answer when it collects
--  declarations across files.  Wiring an answer in now would be guessing
--  with a data structure.

package Landin.Stages.Syntax is

   type Instance is limited new Landin.Stages.Stage with null record;

   overriding function Name (Item : Instance) return String;

   overriding procedure Run
     (Item    : Instance;
      Context : in out Compilation;
      Outcome : out Stage_Outcome);

end Landin.Stages.Syntax;
