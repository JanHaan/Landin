--  D361's report lines, gathered as a backend emits its failed checks.
--
--  A hosted program with no selected panic handler writes one line to
--  standard error when a check fails, and each distinct line is one
--  read-only datum: two checks at the same operation share it.  The text
--  is Landin.Panics'; this keeps the table a backend fills in the order
--  it met each line, so the datums are emitted in a deterministic order,
--  and spells a line as an assembler string operand.

private with Ada.Containers.Indefinite_Hashed_Maps;
private with Ada.Containers.Indefinite_Vectors;
private with Ada.Strings.Hash;

package Landin.Backend.Trap_Reports is

   type Table is tagged limited private;

   --  The line's position in the table, adding it when it is new.
   function Index_Of (Into : in out Table; Text : String) return Positive;

   function Count (Of_Table : Table) return Natural;

   function Text (Of_Table : Table; Index : Positive) return String
     with Pre => Index <= Count (Of_Table);

   --  The bytes as a double-quoted `.ascii`/`.asciz` operand: printable
   --  ASCII as itself, a quote and a backslash escaped, and every other
   --  byte, a path's included, as a three-digit octal escape.
   function Quoted (Bytes : String) return String;

private

   package Index_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type => String, Element_Type => Positive,
      Hash => Ada.Strings.Hash, Equivalent_Keys => "=");

   package Text_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => String);

   type Table is tagged limited record
      Seen : Index_Maps.Map;
      Lines : Text_Vectors.Vector;
   end record;

end Landin.Backend.Trap_Reports;
