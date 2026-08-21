--  Diagnostic transport.
--
--  A diagnostic is data: a code, a severity, one primary label and any
--  number of secondary labels and notes.  Nothing here renders anything and
--  nothing here decides policy; rendering lives in a child package and the
--  catalogue of codes belongs to the frontend that raises them.
--
--  Codes are `L` followed by four digits.  They are asserted separately from
--  prose in tests, because a message may be reworded and a code may not be
--  changed silently.

with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Unbounded;

with Landin.Source;

package Landin.Diagnostics is

   type Severity is (Note, Warning, Error);

   subtype Code_String is String (1 .. 5);

   function Is_Valid_Code (Item : String) return Boolean
     is (Item'Length = 5
         and then Item (Item'First) = 'L'
         and then (for all Index in Item'First + 1 .. Item'Last =>
                     Item (Index) in '0' .. '9'));

   type Label_Role is (Primary, Secondary);

   type Label is private;

   function Make_Label
     (Source  : Landin.Source.Source_Id;
      Where   : Landin.Source.Span;
      Message : String;
      Role    : Label_Role := Secondary) return Label;

   function Source_Of (Item : Label) return Landin.Source.Source_Id;
   function Span_Of   (Item : Label) return Landin.Source.Span;
   function Message   (Item : Label) return String;
   function Role      (Item : Label) return Label_Role;

   type Diagnostic is private;

   --  A diagnostic always has a primary label, even when the span is empty:
   --  a report with no place in the source is a report nobody can act on.
   function Make
     (Code     : Code_String;
      Level    : Severity;
      Source   : Landin.Source.Source_Id;
      Where    : Landin.Source.Span;
      Message  : String) return Diagnostic
     with Pre => Is_Valid_Code (Code);

   function Code    (Item : Diagnostic) return Code_String;
   function Level   (Item : Diagnostic) return Severity;
   function Primary (Item : Diagnostic) return Label;

   procedure Add_Label (Item : in out Diagnostic; Extra : Label)
     with Pre => Role (Extra) = Secondary;

   function Label_Count (Item : Diagnostic) return Natural;
   function Nth_Label (Item : Diagnostic; Index : Positive) return Label
     with Pre => Index <= Label_Count (Item);

   procedure Add_Note (Item : in out Diagnostic; Text : String);

   function Note_Count (Item : Diagnostic) return Natural;
   function Nth_Note (Item : Diagnostic; Index : Positive) return String
     with Pre => Index <= Note_Count (Item);

   --  A collected report.  Order of appending is not the order of reporting:
   --  Sorted puts diagnostics where a reader expects them regardless of the
   --  order the stages happened to produce them in.
   type Diagnostic_List is tagged private;

   procedure Append (List : in out Diagnostic_List; Item : Diagnostic)
     with Post => Count (List) = Count (List)'Old + 1;

   function Count (List : Diagnostic_List) return Natural;

   function Get (List : Diagnostic_List; Index : Positive) return Diagnostic
     with Pre => Index <= Count (List);

   function Has_Errors (List : Diagnostic_List) return Boolean;

   function Count_Of
     (List : Diagnostic_List; Of_Level : Severity) return Natural;

   --  Deterministic order: source, then start offset, then end offset, then
   --  severity, then code, then message.  Two runs over the same input
   --  therefore report the same sequence, which is what makes a negative
   --  fixture assertable.
   function Sorted (List : Diagnostic_List) return Diagnostic_List;

private

   package ASU renames Ada.Strings.Unbounded;

   type Label is record
      Source  : Landin.Source.Source_Id := Landin.Source.No_Source;
      Where   : Landin.Source.Span      := Landin.Source.Empty_Span;
      Text    : ASU.Unbounded_String;
      Role    : Label_Role              := Secondary;
   end record;

   package Label_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => Label);

   package Note_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => String);

   type Diagnostic is record
      --  Not a code, and deliberately not shaped like one: an unset code
      --  is not a number the catalogue holds, and check.py refuses a code
      --  literal written outside it.
      Code    : Code_String := "?????";
      Level   : Severity    := Error;
      Primary : Label;
      Labels  : Label_Vectors.Vector;
      Notes   : Note_Vectors.Vector;
   end record;

   package Diagnostic_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => Diagnostic);

   type Diagnostic_List is tagged record
      Items : Diagnostic_Vectors.Vector;
   end record;

end Landin.Diagnostics;
