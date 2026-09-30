--  How a checked type is written for a person.
--
--  One spelling, and the one a program would write: `ptr mut u8`, `[]utf8`,
--  `pair(u8, 4)`, `a | b`, `[4]u16`, `any shape`.  The checker interns a
--  pointer union's name from it, so what a union is called in a report and
--  what an editor shows over one are the same bytes, and a second spelling
--  written for either would drift from the other.
--
--  A type the checker cannot spell in source is described in one word,
--  `function` or `variant`, and one it does not know is `_`.  The atoms of a
--  set are in each atom's own spelling order, and by declaration identity
--  between two spelt alike, so neither the order a declaration wrote them
--  nor the order the sets were first seen in can change the text.
--
--  Nothing here decides anything: every answer is read out of tables the
--  checker and the resolver already filled.

with Landin.Resolution;
with Landin.Source.Names;

package Landin.Checking.Spelling is

   --  Every table a spelling reads, and nothing it may change.
   type Tables
     (Types     : not null access constant Table;
      Meanings  : not null access constant Landin.Resolution.Table;
      Spellings : not null access constant Landin.Source.Names.Table)
   is limited null record;

   function Atoms_Text (From : Tables; Set_Id : Atom_Set_Id) return String;

   function Nominal_Text (From : Tables; Id : Nominal_Type_Id) return String;

   function Reference_Text (From : Tables; Id : Reference_Id) return String;

   function Referent_Text
     (From : Tables; Item : Reference_Descriptor) return String;

   function Shape_Text (From : Tables; Shape : Field_Shape) return String;

end Landin.Checking.Spelling;
