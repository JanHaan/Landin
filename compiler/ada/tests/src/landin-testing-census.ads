--  How often the language's constructs are written, counted on checked
--  trees rather than by grep.
--
--  An audit of the language asks how much a construct is used before it
--  decides to remove it, and grep cannot see some of what it asks: an
--  operator whose operands are arrays looks like any other operator, and
--  an aggregate written into a destination it also reads looks like any
--  other assignment.  This checks every program of the fixture
--  corpus as the language server checks one, then counts the nodes of each
--  source file once, however many programs reach it, with the types and
--  meanings the checker gave them.  The library and examples/ are counted
--  as far as the corpus reaches them: the derived programs' fixtures
--  import examples/, and the library's own fixtures import the library.
--
--  Each file is counted in the first program that reaches it, so a
--  library module's generic body is typed as its first instance typed it,
--  and a library module no program reaches is not counted at all: the
--  report says how many of the library's files were reached.  A program
--  is checked for the first target its fixture names, or linux-x86-64.
--  Counts are measurements for whoever decides, never a gate: nothing
--  here passes or fails.

package Landin.Testing.Census is

   --  Run from compiler/ada.  Writes the report on standard output; Ok is
   --  False when the corpus could not be read.
   procedure Run (Ok : out Boolean);

end Landin.Testing.Census;
