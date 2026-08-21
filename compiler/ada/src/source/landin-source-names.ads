--  Identities for the byte runs a program names.
--
--  A name is compared far more often than it is printed.  The parser has to
--  ask whether the identifier after `end` is the one before `:` [1800], and
--  name resolution asks that of every reference in the file.  Interning
--  answers it with one integer comparison, so no stage after the lexer
--  re-reads the bytes of an identifier.
--
--  This is a child of Landin.Source deliberately: a child sees the parent's
--  private part, so the body hashes and looks up bytes where they already
--  sit in the snapshot.  A sibling would have to be handed a copy of every
--  identifier in the file to look one up.
--
--  A table is limited.  An identity means something only against the table
--  that issued it, and a copy taken out of one names nothing.

private with Ada.Containers.Indefinite_Hashed_Maps;
private with Ada.Containers.Indefinite_Vectors;
private with Ada.Strings.Hash;

with Ada.Containers;

package Landin.Source.Names is

   --  Opaque, because an identity has to come from Intern.  An integer a
   --  caller invented would name a spelling no table has seen.
   type Name_Id is private;

   No_Name : constant Name_Id;

   type Table is tagged limited private;

   function Count (Of_Table : Table) return Natural;

   function Is_Interned (Of_Table : Table; Id : Name_Id) return Boolean;

   --  Interning is by bytes, so one spelling has one identity however many
   --  times and in however many files it is written.
   function Intern
     (Into : in out Table; From : Snapshot; Where : Span) return Name_Id
     with Pre  => Is_Valid (From, Where) and then Length (Where) > 0,
          Post => Intern'Result /= No_Name
                  and then Is_Interned (Into, Intern'Result);

   --  The same, for a caller holding letters rather than a span: the
   --  reserved words, and a test that asserts two spellings share one
   --  identity without building a snapshot to hold them.
   function Intern (Into : in out Table; Text : String) return Name_Id
     with Pre  => Text'Length > 0,
          Post => Intern'Result /= No_Name
                  and then Is_Interned (Into, Intern'Result);

   --  Printing is rare and copies.  Comparing is common and does not.
   function Spelling (Of_Table : Table; Id : Name_Id) return String
     with Pre => Is_Interned (Of_Table, Id);

   --  So a later stage may key a hashed container on an identity rather
   --  than on a string.  Report order is never identity order: a report is
   --  ordered by span, which Landin.Diagnostics already does.
   function Hash (Id : Name_Id) return Ada.Containers.Hash_Type;

private

   type Name_Id is range 0 .. Integer'Last;

   No_Name : constant Name_Id := 0;

   package Name_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => String);

   package Name_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => String,
      Element_Type    => Name_Id,
      Hash            => Ada.Strings.Hash,
      Equivalent_Keys => "=");

   --  Spellings are appended in first-appearance order, so an identity is a
   --  deterministic function of the bytes the compilation read.  The index
   --  holds a second copy of each spelling, and that is the whole cost.
   type Table is tagged limited record
      Spellings : Name_Vectors.Vector;
      Index     : Name_Maps.Map;
   end record;

end Landin.Source.Names;
